defmodule CodingAgent.Tools.Conflicts do
  @moduledoc "Indexes Git conflict regions and resolves registered regions through the write tool."

  alias CodingAgent.{ConflictStore, FileReadTracker, MutationLock}
  alias CodingAgent.Tools.{ACPFileBridge, FileValidation, PathHelpers}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @max_bytes 4 * 1024 * 1024

  def read(path, cwd, opts) do
    path = PathHelpers.resolve_path(path, cwd, opts)

    with {:ok, scope} <- scope(opts),
         :ok <- local_only(opts),
         {:ok, content} <- read_content(path),
         {:ok, regions} <- scan(content) do
      FileReadTracker.record(opts, path, content)
      entries = ConflictStore.register(scope, path, digest(content), regions, opts[:session_pid])

      lines =
        Enum.map(entries, fn {id, %{region: region}} ->
          "##{id} L#{region.first}-L#{region.last} ours: #{preview(region.ours)} | theirs: #{preview(region.theirs)}"
        end)

      text = if lines == [], do: "(no unresolved conflicts)", else: Enum.join(lines, "\n")
      {text, truncated, _} = CodingAgent.BashExecutor.truncate_tail(text, max_bytes: 50_000)

      %AgentToolResult{
        content: [%TextContent{text: text}],
        details: %{path: path, conflict_count: length(entries), truncated: truncated}
      }
    end
  end

  def replace(reference, body, cwd, opts, write) when is_binary(body) do
    with {:ok, scope} <- scope(opts),
         :ok <- local_only(opts),
         {:ok, id} <- parse_id(reference),
         {:ok, block} <- ConflictStore.fetch(scope, id) do
      MutationLock.with_lock(MutationLock.path_key(block.path), fn ->
        with {:ok, current} <- read_content(block.path),
             :ok <- check_digest(scope, block, current),
             :ok <- FileValidation.check_text_content(body, "content") do
          region = block.region
          replacement = expand(body, region)

          content =
            binary_part(current, 0, region.offset) <>
              replacement <>
              binary_part(current, region.end_offset, byte_size(current) - region.end_offset)

          result = write.(block.path, content, cwd, opts)

          if match?(%AgentToolResult{is_error: false}, result),
            do: ConflictStore.invalidate(scope, block.path)

          result
        end
      end)
    end
  end

  def replace(_reference, _body, _cwd, _opts, _write), do: {:error, "content must be a string"}

  defp read_content(path) do
    with {:ok, _} <- FileValidation.check_path_access(path),
         {:ok, content} <- File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)) do
      cond do
        content == :eof ->
          {:ok, ""}

        not is_binary(content) ->
          {:error, "Failed to read conflict file"}

        byte_size(content) > @max_bytes ->
          {:error, "Conflict files must be at most 4 MiB"}

        true ->
          with :ok <- FileValidation.check_text_content(content, "conflict file"),
               do: {:ok, content}
      end
    end
  end

  defp check_digest(scope, block, content) do
    if digest(content) == block.digest do
      :ok
    else
      ConflictStore.invalidate(scope, block.path)
      {:error, "Conflict id is stale; file changed. Re-read #{block.path}:conflicts"}
    end
  end

  defp scope(opts) do
    case opts[:session_id] do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, "Conflict references require session_id"}
    end
  end

  defp local_only(opts) do
    if ACPFileBridge.read_enabled?(opts) or ACPFileBridge.write_enabled?(opts),
      do: {:error, "Conflict references require local files, not ACP client buffers"},
      else: :ok
  end

  defp parse_id(reference) do
    case Integer.parse(reference) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, "Malformed conflict id; use conflict://N from path:conflicts"}
    end
  end

  defp digest(content), do: :crypto.hash(:sha256, content)

  defp preview(side),
    do: side |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, 120) |> inspect()

  defp expand(body, region) do
    Regex.replace(~r/^@(ours|theirs|base|both)(?:\r?\n|$)/m, body, fn _, side ->
      case side do
        "ours" -> region.ours
        "theirs" -> region.theirs
        "base" -> region.base
        "both" -> region.ours <> region.theirs
      end
    end)
  end

  defp scan(content) do
    lines = Regex.scan(~r/[^\n]*(?:\n|$)/, content) |> List.flatten() |> Enum.reject(&(&1 == ""))
    initial = %{offset: 0, line: 1, current: nil, regions: []}

    Enum.reduce_while(lines, {:ok, initial}, fn line, {:ok, state} ->
      case scan_line(line, state) do
        {:ok, next} ->
          {:cont, {:ok, %{next | offset: state.offset + byte_size(line), line: state.line + 1}}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, %{current: nil, regions: regions}} -> {:ok, Enum.reverse(regions)}
      {:ok, _} -> {:error, "Unterminated conflict markers"}
      error -> error
    end
  end

  defp scan_line(line, state) do
    marker = marker(line)

    case {marker, state.current} do
      {:ours, nil} ->
        offset =
          state.offset + if(String.starts_with?(line, <<0xEF, 0xBB, 0xBF>>), do: 3, else: 0)

        {:ok,
         %{
           state
           | current: %{
               offset: offset,
               first: state.line,
               phase: :ours,
               ours: [],
               base: [],
               theirs: []
             }
         }}

      {:base, %{phase: :ours} = region} ->
        {:ok, %{state | current: %{region | phase: :base}}}

      {:divider, %{phase: phase} = region} when phase in [:ours, :base] ->
        {:ok, %{state | current: %{region | phase: :theirs}}}

      {:end, %{phase: :theirs} = region} ->
        region =
          region
          |> Map.drop([:phase])
          |> Map.merge(%{
            last: state.line,
            end_offset: state.offset + byte_size(line),
            ours: side(region.ours),
            base: side(region.base),
            theirs: side(region.theirs)
          })

        {:ok, %{state | current: nil, regions: [region | state.regions]}}

      {_marker, nil} ->
        {:ok, state}

      {nil, region} ->
        {:ok, %{state | current: Map.update!(region, region.phase, &[line | &1])}}

      _ ->
        {:error, "Malformed conflict markers at line #{state.line}"}
    end
  end

  defp side(lines), do: lines |> Enum.reverse() |> IO.iodata_to_binary()

  defp marker(line) do
    cond do
      Regex.match?(~r/\A(?:\x{FEFF})?<<<<<<<(?:[ \t]|\r?\n|\z)/u, line) -> :ours
      Regex.match?(~r/\A\|\|\|\|\|\|\|(?:[ \t]|\r?\n|\z)/, line) -> :base
      Regex.match?(~r/\A=======\r?(?:\n|\z)/, line) -> :divider
      Regex.match?(~r/\A>>>>>>>(?:[ \t]|\r?\n|\z)/, line) -> :end
      true -> nil
    end
  end
end
