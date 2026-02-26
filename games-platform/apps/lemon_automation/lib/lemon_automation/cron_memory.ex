defmodule LemonAutomation.CronMemory do
  @moduledoc false

  alias LemonAutomation.{CronJob, CronRun}

  @default_memory_dir ".lemon/cron_memory"
  @max_prompt_chars 8_000
  @max_file_chars 24_000
  @recent_tail_chars 14_000
  @max_result_chars 2_000

  @spec memory_file(CronJob.t()) :: binary()
  def memory_file(%CronJob{} = job) do
    configured =
      normalize_string(job.memory_file) ||
        normalize_string(map_get(job.meta, :memory_file)) ||
        normalize_string(map_get(job.meta, :memoryFile))

    case configured do
      nil ->
        default_memory_file(job.id)

      path ->
        expand_path(path)
    end
  end

  @spec read_for_prompt(CronJob.t()) :: {binary(), binary() | nil}
  def read_for_prompt(%CronJob{} = job) do
    path = memory_file(job)

    text =
      case File.read(path) do
        {:ok, content} -> prompt_slice(content)
        {:error, _} -> nil
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

    Persistent memory file: #{memory_file}
    Use the memory notes below as context for continuity across runs.

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
    existing = load_existing(path, job)
    entry = render_entry(job, run, session_key, result)
    updated = compact_if_needed(existing <> "\n\n" <> entry)

    with :ok <- ensure_parent_dir(path),
         :ok <- File.write(path, updated) do
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  def append_run(_job, _run, _session_key, _result), do: :ok

  defp load_existing(path, %CronJob{} = job) do
    case File.read(path) do
      {:ok, content} when is_binary(content) and content != "" ->
        content

      _ ->
        """
        # Cron Memory: #{job.name}

        - Job ID: #{job.id}
        - Agent ID: #{job.agent_id}
        - Base Session Key: #{job.session_key}
        - Memory file created at: #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
        """
    end
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

  defp compact_if_needed(content) when is_binary(content) do
    if String.length(content) <= @max_file_chars do
      content
    else
      total_chars = String.length(content)
      removed_chars = max(total_chars - @recent_tail_chars, 0)
      tail = String.slice(content, -@recent_tail_chars, @recent_tail_chars)
      compacted_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      summary = summarize_removed_content(content, removed_chars)

      compacted = """
      # Cron Memory (Compacted)

      - compacted_at: #{compacted_at}
      - previous_size_chars: #{total_chars}
      - removed_chars: #{removed_chars}

      ## Summary Of Older Content
      #{summary}

      ## Recent Content
      #{tail}
      """

      if String.length(compacted) > @max_file_chars do
        String.slice(compacted, -@max_file_chars, @max_file_chars)
      else
        compacted
      end
    end
  end

  defp summarize_removed_content(_content, removed_chars) when removed_chars <= 0 do
    "- No truncation was needed."
  end

  defp summarize_removed_content(content, removed_chars) do
    removed = String.slice(content, 0, removed_chars)

    highlights =
      removed
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.take(6)
      |> Enum.map(fn line -> "- #{String.slice(line, 0, 140)}" end)

    case highlights do
      [] -> "- Older run history was condensed automatically."
      list -> Enum.join(list, "\n")
    end
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

  defp ensure_parent_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp default_memory_file(job_id) when is_binary(job_id) do
    root =
      case System.user_home() do
        home when is_binary(home) and home != "" -> Path.join(home, @default_memory_dir)
        _ -> Path.expand(@default_memory_dir)
      end

    Path.join(root, "#{job_id}.md")
  end

  defp expand_path(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.expand(path)
    end
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil
end
