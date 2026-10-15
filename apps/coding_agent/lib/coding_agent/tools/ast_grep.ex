defmodule CodingAgent.Tools.AstGrep do
  @moduledoc """
  Structural search and replacement backed by the real ast-grep CLI.

  `tool(cwd, opts)` exposes `ast_grep` with `action: "search" | "replace"`,
  `pattern`, optional `language`, and `paths` (local files, directories or globs).
  Search defaults to `["."]`; replacement requires an explicit nonempty scope.
  The CLI infers built-in languages from extensions when `language` is omitted.
  Unsupported languages and invalid patterns return the CLI's error; there is
  deliberately no regex fallback. Use an explicit language for ambiguous files.

  Patterns use `$NAME` for one named syntax node, `$_` for an anonymous wildcard,
  and `$$$ARGS` for zero or more nodes. Repeating `$NAME` requires identical
  captures. Rewrites reuse these captures, e.g. `oldApi($$$ARGS)` becomes
  `newApi($$$ARGS)`. An empty rewrite deletes the matched node, not surrounding
  punctuation. Undefined or anonymous rewrite captures are refused.

  Replacement defaults to `dry_run: true`. To apply, pass `dry_run: false` and
  `expected_matches` equal to the complete preview count. Output limits never
  limit the replacement scope. Plans reject overlapping matches, stale source
  bytes, binary files and symlinks (including parent directory symlinks), before
  any write. Matching and capture substitution come exclusively from CLI JSON;
  the CLI never receives `--update-all`. Writes use the normal mutation locks,
  read tracker and filesystem checkpoint guard. A session-scoped preview records
  the source digest, so an intervening edit requires re-reading before applying.
  Multi-file writes are not an atomic filesystem transaction: failures after
  checkpoint creation preserve `checkpoint_id`, mark the result as an error,
  and report `partial` plus `written_paths` so session rewind can restore them.

  ## Backend installation and availability

  Install with `brew install ast-grep`, `npm install -g @ast-grep/cli`, or download
  a platform archive from https://github.com/ast-grep/ast-grep/releases.
  `availability(opts)` probes `ast-grep`, then `sg`, on PATH and verifies its
  version identifies ast-grep (the Unix group-switching `sg` is not accepted).
  Set `:ast_grep_executable` to an absolute executable path to override discovery.
  Missing or incompatible backends return actionable installation guidance.
  No installation, network access or credential discovery occurs at runtime.

  Options: `:ast_grep_timeout_ms` (30_000), `:max_bytes` (32_768), `:spill_dir`
  (system temp directory), plus the standard session/checkpoint options. Large
  results spill complete JSONL match records to `full_output_path`; use `read`
  with offset/limit to retrieve them. Visible positions are one-based; CLI JSON
  ranges and capture locations in the spill are zero-based, with exclusive ends.
  Tool output remains tagged as untrusted local search data.
  """

  alias CodingAgent.{FileReadTracker, MutationLock}
  alias CodingAgent.Tools.{CheckpointGuard, FileValidation, PathHelpers}
  alias CodingAgent.Tools.AstGrep.Backend
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  @install "Install ast-grep with `brew install ast-grep` or `npm install -g @ast-grep/cli`, or download a platform binary from https://github.com/ast-grep/ast-grep/releases. Put ast-grep on PATH or set :ast_grep_executable to its absolute path."
  @capture ~r/\${1,3}([A-Z_][A-Z_0-9]*)/

  @doc "Returns the native ast_grep tool. Replacement calls are not parallel-safe."
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "ast_grep",
      label: "Structural Search / Replace",
      parallel_safe: false,
      description:
        "Search or replace code with real ast-grep AST patterns, not regex. " <>
          "$NAME captures one syntax node, $_ ignores a node, $$$ARGS captures zero or more nodes; " <>
          "repeated named captures enforce identity. Example pattern oldApi($$$ARGS), rewrite newApi($$$ARGS). " <>
          "Infer language from extensions or specify language (e.g. typescript, python, cpp). " <>
          "Replace requires explicit paths and rewrite; preview defaults to dry_run=true. " <>
          "Apply with dry_run=false and expected_matches equal to the full preview count. " <>
          "Undefined captures, overlaps, stale files and symlink writes are refused. " <>
          "max_results limits display only, never replacement scope. Large results give a readable spill path. " <>
          "Requires ast-grep CLI; there is no text-search fallback.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["search", "replace"],
            "description" => "Search syntax or preview/apply replacement"
          },
          "pattern" => %{
            "type" => "string",
            "description" => "AST pattern, e.g. console.log($$$ARGS) or $X && $X.foo"
          },
          "language" => %{
            "type" => ["string", "null"],
            "description" =>
              "ast-grep language name; omit or pass null to infer from file extensions"
          },
          "paths" => %{
            "type" => ["array", "null"],
            "items" => %{"type" => "string"},
            "description" =>
              "Local files, directories or globs relative to cwd; search defaults to ['.']; replace requires explicit scope"
          },
          "rewrite" => %{
            "type" => ["string", "null"],
            "description" =>
              "Replacement template; omit or pass null for search. Empty string deletes matched syntax nodes"
          },
          "dry_run" => %{
            "type" => "boolean",
            "description" => "Preview replacement without writing (default true)"
          },
          "expected_matches" => %{
            "type" => ["integer", "null"],
            "minimum" => 0,
            "description" =>
              "Apply-only exact match count when dry_run=false; omit or pass null on preview. Mismatch refuses every write"
          },
          "max_results" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 1000,
            "description" => "Visible matches (default 100); does not limit writes"
          }
        },
        "required" => ["action", "pattern"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc "Checks executable discovery and ast-grep identity; never installs a backend."
  @spec availability(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def availability(opts \\ []) do
    candidates =
      case Keyword.get(opts, :ast_grep_executable) do
        nil ->
          Enum.reject(
            [System.find_executable("ast-grep"), System.find_executable("sg")],
            &is_nil/1
          )

        path when is_binary(path) ->
          [Path.expand(path)]

        _ ->
          []
      end

    Enum.find_value(
      candidates,
      {:error, "ast-grep CLI is unavailable or incompatible. " <> @install},
      fn path ->
        case Backend.run(path, ["--version"], File.cwd!(), nil, 5_000) do
          {:ok, {version, 0}} ->
            if Regex.match?(~r/\Aast-grep \d+\.\d+\.\d+/, String.trim(version)), do: {:ok, path}

          _ ->
            nil
        end
      end
    )
  end

  @doc "Executes a structural search or a guarded replacement."
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    result =
      with :ok <- check_abort(signal),
           {:ok, request} <- validate(params),
           {:ok, paths} <- resolve_paths(request.paths, cwd),
           {:ok, executable} <- availability(opts),
           {:ok, {output, status}} <-
             Backend.run(
               executable,
               arguments(request, paths),
               cwd,
               signal,
               Keyword.get(opts, :ast_grep_timeout_ms, 30_000)
             ),
           {:ok, matches} <- decode_matches(output, status),
           matches <- normalize_matches(matches, cwd),
           :ok <- check_abort(signal) do
        dispatch(request, matches, signal, cwd, opts)
      end

    result
    |> format_error()
    |> ToolResultTrust.untrusted(:local_search)
  end

  defp validate(params) when is_map(params) do
    action = params["action"]
    pattern = params["pattern"]
    language = params["language"]

    paths =
      case params["paths"] do
        nil -> ["."]
        paths -> paths
      end

    rewrite = params["rewrite"]
    dry_run = Map.get(params, "dry_run", true)
    expected = params["expected_matches"]
    limit = Map.get(params, "max_results", 100)

    cond do
      action not in ["search", "replace"] ->
        {:error, "action must be search or replace"}

      not is_binary(pattern) ->
        {:error, "pattern must be a nonempty string"}

      String.trim(pattern) == "" or byte_size(pattern) > 10_000 ->
        {:error, "pattern must contain 1-10000 bytes"}

      not is_nil(language) and (not is_binary(language) or language == "") ->
        {:error, "language must be a nonempty string"}

      not is_list(paths) or paths == [] ->
        {:error, "paths must be a nonempty list of local paths"}

      not Enum.all?(
        paths,
        &(is_binary(&1) and String.trim(&1) != "" and byte_size(&1) <= 4096 and
              not String.contains?(&1, <<0>>))
      ) ->
        {:error, "paths must contain nonempty local path strings without NUL bytes"}

      not is_boolean(dry_run) ->
        {:error, "dry_run must be boolean"}

      not is_integer(limit) or limit < 1 or limit > 1000 ->
        {:error, "max_results must be an integer from 1 to 1000"}

      not is_nil(expected) and (not is_integer(expected) or expected < 0) ->
        {:error, "expected_matches must be a nonnegative integer"}

      action == "search" and not is_nil(rewrite) ->
        {:error, "rewrite is only valid for action=replace"}

      action == "replace" and is_nil(params["paths"]) ->
        {:error, "replace requires explicit paths; preview a bounded scope first"}

      action == "replace" and not is_binary(rewrite) ->
        {:error, "replace requires rewrite (an empty string deletes matches)"}

      action == "replace" and not dry_run and is_nil(expected) ->
        {:error, "Applying replacement requires expected_matches from a dry-run preview"}

      true ->
        with :ok <- FileValidation.check_text_content(pattern, "pattern"),
             :ok <- validate_rewrite(action, rewrite) do
          {:ok,
           %{
             action: action,
             pattern: pattern,
             language: language,
             paths: paths,
             rewrite: rewrite,
             dry_run: dry_run,
             expected: expected,
             limit: limit
           }}
        end
    end
  end

  defp validate(_), do: {:error, "Tool arguments must be an object"}
  defp validate_rewrite("search", _), do: :ok

  defp validate_rewrite("replace", rewrite),
    do: FileValidation.check_text_content(rewrite, "rewrite")

  defp resolve_paths(paths, cwd) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      resolved = PathHelpers.resolve_path(path, cwd)

      expanded =
        if String.contains?(resolved, ["*", "?", "[", "{"]),
          do: Path.wildcard(resolved),
          else: [resolved]

      case validate_paths(expanded) do
        :ok -> {:cont, {:ok, acc ++ expanded}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.uniq(paths)}
      error -> error
    end
  rescue
    error in [ArgumentError] -> {:error, "Invalid path glob: #{Exception.message(error)}"}
  end

  defp validate_paths([]), do: {:error, "A path glob matched no files or directories"}

  defp validate_paths(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case FileValidation.check_path_access(path, [:regular, :directory]) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp arguments(request, paths) do
    args = [
      "run",
      "--json=stream",
      "--color=never",
      "--threads=1",
      "--pattern=" <> request.pattern
    ]

    args = if request.language, do: args ++ ["--lang=" <> request.language], else: args

    args =
      if request.action == "replace", do: args ++ ["--rewrite=" <> request.rewrite], else: args

    args ++ ["--" | paths]
  end

  defp decode_matches(output, status) when status in [0, 1] do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok,
         %{
           "file" => file,
           "text" => text,
           "range" => %{
             "byteOffset" => %{"start" => start, "end" => finish},
             "start" => %{"line" => row, "column" => column}
           }
         } = match}
        when is_binary(file) and is_binary(text) and is_integer(start) and is_integer(finish) and
               start >= 0 and finish > start and is_integer(row) and row >= 0 and
               is_integer(column) and column >= 0 ->
          {:cont, {:ok, [match | acc]}}

        _ ->
          {:halt,
           {:error, "ast-grep returned invalid JSON match output: " <> bounded(line, 2000)}}
      end
    end)
    |> case do
      {:ok, matches} -> {:ok, Enum.reverse(matches)}
      error -> error
    end
  end

  defp decode_matches(output, status),
    do: {:error, "ast-grep exited with status #{status}: " <> bounded(output, 4000)}

  defp normalize_matches(matches, cwd) do
    matches
    |> Enum.map(&Map.update!(&1, "file", fn file -> Path.expand(file, cwd) end))
    |> Enum.uniq_by(&{&1["file"], &1["range"]["byteOffset"]})
    |> Enum.sort_by(&{&1["file"], &1["range"]["byteOffset"]["start"]})
  end

  defp dispatch(%{action: "search"} = request, matches, _signal, _cwd, opts) do
    result(request, matches, false, nil, opts)
  end

  defp dispatch(request, matches, signal, cwd, opts) do
    paths = matches |> Enum.map(& &1["file"]) |> Enum.uniq()

    MutationLock.with_locks(Enum.map(paths, &MutationLock.path_key/1), fn ->
      with :ok <- check_expected(request, length(matches)),
           {:ok, plans} <- plan_files(matches, request, cwd, opts),
           :ok <- check_abort(signal) do
        if request.dry_run or plans == [] do
          with %AgentToolResult{} = preview <- result(request, matches, false, nil, opts) do
            Enum.each(plans, &FileReadTracker.record(opts, &1.path, &1.source))
            preview
          end
        else
          apply_plans(request, matches, plans, signal, cwd, opts)
        end
      end
    end)
  end

  defp check_expected(%{dry_run: true}, _count), do: :ok
  defp check_expected(%{expected: nil}, _count), do: :ok
  defp check_expected(%{expected: count}, count), do: :ok

  defp check_expected(%{expected: expected}, actual),
    do:
      {:error,
       "Expected #{expected} matches but found #{actual}; no files written. Preview again before applying."}

  defp plan_files(matches, request, cwd, opts) do
    matches
    |> Enum.group_by(& &1["file"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {path, file_matches}, {:ok, plans} ->
      with :ok <- FileValidation.check_mutation_target(path, mutation_opts(opts, cwd)),
           {:ok, source} <- File.read(path),
           :ok <- FileValidation.check_text_content(source, path),
           :ok <- FileReadTracker.check(opts, path, source),
           {:ok, rewritten} <- rewrite_source(source, file_matches, request.rewrite) do
        {:cont, {:ok, [%{path: path, source: source, rewritten: rewritten} | plans]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      error -> error
    end
  end

  defp mutation_opts(opts, cwd),
    do: opts |> Keyword.put(:mutation_root, cwd) |> Keyword.put(:allow_symlinks, false)

  defp rewrite_source(source, matches, template) do
    matches = Enum.sort_by(matches, & &1["range"]["byteOffset"]["start"])

    Enum.reduce_while(matches, {:ok, 0, []}, fn match, {:ok, cursor, parts} ->
      %{"start" => start, "end" => finish} = match["range"]["byteOffset"]
      replacement = match["replacement"]
      offsets = match["replacementOffsets"]

      cond do
        start < cursor ->
          {:halt,
           {:error,
            "Overlapping AST matches are ambiguous; narrow the pattern or scope. No files written."}}

        finish > byte_size(source) ->
          {:halt,
           {:error,
            "AST match range exceeds source; file changed during search. Re-read and preview again."}}

        binary_part(source, start, finish - start) != match["text"] ->
          {:halt,
           {:error,
            "Source changed during structural search. Re-read and preview again; no files written."}}

        not is_binary(replacement) or offsets != match["range"]["byteOffset"] ->
          {:halt,
           {:error,
            "ast-grep did not return an exact replacement range; no files written. Upgrade the CLI."}}

        true ->
          with :ok <- validate_captures(template, match),
               :ok <- FileValidation.check_text_content(replacement, "CLI replacement") do
            prefix = binary_part(source, cursor, start - cursor)
            {:cont, {:ok, finish, [replacement, prefix | parts]}}
          else
            error -> {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, cursor, parts} ->
        {:ok,
         IO.iodata_to_binary(
           Enum.reverse([binary_part(source, cursor, byte_size(source) - cursor) | parts])
         )}

      error ->
        error
    end
  end

  defp validate_captures(template, match) do
    variables = Map.get(match, "metaVariables", %{})

    names =
      Enum.flat_map(["single", "multi", "transformed"], &Map.keys(Map.get(variables, &1, %{})))

    case Regex.scan(@capture, template)
         |> Enum.map(&List.last/1)
         |> Enum.find(&(String.starts_with?(&1, "_") or &1 not in names)) do
      nil ->
        :ok

      name ->
        {:error,
         "Rewrite references uncaptured or anonymous $#{name}; no files written. Use a named capture present in the pattern."}
    end
  end

  defp apply_plans(request, matches, plans, signal, cwd, opts) do
    paths = Enum.map(plans, & &1.path)

    with %AgentToolResult{} = prepared <- result(request, matches, true, nil, opts),
         {:ok, checkpoint} <-
           CheckpointGuard.before_mutation(paths, cwd, opts, %{
             tool: "ast_grep",
             action: "replace"
           }) do
      outcome =
        with :ok <- recheck_plans(plans, signal, cwd, opts) do
          write_plans(plans, signal, cwd, opts)
        end

      case outcome do
        :ok ->
          %{prepared | details: CheckpointGuard.put_details(prepared.details, checkpoint)}

        {:error, %{message: message, written_paths: written_paths}} ->
          apply_failure(message, written_paths, paths, checkpoint)

        {:error, reason} ->
          message =
            if is_binary(reason), do: reason, else: "Replacement stopped: #{inspect(reason)}."

          apply_failure(message, [], paths, checkpoint)
      end
    end
  end

  defp apply_failure(message, written_paths, paths, checkpoint) do
    %AgentToolResult{
      content: [%TextContent{text: message}],
      is_error: true,
      details:
        %{
          action: "replace",
          applied: false,
          partial: written_paths != [],
          written_paths: written_paths,
          paths: paths
        }
        |> CheckpointGuard.put_details(checkpoint)
    }
  end

  defp recheck_plans(plans, signal, cwd, opts) do
    Enum.reduce_while(plans, :ok, fn plan, :ok ->
      with :ok <- check_abort(signal),
           :ok <- FileValidation.check_mutation_target(plan.path, mutation_opts(opts, cwd)),
           {:ok, current} <- File.read(plan.path),
           true <- current == plan.source do
        {:cont, :ok}
      else
        false ->
          {:halt,
           {:error,
            "#{plan.path} changed since preview; no files written. Re-read and preview again."}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp write_plans(plans, signal, cwd, opts) do
    Enum.reduce_while(plans, {:ok, []}, fn plan, {:ok, written} ->
      with :ok <- check_abort(signal),
           :ok <- FileValidation.check_mutation_target(plan.path, mutation_opts(opts, cwd)),
           {:ok, current} <- File.read(plan.path),
           true <- current == plan.source,
           :ok <- File.write(plan.path, plan.rewritten) do
        FileReadTracker.record(opts, plan.path, plan.rewritten)
        {:cont, {:ok, [plan.path | written]}}
      else
        error ->
          {:halt,
           {:error,
            %{
              message:
                "Replacement stopped: #{inspect(error)}. Already-written paths: #{inspect(Enum.reverse(written))}. Do not retry blindly; inspect these files first.",
              written_paths: Enum.reverse(written)
            }}}
      end
    end)
    |> case do
      {:ok, _written} -> :ok
      error -> error
    end
  end

  defp result(request, matches, applied, checkpoint, opts) do
    visible = Enum.take(matches, request.limit)
    files = matches |> Enum.map(& &1["file"]) |> Enum.uniq()

    heading =
      case request.action do
        "search" ->
          "#{length(matches)} structural matches in #{length(files)} files."

        "replace" ->
          "#{if applied, do: "Applied", else: "Preview:"} #{length(matches)} replacements in #{length(files)} files."
      end

    body = Enum.map_join(visible, "\n\n", &format_match(&1, request.action))
    text = if matches == [], do: heading <> " No matches found.", else: heading <> "\n\n" <> body
    max_bytes = Keyword.get(opts, :max_bytes, 32_768)
    truncated = length(matches) > request.limit or byte_size(text) > max_bytes

    details =
      %{
        action: request.action,
        applied: applied,
        match_count: length(matches),
        file_count: length(files),
        truncated: truncated,
        matches: Enum.map(visible, &Map.take(&1, ["file", "range", "language"]))
      }
      |> CheckpointGuard.put_details(checkpoint)

    if truncated do
      with {:ok, path} <- spill(matches, opts) do
        note =
          "\n\n[Full JSONL matches saved to: #{path}. Use read with offset/limit. Display limits do not limit writes.]"

        %AgentToolResult{
          content: [
            %TextContent{text: bounded(text, max(max_bytes - byte_size(note), 0)) <> note}
          ],
          details: Map.put(details, :full_output_path, path)
        }
      end
    else
      %AgentToolResult{content: [%TextContent{text: text}], details: details}
    end
  end

  defp format_match(match, action) do
    start = match["range"]["start"]
    location = "#{match["file"]}:#{start["line"] + 1}:#{start["column"] + 1}"
    captures = Jason.encode!(Map.get(match, "metaVariables", %{}))

    replacement =
      if action == "replace", do: "\nRewrite: " <> Map.get(match, "replacement", ""), else: ""

    location <> "\n" <> match["text"] <> replacement <> "\nCaptures: " <> captures
  end

  defp spill(matches, opts) do
    dir = Keyword.get(opts, :spill_dir, System.tmp_dir!())

    path =
      Path.join(dir, "lemon-ast-grep-#{System.unique_integer([:positive, :monotonic])}.jsonl")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, Enum.map(matches, &[Jason.encode!(&1), "\n"]), [:exclusive]) do
      {:ok, path}
    else
      {:error, reason} -> {:error, "Cannot save complete structural result: #{inspect(reason)}"}
    end
  end

  defp bounded(text, bytes) when byte_size(text) <= bytes, do: text

  defp bounded(text, bytes) do
    prefix = binary_part(text, 0, bytes)
    trim_invalid_suffix(prefix)
  end

  defp trim_invalid_suffix(text) do
    if String.valid?(text),
      do: text,
      else: trim_invalid_suffix(binary_part(text, 0, byte_size(text) - 1))
  end

  defp format_error({:error, :stale}),
    do:
      {:error,
       "File changed since your last read. Re-read the file and preview again; no files written."}

  defp format_error({:error, reason}) when is_atom(reason),
    do: {:error, "Structural operation failed: #{reason}"}

  defp format_error(other), do: other
end
