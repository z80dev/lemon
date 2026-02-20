defmodule MarketIntel.Commentary.Pipeline do
  @moduledoc """
  Generates market commentary tweets based on ingested data.

  Triggered by:
  - scheduled intervals (every 30 min)
  - significant price movements (> configured threshold)
  - high-engagement mentions
  - interesting Polymarket events
  - manual requests

  Uses GenStage for backpressure and batching.
  """

  use GenStage
  require Logger

  alias MarketIntel.Commentary.PromptBuilder

  @typedoc "Trigger type for commentary generation"
  @type trigger_type ::
          :scheduled
          | :price_spike
          | :price_drop
          | :mention_reply
          | :weird_market
          | :volume_surge
          | :manual

  @typedoc "Vibe/theme for commentary style"
  @type vibe :: :crypto_commentary | :gaming_joke | :agent_self_aware | :lemon_persona

  @typedoc "Market data snapshot"
  @type market_snapshot :: %{
          timestamp: DateTime.t(),
          token: {:ok, map()} | :error | :expired,
          eth: {:ok, map()} | :error | :expired,
          polymarket: {:ok, map()} | :error | :expired
        }

  @typedoc "Trigger context map"
  @type trigger_context :: %{
          optional(:immediate) => boolean(),
          optional(:change) => number(),
          optional(atom()) => any()
        }

  @typedoc "Commentary record for storage"
  @type commentary_record :: %{
          tweet_id: String.t(),
          content: String.t(),
          trigger_event: String.t(),
          market_context: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  # Commentary vibes/themes
  @vibes [
    :crypto_commentary,
    :gaming_joke,
    :agent_self_aware,
    :lemon_persona
  ]

  # Trigger types
  @triggers %{
    scheduled: "Regular market update",
    price_spike: "Significant price movement",
    price_drop: "Significant price drop",
    mention_reply: "High-engagement mention",
    weird_market: "Interesting Polymarket event",
    volume_surge: "Unusual trading volume",
    manual: "User requested"
  }

  # Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger commentary generation"
  @spec trigger(trigger_type(), trigger_context()) :: :ok
  def trigger(trigger_type, context \\ %{}) do
    GenStage.cast(__MODULE__, {:trigger, trigger_type, context})
  end

  @doc "Generate and post commentary immediately"
  @spec generate_now() :: :ok
  def generate_now do
    trigger(:manual, %{immediate: true})
  end

  # GenStage callbacks

  @impl true
  @spec init(keyword()) :: {:producer_consumer, map(), list()}
  def init(_opts) do
    # Buffer of pending commentary requests
    {:producer_consumer, %{pending: []}, subscribe_to: []}
  end

  @impl true
  @spec handle_cast({:trigger, trigger_type(), trigger_context()}, map()) ::
          {:noreply, list(), map()}
  def handle_cast({:trigger, trigger_type, context}, state) do
    # Add to pending queue
    new_pending = [
      %{type: trigger_type, context: context, timestamp: DateTime.utc_now()} | state.pending
    ]

    # Process if immediate
    if context[:immediate] do
      process_commentary(hd(new_pending))
      {:noreply, [], %{state | pending: tl(new_pending)}}
    else
      {:noreply, [], %{state | pending: new_pending}}
    end
  end

  @impl true
  @spec handle_events(list(), GenServer.from(), map()) :: {:noreply, list(), map()}
  def handle_events(events, _from, state) do
    # Process batched events
    Enum.each(events, &process_commentary/1)
    {:noreply, [], state}
  end

  # Private functions

  @spec process_commentary(%{type: trigger_type(), context: trigger_context()}) :: :ok
  defp process_commentary(%{type: trigger_type, context: context}) do
    Logger.info("[MarketIntel] Generating commentary for: #{@triggers[trigger_type]}")

    # Get current market snapshot
    snapshot = MarketIntel.Cache.get_snapshot()

    # Build prompt using the PromptBuilder module
    prompt = build_prompt(trigger_type, snapshot, context)

    # Generate tweet (integrates with AI module)
    {:ok, tweet_text} = generate_tweet(prompt)

    # Post to X
    post_commentary(tweet_text, trigger_type, snapshot)
  end

  @spec build_prompt(trigger_type(), market_snapshot(), trigger_context()) :: String.t()
  defp build_prompt(trigger_type, snapshot, context) do
    vibe = select_vibe()
    token_name = MarketIntel.Config.tracked_token_name()
    token_ticker = MarketIntel.Config.tracked_token_ticker()

    builder = %PromptBuilder{
      vibe: vibe,
      market_data: %{
        token: snapshot.token,
        eth: snapshot.eth,
        polymarket: snapshot.polymarket
      },
      token_name: token_name,
      token_ticker: token_ticker,
      trigger_type: trigger_type,
      trigger_context: context
    }

    PromptBuilder.build(builder)
  end

  @spec select_vibe() :: vibe()
  defp select_vibe do
    Enum.random(@vibes)
  end

  @spec generate_tweet(String.t()) :: {:ok, String.t()}
  defp generate_tweet(prompt) do
    # Try AI generation if configured
    # Note: AI providers currently return {:error, :not_implemented} as placeholders
    case generate_with_ai(prompt) do
      {:ok, tweet} when is_binary(tweet) and tweet != "" -> {:ok, tweet}
      {:error, reason} -> 
        Logger.warning("[MarketIntel] AI generation failed: #{inspect(reason)}, using fallback")
        {:ok, generate_fallback_tweet()}
    end
  end

  @spec generate_with_ai(String.t()) :: {:ok, String.t()} | {:error, atom()} | nil
  defp generate_with_ai(prompt) do
    # Try OpenAI first, then Anthropic
    cond do
      MarketIntel.Secrets.configured?(:openai_key) ->
        generate_with_openai(prompt)

      MarketIntel.Secrets.configured?(:anthropic_key) ->
        generate_with_anthropic(prompt)

      true ->
        Logger.info("[MarketIntel] No AI provider configured, using fallback tweets")
        nil
    end
  end

  @spec generate_with_openai(String.t()) :: {:ok, String.t()} | {:error, atom()}
  defp generate_with_openai(_prompt) do
    # AI integration placeholder - implement when Lemon's AI module is available
    # This should call the AI module with appropriate parameters for tweet generation
    Logger.debug("[MarketIntel] Attempting OpenAI generation (not yet implemented)")
    
    # Placeholder: Return error to trigger fallback
    # When implemented, this should:
    # 1. Call Lemon's AI module with the prompt
    # 2. Apply tweet-specific parameters (max_tokens for ~280 chars)
    # 3. Return {:ok, generated_text} or {:error, reason}
    {:error, :not_implemented}
  end

  @spec generate_with_anthropic(String.t()) :: {:ok, String.t()} | {:error, atom()}
  defp generate_with_anthropic(_prompt) do
    # AI integration placeholder - implement when Lemon's AI module is available
    # This should call the AI module with appropriate parameters for tweet generation
    Logger.debug("[MarketIntel] Attempting Anthropic generation (not yet implemented)")
    
    # Placeholder: Return error to trigger fallback
    # When implemented, this should:
    # 1. Call Lemon's AI module with the prompt
    # 2. Apply tweet-specific parameters (max_tokens for ~280 chars)
    # 3. Return {:ok, generated_text} or {:error, reason}
    {:error, :not_implemented}
  end

  @spec generate_fallback_tweet() :: String.t()
  defp generate_fallback_tweet do
    token_ticker = MarketIntel.Config.tracked_token_ticker()
    developer_alias = MarketIntel.Config.commentary_developer_alias()

    templates =
      [
        "market update: #{token_ticker} is moving and I'm an AI agent running on BEAM 🍋",
        "just ingested some market data. my memory files are getting full 📊",
        "another day, another DEX scan. base fees still cheap thankfully",
        "polymarket has some wild markets today. humans keep things interesting",
        "my BEAM processes are humming. how's your containerized python agent doing? 😴"
      ]
      |> maybe_append_developer_template(developer_alias)

    Enum.random(templates)
  end

  @spec maybe_append_developer_template(list(String.t()), String.t() | nil) :: list(String.t())
  defp maybe_append_developer_template(templates, nil), do: templates
  defp maybe_append_developer_template(templates, ""), do: templates

  defp maybe_append_developer_template(templates, developer_alias) do
    templates ++
      [
        "runtime status: green. #{developer_alias} gave me another market loop and i survived 🍋"
      ]
  end

  @spec post_commentary(String.t(), trigger_type(), market_snapshot()) :: :ok
  defp post_commentary(text, trigger_type, snapshot) do
    # Post to X using LemonChannels
    case do_post_tweet(text) do
      {:ok, %{tweet_id: id}} ->
        Logger.info("[MarketIntel] Posted tweet #{id}: #{String.slice(text, 0, 50)}...")
        store_commentary(text, trigger_type, snapshot, id)

      {:error, reason} ->
        Logger.error("[MarketIntel] Failed to post: #{inspect(reason)}")
    end
  end

  @spec do_post_tweet(String.t()) :: {:ok, %{tweet_id: String.t()}} | {:error, any()}
  defp do_post_tweet(text) do
    # Use the existing X API client from lemon_channels when available
    client_module = Module.concat([LemonChannels, Adapters, XAPI, Client])

    if Code.ensure_loaded?(client_module) and function_exported?(client_module, :post_text, 1) do
      apply(client_module, :post_text, [text])
    else
      {:error, :x_api_client_unavailable}
    end
  rescue
    error ->
      {:error, "X API error: #{inspect(error)}"}
  end

  @spec store_commentary(String.t(), trigger_type(), market_snapshot(), String.t()) :: :ok
  defp store_commentary(text, trigger_type, snapshot, tweet_id) do
    # Store in SQLite for analysis
    # Track what works, what doesn't
    record = %{
      tweet_id: tweet_id,
      content: text,
      trigger_event: Atom.to_string(trigger_type),
      market_context: snapshot_to_map(snapshot),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    # Insert into commentary_history table
    # This function stub is documented for future implementation
    insert_commentary_history(record)
    
    Logger.debug("[MarketIntel] Stored commentary record: #{inspect(record)}")
    :ok
  end

  @doc """
  Inserts a commentary record into the commentary_history table.
  
  This is a function stub for future database integration. Currently logs the
  record at debug level. When implemented, this should:
  
  1. Insert the record into the commentary_history table via MarketIntel.Repo
  2. Handle duplicate tweet_id gracefully (upsert)
  3. Return {:ok, record} on success or {:error, reason} on failure
  
  ## Example
  
      iex> record = %{
      ...>   tweet_id: "1234567890",
      ...>   content: "market update...",
      ...>   trigger_event: "scheduled",
      ...>   market_context: %{...},
      ...>   inserted_at: DateTime.utc_now(),
      ...>   updated_at: DateTime.utc_now()
      ...> }
      iex> insert_commentary_history(record)
      :ok
  
  """
  @spec insert_commentary_history(commentary_record()) :: :ok | {:error, any()}
  def insert_commentary_history(record) do
    # TODO: Implement database insertion via MarketIntel.Repo
    # Example implementation:
    #
    # import Ecto.Query
    # 
    # changeset = MarketIntel.Schema.CommentaryHistory.changeset(
    #   %MarketIntel.Schema.CommentaryHistory{},
    #   record
    # )
    # 
    # case MarketIntel.Repo.insert(changeset, on_conflict: :replace_all, conflict_target: :tweet_id) do
    #   {:ok, inserted} -> 
    #     Logger.info("[MarketIntel] Stored commentary #{inserted.tweet_id}")
    #     {:ok, inserted}
    #   {:error, changeset} -> 
    #     Logger.error("[MarketIntel] Failed to store commentary: #{inspect(changeset.errors)}")
    #     {:error, changeset}
    # end
    
    Logger.debug("[MarketIntel] Commentary history storage not yet implemented. Record: #{inspect(record)}")
    :ok
  end

  @spec snapshot_to_map(market_snapshot()) :: map()
  defp snapshot_to_map(snapshot) do
    %{
      timestamp: DateTime.to_iso8601(snapshot.timestamp),
      token: format_maybe(snapshot.token),
      eth: format_maybe(snapshot.eth),
      polymarket: format_maybe(snapshot.polymarket)
    }
  end

  @spec format_maybe({:ok, any()} | any()) :: any() | nil
  defp format_maybe({:ok, data}), do: data
  defp format_maybe(_), do: nil
end
