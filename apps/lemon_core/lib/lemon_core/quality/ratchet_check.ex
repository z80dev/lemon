defmodule LemonCore.Quality.RatchetCheck do
  @moduledoc """
  Prevents a small set of measurable architecture debts from increasing.

  Unlike ownership checks, ratchets do not decide whether an individual use is
  valid. They record the current count of narrowly defined constructs and fail
  when a change increases that count. Counts are derived from parsed Elixir AST
  where syntax matters, so comments and documentation examples do not affect
  them.

  `mix lemon.ratchet --update` may lower recorded values after cleanup. Raising
  a value requires a deliberate edit to `.ratchets.exs` and review justification.
  """

  @baseline_file ".ratchets.exs"
  @self_file "apps/lemon_core/lib/lemon_core/quality/ratchet_check.ex"
  @large_file_lines 1_000

  @metrics [
    {:large_lib_files, "Elixir library files longer than #{@large_file_lines} physical lines"},
    {:dynamic_module_atoms, ~s(literal :"Elixir.Some.Module" atoms in library AST)},
    {:reflection_calls,
     "Code.ensure_loaded/1, Code.ensure_loaded?/1, and function_exported?/3 calls in library AST"},
    {:rescue_clauses, "rescue clauses in library AST"},
    {:catch_clauses, "catch clauses in library AST"},
    {:store_wrapper_modules, "library files whose basename ends in _store.ex"},
    {:test_sleep_calls, "Process.sleep/1 and :timer.sleep/1 calls in test AST"}
  ]

  @type metric :: atom()
  @type measurements :: %{optional(metric()) => non_neg_integer()}
  @type issue :: %{code: atom(), message: String.t(), path: String.t()}
  @type report :: %{
          root: String.t(),
          issue_count: non_neg_integer(),
          issues: [issue()],
          measurements: measurements(),
          baselines: measurements()
        }

  @doc "The metric keys in report order, with their exact definitions."
  @spec metrics() :: [{metric(), String.t()}]
  def metrics, do: @metrics

  @doc "Path of the ratchet file, relative to the repository root."
  @spec baseline_file() :: String.t()
  def baseline_file, do: @baseline_file

  @doc "Measures the repository and compares every value with its ratchet."
  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    measurements = measure(root)

    {issues, baselines} =
      case load_baselines(root) do
        {:ok, baselines} -> {regressions(measurements, baselines), baselines}
        {:error, message} -> {[issue(:missing_ratchet_baseline, message)], %{}}
      end

    report = %{
      root: root,
      issue_count: length(issues),
      issues: issues,
      measurements: measurements,
      baselines: baselines
    }

    if issues == [], do: {:ok, report}, else: {:error, report}
  end

  @doc "Measures every ratcheted construct under `root`."
  @spec measure(String.t()) :: measurements()
  def measure(root) do
    lib = source_files(root, "apps/*/lib/**/*.ex", exclude_self?: true)
    tests = source_files(root, "apps/*/test/**/*.exs")

    %{
      large_lib_files:
        Enum.count(lib, fn {_path, source} -> line_count(source) > @large_file_lines end),
      dynamic_module_atoms: literal_ast_count(lib, &dynamic_module_atom?/1),
      reflection_calls: ast_count(lib, &reflection_call?/1),
      rescue_clauses: clause_count(lib, :rescue),
      catch_clauses: clause_count(lib, :catch),
      store_wrapper_modules:
        Enum.count(lib, fn {path, _source} -> String.ends_with?(path, "_store.ex") end),
      test_sleep_calls: ast_count(tests, &test_sleep_call?/1)
    }
  end

  @doc "Lowers ratchets to current measurements without ever raising them."
  @spec update_baselines(String.t()) ::
          {:ok, %{measurements: measurements(), baselines: measurements()}}
  def update_baselines(root) do
    measurements = measure(root)

    previous =
      case load_baselines(root) do
        {:ok, baselines} -> baselines
        {:error, _message} -> %{}
      end

    baselines =
      Map.new(@metrics, fn {key, _description} ->
        current = Map.fetch!(measurements, key)
        {key, min(Map.get(previous, key, current), current)}
      end)

    File.write!(Path.join(root, @baseline_file), render(baselines))
    {:ok, %{measurements: measurements, baselines: baselines}}
  end

  @doc "Reads `.ratchets.exs` as a data-only map literal."
  @spec load_baselines(String.t()) :: {:ok, measurements()} | {:error, String.t()}
  def load_baselines(root) do
    path = Path.join(root, @baseline_file)

    with {:ok, source} <- File.read(path),
         {:ok, ast} <- quote_baseline(source, path) do
      decode_baseline(ast, path)
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "#{@baseline_file} could not be read (#{inspect(reason)})"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp source_files(root, glob, opts \\ []) do
    self_path = Path.join(root, @self_file)

    root
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      Keyword.get(opts, :exclude_self?, false) and path == self_path
    end)
    |> Enum.map(&{&1, File.read!(&1)})
  end

  defp ast_count(sources, matcher) do
    Enum.reduce(sources, 0, fn {path, source}, total ->
      ast = Code.string_to_quoted!(source, file: path)

      {_ast, count} =
        Macro.prewalk(ast, 0, fn node, count ->
          {node, if(matcher.(node), do: count + 1, else: count)}
        end)

      total + count
    end)
  end

  defp literal_ast_count(sources, matcher) do
    literal_encoder = fn literal, meta -> {:ok, {:__ratchet_literal__, meta, [literal]}} end

    Enum.reduce(sources, 0, fn {path, source}, total ->
      ast = Code.string_to_quoted!(source, file: path, literal_encoder: literal_encoder)

      {_ast, count} =
        Macro.prewalk(ast, 0, fn
          {:__ratchet_literal__, _meta, [literal]} = node, count ->
            {node, if(matcher.(literal), do: count + 1, else: count)}

          node, count ->
            {node, count}
        end)

      total + count
    end)
  end

  defp clause_count(sources, kind) do
    Enum.reduce(sources, 0, fn {path, source}, total ->
      ast = Code.string_to_quoted!(source, file: path)

      {_ast, count} =
        Macro.prewalk(ast, 0, fn
          blocks, count when is_list(blocks) ->
            clauses = if Keyword.keyword?(blocks), do: Keyword.get(blocks, kind, []), else: []
            {blocks, count + length(clauses)}

          node, count ->
            {node, count}
        end)

      total + count
    end)
  end

  defp dynamic_module_atom?(atom) when is_atom(atom),
    do: String.starts_with?(Atom.to_string(atom), "Elixir.")

  defp dynamic_module_atom?(_node), do: false

  defp reflection_call?({{:., _, [{:__aliases__, _, [:Code]}, name]}, _, [_arg]})
       when name in [:ensure_loaded, :ensure_loaded?],
       do: true

  defp reflection_call?({:function_exported?, _, [_module, _function, _arity]}), do: true
  defp reflection_call?(_node), do: false

  defp test_sleep_call?({{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, _, [_timeout]}),
    do: true

  defp test_sleep_call?({{:., _, [:timer, :sleep]}, _, [_timeout]}), do: true
  defp test_sleep_call?(_node), do: false

  defp line_count(""), do: 0
  defp line_count(source), do: length(String.split(source, "\n"))

  defp regressions(measurements, baselines) do
    Enum.flat_map(@metrics, fn {key, description} ->
      current = Map.fetch!(measurements, key)

      case Map.fetch(baselines, key) do
        {:ok, maximum} when current > maximum ->
          [
            issue(
              :ratchet_regression,
              "#{key} is #{current}, above the ratchet of #{maximum} (#{description})"
            )
          ]

        {:ok, _maximum} ->
          []

        :error ->
          [issue(:missing_ratchet, "#{key} has no entry in #{@baseline_file}")]
      end
    end)
  end

  defp issue(code, message), do: %{code: code, message: message, path: @baseline_file}

  defp quote_baseline(source, path) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, {_location, message, token}} -> {:error, "#{path}: #{message}#{token}"}
    end
  end

  defp decode_baseline({:%{}, _meta, pairs}, path) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) and is_integer(value) and value >= 0 ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      other, _acc ->
        {:halt,
         {:error, "#{path}: expected atom keys with non-negative integers, got #{inspect(other)}"}}
    end)
  end

  defp decode_baseline(_ast, path), do: {:error, "#{path}: expected a map literal"}

  defp render(baselines) do
    body =
      Enum.map_join(@metrics, ",\n", fn {key, description} ->
        "  # #{description}\n  #{key}: #{Map.fetch!(baselines, key)}"
      end)

    """
    # Quality ratchets. `mix lemon.ratchet --update` only lowers these values.
    # Raising one requires an explicit edit and justification in code review.
    %{
    #{body}
    }
    """
  end
end
