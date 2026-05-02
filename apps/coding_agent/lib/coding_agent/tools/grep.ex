defmodule CodingAgent.Tools.Grep do
  @moduledoc """
  Grep tool for the coding agent.

  Searches for patterns in files using ripgrep (rg) if available,
  falling back to Elixir's built-in file/regex operations.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.FileValidation
  alias CodingAgent.Tools.PathHelpers

  import CodingAgent.Tools.AbortHelpers, only: [aborted?: 1, check_abort: 1]

  @default_max_results 100
  @default_context_lines 0
  @default_max_bytes 50 * 1024
  @grep_max_line_length 500
  @ripgrep_timeout_ms 30_000

  @doc """
  Returns the Grep tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "grep",
      description:
        "Search for patterns in files using regex or literal text. Uses ripgrep for performance when available.",
      label: "Search Files",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Regex pattern to search for"
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "File or directory to search in (relative to cwd or absolute). Defaults to cwd."
          },
          "glob" => %{
            "type" => "string",
            "description" => "File glob pattern to filter (e.g., \"*.ex\", \"*.{ex,exs}\")"
          },
          "case_sensitive" => %{
            "type" => "boolean",
            "description" => "Whether the search is case sensitive (default: true)"
          },
          "literal" => %{
            "type" => "boolean",
            "description" => "Treat the pattern as a literal string instead of a regex"
          },
          "context_lines" => %{
            "type" => "integer",
            "description" => "Number of lines of context to show around matches"
          },
          "max_results" => %{
            "type" => "integer",
            "description" => "Maximum number of matches to return (default: 100)"
          }
        },
        "required" => ["pattern"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute the grep tool.
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: function() | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    if aborted?(signal) do
      {:error, "Operation aborted"}
    else
      do_execute(params, signal, cwd, opts)
    end
  end

  defp do_execute(params, signal, cwd, opts) do
    pattern = Map.get(params, "pattern", "")
    path = Map.get(params, "path")
    glob = Map.get(params, "glob")
    case_sensitive = Map.get(params, "case_sensitive", true)
    literal = Map.get(params, "literal", false)
    context_lines = Map.get(params, "context_lines", @default_context_lines)

    max_results =
      Map.get(params, "max_results", Keyword.get(opts, :max_results, @default_max_results))

    with :ok <- validate_pattern(pattern, literal),
         :ok <- validate_context_lines(context_lines),
         :ok <- validate_max_results(max_results),
         {:ok, resolved_path} <- resolve_path(path, cwd, opts),
         :ok <- check_path_access(resolved_path),
         :ok <- check_abort(signal) do
      search_opts = %{
        pattern: pattern,
        path: resolved_path,
        glob: glob,
        case_sensitive: case_sensitive,
        literal: literal,
        context_lines: context_lines,
        max_results: max_results,
        max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
        signal: signal,
        timeout_ms: Keyword.get(opts, :ripgrep_timeout_ms, @ripgrep_timeout_ms),
        rg_cmd_fun: Keyword.get(opts, :rg_cmd_fun, &System.cmd/3)
      }

      if Keyword.get(opts, :ripgrep_available?, ripgrep_available?()) do
        search_with_ripgrep(search_opts)
      else
        search_with_elixir(search_opts)
      end
    end
  end

  defp validate_pattern("", _literal), do: {:error, "Pattern is required"}
  defp validate_pattern(nil, _literal), do: {:error, "Pattern is required"}

  defp validate_pattern(pattern, _literal) when not is_binary(pattern) do
    {:error, "Pattern must be a string, got: #{inspect(pattern)}"}
  end

  defp validate_pattern(pattern, _literal) when byte_size(pattern) > 10_000 do
    {:error, "Pattern is too long (max 10000 bytes)"}
  end

  defp validate_pattern(_pattern, true), do: :ok

  defp validate_pattern(pattern, false) do
    case Regex.compile(pattern) do
      {:ok, _} ->
        :ok

      {:error, {reason, position}} ->
        hint = suggest_regex_fix(pattern)

        message =
          if position > 0 do
            "Invalid regex pattern at position #{position}: #{reason}#{hint}"
          else
            "Invalid regex pattern: #{reason}#{hint}"
          end

        {:error, message}
    end
  end

  defp validate_context_lines(context_lines)
       when is_integer(context_lines) and context_lines >= 0,
       do: :ok

  defp validate_context_lines(context_lines) do
    {:error, "context_lines must be a non-negative integer, got: #{inspect(context_lines)}"}
  end

  defp validate_max_results(max_results) when is_integer(max_results) and max_results > 0,
    do: :ok

  defp validate_max_results(max_results) do
    {:error, "max_results must be a positive integer, got: #{inspect(max_results)}"}
  end

  defp suggest_regex_fix(pattern) do
    cond do
      String.contains?(pattern, "[") and not String.contains?(pattern, "]") ->
        " (hint: missing closing bracket ']')"

      String.contains?(pattern, "(") and not String.contains?(pattern, ")") ->
        " (hint: missing closing parenthesis ')')"

      String.contains?(pattern, "{") and not String.contains?(pattern, "}") ->
        " (hint: missing closing brace '}')"

      String.ends_with?(pattern, "\\") ->
        " (hint: trailing backslash needs to be escaped as '\\\\')"

      true ->
        ""
    end
  end

  defp resolve_path(nil, cwd, _opts), do: {:ok, cwd}
  defp resolve_path("", cwd, _opts), do: {:ok, cwd}

  defp resolve_path(path, cwd, opts) do
    {:ok, PathHelpers.resolve_path(path, cwd, Keyword.put(opts, :include_bare_memory, true))}
  end

  defp check_path_access(path) do
    case FileValidation.check_path_access(path, [:regular, :directory]) do
      {:ok, _stat} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc false
  def ripgrep_available? do
    case System.find_executable("rg") do
      nil -> false
      _ -> true
    end
  end

  defp search_with_ripgrep(opts) do
    args = build_ripgrep_args(opts)

    case run_ripgrep_command(args, opts) do
      {:ok, {output, 0}} ->
        parse_ripgrep_output(output, opts)

      {:ok, {_output, 1}} ->
        no_matches_result()

      {:ok, {output, 2}} ->
        {:error, "Search error: #{String.trim(output)}"}

      {:ok, {output, code}} ->
        {:error, "ripgrep exited with code #{code}: #{String.trim(output)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_ripgrep_command(args, opts) do
    cmd_fun = Map.get(opts, :rg_cmd_fun, &System.cmd/3)
    timeout_ms = Map.get(opts, :timeout_ms, @ripgrep_timeout_ms)
    signal = Map.get(opts, :signal)

    task =
      Task.Supervisor.async_nolink(CodingAgent.TaskSupervisor, fn ->
        cmd_fun.("rg", args, stderr_to_stdout: true, cd: Path.dirname(opts.path))
      end)

    started_at_ms = System.monotonic_time(:millisecond)
    await_ripgrep_result(task, signal, timeout_ms, started_at_ms)
  end

  defp await_ripgrep_result(task, signal, timeout_ms, started_at_ms) do
    if aborted?(signal) do
      _ = Task.shutdown(task, :brutal_kill)
      {:error, "Operation aborted"}
    else
      case Task.yield(task, 100) do
        {:ok, {output, code}} when is_binary(output) and is_integer(code) ->
          {:ok, {output, code}}

        {:ok, other} ->
          {:error, "Search error: unexpected ripgrep result #{inspect(other)}"}

        {:exit, reason} ->
          {:error, "Search error: #{Exception.format_exit(reason)}"}

        nil ->
          elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

          if elapsed_ms >= timeout_ms do
            _ = Task.shutdown(task, :brutal_kill)
            {:error, "Search timed out after #{timeout_ms}ms"}
          else
            await_ripgrep_result(task, signal, timeout_ms, started_at_ms)
          end
      end
    end
  end

  defp build_ripgrep_args(opts) do
    args = ["--json", "--line-number", "--color", "never"]
    args = if opts.case_sensitive, do: args, else: args ++ ["--ignore-case"]
    args = if opts.literal, do: args ++ ["--fixed-strings"], else: args

    args =
      if opts.glob do
        args ++ ["--glob", opts.glob]
      else
        args
      end

    args ++ [opts.pattern, opts.path]
  end

  defp parse_ripgrep_output(output, opts) do
    matches =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce([], fn line, acc ->
        case Jason.decode(line) do
          {:ok,
           %{
             "type" => "match",
             "data" => %{
               "path" => %{"text" => file_path},
               "line_number" => line_number
             }
           }}
          when is_binary(file_path) and is_integer(line_number) ->
            [%{file_path: file_path, line_number: line_number} | acc]

          _ ->
            acc
        end
      end)
      |> Enum.reverse()

    build_result_from_match_refs(
      matches,
      opts,
      length(matches),
      length(matches) > opts.max_results
    )
  end

  defp search_with_elixir(opts) do
    with {:ok, matcher} <- compile_matcher(opts.pattern, opts.case_sensitive, opts.literal) do
      match_refs =
        opts.path
        |> find_files(opts.glob)
        |> Stream.flat_map(fn file ->
          if aborted?(opts.signal) do
            []
          else
            search_file_refs(file, matcher)
          end
        end)
        |> Enum.to_list()

      if aborted?(opts.signal) do
        {:error, "Operation aborted"}
      else
        total_match_count = length(match_refs)

        build_result_from_match_refs(
          match_refs,
          opts,
          total_match_count,
          total_match_count > opts.max_results
        )
      end
    end
  end

  defp compile_matcher(pattern, case_sensitive, true) do
    normalized_pattern = if case_sensitive, do: pattern, else: String.downcase(pattern)
    {:ok, {:literal, normalized_pattern, case_sensitive}}
  end

  defp compile_matcher(pattern, case_sensitive, false) do
    options = if case_sensitive, do: [], else: [:caseless]

    case Regex.compile(pattern, options) do
      {:ok, regex} -> {:ok, {:regex, regex}}
      {:error, reason} -> {:error, "Invalid regex: #{reason}"}
    end
  end

  defp find_files(path, glob) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        [path]

      {:ok, %File.Stat{type: :directory}} ->
        pattern =
          if glob do
            Path.join([path, "**", glob])
          else
            Path.join(path, "**/*")
          end

        pattern
        |> Path.wildcard()
        |> Enum.filter(&regular_file?/1)
        |> Enum.filter(&text_file?/1)

      _ ->
        []
    end
  end

  defp regular_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  end

  defp text_file?(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        result =
          case IO.binread(file, 512) do
            {:error, _} -> false
            :eof -> true
            data -> not String.contains?(data, <<0>>)
          end

        File.close(file)
        result

      _ ->
        false
    end
  end

  defp search_file_refs(file_path, matcher) do
    case File.read(file_path) do
      {:ok, content} ->
        content
        |> String.split(~r/\r?\n/)
        |> Enum.with_index(1)
        |> Enum.reduce([], fn {line, idx}, acc ->
          if line_matches?(line, matcher) do
            [%{file_path: file_path, line_number: idx} | acc]
          else
            acc
          end
        end)
        |> Enum.reverse()

      {:error, _} ->
        []
    end
  end

  defp line_matches?(line, {:regex, regex}), do: Regex.match?(regex, line)

  defp line_matches?(line, {:literal, pattern, true}) do
    String.contains?(line, pattern)
  end

  defp line_matches?(line, {:literal, pattern, false}) do
    String.contains?(String.downcase(line), pattern)
  end

  defp build_result_from_match_refs([], _opts, _total_match_count, _match_limit_reached?) do
    no_matches_result()
  end

  defp build_result_from_match_refs(match_refs, opts, total_match_count, match_limit_reached?) do
    shown_refs = Enum.take(match_refs, opts.max_results)

    {formatted_lines, lines_truncated?} = format_match_refs(shown_refs, opts)
    raw_output = Enum.join(formatted_lines, "\n")
    truncation = truncate_head_output(raw_output, opts.max_bytes)

    notices =
      []
      |> maybe_add_notice(
        match_limit_reached?,
        "#{opts.max_results} matches limit reached. Use max_results=#{opts.max_results * 2} for more, or refine pattern"
      )
      |> maybe_add_notice(
        truncation.truncated,
        "#{format_size(opts.max_bytes)} limit reached"
      )
      |> maybe_add_notice(
        lines_truncated?,
        "Some lines truncated to #{@grep_max_line_length} chars. Use read tool to see full lines"
      )

    body =
      case {truncation.content, notices} do
        {"", []} ->
          nil

        {"", _} ->
          "[#{Enum.join(notices, ". ")}]"

        {content, []} ->
          content

        {content, _} ->
          content <> "\n\n[" <> Enum.join(notices, ". ") <> "]"
      end

    summary = "Found #{total_match_count} match#{if total_match_count == 1, do: "", else: "es"}."

    text =
      if body do
        summary <> "\n\n" <> body
      else
        summary
      end

    details =
      %{
        match_count: total_match_count,
        truncated: match_limit_reached? or truncation.truncated,
        match_limit_reached: if(match_limit_reached?, do: opts.max_results),
        truncation: if(truncation.truncated, do: truncation),
        lines_truncated: if(lines_truncated?, do: true)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: details
    }
  end

  defp no_matches_result do
    %AgentToolResult{
      content: [%TextContent{text: "No matches found."}],
      details: %{match_count: 0, truncated: false}
    }
  end

  defp format_match_refs(match_refs, opts) do
    directory_search? = directory_search?(opts.path)

    {lines, _cache, lines_truncated?} =
      Enum.reduce(match_refs, {[], %{}, false}, fn match_ref,
                                                   {acc_lines, cache, any_truncated?} ->
        {block_lines, next_cache, block_truncated?} =
          format_match_ref(match_ref, opts, cache, directory_search?)

        {acc_lines ++ block_lines, next_cache, any_truncated? or block_truncated?}
      end)

    {lines, lines_truncated?}
  end

  defp directory_search?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> true
      _ -> false
    end
  end

  defp format_match_ref(
         %{file_path: file_path, line_number: line_number},
         opts,
         cache,
         directory_search?
       ) do
    display_path = display_path(file_path, opts.path, directory_search?)

    case load_file_lines(file_path, cache) do
      {{:ok, lines}, next_cache} ->
        start_line =
          if opts.context_lines > 0 do
            max(1, line_number - opts.context_lines)
          else
            line_number
          end

        end_line =
          if opts.context_lines > 0 do
            min(length(lines), line_number + opts.context_lines)
          else
            line_number
          end

        {block_lines, block_truncated?} =
          Enum.reduce(start_line..end_line, {[], false}, fn current_line, {acc, any_truncated?} ->
            raw_line = Enum.at(lines, current_line - 1, "")
            {line_text, line_truncated?} = truncate_match_line(raw_line)

            formatted_line =
              if current_line == line_number do
                "#{display_path}:#{current_line}: #{line_text}"
              else
                "#{display_path}-#{current_line}- #{line_text}"
              end

            {acc ++ [formatted_line], any_truncated? or line_truncated?}
          end)

        {block_lines, next_cache, block_truncated?}

      {{:error, _reason}, next_cache} ->
        {["#{display_path}:#{line_number}: (unable to read file)"], next_cache, false}
    end
  end

  defp load_file_lines(file_path, cache) do
    case Map.fetch(cache, file_path) do
      {:ok, value} ->
        {value, cache}

      :error ->
        value =
          case File.read(file_path) do
            {:ok, content} ->
              normalized = content |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
              {:ok, String.split(normalized, "\n", trim: false)}

            {:error, reason} ->
              {:error, reason}
          end

        {value, Map.put(cache, file_path, value)}
    end
  end

  defp display_path(file_path, search_path, true) do
    relative_path = Path.relative_to(file_path, search_path)

    if relative_path == file_path or String.starts_with?(relative_path, "../") do
      Path.basename(file_path)
    else
      relative_path
    end
  end

  defp display_path(file_path, _search_path, false), do: Path.basename(file_path)

  defp truncate_match_line(line) do
    if String.length(line) <= @grep_max_line_length do
      {line, false}
    else
      {String.slice(line, 0, @grep_max_line_length) <> "... [truncated]", true}
    end
  end

  defp truncate_head_output(content, max_bytes) when byte_size(content) <= max_bytes do
    %{
      content: content,
      truncated: false,
      truncated_by: nil,
      total_lines: count_lines(content),
      total_bytes: byte_size(content),
      output_lines: count_lines(content),
      output_bytes: byte_size(content)
    }
  end

  defp truncate_head_output(content, max_bytes) do
    lines = String.split(content, "\n", trim: false)
    total_lines = length(lines)
    total_bytes = byte_size(content)

    {output_lines, truncated_by} = take_lines_within_bytes(lines, max_bytes, [], 0)
    output_content = Enum.join(output_lines, "\n")

    %{
      content: output_content,
      truncated: true,
      truncated_by: truncated_by,
      total_lines: total_lines,
      total_bytes: total_bytes,
      output_lines: length(output_lines),
      output_bytes: byte_size(output_content)
    }
  end

  defp take_lines_within_bytes([], _max_bytes, acc, _acc_bytes) do
    {Enum.reverse(acc), :bytes}
  end

  defp take_lines_within_bytes([line | rest], max_bytes, acc, acc_bytes) do
    line_bytes = byte_size(line) + if(acc == [], do: 0, else: 1)

    if acc_bytes + line_bytes > max_bytes do
      {Enum.reverse(acc), :bytes}
    else
      take_lines_within_bytes(rest, max_bytes, [line | acc], acc_bytes + line_bytes)
    end
  end

  defp count_lines(""), do: 0
  defp count_lines(content), do: length(String.split(content, "\n", trim: false))

  defp maybe_add_notice(notices, true, notice), do: notices ++ [notice]
  defp maybe_add_notice(notices, false, _notice), do: notices

  defp format_size(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)}KB"
  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)}MB"
end
