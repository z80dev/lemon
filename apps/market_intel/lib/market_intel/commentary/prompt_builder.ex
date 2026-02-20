defmodule MarketIntel.Commentary.PromptBuilder do
  @moduledoc """
  Builds prompts for market commentary generation.
  
  This module encapsulates prompt construction logic, making it easier to test
  and maintain. It handles formatting of market data, vibe instructions, and
  trigger-specific context.
  
  ## Usage
  
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{
          token: {:ok, %{price_usd: 1.23, price_change_24h: 5.5}},
          eth: {:ok, %{price_usd: 3500.0}},
          polymarket: {:ok, %{trending: ["event1", "event2"]}}
        },
        token_name: "Lemon Token",
        token_ticker: "$LEM",
        trigger_type: :scheduled,
        trigger_context: %{}
      }
      
      prompt = PromptBuilder.build(builder)
  """

  alias __MODULE__

  @typedoc "Market data structure for prompt building"
  @type market_data :: %{
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

  @typedoc "Vibe/theme for commentary style"
  @type vibe :: :crypto_commentary | :gaming_joke | :agent_self_aware | :lemon_persona

  @typedoc "Trigger type for commentary generation"
  @type trigger_type ::
          :scheduled
          | :price_spike
          | :price_drop
          | :mention_reply
          | :weird_market
          | :volume_surge
          | :manual

  defstruct [
    :vibe,
    :market_data,
    :token_name,
    :token_ticker,
    :trigger_type,
    :trigger_context
  ]

  @type t :: %__MODULE__{
          vibe: vibe(),
          market_data: market_data(),
          token_name: String.t(),
          token_ticker: String.t(),
          trigger_type: trigger_type(),
          trigger_context: trigger_context()
        }

  @doc """
  Builds a complete prompt string from the builder struct.
  
  Assembles all prompt components in order:
  1. Base prompt (persona and voice)
  2. Market context (formatted market data)
  3. Vibe instructions (style-specific content)
  4. Trigger context (event-specific instructions)
  5. Rules (output constraints)
  """
  @spec build(t()) :: String.t()
  def build(%PromptBuilder{} = builder) do
    base = build_base_prompt()
    market_context = build_market_context(builder)
    vibe_instructions = build_vibe_instructions(builder)
    trigger_context = build_trigger_context(builder)
    rules = build_rules()

    """
    #{base}
    #{market_context}

    #{vibe_instructions}

    Trigger context: #{trigger_context}

    #{rules}
    """
  end

  @doc """
  Builds the base prompt with persona and voice configuration.
  """
  @spec build_base_prompt() :: String.t()
  def build_base_prompt do
    persona_handle = MarketIntel.Config.commentary_handle()
    persona_voice = MarketIntel.Config.commentary_voice()

    """
    You are #{persona_handle}, an AI agent running on the Lemon platform (BEAM-based).
    Your voice: #{persona_voice}.

    Current market context:
    """
  end

  @doc """
  Builds the market context section from market data.
  
  Formats token, ETH, and Polymarket data into a readable string.
  Handles missing or expired data gracefully.
  """
  @spec build_market_context(t()) :: String.t()
  def build_market_context(%PromptBuilder{} = builder) do
    %{
      token: token_data,
      eth: eth_data,
      polymarket: polymarket_data
    } = builder.market_data

    token_str = format_asset_data(token_data, builder.token_name, &format_token/1)
    eth_str = format_asset_data(eth_data, "ETH", &format_eth/1)
    poly_str = format_asset_data(polymarket_data, "Polymarket", &format_polymarket/1)

    "#{token_str}\n#{eth_str}\n#{poly_str}"
  end

  @doc """
  Builds vibe-specific instructions based on the selected vibe.
  
  Each vibe provides different stylistic guidance for the AI:
  - `:crypto_commentary` - Market analysis with crypto-native language
  - `:gaming_joke` - Gaming-related humor with retro references
  - `:agent_self_aware` - Self-referential AI/agent content
  - `:lemon_persona` - Lemon platform-specific voice
  """
  @spec build_vibe_instructions(t()) :: String.t()
  def build_vibe_instructions(%PromptBuilder{vibe: vibe, token_ticker: token_ticker}) do
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
        developer_alias = MarketIntel.Config.commentary_developer_alias()
        lemon_instructions = MarketIntel.Config.commentary_lemon_persona_instructions()

        """
        #{lemon_instructions}
        #{developer_alias_instruction(developer_alias)}
        """
    end
  end

  @doc """
  Builds trigger-specific context based on the trigger type.
  
  Provides additional context about what event triggered the commentary,
  helping the AI craft an appropriate response.
  """
  @spec build_trigger_context(t()) :: String.t()
  def build_trigger_context(%PromptBuilder{trigger_type: trigger_type, trigger_context: context, token_ticker: token_ticker}) do
    case trigger_type do
      :price_spike -> 
        change = Map.get(context, :change, "unknown")
        "#{token_ticker} just pumped #{change}%. React accordingly."
      
      :price_drop -> 
        change = Map.get(context, :change, "unknown")
        "#{token_ticker} just dropped #{change}%. Make a joke about it."
      
      :mention_reply -> 
        "Someone important mentioned us. Craft a reply."
      
      :weird_market -> 
        "There's a weird Polymarket trending. Comment on it."
      
      _ -> 
        "Regular market update. Pick something interesting to talk about."
    end
  end

  @doc """
  Builds the rules section with output constraints.
  """
  @spec build_rules() :: String.t()
  def build_rules do
    """
    Rules:
    - Under 280 characters
    - No @mentions unless replying
    - Be witty, not cringe
    - Use emojis sparingly
    """
  end

  # Private helper functions

  @spec format_asset_data({:ok, map()} | any(), String.t(), (map() -> String.t())) :: String.t()
  defp format_asset_data({:ok, data}, _label, formatter) when is_map(data) do
    formatter.(data)
  end

  defp format_asset_data(_, label, _) do
    "#{label}: data unavailable"
  end

  @spec format_token(map()) :: String.t()
  defp format_token(data) do
    price = data[:price_usd] || "unknown"
    change = data[:price_change_24h] || 0
    "#{data[:name] || "Token"}: $#{format_price(price)} (#{change}% 24h)"
  end

  @spec format_eth(map()) :: String.t()
  defp format_eth(data) do
    price = data[:price_usd] || "unknown"
    "ETH: $#{format_price(price)}"
  end

  @spec format_polymarket(map()) :: String.t()
  defp format_polymarket(data) do
    trending = length(data[:trending] || [])
    "Polymarket: #{trending} trending markets"
  end

  @spec developer_alias_instruction(String.t() | nil) :: String.t()
  defp developer_alias_instruction(nil), do: ""
  defp developer_alias_instruction(""), do: ""

  defp developer_alias_instruction(alias_name) do
    "Reference #{alias_name} as the developer only when it feels natural."
  end

  @spec format_price(number() | String.t()) :: String.t()
  defp format_price(price) when is_float(price) do
    # Format float without scientific notation
    :erlang.float_to_binary(price, decimals: 2)
  end

  defp format_price(price) when is_integer(price) do
    Integer.to_string(price)
  end

  defp format_price(price), do: to_string(price)
end
