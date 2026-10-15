defmodule CodingAgent.Tools.Bash.GitGuard do
  @moduledoc "Default-on checks for destructive literal Git commands before shell launch."

  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Bash.ShellSegments

  @global_values ~w(-c --config-env --git-dir --work-tree --namespace --super-prefix)

  def check(command, cwd, opts) do
    config = Keyword.get(opts, :bash_config, %{})

    if Map.get(config, :git_guard, Map.get(config, "git_guard", true)) do
      segments = ShellSegments.extract(command)

      uncertain_cwd =
        Enum.any?(segments, &(List.first(&1.argv) in ~w(cd pushd popd))) or
          Regex.match?(~r/(?:^|\s)(?:sudo|env)\s/, command)

      git_env =
        String.contains?(command, "GIT_") or
          Enum.any?(Keyword.get(opts, :command_env, %{}), fn {key, _} ->
            String.starts_with?(key, "GIT_")
          end) or
          Enum.any?(~w(GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR), &(System.get_env(&1) != nil))

      check_segments(segments, cwd, not uncertain_cwd and not git_env)
    else
      :ok
    end
  end

  defp check_segments(segments, cwd, allow_isolation) do
    Enum.reduce_while(segments, :ok, fn segment, :ok ->
      case check_segment(segment.argv, cwd, allow_isolation) do
        nil ->
          {:cont, :ok}

        {form, reason} ->
          {:halt,
           {:blocked,
            "Blocked #{form}: #{reason}. " <>
              "Disable with [runtime.tools.bash] git_guard = false."}}
      end
    end)
  end

  defp check_segment([program | args], cwd, allow_isolation) do
    if Path.basename(program) == "git" do
      {args, effective_cwd, redirected} = global_options(args, cwd, false)
      reason = destructive(args)

      if not is_nil(reason) and allow_isolation and not redirected and
           isolated_worktree?(effective_cwd), do: nil, else: reason
    end
  end

  defp check_segment([], _cwd, _allow_isolation), do: nil

  defp global_options(["-C", path | rest], cwd, redirected),
    do: global_options(rest, Path.expand(path, cwd), redirected)

  defp global_options(["-C" <> path | rest], cwd, redirected) when path != "",
    do: global_options(rest, Path.expand(path, cwd), redirected)

  defp global_options([option, value | rest], cwd, redirected) when option in @global_values,
    do:
      global_options(
        rest,
        cwd,
        redirected or option in ["--git-dir", "--work-tree", "--config-env"] or
          (option == "-c" and String.starts_with?(String.downcase(value), "core.worktree="))
      )

  defp global_options(["--" | rest], cwd, redirected), do: {rest, cwd, redirected}

  defp global_options(["-" <> _ = option | rest], cwd, redirected),
    do:
      global_options(
        rest,
        cwd,
        redirected or
          String.starts_with?(
            String.downcase(option),
            ["--git-dir=", "--work-tree=", "--config-env=", "-ccore.worktree="]
          )
      )

  defp global_options(args, cwd, redirected), do: {args, cwd, redirected}

  defp destructive(["reset" | args]) do
    if "--hard" in flags(args), do: {"git reset --hard", "discards uncommitted tracked changes"}
  end

  defp destructive(["checkout" | args]) do
    if forced?(args) or "." in args or path_checkout?(args),
      do: {"git checkout of worktree paths/--force", "can overwrite uncommitted worktree changes"}
  end

  defp destructive(["restore" | args]) do
    flags = flags(args)

    if not ("--staged" in flags or short?(flags, "S")) or
         "--worktree" in flags or short?(flags, "W"),
       do: {"git restore of the worktree", "discards uncommitted worktree changes"}
  end

  defp destructive(["clean" | args]) do
    if forced?(args), do: {"git clean --force", "permanently deletes untracked files"}
  end

  defp destructive(["stash", action | _]) when action in ["drop", "clear"],
    do: {"git stash #{action}", "deletes saved uncommitted work"}

  defp destructive(["push" | args]) do
    flags = flags(args)

    lease =
      Enum.any?(
        flags,
        &(&1 == "--force-with-lease" or String.starts_with?(&1, "--force-with-lease="))
      )

    if not lease and (forced?(args) or "--force-if-includes" in flags),
      do: {"git push --force", "can overwrite shared history without a lease"}
  end

  defp destructive(["branch" | args]) do
    if short?(flags(args), "D"),
      do: {"git branch -D", "deletes a branch without checking merged work"}
  end

  defp destructive(["worktree", "remove" | args]) do
    if forced?(args),
      do: {"git worktree remove --force", "deletes a worktree even with uncommitted changes"}
  end

  defp destructive(["switch" | args]) do
    if forced?(args) or "--discard-changes" in flags(args),
      do: {"git switch --discard-changes/--force", "discards uncommitted changes"}
  end

  defp destructive(_args), do: nil

  defp path_checkout?(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {_, ["--", _ | _]} -> true
      _ -> false
    end
  end

  defp flags(args), do: Enum.take_while(args, &(&1 != "--"))
  defp forced?(args), do: "--force" in flags(args) or short?(flags(args), "f")

  defp short?(args, flag),
    do:
      Enum.any?(
        args,
        &(String.starts_with?(&1, "-") and
            not String.starts_with?(&1, "--") and String.contains?(&1, flag))
      )

  # The task tool records the prepared workspace before starting the child.
  # Require that record plus Git's bidirectional worktree link, never just a
  # suggestive directory/branch name. No Git process is spawned for this check.
  defp isolated_worktree?(cwd) do
    cwd = Path.expand(cwd)

    case File.lstat(cwd) do
      {:ok, %{type: :directory}} -> find_worktree(cwd)
      _ -> false
    end
  end

  defp find_worktree(root) do
    cond do
      File.regular?(Path.join(root, ".git")) -> recorded_worktree?(root)
      File.exists?(Path.join(root, ".git")) -> false
      Path.dirname(root) == root -> false
      true -> isolated_worktree?(Path.dirname(root))
    end
  end

  defp recorded_worktree?(root) do
    id = Path.basename(root)

    with "lemon-task-worktrees" <- Path.basename(Path.dirname(root)),
         {:ok, %{workspace: %{worktree_path: ^root}}} <- task_record(id),
         {:ok, "gitdir: " <> gitdir} <- File.read(Path.join(root, ".git")),
         gitdir = Path.expand(String.trim(gitdir), root),
         {:ok, common} <- File.read(Path.join(gitdir, "commondir")),
         common = Path.expand(String.trim(common), gitdir),
         true <- root == Path.join([common, "lemon-task-worktrees", id]),
         {:ok, backlink} <- File.read(Path.join(gitdir, "gitdir")),
         true <- Path.expand(String.trim(backlink), gitdir) == Path.join(root, ".git") do
      true
    else
      _ -> false
    end
  end

  defp task_record(id) do
    if Process.whereis(CodingAgent.TaskStoreServer),
      do: TaskStore.get_record(id),
      else: {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
