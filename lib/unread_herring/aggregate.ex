defmodule UnreadHerring.Aggregate do
  @moduledoc """
  Pure functions that turn raw Gmail message metadata into the hierarchy
  rendered by the sunburst.

  No I/O, no processes - everything here is plain data in, plain data out.

  ## Tree shape

  Every node (root included) is a map:

      %{
        id: String.t(),          # stable path, e.g. "root/b.com/a@b.com"
        label: String.t(),       # human-readable name
        count: non_neg_integer,  # messages under this node
        query: String.t() | nil, # Gmail search query (nil when unsearchable,
                                 # e.g. the bucket for unparseable senders)
        children: [node]         # sorted by count descending
      }

  ## Hierarchies (two rings below the root)

  - `:domain` - ring 1 is sender domains, ring 2 is sender addresses
    within each domain.
  - `:sender` - ring 1 is sender addresses (flat, no ring 2).
  - `:label`  - ring 1 is user-label names (a message may count under
    several labels; messages with no user label go under `"(no label)"`),
    ring 2 is sender domains within each label.
  """

  @unknown "unknown"
  @no_label "(no label)"

  @type node_t :: %{
          id: String.t(),
          label: String.t(),
          count: non_neg_integer(),
          query: String.t() | nil,
          children: [node_t()]
        }

  @type message :: %{
          required(:id) => String.t(),
          required(:from) => String.t() | nil,
          required(:label_ids) => [String.t()]
        }

  @type opts :: %{
          optional(:group_by) => :domain | :sender | :label,
          optional(:scope) => :unread | :all,
          optional(:window) => :d30 | :d90 | :y1 | :all,
          optional(:labels) => %{optional(String.t()) => String.t()}
        }

  @doc """
  Parses a Gmail `From` header into name, address and domain.

  Handles `"Display Name" <a@b.com>`, `Display Name <a@b.com>`, bare
  `a@b.com`, `<a@b.com>`. Empty, nil or otherwise unparseable input yields
  address `"unknown"` and domain `"unknown"`. Address and domain are
  lowercased; the name is trimmed of surrounding whitespace and quotes
  (and is `nil` when absent).
  """
  @spec parse_from(String.t() | nil) :: %{
          name: String.t() | nil,
          address: String.t(),
          domain: String.t()
        }
  def parse_from(nil), do: %{name: nil, address: @unknown, domain: @unknown}

  def parse_from(from) when is_binary(from) do
    case Regex.run(~r/^\s*(.*?)\s*<([^<>]*)>\s*$/s, from) do
      [_, name, addr] ->
        %{address: address, domain: domain} = clean_address(addr)
        %{name: clean_name(name), address: address, domain: domain}

      nil ->
        bare = String.trim(from)

        if bare =~ ~r/^[^\s<>,;]+@[^\s<>,;]+$/ do
          %{address: address, domain: domain} = clean_address(bare)
          %{name: nil, address: address, domain: domain}
        else
          %{name: nil, address: @unknown, domain: @unknown}
        end
    end
  end

  defp clean_name(name) do
    name
    |> String.trim()
    |> String.trim("\"")
    |> String.trim()
    |> case do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp clean_address(addr) do
    addr = addr |> String.trim() |> String.downcase()

    if addr =~ ~r/^[^\s@]+@[^\s@]+$/ do
      [_local, domain] = String.split(addr, "@", parts: 2)
      %{address: addr, domain: domain}
    else
      %{address: @unknown, domain: @unknown}
    end
  end

  @doc """
  Builds the scope/window part of a Gmail search query.

  `scope: :unread` contributes `is:unread`; `window:` `:d30`/`:d90`/`:y1`
  contribute `newer_than:30d`/`newer_than:90d`/`newer_than:1y`; `:all`
  contributes nothing for either. Parts are joined with spaces, so the
  result may be `""`.
  """
  @spec base_query(opts()) :: String.t()
  def base_query(opts) do
    scope =
      case Map.get(opts, :scope, :all) do
        :unread -> "is:unread"
        _ -> nil
      end

    # Restrict to the Inbox (what Gmail's sidebar badge counts) when asked;
    # without it, `is:unread` also matches archived/filtered-away mail.
    inbox = if Map.get(opts, :inbox, false), do: "in:inbox", else: nil

    window =
      case Map.get(opts, :window, :all) do
        :d30 -> "newer_than:30d"
        :d90 -> "newer_than:90d"
        :y1 -> "newer_than:1y"
        _ -> nil
      end

    [scope, inbox, window]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc """
  Folds a list of messages (`%{id:, from:, label_ids:}`) into a tree.

  `opts` is a map with `:group_by` (`:domain` | `:sender` | `:label`),
  `:scope` (`:unread` | `:all`), `:inbox` (boolean, restrict to the Inbox;
  defaults to `false` here - the Scanner defaults it to `true`), `:window`
  (`:d30` | `:d90` | `:y1` | `:all`) and `:labels` (a
  `%{label_id => label_name}` map of user labels, used by `:label`
  grouping; defaults to `%{}`).

  Note that with `:label` grouping a message counts under every user
  label it carries, so child counts may sum to more than the root count.
  """
  @spec build_tree([message()], opts()) :: node_t()
  def build_tree(messages, opts) do
    base = base_query(opts)

    root_label =
      case {Map.get(opts, :scope, :all), Map.get(opts, :inbox, false)} do
        {:unread, true} -> "Unread in Inbox"
        {:unread, false} -> "Unread everywhere"
        {_, true} -> "Inbox mail"
        {_, false} -> "All mail"
      end

    children =
      case Map.get(opts, :group_by, :domain) do
        :domain -> domain_children(messages, base)
        :sender -> sender_children(messages, base)
        :label -> label_children(messages, base, Map.get(opts, :labels, %{}))
      end

    %{
      id: "root",
      label: root_label,
      count: length(messages),
      query: base,
      children: children
    }
  end

  defp domain_children(messages, base) do
    messages
    |> Enum.map(&parse_from(&1.from))
    |> Enum.group_by(& &1.domain)
    |> Enum.map(fn {domain, parsed} ->
      domain_query = if domain == @unknown, do: nil, else: compose(base, "from:@" <> domain)

      senders =
        parsed
        |> Enum.frequencies_by(& &1.address)
        |> Enum.map(fn {address, count} ->
          leaf("root/#{domain}/#{address}", address, count, sender_query(base, address))
        end)
        |> sort_children()

      %{
        id: "root/" <> domain,
        label: domain,
        count: length(parsed),
        query: domain_query,
        children: senders
      }
    end)
    |> sort_children()
  end

  defp sender_children(messages, base) do
    messages
    |> Enum.frequencies_by(&parse_from(&1.from).address)
    |> Enum.map(fn {address, count} ->
      leaf("root/" <> address, address, count, sender_query(base, address))
    end)
    |> sort_children()
  end

  defp label_children(messages, base, labels) do
    messages
    |> Enum.flat_map(fn message ->
      domain = parse_from(message.from).domain

      message.label_ids
      |> Enum.map(&Map.get(labels, &1))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> [{@no_label, domain}]
        names -> Enum.map(names, &{&1, domain})
      end
    end)
    |> Enum.group_by(fn {name, _domain} -> name end, fn {_name, domain} -> domain end)
    |> Enum.map(fn {name, domains} ->
      filter = label_filter(name)

      children =
        domains
        |> Enum.frequencies()
        |> Enum.map(fn {domain, count} ->
          leaf(
            "root/#{name}/#{domain}",
            domain,
            count,
            if(domain == @unknown, do: nil, else: compose(base, filter <> " from:@" <> domain))
          )
        end)
        |> sort_children()

      %{
        id: "root/" <> name,
        label: name,
        count: length(domains),
        query: compose(base, filter),
        children: children
      }
    end)
    |> sort_children()
  end

  defp label_filter(@no_label), do: "has:nouserlabels"

  defp label_filter(name) do
    # Gmail has no way to escape a double quote inside a quoted phrase,
    # so strip any from the label name.
    name = String.replace(name, "\"", "")

    if name =~ ~r/\s/ do
      ~s(label:"#{name}")
    else
      "label:" <> name
    end
  end

  # Unparseable senders cannot be found with a Gmail search, so their
  # buckets carry no query.
  defp sender_query(_base, @unknown), do: nil
  defp sender_query(base, address), do: compose(base, "from:" <> address)

  defp leaf(id, label, count, query) do
    %{id: id, label: label, count: count, query: query, children: []}
  end

  defp sort_children(children) do
    Enum.sort_by(children, &{-&1.count, &1.label})
  end

  defp compose("", filter), do: filter
  defp compose(base, filter), do: base <> " " <> filter

  @doc """
  Finds the node with the given id anywhere in the tree, or `nil`.
  """
  @spec find_node(node_t(), String.t()) :: node_t() | nil
  def find_node(%{id: id} = node, id), do: node

  def find_node(%{children: children}, id) do
    Enum.find_value(children, &find_node(&1, id))
  end

  @doc """
  Returns the list of nodes from the root to the node with the given id
  (inclusive), suitable for breadcrumbs, or `nil` when the id is absent.
  """
  @spec path_to(node_t(), String.t()) :: [node_t()] | nil
  def path_to(%{id: id} = node, id), do: [node]

  def path_to(%{children: children} = node, id) do
    Enum.find_value(children, fn child ->
      case path_to(child, id) do
        nil -> nil
        path -> [node | path]
      end
    end)
  end
end
