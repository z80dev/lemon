defmodule CodingAgent.Search.Dispatcher do
  @moduledoc """
  Capability-aware provider selection with bounded, deterministic fallback.
  """

  alias CodingAgent.Search.Registry
  alias CodingAgent.Search.SingleFlight

  @default_timeout_ms 30_000

  @type metadata :: %{
          requested_provider: String.t() | nil,
          provider_used: String.t(),
          attempts: [map()]
        }

  @spec run(:search | :extract, map(), keyword()) ::
          {:ok, map(), metadata()}
          | {:error, {:all_providers_failed, [map()]}}
          | {:error, {:provider_terminal, String.t(), term(), [map()]}}
  def run(capability, request, opts \\ []) when capability in [:search, :extract] do
    operation = fn -> do_run(capability, request, opts) end

    case Keyword.get(opts, :single_flight_key) do
      nil -> operation.()
      key -> SingleFlight.run({capability, key}, operation, timeout_ms(opts))
    end
  end

  defp do_run(capability, request, opts) do
    provider_ids = provider_ids(capability, opts)
    requested = List.first(provider_ids)
    attempt(provider_ids, capability, request, opts, requested, [])
  end

  defp attempt([], _capability, _request, _opts, _requested, attempts) do
    {:error, {:all_providers_failed, Enum.reverse(attempts)}}
  end

  defp attempt([id | rest], capability, request, opts, requested, attempts) do
    case Registry.fetch(id) do
      {:error, :not_found} ->
        failure = failure(id, :not_registered)
        attempt(rest, capability, request, opts, requested, [failure | attempts])

      {:ok, spec} ->
        if capability in spec.capabilities do
          context = provider_context(spec, opts)

          case safe_available(spec.module, capability, context) do
            :ok ->
              case invoke(spec.module, capability, request, context, timeout_ms(opts)) do
                {:ok, payload} when is_map(payload) ->
                  success = %{provider: spec.id, status: :ok}

                  {:ok, payload,
                   %{
                     requested_provider: requested,
                     provider_used: spec.id,
                     attempts: Enum.reverse([success | attempts])
                   }}

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
  end

  defp safe_available(module, capability, context) do
    module.available?(capability, context)
  rescue
    error -> {:error, {:availability_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:availability_throw, kind, reason}}
  end

  defp invoke(module, capability, request, context, timeout_ms) do
    parent = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            apply(module, capability, [request, context])
          rescue
            error -> {:error, {:provider_exception, Exception.message(error)}}
          catch
            kind, reason -> {:error, {:provider_throw, kind, reason}}
          end

        send(parent, {token, result})
      end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:provider_exit, reason}}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :provider_timeout}
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
