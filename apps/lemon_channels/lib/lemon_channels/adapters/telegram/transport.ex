defmodule LemonChannels.Adapters.Telegram.Transport do
  @moduledoc """
  Telegram polling transport that normalizes messages and forwards them to LemonRouter.

  This transport wraps the existing LemonGateway.Telegram.Transport polling logic
  but routes messages through the new lemon_channels -> lemon_router pipeline.
  """

  use GenServer

  require Logger

  alias LemonChannels.Adapters.Telegram.Inbound

  @default_poll_interval 1_000
  @default_dedupe_ttl 600_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config, Application.get_env(:lemon_gateway, :telegram, %{}))
    token = config[:bot_token] || config["bot_token"]

    if is_binary(token) and token != "" do
      # Initialize dedupe ETS table
      ensure_dedupe_table()

      state = %{
        token: token,
        api_mod: config[:api_mod] || LemonGateway.Telegram.API,
        poll_interval_ms: config[:poll_interval_ms] || @default_poll_interval,
        dedupe_ttl_ms: config[:dedupe_ttl_ms] || @default_dedupe_ttl,
        account_id: config[:account_id] || "default",
        offset: config[:offset] || 0
      }

      send(self(), :poll)
      {:ok, state}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_updates(state)
    Process.send_after(self(), :poll, state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp poll_updates(state) do
    case state.api_mod.get_updates(state.token, state.offset, state.poll_interval_ms) do
      {:ok, %{"ok" => true, "result" => updates}} ->
        {state, max_id} = handle_updates(state, updates)
        %{state | offset: max(state.offset, max_id + 1)}

      _ ->
        state
    end
  rescue
    e ->
      Logger.warning("Telegram poll error: #{inspect(e)}")
      state
  end

  defp handle_updates(state, updates) do
    Enum.reduce(updates, {state, state.offset}, fn update, {acc_state, max_id} ->
      id = update["update_id"] || max_id

      # Normalize and route through lemon_router
      case Inbound.normalize(update) do
        {:ok, inbound} ->
          # Set account_id from config
          inbound = %{inbound | account_id: acc_state.account_id}

          # Check dedupe
          key = dedupe_key(inbound)
          if not is_seen?(key, acc_state.dedupe_ttl_ms) do
            mark_seen(key, acc_state.dedupe_ttl_ms)
            route_to_router(inbound)
          end

        {:error, _reason} ->
          # Unsupported update type, skip
          :ok
      end

      {acc_state, max(max_id, id)}
    end)
  end

  defp route_to_router(inbound) do
    # Forward to LemonRouter.Router.handle_inbound/1 if available
    if Code.ensure_loaded?(LemonRouter.Router) and
       function_exported?(LemonRouter.Router, :handle_inbound, 1) do
      LemonRouter.Router.handle_inbound(inbound)
    else
      # Fallback: emit telemetry for observability
      LemonCore.Telemetry.channel_inbound("telegram", %{
        peer_id: inbound.peer.id,
        peer_kind: inbound.peer.kind
      })
    end
  rescue
    e ->
      Logger.warning("Failed to route inbound message: #{inspect(e)}")
  end

  # Dedupe helpers

  @dedupe_table :lemon_channels_telegram_dedupe

  defp ensure_dedupe_table do
    if :ets.whereis(@dedupe_table) == :undefined do
      :ets.new(@dedupe_table, [:named_table, :public, :set])
    end
    :ok
  end

  defp dedupe_key(inbound) do
    {inbound.peer.id, inbound.message.id}
  end

  defp is_seen?(key, ttl_ms) do
    case :ets.lookup(@dedupe_table, key) do
      [{^key, expires_at}] ->
        now = System.system_time(:millisecond)
        if now < expires_at do
          true
        else
          :ets.delete(@dedupe_table, key)
          false
        end

      [] ->
        false
    end
  rescue
    _ -> false
  end

  defp mark_seen(key, ttl_ms) do
    expires_at = System.system_time(:millisecond) + ttl_ms
    :ets.insert(@dedupe_table, {key, expires_at})
  rescue
    _ -> :ok
  end
end
