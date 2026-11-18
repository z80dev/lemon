defmodule LemonCore.CredentialPaths do
  @moduledoc """
  The single choke point that keeps model-directed tools away from Lemon's own
  credential files.

  `protected_paths/0` and `name_rules/0` list them, resolved from the Lemon home
  (`LemonCore.Paths`, `~/.lemon` by default) or their own configuration:

    * `nodes/execution/` — execution-node session and recovery tokens
      (`node_token_dir/0`, the `CodingAgent.ExecutionNode.TokenStore` default)
    * the secrets master key (`LemonCore.Secrets.KeyProvider.key_file/1`,
      `secrets_master_key` by default)
    * the encrypted secrets store: the `store/` directory and the configured
      store database (`LemonCore.Store.location/0`) with its `-wal`, `-shm` and
      `-journal` files
    * `cookie` (Erlang distribution cookie) and `web_secret_key_base` (and the
      launcher's `.web_secret_key_base.*` temporaries)
    * `env` and the runtime `.env` (`LemonCore.Dotenv`), which hold operator
      secrets
    * control-plane operator tokens in `run/`: any `*.token` file and the
      launcher's `.control-plane-*` temporaries; logs and pid files stay readable
    * the bot backend's `master.key`, `local-access.key` and its
      `.local-access.key.*` temporaries, in `lemon_bot/` and in
      `$LEMON_BOT_DATA_DIR`

  Lemon keeps no MCP OAuth token cache on disk (`LemonMCP.Client.HTTP` takes
  caller-supplied loader/persister callbacks), so there is no file to list.

  Every model-reachable byte reader calls `check_read/1` (or `check_read!/1`)
  on the file it is about to open; directory-scanning readers drop protected
  files with `reject/1`; mutations call `check_mutation/1`, which also refuses
  a directory whose subtree holds a protected path, so a rename or delete of a
  parent cannot move credentials out from under the list.

  A path is protected when, after resolving symlinks and `..` the way the
  kernel does, it is a protected path or lies below one (compared
  case-insensitively and by device/inode of every ancestor, so case-folding
  file systems, firmlinks and bind mounts do not alias around it), when it is a
  hard link to a protected file or to a file directly inside a protected
  directory, or when its name matches a name rule in the rule's directory.
  Unresolvable paths (symlink loops) are refused.

  `check_command/1` is the shell's best-effort counterpart: it refuses command
  text that names a protected path. It is a string check, not a sandbox: a
  shell can build the path at run time. Tools run as Lemon's OS user, so none
  of this is an OS boundary against code that the tools run.
  """

  alias LemonCore.Paths

  defmodule DeniedError do
    @moduledoc "Raised by `LemonCore.CredentialPaths.check_read!/1`."
    defexception [:message]
  end

  @max_links 40
  @store_suffixes ["", "-wal", "-shm", "-journal"]
  @bot_names ["master.key", "local-access.key"]
  # Distinctive file names refused in shell text even without a path.
  @command_names ["secrets_master_key", "web_secret_key_base", "local-access.key"]

  @typep rule :: {String.t(), {integer(), integer()} | nil, (String.t() -> boolean())}
  @typep snapshot :: %{
           prefixes: [String.t()],
           dirs: MapSet.t(),
           files: MapSet.t(),
           rules: [rule()]
         }

  @doc "Directory of the execution-node credential store (`nodes/execution`)."
  @spec node_token_dir() :: Path.t()
  def node_token_dir, do: Paths.home_path(["nodes", "execution"])

  @doc "Absolute protected paths (directories and files), unresolved."
  @spec protected_paths() :: [Path.t()]
  def protected_paths do
    [
      node_token_dir(),
      LemonCore.Secrets.KeyProvider.key_file([]),
      Paths.home_path("store"),
      Paths.home_path("cookie"),
      Paths.home_path("web_secret_key_base"),
      Paths.home_path("env"),
      Paths.home_path(".env"),
      LemonCore.Dotenv.path_for(nil)
    ]
    |> Kernel.++(store_files())
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  @doc """
  Protected file names inside a directory, as `{directory, predicate}` pairs;
  the predicate receives the lowercased base name.
  """
  @spec name_rules() :: [{Path.t(), (String.t() -> boolean())}]
  def name_rules do
    bot_rule = &(&1 in @bot_names or String.starts_with?(&1, ".local-access.key."))

    [
      {Paths.home_path("run"),
       &(String.ends_with?(&1, ".token") or String.starts_with?(&1, ".control-plane-"))},
      {Paths.home_state_dir(), &String.starts_with?(&1, ".web_secret_key_base.")},
      {Paths.home_path("lemon_bot"), bot_rule}
    ] ++
      case System.get_env("LEMON_BOT_DATA_DIR") do
        dir when is_binary(dir) and dir != "" -> [{Path.expand(dir), bot_rule}]
        _ -> []
      end
  end

  @doc "`:ok`, or a refusal when reading `path` would reach a credential file."
  @spec check_read(String.t()) :: :ok | {:error, String.t()}
  def check_read(path) when is_binary(path) do
    if protected?(snapshot(), path), do: {:error, refusal(path)}, else: :ok
  end

  def check_read(_path), do: :ok

  @doc "Like `check_read/1`, raising `DeniedError` instead of returning an error."
  @spec check_read!(String.t()) :: :ok
  def check_read!(path) do
    case check_read(path) do
      :ok -> :ok
      {:error, message} -> raise DeniedError, message: message
    end
  end

  @doc """
  `:ok`, or a refusal when creating, writing, renaming or deleting `path` would
  touch a credential file: `path` itself is protected, or it is a directory
  (or an alias of one) that contains a protected path or a name-rule directory.
  """
  @spec check_mutation(String.t()) :: :ok | {:error, String.t()}
  def check_mutation(path) when is_binary(path) do
    snapshot = snapshot()

    cond do
      protected?(snapshot, path) -> {:error, refusal(path)}
      contains_protected?(path) -> {:error, tree_refusal(path)}
      true -> :ok
    end
  end

  def check_mutation(_path), do: :ok

  @doc "Drops protected paths from a list of files (search scopes and results)."
  @spec reject([String.t()]) :: [String.t()]
  def reject([]), do: []

  def reject(paths) when is_list(paths) do
    snapshot = snapshot()
    Enum.reject(paths, &protected?(snapshot, &1))
  end

  @doc """
  Best-effort refusal of shell text that names a protected path (absolute,
  symlink-resolved, or home-relative such as `.lemon/cookie`). Not a sandbox;
  see the module doc.
  """
  @spec check_command(String.t()) :: :ok | {:error, String.t()}
  def check_command(text) when is_binary(text) do
    haystack = String.downcase(text)

    if Enum.any?(command_needles(), &String.contains?(haystack, &1)),
      do:
        {:error,
         "Command refused: it names a Lemon credential file, which tools cannot read or modify."},
      else: :ok
  end

  @doc false
  @spec refusal(String.t()) :: String.t()
  def refusal(path) do
    "Refusing #{path}: it is a Lemon credential file (credential store), which tools cannot " <>
      "read or modify."
  end

  defp tree_refusal(path) do
    "Refusing #{path}: it contains Lemon credential files (credential store), which tools " <>
      "cannot move or delete."
  end

  # The live store database, when the store runs a file-backed backend.
  # Memoized per store process: its location is fixed for its lifetime.
  defp store_files do
    case Process.whereis(LemonCore.Store) do
      nil ->
        []

      pid when pid == self() ->
        []

      pid ->
        key = {__MODULE__, :store_files}

        case LemonCore.RuntimeCache.get(key) do
          {^pid, files} ->
            files

          _ ->
            files = store_location_files()
            :ok = LemonCore.RuntimeCache.put(key, {pid, files})
            files
        end
    end
  end

  defp store_location_files do
    case LemonCore.Store.location() do
      {_backend, path} when is_binary(path) -> for suffix <- @store_suffixes, do: path <> suffix
      _ -> []
    end
  catch
    :exit, _ -> []
  end

  @spec snapshot() :: snapshot()
  defp snapshot do
    real_paths = real_paths()

    {dirs, files} =
      Enum.reduce(real_paths, {MapSet.new(), MapSet.new()}, fn path, {dirs, files} ->
        case File.stat(path) do
          {:ok, %File.Stat{type: :directory} = stat} ->
            {MapSet.put(dirs, id(stat)), MapSet.union(files, child_files(path, fn _ -> true end))}

          {:ok, %File.Stat{type: :regular} = stat} ->
            {dirs, MapSet.put(files, id(stat))}

          _ ->
            {dirs, files}
        end
      end)

    rules = real_rules()

    files =
      Enum.reduce(rules, files, fn {dir, _id, rule}, acc ->
        MapSet.union(acc, child_files(dir, &rule.(String.downcase(&1))))
      end)

    %{
      prefixes: Enum.map(real_paths, &String.downcase/1),
      dirs: dirs,
      files: files,
      rules: rules
    }
  end

  defp real_rules do
    for {dir, rule} <- name_rules(), {:ok, real} <- [resolve(dir)], do: {real, dir_id(real), rule}
  end

  defp child_files(dir, name_filter) do
    for {:ok, names} <- [File.ls(dir)],
        name <- names,
        name_filter.(name),
        {:ok, %File.Stat{type: :regular} = stat} <- [File.lstat(Path.join(dir, name))],
        into: MapSet.new(),
        do: id(stat)
  end

  defp real_paths do
    for path <- protected_paths(), {:ok, real} <- [resolve(path)], uniq: true, do: real
  end

  defp protected?(snapshot, path) do
    case resolve(path) do
      {:ok, real} ->
        under_prefix?(String.downcase(real), snapshot.prefixes) or
          named?(real, snapshot.rules) or hard_link?(real, snapshot.files) or
          ancestor_protected?(real, snapshot.dirs)

      :error ->
        true
    end
  end

  # A directory target whose subtree holds a protected path or a rule directory:
  # by canonical prefix, and by identity of the target among each protected
  # path's ancestors (bind mounts, firmlinks).
  defp contains_protected?(path) do
    case resolve(path) do
      {:ok, real} ->
        target = String.downcase(real)
        target_id = dir_id(real)
        inner = real_paths() ++ for({dir, _id, _rule} <- real_rules(), do: dir)
        prefix = String.trim_trailing(target, "/") <> "/"

        Enum.any?(inner, fn protected ->
          lowered = String.downcase(protected)

          lowered == target or String.starts_with?(lowered, prefix) or
            (target_id != nil and target_id in ancestor_ids(protected))
        end)

      :error ->
        true
    end
  end

  defp ancestor_ids(path) do
    id = dir_id(path)
    rest = if path == "/", do: [], else: ancestor_ids(Path.dirname(path))
    if id, do: [id | rest], else: rest
  end

  defp named?(_path, []), do: false

  defp named?(path, rules) do
    name = path |> Path.basename() |> String.downcase()
    parent = Path.dirname(path)

    Enum.any?(rules, fn {dir, id, rule} ->
      rule.(name) and
        (String.downcase(parent) == String.downcase(dir) or (id != nil and dir_id(parent) == id))
    end)
  end

  defp dir_id(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory} = stat} -> id(stat)
      _ -> nil
    end
  end

  defp under_prefix?(path, prefixes) do
    Enum.any?(prefixes, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  defp hard_link?(path, files) do
    with true <- MapSet.size(files) > 0,
         {:ok, %File.Stat{type: :regular} = stat} <- File.stat(path) do
      MapSet.member?(files, id(stat))
    else
      _ -> false
    end
  end

  defp ancestor_protected?(path, dirs) do
    if MapSet.size(dirs) == 0, do: false, else: ancestor_member?(path, dirs)
  end

  defp ancestor_member?(path, dirs) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory} = stat} -> MapSet.member?(dirs, id(stat))
      _ -> false
    end or (path != "/" and ancestor_member?(Path.dirname(path), dirs))
  end

  defp id(%File.Stat{major_device: device, inode: inode}), do: {device, inode}

  # Kernel-order resolution: each symlink is replaced by its target before the
  # next component (including `..`) is applied, unlike lexical `Path.expand/1`.
  defp resolve(path) do
    path = path |> expand_home() |> Path.absname()

    case walk(Path.split(path), "/", 0) do
      {:ok, real, _hops} -> {:ok, real}
      :error -> :error
    end
  end

  defp expand_home("~"), do: Paths.home_dir()
  defp expand_home("~/" <> rest), do: Path.join(Paths.home_dir(), rest)
  defp expand_home(path), do: path

  defp walk([], current, hops), do: {:ok, current, hops}
  defp walk(["/" | rest], _current, hops), do: walk(rest, "/", hops)
  defp walk(["." | rest], current, hops), do: walk(rest, current, hops)
  defp walk([".." | rest], current, hops), do: walk(rest, Path.dirname(current), hops)

  defp walk([part | rest], current, hops) do
    candidate = Path.join(current, part)

    case :file.read_link_all(candidate) do
      {:ok, _target} when hops >= @max_links ->
        :error

      {:ok, target} ->
        target = IO.chardata_to_string(target)
        base = if Path.type(target) == :absolute, do: "/", else: current

        with {:ok, resolved, hops} <- walk(Path.split(target), base, hops + 1),
             do: walk(rest, resolved, hops)

      {:error, _reason} ->
        walk(rest, candidate, hops)
    end
  end

  # Absolute and resolved paths; their home-relative spellings
  # (`~/.lemon/cookie`, `$HOME/.lemon/run/control-plane-…`, plus `.lemon/nodes`
  # for `cd ~/.lemon/nodes`); and distinctive file names.
  defp command_needles do
    home = Paths.home_state_dir()
    state_dir = Paths.state_dir_name()
    run = Paths.home_path("run")

    paths =
      protected_paths() ++
        [Path.join(run, "control-plane-"), Path.join(run, "*.token")] ++
        for {dir, _rule} <- name_rules(),
            dir != home and dir != run,
            name <- @bot_names,
            do: Path.join(dir, name)

    relative =
      for path <- paths,
          String.starts_with?(path, home <> "/"),
          do: Path.join(state_dir, Path.relative_to(path, home))

    (paths ++ real_paths() ++ relative ++ [Path.join(state_dir, "nodes")] ++ @command_names)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end
end
