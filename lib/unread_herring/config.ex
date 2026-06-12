defmodule UnreadHerring.Config do
  @moduledoc """
  Resolves where Unread Herring keeps its on-disk state (OAuth token,
  last-scan cache). Defaults to `~/.config/unread_herring/`.
  """

  @doc "Absolute path to the config directory, created on demand."
  def dir do
    path =
      case Application.fetch_env!(:unread_herring, :config_dir) do
        {:home, rel} -> Path.join(System.user_home!(), rel)
        {:path, rel} -> Path.expand(rel)
        path when is_binary(path) -> Path.expand(path)
      end

    File.mkdir_p!(path)
    path
  end

  @doc "Path to a file inside the config directory."
  def path(filename), do: Path.join(dir(), filename)

  @doc """
  Writes `content` to `filename` in the config dir with `0600` permissions
  (owner read/write only). Used for the OAuth token file. The file is
  locked down before the content is written, so the secret is never
  briefly world-readable.
  """
  def write_private!(filename, content) do
    file = path(filename)
    File.touch!(file)
    File.chmod!(file, 0o600)
    File.write!(file, content)
    file
  end
end
