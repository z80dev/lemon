defmodule LemonIngestion.Router do
  @moduledoc """
  Routes events to matching subscriptions and delivers them.

  The router:
  1. Receives an event from an adapter or HTTP endpoint
  2. Queries the Registry for subscriptions matching the event type
  3. Filters subscriptions based on event criteria
  4. Delivers to each matching session via LemonRouter.AgentInbox

  Delivery is async (via Task.Supervisor) to avoid blocking.
  """

  use GenServer

  alias LemonIngestion.Registry

  @importance_levels %{
    low: 1,
    medium: 2,
    high: 3,
    critical: 4
  }

  defstruct []

  # --- Client API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Route an event to all matching subscriptions.

  Returns immediately with counts of delivered/failed.
  Actual delivery happens asynchronously.

  ## Event Format

  %{
    source: :polymarket,        # :polymarket | :twitter | :price | :news
    type: :large_trade,         # source-specific event type
    timestamp: DateTime.utc_now(),
    importance: :high,          # :low | :medium | :high | :critical
    data: %{...},               # source-specific payload
    url: "https://..."          # optional link
  }
  """
  @spec route(map()) :: {:ok, %{delivered: non_neg_integer(), failed: non_neg_integer()}}
  def route(event) do
    GenServer.call(__MODULE__, {:route, event})
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:route, event}, _from, state) do
    subscriptions = Registry.find_subscriptions(event.source)

    {matches, _non_matches} =
      Enum.split_with(subscriptions, fn sub ->
        matches?(sub, event)
      end)

    # Deliver async to avoid blocking
    results =
      Enum.map(matches, fn sub ->
        Task.Supervisor.start_child(
          LemonIngestion.TaskSupervisor,
          fn -> deliver(sub, event) end
        )
      end)

    delivered = Enum.count(results, &match?({:ok, _}, &1))
    failed = length(results) - delivered

    {:reply, {:ok, %{delivered: delivered, failed: failed}}, state}
  end

  # --- Private Functions ---

  @doc """
  Check if a subscription matches an event.

  Matching criteria:
  1. Event importance >= subscription importance threshold
  2. Source-specific filters pass
  """
  @spec matches?(Registry.subscription(), map()) :: boolean()
  def matches?(subscription, event) do
    importance_match?(subscription.importance, event.importance) and
      filters_match?(subscription.filters, event)
  end

  defp importance_match?(sub_level, event_level) do
    @importance_levels[event_level] >= @importance_levels[sub_level]
  end

  defp filters_match?(filters, event) do
    Enum.all?(filters, fn {key, value} ->
      filter_matches?(key, value, event)
    end)
  end

  # Polymarket-specific filters
  defp filter_matches?(:min_liquidity, min_liq, %{data: %{liquidity: liq}}) do
    liq >= min_liq
  end

  defp filter_matches?(:min_trade_size, min_size, %{data: %{trade_size: size}}) do
    size >= min_size
  end

  defp filter_matches?(:markets, ["*"], _event), do: true

  defp filter_matches?(:markets, markets, %{data: %{market_id: market_id}}) do
    market_id in markets
  end

  # Price-specific filters
  defp filter_matches?(:tokens, tokens, %{data: %{token_address: addr}}) do
    addr in tokens
  end

  defp filter_matches?(:threshold_pct, threshold, %{data: %{change_pct: change}}) do
    abs(change) >= threshold
  end

  # Twitter-specific filters
  defp filter_matches?(:accounts, accounts, %{data: %{author: author}}) do
    author in accounts
  end

  # News-specific filters
  defp filter_matches?(:keywords, keywords, %{data: %{title: title, content: content}}) do
    text = "#{title} #{content}" |> String.downcase()
    Enum.any?(keywords, fn kw -> String.contains?(text, String.downcase(kw)) end)
  end

  # Default: if filter key doesn't exist in event, it passes
  defp filter_matches?(_key, _value, _event), do: true

  @doc """
  Deliver an event to a subscription.

  Formats the event as a message and sends via LemonRouter.AgentInbox.
  """
  @spec deliver(Registry.subscription(), map()) :: :ok | {:error, term()}
  def deliver(subscription, event) do
    message = format_message(event)

    opts = [
      session: subscription.session_key,
      queue_mode: :followup,
      source: :ingestion,
      meta: %{
        ingestion_event_id: event[:id],
        ingestion_source: event.source,
        ingestion_type: event.type
      }
    ]

    case LemonRouter.send_to_agent(subscription.agent_id, message, opts) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to deliver event to #{subscription.session_key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp format_message(event) do
    base = """
    📡 External Event: #{format_source(event.source)} #{format_type(event.type)}

    #{format_event_data(event.data)}
    """

    if event[:url] do
      base <> "\n\nSource: #{event.url}"
    else
      base
    end
  end

  defp format_source(:polymarket), do: "🎯 Polymarket"
  defp format_source(:twitter), do: "🐦 Twitter"
  defp format_source(:price), do: "📈 Price Alert"
  defp format_source(:news), do: "📰 News"
  defp format_source(other), do: to_string(other)

  defp format_type(type), do: type |> to_string() |> String.replace("_", " ") |> String.upcase()

  defp format_event_data(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} -> "#{format_key(k)}: #{format_value(v)}" end)
    |> Enum.join("\n")
  end

  defp format_key(key) do
    key
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp format_value(n) when is_number(n) and n > 1000, do: "#{Float.round(n / 1000, 1)}K"
  defp format_value(n) when is_number(n), do: to_string(n)
  defp format_value(v), do: to_string(v)
end
