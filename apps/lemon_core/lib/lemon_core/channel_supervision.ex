defmodule LemonCore.ChannelSupervision do
  @moduledoc """
  Optional runtime bridge for durable automation supervision notices.

  The channels runtime registers its implementation with `register/1` when its
  default supervision worker starts. Registration describes a module, not worker
  liveness: binding and lookup may use Store directly, and notice admission may
  persist intent while the worker is down. Isolated workers do not register.

  An absent, unloadable or missing callback returns `{:error, :channels_unavailable}`.
  Provider errors are preserved, including `:supervision_unavailable` after durable
  admission. A failed query returns `{:error, :query_failed}`, never `:none`.
  Mutations that raise, exit, throw or return malformed acknowledgements return
  `{:error, :outcome_unknown}`; callers must reconcile rather than blindly retry.
  `:ok` from `notify/2` acknowledges admission, not platform delivery.
  """

  @provider_key :channel_supervision_provider

  @type target :: %{channel_id: binary(), account_id: binary(), peer: map()}
  @type mutation_result :: :ok | {:error, atom()}
  @type lookup_result :: {:ok, target()} | :none | {:error, atom()}

  @callback bind_run(binary(), binary(), target()) :: mutation_result()
  @callback target_for_run(binary(), binary()) :: lookup_result()
  @callback notify(target(), map()) :: mutation_result()

  @doc "Registers a complete provider without requiring a live worker."
  @spec register(module()) :: :ok | {:error, :not_a_provider}
  def register(module) do
    case LemonCore.RuntimeSeam.register(@provider_key, module, __MODULE__) do
      :ok -> :ok
      {:error, _} -> {:error, :not_a_provider}
    end
  end

  @doc "The registered implementation, or `nil` when absent."
  @spec provider() :: module() | nil
  def provider, do: LemonCore.RuntimeSeam.provider(@provider_key)

  @spec bind_run(binary(), binary(), target()) :: mutation_result()
  def bind_run(run_id, session_key, target),
    do: invoke(:bind_run, [run_id, session_key, target], :mutation)

  @spec target_for_run(binary(), binary()) :: lookup_result()
  def target_for_run(run_id, session_key),
    do: invoke(:target_for_run, [run_id, session_key], :query)

  @spec notify(target(), map()) :: mutation_result()
  def notify(target, notice), do: invoke(:notify, [target, notice], :mutation)

  defp invoke(function, args, kind) do
    result =
      LemonCore.RuntimeSeam.invoke(provider(), function, args,
        unavailable: {:error, :channels_unavailable},
        exception: failed(kind),
        exit: failed(kind),
        throw: failed(kind)
      )

    normalize(result, kind)
  end

  defp normalize(:ok, :mutation), do: :ok
  defp normalize(:none, :query), do: :none

  defp normalize(
         {:ok, %{channel_id: channel_id, account_id: account_id, peer: peer} = target},
         :query
       )
       when is_binary(channel_id) and is_binary(account_id) and is_map(peer),
       do: {:ok, target}

  defp normalize({:error, reason}, _) when is_atom(reason), do: {:error, reason}
  defp normalize(_, kind), do: failed(kind)

  defp failed(:mutation), do: {:error, :outcome_unknown}
  defp failed(:query), do: {:error, :query_failed}
end
