defmodule UnreadHerring.Browser do
  @moduledoc """
  Opens a URL in the user's default browser by shelling out to the
  platform launcher (`open` / `xdg-open` / `start`).
  """

  require Logger

  @doc "Opens `url` in the default browser. Logs instead of raising on failure."
  def open(url) do
    {cmd, args} = launcher(:os.type(), url)

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> fail(url, "#{cmd} exited with #{status}: #{String.trim(out)}")
    end
  rescue
    e in ErlangError -> fail(url, Exception.message(e))
  end

  defp launcher({:unix, :darwin}, url), do: {"open", [url]}
  defp launcher({:win32, _}, url), do: {"cmd", ["/c", "start", "", url]}
  defp launcher({:unix, _}, url), do: {"xdg-open", [url]}

  defp fail(url, reason) do
    Logger.warning("could not open browser (#{reason}); please open #{url} yourself")
    :error
  end
end
