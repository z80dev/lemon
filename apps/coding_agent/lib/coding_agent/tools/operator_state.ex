defmodule CodingAgent.Tools.OperatorState do
  @moduledoc """
  Lemon operator state and operator toolchain locations, which model-driven
  file mutations never write.

  `check_mutation/2` guards every model-driven local write:
  `FileValidation.check_mutation_target/2` (write, edit including anchored
  edits, patch, ast_grep rewrites, archive and SQLite writes, LSP workspace
  edits), `ACPFileBridge` before it asks an ACP client to write, delete or
  rename, `CodingAgent.Checkpoint.restore_filesystem/3` (the `fs_checkpoint`
  restore), browser outputs (downloads, screenshots, analysis captures) and
  media artifacts (the `:output_guard` the tool registry hands to
  `LemonSkills.Tools.MediaCommon`). A path is refused when its lexical form or
  its canonical form (every existing component resolved, symlinks included),
  compared case-insensitively,

    * is a protected root or one of its ancestors, so deleting, renaming or
      replacing it would take the root with it,
    * lies inside an explicit root (below), or
    * lies inside a broad root and outside the carve-outs below.

  An existing regular file with more than one hard link is refused too: its
  other names cannot be enumerated, so it could be operator state.
  `check_aliases/1` applies that rule alone to targets Lemon names itself.

  Broad roots: the Lemon home state directory (`~/.lemon`: `config.toml`, the
  secrets master key, the store, trust and skill-audit records, extensions,
  skills, `cron_memory`, kanban controller repos, execution-node credentials,
  managed installs and backups) and the agent directory (`LEMON_AGENT_DIR`).

  Explicit roots, which carve-outs never reopen:

    * the global config file, the secrets key file, the store directories, the
      dotenv file, the checkpoint directory and the Lemon Bot data directory
      (`LEMON_BOT_DATA_DIR`), wherever they are configured;
    * every operator-configured extension source root
      (`[runtime] extension_paths`, anchored like `ExtensionLifecycle`) and
      the global extensions directory;
    * toolchain locations Lemon executes from: `~/.local/bin`, `~/bin`, and for
      the trusted `git` (`[runtime] git_path`) and every post-edit checker or
      formatter found on `PATH`, the executable as found, its directory, its
      resolved target and that target's directory.

  Carve-outs, the model's work areas inside the broad roots, apply only
  strictly below their root: the assistant workspace (`<agent dir>/workspace`),
  profile workspaces (`profiles/<id>/workspace`), profile bot folders
  (`profiles/<id>/files`) and kanban worker worktrees (`kanban/worktrees`).
  Inside an assistant workspace, `.lemon/skill`, `.lemon/skills`,
  `.lemon/extensions` and `.lemon/config.toml` stay protected (profile skills
  and the workspace's project config).

  Two narrow grants, both set only by Lemon itself, never from tool input:

    * `:operator_state_grant` (a cron run, from the trusted
      `cron_memory_file` run metadata) admits exactly that one
      `cron_memory/<job>.md` path, compared exactly (no case folding);
    * `:operator_state_dir_grant` (the session plan writer) admits direct
      children of exactly that directory.

  The hard-link refusal applies under both grants.

  `shell_names_protected?/3` is the best-effort shell counterpart used by the
  tool approval gate; see its documentation for what it cannot see.
  """

  alias CodingAgent.{Config, RuntimeTables}
  alias CodingAgent.Tools.{LspDiagnostics, LspFormatter}
  alias LemonCore.{Paths, TrustedRoot}

  @cron_memory_dir "cron_memory"
  @shell_tools ~w(bash eval process_input)
  @max_shell_text_bytes 262_144
  @shielded_workspace_entries ~w(skill skills extensions config.toml)

  @doc """
  `:ok` unless `path` is Lemon operator state or an operator toolchain
  location. A path that cannot be resolved to rule that out is refused.
  """
  @spec check_mutation(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check_mutation(path, opts \\ []) when is_binary(path) do
    case forms(path) do
      {:ok, targets} ->
        cond do
          hard_linked?(List.last(targets)) ->
            hard_link_refusal(path)

          granted?(targets, opts) or dir_granted?(targets, opts) ->
            :ok

          protected?(targets) ->
            {:error, refusal(path)}

          true ->
            :ok
        end

      :error ->
        unresolvable(path)
    end
  end

  @doc """
  The alias rule alone, for a target Lemon derives itself (a session's
  `local://` scratch file): refuses a path that cannot
  be resolved or an existing regular file with more than one hard link.
  """
  @spec check_aliases(String.t()) :: :ok | {:error, String.t()}
  def check_aliases(path) when is_binary(path) do
    case forms(path) do
      {:ok, targets} ->
        if hard_linked?(List.last(targets)), do: hard_link_refusal(path), else: :ok

      :error ->
        unresolvable(path)
    end
  end

  defp hard_linked?(path),
    do: match?({:ok, %File.Stat{type: :regular, links: links}} when links > 1, File.lstat(path))

  defp hard_link_refusal(path),
    do:
      {:error,
       "Refusing to modify #{path}: it has other hard links, so it could be Lemon " <>
         "operator state."}

  defp unresolvable(path),
    do:
      {:error, "Cannot resolve #{path} to rule out Lemon operator state; refusing to modify it."}

  @doc """
  Absolute (unresolved) protected roots, broad and explicit; see the module
  documentation. Matching also uses each root's canonical form.
  """
  @spec protected_roots() :: [String.t()]
  def protected_roots, do: normalize(broad_roots() ++ explicit_roots())

  @doc """
  Whether a shell-like tool call (`bash`, `eval`, `process_input`) names
  operator state, so the approval gate must ask a one-time approval.

  Best effort, not a sandbox: it scans the call's text arguments (command,
  code, input, `cwd` and `env` values) after expanding `~`, `$HOME` and
  `${HOME}` for a protected root (toolchain locations only when the session
  can write them) or a `.lemon` path component, and treats a working directory
  inside the state or agent directory as naming it (from an assistant
  workspace, only when the text contains `..`). A command that builds a path at
  run time (variables, globs, `cd` chains through other names, scripts on
  disk) is not seen; file tools enforce `check_mutation/2` instead.
  """
  @spec shell_names_protected?(String.t(), map(), String.t() | nil) :: boolean()
  def shell_names_protected?(tool, params, cwd) when tool in @shell_tools and is_map(params) do
    home = Paths.home_dir()
    text = params |> shell_texts() |> Enum.map_join("\n", &expand_home_refs(&1, home))

    Regex.match?(shell_pattern(), text) or protected_shell_cwd?(params, cwd, text)
  end

  def shell_names_protected?(_tool, _params, _cwd), do: false

  # -- Mutation check ---------------------------------------------------------

  defp refusal(path) do
    "Refusing to modify #{path}: it is Lemon operator state or a toolchain location " <>
      "Lemon executes from. Ask the operator to change it."
  end

  defp protected?(targets) do
    layout = layout()
    targets |> Enum.map(&fold/1) |> Enum.any?(&protected_form?(&1, layout))
  end

  defp layout do
    state_dirs = forms_of(state_dirs())
    agent_dirs = forms_of(agent_dirs())

    %{
      broad: state_dirs ++ agent_dirs,
      explicit: forms_of(explicit_roots()),
      state_dirs: state_dirs,
      agent_dirs: agent_dirs
    }
  end

  defp forms_of(roots),
    do: roots |> normalize() |> Enum.flat_map(&root_forms/1) |> Enum.uniq()

  defp protected_form?(path, layout) do
    Enum.any?(layout.broad ++ layout.explicit, &inside?(&1, path)) or
      Enum.any?(layout.explicit, &inside?(path, &1)) or
      (Enum.any?(layout.broad, &inside?(path, &1)) and not carved?(path, layout))
  end

  defp carved?(path, layout) do
    Enum.any?(layout.agent_dirs, fn dir ->
      case below(path, dir) do
        ["workspace", _ | _] = segments -> not shielded?(tl(segments))
        _ -> false
      end
    end) or
      Enum.any?(layout.state_dirs, fn dir ->
        case below(path, dir) do
          ["profiles", id, "workspace", _ | _] = segments ->
            profile_id?(id) and not shielded?(Enum.drop(segments, 3))

          ["profiles", id, "files", _ | _] ->
            profile_id?(id)

          ["kanban", "worktrees", _ | _] ->
            true

          _ ->
            false
        end
      end)
  end

  defp below(path, dir) do
    prefix = slash(dir)

    if String.starts_with?(path, prefix),
      do: path |> String.replace_prefix(prefix, "") |> Path.split(),
      else: []
  end

  defp shielded?(segments) do
    name = fold(Paths.state_dir_name())

    segments
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [dir, entry] -> dir == name and entry in @shielded_workspace_entries end)
  end

  defp profile_id?(id), do: LemonCore.ProfileStore.validate_id(id) == :ok

  # Exact: the target's lexical and canonical forms must equal the grant's,
  # unfolded, and the grant must name a file directly in a cron_memory dir.
  defp granted?(targets, opts) do
    with grant when is_binary(grant) and grant != "" <- Keyword.get(opts, :operator_state_grant),
         true <- Path.extname(grant) == ".md",
         {:ok, ^targets} <- forms(grant) do
      memory_dirs =
        state_dirs()
        |> Enum.map(&Path.join(&1, @cron_memory_dir))
        |> Enum.flat_map(&exact_forms/1)

      Enum.all?(targets, &(Path.dirname(&1) in memory_dirs))
    else
      _ -> false
    end
  end

  defp dir_granted?(targets, opts) do
    with dir when is_binary(dir) and dir != "" <- Keyword.get(opts, :operator_state_dir_grant),
         {:ok, dir_forms} <- forms(dir) do
      Enum.all?(targets, &(Path.dirname(&1) in dir_forms))
    else
      _ -> false
    end
  end

  defp exact_forms(path) do
    case forms(path) do
      {:ok, forms} -> forms
      :error -> []
    end
  end

  # -- Roots ------------------------------------------------------------------

  defp broad_roots, do: state_dirs() ++ agent_dirs()

  defp explicit_roots, do: sensitive_roots() ++ toolchain_paths()

  defp sensitive_roots do
    [
      Paths.global_config(),
      LemonCore.Secrets.KeyProvider.key_file([]),
      store_dirs(),
      LemonCore.Dotenv.path_for(LemonCore.Dotenv.dir()),
      Paths.checkpoint_dir(),
      # Lemon Bot backend data (master key), default `~/.lemon/lemon_bot`.
      System.get_env("LEMON_BOT_DATA_DIR"),
      extension_roots()
    ]
  end

  defp toolchain_paths do
    home = Paths.home_dir()

    [Path.join([home, ".local", "bin"]), Path.join(home, "bin"), git_paths() | checker_paths()]
  end

  # `System.user_home/0` is where execution-node credentials live
  # (`CodingAgent.ExecutionNode.TokenStore`); it differs from `$HOME` only
  # when the environment was changed after boot.
  defp state_dirs do
    user_home = System.user_home()

    normalize([
      Paths.home_state_dir(),
      if(is_binary(user_home), do: Path.join(user_home, Paths.state_dir_name()))
    ])
  end

  defp agent_dirs, do: normalize([Config.agent_dir(), LemonSkills.Config.agent_dir()])

  defp store_dirs do
    for config <- [
          Application.get_env(:lemon_core, LemonCore.Store, []),
          Application.get_env(:lemon_core, :store_runtime_override, [])
        ],
        is_list(config),
        path = get_in(config, [:backend_opts, :path]),
        is_binary(path) and path != "",
        do: Paths.store_dir(path)
  end

  # Every configured source root, enabled or not (enabling one later must not
  # load bytes a model wrote meanwhile), anchored as `ExtensionLifecycle` does.
  defp extension_roots do
    anchor = Path.dirname(Paths.global_config())

    configured =
      case LemonCore.Config.cached() do
        %{agent: %{extension_paths: paths}} when is_list(paths) ->
          for path <- paths, is_binary(path), do: Path.expand(path, anchor)

        _ ->
          []
      end

    [Config.extensions_dir() | configured]
  rescue
    _ -> [Config.extensions_dir()]
  end

  defp git_paths do
    case LemonCore.SafeGit.executable() do
      {:ok, git} -> executable_paths(git)
      _ -> []
    end
  end

  # The executable as found and its directory, plus its resolved target and
  # that directory (`bin/prettier` -> `lib/node_modules/prettier/bin/...`).
  defp executable_paths(executable) do
    resolved =
      case TrustedRoot.realpath(executable) do
        {:ok, real} -> [real, Path.dirname(real)]
        {:error, _} -> []
      end

    [executable, Path.dirname(executable) | resolved]
  end

  # Looking every checker up on PATH costs hundreds of stats, so the result is
  # cached per PATH value for the runtime's life (a checker installed later
  # into a PATH directory that held none is covered after a restart).
  defp checker_paths do
    if RuntimeTables.available?(),
      do:
        RuntimeTables.fetch(
          {__MODULE__, :checker_paths, System.get_env("PATH")},
          &find_checker_paths/0
        ),
      else: find_checker_paths()
  end

  defp find_checker_paths do
    formatters = LspFormatter.list_formatters() |> Map.values() |> Enum.map(& &1.command)

    for command <- Enum.uniq(formatters ++ LspDiagnostics.commands()),
        executable = System.find_executable(command),
        is_binary(executable) and Path.type(executable) == :absolute,
        path <- executable_paths(executable),
        uniq: true,
        do: path
  end

  # Absolute, expanded, never the filesystem root (a root of "/" would refuse
  # every write rather than protect anything specific).
  defp normalize(paths) do
    paths
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.reject(&(Path.dirname(&1) == &1))
    |> Enum.uniq()
  end

  # -- Path forms -------------------------------------------------------------

  # The lexical form and the canonical form of `path`. Missing trailing
  # components are appended to the realpath of their nearest existing
  # ancestor; an existing component that does not resolve fails closed.
  defp forms(path) do
    lexical = Path.expand(path)

    with {:ok, canonical} <- canonical(lexical) do
      {:ok, Enum.uniq([lexical, canonical])}
    end
  end

  # Folded forms for matching only. Case-insensitive volumes (the macOS
  # default) resolve `~/.LEMON` to `~/.lemon` without realpath changing its
  # case, so every comparison is case-insensitive.
  defp root_forms(root) do
    case forms(root) do
      {:ok, forms} -> Enum.map(forms, &fold/1)
      :error -> [fold(root)]
    end
  end

  defp fold(path), do: String.downcase(path)

  defp canonical(path, missing \\ []) do
    case File.lstat(path) do
      {:ok, _} ->
        case TrustedRoot.realpath(path) do
          {:ok, real} -> {:ok, Path.join([real | missing])}
          {:error, _} -> :error
        end

      {:error, :enoent} ->
        parent = Path.dirname(path)
        if parent == path, do: :error, else: canonical(parent, [Path.basename(path) | missing])

      {:error, _} ->
        :error
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, slash(root))

  defp slash(dir), do: if(String.ends_with?(dir, "/"), do: dir, else: dir <> "/")

  # -- Shell ------------------------------------------------------------------

  defp shell_texts(value) when is_binary(value),
    do: [binary_part(value, 0, min(byte_size(value), @max_shell_text_bytes))]

  defp shell_texts(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&shell_texts/1)

  defp shell_texts(value) when is_list(value), do: Enum.flat_map(value, &shell_texts/1)
  defp shell_texts(_value), do: []

  defp expand_home_refs(text, home) do
    text = Regex.replace(~r/\$\{HOME\}|\$HOME(?![A-Za-z0-9_])/, text, fn _ -> home end)
    Regex.replace(~r/(^|[\s'"=:(])~(?=\/|$|[\s'";|&)])/, text, fn _, lead -> lead <> home end)
  end

  defp shell_pattern do
    roots =
      (broad_roots() ++ sensitive_roots())
      |> normalize()
      |> Kernel.++(Enum.reject(normalize(toolchain_paths()), &unwritable?/1))
      |> Enum.flat_map(&root_forms/1)
      |> Enum.uniq()
      |> Enum.map(&Regex.escape/1)

    name = Regex.escape(Paths.state_dir_name())
    boundary = "(?=$|[^A-Za-z0-9_.+@-])"

    Regex.compile!(
      "(?:" <>
        Enum.map_join(roots, "|", &(&1 <> boundary)) <>
        "|(?:^|[^A-Za-z0-9_.+@-])" <> name <> boundary <> ")",
      "i"
    )
  end

  defp unwritable?(path) do
    match?({:ok, %File.Stat{access: access}} when access in [:none, :read], File.stat(path))
  end

  defp protected_shell_cwd?(params, cwd, text) do
    run_cwd =
      case Map.get(params, "cwd") do
        dir when is_binary(dir) and dir != "" and is_binary(cwd) -> Path.expand(dir, cwd)
        dir when is_binary(dir) and dir != "" -> Path.expand(dir)
        _ -> cwd
      end

    with dir when is_binary(dir) <- run_cwd,
         {:ok, dir_forms} <- forms(dir),
         dir_forms = Enum.map(dir_forms, &fold/1) do
      layout = layout()
      data_dirs = layout.state_dirs ++ layout.agent_dirs

      # A working directory is a work area when its entries would be carved out.
      Enum.any?(dir_forms, fn form -> Enum.any?(data_dirs, &inside?(form, &1)) end) and
        (String.contains?(text, "..") or
           Enum.any?(dir_forms, &(not carved?(Path.join(&1, "entry"), layout))))
    else
      nil -> false
      :error -> true
    end
  end
end
