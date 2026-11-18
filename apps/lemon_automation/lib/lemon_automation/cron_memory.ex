defmodule LemonAutomation.CronMemory do
  @moduledoc """
  Per-job markdown memory that carries context across cron runs.

  The memory file is always Lemon-owned:
  `<home state dir>/cron_memory/<job id>.md` (`~/.lemon/cron_memory` by
  default). No caller chooses its path; a job id that is not a plain file name
  maps to a digest-named file in the same directory.

  Memory I/O is descriptor-bound (`LemonCore.ConfinedFS`, rooted at the Lemon
  state directory; `read_confined/2`, `replace_confined/4`):

    * `cron_memory` is opened (created `0o700` on append) through a directory
      handle that refuses a symlink; every later step works relative to that
      handle, so swapping the directory for a symlink afterwards cannot
      redirect a read or write outside it, and a swap observed after a write
      is reported as an error;
    * the file must be a regular file with exactly one link (a hard link to
      another file is refused) and at most 1 MiB; a read opens it without
      following symlinks (non-blocking, so a FIFO cannot stall it) and requires
      the opened file to be the checked inode;
    * a write goes to a private staged temporary file renamed over the
      entry, never truncating or writing through an existing inode; a new
      file is published only while still absent (atomic), and an existing
      one must still be the inode that was read immediately before the rename
      (best-effort conflict detection, not compare-and-swap).

  Each run appends a `## Run <id>` entry. When the file outgrows 24,000
  characters it is compacted deterministically (no model call):
  the header and the most recent whole run entries are kept, and every older
  entry is reduced to one line - start time, status, and the first line of its
  result - under `## Earlier Runs`. Earlier summaries carry forward, with a
  bounded number of lines and cumulative status counts.
  """

  alias LemonAutomation.{CronJob, CronRun}
  alias LemonCore.ConfinedFS

  @memory_dir "cron_memory"
  @job_file_name ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/
  @max_prompt_chars 8_000
  @max_file_chars 24_000
  # Compaction keeps a memory file far below this; anything larger is not ours.
  @max_file_bytes 1_048_576
  @recent_entries_chars 14_000
  @max_header_chars 2_000
  @max_summary_lines 40
  @summary_line_chars 160
  @max_result_chars 2_000
  @summary_heading "## Earlier Runs"

  @doc "The job's Lemon-owned memory file path."
  @spec memory_file(CronJob.t()) :: binary()
  def memory_file(%CronJob{id: id}) do
    name =
      if is_binary(id) and Regex.match?(@job_file_name, id),
        do: id,
        else:
          "job-" <> Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(id)), case: :lower)

    Path.join(memory_dir(), name <> ".md")
  end

  @spec read_for_prompt(CronJob.t()) :: {binary(), binary() | nil}
  def read_for_prompt(%CronJob{} = job) do
    path = memory_file(job)

    text =
      case read_confined(path) do
        {:ok, content, _stat} -> prompt_slice(content)
        _ -> nil
      end

    {path, text}
  end

  @spec build_prompt(binary(), binary(), binary() | nil) :: binary()
  def build_prompt(prompt, memory_file, memory_text)
      when is_binary(prompt) and is_binary(memory_file) do
    memory_block =
      case normalize_string(memory_text) do
        nil -> "_No previous memory yet._"
        text -> text
      end

    """
    You are running a scheduled cron task.
    This run uses an isolated forked session so scheduled work stays separate from the originating conversation.

    Persistent memory file: #{memory_file}
    Use the memory notes below as prior run history for continuity across runs.
    Update durable findings in that memory file through the normal file tools when the task produces reusable state.

    Delivery: your final answer is sent to the user's chat (the originating chat, or their paired chat when the job was created elsewhere). Write it for the user and keep it concise.

    Scheduling guardrail: do not create, update, remove, or recursively schedule cron jobs from this run unless the task explicitly asks you to manage schedules.

    Tooling guardrail: use only the tools needed for this scheduled task. Prefer reading memory and completing the requested work over broad exploration.

    ## Memory Context
    #{memory_block}

    ## Task
    #{prompt}
    """
  end

  @spec append_run(
          CronJob.t(),
          CronRun.t(),
          binary(),
          {:ok, binary()} | {:error, binary()} | :timeout
        ) ::
          :ok
  def append_run(%CronJob{} = job, %CronRun{} = run, session_key, result)
      when is_binary(session_key) do
    path = memory_file(job)
    entry = render_entry(job, run, session_key, result)

    with :ok <- File.mkdir_p(state_root()) do
      with_memory_dir(path, [create: true, mode: 0o700], fn fs, dir, name ->
        with {:ok, existing, expected} <- existing_memory(fs, dir, name, job) do
          replace_in(fs, dir, name, compact_if_needed(existing <> "\n\n" <> entry), expected)
        end
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  def append_run(_job, _run, _session_key, _result), do: :ok

  # The current memory and the entry state the replacement must still find.
  # An unsafe existing entry (symlink, hard link, special file) is never read
  # or replaced.
  defp existing_memory(fs, dir, name, %CronJob{} = job) do
    case read_in(fs, dir, name, []) do
      {:ok, content, stat} when content != "" -> {:ok, content, stat}
      {:ok, _empty, stat} -> {:ok, memory_header(job), stat}
      {:error, :enoent} -> {:ok, memory_header(job), :absent}
      {:error, _} = error -> error
    end
  end

  defp memory_header(job) do
    """
    # Cron Memory: #{job.name}

    - Job ID: #{job.id}
    - Agent ID: #{job.agent_id}
    - Base Session Key: #{job.session_key}
    - Memory file created at: #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
    """
  end

  defp render_entry(%CronJob{} = job, %CronRun{} = run, session_key, result) do
    status =
      case result do
        {:ok, _} -> "completed"
        {:error, _} -> "failed"
        :timeout -> "timeout"
      end

    result_text =
      case result do
        {:ok, output} -> output
        {:error, error} -> error
        :timeout -> "Run timed out waiting for completion."
      end
      |> normalize_string()
      |> case do
        nil -> "(empty)"
        text -> String.slice(text, 0, @max_result_chars)
      end

    started_at =
      run.started_at_ms
      |> case do
        nil ->
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

        ms ->
          DateTime.from_unix!(ms, :millisecond)
          |> DateTime.truncate(:second)
          |> DateTime.to_iso8601()
      end

    """
    ## Run #{run.id}

    - started_at: #{started_at}
    - status: #{status}
    - triggered_by: #{run.triggered_by}
    - session_key: #{session_key}
    - router_run_id: #{run.run_id || "(unknown)"}

    ### Prompt

    ```text
    #{String.slice(job.prompt || "", 0, 1_200)}
    ```

    ### Result

    ```text
    #{result_text}
    ```
    """
  end

  @doc false
  @spec compact_if_needed(binary()) :: binary()
  def compact_if_needed(content) when is_binary(content) do
    if String.length(content) <= @max_file_chars do
      content
    else
      compact(content)
    end
  end

  defp compact(content) do
    {header, previous_summary, entries} = split_sections(content)
    {kept, dropped} = keep_recent_entries(entries)
    {prior_counts, prior_lines} = parse_summary(previous_summary)

    counts = Enum.reduce(dropped, prior_counts, &count_status(entry_field(&1, "status"), &2))
    lines = Enum.take(prior_lines ++ Enum.map(dropped, &summary_line/1), -@max_summary_lines)

    compacted_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    summary =
      Enum.join(
        [
          @summary_heading,
          "",
          "- compacted_at: #{compacted_at}",
          "- runs_summarized: #{format_counts(counts)}"
          | lines
        ],
        "\n"
      )

    [String.slice(header, 0, @max_header_chars), summary | kept]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  # Header = everything before the first summary/run heading.
  defp split_sections(content) do
    [header | rest] = String.split(content, ~r/^(?=## (?:Run |Earlier Runs))/m)

    {summaries, entries} =
      Enum.split_with(rest, &String.starts_with?(&1, @summary_heading))

    {header, Enum.join(summaries, "\n"), entries}
  end

  # Keep whole recent entries within the budget; always keep the newest one.
  defp keep_recent_entries(entries) do
    {kept, _size} =
      entries
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn entry, {kept, size} ->
        entry_size = String.length(entry)

        cond do
          kept == [] ->
            {:cont, {[String.slice(entry, 0, @recent_entries_chars)], entry_size}}

          size + entry_size <= @recent_entries_chars ->
            {:cont, {[entry | kept], size + entry_size}}

          true ->
            {:halt, {kept, size}}
        end
      end)

    {kept, Enum.take(entries, length(entries) - length(kept))}
  end

  defp parse_summary(summary) do
    counts =
      case Regex.run(~r/runs_summarized: \d+ \(([^)]*)\)/, summary) do
        [_, pairs] ->
          ~r/(\w+): (\d+)/
          |> Regex.scan(pairs)
          |> Map.new(fn [_, status, n] -> {status, String.to_integer(n)} end)

        _ ->
          %{}
      end

    lines =
      summary
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "- run "))

    {counts, lines}
  end

  defp summary_line(entry) do
    id =
      case Regex.run(~r/^## Run (\S+)/, entry) do
        [_, id] -> id
        _ -> "?"
      end

    result =
      case Regex.run(~r/### Result\s*```text\n(.*?)\n/s, entry) do
        [_, first_line] -> String.trim(first_line)
        _ -> ""
      end

    ("- run #{id} · #{entry_field(entry, "started_at") || "?"} · " <>
       "#{entry_field(entry, "status") || "unknown"} · #{result}")
    |> String.slice(0, @summary_line_chars)
  end

  defp entry_field(entry, field) do
    case Regex.run(~r/^- #{field}: (.+)$/m, entry) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  defp count_status(status, counts), do: Map.update(counts, status || "unknown", 1, &(&1 + 1))

  defp format_counts(counts) do
    total = counts |> Map.values() |> Enum.sum()

    pairs =
      counts
      |> Enum.sort()
      |> Enum.map_join(", ", fn {status, n} -> "#{status}: #{n}" end)

    "#{total} (#{pairs})"
  end

  defp prompt_slice(content) when is_binary(content) do
    if String.length(content) <= @max_prompt_chars do
      content
    else
      tail = String.slice(content, -@max_prompt_chars, @max_prompt_chars)

      """
      [Memory truncated to latest #{@max_prompt_chars} chars]
      #{tail}
      """
    end
  end

  defp memory_dir, do: LemonCore.Paths.home_path([@memory_dir])

  # The trusted root of every memory operation: the Lemon state directory.
  defp state_root, do: LemonCore.Paths.home_state_dir()

  # The memory file name of `path`, which must be `<state root>/cron_memory/<name>`.
  defp memory_name(path) do
    case ConfinedFS.beneath(state_root(), path) do
      {:ok, [@memory_dir, name]} -> {:ok, name}
      _ -> {:error, :unsafe_memory_dir}
    end
  end

  # Runs `fun.(fs, dir, name)` with `dir` a handle on the memory directory.
  defp with_memory_dir(path, dir_opts, fun) do
    with {:ok, name} <- memory_name(path) do
      ConfinedFS.with_root(state_root(), fn fs ->
        with {:ok, dir} <- open_memory_dir(fs, dir_opts), do: fun.(fs, dir, name)
      end)
    end
  end

  defp open_memory_dir(fs, opts) do
    case ConfinedFS.open_dir(fs, :root, [@memory_dir], opts) do
      {:ok, dir} -> {:ok, dir}
      {:error, :enoent} -> {:error, :enoent}
      {:error, _} -> {:error, :unsafe_memory_dir}
    end
  end

  @doc false
  # Reads `path` bound to the checked entry (see the moduledoc).
  # `opts[:before_open]` is a test seam run between the check and the read.
  @spec read_confined(binary(), keyword()) ::
          {:ok, binary(), ConfinedFS.Stat.t()} | {:error, term()}
  def read_confined(path, opts \\ []) do
    with_memory_dir(path, [], &read_in(&1, &2, &3, opts))
  end

  defp read_in(fs, dir, name, opts) do
    with {:ok, stat} <- checked_file(fs, dir, name),
         :ok <- run_hook(opts, :before_open) do
      case ConfinedFS.read(fs, dir, name, @max_file_bytes, expect: stat) do
        {:ok, bytes, %ConfinedFS.Stat{type: :regular, nlink: 1} = read} -> {:ok, bytes, read}
        {:ok, _bytes, _stat} -> {:error, :memory_changed}
        {:error, :too_large} -> {:error, :unsafe_memory_file}
        {:error, _} -> {:error, :memory_changed}
      end
    end
  end

  @doc false
  # Replaces `path` with `content` through an exclusive temporary file in the
  # opened directory and a rename, only while the entry is still `expected`
  # (`:absent` or the stat returned by `read_confined/2`).
  # `opts[:before_rename]` is a test seam run after the entry check.
  @spec replace_confined(binary(), binary(), :absent | ConfinedFS.Stat.t(), keyword()) ::
          :ok | {:error, term()}
  def replace_confined(path, content, expected, opts \\ []) do
    with_memory_dir(path, [], &replace_in(&1, &2, &3, content, expected, opts))
  end

  defp replace_in(fs, dir, name, content, expected, opts \\ []) do
    with {:ok, dir_stat} <- ConfinedFS.stat(fs, dir, ""),
         :ok <- entry_is(fs, dir, name, expected),
         :ok <- run_hook(opts, :before_rename),
         :ok <- entry_is(fs, dir, name, expected),
         :ok <- replace_entry(fs, dir, name, content, expected) do
      still_memory_dir(fs, dir_stat)
    end
  end

  defp checked_file(fs, dir, name) do
    case ConfinedFS.stat(fs, dir, name) do
      {:ok, %ConfinedFS.Stat{type: :regular, nlink: 1, size: size} = stat}
      when size <= @max_file_bytes ->
        {:ok, stat}

      {:error, :enoent} ->
        {:error, :enoent}

      _ ->
        {:error, :unsafe_memory_file}
    end
  end

  # The entry is still absent, or still the single-link regular file read.
  defp entry_is(fs, dir, name, :absent) do
    case ConfinedFS.stat(fs, dir, name) do
      {:error, :enoent} -> :ok
      _ -> {:error, :memory_changed}
    end
  end

  defp entry_is(fs, dir, name, %ConfinedFS.Stat{} = expected) do
    case ConfinedFS.stat(fs, dir, name) do
      {:ok, %ConfinedFS.Stat{type: :regular, nlink: 1} = stat} ->
        if ConfinedFS.Stat.same_object?(stat, expected), do: :ok, else: {:error, :memory_changed}

      _ ->
        {:error, :memory_changed}
    end
  end

  # The helper rechecks `expected` right before its rename.
  defp replace_entry(fs, dir, name, content, expected) do
    case ConfinedFS.replace(fs, dir, name, content, expect: expected) do
      {:ok, _stat} -> :ok
      {:error, _} -> {:error, :memory_changed}
    end
  end

  # The written directory is still the one at `cron_memory`. A swap while the
  # handle was open is reported; the write itself stayed in the opened
  # directory.
  defp still_memory_dir(fs, %ConfinedFS.Stat{} = dir_stat) do
    with {:ok, dir} <- ConfinedFS.open_dir(fs, :root, [@memory_dir]),
         {:ok, stat} <- ConfinedFS.stat(fs, dir, ""),
         true <- ConfinedFS.Stat.same_object?(stat, dir_stat) do
      :ok
    else
      _ -> {:error, :memory_changed}
    end
  end

  defp run_hook(opts, key) do
    case Keyword.get(opts, key) do
      nil ->
        :ok

      hook when is_function(hook, 0) ->
        _ = hook.()
        :ok
    end
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil
end
