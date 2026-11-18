defmodule CodingAgent.Tools.LspDiagnostics do
  @moduledoc """
  Workspace-aware diagnostics for files touched by coding tools.

  This is the first Lemon diagnostic layer: it gives agents a stable
  `lsp_diagnostics` tool and lets mutation tools report post-edit diagnostic
  deltas without failing the edit when a checker is missing.

  Lemon reads the diagnosed file itself through the identity-bound
  `CodingAgent.Tools.FileValidation` helpers below the same boundary mutation
  tools use (`mutation_root:`, default `cwd`): a symlink anywhere below it is
  refused, FIFOs and other special files are refused, and content reads are
  bounded (8 MiB). Elixir syntax is parsed from those bytes, and Python syntax
  is compiled from a private staged copy of them
  (`CodingAgent.Tools.CheckerStaging`; nothing is written next to the source,
  unlike `py_compile`).

  The other checkers read the project themselves and are outside Lemon's
  confined I/O: `node --check` and the C/C++ `-fsyntax-only` compilers read
  the file by path; `mix compile`, `tsc --noEmit`, `cargo check` and
  `go vet` build the project in its root and may write that project's own
  build outputs (`_build`, `target`, `.tsbuildinfo`, the Go cache). Marker
  probes that pick the project root (`mix.exs`, `tsconfig.json`, ...) are
  path-based too. No checker is handed a path it writes.
  """

  alias CodingAgent.Tools.Bash.CommandPolicy
  alias CodingAgent.Tools.{CheckerRunner, CheckerStaging, FileValidation, PathHelpers}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.Doctor.LspDiagnostics, as: DoctorLspDiagnostics

  @default_timeout_ms 20_000

  # Bound on the bytes Lemon reads from a diagnosed file.
  @max_source_bytes 8 * 1024 * 1024

  # Syntax-checks the staged copy (argv[1]) under the workspace name (argv[2])
  # without writing bytecode; `-I` keeps the working directory off sys.path.
  @python_compile """
  import sys, traceback
  with open(sys.argv[1], "rb") as source:
      code = source.read()
  try:
      compile(code, sys.argv[2], "exec", dont_inherit=True)
  except (SyntaxError, ValueError) as error:
      sys.stderr.write("".join(traceback.format_exception_only(type(error), error)))
      sys.exit(1)
  """

  @doc """
  Returns the diagnostics tool definition.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "lsp_diagnostics",
      description:
        "Run language diagnostics for a file using the workspace's local language tooling when available.",
      label: "LSP Diagnostics",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "File path to diagnose, relative to cwd or absolute"
          }
        },
        "required" => ["path"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute the diagnostics tool.
  """
  @spec execute(String.t(), map(), reference() | nil, function() | nil, String.t(), keyword()) ::
          AgentToolResult.t() | {:error, String.t()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, opts) do
    with {:ok, path} <- get_path(params),
         {:ok, result} <- diagnose_file(path, cwd, Keyword.put(opts, :signal, signal)) do
      %AgentToolResult{
        content: [%TextContent{text: render_result(result)}],
        details: result
      }
    end
  end

  @doc """
  Run diagnostics for one file.
  """
  @spec diagnose_file(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def diagnose_file(path, cwd, opts \\ [])

  def diagnose_file(path, cwd, opts) when is_binary(path) and is_binary(cwd) do
    resolved_path = PathHelpers.resolve_path(path, cwd, Keyword.put(opts, :expand, false))
    ext = resolved_path |> Path.extname() |> String.downcase()
    language = language_for_extension(ext)
    opts = Keyword.put(opts, :workspace_cwd, Path.expand(cwd))

    with :ok <- check_policy(opts),
         {:ok, source} <- read_source(resolved_path, language, cwd, opts) do
      case language do
        nil ->
          {:ok, skipped_result(resolved_path, nil, "unsupported file extension")}

        :elixir ->
          diagnose_elixir(resolved_path, source, cwd, opts)

        language ->
          diagnose_external(language, resolved_path, source, cwd, opts)
      end
    end
  end

  def diagnose_file(_path, _cwd, _opts), do: {:error, "path and cwd must be strings"}

  @doc """
  Return a baseline result if diagnostics are enabled.
  """
  @spec baseline(String.t(), String.t(), boolean(), keyword()) :: map() | nil
  def baseline(_path, _cwd, false, _opts), do: nil

  def baseline(path, cwd, true, opts) do
    if CommandPolicy.restricted?(Keyword.get(opts, :tool_policy)),
      do: nil,
      else: run_baseline(path, cwd, opts)
  end

  defp run_baseline(path, cwd, opts) do
    case diagnose_file(path, cwd, opts) do
      {:ok, result} -> result
      {:error, reason} -> %{status: :failed, diagnostics: [], error: reason}
    end
  end

  @doc """
  Run post-edit diagnostics and compute diagnostics introduced after a baseline.
  """
  @spec post_edit(String.t(), String.t(), map() | nil, boolean(), keyword()) ::
          {map() | nil, String.t()}
  def post_edit(_path, _cwd, _baseline, false, _opts), do: {nil, ""}

  def post_edit(path, cwd, baseline, true, opts) do
    if CommandPolicy.restricted?(Keyword.get(opts, :tool_policy)),
      do: {nil, ""},
      else: run_post_edit(path, cwd, baseline, opts)
  end

  defp run_post_edit(path, cwd, baseline, opts) do
    result =
      case diagnose_file(path, cwd, opts) do
        {:ok, result} -> result
        {:error, reason} -> %{status: :failed, diagnostics: [], error: reason}
      end

    introduced = introduced_diagnostics(result, baseline)
    enriched = Map.put(result, :introduced_diagnostics, introduced)
    {enriched, render_post_edit_summary(enriched)}
  end

  @doc """
  Extract a boolean diagnostics option from tool params and defaults.
  """
  @spec option(map(), keyword()) :: {:ok, boolean()} | {:error, String.t()}
  # Project diagnostics (`mix compile`, checkers, compilers) run project code
  # that no command list can inspect: under `allowed_commands`/
  # `blocked_commands` an explicit `diagnostics: true` is refused and a
  # configured default is skipped.
  def option(params, opts) do
    explicit? = Map.has_key?(params, "diagnostics")
    value = Map.get(params, "diagnostics", Keyword.get(opts, :diagnostics, false))

    case value do
      true ->
        cond do
          not CommandPolicy.restricted?(Keyword.get(opts, :tool_policy)) -> {:ok, true}
          explicit? -> {:error, CommandPolicy.unavailable("diagnostics")}
          true -> {:ok, false}
        end

      false ->
        {:ok, false}

      _ ->
        {:error, "diagnostics must be a boolean"}
    end
  end

  defp check_policy(opts) do
    if CommandPolicy.restricted?(Keyword.get(opts, :tool_policy)),
      do: {:error, CommandPolicy.unavailable("lsp_diagnostics")},
      else: :ok
  end

  @doc """
  Return redacted diagnostics capability metadata for operator surfaces.
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    DoctorLspDiagnostics.status(opts)
  end

  @doc """
  Render diagnostics as compact lines suitable for tool output.
  """
  @spec render_diagnostics([map()]) :: String.t()
  def render_diagnostics(diagnostics) do
    diagnostics
    |> Enum.take(10)
    |> Enum.map(fn diagnostic ->
      path = Map.get(diagnostic, :path) || Map.get(diagnostic, "path") || "unknown"
      line = Map.get(diagnostic, :line) || Map.get(diagnostic, "line") || 1
      column = Map.get(diagnostic, :column) || Map.get(diagnostic, "column") || 1
      severity = Map.get(diagnostic, :severity) || Map.get(diagnostic, "severity") || "error"
      message = Map.get(diagnostic, :message) || Map.get(diagnostic, "message") || ""
      "#{path}:#{line}:#{column}: #{severity}: #{message}"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Return diagnostics present in `result` but absent from `baseline`.
  """
  @spec introduced_diagnostics(map(), map() | nil) :: [map()]
  def introduced_diagnostics(%{diagnostics: diagnostics}, nil), do: diagnostics

  def introduced_diagnostics(%{diagnostics: diagnostics}, %{diagnostics: baseline}) do
    baseline_keys = MapSet.new(Enum.map(baseline, &diagnostic_key/1))

    Enum.reject(diagnostics, fn diagnostic ->
      MapSet.member?(baseline_keys, diagnostic_key(diagnostic))
    end)
  end

  def introduced_diagnostics(_result, _baseline), do: []

  defp get_path(%{"path" => path}) when is_binary(path) and byte_size(path) > 0 do
    {:ok, path}
  end

  defp get_path(%{"path" => _}), do: {:error, "path must be a non-empty string"}
  defp get_path(_), do: {:error, "missing required parameter: path"}

  # Elixir and Python are checked from these bytes; for the other languages
  # only the file's identity (a regular file, no symlink) is checked.
  defp read_source(path, language, cwd, opts) do
    io_opts = Keyword.put_new(opts, :mutation_root, cwd)

    with {:ok, identity} <- FileValidation.regular_file_identity(path, io_opts) do
      if language in [:elixir, :python],
        do: FileValidation.read_regular_file(path, identity, max_bytes: @max_source_bytes),
        else: {:ok, nil}
    end
    |> case do
      {:ok, source} -> {:ok, source}
      {:error, :enoent} -> {:error, "file not found: #{path}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "cannot access file #{path}: #{inspect(reason)}"}
    end
  end

  defp language_for_extension(ext) do
    cond do
      ext in [".ex", ".exs", ".heex"] -> :elixir
      ext in [".js", ".cjs", ".mjs"] -> :javascript
      ext in [".ts", ".tsx", ".jsx"] -> :typescript
      ext == ".py" -> :python
      ext == ".rs" -> :rust
      ext == ".go" -> :go
      ext in [".c", ".h", ".cc", ".cpp", ".cxx", ".hh", ".hpp", ".hxx"] -> :c_cpp
      true -> nil
    end
  end

  defp diagnose_elixir(path, content, cwd, opts) do
    case Code.string_to_quoted(content, file: path) do
      {:ok, _ast} ->
        case find_workspace_root(path, cwd, ["mix.exs"]) do
          nil ->
            {:ok, clean_result(path, :elixir, "elixir syntax")}

          root ->
            if Keyword.get(opts, :semantic, true) do
              run_mix_compile(path, root, opts)
            else
              {:ok, clean_result(path, :elixir, "elixir syntax")}
            end
        end

      {:error, {meta, message, token}} ->
        {:ok,
         diagnostic_result(path, :elixir, [
           %{
             path: path,
             line: Keyword.get(meta, :line, 1),
             column: Keyword.get(meta, :column, 1),
             severity: "error",
             message: String.trim("#{message} #{token}"),
             source: "elixir syntax"
           }
         ])}
    end
  end

  defp run_mix_compile(path, root, opts) do
    case CheckerRunner.resolve("mix", checker_roots(root, opts), opts) do
      {:ok, mix} ->
        case run_command(mix, ["compile", "--return-errors"], root, opts) do
          {output, 0} ->
            {:ok, clean_result(path, :elixir, "mix compile", output)}

          {output, status} ->
            diagnostics = parse_generic_diagnostics(output, root, "mix compile")
            result = diagnostic_result(path, :elixir, diagnostics)
            {:ok, Map.put(result, :command_exit_status, status)}
        end

      _missing_or_repo_local ->
        {:ok, clean_result(path, :elixir, "elixir syntax")}
    end
  end

  defp diagnose_external(language, path, source, cwd, opts) do
    case external_runner(language, path, cwd) do
      {:ok, %{command: command, args: args, root: root, source: source_label} = runner} ->
        case resolve_runner_command(command, Map.get(runner, :repo_local), root, opts) do
          :missing ->
            {:ok, skipped_result(path, language, "missing executable: #{command}")}

          :repo_local ->
            {:ok,
             skipped_result(
               path,
               language,
               "refused repo-local executable: #{command} (runtime.tools.edit.repo_local_tools)"
             )}

          {:ok, executable} ->
            case run_runner(executable, args, source, root, opts) do
              {output, 0} ->
                {:ok, clean_result(path, language, source_label, output)}

              {output, status} ->
                diagnostics = parse_external_diagnostics(language, output, root, source_label)
                result = diagnostic_result(path, language, diagnostics)

                {:ok,
                 Map.merge(result, %{command_exit_status: status, raw_output: trim_output(output)})}
            end
        end

      {:skip, reason} ->
        {:ok, skipped_result(path, language, reason)}
    end
  end

  # `:staged_source` in `args` is a private copy of the bytes Lemon read.
  defp run_runner(executable, args, source, root, opts) do
    if :staged_source in args do
      CheckerStaging.with_dir(fn stage ->
        case CheckerStaging.write(stage, "source", source) do
          :ok ->
            staged = CheckerStaging.path(stage, "source")
            args = Enum.map(args, &if(&1 == :staged_source, do: staged, else: &1))
            run_command(executable, args, root, opts)

          {:error, reason} ->
            {"cannot stage diagnostics input (#{reason})", 1}
        end
      end)
      |> case do
        {:error, message} -> {message, 1}
        result -> result
      end
    else
      run_command(executable, args, root, opts)
    end
  end

  # A project-provided binary (e.g. `node_modules/.bin/tsc`) is used only when
  # the operator opted in; otherwise only the operator's PATH counts.
  defp resolve_runner_command(command, repo_local, root, opts) do
    if is_binary(repo_local) and CheckerRunner.repo_local_allowed?(opts) and
         File.exists?(repo_local),
       do: {:ok, repo_local},
       else: CheckerRunner.resolve(command, checker_roots(root, opts), opts)
  end

  defp checker_roots(root, opts), do: [Keyword.get(opts, :workspace_cwd), root]

  defp external_runner(:javascript, path, _cwd) do
    {:ok,
     %{command: "node", args: ["--check", path], root: Path.dirname(path), source: "node --check"}}
  end

  defp external_runner(:typescript, path, cwd) do
    root = find_workspace_root(path, cwd, ["tsconfig.json", "package.json"])

    cond do
      root && File.exists?(Path.join(root, "tsconfig.json")) ->
        {command, repo_local, args} = typescript_command(root)

        {:ok,
         %{
           command: command,
           repo_local: repo_local,
           args: args,
           root: root,
           source: "tsc --noEmit"
         }}

      true ->
        {:skip, "no tsconfig.json found"}
    end
  end

  defp external_runner(:python, path, _cwd) do
    {:ok,
     %{
       command: python_command(),
       args: ["-I", "-B", "-c", @python_compile, :staged_source, path],
       root: Path.dirname(path),
       source: "python compile"
     }}
  end

  defp external_runner(:rust, path, cwd) do
    case find_workspace_root(path, cwd, ["Cargo.toml"]) do
      nil ->
        {:skip, "no Cargo.toml found"}

      root ->
        {:ok,
         %{
           command: "cargo",
           args: ["check", "--message-format=short"],
           root: root,
           source: "cargo check"
         }}
    end
  end

  defp external_runner(:go, path, cwd) do
    case find_workspace_root(path, cwd, ["go.mod"]) do
      nil -> {:skip, "no go.mod found"}
      root -> {:ok, %{command: "go", args: ["vet", "./..."], root: root, source: "go vet"}}
    end
  end

  defp external_runner(:c_cpp, path, _cwd) do
    case c_cpp_command(path) do
      nil ->
        {:skip, "missing C/C++ compiler"}

      {command, source} ->
        {:ok,
         %{
           command: command,
           args: ["-fsyntax-only", path],
           root: Path.dirname(path),
           source: source
         }}
    end
  end

  defp typescript_command(root) do
    {"tsc", Path.join([root, "node_modules", ".bin", "tsc"]), ["--noEmit", "--pretty", "false"]}
  end

  defp c_cpp_command(path) do
    candidates =
      case path |> Path.extname() |> String.downcase() do
        ext when ext in [".c", ".h"] -> ["clang", "gcc", "cc"]
        _ -> ["clang++", "g++", "c++"]
      end

    Enum.find_value(candidates, fn command ->
      if System.find_executable(command), do: {command, "#{command} -fsyntax-only"}
    end)
  end

  defp python_command do
    cond do
      System.find_executable("python3") -> "python3"
      true -> "python"
    end
  end

  defp run_command(executable, args, cwd, opts) do
    timeout_ms = Keyword.get(opts, :diagnostics_timeout_ms, @default_timeout_ms)

    case CheckerRunner.run(executable, args, cwd, timeout_ms, 64_000, opts) do
      {:ok, %{timed_out: true}} ->
        {"diagnostics timed out after #{timeout_ms}ms", 124}

      {:ok, %{cancelled: true}} ->
        {"diagnostics cancelled", 130}

      {:ok, %{output: output, exit_code: status}} ->
        {output, status || 1}

      {:error, {:checker_survived, id}} ->
        {"checker process group survived kill (proc://#{id})", 1}

      {:error, {:outcome_unknown, id}} ->
        {"checker launch outcome unknown (proc://#{id})", 1}

      {:error, _reason} ->
        {"diagnostics command failed to start", 1}
    end
  end

  defp find_workspace_root(path, cwd, markers) do
    path
    |> Path.dirname()
    |> Path.expand(cwd)
    |> ancestors()
    |> Enum.find(fn dir ->
      Enum.any?(markers, fn marker -> File.exists?(Path.join(dir, marker)) end)
    end)
  end

  defp ancestors(path) do
    expanded = Path.expand(path)

    Stream.unfold(expanded, fn
      nil ->
        nil

      "/" ->
        {"/", nil}

      dir ->
        {dir, Path.dirname(dir)}
    end)
    |> Enum.uniq()
  end

  defp clean_result(path, language, source, raw_output \\ "") do
    %{
      status: :clean,
      path: path,
      language: language,
      source: source,
      diagnostics: [],
      raw_output: trim_output(raw_output)
    }
  end

  defp diagnostic_result(path, language, diagnostics) do
    %{
      status: :diagnostics,
      path: path,
      language: language,
      diagnostics: diagnostics
    }
  end

  defp skipped_result(path, language, reason) do
    %{
      status: :skipped,
      path: path,
      language: language,
      diagnostics: [],
      reason: reason
    }
  end

  defp parse_external_diagnostics(:python, output, root, source) do
    file_line =
      Regex.run(~r/File "([^"]+)", line (\d+)/, output, capture: :all_but_first) ||
        [nil, "1"]

    message =
      output
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find(
        "python diagnostic",
        &(&1 =~ ~r/(Error|SyntaxError|IndentationError|NameError|TypeError)/)
      )
      |> String.trim()

    [path, line] = file_line

    [
      %{
        path: absolutize(path, root),
        line: parse_int(line, 1),
        column: 1,
        severity: "error",
        message: message,
        source: source
      }
    ]
  end

  defp parse_external_diagnostics(:javascript, output, root, source) do
    [path, line] =
      Regex.run(~r/^(.+):(\d+)$/m, output, capture: :all_but_first) ||
        [root, "1"]

    message =
      output
      |> String.split("\n", trim: true)
      |> Enum.find("javascript diagnostic", &String.contains?(&1, "SyntaxError"))

    [
      %{
        path: absolutize(path, root),
        line: parse_int(line, 1),
        column: 1,
        severity: "error",
        message: String.trim(message),
        source: source
      }
    ]
  end

  defp parse_external_diagnostics(_language, output, root, source) do
    parse_generic_diagnostics(output, root, source)
  end

  defp parse_generic_diagnostics(output, root, source) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      captures =
        Regex.run(~r/^(.+?)\((\d+),(\d+)\):\s*(?:(error|warning)\s+\w+\d+:\s*)?(.*)$/, line,
          capture: :all_but_first
        ) ||
          Regex.run(~r/^(.+?):(\d+)(?::(\d+))?:\s*(?:(error|warning):\s*)?(.*)$/, line,
            capture: :all_but_first
          )

      case captures do
        [path, line_no, column, severity, message] ->
          [
            %{
              path: absolutize(path, root),
              line: parse_int(line_no, 1),
              column: parse_int(column, 1),
              severity: normalize_severity(severity),
              message: String.trim(message),
              source: source
            }
          ]

        [path, line_no, message] ->
          [
            %{
              path: absolutize(path, root),
              line: parse_int(line_no, 1),
              column: 1,
              severity: "error",
              message: String.trim(message),
              source: source
            }
          ]

        _ ->
          []
      end
    end)
    |> case do
      [] ->
        [
          %{
            path: root,
            line: 1,
            column: 1,
            severity: "error",
            message: trim_output(output),
            source: source
          }
        ]

      diagnostics ->
        diagnostics
    end
  end

  defp render_result(%{status: :clean, path: path, source: source}) do
    "Diagnostics clean for #{path} (#{source})"
  end

  defp render_result(%{status: :skipped, path: path, reason: reason}) do
    "Diagnostics skipped for #{path}: #{reason}"
  end

  defp render_result(%{status: :diagnostics, diagnostics: diagnostics}) do
    "Diagnostics found #{length(diagnostics)} issue(s):\n#{render_diagnostics(diagnostics)}"
  end

  defp render_result(%{status: :failed, error: error}) do
    "Diagnostics failed: #{error}"
  end

  defp render_post_edit_summary(%{status: :diagnostics, introduced_diagnostics: introduced})
       when introduced != [] do
    "\n\nDiagnostics introduced #{length(introduced)} issue(s):\n#{render_diagnostics(introduced)}"
  end

  defp render_post_edit_summary(%{status: :diagnostics}),
    do: "\n\nDiagnostics found only pre-existing issues."

  defp render_post_edit_summary(%{status: :clean}), do: "\n\nDiagnostics clean."

  defp render_post_edit_summary(%{status: :skipped, reason: reason}),
    do: "\n\nDiagnostics skipped: #{reason}"

  defp render_post_edit_summary(%{status: :failed, error: error}),
    do: "\n\nDiagnostics failed: #{error}"

  defp diagnostic_key(diagnostic) do
    {
      Map.get(diagnostic, :path) || Map.get(diagnostic, "path"),
      Map.get(diagnostic, :line) || Map.get(diagnostic, "line"),
      Map.get(diagnostic, :column) || Map.get(diagnostic, "column"),
      Map.get(diagnostic, :severity) || Map.get(diagnostic, "severity"),
      Map.get(diagnostic, :message) || Map.get(diagnostic, "message"),
      Map.get(diagnostic, :source) || Map.get(diagnostic, "source")
    }
  end

  defp absolutize(nil, root), do: root

  defp absolutize(path, root) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, _} -> int
      :error -> default
    end
  end

  defp normalize_severity(severity) when severity in [nil, ""], do: "error"
  defp normalize_severity(severity), do: severity

  defp trim_output(output) do
    output
    |> to_string()
    |> String.trim()
    |> String.slice(0, 4_000)
  end
end
