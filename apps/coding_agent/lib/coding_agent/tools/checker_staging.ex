defmodule CodingAgent.Tools.CheckerStaging do
  @moduledoc """
  Private staging directories for formatter and checker input and output.

  A formatter or checker handed a workspace path opens that path by name, so a
  concurrent writer who swaps one of its directories for a symlink redirects
  it. Lemon instead reads the workspace file itself (descriptor-bound, through
  `CodingAgent.Tools.FileValidation`), writes those bytes into a fresh `0700`
  directory below `System.tmp_dir!/0`, lets the external process read and write
  only inside that directory, and reads the result back through
  `LemonCore.ConfinedFS`: never following a symlink, regular files only,
  bounded. The directory is created exclusively and removed afterwards.
  """

  alias LemonCore.ConfinedFS

  @enforce_keys [:fs, :dir, :path]
  defstruct [:fs, :dir, :path]

  @type t :: %__MODULE__{fs: ConfinedFS.t(), dir: pos_integer(), path: String.t()}

  @doc """
  Run `fun` with a new private staging directory, removing it afterwards.
  Returns `fun`'s result, or `{:error, message}` when the directory cannot be
  created.
  """
  @spec with_dir((t() -> result)) :: result | {:error, String.t()} when result: term()
  def with_dir(fun) when is_function(fun, 1) do
    tmp = System.tmp_dir!()
    name = "lemon-stage-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    result =
      ConfinedFS.with_root(tmp, fn fs ->
        with :ok <- ConfinedFS.mkdir(fs, :root, name, 0o700) do
          try do
            case ConfinedFS.open_dir(fs, :root, [name]) do
              {:ok, dir} ->
                {:ran, fun.(%__MODULE__{fs: fs, dir: dir, path: Path.join(tmp, name)})}

              {:error, _} = error ->
                error
            end
          after
            ConfinedFS.remove_tree(fs, :root, name)
          end
        end
      end)

    case result do
      {:ran, result} -> result
      {:error, reason} -> {:error, "cannot create a private staging directory (#{reason})"}
    end
  end

  @doc "Path of `name` inside the staging directory, for the external process."
  @spec path(t(), String.t()) :: String.t()
  def path(%__MODULE__{path: path}, name), do: Path.join(path, name)

  @doc "Create the `0600` file `name` with `content`."
  @spec write(t(), String.t(), iodata()) :: :ok | {:error, atom()}
  def write(%__MODULE__{fs: fs, dir: dir}, name, content) do
    case ConfinedFS.create(fs, dir, name, content, mode: 0o600, exact_mode: true) do
      {:ok, _stat} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Read the regular file `name`: at most `max_bytes` (`:too_large` beyond),
  never through a symlink (`:symlink`) or from a FIFO or other special file
  (`:not_regular`).
  """
  @spec read(t(), String.t(), non_neg_integer()) :: {:ok, binary()} | {:error, atom()}
  def read(%__MODULE__{fs: fs, dir: dir}, name, max_bytes) do
    case ConfinedFS.read(fs, dir, name, max_bytes) do
      {:ok, bytes, _stat} -> {:ok, bytes}
      {:error, _} = error -> error
    end
  end
end
