defmodule LemonIngestion.Registry do
  @moduledoc """
  ETS-based registry for event subscriptions.

  Maps session keys to their subscription criteria. Used by the
  Event Router to determine which sessions should receive an event.

  ## Schema

  Table: `:ingestion_subscriptions`
  - Key: session_key (binary)
  - Value: %Subscription{}

  ## Subscription Structure

  %{
    session_key: "agent:zeebot:main",
    agent_id: "zeebot",
    type: :polymarket,           # :polymarket | :twitter | :price | :news
    filters: %{                   # source-specific filters
      min_liquidity: 100_000,
      min_trade_size: 10_000,
      markets: ["*"] or ["0xabc..."]
    },
    importance: :medium,          # :low | :medium | :high | :critical
    created_at: DateTime.utc_now()
  }
  """

  use GenServer

  @table :ingestion_subscriptions

  defstruct [
    :session_key,
    :agent_id,
    :type,
    :filters,
    :importance,
    :created_at
  ]

  @type subscription :: %__MODULE__{
    session_key: binary(),
    agent_id: binary(),
    type: atom(),
    filters: map(),
    importance: atom(),
    created_at: DateTime.t()
  }

  # --- Client API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Subscribe a session to receive events.

  ## Options

    * `:type` - Required. Event type (:polymarket, :twitter, :price, :news)
    * `:filters` - Optional. Source-specific filter criteria
    * `:importance` - Optional. Minimum importance threshold (:low, :medium, :high)
    * `:agent_id` - Optional. Auto-extracted from session_key if not provided
  """
  @spec subscribe(binary(), map()) :: :ok | {:error, term()}
  def subscribe(session_key, spec) when is_binary(session_key) and is_map(spec) do
    subscription = build_subscription(session_key, spec)
    GenServer.call(__MODULE__, {:subscribe, subscription})
  end

  @doc """
  Unsubscribe a session from all events.
  """
  @spec unsubscribe(binary()) :: :ok
  def unsubscribe(session_key) when is_binary(session_key) do
    GenServer.call(__MODULE__, {:unsubscribe, session_key})
  end

  @doc """
  Look up subscriptions matching a given event type.
  Returns all subscriptions for that type (router applies filters).
  """
  @spec find_subscriptions(atom()) :: [subscription()]
  def find_subscriptions(event_type) when is_atom(event_type) do
    :ets.select(@table, [
      {{
        :_,
        %{type: event_type}
      }, [], [:"$_"]}
    ])
    |> Enum.map(fn {_key, sub} -> sub end)
  end

  @doc """
  Get subscription for a specific session.
  """
  @spec get_subscription(binary()) :: subscription() | nil
  def get_subscription(session_key) do
    case :ets.lookup(@table, session_key) do
      [{^session_key, sub}] -> sub
      [] -> nil
    end
  end

  @doc """
  List all active subscriptions.
  """
  @spec list_subscriptions() :: [subscription()]
  def list_subscriptions do
    :ets.tab2list(@table)
    |> Enum.map(fn {_key, sub} -> sub end)
  end

  @doc """
  Count total subscriptions.
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table, :size)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_) do
    table = :ets.new(@table, [
      :set,
      :protected,
      :named_table,
      read_concurrency: true
    ])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:subscribe, subscription}, _from, state) do
    :ets.insert(@table, {subscription.session_key, subscription})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unsubscribe, session_key}, _from, state) do
    :ets.delete(@table, session_key)
    {:reply, :ok, state}
  end

  # --- Private Functions ---

  defp build_subscription(session_key, spec) do
    agent_id = spec[:agent_id] || extract_agent_id(session_key)

    %__MODULE__{
      session_key: session_key,
      agent_id: agent_id,
      type: spec[:type] || raise(ArgumentError, "type is required"),
      filters: spec[:filters] || %{},
      importance: spec[:importance] || :low,
      created_at: DateTime.utc_now()
    }
  end

  defp extract_agent_id(session_key) do
    case String.split(session_key, ":") do
      ["agent", agent_id | _] -> agent_id
      _ -> "unknown"
    end
  end
end
