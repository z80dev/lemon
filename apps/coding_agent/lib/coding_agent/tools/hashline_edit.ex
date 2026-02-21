defmodule CodingAgent.Tools.HashlineEdit do
  @moduledoc """
  Hashline Edit tool for the coding agent.

  Uses line-addressable editing with xxHash32-compatible content hashes for
  staleness detection. Each line is identified by `LINENUM#HASH`, preventing
  stale edits by validating hashes before any mutation.

  Ported from oh-my-pi's hashline edit mode.

  ## Supported Operations

  - `set` - Replace a single line by reference
  - `replace` - Replace a range of lines (first to last)
  - `append` - Insert after a line (or at EOF if no anchor)
  - `prepend` - Insert before a line (or at BOF if no anchor)
  - `insert` - Insert between two anchor lines

  ## Edit Format

  Each edit is a JSON object with:
  - `op` - Operation name (set, replace, append, prepend, insert)
  - `tag` / `first` / `last` / `after` / `before` - Line references as `"LINE#HASH"`
  - `content` - Array of replacement/insertion lines
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.Hashline
  alias CodingAgent.Tools.Hashline.HashlineMismatchError

  @doc """
  Returns the tool definition for the hashline_edit tool.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "hashline_edit",
      description:
        "Edit a file using line-addressable edits with hash-based staleness detection. " <>
          "Each line is referenced by LINENUM#HASH (e.g. \"5#ZZ\"). " <>
          "Supports: set (replace line), replace (replace range), append (insert after), " <>
          "prepend (insert before), insert (between two lines).",
      label: "Hashline Edit",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "The path to the file to edit"
          },
          "edits" => %{
            "type" => "array",
            "description" => "Array of hashline edit operations",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "op" => %{
                  "type" => "string",
                  "enum" => ["set", "replace", "append", "prepend", "insert"],
                  "description" => "The edit operation"
                },
                "tag" => %{
                  "type" => "string",
                  "description" => "Line reference for set op (e.g. \"5#ZZ\")"
                },
                "first" => %{
                  "type" => "string",
                  "description" => "Start line reference for replace op"
                },
                "last" => %{
                  "type" => "string",
                  "description" => "End line reference for replace op"
                },
                "after" => %{
                  "type" => "string",
                  "description" => "Line reference for append/insert op anchor"
                },
                "before" => %{
                  "type" => "string",
                  "description" => "Line reference for prepend/insert op anchor"
                },
                "content" => %{
                  "type" => "array",
                  "items" => %{"type" => "string"},
                  "description" => "Lines of content for the edit"
                }
              },
              "required" => ["op", "content"]
            }
          }
        },
        "required" => ["path", "edits"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute the hashline_edit tool.
  """
  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t(),
          keyword()
        ) :: AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      do_execute(params, signal, cwd, opts)
    end
  end

  defp do_execute(params, signal, cwd, opts) do
    path = params["path"]
    raw_edits = params["edits"]

    with :ok <- validate_params(path, raw_edits),
         :ok <- check_aborted(signal),
         resolved_path <- resolve_path(path, cwd, opts),
         :ok <- check_file_access(resolved_path),
         {:ok, raw_content} <- File.read(resolved_path),
         {bom, content} <- strip_bom(raw_content),
         line_ending <- detect_line_ending(content),
         normalized <- normalize_to_lf(content),
         {:ok, edits} <- parse_edits(raw_edits),
         {:ok, result} <- Hashline.apply_edits(normalized, edits),
         :ok <- check_aborted(signal),
         final_content <- finalize_content(result.content, line_ending, bom),
         :ok <- File.write(resolved_path, final_content) do
      noop_count = if result.noop_edits, do: length(result.noop_edits), else: 0
      applied_count = length(edits) - noop_count

      summary =
        "Applied #{applied_count} hashline edit(s) to #{path}" <>
          if(noop_count > 0, do: " (#{noop_count} no-op)", else: "") <>
          if(result.first_changed_line,
            do: ", first change at line #{result.first_changed_line}",
            else: ""
          )

      %AgentToolResult{
        content: [%TextContent{type: :text, text: summary}],
        details: %{
          first_changed_line: result.first_changed_line,
          noop_edits: result.noop_edits,
          edits_applied: applied_count
        }
      }
    else
      {:error, %HashlineMismatchError{} = error} ->
        {:error, error.message}

      {:error, :enoent} ->
        {:error, "File not found: #{path}"}

      {:error, :eacces} ->
        {:error, "Permission denied: #{path}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "Failed to apply hashline edits: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Param Validation & Parsing
  # ============================================================================

  defp validate_params(nil, _), do: {:error, "Missing required parameter: path"}
  defp validate_params(_, nil), do: {:error, "Missing required parameter: edits"}
  defp validate_params(_, []), do: {:error, "Edits array cannot be empty"}
  defp validate_params(_, edits) when not is_list(edits), do: {:error, "edits must be an array"}
  defp validate_params(_, _), do: :ok

  @doc """
  Parse raw JSON edit maps into internal hashline edit structs.
  """
  @spec parse_edits([map()]) :: {:ok, [Hashline.edit()]} | {:error, String.t()}
  def parse_edits(raw_edits) do
    result =
      Enum.reduce_while(raw_edits, {:ok, []}, fn raw, {:ok, acc} ->
        case parse_single_edit(raw) do
          {:ok, edit} -> {:cont, {:ok, [edit | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, edits} -> {:ok, Enum.reverse(edits)}
      error -> error
    end
  end

  defp parse_single_edit(%{"op" => "set"} = raw) do
    with {:ok, tag} <- parse_tag_field(raw, "tag") do
      {:ok, %{op: :set, tag: tag, content: parse_content(raw)}}
    end
  end

  defp parse_single_edit(%{"op" => "replace"} = raw) do
    with {:ok, first} <- parse_tag_field(raw, "first"),
         {:ok, last} <- parse_tag_field(raw, "last") do
      {:ok, %{op: :replace, first: first, last: last, content: parse_content(raw)}}
    end
  end

  defp parse_single_edit(%{"op" => "append"} = raw) do
    after_tag = parse_optional_tag(raw, "after")
    {:ok, %{op: :append, after: after_tag, content: parse_content(raw)}}
  end

  defp parse_single_edit(%{"op" => "prepend"} = raw) do
    before_tag = parse_optional_tag(raw, "before")
    {:ok, %{op: :prepend, before: before_tag, content: parse_content(raw)}}
  end

  defp parse_single_edit(%{"op" => "insert"} = raw) do
    with {:ok, after_tag} <- parse_tag_field(raw, "after"),
         {:ok, before_tag} <- parse_tag_field(raw, "before") do
      {:ok, %{op: :insert, after: after_tag, before: before_tag, content: parse_content(raw)}}
    end
  end

  defp parse_single_edit(%{"op" => op}), do: {:error, "Unknown edit operation: #{op}"}
  defp parse_single_edit(_), do: {:error, "Edit missing required 'op' field"}

  defp parse_tag_field(raw, field) do
    case Map.get(raw, field) do
      nil -> {:error, "Missing required field '#{field}' for #{raw["op"]} edit"}
      ref when is_binary(ref) ->
        try do
          {:ok, Hashline.parse_tag(ref)}
        rescue
          ArgumentError -> {:error, "Invalid tag reference in '#{field}': #{ref}"}
        end
      _ -> {:error, "Field '#{field}' must be a string"}
    end
  end

  defp parse_optional_tag(raw, field) do
    case Map.get(raw, field) do
      nil -> nil
      ref when is_binary(ref) ->
        try do
          Hashline.parse_tag(ref)
        rescue
          ArgumentError -> nil
        end
      _ -> nil
    end
  end

  defp parse_content(raw) do
    case Map.get(raw, "content", []) do
      lines when is_list(lines) -> Enum.map(lines, &to_string/1)
      _ -> []
    end
  end

  # ============================================================================
  # File Helpers
  # ============================================================================

  defp check_aborted(nil), do: :ok

  defp check_aborted(signal) when is_reference(signal) do
    if AbortSignal.aborted?(signal), do: {:error, "Operation aborted"}, else: :ok
  end

  defp check_aborted(_), do: :ok

  defp resolve_path(path, cwd, _opts) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(cwd, path) |> Path.expand()
    end
  end

  defp check_file_access(path) do
    case File.stat(path) do
      {:ok, %File.Stat{access: access}} when access in [:read_write, :write] -> :ok
      {:ok, %File.Stat{}} -> {:error, :eacces}
      {:error, reason} -> {:error, reason}
    end
  end

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: {@utf8_bom, rest}
  defp strip_bom(content), do: {nil, content}

  defp detect_line_ending(content) do
    if String.contains?(content, "\r\n"), do: "\r\n", else: "\n"
  end

  defp normalize_to_lf(text), do: String.replace(text, "\r\n", "\n")

  defp finalize_content(content, "\r\n", bom) do
    restored = content |> String.replace("\r\n", "\n") |> String.replace("\n", "\r\n")
    case bom do
      nil -> restored
      b -> b <> restored
    end
  end

  defp finalize_content(content, _, nil), do: content
  defp finalize_content(content, _, bom), do: bom <> content
end
