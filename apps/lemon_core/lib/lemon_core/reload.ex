defmodule Lemon.Reload do
  @moduledoc """
  Runtime hot-reload helpers built on BEAM code loading primitives.

  This module provides two distinct reload paths:

  - beam-based reload (`reload_module/1`, `reload_app/1`) for modules with `.beam`
    artifacts already on the code path
  - source-based reload (`reload_extension/1`) for extension `.ex/.exs` files loaded
    at runtime

  All public reload operations run under a global lock so only one reload plan can
  execute at a time.
  """

  @lock_key {__MODULE__, :reload_lock}

  @type error_item :: %{target: module() | String.t(), reason: term()}
  @type skip_item :: %{target: module() | String.t(), reason: term()}

  @type result :: %{
          kind: :module | :app | :extension,
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
        started = System.monotonic_time()

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

          status = status_for(reloaded, skipped, [])

          {:ok,
           %{
             kind: :extension,
             target: path,
             status: status,
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
      end)
    end)
  end

  @spec reload_app(atom(), keyword()) :: {:ok, result()} | {:error, term()}
  def reload_app(app, opts \\ []) when is_atom(app) do
    with_reload_lock(opts, fn ->
      telemetry_span(:app, app, fn ->
        started = System.monotonic_time()

        modules = Application.spec(app, :modules) || []

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
      end)
    end)
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
