defmodule LemonAutomation.KanbanGitWorkflow do
  @moduledoc """
  Explicitly opted-in, isolated Git review/commit/publication operations.

  Checkpoints and snapshots have string keys and may be persisted as JSON. Pass
  `checkpoint: checkpoint` to `prepare/4` on recovery; a fresh prepare records the
  current HEAD, never an inferred historical base. Snapshots stage ignored-aware
  changes and review the entire resulting tree against the recorded base. Binary,
  submodule and oversized diffs fail closed. Commits bypass hooks and signing,
  use the operator's global (else the workspace repository's configured) Git
  identity, and update only the owned branch with CAS.

  All of this happens in the board's controller-owned repository
  (`LemonAutomation.KanbanGitSandbox`), never in the workspace repository:
  every worktree command runs through `controller_git/3` with `GIT_DIR` set to
  the worktree's administrative directory inside that repository and
  `GIT_WORK_TREE` set to the worktree, after verifying the repository's
  Lemon-written configuration. `git/3` (outside controller repositories) is
  used only for repository discovery and `resolve_destinations/3`.

  Publication is disabled unless explicitly configured. It pushes only to the
  destinations an operator granted (`:destinations`, the push URLs resolved
  when the grant was confirmed), as explicit `git push -- <url> <sha>:<ref>`
  arguments; remote names and URL rewriting are never consulted. Persist
  publish_pending before calling publish; after any dispatched publication
  failure, reconcile instead of retrying. Reconciliation is read-only and
  requires exact remote SHA and (for PRs) repository, head, base and head SHA
  agreement.

  Side-effecting and network commands (`commit-tree`, `update-ref`, every
  `push`, every `ls-remote`, every `gh` call) are built once as
  `{executable, args}`; that exact value is passed to the required `:authorize`
  callback (`({exe, args}) -> :ok | {:error, _}`) and then run. Publication and
  reconciliation authorize their whole command set before any network access.
  A missing callback or a denial returns `{:error, :commit_not_authorized}` or
  `{:error, :publication_not_authorized}` and runs nothing further.

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
         %{cwd: cwd, worktree: %{root: root, path: path, branch: branch, git_dir: git_dir}}
         when is_binary(cwd) and is_binary(root) and is_binary(path) and is_binary(branch) and
                is_binary(git_dir) <-
           workspace,
         true <- is_map(task),
         id when is_binary(id) <- Map.get(task, :id, Map.get(task, "id")),
         true <- cwd == path and branch == LemonAutomation.KanbanWorktree.branch_for(task),
         {:ok, ^path} <- LemonAutomation.KanbanWorktree.path_for(task),
         {:ok, ^git_dir} <- LemonAutomation.KanbanWorktree.controller_path(task),
         :ok <- validate_context(git_dir, path, branch, opts),
         base = %{"gitDir" => git_dir, "cwd" => path, "branch" => branch},
         {:ok, head} <- worktree_git(base, ["rev-parse", "HEAD"], opts),
         {:ok, checkpoint} <- checkpoint(root, git_dir, path, branch, String.trim(head), opts) do
      {:ok, checkpoint}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_worktree}
    end
  end

  defp checkpoint(root, git_dir, path, branch, head, opts) do
    current = %{
      "baseCommit" => head,
      "branch" => branch,
      "cwd" => path,
      "root" => root,
      "gitDir" => git_dir
    }

    case Keyword.get(opts, :checkpoint) do
      nil ->
        {:ok, current}

      %{
        "baseCommit" => base,
        "branch" => ^branch,
        "cwd" => ^path,
        "root" => ^root,
        "gitDir" => ^git_dir
      } = saved ->
        with true <- sha?(base),
             {:ok, _} <- worktree_git(saved, ["merge-base", "--is-ancestor", base, head], opts) do
          {:ok, saved}
        else
          _ -> {:error, :invalid_checkpoint}
        end

      _ ->
        {:error, :invalid_checkpoint}
    end
  end

  @doc false
  # The worktree must be registered in the controller repository `git_dir`
  # (from the repository's own records) with `branch` checked out.
  def validate_context(git_dir, path, branch, opts \\ []) do
    with true <- clean_path?(git_dir) and clean_path?(path) and ref_name?(branch),
         {:ok, repo} <- LemonAutomation.KanbanGitSandbox.worktree_repo(git_dir, path, branch),
         {:ok, actual_branch} <- controller_git(repo, ["symbolic-ref", "--quiet", "HEAD"], opts),
         true <- String.trim(actual_branch) == "refs/heads/#{branch}",
         {:ok, entries} <-
           controller_git(
             %{repo | git_dir: git_dir, work_tree: nil},
             ["worktree", "list", "--porcelain", "-z"],
             opts
           ),
         true <- registered_worktree?(entries, path, branch) do
      :ok
    else
      {:error, :controller_config_changed} = error -> error
      {:error, :worktree_metadata_changed} = error -> error
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

  # Staging reads the worktree's files as data into the controller
  # repository's index for this worktree.
  def snapshot(checkpoint, opts \\ []) do
    with :ok <- validate_checkpoint(checkpoint, opts),
         {:ok, _} <- worktree_git(checkpoint, ["add", "-A", "--", "."], opts),
         {:ok, head} <- worktree_git(checkpoint, ["rev-parse", "HEAD"], opts),
         {:ok, tree} <- worktree_git(checkpoint, ["write-tree"], opts),
         {:ok, base_tree} <-
           worktree_git(checkpoint, ["rev-parse", checkpoint["baseCommit"] <> "^{tree}"], opts),
         {:ok, diff} <- review_diff(checkpoint, checkpoint["baseCommit"], String.trim(tree), opts),
         :ok <- clean_index_worktree(checkpoint, opts) do
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

  defp review_diff(checkpoint, base, tree, opts) do
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
           worktree_git(
             checkpoint,
             ["diff", "--numstat", "--no-ext-diff", "--no-textconv", base, tree, "--"],
             opts
           ),
         false <- Regex.match?(~r/^\-\t\-\t/m, stat),
         {:ok, diff} <-
           worktree_git(checkpoint, args, Keyword.put(opts, :max_output_bytes, @diff_limit)),
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
         {:ok, head_tree} <- worktree_git(checkpoint, ["rev-parse", "HEAD^{tree}"], opts) do
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
    commit_tree =
      {"git", ["commit-tree", snapshot["tree"], "-p", snapshot["headCommit"], "-m", title]}

    with :ok <- authorize([commit_tree], opts, :commit_not_authorized),
         {:ok, commit} <- run(commit_tree, checkpoint, commit_identity(checkpoint, opts)),
         commit = String.trim(commit),
         true <- sha?(commit),
         :ok <- validate_snapshot(checkpoint, snapshot, opts),
         update_ref =
           {"git",
            ["update-ref", "refs/heads/" <> checkpoint["branch"], commit, snapshot["headCommit"]]},
         :ok <- authorize([update_ref], opts, :commit_not_authorized) do
      case run(update_ref, checkpoint, opts) do
        {:ok, _} -> {:ok, commit}
        _ -> {:error, :commit_outcome_unknown}
      end
    else
      false -> {:error, :git_failed}
      {:error, _} = error -> error
    end
  end

  # The workspace repository's configured author identity, read as data
  # (`git config --get`, which runs nothing); the operator's global identity
  # still takes precedence in the sandbox.
  defp commit_identity(%{"root" => root}, opts) when is_binary(root) do
    identity =
      for key <- ["user.name", "user.email"],
          {:ok, value} <- [git(root, ["config", "--get", key], opts)],
          value = String.trim(value),
          value != "" and String.valid?(value),
          do: {key, value}

    Keyword.put(opts, :identity, identity)
  end

  defp commit_identity(_checkpoint, opts), do: opts

  # Every side-effecting controller command is built exactly once as
  # `{executable, args}` and that same value is authorized (`:authorize`
  # option, required) and then run. A missing authorizer refuses.
  defp authorize(commands, opts, denial) do
    case Keyword.get(opts, :authorize) do
      fun when is_function(fun, 1) ->
        if Enum.all?(commands, &(fun.(&1) == :ok)), do: :ok, else: {:error, denial}

      _ ->
        {:error, denial}
    end
  end

  # Worktree commands run in the controller repository with this worktree's
  # administrative directory; network commands run against the controller
  # repository itself and alone receive the operator's credential helpers.
  defp run({"git", [sub | _] = args}, checkpoint, opts) when sub in ["push", "ls-remote"] do
    with {:ok, repo} <- controller_repo(checkpoint),
         do: controller_git(repo, args, Keyword.put(opts, :publication, true))
  end

  defp run({"git", args}, checkpoint, opts), do: worktree_git(checkpoint, args, opts)
  defp run({"gh", args}, _checkpoint, opts), do: gh(args, opts)

  defp controller_repo(%{"gitDir" => git_dir}) when is_binary(git_dir),
    do: {:ok, %{git_dir: git_dir, common_dir: git_dir, work_tree: nil}}

  defp controller_repo(_checkpoint), do: {:error, :invalid_checkpoint}

  # A command in the checkpoint's worktree: `GIT_DIR` is the worktree's
  # administrative directory inside the controller repository, found from the
  # repository's own records and re-verified before the command, and
  # `GIT_WORK_TREE` the worktree.
  defp worktree_git(%{"gitDir" => git_dir, "cwd" => cwd, "branch" => branch}, args, opts) do
    with {:ok, repo} <- LemonAutomation.KanbanGitSandbox.worktree_repo(git_dir, cwd, branch),
         do: controller_git(repo, args, opts)
  end

  defp worktree_git(_checkpoint, _args, _opts), do: {:error, :invalid_checkpoint}

  def reconcile_commit(checkpoint, snapshot, opts \\ []) do
    with :ok <- validate_checkpoint(checkpoint, opts),
         true <- valid_snapshot?(checkpoint, snapshot),
         {:ok, head} <- worktree_git(checkpoint, ["rev-parse", "HEAD"], opts),
         {:ok, tree} <- worktree_git(checkpoint, ["rev-parse", "HEAD^{tree}"], opts),
         true <- String.trim(tree) == snapshot["tree"],
         :ok <- commit_parent(checkpoint, String.trim(head), snapshot["headCommit"], opts) do
      {:ok, String.trim(head)}
    else
      _ -> {:error, :commit_outcome_unknown}
    end
  end

  defp commit_parent(_checkpoint, head, head, _opts), do: :ok

  defp commit_parent(checkpoint, head, parent, opts) do
    case worktree_git(checkpoint, ["rev-list", "--parents", "-n", "1", head], opts) do
      {:ok, result} ->
        if String.split(result) == [head, parent],
          do: :ok,
          else: {:error, :commit_outcome_unknown}

      _ ->
        {:error, :commit_outcome_unknown}
    end
  end

  defp validate_checkpoint(
         %{"cwd" => cwd, "gitDir" => git_dir, "branch" => branch, "baseCommit" => base} =
           checkpoint,
         opts
       ) do
    with true <- sha?(base),
         :ok <- validate_context(git_dir, cwd, branch, opts),
         {:ok, _} <- worktree_git(checkpoint, ["merge-base", "--is-ancestor", base, "HEAD"], opts) do
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
         {:ok, head} <- worktree_git(checkpoint, ["rev-parse", "HEAD"], opts),
         true <- String.trim(head) == snapshot["headCommit"],
         {:ok, tree} <- worktree_git(checkpoint, ["write-tree"], opts),
         true <- String.trim(tree) == snapshot["tree"],
         {:ok, base_tree} <-
           worktree_git(checkpoint, ["rev-parse", checkpoint["baseCommit"] <> "^{tree}"], opts),
         true <- String.trim(base_tree) != snapshot["tree"],
         :ok <- clean_index_worktree(checkpoint, opts) do
      :ok
    else
      _ -> {:error, :changed_after_review}
    end
  end

  defp clean_index_worktree(checkpoint, opts) do
    with {:ok, flags} <-
           worktree_git(
             checkpoint,
             ["ls-files", "-v", "-z"],
             Keyword.put(opts, :max_output_bytes, 8 * 1024 * 1024)
           ),
         true <-
           Enum.all?(String.split(flags, "\0", trim: true), fn
             <<tag, _::binary>> -> tag != ?S and tag not in ?a..?z
             _ -> false
           end),
         {:ok, _} <-
           worktree_git(
             checkpoint,
             ["diff", "--quiet", "--no-ext-diff", "--ignore-submodules=none", "--"],
             opts
           ),
         {:ok, untracked} <-
           worktree_git(checkpoint, ["ls-files", "--others", "--exclude-standard", "-z"], opts),
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

  # The full command set is built from the operator-granted destinations
  # (`:destinations`, pinned push URLs) and authorized before anything touches
  # the network: every push, every ls-remote verification and every `gh` call
  # with all of its arguments. No remote name or URL rewriting is consulted.
  defp dispatch_publication(checkpoint, sha, publish, title, body, opts) do
    case publication_plan(checkpoint, sha, publish, {title, body}, opts) do
      {:ok, plan} ->
        with :ok <- push_all(plan, checkpoint, opts),
             :ok <- remote_commit(plan, checkpoint, sha, opts),
             {:ok, url} <- publish_pr(plan, checkpoint, sha, publish, opts) do
          {:ok, %{"published" => true, "prUrl" => url}}
        else
          _ -> {:error, :publication_outcome_unknown}
        end

      {:error, _} = error ->
        error
    end
  end

  defp push_all(plan, checkpoint, opts) do
    Enum.reduce_while(plan.push, :ok, fn command, :ok ->
      case run(command, checkpoint, opts) do
        {:ok, _} -> {:cont, :ok}
        _ -> {:halt, {:error, :publication_outcome_unknown}}
      end
    end)
  end

  @doc """
  Queries (never mutates) whether a dispatched publication landed at the
  pinned destinations. Its commands (`ls-remote`, `gh pr list`) are authorized
  through `:authorize` before any of them runs; a denial returns
  `{:error, :publication_not_authorized}` without network access.
  """
  def reconcile_publication(checkpoint, commit_sha, config, opts \\ []) do
    with {:ok, %{publish: publish}} when not is_nil(publish) <- normalize(config),
         :ok <- validate_checkpoint(checkpoint, opts),
         true <- sha?(commit_sha),
         {:ok, plan} <- publication_plan(checkpoint, commit_sha, publish, nil, opts),
         :ok <- remote_commit(plan, checkpoint, commit_sha, opts),
         {:ok, url} <- existing_pr(plan, checkpoint, commit_sha, publish, opts),
         true <- publish.mode == :branch or is_binary(url) do
      {:ok, %{"published" => true, "prUrl" => url}}
    else
      {:error, :publication_not_authorized} = denied -> denied
      _ -> {:error, :publication_outcome_unknown}
    end
  end

  defp publication_plan(checkpoint, sha, publish, text, opts) do
    ref = "refs/heads/" <> checkpoint["branch"]

    with [_ | _] = urls <- Keyword.get(opts, :destinations),
         true <- Enum.all?(urls, &destination_url?/1) do
      plan = %{
        # Pin the refspec to the reviewed commit, never a moving local branch,
        # and the destination to the granted URL, never a remote name.
        push:
          Enum.map(
            urls,
            &{"git",
             [
               "push",
               "--no-verify",
               "--porcelain",
               "--no-follow-tags",
               "--no-mirror",
               "--recurse-submodules=no",
               "--",
               &1,
               sha <> ":" <> ref
             ]}
          ),
        ls_remote: Enum.map(urls, &{"git", ["ls-remote", "--refs", "--", &1, ref]}),
        pr_list: pr_list(checkpoint, publish),
        pr_create: pr_create(checkpoint, publish, text)
      }

      commands =
        if(text, do: plan.push, else: []) ++
          plan.ls_remote ++ Enum.reject([plan.pr_list, plan.pr_create], &is_nil/1)

      with :ok <- authorize(commands, opts, :publication_not_authorized), do: {:ok, plan}
    else
      _ -> {:error, :publication_not_authorized}
    end
  end

  @doc """
  Resolves the publication destinations an operator grant would bind: the
  workspace repository's push URL(s) for the configured remote (after its URL
  rewriting), plus the PR repository and base. Called only when an operator
  previews or confirms a grant; publication itself never re-resolves them.
  """
  def resolve_destinations(workspace, settings, opts \\ []) do
    with {:ok, %{publish: publish}} when not is_nil(publish) <-
           normalize(%{"publish" => settings}),
         {:ok, output} <-
           git(workspace, ["remote", "get-url", "--push", "--all", "--", publish.remote], opts),
         [_ | _] = urls <- String.split(output, "\n", trim: true),
         true <- Enum.all?(urls, &destination_url?/1) do
      {:ok, %{"push" => urls, "repository" => publish.repository, "base" => publish.base}}
    else
      _ -> {:error, :publication_destination_unavailable}
    end
  end

  # A push URL usable as one literal argument: no option or transport-helper
  # syntax, no embedded credentials, no control characters or whitespace.
  defp destination_url?(url) do
    is_binary(url) and byte_size(url) in 1..2048 and String.valid?(url) and
      not String.starts_with?(url, "-") and
      not Regex.match?(~r/[\x00-\x20\x7f]/, url) and
      not Regex.match?(~r/\A[A-Za-z][A-Za-z0-9+.-]*::/, url) and
      no_credentials?(url)
  end

  defp no_credentials?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, userinfo: info} when scheme in ["http", "https"] -> is_nil(info)
      _ -> true
    end
  end

  defp pr_list(_checkpoint, %{mode: :branch}), do: nil

  defp pr_list(checkpoint, publish) do
    {"gh",
     [
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
     ]}
  end

  defp pr_create(_checkpoint, %{mode: :branch}, _text), do: nil
  defp pr_create(_checkpoint, _publish, nil), do: nil

  defp pr_create(checkpoint, publish, {title, body}) do
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

    {"gh", if(publish.draft, do: args ++ ["--draft"], else: args)}
  end

  defp publication_ready(checkpoint, sha, opts) do
    with :ok <- validate_checkpoint(checkpoint, opts),
         true <- sha?(sha),
         {:ok, head} <- worktree_git(checkpoint, ["rev-parse", "HEAD"], opts),
         true <- String.trim(head) == sha do
      :ok
    else
      _ -> {:error, :invalid_publication_commit}
    end
  end

  defp remote_commit(plan, checkpoint, sha, opts) do
    ref = "refs/heads/" <> checkpoint["branch"]

    Enum.reduce_while(plan.ls_remote, :ok, fn command, :ok ->
      case run(command, checkpoint, opts) do
        {:ok, observed} ->
          if String.split(observed) == [sha, ref],
            do: {:cont, :ok},
            else: {:halt, {:error, :publication_outcome_unknown}}

        _ ->
          {:halt, {:error, :publication_outcome_unknown}}
      end
    end)
  end

  defp publish_pr(%{pr_create: nil}, _checkpoint, _sha, _publish, _opts), do: {:ok, nil}

  defp publish_pr(plan, checkpoint, sha, publish, opts) do
    case existing_pr(plan, checkpoint, sha, publish, opts) do
      {:ok, nil} ->
        with {:ok, output} <- run(plan.pr_create, checkpoint, opts),
             url = String.trim(output),
             true <- pr_url?(url, publish.repository),
             {:ok, ^url} <- existing_pr(plan, checkpoint, sha, publish, opts) do
          {:ok, url}
        else
          _ -> {:error, :publication_outcome_unknown}
        end

      result ->
        result
    end
  end

  defp existing_pr(%{pr_list: nil}, _checkpoint, _sha, _publish, _opts), do: {:ok, nil}

  defp existing_pr(plan, checkpoint, sha, publish, opts) do
    with {:ok, output} <- run(plan.pr_list, checkpoint, opts),
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

  @doc """
  Runs `git -C cwd args` outside a controller repository in the sanitized
  environment (`LemonAutomation.KanbanGitSandbox.env/1`). Controller code
  uses it only for commands that run no configured program (repository
  discovery and push-URL resolution).
  """
  def git(cwd, args, opts \\ []) do
    with {:ok, env} <- LemonAutomation.KanbanGitSandbox.env(opts) do
      command("git", ["-C", cwd | args], Keyword.put(opts, :env, env))
    end
  end

  @doc """
  Runs `git args` against a controller repository (`GIT_DIR`, and
  `GIT_WORK_TREE` for a worktree), after verifying the repository's
  Lemon-written configuration (`KanbanGitSandbox.controller_env/2`).
  """
  def controller_git(repo, args, opts \\ []) do
    with {:ok, env} <- LemonAutomation.KanbanGitSandbox.controller_env(repo, opts) do
      cwd = Map.get(repo, :work_tree) || Map.fetch!(repo, :common_dir)
      command("git", ["-C", cwd | args], Keyword.put(opts, :env, env))
    end
  end

  @doc "Runs `gh` sanitized, from an empty Lemon-owned directory."
  def gh(args, opts \\ []) do
    with {:ok, env, neutral} <- LemonAutomation.KanbanGitSandbox.gh_env(opts) do
      command("gh", args, opts |> Keyword.put(:env, env) |> Keyword.put(:cwd, neutral))
    end
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

  @doc false
  # Infrastructure reads for the sandbox itself: always a real supervised port
  # with the given environment (never the test runner seam).
  def raw_command(program, args, env, opts) do
    opts =
      opts
      |> Keyword.take([:task_supervisor, :cwd])
      |> Keyword.merge(env: env, max_output_bytes: 1024 * 1024, timeout_ms: 10_000)

    supervised_command(program, args, opts)
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
    case {System.find_executable(program), Keyword.get(opts, :env)} do
      {nil, _env} ->
        {:error, :command_unavailable}

      {_executable, env} when not is_list(env) ->
        # Never run a controller command outside the sanitized environment.
        {:error, :sandbox_unavailable}

      {executable, env} ->
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
