defmodule LemonCore.SafeGit do
  @moduledoc """
  The one runner for Git commands Lemon starts on its own (session-start and
  per-turn environment context, ignore filtering, origin lookup, `@git-diff`
  references, `sessions.changes`, worktree inventory and cleanup checks,
  build and source metadata) rather than at a model's or user's explicit
  request. A repository Lemon reads this way may be an unpacked archive, a
  shared checkout or a tree an agent wrote into, so neither its configuration,
  its attributes, the workspace's `PATH` nor the BEAM's environment may make
  the read run a program.

  ## Executable

  `git` comes from the operator: `[runtime] git_path` in the global
  configuration (a project file cannot set it), else the first `git` in the
  fixed system directories #{inspect(~w(/usr/bin /usr/local/bin /opt/homebrew/bin /bin))}.
  The inherited `PATH` is never searched, an executable inside the repository
  being read is refused, and Git older than 2.31.0 is refused
  (`:unsupported_git_version`). The child's `PATH` is that same fixed list.

  ## Repository

  `repository/1` locates the repository with file reads under a deadline
  (`LemonCore.TrustedRoot.git_root/1` from the realpath of `path`, then
  `TrustedRoot.git_dirs/1`; metadata files must be regular and are read by a
  killable child), never with Git. The work-tree root, its `.git`, the Git
  directory, the common directory and its `config` must all be owned by the
  user running Lemon: Git's own `safe.directory` rule, which an explicit
  `GIT_DIR` would otherwise skip. `safe.directory` exceptions are never
  honoured.

  ## Private Git directory

  Git never reads the repository's live configuration. Each command runs with
  `GIT_DIR` set to a private, freshly created directory holding:

    * a `config` Lemon writes: repository format, object format and ref
      storage, a few work-tree comparison settings, `core.excludesFile`, and
      remote URLs/fetch specs and branch upstreams (data only). They are read
      from the validated common directory's `config` with `git config --file
      … --no-includes`; includes, worktree configuration and every other key
      (drivers, fsmonitor, hooks, helpers, `core.worktree`) never reach Git.
    * a copy of the validated Git directory's `HEAD`;
    * links to the validated common directory's object and ref stores, logs and
      `info/`, and `GIT_INDEX_FILE` naming the validated Git directory's index.

  A filter, textconv or diff driver selected by any attributes file
  (`.gitattributes`, `info/attributes`) therefore names no program, and
  replacing an included file or `commondir` after validation changes nothing
  Git reads. `GIT_WORK_TREE` is the validated root.

  ## Command

  Git runs without a shell, with:

    * a minimal environment: the fixed `PATH`, the operator's `HOME`, no system
      or global configuration (`GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_GLOBAL`,
      `GIT_ATTR_NOSYSTEM`), no transport (`GIT_ALLOW_PROTOCOL`), no lazy fetch
      and no optional locks; every other inherited variable is removed.
    * `--no-pager --no-optional-locks`, `--literal-pathspecs` (except for
      `check-ignore`, which rejects pathspec magic) and command-scope settings
      that disable fsmonitor, hooks, pagers, editors, askpass, SSH and proxy
      commands, external diff, credential helpers, signature display and
      signing programs, maintenance, submodule recursion and colour.
    * a fixed set of read-only subcommands. `status` gets
      `--ignore-submodules=all`, `diff` also `--no-ext-diff --no-textconv`,
      `hash-object` `--no-filters`; arguments that re-enable programs or write
      files (`--ext-diff`, `--textconv`, `--show-signature`, `--output`,
      `--recurse-submodules`, `--dirty`, ...) are refused.
    * a deadline (default 2 seconds, covering the private directory's
      preparation) and an output cap (default 256 KiB). The process is killed
      on either, and the private directory is removed afterwards.
  """

  import Bitwise, only: [&&&: 2]

  alias LemonCore.TrustedRoot

  @default_timeout_ms 2_000
  @discovery_timeout_ms 2_000
  @default_max_bytes 262_144
  @max_config_bytes 1_048_576
  @trusted_dirs ~w(/usr/bin /usr/local/bin /opt/homebrew/bin /bin)
  @minimum_version {2, 31, 0}
  @store_entries ~w(objects refs packed-refs reftable logs info shallow worktrees)

  @global_config [
    {"core.fsmonitor", "false"},
    {"core.hooksPath", "/dev/null"},
    {"core.pager", "cat"},
    {"core.editor", ":"},
    {"sequence.editor", ":"},
    {"core.askPass", ""},
    {"core.sshCommand", ""},
    {"core.gitProxy", ""},
    {"core.alternateRefsCommand", ""},
    {"diff.external", ""},
    {"credential.helper", ""},
    {"log.showSignature", "false"},
    {"gpg.program", ""},
    {"gpg.ssh.program", ""},
    {"gpg.x509.program", ""},
    {"gc.auto", "0"},
    {"maintenance.auto", "false"},
    {"submodule.recurse", "false"},
    {"color.ui", "never"}
  ]

  @commands ~w(rev-parse status diff ls-files check-ignore hash-object describe symbolic-ref rev-list)
  @refused_args ~w(--ext-diff --textconv --show-signature --output --open-files-in-pager
                   --recurse-submodules --dirty --broken --upload-pack --exec)

  @bool ~w(true false yes no on off 1 0)
  @copied_settings %{
    "core.repositoryformatversion" => ~w(0 1),
    "extensions.objectformat" => ~w(sha1 sha256),
    "extensions.refstorage" => ~w(files reftable),
    "core.filemode" => @bool,
    "core.ignorecase" => @bool,
    "core.precomposeunicode" => @bool,
    "core.symlinks" => @bool,
    "core.trustctime" => @bool,
    "core.quotepath" => @bool,
    "core.checkstat" => ~w(default minimal),
    "core.autocrlf" => ["input" | @bool],
    "core.eol" => ~w(lf crlf native),
    "core.excludesfile" => :string
  }
  @copied_subsections ~r/\A(remote)\.([^"\\\n]+)\.(url|fetch)\z|\A(branch)\.([^"\\\n]+)\.(remote|merge)\z/

  @typedoc "A validated repository: realpaths of its work tree, Git and common directories."
  @type repo :: %{root: String.t(), git_dir: String.t(), common_dir: String.t()}

  @typedoc "A command started by `open/3`."
  @type handle :: %{port: port(), private_dir: String.t()}

  @type result ::
          {:ok, binary(), non_neg_integer()}
          | {:truncated, binary(), :unknown}
          | {:error, term()}

  @doc """
  The operator-trusted `git`: `[runtime] git_path` from the global
  configuration, else the first `git` in the fixed system directories.
  """
  @spec executable() :: {:ok, String.t()} | {:error, :git_unavailable}
  def executable do
    candidates =
      case configured_git_path() do
        nil -> Enum.map(@trusted_dirs, &Path.join(&1, "git"))
        path -> [path]
      end

    case Enum.find(candidates, &executable_file?/1) do
      nil -> {:error, :git_unavailable}
      git -> {:ok, git}
    end
  end

  defp configured_git_path do
    case LemonCore.Config.cached() do
      %{agent: %{git_path: path}} when is_binary(path) and path != "" -> path
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp executable_file?(path) do
    Path.type(path) == :absolute and
      match?({:ok, %{type: :regular, mode: mode}} when (mode &&& 0o111) != 0, File.stat(path))
  end

  @doc """
  The validated repository containing `path`: `{:ok, repo}`, `:not_repository`
  when no ancestor holds a repository, `{:error, :untrusted_repository}` when
  the nearest one fails validation or ownership, or `{:error,
  :discovery_timeout}` when the file reads do not finish within 2 seconds.
  """
  @spec repository(String.t()) ::
          {:ok, repo()}
          | :not_repository
          | {:error, :untrusted_repository | :discovery_timeout}
  def repository(path) when is_binary(path) do
    task = Task.async(fn -> discover(path) end)

    case Task.yield(task, @discovery_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :discovery_timeout}
    end
  end

  defp discover(path) do
    with {:ok, real} <- TrustedRoot.realpath(Path.expand(path)),
         root when is_binary(root) <- TrustedRoot.git_root(real) do
      with {:ok, %{git_dir: git_dir, common_dir: common}} <- TrustedRoot.git_dirs(root),
           true <- owned?([root, Path.join(root, ".git"), git_dir, common]),
           true <- owned_if_present?(Path.join(common, "config")) do
        {:ok, %{root: root, git_dir: git_dir, common_dir: common}}
      else
        _ -> {:error, :untrusted_repository}
      end
    else
      nil -> :not_repository
      {:error, _} -> :not_repository
    end
  end

  @doc """
  Run `args` (a subcommand and its arguments) against `repo` and collect its
  output (stderr included). Options: `:git` (an explicit executable for
  trusted callers and tests; `nil` for unavailable; default `executable/0`),
  `:cd` (working directory inside the work tree; default its root),
  `:timeout_ms`, `:max_bytes`, and `:config` (extra `{key, value}` pairs for
  output formatting; Lemon's own settings follow and win).
  """
  @spec run(repo(), [String.t()], keyword()) :: result()
  def run(repo, args, opts \\ []) do
    deadline = deadline(opts)

    with {:ok, %{port: port, private_dir: dir}} <- start(repo, args, opts, deadline) do
      try do
        collect(port, deadline, [], 0, Keyword.get(opts, :max_bytes, @default_max_bytes))
      after
        File.rm_rf(dir)
      end
    end
  end

  @doc """
  Start `args` like `run/3` for a caller that streams stdin (`GIT_FLUSH=1`)
  and reads `handle.port` itself. The caller must `close/1` the handle.
  """
  @spec open(repo(), [String.t()], keyword()) :: {:ok, handle()} | {:error, term()}
  def open(repo, args, opts \\ []), do: start(repo, args, opts, deadline(opts))

  @doc "Kill a command started by `open/3` and remove its private directory."
  @spec close(handle()) :: :ok
  def close(%{port: port, private_dir: dir}) do
    kill(port)
    _ = File.rm_rf(dir)
    :ok
  end

  defp start(repo, args, opts, deadline) do
    with {:ok, args} <- command_args(args),
         {:ok, git} <- git(opts, repo),
         :ok <- supported_version(git, deadline),
         {:ok, cd} <- workdir(repo, opts),
         {:ok, dir} <- private_dir(git, repo, deadline) do
      config = Keyword.get(opts, :config, []) ++ @global_config

      case launch(git, env(repo, dir), cd, global_args(config) ++ pathspec_mode(args) ++ args) do
        {:ok, port} ->
          {:ok, %{port: port, private_dir: dir}}

        error ->
          _ = File.rm_rf(dir)
          error
      end
    end
  end

  defp deadline(opts),
    do: System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, @default_timeout_ms)

  defp git(opts, repo) do
    git =
      case Keyword.fetch(opts, :git) do
        {:ok, git} when is_binary(git) -> {:ok, git}
        {:ok, _} -> {:error, :git_unavailable}
        :error -> executable()
      end

    with {:ok, git} <- git do
      real =
        case TrustedRoot.realpath(git) do
          {:ok, real} -> real
          {:error, _} -> git
        end

      cond do
        Path.type(git) != :absolute ->
          {:error, :git_unavailable}

        Enum.any?([repo.root, repo.git_dir, repo.common_dir], &TrustedRoot.inside?(real, &1)) ->
          {:error, :untrusted_git}

        true ->
          {:ok, git}
      end
    end
  end

  # Checked once per executable path and cached in the supervised runtime cache
  # (rechecked on every call before it starts).
  defp supported_version(git, deadline) do
    key = {__MODULE__, :version, git}

    case LemonCore.RuntimeCache.get(key) do
      nil ->
        with {:ok, port} <- launch(git, base_env([]), "/", ["--version"]),
             {:ok, out, 0} <- collect(port, deadline, [], 0, 4_096) do
          result = if version(out) >= @minimum_version, do: :ok, else: :unsupported
          cache_put(key, result)
          if result == :ok, do: :ok, else: {:error, :unsupported_git_version}
        else
          {:error, _} = error -> error
          _ -> {:error, :unsupported_git_version}
        end

      :ok ->
        :ok

      :unsupported ->
        {:error, :unsupported_git_version}
    end
  end

  defp version(out) do
    case Regex.run(~r/\Agit version (\d+)\.(\d+)(?:\.(\d+))?/, out, capture: :all_but_first) do
      [major, minor | rest] ->
        {String.to_integer(major), String.to_integer(minor),
         String.to_integer(List.first(rest) || "0")}

      _ ->
        {0, 0, 0}
    end
  end

  defp workdir(%{root: root}, opts) do
    with {:ok, cd} <- TrustedRoot.realpath(Keyword.get(opts, :cd, root)),
         true <- TrustedRoot.inside?(cd, root) do
      {:ok, cd}
    else
      _ -> {:error, :outside_repository}
    end
  end

  defp command_args([command | rest] = args) when is_binary(command) do
    refused? =
      Enum.any?(rest, fn arg -> Enum.any?(@refused_args, &String.starts_with?(arg, &1)) end)

    cond do
      refused? ->
        {:error, :unsupported_command}

      command == "status" ->
        {:ok, ["status", "--ignore-submodules=all" | rest]}

      command == "diff" ->
        {:ok, ["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all" | rest]}

      command == "hash-object" ->
        {:ok, ["hash-object", "--no-filters" | rest]}

      match?(["remote", "get-url" | _], args) ->
        {:ok, args}

      match?(["reflog", "show" | _], args) or match?(["worktree", "list" | _], args) ->
        {:ok, args}

      command in @commands ->
        {:ok, args}

      true ->
        {:error, :unsupported_command}
    end
  end

  defp command_args(_args), do: {:error, :unsupported_command}

  # ── Private Git directory ─────────────────────────────────────────────

  defp private_dir(git, repo, deadline) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "lemon-git-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    result =
      with :ok <- File.mkdir(dir),
           :ok <- File.chmod(dir, 0o700),
           {:ok, settings} <- repository_settings(git, repo, dir, deadline),
           {:ok, head} <- head(repo.git_dir),
           :ok <- File.write(Path.join(dir, "config"), render_config(settings)),
           :ok <- File.write(Path.join(dir, "HEAD"), head),
           :ok <- link_store(repo, dir) do
        {:ok, dir}
      end

    case result do
      {:ok, dir} ->
        {:ok, dir}

      {:error, reason} when reason in [:timeout, :command_unavailable] ->
        _ = File.rm_rf(dir)
        {:error, reason}

      _ ->
        _ = File.rm_rf(dir)
        {:error, :repository_unreadable}
    end
  end

  # The validated common directory's own configuration file, without includes,
  # read as data; only allowlisted keys are copied.
  defp repository_settings(git, repo, dir, deadline) do
    config = Path.join(repo.common_dir, "config")

    case File.lstat(config) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, %{type: :regular}} ->
        args = ["--no-pager", "config", "--file", config, "--no-includes", "--list", "-z"]
        ceiling = [{"GIT_CEILING_DIRECTORIES", Path.dirname(dir)}]

        with {:ok, port} <- launch(git, base_env(ceiling), dir, args),
             {:ok, out, 0} <- collect(port, deadline, [], 0, @max_config_bytes) do
          {:ok, out |> String.split(<<0>>, trim: true) |> Enum.flat_map(&copied_setting/1)}
        else
          {:error, _} = error -> error
          _ -> {:error, :repository_unreadable}
        end

      _ ->
        {:error, :repository_unreadable}
    end
  end

  defp copied_setting(entry) do
    {key, value} =
      case String.split(entry, "\n", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, "true"}
      end

    cond do
      String.contains?(value, ["\n", <<0>>]) or not String.valid?(value) ->
        []

      Map.has_key?(@copied_settings, key) ->
        allowed = Map.fetch!(@copied_settings, key)

        if allowed == :string or String.downcase(value) in allowed,
          do: [{key, value}],
          else: []

      Regex.match?(@copied_subsections, key) ->
        [{key, value}]

      true ->
        []
    end
  end

  defp render_config(settings) do
    {version, settings} =
      case List.keytake(settings, "core.repositoryformatversion", 0) do
        {{_, version}, rest} -> {version, rest}
        nil -> {"0", settings}
      end

    sections =
      Enum.group_by(settings, fn {key, _} -> section(key) end, fn {key, value} ->
        {key |> String.split(".") |> List.last(), value}
      end)

    core = [
      {"repositoryformatversion", version},
      {"bare", "false"} | Map.get(sections, "core", [])
    ]

    sections
    |> Map.delete("core")
    |> Enum.sort()
    |> Enum.map(fn {header, entries} -> render_section(header, entries) end)
    |> then(&[render_section("core", core) | &1])
    |> IO.iodata_to_binary()
  end

  defp section(key) do
    case String.split(key, ".") do
      [section, name] when section != "" and name != "" -> section
      [section | rest] -> {section, rest |> Enum.drop(-1) |> Enum.join(".")}
    end
  end

  defp render_section({section, subsection}, entries),
    do: render_entries("[#{section} #{quote_value(subsection)}]\n", entries)

  defp render_section(section, entries), do: render_entries("[#{section}]\n", entries)

  defp render_entries(header, entries),
    do: [
      header | Enum.map(entries, fn {name, value} -> "\t#{name} = #{quote_value(value)}\n" end)
    ]

  defp quote_value(value),
    do: "\"" <> (value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""

  defp head(git_dir) do
    with {:ok, data} <- TrustedRoot.read_metadata(Path.join(git_dir, "HEAD"), 1_024),
         head = String.trim_trailing(data, "\n"),
         true <-
           Regex.match?(~r/\A(?:ref: refs\/[!-~]+|[0-9a-f]{40}|[0-9a-f]{64})\z/, head) and
             not String.contains?(head, "..") do
      {:ok, head <> "\n"}
    else
      _ -> {:error, :repository_unreadable}
    end
  end

  # Links bind the private directory to the validated common directory, so a
  # `commondir` file replaced after validation is never consulted.
  defp link_store(repo, dir) do
    shared =
      case File.ls(repo.git_dir) do
        {:ok, names} ->
          for name <- names, String.starts_with?(name, "sharedindex."), do: {repo.git_dir, name}

        _ ->
          []
      end

    Enum.reduce_while(
      Enum.map(@store_entries, &{repo.common_dir, &1}) ++ shared,
      :ok,
      fn {source_dir, name}, :ok ->
        source = Path.join(source_dir, name)

        case File.lstat(source) do
          {:ok, _} ->
            case File.ln_s(source, Path.join(dir, name)) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end

          {:error, :enoent} ->
            {:cont, :ok}

          error ->
            {:halt, error}
        end
      end
    )
  end

  # ── Process ───────────────────────────────────────────────────────────

  defp global_args(config) do
    ["--no-pager", "--no-optional-locks"] ++
      Enum.flat_map(config, fn {key, value} -> ["-c", key <> "=" <> value] end)
  end

  defp pathspec_mode(["check-ignore" | _]), do: []
  defp pathspec_mode(_args), do: ["--literal-pathspecs"]

  defp launch(git, env, cd, args) do
    port =
      LemonCore.NativeProcess.open({:spawn_executable, String.to_charlist(git)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        cd: String.to_charlist(cd),
        args: Enum.map(args, &String.to_charlist/1),
        env: env
      ])

    {:ok, port}
  rescue
    _ -> {:error, :command_unavailable}
  end

  defp env(repo, dir) do
    base_env([
      {"GIT_DIR", dir},
      {"GIT_WORK_TREE", repo.root},
      {"GIT_INDEX_FILE", Path.join(repo.git_dir, "index")}
    ])
  end

  defp base_env(extra) do
    home = for home <- [System.get_env("HOME")], is_binary(home), do: {"HOME", home}

    removed = for {name, _} <- System.get_env(), do: {String.to_charlist(name), false}

    removed ++
      Enum.map(
        [
          {"PATH", Enum.join(@trusted_dirs, ":")},
          {"GIT_CONFIG_NOSYSTEM", "1"},
          {"GIT_CONFIG_GLOBAL", "/dev/null"},
          {"GIT_ATTR_NOSYSTEM", "1"},
          # No transport name (they are URL-scheme characters) is "/".
          {"GIT_ALLOW_PROTOCOL", "/"},
          {"GIT_NO_LAZY_FETCH", "1"},
          {"GIT_TERMINAL_PROMPT", "0"},
          {"GIT_OPTIONAL_LOCKS", "0"},
          {"GIT_FLUSH", "1"},
          {"LC_ALL", "C"}
        ] ++ home ++ extra,
        fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end
      )
  end

  defp collect(port, deadline, chunks, size, max_bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        if size + byte_size(data) > max_bytes do
          part = binary_part(data, 0, max_bytes - size)
          kill(port)
          {:truncated, IO.iodata_to_binary(Enum.reverse([part | chunks])), :unknown}
        else
          collect(port, deadline, [data | chunks], size + byte_size(data), max_bytes)
        end

      {^port, {:exit_status, status}} ->
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks)), status}
    after
      remaining ->
        kill(port)
        {:error, :timeout}
    end
  end

  defp kill(port) do
    _ =
      with {:os_pid, pid} when pid > 1 <- Port.info(port, :os_pid) do
        LemonCore.ProcessGroup.terminate(pid, scope: :process)
      end

    Port.close(port)

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      0 -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # ── Ownership ─────────────────────────────────────────────────────────

  defp owned?(paths), do: Enum.all?(paths, &owned_by_user?/1)

  defp owned_if_present?(path) do
    case File.lstat(path) do
      {:error, :enoent} -> true
      _ -> owned_by_user?(path)
    end
  end

  defp owned_by_user?(path) do
    uid = current_uid()
    is_integer(uid) and match?({:ok, %{uid: ^uid}}, File.lstat(path))
  end

  # The effective uid, read from a file this process creates; unknown (every
  # repository untrusted) when no such file can be created.
  defp current_uid do
    case LemonCore.RuntimeCache.get({__MODULE__, :uid}) do
      nil ->
        uid = probe_uid()
        if is_integer(uid), do: cache_put({__MODULE__, :uid}, uid)
        uid

      uid ->
        uid
    end
  end

  # Outside a started application the cache table is absent; skip caching.
  defp cache_put(key, value) do
    LemonCore.RuntimeCache.put(key, value)
  rescue
    ArgumentError -> :ok
  end

  defp probe_uid do
    path =
      Path.join(
        System.tmp_dir!(),
        "lemon-uid-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    try do
      with :ok <- File.write(path, "", [:exclusive]),
           {:ok, %{uid: uid}} <- File.lstat(path) do
        uid
      else
        _ -> nil
      end
    after
      File.rm(path)
    end
  rescue
    _ -> nil
  end
end
