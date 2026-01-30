defmodule CodingAgent.Tools.Patch do
  @moduledoc """
  Patch tool for the coding agent.

  Applies a unified patch format similar to apply_patch.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @doc """
  Returns the patch tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "patch",
      description: "Apply a patch describing file edits, additions, and deletions.",
      label: "Apply Patch",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "patch_text" => %{
            "type" => "string",
            "description" => "Full patch text to apply"
          }
        },
        "required" => ["patch_text"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, _opts) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      patch_text = Map.get(params, "patch_text", "")

      if patch_text == "" do
        {:error, "patch_text is required"}
      else
        with {:ok, operations} <- parse_patch(patch_text),
             {:ok, summary} <- apply_operations(operations, cwd, signal) do
          %AgentToolResult{
            content: [%TextContent{text: summary.output}],
            details: summary.details
          }
        end
      end
    end
  end

  # ============================================================================
  # Patch Parsing
  # ============================================================================

  defp parse_patch(text) do
    lines = String.split(text, ~r/\r?\n/, trim: false)
    {ops, _idx} = parse_lines(lines, 0, [])

    if ops == [] do
      {:error, "No patch operations found"}
    else
      {:ok, Enum.reverse(ops)}
    end
  end

  defp parse_lines(lines, idx, ops) do
    if idx >= length(lines) do
      {ops, idx}
    else
      line = Enum.at(lines, idx)

      cond do
        line == "*** Begin Patch" ->
          parse_lines(lines, idx + 1, ops)

        line == "*** End Patch" ->
          {ops, idx + 1}

        String.starts_with?(line, "*** Update File:") ->
          {op, next_idx} = parse_update(lines, idx)
          parse_lines(lines, next_idx, [op | ops])

        String.starts_with?(line, "*** Add File:") ->
          {op, next_idx} = parse_add(lines, idx)
          parse_lines(lines, next_idx, [op | ops])

        String.starts_with?(line, "*** Delete File:") ->
          {op, next_idx} = parse_delete(lines, idx)
          parse_lines(lines, next_idx, [op | ops])

        true ->
          parse_lines(lines, idx + 1, ops)
      end
    end
  end

  defp parse_update(lines, idx) do
    line = Enum.at(lines, idx)
    path = line |> String.replace_prefix("*** Update File:", "") |> String.trim()
    idx = idx + 1

    {move_to, idx} =
      case Enum.at(lines, idx) do
        nil ->
          {nil, idx}

        next when is_binary(next) ->
          if String.starts_with?(next, "*** Move to:") do
            move_path = next |> String.replace_prefix("*** Move to:", "") |> String.trim()
            {move_path, idx + 1}
          else
            {nil, idx}
          end

        _ ->
          {nil, idx}
      end

    {hunks, next_idx} = parse_hunks(lines, idx, [])

    {%{type: :update, path: path, move_to: move_to, hunks: Enum.reverse(hunks)}, next_idx}
  end

  defp parse_hunks(lines, idx, hunks) do
    if idx >= length(lines) do
      {hunks, idx}
    else
      line = Enum.at(lines, idx)

      cond do
        String.starts_with?(line, "***") ->
          {hunks, idx}

        String.starts_with?(line, "@@") ->
          {hunk, next_idx} = parse_hunk(lines, idx + 1, [])
          parse_hunks(lines, next_idx, [hunk | hunks])

        true ->
          parse_hunks(lines, idx + 1, hunks)
      end
    end
  end

  defp parse_hunk(lines, idx, changes) do
    if idx >= length(lines) do
      {%{changes: Enum.reverse(changes)}, idx}
    else
      line = Enum.at(lines, idx)

      cond do
        String.starts_with?(line, "@@") or String.starts_with?(line, "***") ->
          {%{changes: Enum.reverse(changes)}, idx}

        String.starts_with?(line, " ") ->
          content = String.slice(line, 1..-1//1)
          parse_hunk(lines, idx + 1, [%{type: :keep, content: content} | changes])

        String.starts_with?(line, "-") ->
          content = String.slice(line, 1..-1//1)
          parse_hunk(lines, idx + 1, [%{type: :remove, content: content} | changes])

        String.starts_with?(line, "+") ->
          content = String.slice(line, 1..-1//1)
          parse_hunk(lines, idx + 1, [%{type: :add, content: content} | changes])

        true ->
          parse_hunk(lines, idx + 1, changes)
      end
    end
  end

  defp parse_add(lines, idx) do
    line = Enum.at(lines, idx)
    path = line |> String.replace_prefix("*** Add File:", "") |> String.trim()

    {content_lines, next_idx} = parse_add_lines(lines, idx + 1, [])
    content = Enum.join(content_lines, "\n")

    {%{type: :add, path: path, content: content}, next_idx}
  end

  defp parse_add_lines(lines, idx, acc) do
    if idx >= length(lines) do
      {Enum.reverse(acc), idx}
    else
      line = Enum.at(lines, idx)

      if String.starts_with?(line, "***") do
        {Enum.reverse(acc), idx}
      else
        if String.starts_with?(line, "+") do
          content = String.slice(line, 1..-1//1)
          parse_add_lines(lines, idx + 1, [content | acc])
        else
          parse_add_lines(lines, idx + 1, acc)
        end
      end
    end
  end

  defp parse_delete(lines, idx) do
    line = Enum.at(lines, idx)
    path = line |> String.replace_prefix("*** Delete File:", "") |> String.trim()
    {%{type: :delete, path: path}, idx + 1}
  end

  # ============================================================================
  # Patch Application
  # ============================================================================

  defp apply_operations(operations, cwd, signal) do
    result =
      Enum.reduce_while(operations, %{changed: [], additions: 0, removals: 0}, fn op, acc ->
        if AbortSignal.aborted?(signal) do
          {:halt, {:error, "Operation aborted"}}
        else
          case apply_operation(op, cwd, signal) do
            {:ok, info} ->
              updated = %{
                changed: acc.changed ++ info.changed,
                additions: acc.additions + info.additions,
                removals: acc.removals + info.removals
              }

              {:cont, updated}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end
      end)

    case result do
      {:error, reason} ->
        {:error, reason}

      %{changed: changed, additions: adds, removals: removes} ->
        output =
          "Patch applied successfully. #{length(changed)} files changed, #{adds} additions, #{removes} removals"

        {:ok,
         %{
           output: output,
           details: %{changed: changed, additions: adds, removals: removes}
         }}
    end
  end

  defp apply_operation(%{type: :add, path: path, content: content}, cwd, signal) do
    resolved = resolve_path(path, cwd)

    with :ok <- check_abort(signal),
         :ok <- ensure_parent_dir(resolved),
         {:ok, false} <- file_exists?(resolved),
         :ok <- File.write(resolved, content) do
      additions = count_lines(content)
      {:ok, %{changed: [resolved], additions: additions, removals: 0}}
    else
      {:ok, true} -> {:error, "File already exists: #{resolved}"}
      {:error, reason} -> {:error, format_error(reason, resolved)}
    end
  end

  defp apply_operation(%{type: :delete, path: path}, cwd, signal) do
    resolved = resolve_path(path, cwd)

    with :ok <- check_abort(signal),
         {:ok, true} <- file_exists?(resolved),
         {:ok, content} <- File.read(resolved),
         :ok <- File.rm(resolved) do
      removals = count_lines(content)
      {:ok, %{changed: [resolved], additions: 0, removals: removals}}
    else
      {:ok, false} -> {:error, "File not found: #{resolved}"}
      {:error, reason} -> {:error, format_error(reason, resolved)}
    end
  end

  defp apply_operation(%{type: :update, path: path, move_to: move_to, hunks: hunks}, cwd, signal) do
    resolved = resolve_path(path, cwd)
    target = if move_to, do: resolve_path(move_to, cwd), else: resolved

    with :ok <- check_abort(signal),
         {:ok, true} <- file_exists?(resolved),
         {:ok, content} <- File.read(resolved),
         {:ok, new_content, adds, removes} <- apply_hunks(content, hunks),
         :ok <- ensure_parent_dir(target),
         :ok <- File.write(target, new_content) do
      if target != resolved do
        _ = File.rm(resolved)
      end

      {:ok, %{changed: [target], additions: adds, removals: removes}}
    else
      {:ok, false} -> {:error, "File not found: #{resolved}"}
      {:error, reason} -> {:error, format_error(reason, resolved)}
    end
  end

  defp apply_hunks(content, hunks) do
    lines = String.split(content, ~r/\r?\n/, trim: false)
    newline = if String.contains?(content, "\r\n"), do: "\r\n", else: "\n"

    result =
      Enum.reduce_while(hunks, {lines, 0, 0}, fn hunk, {acc_lines, acc_adds, acc_removes} ->
        case apply_hunk(acc_lines, hunk) do
          {:ok, new_lines, adds, removes} ->
            {:cont, {new_lines, acc_adds + adds, acc_removes + removes}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:error, reason} ->
        {:error, reason}

      {updated_lines, adds, removes} ->
        {:ok, Enum.join(updated_lines, newline), adds, removes}
    end
  end

  defp apply_hunk(lines, %{changes: changes}) do
    pattern =
      changes
      |> Enum.filter(fn change -> change.type in [:keep, :remove] end)
      |> Enum.map(& &1.content)

    start_idx = find_pattern(lines, pattern)

    if start_idx == nil do
      {:error, "Context not found for patch hunk"}
    else
      do_apply_changes(lines, changes, start_idx)
    end
  end

  defp do_apply_changes(lines, changes, start_idx) do
    Enum.reduce_while(changes, {lines, start_idx, 0, 0}, fn change,
                                                           {acc_lines, idx, adds, removes} ->
      case change.type do
        :keep ->
          {:cont, {acc_lines, idx + 1, adds, removes}}

        :remove ->
          if idx >= length(acc_lines) do
            {:halt, {:error, "Patch remove out of bounds"}}
          else
            {:cont, {List.delete_at(acc_lines, idx), idx, adds, removes + 1}}
          end

        :add ->
          {:cont, {List.insert_at(acc_lines, idx, change.content), idx + 1, adds + 1, removes}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, reason}
      {final_lines, _idx, adds, removes} -> {:ok, final_lines, adds, removes}
    end
  end

  defp find_pattern(lines, pattern) do
    plen = length(pattern)

    cond do
      plen == 0 ->
        length(lines)

      length(lines) < plen ->
        nil

      true ->
        0..(length(lines) - plen)
        |> Enum.find(fn idx -> Enum.slice(lines, idx, plen) == pattern end)
    end
  end

  defp resolve_path(path, cwd) do
    expanded = expand_home(path)

    if Path.type(expanded) == :absolute do
      expanded
    else
      Path.join(cwd, expanded) |> Path.expand()
    end
  end

  defp expand_home("~" <> rest), do: Path.expand("~") <> rest
  defp expand_home(path), do: path

  defp ensure_parent_dir(path) do
    dir = Path.dirname(path)
    File.mkdir_p(dir)
  end

  defp file_exists?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, true}
      {:ok, _} -> {:error, "Path is not a regular file: #{path}"}
      {:error, :enoent} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp count_lines(text) when is_binary(text) do
    text
    |> String.split(~r/\r?\n/, trim: false)
    |> length()
  end

  defp check_abort(nil), do: :ok

  defp check_abort(signal) when is_reference(signal) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      :ok
    end
  end

  defp format_error(reason, _path) when is_binary(reason), do: reason
  defp format_error(reason, path), do: "Failed to apply patch for #{path}: #{inspect(reason)}"
end
