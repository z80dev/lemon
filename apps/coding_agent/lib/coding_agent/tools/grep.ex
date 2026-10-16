defmodule CodingAgent.Tools.Grep do
  @moduledoc """
  Grep tool for the coding agent.

  Searches for patterns in files using ripgrep (rg) if available,
  falling back to Elixir's built-in file/regex operations.
  Both paths skip hidden files and `.gitignore`/`.ignore`d files by default
  (`hidden: true` / `no_ignore: true` include them); `skip` pages past
  `max_results`.
  Binary and invalid UTF-8 files are skipped by the Elixir fallback, including
  explicitly targeted files. Truncated lines can be recovered with `read`.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAi.Types.TextContent
  alias CodingAgent.Tools.IgnoreFilter
  alias CodingAgent.Tools.PathHelpers

  import LemonAgent.Tools.AbortHelpers, only: [aborted?: 1, check_abort: 1]

  @default_max_results 100
  @default_context_lines 0
  @default_max_bytes 50 * 1024
  @grep_max_line_length 500
  @ripgrep_timeout_ms 30_000
  @max_file_bytes 4 * 1024 * 1024

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
      parallel_safe: true,
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
              "File/directory roots separated by semicolons (relative to cwd or absolute). Defaults to cwd."
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
          "output_mode" => %{
            "type" => "string",
            "enum" => ["content", "files", "count"],
            "description" =>
              "Return matching content (default), paths, or per-file counts and total"
          },
          "context_lines" => %{
            "type" => "integer",
            "description" => "Number of lines of context to show around matches"
          },
          "max_results" => %{
            "type" => "integer",
            "description" => "Maximum number of matches to return (default: 100)"
          },
          "skip" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" =>
              "Number of matches to skip before returning results, for paging past max_results (default: 0)"
          },
          "hidden" => %{
            "type" => "boolean",
            "description" => "Search hidden files and directories (default: false)"
          },
          "no_ignore" => %{
            "type" => "boolean",
            "description" =>
              "Include files ignored by .gitignore/.ignore (default: false; ignored files are skipped)"
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
      params
      |> do_execute(signal, cwd, opts)
      |> ToolResultTrust.untrusted(:local_search)
    end
  end

  defp do_execute(params, signal, cwd, opts) do
    pattern = Map.get(params, "pattern", "")
    path = Map.get(params, "path")
    glob = Map.get(params, "glob")
    case_sensitive = Map.get(params, "case_sensitive", true)
    literal = Map.get(params, "literal", false)
    context_lines = Map.get(params, "context_lines", @default_context_lines)
    skip = Map.get(params, "skip", 0)
    output_mode = Map.get(params, "output_mode", "content")

    max_results =
      Map.get(params, "max_results", Keyword.get(opts, :max_results, @default_max_results))

    with :ok <- validate_pattern(pattern, literal),
         :ok <- validate_context_lines(context_lines),
         :ok <- validate_max_results(max_results),
         :ok <- validate_skip(skip),
         :ok <- validate_output_mode(output_mode),
         {:ok, paths, missing} <-
           PathHelpers.resolve_search_paths(
             path,
             cwd,
             [:regular, :directory],
             Keyword.put(opts, :include_bare_memory, true)
           ),
         :ok <- check_abort(signal) do
      search_opts = %{
        pattern: pattern,
        path: if(length(paths) == 1, do: hd(paths), else: cwd),
        paths: paths,
        glob: glob,
        case_sensitive: case_sensitive,
        literal: literal,
        output_mode: output_mode,
        multiline: String.contains?(pattern, ["\n", "\\n"]),
        context_lines: context_lines,
        max_results: max_results,
        skip: skip,
        hidden: Map.get(params, "hidden", false) == true,
        no_ignore: Map.get(params, "no_ignore", false) == true,
        max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
        signal: signal,
        timeout_ms: Keyword.get(opts, :ripgrep_timeout_ms, @ripgrep_timeout_ms),
        rg_cmd_fun: Keyword.get(opts, :rg_cmd_fun, &System.cmd/3),
        pcre2_available?:
          Keyword.get_lazy(opts, :pcre2_available?, fn -> &pcre2_available?/0 end),
        fallback_timeout_ms: Keyword.get(opts, :fallback_timeout_ms, @ripgrep_timeout_ms),
        fallback_files_fun: Keyword.get(opts, :fallback_files_fun, &find_files/2),
        fallback_match_fun: Keyword.get(opts, :fallback_match_fun, &line_matches?/2)
      }

      result =
        if Keyword.get(opts, :ripgrep_available?, ripgrep_available?()) do
          search_with_ripgrep(search_opts)
        else
          search_with_elixir(search_opts)
        end

      PathHelpers.with_missing_paths(result, missing)
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

  defp validate_skip(skip) when is_integer(skip) and skip >= 0, do: :ok

  defp validate_skip(skip) do
    {:error, "skip must be a non-negative integer, got: #{inspect(skip)}"}
  end

  defp validate_output_mode(mode) when mode in ["content", "files", "count"], do: :ok
  defp validate_output_mode(_), do: {:error, "output_mode must be content, files, or count"}

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

  @doc false
  def ripgrep_available? do
    case System.find_executable("rg") do
      nil -> false
      _ -> true
    end
  end

  defp pcre2_available? do
    key = {__MODULE__, :pcre2, System.find_executable("rg")}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        supported? =
          case System.cmd("rg", ["--pcre2-version"], stderr_to_stdout: true) do
            {_, 0} -> true
            _ -> false
          end

        :persistent_term.put(key, supported?)
        supported?

      supported? ->
        supported?
    end
  end

  defp regex_engine(%{literal: true}), do: {:ok, false}

  defp regex_engine(opts) do
    case pcre_construct(opts.pattern) do
      nil ->
        {:ok, false}

      construct ->
        supported? = opts.pcre2_available?
        supported? = if is_function(supported?, 0), do: supported?.(), else: supported?

        if supported? do
          {:ok, true}
        else
          {:error,
           "Pattern uses #{construct}, but rg uses Rust regex without PCRE2 support. " <>
             "Use a Rust-regex-compatible pattern or install ripgrep with PCRE2."}
        end
    end
  end

  defp pcre_construct(""), do: nil

  defp pcre_construct(<<"\\", next, _::binary>>) when next in ?1..?9 or next in [?g, ?k],
    do: "backreferences"

  defp pcre_construct(<<"\\", _, rest::binary>>), do: pcre_construct(rest)
  defp pcre_construct(<<"[", rest::binary>>), do: skip_character_class(rest)
  defp pcre_construct(<<"(?=", _::binary>>), do: "lookaround"
  defp pcre_construct(<<"(?!", _::binary>>), do: "lookaround"
  defp pcre_construct(<<"(?<=", _::binary>>), do: "lookaround"
  defp pcre_construct(<<"(?<!", _::binary>>), do: "lookaround"
  defp pcre_construct(<<"(?P=", _::binary>>), do: "backreferences"
  defp pcre_construct(<<_, rest::binary>>), do: pcre_construct(rest)

  defp skip_character_class(""), do: nil
  defp skip_character_class(<<"\\", _, rest::binary>>), do: skip_character_class(rest)
  defp skip_character_class(<<"]", rest::binary>>), do: pcre_construct(rest)
  defp skip_character_class(<<_, rest::binary>>), do: skip_character_class(rest)

  defp search_with_ripgrep(opts) do
    with {:ok, pcre2?} <- regex_engine(opts) do
      args = build_ripgrep_args(opts)
      args = if pcre2?, do: ["--pcre2" | args], else: args

      case run_ripgrep_command(args, opts) do
        {:ok, {output, 0}} ->
          parse_ripgrep_output(output, opts)

        {:ok, {_output, 1}} ->
          no_matches_result()

        {:ok, {output, 2}} ->
          result = parse_ripgrep_output(output, opts)
          warning = first_ripgrep_warning(output)

          if result.details.match_count > 0 do
            %{
              result
              | content: result.content ++ [%TextContent{text: "warnings: #{warning}"}],
                details: Map.put(result.details, :warnings, [warning])
            }
          else
            {:error, "Search error: #{warning}"}
          end

        {:ok, {output, code}} ->
          {:error, "ripgrep exited with code #{code}: #{String.trim(output)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp first_ripgrep_warning(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find("ripgrep exited with code 2", fn line ->
      not match?({:ok, %{"type" => _}}, Jason.decode(line))
    end)
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
    args = if opts.multiline, do: args ++ ["-U"], else: args
    args = if opts.hidden, do: args ++ ["--hidden"], else: args
    args = if opts.no_ignore, do: args ++ ["--no-ignore"], else: args

    args =
      if opts.glob do
        args ++ ["--glob", opts.glob]
      else
        args
      end

    # `--regexp=` keeps a pattern that starts with `-` (e.g. `->`) from being
    # parsed as a flag (`-e -foo` is rejected by ripgrep's argument parser);
    # `--` does the same for the path.
    args ++ ["--regexp=" <> opts.pattern, "--"] ++ opts.paths
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
             "data" =>
               %{
                 "path" => %{"text" => file_path},
                 "line_number" => line_number
               } = data
           }}
          when is_binary(file_path) and is_integer(line_number) ->
            column = get_in(data, ["submatches", Access.at(0), "start"]) || 0
            [%{file_path: file_path, line_number: line_number, column: column} | acc]

          _ ->
            acc
        end
      end)
      |> Enum.uniq_by(&{&1.file_path, &1.line_number})
      |> Enum.sort_by(&{&1.file_path, &1.line_number})

    build_result_from_match_refs(matches, opts)
  end

  defp search_with_elixir(opts) do
    task =
      Task.Supervisor.async_nolink(CodingAgent.TaskSupervisor, fn ->
        run_elixir_search(opts)
      end)

    await_elixir_result(task, opts, System.monotonic_time(:millisecond))
  end

  defp await_elixir_result(task, opts, started_at_ms) do
    remaining = opts.fallback_timeout_ms - (System.monotonic_time(:millisecond) - started_at_ms)

    cond do
      aborted?(opts.signal) ->
        Task.shutdown(task, :brutal_kill)
        {:error, "Operation aborted"}

      remaining <= 0 ->
        Task.shutdown(task, :brutal_kill)
        {:error, "Search timed out after #{opts.fallback_timeout_ms}ms"}

      true ->
        case Task.yield(task, min(100, remaining)) do
          {:ok, result} -> result
          {:exit, reason} -> {:error, "Search error: #{Exception.format_exit(reason)}"}
          nil -> await_elixir_result(task, opts, started_at_ms)
        end
    end
  end

  defp run_elixir_search(opts) do
    with {:ok, matcher} <- compile_matcher(opts.pattern, opts.case_sensitive, opts.literal) do
      limit = if opts.output_mode == "count", do: :infinity, else: opts.skip + opts.max_results

      {refs, count, oversized, incomplete?} =
        opts.paths
        |> Enum.flat_map(&opts.fallback_files_fun.(&1, opts))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.reduce_while({[], 0, 0, false}, fn file, {refs, count, oversized, _} ->
          if aborted?(opts.signal) do
            {:halt, {refs, count, oversized, true}}
          else
            remaining =
              cond do
                opts.output_mode == "files" -> 1
                limit == :infinity -> :infinity
                true -> limit - count
              end

            {matches, oversized?, more?} = search_file_refs(file, matcher, remaining, opts)
            count = count + length(matches)

            acc =
              {Enum.reverse(matches, refs), count, oversized + if(oversized?, do: 1, else: 0),
               (opts.output_mode == "content" and more?) or count == limit}

            if count == limit, do: {:halt, acc}, else: {:cont, acc}
          end
        end)

      if aborted?(opts.signal) do
        {:error, "Operation aborted"}
      else
        refs = Enum.sort_by(refs, &{&1.file_path, &1.line_number})
        opts = Map.merge(opts, %{incomplete: incomplete?, bounded: true})
        result = build_result_from_match_refs(refs, opts)

        details =
          Map.merge(result.details, %{skipped_oversized: oversized, incomplete: incomplete?})

        details =
          if incomplete? and count > 0,
            do:
              Map.put_new(
                details,
                :next_skip,
                opts.skip + min(opts.max_results, count - opts.skip)
              ),
            else: details

        %{result | details: details}
      end
    end
  end

  defp compile_matcher(pattern, case_sensitive, true) do
    normalized_pattern = if case_sensitive, do: pattern, else: String.downcase(pattern)
    {:ok, {:literal, normalized_pattern, case_sensitive}}
  end

  defp compile_matcher(pattern, case_sensitive, false) do
    options = if case_sensitive, do: [:multiline], else: [:multiline, :caseless]

    case Regex.compile(pattern, options) do
      {:ok, regex} -> {:ok, {:regex, regex}}
      {:error, reason} -> {:error, "Invalid regex: #{reason}"}
    end
  end

  defp find_files(path, opts) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        [path]

      {:ok, %File.Stat{type: :directory}} ->
        pattern =
          if opts.glob do
            Path.join([path, "**", opts.glob])
          else
            Path.join(path, "**/*")
          end

        files =
          pattern
          |> Path.wildcard(match_dot: opts.hidden)
          |> Enum.filter(&regular_file?/1)
          |> Enum.sort()

        if opts.no_ignore, do: files, else: IgnoreFilter.reject_ignored(files, path)

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

  defp read_leading_window(file_path) do
    with {:ok, stat} <- File.stat(file_path),
         {:ok, content} <-
           File.open(file_path, [:read, :binary], &IO.binread(&1, @max_file_bytes)) do
      content = if content == :eof, do: "", else: content
      oversized? = stat.size > @max_file_bytes

      content =
        if oversized? and is_binary(content) do
          case :unicode.characters_to_binary(content) do
            {:incomplete, prefix, _} -> prefix
            _ -> content
          end
        else
          content
        end

      if is_binary(content), do: {:ok, content, oversized?}, else: {:error, :read}
    end
  end

  defp search_file_refs(file_path, matcher, limit, opts) do
    case read_leading_window(file_path) do
      {:ok, content, oversized?} ->
        refs =
          if String.valid?(content) and not String.contains?(content, <<0>>) do
            if opts.multiline do
              multiline_refs(content, matcher, file_path, limit)
            else
              content
              |> String.split(~r/\r?\n/)
              |> Stream.with_index(1)
              |> Stream.filter(fn {line, _} -> opts.fallback_match_fun.(line, matcher) end)
              |> Stream.map(fn {line, idx} ->
                %{file_path: file_path, line_number: idx, column: match_column(line, matcher)}
              end)
              |> take_refs(limit)
            end
          else
            []
          end

        {refs, oversized?, length(refs) == limit}

      {:error, _} ->
        {[], false, false}
    end
  end

  defp take_refs(refs, :infinity), do: Enum.to_list(refs)
  defp take_refs(refs, limit), do: Enum.take(refs, limit)

  defp multiline_refs(content, matcher, file_path, limit) do
    offsets =
      case matcher do
        {:regex, regex} ->
          Regex.scan(regex, content, return: :index, capture: :first)
          |> Enum.map(fn [{offset, _}] -> offset end)

        {:literal, pattern, case_sensitive} ->
          source = if case_sensitive, do: content, else: String.downcase(content)
          :binary.matches(source, pattern) |> Enum.map(&elem(&1, 0))
      end

    offsets
    |> Stream.map(fn offset ->
      line = 1 + length(:binary.matches(binary_part(content, 0, offset), "\n"))

      line_start =
        case :binary.matches(binary_part(content, 0, offset), "\n") |> List.last() do
          nil -> 0
          {last, _} -> last + 1
        end

      %{file_path: file_path, line_number: line, column: offset - line_start}
    end)
    |> Stream.uniq_by(& &1.line_number)
    |> take_refs(limit)
  end

  defp match_column(line, {:regex, regex}) do
    case Regex.run(regex, line, return: :index, capture: :first) do
      [{offset, _}] -> offset
      _ -> 0
    end
  end

  defp match_column(line, {:literal, pattern, true}) do
    case :binary.match(line, pattern) do
      {offset, _} -> offset
      :nomatch -> 0
    end
  end

  defp match_column(line, {:literal, pattern, false}) do
    match_column(line, {:regex, Regex.compile!(Regex.escape(pattern), [:caseless])})
  end

  defp line_matches?(line, {:regex, regex}), do: Regex.match?(regex, line)

  defp line_matches?(line, {:literal, pattern, true}) do
    String.contains?(line, pattern)
  end

  defp line_matches?(line, {:literal, pattern, false}) do
    String.contains?(String.downcase(line), pattern)
  end

  defp build_result_from_match_refs([], _opts), do: no_matches_result()

  defp build_result_from_match_refs(refs, %{output_mode: mode} = opts)
       when mode in ["files", "count"] do
    counts = Enum.frequencies_by(refs, & &1.file_path)
    entries = Enum.sort(counts)
    page = entries |> Enum.drop(opts.skip) |> Enum.take(opts.max_results)
    incomplete? = Map.get(opts, :incomplete, false)

    {lines, shown, _, byte_limited?} =
      Enum.reduce_while(page, {[], 0, 0, false}, fn {path, count}, {lines, shown, bytes, _} ->
        line =
          display_path(path, opts.path, directory_search?(opts.path)) <>
            if(mode == "count", do: ": #{count}", else: "")

        size = byte_size(line) + 1

        if bytes + size > opts.max_bytes do
          {:halt, {lines, shown, bytes, true}}
        else
          {:cont, {[line | lines], shown + 1, bytes + size, false}}
        end
      end)

    more? = incomplete? or length(entries) > opts.skip + shown
    total = length(refs)
    qualifier = if incomplete?, do: "at least ", else: ""

    summary =
      if mode == "count",
        do: "Total: #{qualifier}#{total} matches.",
        else: "Found #{qualifier}#{length(entries)} matching files."

    notice = if more?, do: "\n\n[Use skip=#{opts.skip + shown} for the next page.]", else: ""

    details = %{
      output_mode: mode,
      match_count: total,
      file_count: length(entries),
      truncated: more? or byte_limited?
    }

    details = if more?, do: Map.put(details, :next_skip, opts.skip + shown), else: details
    details = if mode == "count", do: Map.put(details, :counts, Map.new(counts)), else: details

    %AgentToolResult{
      content: [
        %TextContent{text: summary <> "\n\n" <> Enum.join(Enum.reverse(lines), "\n") <> notice}
      ],
      details: details
    }
  end

  defp build_result_from_match_refs(match_refs, opts) do
    total_match_count = length(match_refs)
    shown_refs = match_refs |> Enum.drop(opts.skip) |> Enum.take(opts.max_results)
    incomplete? = Map.get(opts, :incomplete, false)
    match_limit_reached? = incomplete? or total_match_count > opts.skip + opts.max_results

    {formatted_lines, lines_truncated?, shown_count, byte_limit_reached?} =
      format_match_refs(shown_refs, opts)

    raw_output = Enum.join(formatted_lines, "\n")
    truncation = truncate_head_output(raw_output, opts.max_bytes)

    truncation =
      if byte_limit_reached?,
        do: %{truncation | truncated: true, truncated_by: :bytes},
        else: truncation

    more? = incomplete? or total_match_count > opts.skip + shown_count

    notices =
      []
      |> maybe_add_notice(
        shown_count == 0,
        "skip=#{opts.skip} is past the last match"
      )
      |> maybe_add_notice(
        match_limit_reached?,
        "#{opts.max_results} matches limit reached: showing matches #{opts.skip + 1}-#{opts.skip + shown_count} of #{if incomplete?, do: "at least ", else: ""}#{total_match_count}. Use skip=#{opts.skip + shown_count} for the next page, or refine pattern"
      )
      |> maybe_add_notice(
        truncation.truncated,
        "#{format_size(opts.max_bytes)} limit reached. " <>
          if(more?, do: "Use skip=#{opts.skip + shown_count} for the next page; ", else: "") <>
          "use read on the reported file and line for full text"
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

    summary =
      "Found #{if incomplete?, do: "at least ", else: ""}#{total_match_count} match#{if total_match_count == 1, do: "", else: "es"}."

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
        skip: if(opts.skip > 0, do: opts.skip),
        next_skip: if(more?, do: opts.skip + shown_count),
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

    {blocks, _cache, lines_truncated?, shown, _bytes, byte_limited?} =
      Enum.reduce_while(match_refs, {[], %{}, false, 0, 0, false}, fn match_ref,
                                                                      {blocks, cache, truncated?,
                                                                       shown, bytes, _} ->
        {lines, cache, line_truncated?} =
          format_match_ref(match_ref, opts, cache, directory_search?)

        block = Enum.join(lines, "\n")
        size = byte_size(block) + if(shown == 0, do: 0, else: 1)

        cond do
          bytes + size <= opts.max_bytes ->
            {:cont,
             {[block | blocks], cache, truncated? or line_truncated?, shown + 1, bytes + size,
              false}}

          shown == 0 ->
            {lines, cache, _} =
              format_match_ref(match_ref, %{opts | context_lines: 0}, cache, directory_search?)

            line = Enum.join(lines, "\n")
            prefix = binary_part(line, 0, min(byte_size(line), opts.max_bytes))

            prefix =
              case :unicode.characters_to_binary(prefix) do
                text when is_binary(text) -> text
                {:incomplete, text, _} -> text
                {:error, _valid, _invalid} -> prefix
              end

            {:halt, {[prefix], cache, true, 1, byte_size(prefix), true}}

          true ->
            {:halt, {blocks, cache, truncated?, shown, bytes, true}}
        end
      end)

    {Enum.reverse(blocks), lines_truncated?, shown, byte_limited?}
  end

  defp directory_search?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> true
      _ -> false
    end
  end

  defp format_match_ref(
         %{file_path: file_path, line_number: line_number} = match_ref,
         opts,
         cache,
         directory_search?
       ) do
    display_path = display_path(file_path, opts.path, directory_search?)

    case load_file_lines(file_path, cache, opts) do
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
            column = if current_line == line_number, do: Map.get(match_ref, :column, 0), else: 0
            {line_text, line_truncated?} = truncate_match_line(raw_line, column)

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

  defp load_file_lines(file_path, cache, opts) do
    case Map.fetch(cache, file_path) do
      {:ok, value} ->
        {value, cache}

      :error ->
        value =
          case read_display_file(file_path, opts) do
            {:ok, content} ->
              normalized = content |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
              {:ok, String.split(normalized, "\n", trim: false)}

            {:error, reason} ->
              {:error, reason}
          end

        {value, Map.put(cache, file_path, value)}
    end
  end

  defp read_display_file(file_path, %{bounded: true}) do
    case read_leading_window(file_path) do
      {:ok, content, _} -> {:ok, content}
      error -> error
    end
  end

  defp read_display_file(file_path, _opts), do: File.read(file_path)

  defp display_path(file_path, search_path, true) do
    relative_path = Path.relative_to(file_path, search_path)

    relative_path
  end

  defp display_path(file_path, _search_path, false), do: Path.basename(file_path)

  defp truncate_match_line(line, byte_offset) do
    if String.length(line) <= @grep_max_line_length do
      {line, false}
    else
      prefix = binary_part(line, 0, min(byte_offset, byte_size(line)))
      column = String.length(prefix)

      start =
        max(
          0,
          min(column - div(@grep_max_line_length, 2), String.length(line) - @grep_max_line_length)
        )

      window = String.slice(line, start, @grep_max_line_length)
      left = if start > 0, do: "...", else: ""
      right = if start + @grep_max_line_length < String.length(line), do: "...", else: ""
      {left <> window <> right <> " [col #{column + 1}]", true}
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
