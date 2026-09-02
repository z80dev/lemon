defmodule LemonCore.Quality.RatchetCheck do
  @moduledoc """
  Quality ratchets: repository-wide counts that may only go down.

  Each metric is measured from the source tree and compared with the maximum
  recorded in `.ratchets.exs` at the repository root. A measurement above its
  ratchet fails `mix lemon.quality`. `mix lemon.ratchet --update` lowers each
  ratchet to the current measurement and never raises one; raising a value is
  a deliberate edit of the file that needs a reason in the commit message.

  The metrics are the ones named in the September 2026 architecture review
  (`docs/architecture/review-2026-09.md`). They count the mechanisms that let
  the umbrella grow past its own boundaries (dynamic module atoms, runtime
  reflection, blanket and silent `rescue`, generic store tables, wrapper
  modules) and the habits that keep the suite slow (`Process.sleep`,
  synchronous test files).

  Counts are pattern counts over `apps/*/lib/**/*.ex` and
  `apps/*/test/**/*.exs`, excluding this directory. They include the occasional
  comment or doc example on purpose: the ratchet is compared against the same
  pattern count, so a false positive costs nothing until someone adds another.
  """

  @baseline_file ".ratchets.exs"
  @self_dir "apps/lemon_core/lib/lemon_core/quality"
  @rules_file "apps/lemon_core/lib/lemon_core/quality/architecture_rules_check.ex"
  @store_file "apps/lemon_core/lib/lemon_core/store.ex"
  @table_marker "use LemonCore.Store.Table"
  @large_file_lines 1_000

  @dynamic_atom ~r/:"Elixir\./
  @reflection ~r/\b(?:Code\.ensure_loaded\??|function_exported\?)\(/
  @rescue_clause ~r/^[ \t]*rescue\b/m
  @silent_rescue ~r/^[ \t]*rescue[ \t]*\n[ \t]*_[A-Za-z0-9_]*[ \t]*->/m
  @catch_clause ~r/^[ \t]*catch\b/m
  @sleep ~r/(?:Process|:timer)\.sleep\(/
  @async_marker ~r/async:\s*true/
  @attribute_declaration ~r/^[ \t]*@([a-z_]+)\s+(:[a-z_]+)\s*$/m
  @generic_store_call ~r/Store\.(?:get|put|put_new|delete|list|take|compare_and_swap)\(\s*(@[a-z_]+|:[a-z_]+)/
  @rule_entry ~r/^[ \t]+code: :/m

  @metrics [
    {:lib_lines, "lines in apps/*/lib/**/*.ex"},
    {:large_lib_files, "lib files over #{@large_file_lines} lines"},
    {:dynamic_module_atoms, ~s(:"Elixir.Some.Module" atoms in lib)},
    {:reflection_sites, "Code.ensure_loaded?/1 and function_exported?/3 calls in lib"},
    {:rescue_clauses, "rescue clauses in lib"},
    {:silent_rescues, "rescue clauses whose first clause discards the exception"},
    {:catch_clauses, "catch clauses in lib"},
    {:generic_store_tables,
     "distinct tables named in generic LemonCore.Store calls outside Store.Table modules"},
    {:store_wrapper_modules, "*_store.ex modules in lib"},
    {:architecture_rules, "source-pattern rules in LemonCore.Quality.ArchitectureRulesCheck"},
    {:test_sleeps, "Process.sleep/1 and :timer.sleep/1 calls in tests"},
    {:sync_test_files, "*_test.exs files that are not async: true"},
    {:agents_md_bytes, "bytes across apps/*/AGENTS.md"},
    {:agents_md_max_bytes, "bytes in the largest apps/*/AGENTS.md"}
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

  @doc "The metric keys in report order, each with a one-line description."
  @spec metrics() :: [{metric(), String.t()}]
  def metrics, do: @metrics

  @doc "Path of the ratchet file, relative to the repository root."
  @spec baseline_file() :: String.t()
  def baseline_file, do: @baseline_file

  @doc """
  Measures every metric and compares it with the recorded ratchet.

  Returns `{:ok, report}` when every measurement is at or below its ratchet
  and `{:error, report}` otherwise. A missing or malformed ratchet file is an
  error with a single `:missing_ratchet_baseline` issue.
  """
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

  @doc "Measures every metric under `root`."
  @spec measure(String.t()) :: measurements()
  def measure(root) do
    lib = read_all(lib_files(root))
    tests = read_all(Path.wildcard(Path.join(root, "apps/*/test/**/*.exs")))

    %{
      lib_lines: lib |> Enum.map(fn {_path, source} -> line_count(source) end) |> Enum.sum(),
      large_lib_files:
        Enum.count(lib, fn {_path, source} -> line_count(source) > @large_file_lines end),
      dynamic_module_atoms: count(lib, @dynamic_atom),
      reflection_sites: count(lib, @reflection),
      rescue_clauses: count(lib, @rescue_clause),
      silent_rescues: count(lib, @silent_rescue),
      catch_clauses: count(lib, @catch_clause),
      generic_store_tables: generic_store_tables(root, lib),
      store_wrapper_modules:
        Enum.count(lib, fn {path, _} -> String.ends_with?(path, "_store.ex") end),
      architecture_rules: architecture_rules(root),
      test_sleeps: count(tests, @sleep),
      sync_test_files:
        Enum.count(tests, fn {path, source} ->
          String.ends_with?(path, "_test.exs") and not Regex.match?(@async_marker, source)
        end),
      agents_md_bytes: Enum.sum(agents_md_sizes(root)),
      agents_md_max_bytes: Enum.max(agents_md_sizes(root), fn -> 0 end)
    }
  end

  defp agents_md_sizes(root) do
    root
    |> Path.join("apps/*/AGENTS.md")
    |> Path.wildcard()
    |> Enum.map(&File.stat!(&1).size)
  end

  @doc """
  Lowers every ratchet to the current measurement and writes `.ratchets.exs`.

  A ratchet is never raised: the recorded value is the minimum of the previous
  ratchet and the measurement. Creates the file when it does not exist.
  """
  @spec update_baselines(String.t()) ::
          {:ok, %{measurements: measurements(), baselines: measurements()}}
  def update_baselines(root) do
    measurements = measure(root)

    previous =
      case load_baselines(root) do
        {:ok, baselines} -> baselines
        {:error, _} -> %{}
      end

    baselines =
      Map.new(@metrics, fn {key, _doc} ->
        current = Map.fetch!(measurements, key)
        {key, min(Map.get(previous, key, current), current)}
      end)

    File.write!(Path.join(root, @baseline_file), render(baselines))
    {:ok, %{measurements: measurements, baselines: baselines}}
  end

  @doc "Reads the ratchet file without evaluating it."
  @spec load_baselines(String.t()) :: {:ok, measurements()} | {:error, String.t()}
  def load_baselines(root) do
    path = Path.join(root, @baseline_file)

    with {:ok, source} <- read_baseline(path),
         {:ok, ast} <- quote_baseline(source, path) do
      decode_baseline(ast, path)
    end
  end

  # ---------------------------------------------------------------------------
  # Measurement helpers
  # ---------------------------------------------------------------------------

  defp lib_files(root) do
    self_prefix = Path.join(root, @self_dir)

    root
    |> Path.join("apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.starts_with?(&1, self_prefix))
  end

  defp read_all(paths), do: Enum.map(paths, &{&1, File.read!(&1)})

  defp count(sources, regex) do
    Enum.reduce(sources, 0, fn {_path, source}, acc ->
      acc + length(Regex.scan(regex, source))
    end)
  end

  defp line_count(source), do: length(:binary.matches(source, "\n"))

  # A table is named either as a literal atom or through a module attribute
  # declared in the same file (`@table :tts_config` then `Store.get(@table, k)`),
  # so attributes are resolved per file before the atoms are made distinct.
  defp generic_store_tables(root, lib) do
    store_path = Path.join(root, @store_file)

    lib
    |> Enum.reject(fn {path, source} ->
      path == store_path or String.contains?(source, @table_marker)
    end)
    |> Enum.flat_map(fn {_path, source} ->
      attributes =
        @attribute_declaration
        |> Regex.scan(source, capture: :all_but_first)
        |> Map.new(fn [name, atom] -> {"@" <> name, atom} end)

      @generic_store_call
      |> Regex.scan(source, capture: :all_but_first)
      |> Enum.map(fn [name] -> Map.get(attributes, name, name) end)
    end)
    |> Enum.uniq()
    |> length()
  end

  defp architecture_rules(root) do
    case File.read(Path.join(root, @rules_file)) do
      {:ok, source} -> length(Regex.scan(@rule_entry, source))
      {:error, _} -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Ratchet file
  # ---------------------------------------------------------------------------

  defp regressions(measurements, baselines) do
    Enum.flat_map(@metrics, fn {key, doc} ->
      current = Map.fetch!(measurements, key)

      case Map.fetch(baselines, key) do
        {:ok, max} when current > max ->
          [
            issue(
              :ratchet_regression,
              "#{key} is #{current}, above the ratchet of #{max} (#{doc})"
            )
          ]

        {:ok, _} ->
          []

        :error ->
          [
            issue(
              :missing_ratchet,
              "#{key} has no ratchet in #{@baseline_file}; run mix lemon.ratchet --update"
            )
          ]
      end
    end)
  end

  defp issue(code, message), do: %{code: code, message: message, path: @baseline_file}

  defp read_baseline(path) do
    case File.read(path) do
      {:ok, source} ->
        {:ok, source}

      {:error, reason} ->
        {:error,
         "#{@baseline_file} could not be read (#{inspect(reason)}); " <>
           "run mix lemon.ratchet --update to record the current measurements"}
    end
  end

  defp quote_baseline(source, path) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, {_meta, message, token}} -> {:error, "#{path}: #{message}#{token}"}
    end
  end

  defp decode_baseline({:%{}, _meta, pairs}, path) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) and is_integer(value) and value >= 0 ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      other, _acc ->
        {:halt,
         {:error,
          "#{path}: expected atom keys with non-negative integer values, got #{inspect(other)}"}}
    end)
  end

  defp decode_baseline(_ast, path), do: {:error, "#{path}: expected a map literal"}

  defp render(baselines) do
    body =
      Enum.map_join(@metrics, ",\n", fn {key, doc} ->
        "  # #{doc}\n  #{key}: #{Map.fetch!(baselines, key)}"
      end)

    """
    # Quality ratchets. Each value is the highest measurement `mix lemon.quality`
    # accepts for that metric; LemonCore.Quality.RatchetCheck says what is counted.
    # `mix lemon.ratchet --update` lowers a value to the current measurement and
    # never raises one. Raising a value is a deliberate edit that needs a reason
    # in the commit message.
    %{
    #{body}
    }
    """
  end
end
