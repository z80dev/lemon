defmodule LemonCore.ConfinedFS do
  @moduledoc """
  Descriptor-bound file operations below a trusted root directory.

  OTP has no `openat` or `O_NOFOLLOW`: a path checked with `lstat` and then
  opened, renamed or unlinked by path can be redirected by a concurrent writer
  who swaps a checked directory for a symlink between the two syscalls. This
  module runs those operations in a small port helper
  (`priv/lemon_confined_fs`, built from `c_src/lemon_confined_fs.c`) that
  holds directory descriptors and works relative to them:

    * `open/1` opens the trusted root (symlinks in the root path itself are
      followed: the caller chose that root); every other path is a list of
      single components below a directory handle. Empty components, `.`,
      `..`, `/` and NUL are refused before any syscall;
    * `open_dir/4` walks components with `openat(O_DIRECTORY | O_NOFOLLOW)`
      (on Linux first `openat2` with `RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS`),
      so a symlink anywhere below the root is refused with `:symlink` and a
      later swap of a walked path cannot move the returned handle;
    * leaf operations (`stat/3`, `read/5`, `create/5`, `replace/5`,
      `overwrite/5`, `append/5`, `mkdir/4`, `unlink/4`, `rmdir/3`,
      `remove_tree/3`, `rename/6`, `chmod/4`, `symlink/4`, `readlink/3`,
      `list/3`) use the `*at` calls on a handle and never follow a final
      symlink. Reads, appends and in-place writes open only regular files
      (non-blocking, so a FIFO cannot stall them) and require the opened
      descriptor to be the entry that was just checked; `:expect` binds them
      to an earlier `Stat`;
    * `replace/5` creates its temporary file `0600` inside a private `0700`
      staging directory that the helper creates in the target directory and
      holds by descriptor, applies the final mode through the descriptor and
      publishes it with `renameat` from the staging descriptor, so the
      contents are never more widely readable than the final mode and the
      published source is not looked up by a name another writer can replace
      in the target directory. The published entry is checked to be the
      written file afterwards; `remove_tree/3` empties directories through
      their own descriptors.

  Conditional operations: `expect: :absent` on `replace/5` publishes with an
  atomic no-replace rename (`renameat2(RENAME_NOREPLACE)` on Linux,
  `renamex_np(RENAME_EXCL)` on macOS, `linkat` where a filesystem lacks
  them), and `create/5` is `O_EXCL`. `expect: stat` on `read/5`,
  `overwrite/5` and `append/5` is bound to the opened inode. `expect: stat` on
  `replace/5` and `unlink/4` is best-effort conflict detection immediately
  before the rename or unlink, not compare-and-swap: an entry substituted in
  between is replaced or removed (still never through a symlink or outside
  the walked directory).

  A session is a process that owns one helper; it stops when its owner exits,
  including while a request is in flight. `with_root/2` opens and closes one
  around a function. A missing helper or a helper failure returns
  `{:error, reason}` (`:helper_unavailable`, `:helper_failed`,
  `:helper_timeout`) and never falls back to path-based I/O.

  ## Availability

  The helper is compiled into `priv/` by `mix compile` (`:elixir_make`, a C
  compiler and `make`). Inside the Lemon umbrella the build is required and
  `mix compile` fails without it; release verification requires the binary.
  As a Hex dependency, `lemon_core` builds the helper when `make` and a C
  compiler are present and otherwise compiles without it: `available?/0` is
  then `false` and every operation returns `{:error, :helper_unavailable}`,
  so callers that depend on confinement fail closed.

  Hard links are not symlinks: a hard link inside the root to a file elsewhere
  is the same file. Callers that must not write through one check
  `Stat.nlink`. Mount points below the root are crossed. A helper killed
  mid-`replace/5` can leave an empty-or-private `.lemon-stage-*` directory.
  """

  import Bitwise

  alias LemonCore.ConfinedFS.{Session, Stat}

  @enforce_keys [:server, :root]
  defstruct [:server, :root]

  @type t :: %__MODULE__{server: pid(), root: pos_integer()}
  @type dir :: :root | pos_integer()
  @type reason :: atom()

  @op_open_root 1
  @op_open_dir 2
  @op_close 3
  @op_stat 4
  @op_list 5
  @op_read 6
  @op_write 7
  @op_mkdir 8
  @op_unlink 9
  @op_rmdir 10
  @op_remove_tree 11
  @op_rename 12
  @op_chmod 13
  @op_symlink 14
  @op_readlink 15
  @op_append 16

  @how_create 1
  @how_replace 2
  @how_overwrite 3

  @flag_expect_identity 1
  @flag_expect_absent 2
  @flag_mode_exact 4
  @flag_sync 8
  @flag_preserve_mode 16
  @flag_prefix 32
  @flag_create 64

  @dir_create 1
  @rename_no_replace 1

  @max_name 255
  @default_max_entries 100_000

  @errors Map.new(
            ~w(enoent eexist eacces eperm enotdir eisdir symlink enotempty exdev enospc
               erofs ebusy emfile enfile enametoolong einval enxio etxtbsy efbig enomem
               eio enotsup edquot eagain not_regular changed too_large bad_request
               bad_handle too_many),
            &{&1, String.to_atom(&1)}
          )

  # Encoded `Stat` size (see LemonCore.ConfinedFS.Stat.decode/1).
  @stat_size 49

  # ---------------------------------------------------------------------------
  # Sessions
  # ---------------------------------------------------------------------------

  @doc "Path of the compiled helper."
  @spec helper_path() :: String.t()
  def helper_path, do: Application.app_dir(:lemon_core, "priv/lemon_confined_fs")

  @doc "Whether the compiled helper is present (see \"Availability\")."
  @spec available?() :: boolean()
  def available? do
    case File.stat(helper_path()) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
      _ -> false
    end
  end

  @doc """
  Open a session rooted at the absolute directory `root`. The session process
  stops when the calling process exits; call `close/1` when done.

  `stage_hook: {notify_fifo, resume_fifo}` is a test-only interleaving point:
  each `replace/5` writes its staging directory name to `notify_fifo` after
  writing the staged contents (before setting the mode or publishing) and
  waits for a byte on `resume_fifo`.
  """
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, reason()}
  def open(root, opts \\ [])

  def open(root, opts) when is_binary(root) do
    if Path.type(root) == :absolute and not String.contains?(root, <<0>>) do
      with {:ok, server} <- Session.start(helper_path(), self(), helper_args(opts)) do
        case request(server, [@op_open_root, bin(root)]) do
          {:ok, <<handle::32>>} ->
            {:ok, %__MODULE__{server: server, root: handle}}

          {:error, _} = error ->
            Session.stop(server)
            error
        end
      end
    else
      {:error, :einval}
    end
  end

  def open(_root, _opts), do: {:error, :einval}

  defp helper_args(opts) do
    case Keyword.get(opts, :stage_hook) do
      {notify, resume} when is_binary(notify) and is_binary(resume) ->
        ["--test-stage-hook", notify, resume]

      nil ->
        []
    end
  end

  @doc "Close a session and its helper."
  @spec close(t()) :: :ok
  def close(%__MODULE__{server: server}), do: Session.stop(server)

  @doc "Run `fun` with a session rooted at `root`, closing it afterwards."
  @spec with_root(Path.t(), (t() -> result)) :: result | {:error, reason()} when result: term()
  def with_root(root, fun) when is_function(fun, 1) do
    with {:ok, fs} <- open(root) do
      try do
        fun.(fs)
      after
        close(fs)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Paths
  # ---------------------------------------------------------------------------

  @doc """
  Split a relative path into components for this module. Empty and `.`
  components are dropped; `..`, absolute paths and NUL are refused.
  """
  @spec split(String.t()) :: {:ok, [String.t()]} | {:error, reason()}
  def split(rel) when is_binary(rel) do
    parts = rel |> String.split("/") |> Enum.reject(&(&1 in ["", "."]))

    cond do
      String.starts_with?(rel, "/") -> {:error, :einval}
      String.contains?(rel, <<0>>) -> {:error, :einval}
      Enum.any?(parts, &(&1 == "..")) -> {:error, :einval}
      true -> {:ok, parts}
    end
  end

  def split(_rel), do: {:error, :einval}

  @doc """
  The components of the absolute `path` below the absolute `root` (both
  lexically expanded), or `:error` when `path` is not `root` or below it.
  """
  @spec beneath(Path.t(), Path.t()) :: {:ok, [String.t()]} | :error
  def beneath(root, path) when is_binary(root) and is_binary(path) do
    root = Path.expand(root)
    path = Path.expand(path)

    cond do
      path == root ->
        {:ok, []}

      root == "/" ->
        {:ok, path |> Path.relative_to("/") |> Path.split()}

      String.starts_with?(path, root <> "/") ->
        {:ok,
         path
         |> binary_part(byte_size(root) + 1, byte_size(path) - byte_size(root) - 1)
         |> Path.split()}

      true ->
        :error
    end
  end

  # ---------------------------------------------------------------------------
  # Directories
  # ---------------------------------------------------------------------------

  @doc """
  Open the directory `parts` below `dir` as a new handle, refusing symlinks.

  Options: `create: true` creates missing components (mode `:mode`, default
  `0o777` before the umask).
  """
  @spec open_dir(t(), dir(), [String.t()], keyword()) :: {:ok, pos_integer()} | {:error, reason()}
  def open_dir(%__MODULE__{} = fs, dir, parts, opts \\ []) when is_list(parts) do
    flags = if Keyword.get(opts, :create, false), do: @dir_create, else: 0
    mode = Keyword.get(opts, :mode, 0o777)

    with :ok <- valid_names(parts) do
      case call(fs, [
             @op_open_dir,
             <<handle(fs, dir)::32, flags::32, mode::32, length(parts)::32>>,
             Enum.map(parts, &bin/1)
           ]) do
        {:ok, <<handle::32>>} -> {:ok, handle}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Open the parent of `parts` (all but the last component) and return it with
  the final name. Accepts `open_dir/4` options.
  """
  @spec open_parent(t(), dir(), [String.t()], keyword()) ::
          {:ok, pos_integer(), String.t()} | {:error, reason()}
  def open_parent(fs, dir, parts, opts \\ [])

  def open_parent(%__MODULE__{} = fs, dir, [_ | _] = parts, opts) do
    {dirs, [name]} = Enum.split(parts, -1)

    with :ok <- valid_name(name),
         {:ok, handle} <- open_dir(fs, dir, dirs, opts) do
      {:ok, handle, name}
    end
  end

  def open_parent(_fs, _dir, _parts, _opts), do: {:error, :einval}

  @doc "Release a directory handle."
  @spec close_dir(t(), pos_integer()) :: :ok | {:error, reason()}
  def close_dir(%__MODULE__{} = fs, handle) when is_integer(handle) do
    ok(call(fs, [@op_close, <<handle::32>>]))
  end

  @doc """
  List `dir`: `{name, stat}` pairs (no `.`/`..`), never following symlinks.
  Entries that vanish while listing are skipped. `prefix:` lists only names
  starting with it. More than `:max_entries` (default
  #{@default_max_entries}) is `{:error, :too_many}`.
  """
  @spec list(t(), dir(), keyword()) :: {:ok, [{String.t(), Stat.t()}]} | {:error, reason()}
  def list(%__MODULE__{} = fs, dir, opts \\ []) do
    max = Keyword.get(opts, :max_entries, @default_max_entries)
    prefix = Keyword.get(opts, :prefix, "")

    case call(fs, [@op_list, <<handle(fs, dir)::32, max::32>>, bin(prefix)]) do
      {:ok, <<count::32, rest::binary>>} -> {:ok, decode_entries(rest, count, [])}
      {:error, _} = error -> error
    end
  end

  @doc "Create the directory `name` in `dir` (mode before the umask)."
  @spec mkdir(t(), dir(), String.t(), non_neg_integer()) :: :ok | {:error, reason()}
  def mkdir(%__MODULE__{} = fs, dir, name, mode \\ 0o777) do
    with :ok <- valid_name(name) do
      ok(call(fs, [@op_mkdir, <<handle(fs, dir)::32>>, bin(name), <<mode::32>>]))
    end
  end

  @doc "Remove the empty directory `name` in `dir`."
  @spec rmdir(t(), dir(), String.t()) :: :ok | {:error, reason()}
  def rmdir(%__MODULE__{} = fs, dir, name) do
    with :ok <- valid_name(name) do
      ok(call(fs, [@op_rmdir, <<handle(fs, dir)::32>>, bin(name)]))
    end
  end

  @doc """
  Remove `name` in `dir` and, for a directory, everything below it, without
  following symlinks. Directories the owner cannot list or modify get owner
  access first.
  """
  @spec remove_tree(t(), dir(), String.t()) :: :ok | {:error, reason()}
  def remove_tree(%__MODULE__{} = fs, dir, name) do
    with :ok <- valid_name(name) do
      ok(call(fs, [@op_remove_tree, <<handle(fs, dir)::32>>, bin(name)]))
    end
  end

  # ---------------------------------------------------------------------------
  # Entries
  # ---------------------------------------------------------------------------

  @doc "`lstat` of `name` in `dir`; `\"\"` stats the directory itself."
  @spec stat(t(), dir(), String.t()) :: {:ok, Stat.t()} | {:error, reason()}
  def stat(%__MODULE__{} = fs, dir, name \\ "") do
    with :ok <- valid_name_or_self(name) do
      case call(fs, [@op_stat, <<handle(fs, dir)::32>>, bin(name)]) do
        {:ok, stat} -> {:ok, Stat.decode(stat)}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Read the regular file `name` in `dir`: `{:ok, bytes, stat}`. A file larger
  than `max_bytes` is `{:error, :too_large}`, or with `prefix: true` its
  first `max_bytes` bytes; a symlink is `:symlink`, any other non-regular
  entry `:not_regular`. `expect: stat` requires the same device and inode
  (`:changed` otherwise).
  """
  @spec read(t(), dir(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, binary(), Stat.t()} | {:error, reason()}
  def read(%__MODULE__{} = fs, dir, name, max_bytes, opts \\ [])
      when is_integer(max_bytes) and max_bytes >= 0 do
    {flags, dev, ino} = expectation(Keyword.get(opts, :expect))
    flags = flag(flags, Keyword.get(opts, :prefix, false), @flag_prefix)

    with :ok <- valid_name(name) do
      case call(fs, [
             @op_read,
             <<handle(fs, dir)::32>>,
             bin(name),
             <<max_bytes::64, flags::32, dev::64, ino::64>>
           ]) do
        {:ok, <<stat::binary-size(@stat_size), size::32, bytes::binary-size(size)>>} ->
          {:ok, bytes, Stat.decode(stat)}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Create `name` in `dir` exclusively (`O_CREAT | O_EXCL | O_NOFOLLOW`) with
  `data`. Options: `:mode` (default `0o666` before the umask),
  `exact_mode: true` applies `:mode` regardless of the umask, `sync: true`
  flushes the file and directory.
  """
  @spec create(t(), dir(), String.t(), iodata(), keyword()) ::
          {:ok, Stat.t()} | {:error, reason()}
  def create(%__MODULE__{} = fs, dir, name, data, opts \\ []) do
    write(fs, dir, name, @how_create, data, opts)
  end

  @doc """
  Atomically replace (or create) `name` in `dir`. `data` is written to a
  `0600` temporary file in a private staging directory, the final mode is set
  through its descriptor, and it is renamed over the entry (see the
  moduledoc). The entry must be absent or a regular file. `expect: :absent`
  publishes only if the entry is still absent (atomic); `expect: stat`
  requires it to still be that file, checked immediately before the rename
  (best-effort, not compare-and-swap). The final mode is `:mode` under the
  umask (default `0o666`), `exact_mode: true` applies `:mode` as given, and
  `preserve_mode: true` copies an existing entry's `0o777` bits. Also accepts
  `sync: true`.
  """
  @spec replace(t(), dir(), String.t(), iodata(), keyword()) ::
          {:ok, Stat.t()} | {:error, reason()}
  def replace(%__MODULE__{} = fs, dir, name, data, opts \\ []) do
    write(fs, dir, name, @how_replace, data, opts)
  end

  @doc """
  Overwrite the existing regular file `name` in `dir` in place (same inode,
  mode and links), truncating it to `data`. Accepts `expect:` and `sync:`.
  """
  @spec overwrite(t(), dir(), String.t(), iodata(), keyword()) ::
          {:ok, Stat.t()} | {:error, reason()}
  def overwrite(%__MODULE__{} = fs, dir, name, data, opts \\ []) do
    write(fs, dir, name, @how_overwrite, data, opts)
  end

  @doc """
  Append `data` to the regular file `name` in `dir` (`O_APPEND`, no-follow).
  `create: true` creates it exclusively with `:mode` when absent;
  `exact_mode: true` sets `:mode` on the opened file; `expect: stat` binds the
  opened file; `sync: true` flushes it.
  """
  @spec append(t(), dir(), String.t(), iodata(), keyword()) ::
          {:ok, Stat.t()} | {:error, reason()}
  def append(%__MODULE__{} = fs, dir, name, data, opts \\ []) do
    {expect_flags, dev, ino} = expectation(Keyword.get(opts, :expect))
    mode = Keyword.get(opts, :mode, 0o666)

    flags =
      expect_flags
      |> flag(Keyword.get(opts, :create, false), @flag_create)
      |> flag(Keyword.get(opts, :exact_mode, false), @flag_mode_exact)
      |> flag(Keyword.get(opts, :sync, false), @flag_sync)

    with :ok <- valid_name(name) do
      case call(fs, [
             @op_append,
             <<handle(fs, dir)::32>>,
             bin(name),
             <<mode &&& 0o7777::32, flags::32, dev::64, ino::64>>,
             <<IO.iodata_length(data)::32>>,
             data
           ]) do
        {:ok, stat} -> {:ok, Stat.decode(stat)}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Unlink the non-directory `name` in `dir`. `expect: stat` is checked
  immediately before the unlink (best-effort, not compare-and-swap).
  """
  @spec unlink(t(), dir(), String.t(), keyword()) :: :ok | {:error, reason()}
  def unlink(%__MODULE__{} = fs, dir, name, opts \\ []) do
    {flags, dev, ino} = expectation(Keyword.get(opts, :expect))

    with :ok <- valid_name(name) do
      ok(
        call(fs, [
          @op_unlink,
          <<handle(fs, dir)::32>>,
          bin(name),
          <<flags::32, dev::64, ino::64>>
        ])
      )
    end
  end

  @doc """
  `renameat` from `name` in `from_dir` to `to_name` in `to_dir`.
  `no_replace: true` fails with `:eexist` instead of replacing an entry.
  """
  @spec rename(t(), dir(), String.t(), dir(), String.t(), keyword()) :: :ok | {:error, reason()}
  def rename(%__MODULE__{} = fs, from_dir, name, to_dir, to_name, opts \\ []) do
    flags = if Keyword.get(opts, :no_replace, false), do: @rename_no_replace, else: 0

    with :ok <- valid_name(name),
         :ok <- valid_name(to_name) do
      ok(
        call(fs, [
          @op_rename,
          <<handle(fs, from_dir)::32>>,
          bin(name),
          <<handle(fs, to_dir)::32>>,
          bin(to_name),
          <<flags::32>>
        ])
      )
    end
  end

  @doc "Set permission bits of `name` in `dir` (`\"\"`: the directory), refusing symlinks."
  @spec chmod(t(), dir(), String.t(), non_neg_integer()) :: :ok | {:error, reason()}
  def chmod(%__MODULE__{} = fs, dir, name, mode) when is_integer(mode) do
    with :ok <- valid_name_or_self(name) do
      ok(call(fs, [@op_chmod, <<handle(fs, dir)::32>>, bin(name), <<mode &&& 0o7777::32>>]))
    end
  end

  @doc "Create the symlink `name` in `dir` pointing at `target` (never followed here)."
  @spec symlink(t(), dir(), String.t(), String.t()) :: :ok | {:error, reason()}
  def symlink(%__MODULE__{} = fs, dir, name, target) when is_binary(target) do
    with :ok <- valid_name(name) do
      ok(call(fs, [@op_symlink, <<handle(fs, dir)::32>>, bin(name), bin(target)]))
    end
  end

  @doc "The target of the symlink `name` in `dir`."
  @spec readlink(t(), dir(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def readlink(%__MODULE__{} = fs, dir, name) do
    with :ok <- valid_name(name) do
      case call(fs, [@op_readlink, <<handle(fs, dir)::32>>, bin(name)]) do
        {:ok, <<size::32, target::binary-size(size)>>} -> {:ok, target}
        {:error, _} = error -> error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp write(fs, dir, name, how, data, opts) do
    {expect_flags, dev, ino} = expectation(Keyword.get(opts, :expect))
    default_mode = 0o666
    mode = Keyword.get(opts, :mode, default_mode)

    flags =
      expect_flags
      |> flag(Keyword.get(opts, :exact_mode, false), @flag_mode_exact)
      |> flag(Keyword.get(opts, :sync, false), @flag_sync)
      |> flag(Keyword.get(opts, :preserve_mode, false), @flag_preserve_mode)

    with :ok <- valid_name(name) do
      case call(fs, [
             @op_write,
             <<handle(fs, dir)::32>>,
             bin(name),
             <<how::32, mode &&& 0o7777::32, flags::32, dev::64, ino::64>>,
             <<IO.iodata_length(data)::32>>,
             data
           ]) do
        {:ok, stat} -> {:ok, Stat.decode(stat)}
        {:error, _} = error -> error
      end
    end
  end

  defp flag(flags, true, bit), do: flags ||| bit
  defp flag(flags, _enabled, _bit), do: flags

  defp expectation(nil), do: {0, 0, 0}
  defp expectation(:absent), do: {@flag_expect_absent, 0, 0}
  defp expectation(%Stat{dev: dev, inode: ino}), do: {@flag_expect_identity, dev, ino}

  defp handle(%__MODULE__{root: root}, :root), do: root
  defp handle(_fs, handle) when is_integer(handle) and handle > 0, do: handle

  defp call(%__MODULE__{server: server}, iodata), do: request(server, iodata)

  defp request(server, iodata) do
    case Session.request(server, iodata) do
      {:ok, <<0, body::binary>>} -> {:ok, body}
      {:ok, <<1, name::binary>>} -> {:error, Map.get(@errors, name, :eio)}
      {:error, _} = error -> error
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok({:error, _} = error), do: error

  defp bin(value) when is_binary(value), do: [<<byte_size(value)::32>>, value]

  defp valid_names(parts) do
    Enum.reduce_while(parts, :ok, fn part, :ok ->
      case valid_name(part) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_name_or_self(""), do: :ok
  defp valid_name_or_self(name), do: valid_name(name)

  defp valid_name(name) when is_binary(name) do
    if name in ["", ".", ".."] or byte_size(name) > @max_name or
         String.contains?(name, ["/", <<0>>]),
       do: {:error, :einval},
       else: :ok
  end

  defp valid_name(_name), do: {:error, :einval}

  defp decode_entries(_rest, 0, acc), do: Enum.reverse(acc)

  defp decode_entries(
         <<size::32, name::binary-size(size), stat::binary-size(@stat_size), rest::binary>>,
         count,
         acc
       ),
       do: decode_entries(rest, count - 1, [{name, Stat.decode(stat)} | acc])
end

defmodule LemonCore.ConfinedFS.Stat do
  @moduledoc "`lstat` result from `LemonCore.ConfinedFS`; `mode` holds permission bits only."

  @enforce_keys [:type, :mode, :size, :dev, :inode, :nlink, :uid, :mtime]
  defstruct [:type, :mode, :size, :dev, :inode, :nlink, :uid, :mtime, mtime_nsec: 0]

  @type t :: %__MODULE__{
          type: :regular | :directory | :symlink | :other,
          mode: non_neg_integer(),
          size: non_neg_integer(),
          dev: non_neg_integer(),
          inode: non_neg_integer(),
          nlink: non_neg_integer(),
          uid: non_neg_integer(),
          mtime: integer(),
          mtime_nsec: non_neg_integer()
        }

  @doc false
  def decode(
        <<type, mode::32, size::64, dev::64, inode::64, nlink::32, uid::32, mtime::64-signed,
          mtime_nsec::32>>
      ) do
    %__MODULE__{
      type: decode_type(type),
      mode: mode,
      size: size,
      dev: dev,
      inode: inode,
      nlink: nlink,
      uid: uid,
      mtime: mtime,
      mtime_nsec: mtime_nsec
    }
  end

  @doc "Whether two stats name the same filesystem object (device and inode)."
  @spec same_object?(t(), t()) :: boolean()
  def same_object?(%__MODULE__{dev: dev, inode: inode}, %__MODULE__{dev: dev, inode: inode}),
    do: true

  def same_object?(_a, _b), do: false

  defp decode_type(1), do: :regular
  defp decode_type(2), do: :directory
  defp decode_type(3), do: :symlink
  defp decode_type(_), do: :other
end

defmodule LemonCore.ConfinedFS.Session do
  @moduledoc false
  # One helper port per session. The session monitors its owner and stops
  # (closing the port, so the helper sees EOF and exits) when the owner exits.

  use GenServer

  @reply_timeout 120_000

  def start(helper, owner, args \\ []) do
    if File.regular?(helper) do
      case GenServer.start(__MODULE__, {helper, owner, args}) do
        {:ok, pid} -> {:ok, pid}
        {:error, _} -> {:error, :helper_unavailable}
      end
    else
      {:error, :helper_unavailable}
    end
  end

  def stop(server) do
    GenServer.stop(server, :normal, :infinity)
  catch
    :exit, _ -> :ok
  end

  def request(server, iodata) do
    GenServer.call(server, {:request, iodata}, :infinity)
  catch
    :exit, _ -> {:error, :helper_failed}
  end

  @impl true
  def init({helper, owner, args}) do
    owner_ref = Process.monitor(owner)

    port =
      Port.open({:spawn_executable, helper}, [
        :binary,
        {:packet, 4},
        :exit_status,
        :use_stdio,
        :hide,
        args: args
      ])

    {:ok, {port, owner_ref}}
  rescue
    _error in [ArgumentError, ErlangError] -> {:stop, :helper_unavailable}
  end

  # The owner's exit is also handled while a request is in flight: the port
  # closes, so the helper stops at its next read of the request stream.
  @impl true
  def handle_call({:request, iodata}, _from, {port, owner_ref} = state) do
    true = Port.command(port, iodata)

    receive do
      {^port, {:data, reply}} ->
        {:reply, {:ok, reply}, state}

      {^port, {:exit_status, _status}} ->
        {:stop, :normal, {:error, :helper_failed}, state}

      {:DOWN, ^owner_ref, :process, _owner, _reason} ->
        {:stop, :normal, {:error, :helper_failed}, state}
    after
      @reply_timeout ->
        {:stop, :normal, {:error, :helper_timeout}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _owner, _reason}, {_port, ref} = state),
    do: {:stop, :normal, state}

  def handle_info({port, {:exit_status, _}}, {port, _ref} = state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}
end
