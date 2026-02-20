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
    {:ok, tweet_text} = generate_tweet(prompt)

    # Post to X
    post_commentary(tweet_text, trigger_type, snapshot)
  end

  defp build_prompt(trigger_type, snapshot, context) do
    # Select random vibe
    vibe = Enum.random(@vibes)

    # Get relevant data
    token_data = snapshot.token
    eth_data = snapshot.eth
    polymarket_data = snapshot.polymarket

    token_name = MarketIntel.Config.tracked_token_name()
    token_ticker = MarketIntel.Config.tracked_token_ticker()
    persona_handle = MarketIntel.Config.commentary_handle()
    persona_voice = MarketIntel.Config.commentary_voice()
    lemon_persona_instructions = MarketIntel.Config.commentary_lemon_persona_instructions()
    developer_alias = MarketIntel.Config.commentary_developer_alias()

    base_prompt = """
    You are #{persona_handle}, an AI agent running on the Lemon platform (BEAM-based).
    Your voice: #{persona_voice}.

    Current market context:
    """

    market_context = format_market_context(token_data, eth_data, polymarket_data, token_name)

    vibe_instructions =
      case vibe do
        :crypto_commentary ->
          """
          Write market commentary. Roast ETH gas if high, celebrate Base if relevant.
          Comment on #{token_ticker} price action. Reference real crypto events.
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
          #{lemon_persona_instructions}
          #{developer_alias_instruction(developer_alias)}
          """
      end

    trigger_context =
      case trigger_type do
        :price_spike -> "#{token_ticker} just pumped #{context.change}%. React accordingly."
        :price_drop -> "#{token_ticker} just dropped #{context.change}%. Make a joke about it."
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

  defp format_market_context(token, eth, polymarket, token_name) do
    token_str =
      case token do
        {:ok, data} ->
          price = data[:price_usd] || "unknown"
          change = data[:price_change_24h] || 0
          "#{token_name}: $#{price} (#{change}% 24h)"

        _ ->
          "#{token_name}: data unavailable"
      end

    eth_str =
      case eth do
        {:ok, data} ->
          price = data[:price_usd] || "unknown"
          "ETH: $#{price}"

        _ ->
          "ETH: data unavailable"
      end

    poly_str =
      case polymarket do
        {:ok, data} ->
          trending = length(data[:trending] || [])
          "Polymarket: #{trending} trending markets"

        _ ->
          "Polymarket: data unavailable"
      end

    "#{token_str}\n#{eth_str}\n#{poly_str}"
  end

  defp generate_tweet(prompt) do
    # Try AI generation if configured
    case generate_with_ai(prompt) do
      {:ok, tweet} when is_binary(tweet) and tweet != "" -> {:ok, tweet}
      {:error, _} -> {:ok, generate_fallback_tweet()}
      _ -> {:ok, generate_fallback_tweet()}
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
        {:ok, nil}
    end
  end

  defp generate_with_openai(_prompt) do
    # TODO: Integrate with Lemon's AI module
    # For now, return error to trigger fallback
    {:error, :not_implemented}
  end

  defp generate_with_anthropic(_prompt) do
    # TODO: Integrate with Lemon's AI module
    # For now, return error to trigger fallback
    {:error, :not_implemented}
  end

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

  defp maybe_append_developer_template(templates, nil), do: templates
  defp maybe_append_developer_template(templates, ""), do: templates

  defp maybe_append_developer_template(templates, developer_alias) do
    templates ++
      [
        "runtime status: green. #{developer_alias} gave me another market loop and i survived 🍋"
      ]
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

    # TODO: Insert into commentary_history table
    Logger.debug("[MarketIntel] Stored commentary record: #{inspect(record)}")
    :ok
  end

  defp snapshot_to_map(snapshot) do
    %{
      timestamp: DateTime.to_iso8601(snapshot.timestamp),
      token: format_maybe(snapshot.token),
      eth: format_maybe(snapshot.eth),
      polymarket: format_maybe(snapshot.polymarket)
    }
  end

  defp developer_alias_instruction(nil), do: ""
  defp developer_alias_instruction(""), do: ""

  defp developer_alias_instruction(alias_name) do
    "Reference #{alias_name} as the developer only when it feels natural."
  end

  defp format_maybe({:ok, data}), do: data
  defp format_maybe(_), do: nil
end
