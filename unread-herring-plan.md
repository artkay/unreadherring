# Unread Herring (Elixir) — Project Description & Plan

> A local-first, open-source **Elixir** tool that scans your Gmail, renders an
> interactive **sunburst** of where your mail comes from (grouped by sender
> domain / sender / label), lets you **drill down** through the rings, and lets
> you **click a wedge to open that exact filtered view in Gmail** in your
> browser. Built on **Phoenix LiveView** for the UI; launched from the terminal.

**Naming convention:** the display name is **Unread Herring** — a double Monty
Python pun (red herring → unread herring, plus the Knights Who Say Ni's
tree-felling herring). Tagline: *"Cut down the mightiest inbox."* Machine names:
Mix app `unread_herring`, module `UnreadHerring`, Hex package `unread_herring`,
repo `unread_herring`, config dir `~/.config/unread_herring/` — and the CLI
binary is just **`herring`** (so it's `herring scan`, `herring serve`).
Name availability was checked (GitHub/npm/PyPI clean as of June 2026); verify
`hex.pm/packages/unread_herring` before first publish.

---

## 1. What it is (and the shape of it)

You run a binary, `herring` (or `mix herring.serve` in dev). It:

1. Boots an OTP application with a Phoenix endpoint bound to `127.0.0.1` on a
   local port.
2. If there's no valid token, opens your default browser to start a one-time
   OAuth flow (loopback redirect back to the same local endpoint).
3. Opens your default browser to the LiveView dashboard.
4. You pick grouping + scope, hit **Scan**, watch a live progress bar as the
   BEAM fans out concurrent Gmail reads, then explore the sunburst.

This is the **Livebook model**: a terminal-launched Phoenix app you drive from
the browser. The terminal is the launcher/log surface; the rich UI is LiveView.

### Why LiveView here (honest version)
For a single-user local app, LiveView's server-pushes-diffs-over-websocket model
is heavier than strictly necessary — a static page with a little JS could do it.
But LiveView buys two things that are exactly what this project wants to exercise:
**live scan progress** straight from OTP processes, and **server-computed
interactive SVG** (drill-down, breadcrumbs) with almost no handwritten
JavaScript. The arc geometry is a clean, pure-function problem in Elixir. That's
the fun, and it's a legitimate use — not the optimal tool, the *enjoyable* one.

---

## 2. Goals / non-goals

**Goals**
- Group an inbox by domain / sender / label and show proportions visually.
- Drill down a ring to re-root the chart (click center to go back up).
- Click a wedge → open `https://mail.google.com/...#search/<query>` in the
  browser (the live, real filtered view in Gmail).
- Optional bulk actions on a focused bucket: mark-read / archive / trash.
- Ship as a self-contained binary; be pleasant to read as open-source Elixir.

**Non-goals**
- No permanent delete (scope ceiling is `gmail.modify`; trash only).
- No hosted/multi-tenant service. No database. No third-party servers.
- No attempt at a real-terminal (TUI) sunburst — SVG needs a browser.

---

## 3. Privacy & distribution model (the part that keeps it free)

The repo ships **no credentials**. Each user creates **their own** Google Cloud
OAuth client (Desktop type) and points the app at it via config/env. Consequences:

- Every user is their own app in their own Google Cloud project, in **Testing**
  mode, scoped to themselves — which is exempt from Google's OAuth verification
  and the annual CASA security assessment.
- The open-source project therefore **never** has a single OAuth app with
  external users, so the whole CASA question never applies to it.
- Nothing leaves the user's machine except calls to the Gmail API itself.

Document the "bring your own OAuth client" step prominently in the README.

---

## 4. Tech stack (current as of 2026)

- **Elixir / OTP**, **Phoenix ~> 1.8**, **Phoenix LiveView ~> 1.1**
  (streams, colocated hooks, JS-client types).
- **Req** for HTTP to the Gmail REST API (has a built-in test adapter, `Req.Test`).
- **Phoenix.PubSub** for scan progress; **Task.Supervisor** + `Task.async_stream`
  for concurrent metadata fetches.
- OAuth: lightweight flow via `assent` *or* hand-rolled with `Req`
  (`ueberauth` is more web-login oriented; we want an installed-app loopback
  with `access_type=offline` for a refresh token).
- No Ecto/DB — token + last-scan cache persisted to `~/.config/unread_herring/`
  (token file `0600`).
- Packaging: `mix release` for dev/prod, **Burrito** for single cross-platform
  binaries (needs Zig + xz to build; set `PHX_SERVER=1`; compile assets before
  wrapping; macOS Gatekeeper needs an exemption unless code-signed).
- Optional later: **D3** via a LiveView **colocated hook** for animated zoom.

> Alternative to raw Req: `GoogleApi.Gmail.V1` (the generated Tesla client) if you
> prefer a typed client. Req keeps deps minimal and the needed surface is small.

---

## 5. Architecture

### 5.1 Supervision tree
```
UnreadHerring.Application
├── Phoenix.PubSub                      # scan progress + completion events
├── UnreadHerringWeb.Endpoint               # LiveView UI + OAuth callback, 127.0.0.1
├── UnreadHerring.Auth.TokenStore           # GenServer: load / refresh / persist token
├── UnreadHerring.Scanner                   # GenServer: owns a scan + aggregated result
└── Task.Supervisor (UnreadHerring.Tasks)   # supervises concurrent fetch/scan tasks
```

### 5.2 Modules
- **`UnreadHerring.Auth`** — OAuth loopback (build consent URL, exchange code, refresh).
  `TokenStore` holds the current access token, refreshes lazily, persists the
  refresh token to disk.
- **`UnreadHerring.Gmail`** — thin Req client:
  - `list_message_ids(query, opts)` — paginate `users/me/messages`.
  - `fetch_metadata(ids)` — `Task.async_stream/3` over
    `users/me/messages/{id}?format=metadata&metadataHeaders=From`, bounded
    `max_concurrency` (~15), Req retry/backoff on 429/5xx. Returns `From` +
    `labelIds` per message.
  - `batch_modify(ids, add: [...], remove: [...])` — `messages/batchModify`
    (≤1000 ids/call; chunk).
  - `list_labels/0` — id→name map (filter `type: "user"` for label grouping).
- **`UnreadHerring.Aggregate`** — pure functions: parse `From` → address → domain;
  fold messages into `%{key => count}`; build the hierarchy
  (`root → bucket → children`).
- **`UnreadHerring.Sunburst`** — pure functions: turn the hierarchy + a "current
  root" into a list of arc segments `{node_id, start_angle, end_angle,
  r_inner, r_outer, color}`; emit SVG `path` `d` strings. Fully unit-testable,
  no I/O.
- **`UnreadHerring.Scanner`** — GenServer. `scan(opts)` spawns a supervised task that
  lists ids, fetches metadata, aggregates, and **broadcasts** `{:progress, n,
  total}` then `{:done, tree}` over PubSub. Caches the last result so drill-down
  and actions don't rescan.
- **`UnreadHerringWeb.DashboardLive`** — the LiveView (see §6).
- **`UnreadHerringWeb.OAuthController`** — `/auth` (redirect to Google) and
  `/oauth/callback` (exchange code, hand token to `TokenStore`, redirect to `/`).
- **`Mix.Tasks.Herring.Serve`** — boots the app, opens the browser.

### 5.3 Scan data flow
```
DashboardLive --cast--> Scanner --task--> Gmail.list_message_ids
                                   |          |
                                   |          v
                                   |     Gmail.fetch_metadata  (Task.async_stream, concurrent)
                                   |          |
                                   |          v
                                   |     Aggregate.fold ----> %{key => count} + hierarchy
                                   |
        PubSub {:progress n total} <┘   (during)        PubSub {:done, tree} (after)
                 |                                              |
                 v                                              v
        DashboardLive updates progress bar          DashboardLive assigns tree, renders sunburst
```

### 5.4 Opening filtered email in Gmail
Each wedge carries the Gmail search query for its node (e.g.
`is:unread from:@news.example.com`). Because the LiveView is already in the
browser, the simplest correct thing is an anchor:
`<a href={"https://mail.google.com/mail/u/0/#search/" <> URI.encode(query)}
    target="_blank">`. That opens the real, live filtered view in a new tab of
the same (default) browser. (For a truly headless launch, `UnreadHerring.Browser.open/1`
shells out to `open` / `xdg-open` / `start`; reused for auto-opening on boot.)

---

## 6. LiveView & visualization design

**Controls (a form):** group-by (`domain` | `sender` | `label`), scope
(`unread` | `all`), time window (`30d` | `90d` | `1y` | `all`), then **Scan**.

**Scan lifecycle:** on submit, `cast` to `Scanner`; `DashboardLive` shows a
progress bar fed by `{:progress, n, total}`; on `{:done, tree}` it assigns the
tree and renders the sunburst.

**Sunburst rendering (core approach — max LiveView, minimal JS):**
- `UnreadHerring.Sunburst` computes arc segments for the **current root** and renders
  them as server-side SVG `<path>` elements in the HEEx template.
- `phx-click="drill"` with `node_id` re-roots: assign `current_root = node_id`,
  recompute segments, LiveView diffs the SVG. Push a breadcrumb.
- Clicking the **center** pops the breadcrumb (zoom out), DaisyDisk-style.
- Hover shows a tooltip (label + count + share); a small side panel lists the
  focused node's children with counts and the "Open in Gmail" link + action
  buttons.

**Stretch (smooth animation):** a colocated hook wrapping **D3** that receives the
segment data via `pushEvent`/`this.el.dataset` and animates ring transitions
client-side. LiveView 1.1 lets this `<script :type={Phoenix.LiveView.ColocatedHook}>`
sit right in the component.

**Actions:** for the focused node, buttons → confirm modal (required for trash) →
`Gmail.batch_modify` via the Scanner/Gmail layer → toast → re-scan that bucket to
refresh counts. Scope stays `gmail.modify`; trash adds the `TRASH` label
(recoverable 30 days); no permanent delete path exists in the code.

---

## 7. Milestones

- **M0 — Skeleton.** `mix phx.new unread_herring --live --no-ecto`; bind to localhost;
  app supervision tree; health page; `herring.serve` task opens the browser.
- **M1 — Auth.** OAuth loopback (`/auth`, `/oauth/callback`), `TokenStore` with
  refresh + on-disk persistence (`0600`). BYO-credentials config.
- **M2 — Gmail client.** Req-based `list/get/batchModify/labels`; a `mix` smoke
  task that prints domain counts to stdout (prove the API before any UI).
- **M3 — Scanner + progress.** GenServer scan task; PubSub `{:progress}`/`{:done}`;
  `Aggregate` by domain; concurrency-bounded `Task.async_stream`.
- **M4 — Dashboard (list first).** LiveView controls + live progress bar +
  ranked list (no graph yet) wired to the Scanner.
- **M5 — Sunburst.** `Sunburst` geometry + server-SVG render + `drill` /
  center-up + breadcrumbs.
- **M6 — Open in Gmail.** Per-wedge query → anchor opening filtered Gmail tab.
- **M7 — Actions.** mark-read / archive / trash with confirm modal; re-scan.
- **M8 — Grouping options.** sender + label grouping; scope/window options.
- **M9 — Hardening.** Req retry/backoff for 429, large-mailbox caps + streamed
  scanning, empty/error states, toasts.
- **M10 — Package & publish.** `mix release` + Burrito targets (macOS/Linux/
  Windows); README with BYO-OAuth quickstart; LICENSE (MIT/Apache-2.0); CI.
- **Stretch.** D3 colocated-hook zoom animation; CSV export; thread-based
  counting; an Owl/`ratatouille` status line in the terminal.

---

## 8. Testing

- **Pure functions** (`Aggregate`, `Sunburst`): straight `ExUnit` — geometry
  angles sum to 2π, domain parsing, hierarchy folding.
- **Gmail client**: `Req.Test` stubs — no live calls in CI; assert request
  shapes (queries, batchModify bodies) and decode handling.
- **Auth**: stub the token endpoint; test refresh + persistence.
- **LiveView**: `Phoenix.LiveViewTest` — `render_submit` the scan form,
  `render_click` a wedge asserts re-root + breadcrumb, assert the Gmail anchor
  href, assert the trash confirm modal gates the action.

---

## 9. Risks / open questions
- **Large mailboxes:** ranking requires a `From` read per message. Mitigate with
  bounded concurrency, `newer_than:` windows, a scan cap with "scan more", and
  streaming progress. Watch Gmail per-user rate limits; back off on 429.
- **Testing-mode token expiry:** refresh tokens for sensitive scopes can expire
  ~weekly in Testing; document re-auth, or moving the consent screen to
  Production (still unverified, personal) to avoid it.
- **Burrito maturity:** great for distribution but self-described as experimental;
  keep a plain `mix release` path as the fallback, and document the macOS
  Gatekeeper/code-signing caveat.
- **Drill-down depth:** decide the hierarchy (domain→sender, or label→domain→
  sender). Start with two levels; generalize `Aggregate`/`Sunburst` to N levels.
- **Color stability:** assign deterministic colors per node key so re-renders
  don't reshuffle the palette (hash the key → hue).
