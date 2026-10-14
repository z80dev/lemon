defmodule CodingAgent.SystemPrompt.Environment do
  @moduledoc """
  Captures working directory, platform, shell, Git worktree root and status,
  a bounded workspace layout and descendant instruction-path index, and date.

  Capture once at session start and reuse the returned string on prompt refresh.
  All filesystem and Git information is labelled as a session-start snapshot;
  deterministic ordering avoids time-relative prompt-cache churn. Descendant
  guides are indexed, not loaded: read applicable guides before editing there.

  Git discovery includes tracked and non-ignored untracked files. Generated
  trees are excluded even if tracked. Without Git, a bounded traversal skips
  symlinks and generated trees; unavailable Git ignore rules are labelled. Git
  failures are distinct from a confirmed non-repository. Truncation and read
  failures are explicit, never an assertion that discovery was exhaustive.

  `CodingAgent.Session.PromptComposer` appends this block after all other prompt
  sections. The date remains the final line.
  """

  alias CodingAgent.ResourceLoader

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

  @doc """
  Capture and render the environment block for `cwd`.

  Options:

    * `:date` - date to report (default: today, UTC)
    * `:shell` - shell used by the bash tool (default: its configured shell)
    * `:git_executable` - Git executable path (default: resolve `git` on PATH);
      explicit `nil` reports Git unavailable and uses filesystem discovery
    * `:git_timeout_ms` - deadline per Git command (default: 2,000 milliseconds)

  Git output is capped at 256 KiB per command. The instruction index displays
  at most 200 paths and layout at most 24 top-level entries. Filesystem fallback
  visits at most 4,096 entries, to depth 12, with a 2-second scan deadline.
  """
  @spec capture(String.t(), [capture_opt()]) :: String.t()
  def capture(cwd, opts \\ []) when is_binary(cwd) do
    cwd = Path.expand(cwd)
    date = Keyword.get(opts, :date) || Date.utc_today()
    shell = Keyword.get(opts, :shell) || default_shell()
    git = Keyword.get_lazy(opts, :git_executable, fn -> System.find_executable("git") end)
    timeout = Keyword.get(opts, :git_timeout_ms, @git_timeout_ms)
    {git_lines, root, snapshot} = repository_snapshot(cwd, git, timeout)

    [
      "## Environment",
      "Working directory: #{cwd}",
      "Platform: #{platform()}",
      "Shell: #{shell}"
    ]
    |> Kernel.++(git_lines)
    |> Kernel.++(workspace_lines(root, snapshot))
    |> Kernel.++(["Today's date: #{Date.to_iso8601(date)}"])
    |> Enum.join("\n")
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

  defp repository_snapshot(cwd, nil, _timeout) do
    {["Git repository: unavailable (Git executable not found)"], cwd,
     filesystem_snapshot(cwd, "Git ignore rules unavailable")}
  end

  defp repository_snapshot(cwd, git, timeout) do
    case git_command(git, cwd, ["rev-parse", "--show-toplevel"], timeout) do
      {:ok, output, 0} ->
        root = String.trim(output)

        if root != "" and File.dir?(root) do
          {repository_lines(cwd, root, git, timeout), root, git_snapshot(root, git, timeout)}
        else
          unavailable_snapshot(cwd, :invalid_root)
        end

      {:ok, output, _status} ->
        if String.contains?(output, "not a git repository") do
          {["Git repository: no"], cwd, filesystem_snapshot(cwd, "non-Git traversal")}
        else
          unavailable_snapshot(cwd, :command_failed)
        end

      {:truncated, _output, :unknown} ->
        unavailable_snapshot(cwd, :output_limit)

      {:error, reason} ->
        unavailable_snapshot(cwd, reason)
    end
  end

  defp unavailable_snapshot(cwd, reason) do
    {["Git repository: unavailable (#{reason})"], cwd,
     filesystem_snapshot(cwd, "Git ignore rules unavailable")}
  end

  defp repository_lines(cwd, root, git, timeout) do
    root_line = "Git worktree root: #{root}"

    case git_command(git, cwd, ["status", "--porcelain=v1", "--branch"], timeout) do
      {result, output, status}
      when (result == :ok and status == 0) or result == :truncated ->
        case complete_lines(output, result, "\n") do
          ["## " <> branch | changes] ->
            ["Git repository: yes (branch: #{branch})", root_line] ++
              status_lines(changes, result == :truncated)

          _ ->
            ["Git repository: yes", root_line, "Git status at session start: unavailable"]
        end

      _ ->
        ["Git repository: yes", root_line, "Git status at session start: unavailable"]
    end
  end

  defp status_lines([], false), do: ["Git status at session start: clean"]

  defp status_lines(changes, truncated) do
    shown = Enum.take(changes, @max_status_lines)
    truncated = truncated or length(changes) > @max_status_lines
    more = if truncated, do: ["... Git status snapshot truncated"], else: []

    ["Git status at session start (a snapshot; it does not update during the session):" | shown] ++
      more
  end

  defp git_snapshot(root, git, timeout) do
    case git_command(
           git,
           root,
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
              regular_file?(Path.join(root, path))
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

      _ ->
        %{
          guides: [],
          entries: [],
          truncated: false,
          source: "Git discovery unavailable",
          unavailable: true
        }
    end
  end

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

  defp filesystem_snapshot(root, source) do
    task = Task.async(fn -> walk([{root, 0}], root, @max_walk_entries, [], [], false) end)

    case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
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

  # Use a port rather than System.cmd/3 so output is bounded while it is read,
  # and close the command on timeout or output overflow instead of retaining an
  # unbounded ls-files/status result. No shell is involved.
  defp git_command(git, cwd, args, timeout) do
    port =
      Port.open({:spawn_executable, String.to_charlist(git)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: Enum.map(["-C", cwd | args], &String.to_charlist/1),
        env: [{~c"GIT_OPTIONAL_LOCKS", ~c"0"}, {~c"LC_ALL", ~c"C"}]
      ])

    deadline = System.monotonic_time(:millisecond) + timeout
    collect_git(port, deadline, [], 0)
  rescue
    _ -> {:error, :command_unavailable}
  end

  defp collect_git(port, deadline, chunks, size) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        if size + byte_size(data) > @max_git_bytes do
          part = binary_part(data, 0, @max_git_bytes - size)
          close_port(port)
          {:truncated, IO.iodata_to_binary(Enum.reverse([part | chunks])), :unknown}
        else
          collect_git(port, deadline, [data | chunks], size + byte_size(data))
        end

      {^port, {:exit_status, status}} ->
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks)), status}
    after
      remaining ->
        close_port(port)
        {:error, :timeout}
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
