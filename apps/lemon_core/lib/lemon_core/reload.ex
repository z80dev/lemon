defmodule Lemon.Reload do
  @moduledoc """
  Runtime hot-reload helpers built on BEAM code loading primitives.

  This module provides two distinct reload paths:

  - beam-based reload (`reload_module/1`, `reload_app/1`) for modules with `.beam`
    artifacts already on the code path
  - source-based reload (`reload_extension/1`) for extension `.ex/.exs` files loaded
    at runtime

  It also exposes `reload_system/1` for orchestrated reload workflows under one
  global lock: app reloads, extension reloads, and `code_change/3` callbacks for
  live OTP processes.
  """

  @lock_key {__MODULE__, :reload_lock}

  @type error_item :: %{target: module() | String.t() | atom(), reason: term()}
  @type skip_item :: %{target: module() | String.t() | atom(), reason: term()}

  @type reload_kind :: :module | :app | :extension | :code_change | :system

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

  @spec reload_module(module(), keyword()) :: {:ok, result()} | {:error, term()}
  def reload_module(module, opts \\ []) when is_atom(module) do
    with_reload_lock(opts, fn ->
      telemetry_span(:module, module, fn ->
        do_reload_module(module)
      end)
    end)
  end

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

  @spec reload_extension(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def reload_extension(path, opts \\ []) when is_binary(path) do
    with_reload_lock(opts, fn ->
      telemetry_span(:extension, path, fn ->
        do_reload_extension(path)
      end)
    end)
  end

  @spec reload_app(atom(), keyword()) :: {:ok, result()} | {:error, term()}
  def reload_app(app, opts \\ []) when is_atom(app) do
    with_reload_lock(opts, fn ->
      telemetry_span(:app, app, fn ->
        do_reload_app(app)
      end)
    end)
  end

  @doc """
  Orchestrate a full runtime reload under one global lock.

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
           metadata: %{
             results: results,
             app_count: length(apps),
             extension_count: length(extension_paths),
             code_change_count: length(code_change_targets)
           }
         }}
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

  defp with_reload_lock(opts, fun) do
    lock_nodes = Keyword.get(opts, :lock_nodes, [node()])
    retries = Keyword.get(opts, :lock_retries, 0)

    case :global.trans(@lock_key, fn -> fun.() end, lock_nodes, retries) do
      :aborted -> {:error, :reload_in_progress}
      result -> result
    end
  end

  defp unwrap({:ok, result}), do: result

  defp unwrap(other),
    do: %{
      kind: :system,
      target: :unknown,
      status: :error,
      reloaded: [],
      skipped: [],
      errors: [%{target: :unknown, reason: other}],
      duration_ms: 0,
      metadata: %{}
    }

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
