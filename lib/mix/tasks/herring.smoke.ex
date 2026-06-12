defmodule Mix.Tasks.Herring.Smoke do
  @shortdoc "Prints sender-domain counts for your mailbox (API smoke test)"

  @moduledoc """
  Smoke-tests the Gmail API client against your real mailbox.

  Lists messages matching a query, fetches their `From` headers, and prints
  a ranked table of sender-domain counts to stdout. Requires a completed
  OAuth flow (run `mix herring.serve` first).

  ## Usage

      mix herring.smoke [--query "is:unread"] [--max 500]

  ## Options

  - `--query` - Gmail search query (default: `is:unread`)
  - `--max` - maximum number of messages to scan (default: 500)
  """

  use Mix.Task

  @progress_dot_every 25

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args, strict: [query: :string, max: :integer])

    query = Keyword.get(opts, :query, "is:unread")
    max = Keyword.get(opts, :max, 500)

    Mix.Task.run("app.start")

    case UnreadHerring.Auth.TokenStore.get_access_token() do
      {:ok, _token} ->
        smoke(query, max)

      {:error, :not_authenticated} ->
        Mix.shell().error("Not authenticated with Gmail.")

        Mix.shell().info(
          "Run `mix herring.serve` and complete the browser OAuth flow first, then re-run this task."
        )

      {:error, reason} ->
        Mix.shell().error("Could not obtain an access token: #{inspect(reason)}")
    end
  end

  defp smoke(query, max) do
    Mix.shell().info("Listing messages for query \"#{query}\" (max #{max})...")

    case UnreadHerring.Gmail.list_message_ids(query, max: max) do
      {:ok, []} -> Mix.shell().info("No messages matched.")
      {:ok, ids} -> fetch_and_print(ids)
      {:error, reason} -> Mix.shell().error("Listing messages failed: #{inspect(reason)}")
    end
  end

  defp fetch_and_print(ids) do
    Mix.shell().info("Fetching metadata for #{length(ids)} messages...")

    counter = :counters.new(1, [])

    on_each = fn _result ->
      :counters.add(counter, 1, 1)
      if rem(:counters.get(counter, 1), @progress_dot_every) == 0, do: IO.write(".")
    end

    case UnreadHerring.Gmail.fetch_metadata(ids, on_each: on_each) do
      {:ok, messages} ->
        IO.write("\n")
        Mix.shell().info("Fetched #{length(messages)} of #{length(ids)} messages.")
        print_domain_table(messages)

      {:error, reason} ->
        Mix.shell().error("Metadata fetch failed: #{inspect(reason)}")
    end
  end

  defp print_domain_table(messages) do
    rows =
      messages
      |> Enum.map(&domain_of(&1.from))
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_domain, count} -> -count end)

    width =
      rows
      |> Enum.map(fn {_domain, count} -> count |> Integer.to_string() |> String.length() end)
      |> Enum.max(fn -> 1 end)

    Mix.shell().info("")

    Enum.each(rows, fn {domain, count} ->
      padded = count |> Integer.to_string() |> String.pad_leading(width)
      Mix.shell().info("#{padded} #{domain}")
    end)
  end

  # Self-contained domain extraction (intentionally not using
  # UnreadHerring.Aggregate): take the part after "@" from the address inside
  # <...> if present, otherwise from the bare address; lowercase; "unknown"
  # when unparseable.
  defp domain_of(nil), do: "unknown"

  defp domain_of(from) when is_binary(from) do
    address =
      case Regex.run(~r/<([^>]+)>/, from) do
        [_, addr] -> addr
        nil -> from
      end

    address
    |> String.trim()
    |> String.split("@")
    |> domain_from_parts()
  end

  defp domain_from_parts([_local | _rest] = parts) when length(parts) >= 2 do
    case parts |> List.last() |> String.trim() |> String.downcase() do
      "" -> "unknown"
      domain -> domain
    end
  end

  defp domain_from_parts(_no_at_sign), do: "unknown"
end
