defmodule CodingAgent.Tools.AnchoredEdit do
  @moduledoc """
  Snapshot-checked edits against the original, 1-based lines shown by `read`.

  The file tag is derived from the complete bytes, not just a displayed range.
  Every edit in a batch addresses the same original snapshot. Overlapping ranges
  and coincident insertion points are rejected before any write. Original BOM,
  line endings and final-newline convention are preserved by the edit caller.
  """

  alias CodingAgent.Tools.{FileFormatHelpers, FileValidation}

  @operations ~w(replace insert_before insert_after delete)
  @max_edits 100

  def snapshot(content) when is_binary(content), do: snapshot_for_digest(:erlang.md5(content))

  def snapshot_for_digest(<<prefix::binary-size(8), _rest::binary>>) do
    Base.encode16(prefix, case: :upper)
  end

  @doc "Accept a bare tag, a bracketed tag, or a copied read header."
  def normalize_snapshot(value) when is_binary(value) do
    value = String.trim(value)

    value =
      if String.starts_with?(value, "[") and String.ends_with?(value, "]"),
        do: value |> String.slice(1..-2//1) |> String.trim(),
        else: value

    case Regex.named_captures(~r/\A(?:(?<path>[^#\[\]\r\n]+)#)?(?<tag>[0-9a-fA-F]{16})\z/, value) do
      %{"path" => path, "tag" => tag} ->
        {:ok, String.upcase(tag), if(path != "", do: String.trim(path))}

      _ ->
        invalid_snapshot()
    end
  end

  def normalize_snapshot(_value), do: invalid_snapshot()

  defp invalid_snapshot,
    do: {:error, "snapshot must be a 16-character file tag or a single [path#TAG] read header."}

  @doc "Return a bounded fresh snapshot and numbered context for a refused mutation."
  def current_context(raw, path, opts, ranges \\ [{1, 40}]) do
    {_bom, text} = FileFormatHelpers.strip_bom(raw)

    current =
      if FileValidation.check_text_content(text, path) == :ok,
        do: text |> FileFormatHelpers.normalize_to_lf() |> lines(),
        else: []

    count = length(current)

    selected =
      ranges
      |> Enum.flat_map(fn {first, last} ->
        first = min(max(first - 1, 1), count)
        last = min(max(last + 2, first), count)
        if count == 0, do: [], else: Enum.to_list(first..min(last, first + 39))
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(40)

    {shown, _bytes} =
      Enum.reduce_while(selected, {[], 0}, fn number, {shown, bytes} ->
        line = "#{number}: #{Enum.at(current, number - 1)}\n"

        if bytes + byte_size(line) <= 8192,
          do: {:cont, {[{number, line} | shown], bytes + byte_size(line)}},
          else: {:halt, {shown, bytes}}
      end)

    shown = Enum.reverse(shown)
    tag = snapshot(raw)
    CodingAgent.FileReadTracker.record(opts, path, raw)
    CodingAgent.FileReadTracker.record_seen_lines(opts, path, tag, Enum.map(shown, &elem(&1, 0)))
    body = Enum.map_join(shown, "", &elem(&1, 1))

    "\n\nCurrent snapshot [#{path}##{tag}] (bounded context; use these current line numbers):\n#{body}"
  end

  @doc false
  def context_ranges(raw, needles) do
    wanted = needles |> Enum.flat_map(&lines/1) |> Enum.reject(&(String.trim(&1) == ""))
    wanted = MapSet.new(Enum.map(wanted, &FileFormatHelpers.normalize_line/1))
    raw = if String.valid?(raw), do: raw, else: ""

    matches =
      raw
      |> FileFormatHelpers.normalize_to_lf()
      |> lines()
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} ->
        MapSet.member?(wanted, FileFormatHelpers.normalize_line(line))
      end)
      |> Enum.take(10)
      |> Enum.map(fn {_, number} -> {number, number} end)

    if matches == [], do: [{1, 40}], else: matches
  end

  def validate(snapshot, edits) do
    cond do
      not is_binary(snapshot) or not Regex.match?(~r/^[0-9a-fA-F]{16}$/, snapshot) ->
        {:error, "snapshot must be the 16-character file tag returned by read; re-read the file."}

      not is_list(edits) or edits == [] ->
        {:error, "edits must be a non-empty array of line edits"}

      length(edits) > @max_edits ->
        {:error, "A single edit call supports at most #{@max_edits} line edits"}

      true ->
        Enum.reduce_while(edits, :ok, fn edit, :ok ->
          case validate_edit(edit) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
    end
  end

  def apply(raw_content, normalized_content, snapshot, edits, previous_lines \\ nil) do
    with {:ok, edits} <- resolve_edits(raw_content, snapshot, edits, previous_lines) do
      lines = lines(normalized_content)

      with {:ok, operations} <- operations(edits, length(lines)),
           :ok <- validate_disjoint(operations) do
        {remaining, chunks, _cursor} =
          Enum.reduce(operations, {lines, [], 0}, fn op, {remaining, chunks, cursor} ->
            {before, after_before} = Enum.split(remaining, op.start - cursor)
            {_removed, after_removed} = Enum.split(after_before, op.finish - op.start)
            {after_removed, [op.lines, before | chunks], op.finish}
          end)

        result_lines = Enum.concat(Enum.reverse([remaining | chunks]))
        result = Enum.join(result_lines, "\n")

        result =
          if result_lines != [] and String.ends_with?(normalized_content, "\n"),
            do: result <> "\n",
            else: result

        {:ok, result}
      end
    end
  end

  defp resolve_edits(raw, tag, edits, previous) do
    cond do
      String.upcase(tag) == snapshot(raw) ->
        {:ok, edits}

      is_list(previous) ->
        current = lines(raw)

        with {:ok, original_ops} <- operations(edits, length(previous)),
             :ok <- validate_disjoint(original_ops),
             {:ok, rebased} <- rebase_edits(edits, previous, current),
             {:ok, rebased_ops} <- operations(rebased, length(current)),
             :ok <- validate_disjoint(rebased_ops) do
          {:ok, rebased}
        else
          _ -> snapshot_mismatch()
        end

      true ->
        snapshot_mismatch()
    end
  end

  defp rebase_edits(edits, previous, current) do
    Enum.reduce_while(edits, {:ok, []}, fn edit, {:ok, rebased} ->
      first = edit["start_line"]
      last = Map.get(edit, "end_line", first)
      anchor = Enum.slice(previous, first - 1, last - first + 1)
      count = length(anchor)

      matches =
        current
        |> Enum.chunk_every(count, 1, :discard)
        |> Enum.with_index(1)
        |> Enum.filter(fn {candidate, _index} -> candidate == anchor end)

      case matches do
        [{_anchor, start}] ->
          edit = edit |> Map.put("start_line", start) |> Map.put("end_line", start + count - 1)
          {:cont, {:ok, [edit | rebased]}}

        _ ->
          {:halt, snapshot_mismatch()}
      end
    end)
    |> case do
      {:ok, rebased} -> {:ok, Enum.reverse(rebased)}
      error -> error
    end
  end

  defp snapshot_mismatch do
    {:error,
     "Snapshot mismatch: the file changed since read. Re-read it and use fresh line numbers and snapshot; no edits were applied."}
  end

  # A terminal LF closes a line; it is not an extra editable empty line.
  def lines(content) do
    segments = String.split(content, "\n", trim: false)

    if content != "" and String.ends_with?(content, "\n"),
      do: Enum.drop(segments, -1),
      else: segments
  end

  defp validate_edit(edit) when is_map(edit) do
    operation = Map.get(edit, "operation", "replace")
    first = Map.get(edit, "start_line")
    last = Map.get(edit, "end_line", first)

    cond do
      operation not in @operations ->
        {:error, "operation must be replace, insert_before, insert_after, or delete"}

      not is_integer(first) or first < 1 ->
        {:error, "start_line must be a positive, 1-based line number from read"}

      not is_integer(last) or last < first ->
        {:error, "end_line must be an integer greater than or equal to start_line"}

      operation in ["insert_before", "insert_after"] and last != first ->
        {:error, "Insertions target one start_line; omit end_line or use the same line"}

      operation == "delete" ->
        :ok

      not is_binary(Map.get(edit, "new_text")) ->
        {:error, "new_text must be a string for replacement and insertion edits"}

      true ->
        FileValidation.check_text_content(edit["new_text"], "new_text")
    end
  end

  defp validate_edit(_edit), do: {:error, "Each line edit must be an object"}

  defp operations(edits, count) do
    Enum.reduce_while(edits, {:ok, []}, fn edit, {:ok, acc} ->
      first = edit["start_line"]
      last = Map.get(edit, "end_line", first)

      if last > count do
        {:halt,
         {:error,
          "Line range #{first}-#{last} exceeds the file's #{count} editable lines. Re-read the file; no edits were applied."}}
      else
        operation = Map.get(edit, "operation", "replace")

        {start, finish} =
          case operation do
            "insert_before" -> {first - 1, first - 1}
            "insert_after" -> {first, first}
            _ -> {first - 1, last}
          end

        replacement = if operation == "delete", do: [], else: replacement_lines(edit["new_text"])
        {:cont, {:ok, [%{start: start, finish: finish, lines: replacement} | acc]}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.sort_by(operations, &{&1.start, &1.finish})}
      error -> error
    end
  end

  defp replacement_lines(text) do
    text |> FileFormatHelpers.normalize_to_lf() |> lines()
  end

  defp validate_disjoint(operations) do
    Enum.reduce_while(operations, {:ok, nil}, fn op, {:ok, previous} ->
      if previous && (op.start < previous.finish or op.start == previous.start) do
        {:halt,
         {:error,
          "Line edits overlap at original line #{op.start + 1}. Combine overlapping changes into one edit; no edits were applied."}}
      else
        {:cont, {:ok, op}}
      end
    end)
    |> case do
      {:ok, _last} -> :ok
      error -> error
    end
  end
end
