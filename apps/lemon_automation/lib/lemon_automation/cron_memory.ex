defmodule LemonAutomation.CronMemory do
  @moduledoc """
  Per-job markdown memory that carries context across cron runs.

  The memory file is always Lemon-owned:
  `<home state dir>/cron_memory/<job id>.md` (`~/.lemon/cron_memory` by
  default). No caller chooses its path; a job id that is not a plain file name
  maps to a digest-named file in the same directory.

  Memory I/O is bound to checked filesystem objects (`read_confined/2`,
  `replace_confined/4`):

    * the directory must be a real directory (not a symlink) and the file a
      regular file with exactly one link (a hard link to another file is
      refused); both are re-checked with `lstat` before and after each
      operation;
    * a read compares the opened handle's inode with the checked entry, so a
      file swapped for a symlink or another inode after the check is not read;
    * a write goes to an exclusively created temporary file in the same
      directory and is renamed over the entry, never truncating or writing
      through an existing inode; the entry must still be the inode that was
      read (or still absent) right before the rename.

  Known gap (shared finding NEW-6): OTP has no `openat`/`O_NOFOLLOW`, so the
  checks and the path-based open/rename are separate syscalls. A local writer
  who swaps the memory directory for a symlink in the window between the last
  check and the open, exclusive create or rename can redirect that one
  operation (or block a read on a substituted FIFO); the following re-check
  reports the swap but cannot undo it. Do not rely on this module for
  containment against a concurrent local writer inside the Lemon state
  directory.

  Each run appends a `## Run <id>` entry. When the file outgrows 24,000
  characters it is compacted deterministically (no model call):
  the header and the most recent whole run entries are kept, and every older
  entry is reduced to one line - start time, status, and the first line of its
  result - under `## Earlier Runs`. Earlier summaries carry forward, with a
  bounded number of lines and cumulative status counts.
  """

  alias LemonAutomation.{CronJob, CronRun}

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

    with :ok <- File.mkdir_p(memory_dir()),
         {:ok, existing, expected} <- existing_memory(path, job) do
      entry = render_entry(job, run, session_key, result)
      _ = replace_confined(path, compact_if_needed(existing <> "\n\n" <> entry), expected)
    end

    :ok
  rescue
    _ -> :ok
  end

  def append_run(_job, _run, _session_key, _result), do: :ok

  # The current memory and the entry state the replacement must still find.
  # An unsafe existing entry (symlink, hard link, special file) is never read
  # or replaced.
  defp existing_memory(path, %CronJob{} = job) do
    case read_confined(path) do
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

  @doc false
  # Reads `path` bound to the checked entry (see the moduledoc).
  # `opts[:before_open]` is a test seam run between the checks and the open.
  @spec read_confined(binary(), keyword()) :: {:ok, binary(), File.Stat.t()} | {:error, term()}
  def read_confined(path, opts \\ []) do
    dir = Path.dirname(path)

    with {:ok, dir_stat} <- checked_dir(dir),
         {:ok, file_stat} <- checked_file(path),
         :ok <- run_hook(opts, :before_open),
         {:ok, result} <- File.open(path, [:read, :binary], &read_bound(&1, file_stat)),
         {:ok, bytes} <- result,
         :ok <- unchanged(dir, dir_stat),
         :ok <- unchanged(path, file_stat) do
      {:ok, bytes, file_stat}
    end
  end

  @doc false
  # Replaces `path` with `content` through an exclusive temporary file in the
  # checked directory and a rename, only while the entry is still `expected`
  # (`:absent` or the stat returned by `read_confined/2`).
  # `opts[:before_rename]` is a test seam run after the temporary file is
  # written.
  @spec replace_confined(binary(), binary(), :absent | File.Stat.t(), keyword()) ::
          :ok | {:error, term()}
  def replace_confined(path, content, expected, opts \\ []) do
    dir = Path.dirname(path)
    tmp = Path.join(dir, ".#{Path.basename(path)}.#{temp_suffix()}.tmp")

    with {:ok, dir_stat} <- checked_dir(dir),
         :ok <- entry_is(path, expected),
         {:ok, tmp_stat} <- write_exclusive(tmp, content) do
      result =
        with :ok <- run_hook(opts, :before_rename),
             :ok <- unchanged(dir, dir_stat),
             :ok <- entry_is(path, expected),
             :ok <- unchanged(tmp, tmp_stat),
             :ok <- File.rename(tmp, path),
             :ok <- unchanged(dir, dir_stat) do
          unchanged(path, tmp_stat)
        end

      if result != :ok, do: discard_temp(tmp, tmp_stat)
      result
    end
  end

  defp checked_dir(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory} = stat} -> {:ok, stat}
      _ -> {:error, :unsafe_memory_dir}
    end
  end

  defp checked_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, links: 1, size: size} = stat}
      when size <= @max_file_bytes ->
        {:ok, stat}

      {:error, :enoent} ->
        {:error, :enoent}

      _ ->
        {:error, :unsafe_memory_file}
    end
  end

  defp entry_is(path, :absent) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _ -> {:error, :memory_changed}
    end
  end

  defp entry_is(path, %File.Stat{} = expected), do: unchanged(path, expected)

  # Same object (device and inode), same type, and a regular file still has
  # exactly one link.
  defp unchanged(path, %File.Stat{} = expected) do
    case File.lstat(path) do
      {:ok, %File.Stat{} = stat} ->
        if same_object?(stat, expected) and (stat.type != :regular or stat.links == 1),
          do: :ok,
          else: {:error, :memory_changed}

      _ ->
        {:error, :memory_changed}
    end
  end

  defp same_object?(a, b) do
    a.type == b.type and a.inode == b.inode and a.major_device == b.major_device and
      a.minor_device == b.minor_device
  end

  defp read_bound(io, %File.Stat{size: size} = expected) do
    with {:ok, info} <- :file.read_file_info(io),
         %File.Stat{type: :regular, links: 1} = opened <- File.Stat.from_record(info),
         true <- same_object?(opened, expected) do
      case IO.binread(io, size + 1) do
        :eof when size == 0 -> {:ok, ""}
        bytes when is_binary(bytes) and byte_size(bytes) == size -> {:ok, bytes}
        _ -> {:error, :memory_changed}
      end
    else
      _ -> {:error, :memory_changed}
    end
  end

  defp write_exclusive(tmp, content) do
    result =
      File.open(tmp, [:write, :exclusive, :binary], fn io ->
        with {:ok, info} <- :file.read_file_info(io),
             %File.Stat{type: :regular, links: 1} = stat <- File.Stat.from_record(info),
             :ok <- IO.binwrite(io, content) do
          {:ok, stat}
        else
          _ -> {:error, :memory_changed}
        end
      end)

    case result do
      {:ok, {:ok, stat}} ->
        {:ok, stat}

      {:ok, error} ->
        _ = discard_temp(tmp, nil)
        error

      {:error, _} = error ->
        error
    end
  end

  # Removes only the temporary file this process created.
  defp discard_temp(tmp, nil), do: File.rm(tmp)

  defp discard_temp(tmp, %File.Stat{} = stat) do
    if unchanged(tmp, stat) == :ok, do: File.rm(tmp), else: :ok
  end

  defp temp_suffix, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

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
