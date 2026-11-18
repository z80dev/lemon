defmodule CodingAgent.SystemPrompt.Environment do
  @moduledoc """
  Captures stable working-directory, platform, shell, workspace layout and
  descendant instruction-path context. Journal this block once per session and
  reuse it on resume; a cwd change starts a new snapshot.

  Layout and guide paths stay in the stable block because they are orientation,
  not live filesystem truth. Their explicit snapshot labels require fresh
  discovery for newly created directories without churning the system prefix.

  Git discovery includes tracked and non-ignored untracked files. Generated
  trees are excluded even if tracked. Without Git, a bounded traversal skips
  symlinks and generated trees; unavailable Git ignore rules are labelled. Git
  failures are distinct from a confirmed non-repository. Truncation and read
  failures are explicit, never an assertion that discovery was exhaustive.

  The repository is located with file reads and every Git command runs through
  `LemonCore.SafeGit`, so a repository's configuration, attributes or a `.git`
  redirect cannot make this context run a program. A repository failing
  SafeGit's ownership checks is reported unavailable and its work tree is
  traversed without Git.

  `turn_section/2` supplies the current date and Git status with ContextRegistry's
  `:user_message` placement, never in the cached system prefix.
  """

  alias CodingAgent.ResourceLoader
  alias LemonCore.SafeGit

  @git_timeout_ms 2_000
  @max_git_bytes 262_144
  @max_status_lines 20
  @max_guides 200
  @max_layout_entries 24
  @max_walk_entries 4_096
  @max_walk_depth 12
  @excluded_dirs ~w(.git node_modules deps _build vendor cache .cache)

  @type capture_opt ::
          {:date, Date.t()}
          | {:shell, String.t() | nil}
          | {:git_executable, String.t() | nil}
          | {:git_timeout_ms, pos_integer()}
          | {:filesystem_probe, ((-> map()) -> term())}

  @doc """
  Capture and render the environment block for `cwd`.

  Options:

    * `:date` - used only by `turn_section/2` (default: today, UTC)
    * `:shell` - shell used by the bash tool (default: its configured shell)
    * `:git_executable` - Git executable path (default: `LemonCore.SafeGit.executable/0`,
      the operator-configured or fixed system `git`, never one found on `PATH`);
      explicit `nil` reports Git unavailable and uses filesystem discovery
    * `:git_timeout_ms` - deadline per Git command (default: 2,000 milliseconds)
    * `:filesystem_probe` - executes a zero-arity filesystem scan and returns
      `{:ok, snapshot}` or an unavailable result. Defaults to a monitored task
      with a 2-second deadline; controlled callers can inject its execution.

  Git output is capped at 256 KiB per command. The instruction index displays
  at most 200 paths and layout at most 24 top-level entries. Filesystem fallback
  visits at most 4,096 entries, to depth 12, with a 2-second scan deadline.
  """
  @spec capture(String.t(), [capture_opt()]) :: String.t()
  def capture(cwd, opts \\ []) when is_binary(cwd) do
    cwd = Path.expand(cwd)
    shell = Keyword.get(opts, :shell) || default_shell()
    git = Keyword.get_lazy(opts, :git_executable, &default_git/0)
    timeout = Keyword.get(opts, :git_timeout_ms, @git_timeout_ms)
    filesystem_probe = Keyword.get(opts, :filesystem_probe, &bounded_filesystem_probe/1)
    {git_lines, root, snapshot} = repository_snapshot(cwd, git, timeout, filesystem_probe)

    [
      "## Environment",
      "Working directory: #{cwd}",
      "Platform: #{platform()}",
      "Shell: #{shell}"
    ]
    |> Kernel.++(git_lines)
    |> Kernel.++(workspace_lines(root, snapshot))
    |> Enum.join("\n")
  end

  @doc "Current date and bounded Git snapshot for the user turn, not the system prompt."
  def turn_section(cwd, opts \\ []) do
    cwd = Path.expand(cwd)
    date = Keyword.get(opts, :date) || Date.utc_today()
    git = Keyword.get_lazy(opts, :git_executable, &default_git/0)
    timeout = Keyword.get(opts, :git_timeout_ms, @git_timeout_ms)

    lines =
      if git do
        case SafeGit.repository(cwd) do
          {:ok, repo} -> repository_lines(repo, git, timeout)
          :not_repository -> ["Git repository: no"]
          {:error, reason} -> ["Git repository: unavailable (#{reason})"]
        end
      else
        ["Git repository: unavailable (Git executable not found)"]
      end

    %{
      name: :environment,
      title: "Current environment",
      body: Enum.join(["Today's date: #{Date.to_iso8601(date)}" | lines], "\n"),
      placement: :user_message
    }
  end

  defp default_git do
    case SafeGit.executable() do
      {:ok, git} -> git
      {:error, _} -> nil
    end
  end

  defp default_shell do
    {shell, _args} = CodingAgent.BashExecutor.get_shell_config()
    shell
  end

  defp platform do
    os =
      case :os.type() do
        {:unix, name} -> Atom.to_string(name)
        {:win32, _} -> "windows"
      end

    "#{os} (#{:erlang.system_info(:system_architecture)})"
  end

  defp repository_snapshot(cwd, nil, _timeout, probe) do
    {["Git repository: unavailable (Git executable not found)"], cwd,
     filesystem_snapshot(cwd, "Git ignore rules unavailable", probe)}
  end

  defp repository_snapshot(cwd, git, timeout, probe) do
    case SafeGit.repository(cwd) do
      {:ok, repo} ->
        {["Git worktree root: #{repo.root}"], repo.root, git_snapshot(repo, git, timeout)}

      :not_repository ->
        {["Git repository: no"], cwd, filesystem_snapshot(cwd, "non-Git traversal", probe)}

      {:error, reason} ->
        unavailable_snapshot(cwd, reason, probe)
    end
  end

  defp unavailable_snapshot(cwd, reason, probe) do
    {["Git repository: unavailable (#{reason})"], cwd,
     filesystem_snapshot(cwd, "Git ignore rules unavailable", probe)}
  end

  defp repository_lines(repo, git, timeout) do
    root_line = "Git worktree root: #{repo.root}"

    case git_command(repo, git, ["status", "--porcelain=v1", "--branch"], timeout) do
      {result, output, status}
      when (result == :ok and status == 0) or result == :truncated ->
        case complete_lines(output, result, "\n") do
          ["## " <> branch | changes] ->
            ["Git repository: yes (branch: #{branch})", root_line] ++
              status_lines(changes, result == :truncated)

          _ ->
            ["Git repository: yes", root_line, "Git status at turn start: unavailable"]
        end

      _ ->
        ["Git repository: yes", root_line, "Git status at turn start: unavailable"]
    end
  end

  defp status_lines([], false), do: ["Git status at turn start: clean"]

  defp status_lines(changes, truncated) do
    shown = Enum.take(changes, @max_status_lines)
    truncated = truncated or length(changes) > @max_status_lines
    more = if truncated, do: ["... Git status snapshot truncated"], else: []

    ["Git status at turn start (snapshot):" | shown] ++
      more
  end

  defp git_snapshot(repo, git, timeout) do
    case git_command(
           repo,
           git,
           ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
           timeout
         ) do
      {result, output, status}
      when (result == :ok and status == 0) or result == :truncated ->
        paths = complete_lines(output, result, <<0>>)
        paths = paths |> Enum.reject(&excluded_path?/1) |> Enum.uniq() |> Enum.sort()

        guides =
          Enum.filter(paths, fn path ->
            Path.dirname(path) != "." and ResourceLoader.instruction_guide?(path) and
              regular_file?(Path.join(repo.root, path))
          end)

        entries =
          paths
          |> Enum.map(fn path ->
            [name | rest] = Path.split(path)
            if rest == [], do: name, else: name <> "/"
          end)
          |> Enum.uniq()
          |> Enum.sort()

        %{
          guides: guides,
          entries: entries,
          truncated: result == :truncated,
          source: "Git tracked and non-ignored untracked files",
          unavailable: false
        }

      failure ->
        %{
          guides: [],
          entries: [],
          truncated: false,
          source: "Git discovery unavailable" <> failure_reason(failure),
          unavailable: true
        }
    end
  end

  defp failure_reason({:error, reason}), do: " (#{reason})"
  defp failure_reason({:ok, _output, status}), do: " (exit status #{status})"

  defp complete_lines(output, result, separator) do
    parts = String.split(output, separator)
    parts = if result == :truncated, do: Enum.drop(parts, -1), else: parts
    Enum.reject(parts, &(&1 == ""))
  end

  defp excluded_path?(path) do
    Enum.any?(Path.split(path), &(&1 in @excluded_dirs))
  end

  defp regular_file?(path) do
    match?({:ok, %{type: :regular}}, File.lstat(path))
  end

  defp bounded_filesystem_probe(scan) do
    task = Task.async(scan)
    Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill)
  end

  defp filesystem_snapshot(root, source, probe) do
    case probe.(fn -> walk([{root, 0}], root, @max_walk_entries, [], [], false) end) do
      {:ok, snapshot} ->
        Map.merge(snapshot, %{source: source, unavailable: false})

      _ ->
        %{
          guides: [],
          entries: [],
          truncated: true,
          source: source <> "; filesystem scan unavailable",
          unavailable: true
        }
    end
  end

  defp walk([], _root, _remaining, guides, entries, truncated) do
    %{guides: Enum.sort(guides), entries: Enum.sort(entries), truncated: truncated}
  end

  defp walk(_queue, _root, 0, guides, entries, _truncated) do
    %{guides: Enum.sort(guides), entries: Enum.sort(entries), truncated: true}
  end

  defp walk([{dir, depth} | queue], root, remaining, guides, entries, truncated) do
    case File.ls(dir) do
      {:ok, names} ->
        names = names |> Enum.reject(&(&1 in @excluded_dirs)) |> Enum.sort()
        selected = Enum.take(names, remaining)
        truncated = truncated or length(names) > remaining

        {children, guides, entries, truncated} =
          Enum.reduce(selected, {[], guides, entries, truncated}, fn name,
                                                                     {children, guides, entries,
                                                                      cut} ->
            path = Path.join(dir, name)

            case File.lstat(path) do
              {:ok, %{type: :directory}} ->
                entries = if depth == 0, do: [name <> "/" | entries], else: entries

                if depth < @max_walk_depth do
                  {[{path, depth + 1} | children], guides, entries, cut}
                else
                  {children, guides, entries, true}
                end

              {:ok, %{type: :regular}} ->
                entries = if depth == 0, do: [name | entries], else: entries

                guides =
                  if depth > 0 and ResourceLoader.instruction_guide?(path),
                    do: [Path.relative_to(path, root) | guides],
                    else: guides

                {children, guides, entries, cut}

              {:ok, %{type: :symlink}} ->
                {children, guides, entries, cut}

              _ ->
                {children, guides, entries, true}
            end
          end)

        walk(
          Enum.reverse(children, queue),
          root,
          remaining - length(selected),
          guides,
          entries,
          truncated
        )

      {:error, _} ->
        walk(queue, root, remaining, guides, entries, true)
    end
  end

  defp workspace_lines(root, snapshot) do
    guides = Enum.take(snapshot.guides, @max_guides)
    entries = Enum.take(snapshot.entries, @max_layout_entries)
    guide_cut = snapshot.truncated or length(snapshot.guides) > @max_guides
    layout_cut = snapshot.truncated or length(snapshot.entries) > @max_layout_entries

    [
      "Workspace snapshot root: #{root}",
      "Workspace context at session start (snapshot; #{snapshot.source}; generated trees excluded):",
      "Top-level entries (bounded, sorted):"
    ] ++
      Enum.map(entries, &("- " <> inspect(&1))) ++
      truncation_lines(layout_cut, snapshot.unavailable, "workspace layout") ++
      [
        "Descendant instruction paths (bounded index, not contents):",
        "Before editing, read applicable instruction guides (AGENTS.md, CLAUDE.md, GEMINI.md and similar); " <>
          "deeper directory rules override broader ones. " <>
          "This bounded snapshot is not exhaustive; discover guides in omitted or newly created directories."
      ] ++
      Enum.map(guides, &("- " <> inspect(Path.join(root, &1)))) ++
      truncation_lines(guide_cut, snapshot.unavailable, "instruction index")
  end

  defp truncation_lines(_truncated, true, label), do: ["... #{label} unavailable"]
  defp truncation_lines(true, false, label), do: ["... #{label} truncated"]
  defp truncation_lines(false, false, _label), do: []

  # SafeGit bounds output while it is read and kills the command on timeout or
  # output overflow instead of retaining an unbounded ls-files/status result.
  defp git_command(repo, git, args, timeout),
    do: SafeGit.run(repo, args, git: git, timeout_ms: timeout, max_bytes: @max_git_bytes)
end
