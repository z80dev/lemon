defmodule LemonAutomation.KanbanGitSandbox do
  @moduledoc """
  Controller-owned Git repositories and the sanitized environment for every
  controller `git` and `gh` command.

  ## Controller repositories

  A board's workspace repository is writable by people and agents who may not
  run programs, so its configuration must never select a program the
  controller runs. Kanban Git work therefore happens in a controller-owned bare
  repository per board, `~/.lemon/kanban/repos/<board>.git`:

    * Lemon creates it (`git init --bare` with an empty template) and writes its
      whole `config` itself (`controller_config/0`): no includes, no
      per-worktree configuration (`extensions.worktreeConfig` is never set), no
      filters, drivers, hooks, helpers or programs.
    * Before every command against it, the configuration file's SHA-256 is
      compared with that content and the command is refused
      (`:controller_config_changed`) on any difference.
    * Commands run with `GIT_DIR` set to the repository (or, for a worker
      worktree, to its administrative directory inside the repository) and
      `GIT_WORK_TREE` set to the worktree, so a worktree's `.git` file is never
      consulted.
    * The workspace's commits enter it only by `git fetch --no-tags <workspace>
      <refspec>`; Lemon reads objects from the workspace repository and never
      checks out, stages or commits there.

  ## Environment

  Every command (controller repository or not) runs with
  `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null` and
  `GIT_ATTR_NOSYSTEM=1`; other inherited `GIT_*` variables are removed
  (configured author/committer identity variables are kept). Command-scope
  configuration (`GIT_CONFIG_PARAMETERS`, the environment form of `git -c`)
  fixes `core.hooksPath` to an empty Lemon-owned directory, disables fsmonitor,
  pagers, editors, askpass, proxies, signing programs, alternate ref commands
  and credential helpers, and allows only the `https` transport
  (`protocol.allow=never`).

  Operator-owned global settings are honoured only where publication needs
  them: `credential.helper` values (for `push`/`ls-remote`) and
  `protocol.ssh.allow=always` from the operator's own global Git configuration,
  and identity (`user.name`, `user.email`). `:allowed_protocols` in trusted
  controller options (never tool or chat input) can add further transports, e.g.
  `file` for local test remotes.

  Outside controller repositories Lemon only runs commands that execute no
  configured program: `rev-parse` (repository discovery), `config --get
  user.name|user.email` (commit identity), `remote get-url` (resolving
  publication destinations when an operator previews or confirms a grant) and
  the serving side of a local fetch (`git-upload-pack`).

  `gh` runs with the same environment from an empty Lemon-owned directory, so
  it never reads a repository.
  """

  @always [
    {"core.fsmonitor", "false"},
    {"core.pager", "cat"},
    {"core.editor", "true"},
    {"sequence.editor", "true"},
    {"core.askPass", ""},
    {"core.sshCommand", ""},
    {"core.gitProxy", ""},
    {"core.alternateRefsCommand", ""},
    {"core.quotePath", "true"},
    {"diff.external", ""},
    {"commit.gpgSign", "false"},
    {"tag.gpgSign", "false"},
    {"gpg.program", ""},
    {"gpg.ssh.program", ""},
    {"gpg.x509.program", ""},
    {"credential.helper", ""},
    {"gc.auto", "0"},
    {"maintenance.auto", "false"},
    {"uploadpack.packObjectsHook", ""},
    {"user.useConfigOnly", "true"},
    {"protocol.allow", "never"}
  ]

  @identity ~w(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE)

  @typedoc "A controller repository command target."
  @type repo :: %{git_dir: binary(), common_dir: binary(), work_tree: binary() | nil}

  @doc """
  Port environment for a sanitized `git` command outside a controller
  repository. `publication: true` adds the operator's global credential
  helpers; `identity: [{"user.name", v}, {"user.email", v}]` supplies a
  commit identity, overridden by the operator's global identity.
  """
  @spec env(keyword()) :: {:ok, [{charlist(), charlist() | false}]} | {:error, term()}
  def env(opts) do
    with {:ok, hooks} <- lemon_dir("empty-hooks") do
      overrides =
        [{"core.hooksPath", hooks} | @always] ++
          supplied_identity(opts) ++
          identity_overrides() ++ protocol_overrides(opts) ++ credential_overrides(opts)

      {:ok, base_env() ++ config_env(overrides)}
    end
  end

  defp supplied_identity(opts) do
    for {key, value} <- Keyword.get(opts, :identity, []),
        key in ["user.name", "user.email"] and is_binary(value),
        do: {key, value}
  end

  @doc """
  Port environment for a command against a controller repository, built
  immediately before the command: the repository's configuration and, for a
  worktree, its administrative metadata are verified first (refusing on any
  difference), and `GIT_DIR`, `GIT_COMMON_DIR` (always the verified
  repository, whatever an administrative `commondir` file says) and
  `GIT_WORK_TREE` are fixed.
  """
  @spec controller_env(repo(), keyword()) ::
          {:ok, [{charlist(), charlist() | false}]} | {:error, term()}
  def controller_env(%{git_dir: git_dir, common_dir: common} = repo, opts)
      when is_binary(git_dir) and is_binary(common) do
    with :ok <- verify_controller(common),
         :ok <- verify_worktree_metadata(repo),
         {:ok, env} <- env(opts) do
      work_tree =
        case Map.get(repo, :work_tree) do
          path when is_binary(path) -> [{~c"GIT_WORK_TREE", String.to_charlist(path)}]
          _ -> []
        end

      {:ok,
       env ++
         [
           {~c"GIT_DIR", String.to_charlist(git_dir)},
           {~c"GIT_COMMON_DIR", String.to_charlist(common)} | work_tree
         ]}
    end
  end

  def controller_env(_repo, _opts), do: {:error, :invalid_controller_repo}

  # The worktree administrative files Git reads to locate and identify the
  # worktree must hold exactly what `git worktree add` wrote for this worktree
  # (`worktree_metadata/2`), and no per-worktree configuration may exist.
  defp verify_worktree_metadata(%{git_dir: common, common_dir: common}), do: :ok

  defp verify_worktree_metadata(%{git_dir: admin, common_dir: common} = repo) do
    with %{work_tree: work_tree, branch: branch} when is_binary(work_tree) and is_binary(branch) <-
           repo,
         true <- Path.dirname(admin) == Path.join(common, "worktrees"),
         {:ok, %{type: :directory}} <- File.lstat(admin),
         {:error, :enoent} <- File.lstat(Path.join(admin, "config.worktree")),
         true <-
           Enum.all?(worktree_metadata(work_tree, branch), fn {name, content} ->
             path = Path.join(admin, name)

             match?({:ok, %{type: :regular}}, File.lstat(path)) and
               File.read(path) == {:ok, content}
           end) do
      :ok
    else
      _ -> {:error, :worktree_metadata_changed}
    end
  end

  @doc """
  The administrative files of a controller worktree, as `git worktree add`
  records them: `commondir` (the repository, two levels up), `gitdir` (the
  worktree's `.git` file) and `HEAD` (the task branch). Checked when the
  worktree is created and before every command.
  """
  def worktree_metadata(work_tree, branch) do
    %{
      "commondir" => "../..\n",
      "gitdir" => Path.join(work_tree, ".git") <> "\n",
      "HEAD" => "ref: refs/heads/" <> branch <> "\n"
    }
  end

  @doc "Port environment and working directory for a sanitized `gh` command."
  @spec gh_env(keyword()) ::
          {:ok, [{charlist(), charlist() | false}], binary()} | {:error, term()}
  def gh_env(opts) do
    with {:ok, neutral} <- lemon_dir("neutral"),
         {:ok, env} <- env(opts) do
      {:ok, env, neutral}
    end
  end

  @doc "The exact configuration Lemon writes into every controller repository."
  @spec controller_config() :: binary()
  def controller_config do
    platform =
      case :os.type() do
        {:unix, :darwin} -> "\tignorecase = true\n\tprecomposeunicode = true\n"
        _ -> ""
      end

    "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n" <>
      "\tlogallrefupdates = false\n" <> platform <> "[gc]\n\tauto = 0\n"
  end

  @doc "Path of the controller repository for `board_id` (not created)."
  @spec controller_path(term()) :: {:ok, binary()} | {:error, term()}
  def controller_path(board_id) when is_binary(board_id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, board_id) do
      with {:ok, base} <- repos_base(), do: {:ok, Path.join(base, board_id <> ".git")}
    else
      {:error, :invalid_board}
    end
  end

  def controller_path(_board_id), do: {:error, :invalid_board}

  @doc """
  Creates (once) or verifies the controller repository for `board_id`. A
  repository whose configuration differs from `controller_config/0` is
  refused, never repaired.
  """
  @spec ensure_controller(term(), keyword()) :: {:ok, binary()} | {:error, term()}
  def ensure_controller(board_id, opts \\ []) do
    with {:ok, path} <- controller_path(board_id) do
      case File.lstat(path) do
        {:error, :enoent} -> create_controller(path, opts)
        {:ok, %{type: :directory}} -> with :ok <- verify_controller(path), do: {:ok, path}
        _ -> {:error, :invalid_controller_repo}
      end
    end
  end

  defp create_controller(path, opts) do
    with {:ok, template} <- lemon_dir("empty-template"),
         {:ok, env} <- env(opts),
         {:ok, _} <-
           LemonAutomation.KanbanGitWorkflow.raw_command(
             "git",
             ["init", "--quiet", "--bare", "--template=" <> template, "--", path],
             env,
             opts
           ),
         :ok <- File.write(Path.join(path, "config"), controller_config()),
         :ok <- verify_controller(path) do
      {:ok, path}
    else
      {:error, :controller_config_changed} = error -> error
      _ -> {:error, :controller_repo_unavailable}
    end
  end

  @doc """
  `:ok` when `path` is a controller repository directly under the Lemon-owned
  repository base whose `config` is exactly `controller_config/0` (compared by
  SHA-256).
  """
  @spec verify_controller(term()) :: :ok | {:error, term()}
  def verify_controller(path) when is_binary(path) do
    config = Path.join(path, "config")

    with {:ok, base} <- repos_base(),
         true <- Path.dirname(path) == base and String.ends_with?(path, ".git"),
         {:ok, %{type: :directory}} <- File.lstat(path),
         {:ok, %{type: :regular}} <- File.lstat(config),
         {:ok, content} <- File.read(config) do
      if :crypto.hash(:sha256, content) == :crypto.hash(:sha256, controller_config()),
        do: :ok,
        else: {:error, :controller_config_changed}
    else
      _ -> {:error, :invalid_controller_repo}
    end
  end

  def verify_controller(_path), do: {:error, :invalid_controller_repo}

  @doc """
  The command target for the worktree at `work_tree` (on `branch`) of
  controller repository `common`: its administrative directory is found from
  the repository's own records (`worktrees/*/gitdir`), never from the
  worktree's `.git` file. Its metadata is verified again before every command
  (`controller_env/2`).
  """
  @spec worktree_repo(term(), term(), term()) :: {:ok, repo()} | {:error, term()}
  def worktree_repo(common, work_tree, branch)
      when is_binary(common) and is_binary(work_tree) and is_binary(branch) do
    admin_root = Path.join(common, "worktrees")
    expected = Path.join(work_tree, ".git")

    with :ok <- verify_controller(common),
         {:ok, names} <- File.ls(admin_root),
         [admin] <-
           Enum.filter(names, fn name ->
             admin = Path.join(admin_root, name)

             match?({:ok, %{type: :directory}}, File.lstat(admin)) and
               match?({:ok, %{type: :regular}}, File.lstat(Path.join(admin, "gitdir"))) and
               File.read(Path.join(admin, "gitdir")) == {:ok, expected <> "\n"}
           end),
         repo = %{
           git_dir: Path.join(admin_root, admin),
           common_dir: common,
           work_tree: work_tree,
           branch: branch
         },
         :ok <- verify_worktree_metadata(repo) do
      {:ok, repo}
    else
      {:error, :controller_config_changed} = error -> error
      {:error, :worktree_metadata_changed} = error -> error
      _ -> {:error, :invalid_worktree}
    end
  end

  def worktree_repo(_common, _work_tree, _branch), do: {:error, :invalid_worktree}

  # Canonical, controller-created `~/.lemon/kanban/repos`.
  defp repos_base do
    path = LemonCore.Paths.home_path(["kanban", "repos"])

    with :ok <- File.mkdir_p(path),
         {:ok, base} <- LemonAutomation.KanbanAuthority.canonical_directory(path) do
      {:ok, base}
    else
      _ -> {:error, :controller_repo_unavailable}
    end
  end

  # Environment shared by every controller command.
  defp base_env do
    keep = MapSet.new(@identity)

    removed =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&(String.starts_with?(&1, "GIT_") and not MapSet.member?(keep, &1)))
      |> Enum.map(&{String.to_charlist(&1), false})

    removed ++
      [
        {~c"GIT_CONFIG_NOSYSTEM", ~c"1"},
        {~c"GIT_CONFIG_GLOBAL", ~c"/dev/null"},
        {~c"GIT_ATTR_NOSYSTEM", ~c"1"},
        {~c"GIT_TERMINAL_PROMPT", ~c"0"},
        {~c"GCM_INTERACTIVE", ~c"Never"},
        {~c"GH_PROMPT_DISABLED", ~c"1"},
        {~c"LC_ALL", ~c"C"}
      ]
  end

  # Command-scope configuration in `GIT_CONFIG_PARAMETERS`, the environment
  # form Git itself uses to pass `git -c` to every child Git process. Keys and
  # values are shell-single-quoted (`'key'='value'`), so empty values (which
  # reset lists such as `credential.helper`) are unambiguous.
  defp config_env(overrides) do
    parameters =
      overrides
      |> Enum.map(fn {key, value} -> sq(key) <> "=" <> sq(value) end)
      |> Enum.join(" ")

    [{~c"GIT_CONFIG_PARAMETERS", String.to_charlist(parameters)}]
  end

  defp sq(text),
    do: "'" <> (text |> String.replace("'", "'\\''") |> String.replace("!", "'\\!'")) <> "'"

  defp protocol_overrides(opts) do
    trusted = Keyword.get(opts, :allowed_protocols, [])
    ssh = if operator_global("protocol.ssh.allow") == ["always"], do: ["ssh"], else: []

    (["https"] ++ trusted ++ ssh)
    |> Enum.filter(&(is_binary(&1) and Regex.match?(~r/\A[a-z][a-z0-9+.-]*\z/, &1)))
    |> Enum.uniq()
    |> Enum.map(&{"protocol.#{&1}.allow", "always"})
  end

  defp identity_overrides do
    for key <- ["user.name", "user.email"],
        [value | _] <- [operator_global(key)],
        value != "",
        do: {key, value}
  end

  defp credential_overrides(opts) do
    if Keyword.get(opts, :publication) == true,
      do: Enum.map(operator_global("credential.helper"), &{"credential.helper", &1}),
      else: []
  end

  # The operator's own global Git configuration (never a board repository).
  defp operator_global(key) do
    env = Enum.reject(base_env(), fn {name, _} -> name == ~c"GIT_CONFIG_GLOBAL" end)

    case LemonAutomation.KanbanGitWorkflow.raw_command(
           "git",
           ["config", "--global", "--get-all", key],
           env,
           cwd: System.tmp_dir!()
         ) do
      {:ok, output} -> output |> String.split("\n", trim: true) |> Enum.filter(&String.valid?/1)
      _ -> []
    end
  end

  @doc "A canonical, controller-created empty directory under `~/.lemon/kanban`."
  def lemon_dir(name) do
    path = LemonCore.Paths.home_path(["kanban", name])

    with :ok <- File.mkdir_p(path),
         {:ok, dir} <- LemonAutomation.KanbanAuthority.canonical_directory(path),
         {:ok, []} <- File.ls(dir) do
      {:ok, dir}
    else
      _ -> {:error, :sandbox_unavailable}
    end
  end
end
