# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

This is a planned-but-not-yet-scaffolded Elixir project. There is no `mix.exs` yet; the only substantive file is `unread-herring-plan.md`, which is the source of truth for architecture, milestones, and design decisions. Read it before doing any implementation work. The first implementation step (milestone M0) is `mix phx.new unread_herring --live --no-ecto`.

## What this is

**Unread Herring** is a local-first Gmail inbox visualizer: a terminal-launched Phoenix LiveView app (the Livebook model) that scans Gmail via its REST API, renders an interactive sunburst of senders/domains/labels as server-side SVG, and lets you drill down or click a wedge to open that filtered view in Gmail. Optional bulk actions: mark-read, archive, trash.

## Naming conventions

- Display name: Unread Herring. Mix app `unread_herring`, module `UnreadHerring`, Hex package `unread_herring`.
- CLI binary is `herring` (e.g. `herring scan`, `herring serve`); dev equivalent is `mix herring.serve`.
- Config dir: `~/.config/unread_herring/` (token file must be `0600`).

## Commands (once scaffolded)

Standard Phoenix project commands will apply:

- `mix deps.get` - install dependencies
- `mix test` - run tests; `mix test test/path/to/file_test.exs:LINE` for a single test
- `mix format` - format code
- `mix herring.serve` - boot the app and open the browser (to be created in M0)

## Architecture (from the plan)

Supervision tree under `UnreadHerring.Application`: `Phoenix.PubSub`, `UnreadHerringWeb.Endpoint` (bound to `127.0.0.1` only), `UnreadHerring.Auth.TokenStore` (GenServer holding/refreshing the OAuth token), `UnreadHerring.Scanner` (GenServer owning a scan and its aggregated result), and a `Task.Supervisor` (`UnreadHerring.Tasks`).

Key layering:

- `UnreadHerring.Gmail` - thin Req-based HTTP client (list message ids, fetch metadata concurrently via `Task.async_stream` with bounded concurrency ~15, `batchModify` chunked at 1000 ids, list labels).
- `UnreadHerring.Aggregate` and `UnreadHerring.Sunburst` - pure functions, no I/O. Aggregate parses `From` headers into domain/sender hierarchies; Sunburst turns a hierarchy plus current root into arc segments and SVG path strings. Keep these pure and unit-testable.
- `UnreadHerring.Scanner` broadcasts `{:progress, n, total}` and `{:done, tree}` over PubSub; `UnreadHerringWeb.DashboardLive` subscribes and renders the progress bar and sunburst. Drill-down re-roots from the cached tree without rescanning.
- Scans are capped at the `:scan_max` app env (default 10,000 messages; runtime default override via `HERRING_SCAN_MAX`). The dashboard's "Max messages" input adjusts it per scan, clamped to 100,000 server-side; a truncation notice appears when a scan hits the cap.
- Sunburst interactivity is server-rendered SVG with `phx-click` - minimal JavaScript by design. D3 animation is a stretch goal via a LiveView colocated hook.

## Hard constraints

- **No shipped credentials.** Users bring their own Google Cloud OAuth client (Desktop type, Testing mode). This keeps the project exempt from Google OAuth verification/CASA; do not introduce any shared OAuth app.
- **OAuth scope ceiling is `gmail.modify`.** Trash only (adds the `TRASH` label); no permanent-delete code path may exist. Trash actions require a confirm modal.
- **No database, no Ecto, no hosted service.** State is the token and last-scan cache in `~/.config/unread_herring/`. Nothing leaves the machine except Gmail API calls.
- Endpoint binds to localhost only.

## Tech stack

Elixir/OTP, Phoenix ~> 1.8, LiveView ~> 1.1, Req for HTTP (use `Req.Test` stubs in tests - no live API calls in CI), Phoenix.PubSub, OAuth via assent or hand-rolled Req loopback flow (installed-app loopback with `access_type=offline`). Packaging via `mix release`, with Burrito for single-file binaries (keep plain `mix release` as the fallback).

## Testing approach

- Pure modules (`Aggregate`, `Sunburst`): plain ExUnit (e.g. arc angles sum to 2π, From-header parsing, hierarchy folding).
- Gmail client and auth: `Req.Test` stubs asserting request shapes and token refresh/persistence.
- UI: `Phoenix.LiveViewTest` - submit the scan form, click wedges to assert re-rooting/breadcrumbs, assert the Gmail anchor href and that the trash confirm modal gates the action.
