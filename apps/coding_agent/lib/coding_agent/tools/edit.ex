defmodule CodingAgent.Tools.Edit do
  @moduledoc """
  Snapshot-anchored line editing and unique text replacement.

  Prefer `path`, `snapshot`, and `edits`: copy the tag from `read` and describe
  inclusive 1-based original line ranges, without reproducing `old_text`.
  All edits are preflighted against one complete-file snapshot. Supported
  operations are `replace`, `insert_before`, `insert_after`, and `delete`.
  Disjoint edits may share a call; changed snapshots or overlapping ranges
  fail without writing. Whole-line replacement text may omit its final LF.

  Alternatively, `old_text` and `new_text` replace one unique text occurrence.

  ## Matching

  1. Exact byte match. Exactly one occurrence is required.
  2. If there is no exact match, a line-based match: file lines and
     `old_text` lines are compared after trimming, collapsing runs of
     whitespace, and folding smart quotes/unicode dashes to ASCII. The first
     and last `old_text` lines may match a suffix/prefix of a file line;
     interior lines must match whole lines. The replaced span is the matching
     span of the ORIGINAL file, so indentation differences and multibyte
     characters never shift it.

  More than one candidate (exact or line-based) is an error that lists the
  matching line numbers.

  ## Safety

  - Edits of one file are serialized (`CodingAgent.MutationLock`), so two
    concurrent edits of the same file both apply.
  - When the session has read the file, the edit is refused if the file
    changed on disk since that read (`CodingAgent.FileReadTracker`).
  - UTF-8 BOM, CRLF/LF line endings, and the trailing newline are preserved.
  - Binary data (invalid UTF-8 or NUL bytes) is rejected before matching.

  Successful results include the absolute `path` and complete `oldText`/`newText`
  snapshots only when both are at most 16 KiB. Otherwise both snapshots are
  omitted; the existing diff and first changed line remain available.
  """

  require Logger

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias CodingAgent.FileReadTracker
  alias CodingAgent.MutationLock
  alias CodingAgent.Tools.ACPFileBridge
  alias CodingAgent.Tools.AnchoredEdit
  alias CodingAgent.Tools.CheckpointGuard
  alias CodingAgent.Tools.FileFormatHelpers
  alias CodingAgent.Tools.FileValidation
  alias CodingAgent.Tools.LspDiagnostics
  alias CodingAgent.Tools.PathHelpers

  import LemonAgent.Tools.AbortHelpers, only: [aborted?: 1, check_aborted: 1]

  @doc """
  Returns the tool definition for the edit tool.

  ## Parameters

    - `cwd` - Current working directory for resolving relative paths
    - `opts` - Optional configuration (reserved for future use)
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "edit",
      description:
        "Edit a text file. Prefer snapshot-anchored line edits after read: copy its snapshot tag and " <>
          "send edits [{start_line, end_line, new_text, operation}]. Lines are 1-based and inclusive; " <>
          "every edit uses the ORIGINAL read snapshot. operation is replace (default), insert_before, " <>
          "insert_after, or delete. No old text is needed. Re-read if the snapshot changed. " <>
          "Alternatively supply unique old_text and new_text for text matching.",
      label: "Edit File",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "The path to the file to edit"},
          "old_text" => %{
            "type" => "string",
            "description" => "The exact text to find and replace (must be unique in the file)"
          },
          "new_text" => %{"type" => "string", "description" => "The replacement text"},
          "snapshot" => %{
            "type" => "string",
            "description" => "Copy the 16-character file tag from read's [path#SNAPSHOT] header",
            "pattern" => "^[0-9A-Fa-f]{16}$"
          },
          "edits" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 100,
            "description" =>
              "Non-overlapping edits using original read line numbers. Replacement/insertion new_text contains whole lines; a final newline is optional. Original file line endings/final newline are preserved.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "operation" => %{
                  "type" => "string",
                  "enum" => ["replace", "insert_before", "insert_after", "delete"]
                },
                "start_line" => %{"type" => "integer", "minimum" => 1},
                "end_line" => %{
                  "type" => "integer",
                  "minimum" => 1,
                  "description" =>
                    "Inclusive final line; defaults to start_line. Insertions target just start_line."
                },
                "new_text" => %{
                  "type" => "string",
                  "description" => "Whole replacement/inserted lines; omitted for delete"
                }
              },
              "required" => ["start_line"]
            }
          },
          "diagnostics" => %{
            "type" => "boolean",
            "default" => Keyword.get(opts, :diagnostics, false),
            "description" =>
              "Whether to run language diagnostics after editing and report newly introduced issues"
          }
        },
        "required" => ["path"],
        "anyOf" => [
          %{"required" => ["snapshot", "edits"]},
          %{"required" => ["old_text", "new_text"]}
        ]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute the edit tool.

  Replaces exact text in a file, handling BOM, line endings, and fuzzy matching.
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
    if aborted?(signal) do
      {:error, "Operation aborted"}
    else
      path = params["path"]

      # Parameter validation
      result =
        with :ok <- validate_required_param(path, "path"),
             {:ok, edit_spec} <- build_edit_spec(params),
             {:ok, diagnostics?} <- LspDiagnostics.option(params, opts) do
          do_execute(path, edit_spec, diagnostics?, signal, cwd, opts)
        end

      case result do
        {:error, :aborted} -> {:error, "Operation aborted"}
        other -> LemonAgent.Security.ToolResultTrust.untrusted(other, :local_file)
      end
    end
  end

  defp do_execute(path, edit_spec, diagnostics?, signal, cwd, opts) do
    resolved_path = resolve_path(path, cwd, opts)

    if ACPFileBridge.read_enabled?(opts) and ACPFileBridge.write_enabled?(opts) do
      do_execute_acp(path, resolved_path, edit_spec, signal, opts)
    else
      do_execute_local(path, resolved_path, edit_spec, diagnostics?, signal, cwd, opts)
    end
  end

  defp do_execute_acp(path, resolved_path, edit_spec, signal, opts) do
    with :ok <- check_aborted(signal),
         {:ok, raw_content} <- ACPFileBridge.read_text_file(resolved_path, nil, nil, opts),
         :ok <- FileValidation.check_text_content(raw_content, path),
         {bom, content} <- FileFormatHelpers.strip_bom(raw_content),
         line_ending <- FileFormatHelpers.detect_line_ending(content),
         normalized_content <- FileFormatHelpers.normalize_to_lf(content),
         {:ok, new_content} <- perform_edit(raw_content, normalized_content, edit_spec),
         :ok <- check_content_changed(normalized_content, new_content),
         :ok <- check_aborted(signal),
         final_content <- FileFormatHelpers.finalize_content(new_content, line_ending, bom),
         :ok <- ACPFileBridge.write_text_file(resolved_path, final_content, opts) do
      diff = generate_diff(normalized_content, new_content)
      first_changed_line = find_first_changed_line(normalized_content, new_content)
      snapshot = AnchoredEdit.snapshot(final_content)

      %AgentToolResult{
        content: [
          %TextContent{
            type: :text,
            text:
              "Successfully replaced text in #{path}.\n\n[#{resolved_path}##{snapshot}]\n#{diff}"
          }
        ],
        details:
          %{diff: diff, first_changed_line: first_changed_line, acp_client: true}
          |> FileValidation.put_text_snapshots(resolved_path, raw_content, final_content)
          |> Map.put(:snapshot, snapshot)
      }
    else
      error -> format_error(error, path)
    end
  end

  defp do_execute_local(path, resolved_path, edit_spec, diagnostics?, signal, cwd, opts) do
    MutationLock.with_lock(MutationLock.path_key(resolved_path), fn ->
      edit_local(path, resolved_path, edit_spec, diagnostics?, signal, cwd, opts)
    end)
  end

  defp edit_local(path, resolved_path, edit_spec, diagnostics?, signal, cwd, opts) do
    baseline = LspDiagnostics.baseline(resolved_path, cwd, diagnostics?, opts)

    with :ok <- check_aborted(signal),
         :ok <-
           FileValidation.check_mutation_target(
             resolved_path,
             Keyword.put(opts, :mutation_root, cwd)
           ),
         {:ok, raw_content} <- File.read(resolved_path),
         :ok <- FileValidation.check_text_content(raw_content, path),
         :ok <- FileReadTracker.check(opts, resolved_path, raw_content),
         {bom, content} <- FileFormatHelpers.strip_bom(raw_content),
         line_ending <- FileFormatHelpers.detect_line_ending(content),
         normalized_content <- FileFormatHelpers.normalize_to_lf(content),
         {:ok, new_content} <- perform_edit(raw_content, normalized_content, edit_spec),
         :ok <- check_content_changed(normalized_content, new_content),
         :ok <- check_aborted(signal),
         final_content <- FileFormatHelpers.finalize_content(new_content, line_ending, bom),
         {:ok, checkpoint} <-
           CheckpointGuard.before_mutation([resolved_path], cwd, opts, %{
             tool: "edit",
             action: "replace",
             path: resolved_path
           }),
         :ok <- File.write(resolved_path, final_content) do
      digest = :erlang.md5(final_content)
      FileReadTracker.record_digest(opts, resolved_path, digest)
      snapshot = AnchoredEdit.snapshot_for_digest(digest)
      diff = generate_diff(normalized_content, new_content)
      first_changed_line = find_first_changed_line(normalized_content, new_content)

      {diagnostics, diagnostics_text} =
        LspDiagnostics.post_edit(resolved_path, cwd, baseline, diagnostics?, opts)

      %AgentToolResult{
        content: [
          %TextContent{
            type: :text,
            text:
              "Successfully replaced text in #{path}.\n\n[#{resolved_path}##{snapshot}]\n#{diff}#{diagnostics_text}"
          }
        ],
        details:
          %{diff: diff, first_changed_line: first_changed_line}
          |> CheckpointGuard.put_details(checkpoint)
          |> FileValidation.put_text_snapshots(resolved_path, raw_content, final_content)
          |> Map.put(:snapshot, snapshot)
          |> maybe_put_diagnostics(diagnostics)
      }
    else
      error -> format_error(error, path)
    end
  end

  defp build_edit_spec(params) do
    if not is_nil(params["snapshot"]) or not is_nil(params["edits"]) do
      if not is_nil(params["old_text"]) or not is_nil(params["new_text"]) do
        {:error,
         "Choose snapshot + edits OR old_text + new_text; anchored replacements put new_text inside each edit."}
      else
        with :ok <- AnchoredEdit.validate(params["snapshot"], params["edits"]) do
          {:ok, {:anchored, params["snapshot"], params["edits"]}}
        end
      end
    else
      with :ok <- validate_required_param(params["old_text"], "old_text"),
           :ok <- validate_required_param(params["new_text"], "new_text"),
           :ok <- validate_old_text(params["old_text"]) do
        {:ok, {:text, params["old_text"], params["new_text"]}}
      end
    end
  end

  defp perform_edit(raw_content, content, {:anchored, snapshot, edits}) do
    AnchoredEdit.apply(raw_content, content, snapshot, edits)
  end

  defp perform_edit(_raw_content, content, {:text, old_text, new_text}) do
    normalized_old_text = FileFormatHelpers.normalize_to_lf(old_text)

    with {:ok, index, length} <- find_match(content, normalized_old_text) do
      perform_replacement(content, index, length, new_text)
    end
  end

  defp format_error({:error, :enoent}, path), do: {:error, "File not found: #{path}"}
  defp format_error({:error, :eacces}, path), do: {:error, "Permission denied: #{path}"}

  defp format_error({:error, :stale}, path) do
    {:error,
     "#{path} has been modified on disk since you last read it (by the user, a formatter, " <>
       "or a command). Re-read the file before editing it."}
  end

  defp format_error({:error, :not_found}, _path) do
    {:error,
     "Could not find the exact text to replace. The text must match exactly " <>
       "(or match whole lines ignoring indentation and whitespace). " <>
       "Re-read the file and copy old_text from it."}
  end

  defp format_error({:error, {:multiple_occurrences, count, lines, more?}}, _path) do
    listed = Enum.map_join(lines, ", ", &Integer.to_string/1)
    listed = if more?, do: listed <> ", ...", else: listed

    {:error,
     "Found #{count} occurrences of the text (at lines #{listed}). " <>
       "The text to replace must be unique: include more surrounding lines in old_text."}
  end

  defp format_error({:error, :no_change}, _path),
    do: {:error, "No changes made. The replacement produces identical content."}

  defp format_error({:error, :aborted}, _path), do: {:error, "Operation aborted"}
  defp format_error({:error, reason}, _path) when is_binary(reason), do: {:error, reason}

  defp format_error({:error, reason}, _path) do
    Logger.warning("Failed to edit file: #{inspect(reason)}")

    {:error,
     "Failed to edit file. Re-read the file and check write permissions before trying again."}
  end

  defp maybe_put_diagnostics(details, nil), do: details

  defp maybe_put_diagnostics(details, diagnostics),
    do: Map.put(details, :diagnostics, diagnostics)

  # ============================================================================
  # Parameter Validation
  # ============================================================================

  @spec validate_required_param(any(), String.t()) :: :ok | {:error, String.t()}
  defp validate_required_param(nil, param_name) do
    {:error, "Missing required parameter: #{param_name}"}
  end

  defp validate_required_param(value, param_name) when is_binary(value) do
    FileValidation.check_text_content(value, param_name)
  end

  defp validate_required_param(_value, param_name),
    do: {:error, "#{param_name} must be a string"}

  defp validate_old_text(""), do: {:error, "old_text must not be empty"}
  defp validate_old_text(_old_text), do: :ok

  # ============================================================================
  # Path Resolution
  # ============================================================================

  @spec resolve_path(String.t(), String.t(), keyword()) :: String.t()
  defp resolve_path(path, cwd, opts), do: PathHelpers.resolve_path(path, cwd, opts)

  # ============================================================================
  # File Access
  # ============================================================================

  # ============================================================================
  # Text Matching
  # ============================================================================

  @max_reported_lines 10

  # Smart quotes and unicode dashes fold to ASCII for line-based matching.
  # Left/right single quote, single high-reversed-9 quote, prime, reversed prime
  @single_quotes [0x2018, 0x2019, 0x201B, 0x2032, 0x2035]
  # Left/right double quote, double low-9 / high-reversed-9 quote, (reversed) double prime
  @double_quotes [0x201C, 0x201D, 0x201E, 0x201F, 0x2033, 0x2036]
  # En dash, em dash, horizontal bar, minus sign
  @dashes [0x2013, 0x2014, 0x2015, 0x2212]
  # Collapsed to a single space; trimmed at line edges
  @horizontal_space [?\s, ?\t, ?\r, ?\f, ?\v, 0x00A0]

  @typep match_result ::
           {:ok, non_neg_integer(), non_neg_integer()}
           | {:error, :not_found}
           | {:error, {:multiple_occurrences, pos_integer(), [pos_integer()], boolean()}}

  # Returns the byte index and byte length of the unique match in `content`.
  @spec find_match(String.t(), String.t()) :: match_result()
  defp find_match(content, search_text) do
    case overlapping_matches(content, search_text) do
      [{index, length}] -> {:ok, index, length}
      [] -> find_line_match(content, search_text)
      matches -> multiple_occurrences(content, Enum.map(matches, &elem(&1, 0)))
    end
  end

  # :binary.matches/2 skips overlapping matches (e.g. "aa" in "aaa").
  # Advance one byte so uniqueness means every possible replacement location.
  defp overlapping_matches(content, needle), do: overlapping_matches(content, needle, 0, [])

  defp overlapping_matches(content, needle, offset, acc) do
    if offset + byte_size(needle) > byte_size(content) do
      Enum.reverse(acc)
    else
      case :binary.match(content, needle, scope: {offset, byte_size(content) - offset}) do
        :nomatch ->
          Enum.reverse(acc)

        {index, length} ->
          overlapping_matches(content, needle, index + 1, [{index, length} | acc])
      end
    end
  end

  defp multiple_occurrences(content, starts) do
    lines =
      starts
      |> Enum.take(@max_reported_lines)
      |> Enum.map(&line_number_at(content, &1))
      |> Enum.uniq()

    count = length(starts)
    {:error, {:multiple_occurrences, count, lines, count > @max_reported_lines}}
  end

  defp line_number_at(content, byte_index) do
    content
    |> binary_part(0, byte_index)
    |> :binary.matches("\n")
    |> length()
    |> Kernel.+(1)
  end

  # Line-based fallback. Every offset below is a byte offset into `content`;
  # normalized text is only ever compared, never used as a coordinate.
  defp find_line_match(content, search_text) do
    raw_search_lines = String.split(search_text, "\n")
    needles = Enum.map(raw_search_lines, &normalize_line/1)

    if Enum.all?(needles, &(&1 == "")) do
      {:error, :not_found}
    else
      lines = String.split(content, "\n")

      file = %{
        lines: List.to_tuple(lines),
        norms: lines |> Enum.map(&normalize_line/1) |> List.to_tuple(),
        starts: lines |> line_start_offsets() |> List.to_tuple()
      }

      search = %{
        needles: needles,
        leading_space?: leading_space?(List.first(raw_search_lines)),
        trailing_space?: trailing_space?(List.last(raw_search_lines))
      }

      case line_match_spans(file, search) do
        [] -> {:error, :not_found}
        [{start, stop}] -> {:ok, start, stop - start}
        spans -> multiple_occurrences(content, Enum.map(spans, &elem(&1, 0)))
      end
    end
  end

  defp line_start_offsets(lines) do
    {starts, _end} =
      Enum.map_reduce(lines, 0, fn line, offset -> {offset, offset + byte_size(line) + 1} end)

    starts
  end

  defp leading_space?(<<cp::utf8, _::binary>>) when cp in @horizontal_space, do: true
  defp leading_space?(_line), do: false

  defp trailing_space?(line) do
    case String.last(line) do
      <<cp::utf8>> when cp in @horizontal_space -> true
      _ -> false
    end
  end

  # Single-line search: any occurrence inside a normalized file line.
  defp line_match_spans(file, %{needles: [needle]} = search) do
    Enum.flat_map(0..(tuple_size(file.lines) - 1), fn index ->
      norm = elem(file.norms, index)

      norm
      |> overlapping_matches(needle)
      |> Enum.flat_map(fn {pos, len} ->
        with {:ok, start} <- span_start(file, index, pos, search.leading_space?),
             {:ok, stop} <- span_end(file, index, pos + len, search.trailing_space?) do
          [{start, stop}]
        else
          _ -> []
        end
      end)
    end)
  end

  # Multi-line search: the first needle matches a suffix of a line, interior
  # needles match whole lines, and the last needle matches a line prefix.
  defp line_match_spans(file, %{needles: [first | rest]} = search) do
    {middle, [last]} = Enum.split(rest, -1)
    needle_count = length(rest) + 1
    line_count = tuple_size(file.lines)

    if needle_count > line_count do
      []
    else
      Enum.flat_map(0..(line_count - needle_count), fn index ->
        with {:ok, start} <- first_line_start(file, index, first, search.leading_space?),
             true <- middle_lines_match?(file, index + 1, middle),
             {:ok, stop} <-
               last_line_end(file, index + needle_count - 1, last, search.trailing_space?) do
          [{start, stop}]
        else
          _ -> []
        end
      end)
    end
  end

  defp first_line_start(file, index, "", _leading_space?) do
    # The search starts with a blank line: begin at the end of this line.
    if elem(file.norms, index) == "",
      do: {:ok, elem(file.starts, index)},
      else: {:ok, elem(file.starts, index) + byte_size(elem(file.lines, index))}
  end

  defp first_line_start(file, index, needle, leading_space?) do
    norm = elem(file.norms, index)

    if String.ends_with?(norm, needle) do
      span_start(file, index, byte_size(norm) - byte_size(needle), leading_space?)
    else
      :error
    end
  end

  defp middle_lines_match?(file, first_index, needles) do
    needles
    |> Enum.with_index(first_index)
    |> Enum.all?(fn {needle, index} -> elem(file.norms, index) == needle end)
  end

  defp last_line_end(file, index, "", _trailing_space?) do
    # The search ends with a newline: stop at the start of this line.
    if elem(file.norms, index) == "",
      do: {:ok, elem(file.starts, index) + byte_size(elem(file.lines, index))},
      else: {:ok, elem(file.starts, index)}
  end

  defp last_line_end(file, index, needle, trailing_space?) do
    if String.starts_with?(elem(file.norms, index), needle) do
      span_end(file, index, byte_size(needle), trailing_space?)
    else
      :error
    end
  end

  # A match that begins at the first normalized character starts at the line
  # start when the search itself was indented, otherwise at the first
  # non-blank character (keeping the file's indentation).
  defp span_start(file, index, 0, true), do: {:ok, elem(file.starts, index)}

  defp span_start(file, index, norm_offset, _leading_space?) do
    case original_offset(elem(file.lines, index), norm_offset, :start) do
      nil -> :error
      offset -> {:ok, elem(file.starts, index) + offset}
    end
  end

  defp span_end(file, index, norm_offset, trailing_space?) do
    line = elem(file.lines, index)

    if trailing_space? and norm_offset == byte_size(elem(file.norms, index)) do
      {:ok, elem(file.starts, index) + byte_size(line)}
    else
      case original_offset(line, norm_offset, :end) do
        nil -> :error
        offset -> {:ok, elem(file.starts, index) + offset}
      end
    end
  end

  # Map a normalized byte offset on a token boundary back to the byte offset
  # in the original line.
  defp original_offset(line, norm_offset, edge) do
    {_norm_end, offset} =
      line
      |> line_tokens()
      |> Enum.reduce_while({0, nil}, fn {text, orig_start, orig_end}, {norm_pos, nil} ->
        norm_end = norm_pos + byte_size(text)

        cond do
          edge == :start and norm_pos == norm_offset -> {:halt, {norm_end, orig_start}}
          edge == :end and norm_end == norm_offset -> {:halt, {norm_end, orig_end}}
          norm_pos > norm_offset -> {:halt, {norm_end, nil}}
          true -> {:cont, {norm_end, nil}}
        end
      end)

    offset
  end

  defp normalize_line(line) do
    line
    |> line_tokens()
    |> Enum.map_join(fn {text, _orig_start, _orig_end} -> text end)
  end

  # Tokens are `{normalized_text, orig_start, orig_end}` byte ranges of the
  # original line: one per codepoint (quotes/dashes folded to ASCII), with
  # whitespace runs collapsed to one " " token and trimmed at both ends.
  defp line_tokens(line) do
    line
    |> tokenize(0, [])
    |> Enum.drop_while(&space_token?/1)
    |> Enum.reverse()
    |> Enum.drop_while(&space_token?/1)
  end

  defp space_token?({" ", _start, _end}), do: true
  defp space_token?(_token), do: false

  defp tokenize(<<>>, _pos, acc), do: acc

  defp tokenize(<<cp::utf8, rest::binary>>, pos, acc) when cp in @horizontal_space do
    next = pos + byte_size(<<cp::utf8>>)

    case acc do
      [{" ", start, _end} | tail] -> tokenize(rest, next, [{" ", start, next} | tail])
      _ -> tokenize(rest, next, [{" ", pos, next} | acc])
    end
  end

  defp tokenize(<<cp::utf8, rest::binary>>, pos, acc) do
    next = pos + byte_size(<<cp::utf8>>)
    tokenize(rest, next, [{fold_codepoint(cp), pos, next} | acc])
  end

  # Invalid UTF-8 byte: keep it as an opaque one-byte token.
  defp tokenize(<<byte, rest::binary>>, pos, acc) do
    tokenize(rest, pos + 1, [{<<byte>>, pos, pos + 1} | acc])
  end

  defp fold_codepoint(cp) when cp in @single_quotes, do: "'"
  defp fold_codepoint(cp) when cp in @double_quotes, do: "\""
  defp fold_codepoint(cp) when cp in @dashes, do: "-"
  defp fold_codepoint(cp), do: <<cp::utf8>>

  # ============================================================================
  # Replacement
  # ============================================================================

  @spec perform_replacement(String.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          {:ok, String.t()}
  defp perform_replacement(content, match_index, match_length, new_text) do
    # Normalize new_text to LF as well
    normalized_new_text = FileFormatHelpers.normalize_to_lf(new_text)

    before = :binary.part(content, 0, match_index)

    after_match =
      :binary.part(
        content,
        match_index + match_length,
        byte_size(content) - match_index - match_length
      )

    {:ok, before <> normalized_new_text <> after_match}
  end

  @spec check_content_changed(String.t(), String.t()) :: :ok | {:error, :no_change}
  defp check_content_changed(old_content, new_content) do
    if old_content == new_content do
      {:error, :no_change}
    else
      :ok
    end
  end

  # ============================================================================
  # Diff Generation
  # ============================================================================

  @default_context_lines 4

  @spec generate_diff(String.t(), String.t(), non_neg_integer()) :: String.t()
  defp generate_diff(old_content, new_content, context_lines \\ @default_context_lines) do
    old_lines = AnchoredEdit.lines(old_content)
    new_lines = AnchoredEdit.lines(new_content)

    # Find changed regions
    changes = compute_line_changes(old_lines, new_lines)

    # Generate diff with context
    format_diff(old_lines, new_lines, changes, context_lines)
  end

  @spec compute_line_changes([String.t()], [String.t()]) :: [
          {:same | :removed | :added, non_neg_integer(), String.t()}
        ]
  defp compute_line_changes(old_lines, new_lines) do
    {changes, _old_line, _new_line} =
      old_lines
      |> List.myers_difference(new_lines)
      |> Enum.reduce({[], 1, 1}, fn {kind, lines}, state ->
        Enum.reduce(lines, state, fn text, {acc, old_line, new_line} ->
          case kind do
            :eq -> {[{:same, old_line, text} | acc], old_line + 1, new_line + 1}
            :del -> {[{:removed, old_line, text} | acc], old_line + 1, new_line}
            :ins -> {[{:added, new_line, text} | acc], old_line, new_line + 1}
          end
        end)
      end)

    Enum.reverse(changes)
  end

  @spec format_diff(
          [String.t()],
          [String.t()],
          [{:same | :removed | :added, non_neg_integer(), String.t()}],
          non_neg_integer()
        ) ::
          String.t()
  defp format_diff(_old_lines, _new_lines, changes, context_lines) do
    # Find indices of changed lines
    change_indices =
      changes
      |> Enum.with_index()
      |> Enum.filter(fn {{type, _, _}, _} -> type != :same end)
      |> Enum.map(fn {_, idx} -> idx end)

    if Enum.empty?(change_indices) do
      "(no changes)"
    else
      # Determine which lines to show (changes + context)
      lines_to_show =
        change_indices
        |> Enum.flat_map(fn idx ->
          max(0, idx - context_lines)..min(length(changes) - 1, idx + context_lines)
        end)
        |> Enum.uniq()
        |> Enum.sort()

      # Group into hunks (continuous ranges)
      hunks = group_into_hunks(lines_to_show)

      # Format each hunk
      hunks
      |> Enum.map(fn hunk_indices ->
        format_hunk(changes, hunk_indices)
      end)
      |> Enum.join("\n...\n")
    end
  end

  @spec group_into_hunks([non_neg_integer()]) :: [[non_neg_integer()]]
  defp group_into_hunks([]), do: []

  defp group_into_hunks(indices) do
    indices
    |> Enum.reduce([], fn idx, acc ->
      case acc do
        [[previous | _] = current | rest] when idx == previous + 1 ->
          [[idx | current] | rest]

        _ ->
          [[idx] | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
  end

  @spec format_hunk([{:same | :removed | :added, non_neg_integer(), String.t()}], [
          non_neg_integer()
        ]) :: String.t()
  defp format_hunk(changes, indices) do
    indices
    |> Enum.map(fn idx ->
      {type, line_num, text} = Enum.at(changes, idx)

      case type do
        :same -> " #{line_num}\t#{text}"
        :removed -> "-#{line_num}\t#{text}"
        :added -> "+#{line_num}\t#{text}"
      end
    end)
    |> Enum.join("\n")
  end

  @spec find_first_changed_line(String.t(), String.t()) :: non_neg_integer()
  defp find_first_changed_line(old_content, new_content) do
    old_lines = AnchoredEdit.lines(old_content)
    new_lines = AnchoredEdit.lines(new_content)

    # Find first differing line (1-indexed)
    old_lines
    |> Enum.zip(new_lines)
    |> Enum.with_index(1)
    |> Enum.find(fn {{old_line, new_line}, _idx} -> old_line != new_line end)
    |> case do
      {{_, _}, idx} ->
        idx

      nil ->
        # Lines match but lengths differ
        min(length(old_lines), length(new_lines)) + 1
    end
  end
end
