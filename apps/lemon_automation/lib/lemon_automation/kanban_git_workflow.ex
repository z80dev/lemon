defmodule LemonAutomation.KanbanGitWorkflow do
  @moduledoc """
  Explicitly opted-in, isolated Git review/commit/publication operations.

  Checkpoints and snapshots have string keys and may be persisted as JSON. Pass
  `checkpoint: checkpoint` to `prepare/4` on recovery; a fresh prepare records the
  current HEAD, never an inferred historical base. Snapshots stage ignored-aware
  changes and review the entire resulting tree against the recorded base. Binary,
  submodule and oversized diffs fail closed. Commits bypass hooks and signing,
  use the configured Git identity, and update only the owned branch with CAS.

  Publication is disabled unless explicitly configured. Persist publish_pending
  before calling publish; after any dispatched publication failure, reconcile
  instead of retrying. Reconciliation is read-only and requires exact remote SHA
  and (for PRs) repository, head, base and head SHA agreement.

  All operations accept optional trailing keyword options. `:runner` is a test
  seam of arity three `(program, argv, options)`, returning `{:ok, stdout}` or
  `{:error, atom}`. Production uses supervised bounded ports, never a shell.
  Timeout, output overflow and caller death terminate the owned local process
  group through `LemonCore.ProcessGroup.terminate/2` before closing the port,
  including descendants that ignore stdin EOF. Descendants that deliberately
  leave the group are not contained.
  Options include `:task_supervisor` (default LemonAutomation.TaskSupervisor)
  and `:timeout_ms` (default 30 seconds, capped at 120 seconds).
  """

  alias LemonCore.ProcessGroup

  @diff_limit 128 * 1024
  @git_options [
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "commit.gpgSign=false",
    "-c",
    "diff.external=",
    "-c",
    "core.quotePath=true",
    "-c",
    "user.useConfigOnly=true"
  ]

  def normalize(raw) when raw in [nil, false], do: {:ok, nil}
  def normalize(%{"reviewModel" => nil}), do: {:error, :invalid_review_model}
  def normalize(%{"publish" => nil}), do: {:error, :invalid_publish}

  def normalize(raw) when is_map(raw) do
    with {:ok, values} <-
           keys(raw, %{
             "reviewModel" => :review_model,
             :review_model => :review_model,
             "publish" => :publish,
             :publish => :publish
           }),
         :ok <- optional_text(values[:review_model], :invalid_review_model),
         {:ok, publish} <- normalize_publish(values[:publish]) do
      {:ok, %{review_model: values[:review_model], publish: publish}}
    end
  end

  def normalize(_), do: {:error, :invalid_workflow}

  defp normalize_publish(value) when value in [nil, false], do: {:ok, nil}

  defp normalize_publish(raw) when is_map(raw) do
    allowed = Map.new([:mode, :remote, :repository, :base, :draft], &{Atom.to_string(&1), &1})
    allowed = Map.merge(allowed, Map.new([:mode, :remote, :repository, :base, :draft], &{&1, &1}))

    with {:ok, values} <- keys(raw, allowed),
         {:ok, mode} <- publication_mode(values[:mode]),
         true <- safe_remote?(values[:remote]),
         true <- is_boolean(Map.get(values, :draft, true)),
         :ok <- publication_target(mode, values) do
      {:ok,
       %{
         mode: mode,
         remote: values.remote,
         repository: values[:repository],
         base: values[:base],
         draft: Map.get(values, :draft, true)
       }}
    else
      false -> {:error, :invalid_publish}
      {:error, _} = error -> error
    end
  end

  defp normalize_publish(_), do: {:error, :invalid_publish}
  defp publication_mode(mode) when mode in ["branch", :branch], do: {:ok, :branch}

  defp publication_mode(mode) when mode in ["pull_request", :pull_request],
    do: {:ok, :pull_request}

  defp publication_mode(_), do: {:error, :invalid_publish}

  defp publication_target(:pull_request, values) do
    if repository?(values[:repository]) and ref_name?(values[:base]),
      do: :ok,
      else: {:error, :invalid_publish}
  end

  defp publication_target(:branch, values) do
    if (is_nil(values[:repository]) or repository?(values[:repository])) and
         (is_nil(values[:base]) or ref_name?(values[:base])),
       do: :ok,
       else: {:error, :invalid_publish}
  end

  defp keys(raw, allowed) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(allowed, key) do
        {:ok, canonical} ->
          if Map.has_key?(acc, canonical),
            do: {:halt, {:error, :duplicate_workflow_key}},
            else: {:cont, {:ok, Map.put(acc, canonical, value)}}

        :error ->
          {:halt, {:error, :unknown_workflow_key}}
      end
    end)
  end

  defp optional_text(nil, _), do: :ok
  defp optional_text(value, error), do: if(text?(value, 512), do: :ok, else: {:error, error})

  defp text?(value, limit),
    do:
      is_binary(value) and String.valid?(value) and
        byte_size(value) <= limit and String.trim(value) != "" and
        not String.contains?(value, ["\0", "\r", "\n"])

  defp safe_remote?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/, value)

  defp repository?(value),
    do:
      is_binary(value) and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*\z/, value)

  defp ref_name?(value),
    do:
      text?(value, 255) and not String.starts_with?(value, ["-", "/", "."]) and
        not String.ends_with?(value, ["/", ".", ".lock"]) and
        not String.contains?(value, ["..", "@{", "//", " ", "~", "^", ":", "?", "*", "[", "\\"]) and
        not Regex.match?(~r/[\x00-\x20\x7f]/, value)

  def prepare(workspace, task, config, opts \\ []) do
    with {:ok, normalized} when not is_nil(normalized) <- normalize(config),
         %{cwd: cwd, worktree: %{root: root, path: path, branch: branch}}
         when is_binary(cwd) and is_binary(root) and is_binary(path) and is_binary(branch) <-
           workspace,
         true <- is_map(task),
         id when is_binary(id) <- Map.get(task, :id, Map.get(task, "id")),
         true <- cwd == path and branch == LemonAutomation.KanbanWorktree.branch_for(task),
         true <- path == LemonAutomation.KanbanWorktree.path_for(root, task),
         :ok <- validate_context(root, path, branch, opts),
         {:ok, head} <- git(path, ["rev-parse", "HEAD"], opts),
         {:ok, checkpoint} <- checkpoint(root, path, branch, String.trim(head), opts) do
      {:ok, checkpoint}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_worktree}
    end
  end

  defp checkpoint(root, path, branch, head, opts) do
    current = %{"baseCommit" => head, "branch" => branch, "cwd" => path, "root" => root}

    case Keyword.get(opts, :checkpoint) do
      nil ->
        {:ok, current}

      %{"baseCommit" => base, "branch" => ^branch, "cwd" => ^path, "root" => ^root} = saved ->
        with true <- sha?(base),
             {:ok, _} <- git(path, ["merge-base", "--is-ancestor", base, head], opts) do
          {:ok, saved}
        else
          _ -> {:error, :invalid_checkpoint}
        end

      _ ->
        {:error, :invalid_checkpoint}
    end
  end

  @doc false
  def validate_context(root, path, branch, opts \\ []) do
    with true <- clean_path?(root) and clean_path?(path) and root != path and ref_name?(branch),
         {:ok, root_top} <- git(root, ["rev-parse", "--show-toplevel"], opts),
         true <- String.trim(root_top) == root,
         {:ok, top} <- git(path, ["rev-parse", "--show-toplevel"], opts),
         true <- String.trim(top) == path,
         {:ok, common_root} <-
           git(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"], opts),
         {:ok, common_path} <-
           git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"], opts),
         true <- String.trim(common_root) == String.trim(common_path),
         {:ok, git_dir} <- git(path, ["rev-parse", "--absolute-git-dir"], opts),
         true <- String.trim(git_dir) != String.trim(common_path),
         {:ok, actual_branch} <- git(path, ["symbolic-ref", "--quiet", "HEAD"], opts),
         true <- String.trim(actual_branch) == "refs/heads/#{branch}",
         {:ok, entries} <- git(root, ["worktree", "list", "--porcelain", "-z"], opts),
         true <- registered_worktree?(entries, path, branch) do
      :ok
    else
      _ -> {:error, :invalid_worktree}
    end
  end

  defp registered_worktree?(entries, path, branch) do
    entries
    |> String.split("\0\0", trim: true)
    |> Enum.any?(fn entry ->
      fields = String.split(entry, "\0", trim: true)
      "worktree #{path}" in fields and "branch refs/heads/#{branch}" in fields
    end)
  end

  @doc false
  def clean_path?(path) when is_binary(path) do
    if path == Path.expand(path) and not String.contains?(path, ["\0", "\n", "\r"]) do
      result =
        path
        |> Path.split()
        |> Enum.reduce_while("", fn segment, parent ->
          current = if parent == "", do: segment, else: Path.join(parent, segment)

          case File.lstat(current) do
            {:ok, %{type: :symlink}} -> {:halt, false}
            {:ok, _} -> {:cont, current}
            _ -> {:halt, false}
          end
        end)

      is_binary(result)
    else
      false
    end
  end

  def clean_path?(_), do: false

  def snapshot(checkpoint, opts \\ []) do
    with :ok <- validate_checkpoint(checkpoint, opts),
         cwd = checkpoint["cwd"],
         {:ok, _} <- git(cwd, ["add", "-A", "--", "."], opts),
         {:ok, head} <- git(cwd, ["rev-parse", "HEAD"], opts),
         {:ok, tree} <- git(cwd, ["write-tree"], opts),
         {:ok, base_tree} <- git(cwd, ["rev-parse", checkpoint["baseCommit"] <> "^{tree}"], opts),
         {:ok, diff} <- review_diff(cwd, checkpoint["baseCommit"], String.trim(tree), opts),
         :ok <- clean_index_worktree(cwd, opts) do
      {:ok,
       %{
         "headCommit" => String.trim(head),
         "tree" => String.trim(tree),
         "baseCommit" => checkpoint["baseCommit"],
         "diff" => diff,
         "changed" => String.trim(tree) != String.trim(base_tree)
       }}
    end
  end

  defp review_diff(cwd, base, tree, opts) do
    args = [
      "diff",
      "--no-ext-diff",
      "--no-textconv",
      "--no-renames",
      "--submodule=short",
      "--full-index",
      base,
      tree,
      "--"
    ]

    with {:ok, stat} <-
           git(
             cwd,
             ["diff", "--numstat", "--no-ext-diff", "--no-textconv", base, tree, "--"],
             opts
           ),
         false <- Regex.match?(~r/^\-\t\-\t/m, stat),
         {:ok, diff} <- git(cwd, args, Keyword.put(opts, :max_output_bytes, @diff_limit)),
         true <- String.valid?(diff) and not String.contains?(diff, "\0"),
         false <-
           Regex.match?(
             ~r/^(?:[ +-]Subproject commit |(?:old|new|deleted file|new file) mode 160000)/m,
             diff
           ) do
      {:ok, diff}
    else
      {:error, :output_too_large} -> {:error, :diff_too_large}
      {:error, _} = error -> error
      _ -> {:error, :unreviewable_diff}
    end
  end

  def commit(checkpoint, snapshot, title, opts \\ []) do
    with true <- text?(title, 4096),
         :ok <- validate_snapshot(checkpoint, snapshot, opts),
         {:ok, head_tree} <- git(checkpoint["cwd"], ["rev-parse", "HEAD^{tree}"], opts) do
      if String.trim(head_tree) == snapshot["tree"] do
        {:ok, snapshot["headCommit"]}
      else
        create_commit(checkpoint, snapshot, title, opts)
      end
    else
      false -> {:error, :invalid_commit_title}
      {:error, _} = error -> error
    end
  end

  defp create_commit(checkpoint, snapshot, title, opts) do
    cwd = checkpoint["cwd"]

    with {:ok, commit} <-
           git(
             cwd,
             ["commit-tree", snapshot["tree"], "-p", snapshot["headCommit"], "-m", title],
             opts
           ),
         commit = String.trim(commit),
         true <- sha?(commit),
         :ok <- validate_snapshot(checkpoint, snapshot, opts) do
      case git(
             cwd,
             [
               "update-ref",
               "refs/heads/" <> checkpoint["branch"],
               commit,
               snapshot["headCommit"]
             ],
             opts
           ) do
        {:ok, _} -> {:ok, commit}
        _ -> {:error, :commit_outcome_unknown}
      end
    else
      false -> {:error, :git_failed}
      {:error, _} = error -> error
    end
  end

  def reconcile_commit(checkpoint, snapshot, opts \\ []) do
    with :ok <- validate_checkpoint(checkpoint, opts),
         true <- valid_snapshot?(checkpoint, snapshot),
         {:ok, head} <- git(checkpoint["cwd"], ["rev-parse", "HEAD"], opts),
         {:ok, tree} <- git(checkpoint["cwd"], ["rev-parse", "HEAD^{tree}"], opts),
         true <- String.trim(tree) == snapshot["tree"],
         :ok <- commit_parent(checkpoint["cwd"], String.trim(head), snapshot["headCommit"], opts) do
      {:ok, String.trim(head)}
    else
      _ -> {:error, :commit_outcome_unknown}
    end
  end

  defp commit_parent(_cwd, head, head, _opts), do: :ok

  defp commit_parent(cwd, head, parent, opts) do
    case git(cwd, ["rev-list", "--parents", "-n", "1", head], opts) do
      {:ok, result} ->
        if String.split(result) == [head, parent],
          do: :ok,
          else: {:error, :commit_outcome_unknown}

      _ ->
        {:error, :commit_outcome_unknown}
    end
  end

  defp validate_checkpoint(
         %{"cwd" => cwd, "root" => root, "branch" => branch, "baseCommit" => base},
         opts
       ) do
    with true <- sha?(base),
         :ok <- validate_context(root, cwd, branch, opts),
         {:ok, _} <- git(cwd, ["merge-base", "--is-ancestor", base, "HEAD"], opts) do
      :ok
    else
      _ -> {:error, :invalid_checkpoint}
    end
  end

  defp validate_checkpoint(_, _), do: {:error, :invalid_checkpoint}

  defp valid_snapshot?(checkpoint, snapshot) when is_map(snapshot) do
    snapshot["changed"] == true and snapshot["baseCommit"] == checkpoint["baseCommit"] and
      sha?(snapshot["headCommit"]) and sha?(snapshot["tree"])
  end

  defp valid_snapshot?(_, _), do: false

  defp validate_snapshot(checkpoint, snapshot, opts) do
    with :ok <- validate_checkpoint(checkpoint, opts),
         true <- valid_snapshot?(checkpoint, snapshot),
         {:ok, head} <- git(checkpoint["cwd"], ["rev-parse", "HEAD"], opts),
         true <- String.trim(head) == snapshot["headCommit"],
         {:ok, tree} <- git(checkpoint["cwd"], ["write-tree"], opts),
         true <- String.trim(tree) == snapshot["tree"],
         {:ok, base_tree} <-
           git(checkpoint["cwd"], ["rev-parse", checkpoint["baseCommit"] <> "^{tree}"], opts),
         true <- String.trim(base_tree) != snapshot["tree"],
         :ok <- clean_index_worktree(checkpoint["cwd"], opts) do
      :ok
    else
      _ -> {:error, :changed_after_review}
    end
  end

  defp clean_index_worktree(cwd, opts) do
    with {:ok, flags} <-
           git(
             cwd,
             ["ls-files", "-v", "-z"],
             Keyword.put(opts, :max_output_bytes, 8 * 1024 * 1024)
           ),
         true <-
           Enum.all?(String.split(flags, "\0", trim: true), fn
             <<tag, _::binary>> -> tag != ?S and tag not in ?a..?z
             _ -> false
           end),
         {:ok, _} <-
           git(cwd, ["diff", "--quiet", "--no-ext-diff", "--ignore-submodules=none", "--"], opts),
         {:ok, untracked} <- git(cwd, ["ls-files", "--others", "--exclude-standard", "-z"], opts),
         true <- untracked == "" do
      :ok
    else
      _ -> {:error, :changed_after_review}
    end
  end

  def publish(checkpoint, commit_sha, config, title, body, opts \\ []) do
    with {:ok, normalized} <- normalize(config) do
      case normalized do
        %{publish: publish} when not is_nil(publish) ->
          with :ok <- publication_ready(checkpoint, commit_sha, opts),
               true <-
                 text?(title, 4096) and is_binary(body) and byte_size(body) <= @diff_limit and
                   String.valid?(body) and not String.contains?(body, "\0") do
            dispatch_publication(checkpoint, commit_sha, publish, title, body, opts)
          else
            false -> {:error, :invalid_publication_text}
            {:error, _} = error -> error
          end

        _ ->
          {:ok, %{"published" => false}}
      end
    end
  end

  defp dispatch_publication(checkpoint, sha, publish, title, body, opts) do
    # Pin the refspec to the reviewed commit, never a moving local branch.
    refspec = sha <> ":refs/heads/" <> checkpoint["branch"]

    with {:ok, _} <-
           git(
             checkpoint["cwd"],
             [
               "push",
               "--no-verify",
               "--porcelain",
               "--no-follow-tags",
               "--no-mirror",
               "--recurse-submodules=no",
               publish.remote,
               refspec
             ],
             opts
           ),
         :ok <- remote_commit(checkpoint, sha, publish, opts),
         {:ok, url} <- publish_pr(checkpoint, sha, publish, title, body, opts) do
      {:ok, %{"published" => true, "prUrl" => url}}
    else
      _ -> {:error, :publication_outcome_unknown}
    end
  end

  def reconcile_publication(checkpoint, commit_sha, config, opts \\ []) do
    with {:ok, %{publish: publish}} when not is_nil(publish) <- normalize(config),
         :ok <- validate_checkpoint(checkpoint, opts),
         true <- sha?(commit_sha),
         :ok <- remote_commit(checkpoint, commit_sha, publish, opts),
         {:ok, url} <- existing_pr(checkpoint, commit_sha, publish, opts),
         true <- publish.mode == :branch or is_binary(url) do
      {:ok, %{"published" => true, "prUrl" => url}}
    else
      _ -> {:error, :publication_outcome_unknown}
    end
  end

  defp publication_ready(checkpoint, sha, opts) do
    with :ok <- validate_checkpoint(checkpoint, opts),
         true <- sha?(sha),
         {:ok, head} <- git(checkpoint["cwd"], ["rev-parse", "HEAD"], opts),
         true <- String.trim(head) == sha do
      :ok
    else
      _ -> {:error, :invalid_publication_commit}
    end
  end

  defp remote_commit(checkpoint, sha, publish, opts) do
    ref = "refs/heads/" <> checkpoint["branch"]

    with {:ok, output} <-
           git(checkpoint["cwd"], ["remote", "get-url", "--push", "--all", publish.remote], opts),
         urls = String.split(output, "\n", trim: true),
         true <- urls != [] do
      Enum.reduce_while(urls, :ok, fn url, :ok ->
        case git(checkpoint["cwd"], ["ls-remote", "--refs", "--", url, ref], opts) do
          {:ok, observed} ->
            if String.split(observed) == [sha, ref],
              do: {:cont, :ok},
              else: {:halt, {:error, :publication_outcome_unknown}}

          _ ->
            {:halt, {:error, :publication_outcome_unknown}}
        end
      end)
    else
      _ -> {:error, :publication_outcome_unknown}
    end
  end

  defp publish_pr(_checkpoint, _sha, %{mode: :branch}, _title, _body, _opts), do: {:ok, nil}

  defp publish_pr(checkpoint, sha, publish, title, body, opts) do
    case existing_pr(checkpoint, sha, publish, opts) do
      {:ok, nil} ->
        args = [
          "pr",
          "create",
          "--repo",
          publish.repository,
          "--head",
          checkpoint["branch"],
          "--base",
          publish.base,
          "--title",
          title,
          "--body",
          body
        ]

        args = if publish.draft, do: args ++ ["--draft"], else: args

        with {:ok, output} <- command("gh", args, Keyword.put(opts, :cwd, checkpoint["cwd"])),
             url = String.trim(output),
             true <- pr_url?(url, publish.repository),
             {:ok, ^url} <- existing_pr(checkpoint, sha, publish, opts) do
          {:ok, url}
        else
          _ -> {:error, :publication_outcome_unknown}
        end

      result ->
        result
    end
  end

  defp existing_pr(_checkpoint, _sha, %{mode: :branch}, _opts), do: {:ok, nil}

  defp existing_pr(checkpoint, sha, publish, opts) do
    args = [
      "pr",
      "list",
      "--repo",
      publish.repository,
      "--head",
      checkpoint["branch"],
      "--base",
      publish.base,
      "--state",
      "all",
      "--limit",
      "100",
      "--json",
      "url,headRefName,baseRefName,headRefOid,isCrossRepository"
    ]

    with {:ok, output} <- command("gh", args, Keyword.put(opts, :cwd, checkpoint["cwd"])),
         {:ok, entries} when is_list(entries) <- Jason.decode(output) do
      case entries do
        [] ->
          {:ok, nil}

        [
          %{
            "url" => url,
            "headRefName" => branch,
            "baseRefName" => base,
            "headRefOid" => ^sha,
            "isCrossRepository" => false
          }
        ] ->
          if branch == checkpoint["branch"] and base == publish.base and
               pr_url?(url, publish.repository),
             do: {:ok, url},
             else: {:error, :publication_outcome_unknown}

        _ ->
          {:error, :publication_outcome_unknown}
      end
    else
      _ -> {:error, :publication_outcome_unknown}
    end
  end

  defp pr_url?(url, repository) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path,
        port: 443
      }
      when is_binary(host) and host != "" and is_binary(path) ->
        Regex.match?(~r/\A\/#{Regex.escape(repository)}\/pull\/[1-9][0-9]*\z/, path)

      _ ->
        false
    end
  end

  defp pr_url?(_, _), do: false

  defp sha?(value),
    do: is_binary(value) and Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, value)

  @doc false
  def git(cwd, args, opts \\ []) do
    command("git", @git_options ++ ["-C", cwd | args], opts)
  end

  @doc false
  def command(program, args, opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:max_output_bytes, @diff_limit)
      |> Keyword.put_new(:timeout_ms, 30_000)

    case Keyword.get(opts, :runner) do
      runner when is_function(runner, 3) -> runner.(program, args, opts)
      nil -> supervised_command(program, args, opts)
    end
  rescue
    _ -> {:error, :command_failed}
  catch
    :exit, _ -> {:error, :command_failed}
  end

  defp supervised_command(program, args, opts) do
    timeout = min(max(Keyword.fetch!(opts, :timeout_ms), 1), 120_000)
    supervisor = Keyword.get(opts, :task_supervisor, LemonAutomation.TaskSupervisor)
    owner = self()

    with {:ok, task} <-
           LemonCore.TaskSupervisor.async_nolink(supervisor, fn ->
             monitor = Process.monitor(owner)

             try do
               run_port(program, args, opts, timeout, monitor)
             after
               Process.demonitor(monitor, [:flush])
             end
           end) do
      case Task.yield(task, timeout + 6000) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, :command_timeout}
      end
    end
  end

  defp run_port(program, args, opts, timeout, monitor) do
    case System.find_executable(program) do
      nil ->
        {:error, :command_unavailable}

      executable ->
        # Ignore inherited Git plumbing overrides but retain operator credentials
        # and configured identity. No identity is manufactured by this workflow.
        identity =
          ~w(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE)

        removed =
          System.get_env()
          |> Map.keys()
          |> Enum.filter(&(String.starts_with?(&1, "GIT_") and &1 not in identity))

        env =
          Enum.map(removed, &{String.to_charlist(&1), false}) ++
            [
              {~c"GIT_TERMINAL_PROMPT", ~c"0"},
              {~c"GCM_INTERACTIVE", ~c"Never"},
              {~c"GH_PROMPT_DISABLED", ~c"1"},
              {~c"LC_ALL", ~c"C"}
            ]

        port_opts = [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          args: args,
          env: env
        ]

        port_opts = if opts[:cwd], do: [{:cd, opts[:cwd]} | port_opts], else: port_opts
        port = Port.open({:spawn_executable, executable}, port_opts)

        try do
          collect(
            port,
            System.monotonic_time(:millisecond) + timeout,
            Keyword.fetch!(opts, :max_output_bytes),
            [],
            0,
            monitor
          )
        after
          terminate_port(port)
        end
    end
  rescue
    _ -> {:error, :command_failed}
  end

  defp collect(port, deadline, limit, chunks, size, monitor) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        if size + byte_size(data) > limit do
          {:error, :output_too_large}
        else
          collect(port, deadline, limit, [data | chunks], size + byte_size(data), monitor)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, _}} ->
        {:error, :git_failed}

      {:DOWN, ^monitor, :process, _owner, _reason} ->
        {:error, :command_cancelled}
    after
      remaining -> {:error, :command_timeout}
    end
  end

  # Keep the supervised command task alive for bounded group termination and
  # consume the exit event. The caller monitor also handles abrupt worker death.
  defp terminate_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        ProcessGroup.terminate(pid, [])
        reap(port, System.monotonic_time(:millisecond) + 1000)
        if Port.info(port), do: Port.close(port)

      nil ->
        :ok
    end
  rescue
    _ -> if Port.info(port), do: Port.close(port)
  end

  defp reap(port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, {:data, _}} -> reap(port, deadline)
    after
      remaining -> :ok
    end
  end
end
