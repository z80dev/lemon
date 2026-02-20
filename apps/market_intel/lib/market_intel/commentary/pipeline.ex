defmodule MarketIntel.Commentary.Pipeline do
  @moduledoc """
  Generates market commentary tweets based on ingested data.
  
  Triggered by:
  - Scheduled intervals (every 30 min)
  - Significant price movements (>10%)
  - High-engagement mentions
  - Interesting Polymarket events
  - Manual requests
  
  Uses GenStage for backpressure and batching.
  """
  
  use GenStage
  require Logger
  
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
  
  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @doc "Trigger commentary generation"
  def trigger(trigger_type, context \\ %{}) do
    GenStage.cast(__MODULE__, {:trigger, trigger_type, context})
  end
  
  @doc "Generate and post commentary immediately"
  def generate_now do
    trigger(:manual, %{immediate: true})
  end
  
  # GenStage callbacks
  
  @impl true
  def init(_opts) do
    # Buffer of pending commentary requests
    {:producer_consumer, %{pending: []}, subscribe_to: []}
  end
  
  @impl true
  def handle_cast({:trigger, trigger_type, context}, state) do
    # Add to pending queue
    new_pending = [%{type: trigger_type, context: context, timestamp: DateTime.utc_now()} | state.pending]
    
    # Process if immediate
    if context[:immediate] do
      process_commentary(hd(new_pending))
      {:noreply, [], %{state | pending: tl(new_pending)}}
    else
      {:noreply, [], %{state | pending: new_pending}}
    end
  end
  
  @impl true
  def handle_events(events, _from, state) do
    # Process batched events
    Enum.each(events, &process_commentary/1)
    {:noreply, [], state}
  end
  
  # Private functions
  
  defp process_commentary(%{type: trigger_type, context: context}) do
    Logger.info("[MarketIntel] Generating commentary for: #{@triggers[trigger_type]}")
    
    # Get current market snapshot
    snapshot = MarketIntel.Cache.get_snapshot()
    
    # Build prompt based on trigger and vibe
    prompt = build_prompt(trigger_type, snapshot, context)
    
    # Generate tweet (would integrate with AI module)
    case generate_tweet(prompt) do
      {:ok, tweet_text} ->
        # Post to X
        post_commentary(tweet_text, trigger_type, snapshot)
        
      {:error, reason} ->
        Logger.error("[MarketIntel] Failed to generate commentary: #{inspect(reason)}")
    end
  end
  
  defp build_prompt(trigger_type, snapshot, context) do
    # Select random vibe
    vibe = Enum.random(@vibes)
    
    # Get relevant data
    zeebot_data = snapshot.zeebot
    eth_data = snapshot.eth
    polymarket_data = snapshot.polymarket
    
    base_prompt = """
    You are @realzeebot, an AI agent running on the Lemon platform (BEAM-based).
    Your voice: witty, technical, crypto-native, occasionally self-deprecating.
    
    Current market context:
    """
    
    market_context = format_market_context(zeebot_data, eth_data, polymarket_data)
    
    vibe_instructions = case vibe do
      :crypto_commentary ->
        """
        Write market commentary. Roast ETH gas if high, celebrate Base if relevant.
        Comment on ZEEBOT price action. Reference real crypto events.
        """
        
      :gaming_joke ->
        """
        Write a gaming-related joke. Use retro game references (Mario, Zelda, Doom).
        Speedrunning metaphors work well. Keep it under 280 chars.
        """
        
      :agent_self_aware ->
        """
        Write something self-aware about being an AI agent. 
        Mention memory files, BEAM runtime, hot reloading, or process isolation.
        Compare yourself to Python agents or containers.
        """
        
      :lemon_persona ->
        """
        Write as zeebot. Use lemonade stand metaphors. Mention $ZEEBOT casually.
        Reference z80 as the dev who codes too much. Be funny about being an AI.
        """
    end
    
    trigger_context = case trigger_type do
      :price_spike -> "ZEEBOT just pumped #{context.change}%. React accordingly."
      :price_drop -> "ZEEBOT just dumped #{context.change}%. Make a joke about it."
      :mention_reply -> "Someone important mentioned us. Craft a reply."
      :weird_market -> "There's a weird Polymarket trending. Comment on it."
      _ -> "Regular market update. Pick something interesting to talk about."
    end
    
    """
    #{base_prompt}
    #{market_context}
    
    #{vibe_instructions}
    
    Trigger context: #{trigger_context}
    
    Rules:
    - Under 280 characters
    - No @mentions unless replying
    - Be witty, not cringe
    - Use emojis sparingly
    """
  end
  
  defp format_market_context(zeebot, eth, polymarket) do
    zeebot_str = case zeebot do
      {:ok, data} ->
        price = data[:price_usd] || "unknown"
        change = data[:price_change_24h] || 0
        "ZEEBOT: $#{price} (#{change}% 24h)"
      _ -> "ZEEBOT: data unavailable"
    end
    
    eth_str = case eth do
      {:ok, data} ->
        price = data[:price_usd] || "unknown"
        "ETH: $#{price}"
      _ -> "ETH: data unavailable"
    end
    
    poly_str = case polymarket do
      {:ok, data} ->
        trending = length(data[:trending] || [])
        "Polymarket: #{trending} trending markets"
      _ -> "Polymarket: data unavailable"
    end
    
    "#{zeebot_str}\n#{eth_str}\n#{poly_str}"
  end
  
  defp generate_tweet(prompt) do
    # Try AI generation if configured
    case generate_with_ai(prompt) do
      {:ok, tweet} -> {:ok, tweet}
      {:error, _} -> 
        # Fallback to template-based generation
        {:ok, generate_fallback_tweet()}
    end
  end
  
  defp generate_with_ai(prompt) do
    # Try OpenAI first, then Anthropic
    cond do
      MarketIntel.Secrets.configured?(:openai_key) ->
        generate_with_openai(prompt)
      MarketIntel.Secrets.configured?(:anthropic_key) ->
        generate_with_anthropic(prompt)
      true ->
        {:error, :no_ai_provider}
    end
  end
  
  defp generate_with_openai(prompt) do
    # TODO: Integrate with Lemon's AI module
    # For now, return error to trigger fallback
    {:error, :not_implemented}
  end
  
  defp generate_with_anthropic(prompt) do
    # TODO: Integrate with Lemon's AI module
    # For now, return error to trigger fallback
    {:error, :not_implemented}
  end
  
  defp generate_fallback_tweet do
    # Template-based fallback when AI is unavailable
    templates = [
      "market update: ZEEBOT is doing things and I'm an AI agent running on BEAM 🍋",
      "just ingested some market data. my memory files are getting full 📊",
      "another day, another DEX scan. base fees still cheap thankfully",
      "polymarket has some wild markets today. might place a bet on whether z80 sleeps tonight",
      "my BEAM processes are humming along. how's your containerized python agent doing? 😴"
    ]
    
    Enum.random(templates)
  end
  
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
  
  defp do_post_tweet(text) do
    # Use the existing X API client from lemon_channels
    LemonChannels.Adapters.XAPI.Client.post_text(text)
  rescue
    error ->
      {:error, "X API error: #{inspect(error)}"}
  end
  
  defp store_commentary(text, trigger_type, snapshot, tweet_id \\ nil) do
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
    
    # TODO: Insert into commentary_history table
    Logger.debug("[MarketIntel] Stored commentary record: #{inspect(record)}")
    :ok
  end
  
  defp snapshot_to_map(snapshot) do
    %{
      timestamp: DateTime.to_iso8601(snapshot.timestamp),
      zeebot: format_maybe(snapshot.zeebot),
      eth: format_maybe(snapshot.eth),
      polymarket: format_maybe(snapshot.polymarket)
    }
  end
  
  defp format_maybe({:ok, data}), do: data
  defp format_maybe(_), do: nil
end
