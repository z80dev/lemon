# Coding Agent Tools - Duplication Analysis

## Executive Summary

Found **9 major duplication patterns** across 20+ tool files. Most are related to file I/O, path handling, and result formatting. Estimated impact: **20-30% code reduction** possible with shared helpers.

---

## 1. Path Resolution & Normalization

### Pattern: `expand_home/1`
**Files:** `read.ex`, `write.ex`, `edit.ex`, `glob.ex`, `grep.ex`, `find.ex`, `ls.ex`, `webdownload.ex`, `patch.ex`

**Duplicate Code:**
```elixir
defp expand_home("~" <> rest) do
  Path.expand("~") <> rest
end

defp expand_home(path), do: path
```

**Occurrences:** 9+ (variations with single vs multi-line)

**Lines:**
- `read.ex:258-262`
- `write.ex:135-139`
- `edit.ex` (in fuzzy matching, not simple home expansion)
- `glob.ex:137-138`
- `grep.ex:219-223`
- `find.ex:147-151`
- `ls.ex:136-140`
- `webdownload.ex:279-280`
- `patch.ex:751-752`

**Shared Helper Suggestion:**
```elixir
defmodule CodingAgent.Tools.PathHelpers do
  @doc "Expand ~ to home directory"
  def expand_home("~" <> rest) do
    Path.expand("~") <> rest
  end
  def expand_home(path), do: path
end
```

---

### Pattern: `prefer_workspace_for_path?/2`
**Files:** `read.ex`, `write.ex`, `edit.ex`, `grep.ex`

**Duplicate Code (identical across files):**
```elixir
defp prefer_workspace_for_path?(path, workspace_dir) do
  is_binary(workspace_dir) and String.trim(workspace_dir) != "" and
    not explicit_relative?(path) and
    (path == "MEMORY.md" or String.starts_with?(path, "memory/") or
       String.starts_with?(path, "memory\\"))
end
```

**Occurrences:** 4 (exactly identical)
- `read.ex:278-283`
- `write.ex:155-160`
- `edit.ex:195-200`
- `grep.ex:239-244`

**Note:** `grep.ex:239-244` has slight variation: also checks `path == "memory"` in addition to paths.

**Shared Helper Suggestion:**
```elixir
def prefer_workspace_for_path?(path, workspace_dir) do
  is_binary(workspace_dir) and String.trim(workspace_dir) != "" and
    not explicit_relative?(path) and
    (path == "MEMORY.md" or path == "memory" or
     String.starts_with?(path, "memory/") or
     String.starts_with?(path, "memory\\"))
end
```

---

### Pattern: `explicit_relative?/1`
**Files:** `read.ex`, `write.ex`, `edit.ex`, `grep.ex`

**Duplicate Code (identical):**
```elixir
defp explicit_relative?(path) when is_binary(path) do
  String.starts_with?(path, "./") or String.starts_with?(path, "../") or
    String.starts_with?(path, ".\\") or String.starts_with?(path, "..\\")
end
```

**Occurrences:** 4 (exactly identical)
- `read.ex:285-288`
- `write.ex:162-165`
- `edit.ex:202-205`
- `grep.ex:246-249`

---

### Pattern: `resolve_path/2-3` (with workspace logic)
**Files:** `read.ex`, `write.ex`, `edit.ex`, `grep.ex`, `find.ex`

Full path resolution including home expansion + workspace preference:

- `read.ex:249-276` — Full resolution with workspace preference
- `write.ex:129-153` — Full resolution with workspace preference
- `edit.ex:181-193` — Full resolution with workspace preference
- `grep.ex:210-237` — Full resolution with workspace preference
- `find.ex:138-159` — Simplified version without workspace logic
- `glob.ex:127-135` — Simplified version, calls `expand_home` then `Path.expand`

**Shared Helper Suggestion:**
```elixir
def resolve_path(path, cwd, opts \\ []) do
  expanded = expand_home(path)
  if Path.type(expanded) == :absolute do
    expanded
  else
    workspace_dir = Keyword.get(opts, :workspace_dir)
    if prefer_workspace_for_path?(expanded, workspace_dir) do
      Path.join(workspace_dir, expanded) |> Path.expand()
    else
      Path.join(cwd, expanded) |> Path.expand()
    end
  end
end
```

---

## 2. Abort Signal Handling

### Pattern A: `aborted?/1` + `check_abort/1`
**Files:** `find.ex`, `grep.ex`, `read.ex`, `truncate.ex`, `ls.ex`

**Duplicate Code:**
```elixir
defp aborted?(nil), do: false
defp aborted?(signal), do: AbortSignal.aborted?(signal)

defp check_abort(signal) do
  if aborted?(signal) do
    {:error, "Operation aborted"}
  else
    :ok
  end
end
```

**Occurrences:** 5
- `find.ex:539-548`
- `grep.ex:598-607`
- `read.ex:498-507`
- `truncate.ex:507-509` (only has `aborted?` not `check_abort`)
- `ls.ex:468-477`

---

### Pattern B: `check_aborted/1` (style variant)
**Files:** `edit.ex`, `hashline_edit.ex`, `patch.ex`, `webdownload.ex`, `webfetch.ex`, `websearch.ex`

**Duplicate Code:**
```elixir
defp check_aborted(nil), do: :ok

defp check_aborted(signal) when is_reference(signal) do
  if AbortSignal.aborted?(signal) do
    {:error, :aborted}
  else
    :ok
  end
end

defp check_aborted(_), do: :ok
```

**Occurrences:** 6+
- `edit.ex:164-174`
- `hashline_edit.ex:265-271`
- `patch.ex:797-806`
- `webdownload.ex:301-309`
- `webfetch.ex:823-831`
- `websearch.ex:810-818`

**Difference:** This variant returns `:ok` by default and `:error` on abort, while Pattern A's `check_abort` takes a slightly different approach.

**Shared Helper Suggestion:**
```elixir
def check_aborted(signal) do
  case signal do
    nil -> :ok
    signal when is_reference(signal) ->
      if AbortSignal.aborted?(signal), do: {:error, :aborted}, else: :ok
    _ -> :ok
  end
end

# For tools preferring the other style:
def check_abort_or_ok(signal) do
  if aborted?(signal), do: {:error, "Operation aborted"}, else: :ok
end

def aborted?(nil), do: false
def aborted?(signal), do: AbortSignal.aborted?(signal)
```

---

## 3. File Access & Permission Checking

### Pattern: Error Response Construction for File Errors
**Files:** `read.ex`, `edit.ex`, `grep.ex`, `ls.ex`, `patch.ex`, `find.ex`, `hashline_edit.ex`

**Common Error Patterns:**

```elixir
{:error, :enoent} -> {:error, "File not found: #{path}"}
{:error, :eacces} -> {:error, "Permission denied: #{path}"}
{:error, reason} -> {:error, "Cannot access path: #{path} (#{reason})"}
```

**Occurrences:** 7+
- `read.ex:305-312` (in `check_file_access`)
- `edit.ex:212-223` (in `check_file_access`)
- `grep.ex:251-268` (in `check_path_access`)
- `ls.ex:156-174` (in `check_directory` + inline)
- `patch.ex:808-809` (in `format_error` helper - GOOD)
- `find.ex:165-182` (in `check_directory`)
- `hashline_edit.ex:281-286` (in `check_file_access`)

**Shared Helper Suggestion:**
```elixir
def format_file_error(error_atom, path, context \\ "file") do
  case error_atom do
    :enoent -> "File not found: #{path}"
    :eacces -> "Permission denied: #{path}"
    :eisdir -> "Path is a directory, not a #{context}: #{path}"
    :enotdir -> "Path is not a directory: #{path}"
    reason -> "Cannot access #{context}: #{path} (#{reason})"
  end
end
```

---

## 4. BOM & Line Ending Handling

### Pattern: UTF-8 BOM Detection & Stripping
**Files:** `edit.ex`, `hashline_edit.ex`, `multiedit.ex` (likely)

**Duplicate Code:**
```elixir
@utf8_bom <<0xEF, 0xBB, 0xBF>>

defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>) do
  {@utf8_bom, rest}
end

defp strip_bom(content) do
  {nil, content}
end
```

**Occurrences:** 3+
- `edit.ex:229-238`
- `hashline_edit.ex:289-292`
- (implied in `multiedit.ex`)

---

### Pattern: Line Ending Detection & Restoration
**Files:** `edit.ex`, `hashline_edit.ex`, `multiedit.ex` (likely)

**Duplicate Code:**
```elixir
defp detect_line_ending(content) do
  if String.contains?(content, "\r\n") do
    "\r\n"
  else
    "\n"
  end
end

defp normalize_to_lf(text) do
  String.replace(text, "\r\n", "\n")
end

defp restore_line_endings(text, "\r\n") do
  text
  |> String.replace("\r\n", "\n")
  |> String.replace("\n", "\r\n")
end

defp restore_line_endings(text, _) do
  text
end
```

**Occurrences:** 3+
- `edit.ex:244-268`
- `hashline_edit.ex:294-301+`
- (implied in `multiedit.ex`)

**Shared Helper Suggestion:**
```elixir
defmodule CodingAgent.Tools.FileFormatHelpers do
  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  def strip_bom(<<@utf8_bom::binary, rest::binary>>), do: {@utf8_bom, rest}
  def strip_bom(content), do: {nil, content}

  def detect_line_ending(content) do
    if String.contains?(content, "\r\n"), do: "\r\n", else: "\n"
  end

  def normalize_to_lf(text), do: String.replace(text, "\r\n", "\n")

  def restore_line_endings(text, "\r\n") do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\n", "\r\n")
  end
  def restore_line_endings(text, _), do: text

  def finalize_content(content, line_ending, bom \\ nil) do
    with_endings = restore_line_endings(content, line_ending)
    case bom do
      nil -> with_endings
      bom_bytes -> bom_bytes <> with_endings
    end
  end
end
```

---

## 5. Truncation & Result Limiting Logic

### Pattern: Truncation with Message Formatting
**Files:** `read.ex`, `grep.ex`, `find.ex`

**Common Pattern:**
```elixir
{truncated_lines, truncation_info} =
  if length(lines) > max_lines do
    {Enum.take(lines, max_lines), true}
  else
    {lines, false}
  end

# Later:
if truncated do
  output <> "\n\n[Results truncated at #{max_results} matches]"
else
  output
end
```

**Occurrences:** 3+
- `read.ex:425-456` — Line-based truncation with byte limits
- `grep.ex:389-415` — Match count truncation
- `find.ex:484-518` — File count truncation

**Shared Helper Suggestion:**
```elixir
def truncate_results(items, max_count) when is_list(items) do
  count = length(items)
  truncated? = count >= max_count
  taken = if truncated?, do: Enum.take(items, max_count), else: items
  {taken, truncated?}
end

def format_truncation_message(count, type \\ "results") do
  "[Results truncated at #{count} #{type}]"
end
```

---

## 6. Result Formatting & Summary Construction

### Pattern: Match/Result Count Formatting
**Files:** `grep.ex`, `find.ex`

**Duplicate Code:**
```elixir
match_count = length(results)
truncated = match_count >= max_results

text =
  if truncated do
    "Found #{match_count} match#{if match_count == 1, do: "", else: "es"} (truncated).\n\n#{formatted}"
  else
    "Found #{match_count} match#{if match_count == 1, do: "", else: "es"}.\n\n#{formatted}"
  end
```

**Occurrences:** 2+
- `grep.ex:561-584`
- `find.ex:484-518`

**Similar but Different:**
- `bash.ex:142-195` — Different result formatting (exit code + output handling)

**Shared Helper Suggestion:**
```elixir
def format_count_result(count, singular \\ "result", plural \\ nil) do
  plural = plural || singular <> "es"
  if count == 1, do: singular, else: plural
end

def format_result_summary(count, type, truncated) do
  label = format_count_result(count, type)
  base = "Found #{count} #{label}."
  if truncated, do: base <> " (truncated)", else: base
end
```

---

## 7. Tool Definition Structure

All tools follow identical structure:
```elixir
def tool(cwd, opts \\ []) do
  %AgentTool{
    name: "...",
    description: "...",
    label: "...",
    parameters: %{...},
    execute: &execute(&1, &2, &3, &4, cwd, opts)
  }
end
```

**Suggestion:** Could create a macro or factory function, but impact is low since it's boilerplate.

---

## 8. Directory/File Type Checking

### Pattern: File Type Validation
**Files:** `read.ex`, `grep.ex`, `find.ex`, `ls.ex`, `patch.ex`

**Duplicate Code:**
```elixir
case File.stat(path) do
  {:ok, %File.Stat{type: :regular}} -> {:ok, stat}
  {:ok, %File.Stat{type: :directory}} -> {:error, "Path is a directory..."}
  {:ok, %File.Stat{type: type}} -> {:error, "Path is not a regular file (#{type})..."}
  {:error, :enoent} -> {:error, "File not found: #{path}"}
  {:error, :eacces} -> {:error, "Permission denied: #{path}"}
  {:error, reason} -> {:error, "Cannot access file..."}
end
```

**Occurrences:** 5+
- `read.ex:294-314` (in `check_file_access`)
- `grep.ex:251-268` (in `check_path_access`, checks `:regular` OR `:directory`)
- `find.ex:165-182` (in `check_directory`, only checks `:directory`)
- `ls.ex:156-174` (inline, checks `:directory`)
- `patch.ex:726-745` (in `check_file_exists`, similar)

**Shared Helper Suggestion:**
```elixir
def check_file_type(path, allowed_types) when is_list(allowed_types) do
  case File.stat(path) do
    {:ok, %File.Stat{type: type}} = result when type in allowed_types ->
      {:ok, result}
    {:ok, %File.Stat{type: type}} ->
      {:error, {:invalid_type, type, path}}
    {:error, :enoent} ->
      {:error, {:not_found, path}}
    {:error, :eacces} ->
      {:error, {:permission_denied, path}}
    {:error, reason} ->
      {:error, {:access_error, reason, path}}
  end
end
```

---

## 9. Line Number & Index Handling

### Pattern: Offset Normalization
**Files:** `read.ex`, (potentially others)

**Code:**
```elixir
defp normalize_offset(nil), do: 0
defp normalize_offset(offset) when offset < 1, do: 0
defp normalize_offset(offset), do: offset - 1
```

**Occurrences:** 1+ (appears only in read.ex)

**Shared Helper Suggestion:**
```elixir
def normalize_line_offset(nil), do: 0
def normalize_line_offset(offset) when offset < 1, do: 0
def normalize_line_offset(offset), do: offset - 1
```

---

## Summary Table

| Pattern | Files | Count | Complexity | Priority |
|---------|-------|-------|------------|----------|
| Path expansion (`expand_home`) | 9 | 9+ | Low | HIGH |
| Workspace path preference | 4 | 4 | Medium | HIGH |
| Explicit relative path check | 4 | 4 | Low | HIGH |
| Full path resolution | 5 | 5 | Medium | HIGH |
| Abort signal handling (2 variants) | 11 | 11+ | Low | MEDIUM |
| File error formatting | 7 | 7+ | Low | HIGH |
| BOM/line ending handling | 3 | 3+ | Medium | MEDIUM |
| Truncation logic | 3 | 3+ | Medium | MEDIUM |
| Result count formatting | 2 | 2+ | Low | LOW |
| File type checking | 5 | 5+ | Medium | MEDIUM |

---

## Recommended Shared Modules

1. **`CodingAgent.Tools.PathHelpers`** (Priority: HIGH)
   - `expand_home/1`
   - `explicit_relative?/1`
   - `prefer_workspace_for_path?/2`
   - `resolve_path/2-3`

2. **`CodingAgent.Tools.AbortSignal`** (Priority: MEDIUM)
   - `aborted?/1`
   - `check_abort/1`
   - `check_aborted/1`

3. **`CodingAgent.Tools.FileFormatHelpers`** (Priority: MEDIUM)
   - `strip_bom/1`
   - `detect_line_ending/1`
   - `normalize_to_lf/1`
   - `restore_line_endings/2`
   - `finalize_content/3`

4. **`CodingAgent.Tools.FileValidation`** (Priority: MEDIUM)
   - `check_file_type/2`
   - `format_file_error/3`
   - `check_file_access/1`

5. **`CodingAgent.Tools.ResultFormatting`** (Priority: LOW)
   - `format_count_result/2-3`
   - `format_result_summary/3`
   - `truncate_results/2`

---

## Estimated Impact

- **Lines of code eliminated:** 300-400 (duplicated across 20+ files)
- **Maintenance improvement:** Higher consistency, easier to fix bugs in one place
- **Risk:** Low if extracted modules are properly tested
- **Implementation effort:** 4-6 hours for extraction + testing

---

## Notes

- **Variations found:** Tools have slight semantic differences (e.g., returning `:ok` vs `:error` atoms, different error messages), so extracted helpers should provide flexibility
- **Existing good practices:** `patch.ex` already has `format_error/2` helper — this pattern should be extended
- **Not duplicated but worth noting:**
  - Diff generation (edit.ex only)
  - Fuzzy text matching (edit.ex only)
  - Hashline operations (specialized, not duplicated)
