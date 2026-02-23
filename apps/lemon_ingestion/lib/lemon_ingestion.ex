defmodule LemonIngestion do
  @moduledoc """
  Data ingestion pipeline for external events.

  Provides infrastructure to ingest events from external sources
  (Polymarket, Twitter, price feeds, news) and deliver them to
  agent sessions as system messages.

  ## Usage

      # Subscribe an agent session to events
      LemonIngestion.subscribe("agent:zeebot:main", %{
        type: :polymarket,
        filters: %{min_liquidity: 100_000, min_trade_size: 10_000}
      })

      # Ingest an event (called by adapters or external webhooks)
      LemonIngestion.ingest(%{
        source: :polymarket,
        type: :large_trade,
        data: %{...},
        importance: :high
      })

  ## Architecture

  ┌─────────────────────────────────────────────────────────────┐
  │  Adapters (Polymarket, Twitter, etc.) → ingest/1            │
  ├─────────────────────────────────────────────────────────────┤
  │  Subscription Registry (ETS) - who wants what               │
  ├─────────────────────────────────────────────────────────────┤
  │  Event Router - match events to subscriptions               │
  ├─────────────────────────────────────────────────────────────┤
  │  Delivery → LemonRouter.AgentInbox.send/3                   │
  └─────────────────────────────────────────────────────────────┘
  """

  alias LemonIngestion.{Registry, Router}

  @doc """
  Subscribe a session to receive events matching the given criteria.

  ## Options

    * `:type` - Event type (:polymarket, :twitter, :price, :news)
    * `:filters` - Source-specific filters
    * `:importance` - Minimum importance level (:low, :medium, :high, :critical)

  ## Examples

      LemonIngestion.subscribe("agent:zeebot:main", %{
        type: :polymarket,
        filters: %{min_liquidity: 100_000},
        importance: :medium
      })
  """
  @spec subscribe(binary(), map()) :: :ok | {:error, term()}
  def subscribe(session_key, subscription_spec) do
    Registry.subscribe(session_key, subscription_spec)
  end

  @doc """
  Unsubscribe a session from events.
  """
  @spec unsubscribe(binary()) :: :ok
  def unsubscribe(session_key) do
    Registry.unsubscribe(session_key)
  end

  @doc """
  List all active subscriptions.
  """
  @spec list_subscriptions() :: [map()]
  def list_subscriptions do
    Registry.list_subscriptions()
  end

  @doc """
  Ingest an event and route it to matching subscriptions.

  Called by adapters when they detect events, or by external
  webhooks pushing events to the HTTP endpoint.
  """
  @spec ingest(map()) :: {:ok, %{delivered: non_neg_integer(), failed: non_neg_integer()}} | {:error, term()}
  def ingest(event) do
    Router.route(event)
  end

  @doc """
  Get the status of all ingestion adapters.
  """
  @spec adapter_status() :: map()
  def adapter_status do
    LemonIngestion.Adapters.Supervisor.status()
  end
end
