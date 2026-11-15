defmodule Lemon.Reload do
  @moduledoc """
  Low-level BEAM and extension reload API shipped in the `lemon_core` Hex package.

  This is separate from `LemonCore.CodeReload`, which implements the
  source-development `lemon reload` control-plane workflow. These functions do
  not enforce that workflow's source-launcher or admin authorization checks.
  Only invoke them with trusted modules, application names and source paths.

  ## Public entry points

  All options default to `[]`; the corresponding lower arities remain public.

  - `reload_module/2` soft-purges old code, then loads one module's BEAM from the
    code path. It does not check whether the artifact changed.
  - `soft_purge_module/2` only attempts to purge old code. It neither loads nor
    deletes the current module. Extension-cache cleanup uses this operation.
  - `reload_extension/2` compiles and loads an `.ex/.exs` source file, then
    soft-purges its compiled modules. The extension loader uses this operation.
  - `reload_app/2` attempts a BEAM reload of every module in an application's
    loaded specification, not just changed modules. It does not restart the app.
  - `reload_system/1` composes application reloads, extension compilation and
    explicitly requested `:sys.change_code/4` calls.

  `reload_module/2`, `reload_app/2` and `reload_system/1` retain their existing
  documented package contract even though the umbrella's operator reload path
  does not call them. They are not a release-upgrade or automatic state-migration
  mechanism.

  ## Results and safety

  A completed attempt returns `{:ok, result}` even when `result.status` is
  `:partial` or `:error`. Inspect `reloaded`, `skipped` and `errors`; errors take
  precedence over skips when aggregating status. `duration_ms` is elapsed time
  and `metadata` holds operation-specific details. Lock or orchestration failures
  can instead return `{:error, reason}`.

  BEAM reload skips modules with old code still in use (`reason: :in_use`); no
  function hard-purges code or deliberately kills its users. Source compilation,
  however, loads modules and runs arbitrary top-level code before checking old
  code usage. An extension error or skip does not mean nothing changed. Operations
  are not transactional and do not roll back earlier loads or side effects.
  Existing closures may retain old code; these helpers do not rebuild sessions.
  Configuration, dependencies, application/supervision changes and incompatible
  process-state changes still need an explicit lifecycle or upgrade plan.

  ## Common options

  Each entry point uses `:global.trans/4` with `:lock_nodes` (default `[node()]`)
  and `:lock_retries` (default `0`). An aborted lock returns
  `{:error, :reload_in_progress}`.

  For `reload_module/2`, `reload_app/2` and `reload_system/1`, `compile: true`
  first runs `Mix.Task.run("compile", args)` inside the calling node.
  `:compile_force` (falling back to `:force`, default `false`) adds `--force`.
  This requires Mix to be available, otherwise it returns
  `{:error, :mix_unavailable}`. A zero-arity `:compile_fn` may replace Mix and must
  return `:ok` or `{:error, reason}`. Compilation failures return
  `{:error, {:compile_failed, reason}}`; successful compilation adds `:compile`
  metadata. The operator CLI instead compiles outside the live runtime.

  Operations emit `[:lemon, :reload, :start]`, `:stop` or `:exception` telemetry.
  Targets, exception terms and stacktraces can contain sensitive source details;
  these events are not a redacted management projection.
  """

  @lock_key {__MODULE__, :reload_lock}

  @type error_item :: %{target: module() | String.t() | atom(), reason: term()}
  @type skip_item :: %{target: module() | String.t() | atom(), reason: term()}

  @type reload_kind :: :module | :app | :extension | :code_change | :system
  @type compile_metadata :: %{
          ran: true,
          source: :mix | :custom,
          force: boolean(),
          duration_ms: non_neg_integer()
        }

  @type result :: %{
          kind: reload_kind(),
          target: module() | atom() | String.t(),
          status: :ok | :partial | :error,
          reloaded: [module()],
          skipped: [skip_item()],
          errors: [error_item()],
          duration_ms: non_neg_integer(),
          metadata: map()
        }

  @doc """
  Soft-purges old code and loads `module` from its BEAM on the code path.

  Supports the common lock and compilation options. Old code still in use is
  reported in `skipped`; a load failure is reported in `errors`.
  """
  @spec reload_module(module(), keyword()) :: {:ok, result()} | {:error, term()}
  def reload_module(module, opts \\ []) when is_atom(module) do
    with_reload_lock(opts, fn ->
      telemetry_span(:module, module, fn ->
        with {:ok, compile_meta} <- maybe_compile_sources(opts),
             {:ok, result} <- do_reload_module(module) do
          {:ok, maybe_put_compile_metadata(result, compile_meta)}
        end
      end)
    end)
  end

  @doc """
  Attempts to soft-purge `module` without loading or deleting its current code.

  Supports only the common lock options. A successful purge reports the module
  in `reloaded` with `metadata.operation == :soft_purge`; old code still in use
  yields `status: :partial` and a skipped item with `reason: :in_use`.
  """
  @spec soft_purge_module(module(), keyword()) :: {:ok, result()} | {:error, term()}
  def soft_purge_module(module, opts \\ []) when is_atom(module) do
    with_reload_lock(opts, fn ->
      telemetry_span(:module, module, fn ->
        started = System.monotonic_time()

        case :code.soft_purge(module) do
          true ->
            ok_result(:module, module, [module], [], [], started, %{operation: :soft_purge})

          false ->
            partial_result(
              :module,
              module,
              [],
              [%{target: module, reason: :in_use}],
              [],
              started,
              %{operation: :soft_purge}
            )
        end
      end)
    end)
  end

  @doc """
  Compiles and loads a trusted extension source file, then soft-purges old code.

  Supports only the common lock options; source compilation always runs.
  `metadata.compiled_modules` lists modules on success. Empty or missing paths
  and compilation exceptions produce an error-status result with
  `metadata.error_message`. Compiler options are restored after compilation,
  but loaded modules and top-level side effects are not rolled back on failure.
  """
  @spec reload_extension(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def reload_extension(path, opts \\ []) when is_binary(path) do
    with_reload_lock(opts, fn ->
      telemetry_span(:extension, path, fn ->
        do_reload_extension(path)
      end)
    end)
  end

  @doc """
  Reloads every module in `Application.spec(app, :modules)` from the code path.

  Supports the common lock and compilation options. Missing applications produce
  an error-status result with `reason: :app_not_found`. Results aggregate module
  loads, skips and errors; `metadata.module_count` records the specification's
  module count. This does not reload application configuration or supervision.
  """
  @spec reload_app(atom(), keyword()) :: {:ok, result()} | {:error, term()}
  def reload_app(app, opts \\ []) when is_atom(app) do
    with_reload_lock(opts, fn ->
      telemetry_span(:app, app, fn ->
        with {:ok, compile_meta} <- maybe_compile_sources(opts),
             {:ok, result} <- do_reload_app(app) do
          {:ok, maybe_put_compile_metadata(result, compile_meta)}
        end
      end)
    end)
  end

  @doc """
  Composes application, extension and explicit process code-change attempts.

  Supports the common lock and compilation options. Compilation runs once before
  the individual operations. `metadata.results` contains their individual
  reports; the top-level result aggregates loads, skips and errors.

  Code-change targets must identify a local registered name or PID. The caller
  is responsible for suspending/resuming the process and supplying compatible
  state-upgrade arguments; this function does neither and discovers no targets
  automatically. Non-running targets are skipped, and invalid targets or returned
  code-change errors are reported. This is not used by `lemon reload`.

  ## Options

    - `:apps` - list of app atoms to reload via BEAM (`:code.load_file/1`)
    - `:extensions` - list of extension source paths to compile/reload
    - `:code_change_targets` - list of code-change targets; each target may be:
      - `%{server: atom() | pid(), module: module(), old_vsn: term(), extra: term()}`
      - `{server, module}`
      - `{server, module, old_vsn}`
      - `{server, module, old_vsn, extra}`
    - `:lock_nodes` - distributed lock nodes (default: `[node()]`)
    - `:lock_retries` - `:global.trans/4` retries (default: `0`)
  """
  @spec reload_system(keyword()) :: {:ok, result()} | {:error, term()}
  def reload_system(opts \\ []) do
    with_reload_lock(opts, fn ->
      telemetry_span(:system, :system, fn ->
        started = System.monotonic_time()

        with {:ok, compile_meta} <- maybe_compile_sources(opts) do
          apps = normalize_atom_list(Keyword.get(opts, :apps, []))
          extension_paths = normalize_string_list(Keyword.get(opts, :extensions, []))

          code_change_targets =
            opts
            |> Keyword.get(:code_change_targets, [])
            |> List.wrap()

          app_results = Enum.map(apps, &unwrap(do_reload_app(&1)))
          extension_results = Enum.map(extension_paths, &unwrap(do_reload_extension(&1)))
          code_change_results = Enum.map(code_change_targets, &do_change_code_target/1)

          results = app_results ++ extension_results ++ code_change_results

          reloaded =
            results
            |> Enum.flat_map(&Map.get(&1, :reloaded, []))
            |> Enum.uniq()

          skipped = Enum.flat_map(results, &Map.get(&1, :skipped, []))
          errors = Enum.flat_map(results, &Map.get(&1, :errors, []))

          {:ok,
           %{
             kind: :system,
             target: :system,
             status: status_for(reloaded, skipped, errors),
             reloaded: reloaded,
             skipped: skipped,
             errors: errors,
             duration_ms: elapsed_ms(started),
             metadata:
               maybe_put_compile_metadata(
                 %{
                   results: results,
                   app_count: length(apps),
                   extension_count: length(extension_paths),
                   code_change_count: length(code_change_targets)
                 },
                 compile_meta
               )
           }}
        end
      end)
    end)
  end

  defp do_reload_app(app) do
    started = System.monotonic_time()

    modules = Application.spec(app, :modules)

    if is_nil(modules) do
      {:ok,
       %{
         kind: :app,
         target: app,
         status: :error,
         reloaded: [],
         skipped: [],
         errors: [%{target: app, reason: :app_not_found}],
         duration_ms: elapsed_ms(started),
         metadata: %{module_count: 0}
       }}
    else
      modules = modules || []

      {reloaded, skipped, errors} =
        Enum.reduce(modules, {[], [], []}, fn module, {ok, skip, errs} ->
          case do_reload_module(module) do
            {:ok, %{status: :ok, reloaded: loaded}} ->
              {loaded ++ ok, skip, errs}

            {:ok, %{status: :partial, reloaded: loaded, skipped: skipped_items}} ->
              {loaded ++ ok, skipped_items ++ skip, errs}

            {:ok, %{status: :error, errors: error_items}} ->
              {ok, skip, error_items ++ errs}
          end
        end)

      {:ok,
       %{
         kind: :app,
         target: app,
         status: status_for(reloaded, skipped, errors),
         reloaded: Enum.reverse(reloaded),
         skipped: Enum.reverse(skipped),
         errors: Enum.reverse(errors),
         duration_ms: elapsed_ms(started),
         metadata: %{module_count: length(modules)}
       }}
    end
  end

  defp do_reload_module(module) do
    started = System.monotonic_time()

    case :code.soft_purge(module) do
      true ->
        case :code.load_file(module) do
          {:module, _} ->
            ok_result(:module, module, [module], [], [], started, %{})

          {:error, reason} ->
            {:ok,
             %{
               kind: :module,
               target: module,
               status: :error,
               reloaded: [],
               skipped: [],
               errors: [%{target: module, reason: reason}],
               duration_ms: elapsed_ms(started),
               metadata: %{}
             }}
        end

      false ->
        partial_result(
          :module,
          module,
          [],
          [%{target: module, reason: :in_use}],
          [],
          started,
          %{}
        )
    end
  end

  defp do_reload_extension(path) do
    started = System.monotonic_time()

    cond do
      String.trim(path) == "" ->
        {:ok,
         %{
           kind: :extension,
           target: path,
           status: :error,
           reloaded: [],
           skipped: [],
           errors: [%{target: path, reason: :empty_path}],
           duration_ms: elapsed_ms(started),
           metadata: %{error_message: "Extension path is empty"}
         }}

      not File.regular?(path) ->
        {:ok,
         %{
           kind: :extension,
           target: path,
           status: :error,
           reloaded: [],
           skipped: [],
           errors: [%{target: path, reason: :enoent}],
           duration_ms: elapsed_ms(started),
           metadata: %{error_message: "Extension file not found"}
         }}

      true ->
        previous_opts = Code.compiler_options()

        try do
          Code.compiler_options(ignore_module_conflict: true)
          # Compilation runs arbitrary top-level extension code, even if it fails.
          LemonCore.NativeProcess.unsupported!()

          modules =
            Code.compile_file(path)
            |> Enum.map(fn {module, _binary} -> module end)

          Enum.each(modules, &Code.ensure_loaded?/1)

          {reloaded, skipped} =
            Enum.reduce(modules, {[], []}, fn module, {ok, skip} ->
              case :code.soft_purge(module) do
                true -> {[module | ok], skip}
                false -> {ok, [%{target: module, reason: :in_use} | skip]}
              end
            end)

          {:ok,
           %{
             kind: :extension,
             target: path,
             status: status_for(reloaded, skipped, []),
             reloaded: Enum.reverse(reloaded),
             skipped: Enum.reverse(skipped),
             errors: [],
             duration_ms: elapsed_ms(started),
             metadata: %{compiled_modules: modules}
           }}
        rescue
          e in CompileError ->
            error_result(:extension, path, started, e, "Compile error: #{e.description}")

          e in SyntaxError ->
            error_result(
              :extension,
              path,
              started,
              e,
              "Syntax error at line #{e.line}: #{e.description}"
            )

          e in TokenMissingError ->
            error_result(
              :extension,
              path,
              started,
              e,
              "Token error at line #{e.line}: #{e.description}"
            )

          e ->
            error_result(:extension, path, started, e, Exception.message(e))
        after
          Code.compiler_options(previous_opts)
        end
    end
  end

  defp do_change_code_target(target) do
    started = System.monotonic_time()

    case normalize_code_change_target(target) do
      {:ok, server, module, old_vsn, extra} ->
        case server_alive?(server) do
          true ->
            try do
              case :sys.change_code(server, module, old_vsn, extra) do
                {:ok, _} = ok ->
                  {:ok,
                   %{
                     kind: :code_change,
                     target: target_name(server, module),
                     status: :ok,
                     reloaded: [],
                     skipped: [],
                     errors: [],
                     duration_ms: elapsed_ms(started),
                     metadata: %{result: ok, module: module}
                   }}

                {:error, reason} ->
                  {:ok,
                   %{
                     kind: :code_change,
                     target: target_name(server, module),
                     status: :error,
                     reloaded: [],
                     skipped: [],
                     errors: [%{target: target_name(server, module), reason: reason}],
                     duration_ms: elapsed_ms(started),
                     metadata: %{module: module}
                   }}
              end
            catch
              :exit, reason ->
                {:ok,
                 %{
                   kind: :code_change,
                   target: target_name(server, module),
                   status: :error,
                   reloaded: [],
                   skipped: [],
                   errors: [%{target: target_name(server, module), reason: reason}],
                   duration_ms: elapsed_ms(started),
                   metadata: %{module: module}
                 }}
            end

          false ->
            {:ok,
             %{
               kind: :code_change,
               target: target_name(server, module),
               status: :partial,
               reloaded: [],
               skipped: [%{target: target_name(server, module), reason: :not_running}],
               errors: [],
               duration_ms: elapsed_ms(started),
               metadata: %{module: module}
             }}
        end

      {:error, reason} ->
        {:ok,
         %{
           kind: :code_change,
           target: inspect(target),
           status: :error,
           reloaded: [],
           skipped: [],
           errors: [%{target: inspect(target), reason: reason}],
           duration_ms: elapsed_ms(started),
           metadata: %{}
         }}
    end
    |> unwrap()
  end

  defp normalize_code_change_target(%{server: server, module: module} = map)
       when is_atom(module) do
    {:ok, server, module, Map.get(map, :old_vsn, nil), Map.get(map, :extra, %{})}
  end

  defp normalize_code_change_target({server, module}) when is_atom(module) do
    {:ok, server, module, nil, %{}}
  end

  defp normalize_code_change_target({server, module, old_vsn}) when is_atom(module) do
    {:ok, server, module, old_vsn, %{}}
  end

  defp normalize_code_change_target({server, module, old_vsn, extra}) when is_atom(module) do
    {:ok, server, module, old_vsn, extra}
  end

  defp normalize_code_change_target(_), do: {:error, :invalid_code_change_target}

  defp server_alive?(server) when is_atom(server) do
    case Process.whereis(server) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp server_alive?(server) when is_pid(server), do: Process.alive?(server)
  defp server_alive?(_), do: false

  defp target_name(server, module), do: "#{inspect(server)}:#{inspect(module)}"

  defp telemetry_span(kind, target, fun) do
    metadata = %{kind: kind, target: target}

    started = System.monotonic_time()
    :telemetry.execute([:lemon, :reload, :start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()

      duration_ms = elapsed_ms(started)
      status = result_status(result)

      :telemetry.execute(
        [:lemon, :reload, :stop],
        %{duration_ms: duration_ms},
        Map.put(metadata, :status, status)
      )

      result
    rescue
      error ->
        duration_ms = elapsed_ms(started)

        :telemetry.execute(
          [:lemon, :reload, :exception],
          %{duration_ms: duration_ms},
          Map.merge(metadata, %{error: error, stacktrace: __STACKTRACE__})
        )

        {:error, {:exception, Exception.message(error)}}
    catch
      kind, value ->
        duration_ms = elapsed_ms(started)

        :telemetry.execute(
          [:lemon, :reload, :exception],
          %{duration_ms: duration_ms},
          Map.merge(metadata, %{error: {kind, value}, stacktrace: __STACKTRACE__})
        )

        {:error, {kind, value}}
    end
  end

  defp maybe_compile_sources(opts) do
    if Keyword.get(opts, :compile, false) do
      compile_force = Keyword.get(opts, :compile_force, Keyword.get(opts, :force, false))
      compile_fn = Keyword.get(opts, :compile_fn)
      started = System.monotonic_time()

      cond do
        is_function(compile_fn, 0) ->
          case compile_fn.() do
            :ok ->
              {:ok,
               %{
                 ran: true,
                 source: :custom,
                 force: compile_force,
                 duration_ms: elapsed_ms(started)
               }}

            {:error, reason} ->
              {:error, {:compile_failed, reason}}

            other ->
              {:error, {:compile_failed, other}}
          end

        mix_available?() ->
          try do
            Mix.Task.reenable("compile")
            args = if compile_force, do: ["--force"], else: []
            _ = Mix.Task.run("compile", args)

            {:ok,
             %{
               ran: true,
               source: :mix,
               force: compile_force,
               duration_ms: elapsed_ms(started)
             }}
          rescue
            e ->
              {:error, {:compile_failed, Exception.message(e)}}
          catch
            kind, value ->
              {:error, {:compile_failed, {kind, value}}}
          end

        true ->
          {:error, :mix_unavailable}
      end
    else
      {:ok, nil}
    end
  end

  defp mix_available? do
    Code.ensure_loaded?(Mix.Task) and function_exported?(Mix.Task, :run, 2) and
      function_exported?(Mix.Task, :reenable, 1)
  end

  defp with_reload_lock(opts, fun) do
    lock_nodes = Keyword.get(opts, :lock_nodes, [node()])
    retries = Keyword.get(opts, :lock_retries, 0)

    case :global.trans(@lock_key, fn -> fun.() end, lock_nodes, retries) do
      :aborted -> {:error, :reload_in_progress}
      result -> result
    end
  end

  defp unwrap({:ok, result}), do: result

  defp normalize_atom_list(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(values) do
    values
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp maybe_put_compile_metadata(result_or_metadata, nil), do: result_or_metadata

  defp maybe_put_compile_metadata(%{metadata: metadata} = result, compile_meta) do
    %{result | metadata: Map.put(metadata || %{}, :compile, compile_meta)}
  end

  defp maybe_put_compile_metadata(metadata, compile_meta) when is_map(metadata) do
    Map.put(metadata, :compile, compile_meta)
  end

  defp ok_result(kind, target, reloaded, skipped, errors, started, metadata) do
    {:ok,
     %{
       kind: kind,
       target: target,
       status: status_for(reloaded, skipped, errors),
       reloaded: reloaded,
       skipped: skipped,
       errors: errors,
       duration_ms: elapsed_ms(started),
       metadata: metadata
     }}
  end

  defp partial_result(kind, target, reloaded, skipped, errors, started, metadata) do
    {:ok,
     %{
       kind: kind,
       target: target,
       status: :partial,
       reloaded: reloaded,
       skipped: skipped,
       errors: errors,
       duration_ms: elapsed_ms(started),
       metadata: metadata
     }}
  end

  defp error_result(kind, target, started, error, message) do
    {:ok,
     %{
       kind: kind,
       target: target,
       status: :error,
       reloaded: [],
       skipped: [],
       errors: [%{target: target, reason: error}],
       duration_ms: elapsed_ms(started),
       metadata: %{error_message: message}
     }}
  end

  defp status_for(_reloaded, _skipped, errors) when errors != [], do: :error
  defp status_for(_reloaded, skipped, _errors) when skipped != [], do: :partial
  defp status_for(_reloaded, _skipped, _errors), do: :ok

  defp result_status({:ok, %{status: status}}), do: status
  defp result_status({:error, _}), do: :error
  defp result_status(_), do: :unknown

  defp elapsed_ms(started) do
    elapsed = System.monotonic_time() - started
    System.convert_time_unit(elapsed, :native, :millisecond)
  end
end
