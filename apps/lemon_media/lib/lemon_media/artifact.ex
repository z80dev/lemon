defmodule LemonMedia.Artifact do
  @moduledoc """
  Writes media artifacts and builds the job updates that describe them.
  """

  @doc """
  Writes an artifact through an exclusive temporary file renamed over `path`,
  so an existing symlink or hard link at `path` is replaced, never written
  through: the inode it aliases is not modified.
  """
  @spec write(String.t(), iodata()) :: :ok | {:error, term()}
  def write(path, bytes) do
    dir = Path.dirname(path)
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    temp = Path.join(dir, ".#{Path.basename(path)}.tmp-#{suffix}")

    with :ok <- File.mkdir_p(dir) do
      try do
        with :ok <- File.write(temp, bytes, [:exclusive]), do: File.rename(temp, path)
      after
        File.rm(temp)
      end
    end
  end

  @doc """
  Writes `bytes` to `path` and returns the media-job updates for it, merged
  with `extra` (for example a transcript or a redacted provider job id).
  """
  @spec store(String.t(), binary(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def store(path, bytes, mime_type, extra \\ %{}) when is_binary(bytes) do
    with :ok <- write(path, bytes),
         {:ok, stat} <- File.stat(path) do
      {:ok,
       Map.merge(
         %{
           artifact_path: path,
           artifact_name: Path.basename(path),
           mime_type: mime_type,
           bytes: stat.size
         },
         extra
       )}
    end
  end
end
