defmodule CodingAgent.Search.Dispatcher do
  @moduledoc """
  Capability-aware provider selection with bounded, deterministic fallback.

  The optional `:signal` aborts provider work without attempting fallback and is
  passed to providers as `context.abort_signal`. With `:single_flight_key`, each
  caller can leave independently; providers receive the shared flight signal.
  Blocked callbacks get a short cooperative cleanup window before they are
  killed; provider termination is confirmed before the dispatcher returns.

  An optional zero-argument `:authorize` callback admits each provider attempt.
  Shared-fetch callers use this to refresh caller cancellation synchronously
  before fallback instead of relying on the shared signal's abort poll.
  """

  import LemonAgent.Tools.AbortHelpers, only: [aborted?: 1, check_abort: 1]

  alias CodingAgent.Search.Registry
  alias CodingAgent.Search.SingleFlight

  @default_timeout_ms 30_000
  @abort_poll_ms 50
  @abort_grace_ms 250

  @type metadata :: %{
          requested_provider: String.t() | nil,
          provider_used: String.t(),
          attempts: [map()]
        }

  @spec run(:search | :extract, map(), keyword()) ::
          {:ok, map(), metadata()}
          | {:error, {:all_providers_failed, [map()]}}
          | {:error, {:provider_terminal, String.t(), term(), [map()]}}
          | {:error, String.t()}
  def run(capability, request, opts \\ []) when capability in [:search, :extract] do
    signal = Keyword.get(opts, :signal)

    with :ok <- check_abort(signal) do
      case Keyword.get(opts, :single_flight_key) do
        nil ->
          do_run(capability, request, opts)

        key ->
          SingleFlight.run(
            {capability, key},
            fn flight_signal ->
              do_run(capability, request, Keyword.put(opts, :signal, flight_signal))
            end,
            timeout_ms(opts),
            signal: signal
          )
      end
    end
  end

  defp do_run(capability, request, opts) do
    provider_ids = provider_ids(capability, opts)
    requested = List.first(provider_ids)
    attempt(provider_ids, capability, request, opts, requested, [])
  end

  defp attempt(providers, capability, request, opts, requested, attempts) do
    with :ok <- check_abort(Keyword.get(opts, :signal)),
         :ok <- authorize(opts) do
      attempt_next(providers, capability, request, opts, requested, attempts)
    end
  end

  # Optional shared-flight admission refreshes the attached callers rather than
  # relying on the asynchronous flight-signal poll before starting a fallback.
  defp authorize(opts) do
    case Keyword.get(opts, :authorize) do
      nil -> :ok
      fun -> fun.()
    end
  end

  defp attempt_next([], _capability, _request, _opts, _requested, attempts) do
    {:error, {:all_providers_failed, Enum.reverse(attempts)}}
  end

  defp attempt_next([id | rest], capability, request, opts, requested, attempts) do
    case Registry.fetch(id) do
      {:error, :not_found} ->
        failure = failure(id, :not_registered)
        attempt(rest, capability, request, opts, requested, [failure | attempts])

      {:ok, spec} ->
        if capability in spec.capabilities do
          context = provider_context(spec, opts)

          case safe_available(spec.module, capability, context) do
            :ok ->
              signal = Keyword.get(opts, :signal)

              case invoke(spec.module, capability, request, context, timeout_ms(opts), signal) do
                {:ok, payload} when is_map(payload) ->
                  with :ok <- check_abort(signal) do
                    success = %{provider: spec.id, status: :ok}

                    {:ok, payload,
                     %{
                       requested_provider: requested,
                       provider_used: spec.id,
                       attempts: Enum.reverse([success | attempts])
                     }}
                  end

                {:error, "Operation aborted"} = error ->
                  error

                {:error, {:terminal, reason}} ->
                  terminal = failure(spec.id, reason)

                  {:error,
                   {:provider_terminal, spec.id, reason, Enum.reverse([terminal | attempts])}}

                {:error, reason} ->
                  failure = failure(spec.id, reason)
                  attempt(rest, capability, request, opts, requested, [failure | attempts])
              end

            {:error, reason} ->
              failure = failure(spec.id, {:unavailable, reason})
              attempt(rest, capability, request, opts, requested, [failure | attempts])
          end
        else
          failure = failure(id, :unsupported_capability)
          attempt(rest, capability, request, opts, requested, [failure | attempts])
        end
    end
  end

  defp provider_ids(capability, opts) do
    explicit = Keyword.get(opts, :providers) || optional_list(Keyword.get(opts, :provider))

    ids =
      case explicit do
        nil -> Enum.map(Registry.list(capability: capability), & &1.id)
        values -> values
      end

    ids
    |> Enum.map(&normalize_id/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp optional_list(nil), do: nil
  defp optional_list(value) when is_list(value), do: value
  defp optional_list(value), do: [value]

  defp provider_context(spec, opts) do
    base = Keyword.get(opts, :context, %{})
    configured = Map.get(Keyword.get(opts, :provider_contexts, %{}), spec.id, %{})

    base
    |> Map.merge(spec.config)
    |> Map.merge(configured)
    |> Map.put(:provider_id, spec.id)
    |> Map.put(:abort_signal, Keyword.get(opts, :signal))
  end

  defp safe_available(module, capability, context) do
    module.available?(capability, context)
  rescue
    error -> {:error, {:availability_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:availability_throw, kind, reason}}
  end

  defp invoke(module, capability, request, context, timeout_ms, signal) do
    with :ok <- check_abort(signal) do
      caller = self()
      token = make_ref()
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      {owner, monitor} =
        spawn_monitor(fn ->
          caller_monitor = Process.monitor(caller)
          owner = self()

          {provider, provider_monitor} =
            spawn_monitor(fn ->
              result =
                try do
                  apply(module, capability, [request, context])
                rescue
                  error -> {:error, {:provider_exception, Exception.message(error)}}
                catch
                  kind, reason -> {:error, {:provider_throw, kind, reason}}
                end

              send(owner, {token, result})
            end)

          guard_provider(caller, caller_monitor, provider, provider_monitor, token)
        end)

      await_provider(owner, monitor, token, signal, deadline)
    end
  end

  # This owner outlives a cancelled dispatcher/flight task long enough to stop
  # its provider. Linking the callback to the caller would propagate provider
  # crashes and would not stop a callback that traps exits.
  defp guard_provider(caller, caller_monitor, provider, provider_monitor, token) do
    receive do
      {^token, result} ->
        await_down(provider, provider_monitor)
        send(caller, {token, result})

      {:DOWN, ^provider_monitor, :process, ^provider, reason} ->
        send(caller, {token, {:error, {:provider_exit, reason}}})

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        kill_provider(provider, provider_monitor)

      {^token, :stop, :abort} ->
        receive do
          {:DOWN, ^provider_monitor, :process, ^provider, _reason} -> :ok
        after
          @abort_grace_ms -> kill_provider(provider, provider_monitor)
        end

      {^token, :stop, :timeout} ->
        kill_provider(provider, provider_monitor)
    end
  end

  defp await_provider(owner, monitor, token, signal, deadline) do
    if aborted?(signal) do
      stop_provider(owner, monitor, token, :abort)
      {:error, "Operation aborted"}
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)
      wait_ms = if is_nil(signal), do: remaining, else: min(remaining, @abort_poll_ms)

      receive do
        {^token, result} ->
          await_down(owner, monitor)
          with :ok <- check_abort(signal), do: result

        {:DOWN, ^monitor, :process, ^owner, reason} ->
          with :ok <- check_abort(signal), do: {:error, {:provider_exit, reason}}
      after
        wait_ms ->
          if System.monotonic_time(:millisecond) >= deadline do
            stop_provider(owner, monitor, token, :timeout)
            with :ok <- check_abort(signal), do: {:error, :provider_timeout}
          else
            await_provider(owner, monitor, token, signal, deadline)
          end
      end
    end
  end

  defp stop_provider(owner, monitor, token, reason) do
    send(owner, {token, :stop, reason})
    await_down(owner, monitor)

    receive do
      {^token, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp kill_provider(provider, monitor) do
    Process.exit(provider, :kill)
    await_down(provider, monitor)
  end

  defp await_down(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end
  end

  defp failure(provider, reason),
    do: %{provider: normalize_id(provider), status: :error, reason: reason}

  defp normalize_id(id) when is_atom(id), do: id |> Atom.to_string() |> normalize_id()
  defp normalize_id(id) when is_binary(id), do: id |> String.trim() |> String.downcase()
  defp normalize_id(_), do: ""

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, @default_timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_timeout_ms
    end
  end
end
