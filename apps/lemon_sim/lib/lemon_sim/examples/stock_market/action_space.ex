defmodule LemonSim.Examples.StockMarket.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.ActionSpace

  import LemonSim.GameHelpers

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonSim.GameHelpers.Tools, as: GameTools
  alias LemonSim.Examples.StockMarket.{Events, Market}

  @impl true
  def tools(state, _opts) do
    world = state.world
    status = get(world, :status, "in_progress")

    if status != "in_progress" do
      {:ok, []}
    else
      phase = get(world, :phase, "news")
      actor_id = get(world, :active_actor_id)
      players = get(world, :players, %{})
      actor = Map.get(players, actor_id)

      if is_nil(actor) do
        {:ok, []}
      else
        {:ok, tools_for_phase(phase, actor_id, players, world)}
      end
    end
  end

  defp tools_for_phase("discussion", actor_id, players, world) do
    other_ids =
      players
      |> Map.keys()
      |> Enum.reject(&(&1 == actor_id))
      |> Enum.sort()

    target_labels =
      Enum.map(other_ids, fn id ->
        "#{id} (#{player_name(players, id)})"
      end)
      |> Enum.join(", ")

    case get(world, :discussion_round, 1) do
      1 ->
        [
          broadcast_market_call_tool(actor_id),
          GameTools.statement_tool(actor_id,
            description:
              "Make a public statement on the trading floor. All players will see what you say. " <>
                "Use trader names in public, not raw ids. You can share tips, challenge a thesis, " <>
                "or frame the market narrative before trading opens."
          )
        ]

      _ ->
        [
          GameTools.whisper_tool(actor_id, other_ids,
            description:
              "Send a private message to another trader. Only the recipient will see the contents, " <>
                "but ALL players will know you whispered. Valid recipients: #{target_labels}. " <>
                "Use ids for tool args and names in the message itself."
          ),
          skip_whisper_tool(actor_id)
        ]
    end
  end

  defp tools_for_phase("trading", actor_id, players, world) do
    stocks = get(world, :stocks, %{})
    actor = Map.get(players, actor_id, %{})
    [place_trade_tool(actor_id, actor, stocks)]
  end

  defp tools_for_phase(_phase, _actor_id, _players, _world) do
    # news and resolution phases are automatic, no tools
    []
  end

  # -- Game-specific tool builders --

  defp broadcast_market_call_tool(actor_id) do
    stock_names = Market.stock_names()

    %AgentTool{
      name: "broadcast_market_call",
      description:
        "Broadcast a clear public market call before trading starts. " <>
          "Pick a stock, take a bullish or bearish stance, give a confidence score 1-5, " <>
          "and explain your thesis in 1-2 sentences. These calls influence the market, and accurate calls improve your reputation.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "stock" => %{
            "type" => "string",
            "description" => "Stock ticker for the public call.",
            "enum" => stock_names
          },
          "stance" => %{
            "type" => "string",
            "description" => "Direction of your call.",
            "enum" => ["bullish", "bearish"]
          },
          "confidence" => %{
            "type" => "integer",
            "description" => "How strongly you want to lean into the call.",
            "minimum" => 1,
            "maximum" => 5
          },
          "thesis" => %{
            "type" => "string",
            "description" => "Your concise explanation for the call."
          }
        },
        "required" => ["stock", "stance", "confidence", "thesis"],
        "additionalProperties" => false
      },
      label: "Broadcast Call",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        stock = Map.get(params, "stock", Map.get(params, :stock, "NOVA"))
        stance = Map.get(params, "stance", Map.get(params, :stance, "bullish"))
        confidence = Map.get(params, "confidence", Map.get(params, :confidence, 3))
        thesis = Map.get(params, "thesis", Map.get(params, :thesis, ""))

        event = Events.broadcast_market_call(actor_id, stock, stance, confidence, thesis)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You broadcast a #{stance} call on #{stock}.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp skip_whisper_tool(actor_id) do
    %AgentTool{
      name: "skip_whisper",
      description:
        "Pass on private outreach this round. Use this if you want your public call to stand on its own.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "additionalProperties" => false
      },
      label: "Skip Whisper",
      execute: fn _tool_call_id, _params, _signal, _on_update ->
        event = Events.skip_whisper(actor_id)

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content("You skipped whispering this round.")],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp place_trade_tool(actor_id, actor, stocks) do
    cash = get(actor, :cash, 0)
    portfolio = get(actor, :portfolio, %{})
    short_book = get(actor, :short_book, %{})
    stock_names = Market.stock_names()

    stock_info =
      Enum.map(stock_names, fn ticker ->
        price = Market.get_stock_price(stocks, ticker)
        long_shares = Map.get(portfolio, ticker, 0)
        short_shares = Map.get(short_book, ticker, 0)
        "#{ticker}: $#{price} (long #{long_shares}, short #{short_shares})"
      end)
      |> Enum.join(", ")

    max_shares_info =
      Enum.map(stock_names, fn ticker ->
        price = Market.get_stock_price(stocks, ticker)
        max_buy = if price > 0, do: floor(cash / price), else: 0
        long_shares = Map.get(portfolio, ticker, 0)
        short_shares = Map.get(short_book, ticker, 0)
        max_short = Market.max_short_capacity(actor, stocks, ticker)

        "#{ticker}: buy #{max_buy}, sell #{long_shares}, short to #{max_short} total, cover #{short_shares}"
      end)
      |> Enum.join("; ")

    %AgentTool{
      name: "place_trade",
      description:
        "Place a trade order. You have $#{Float.round(cash * 1.0, 2)} cash. " <>
          "Current prices & holdings: #{stock_info}. " <>
          "Limits: #{max_shares_info}. " <>
          "Choose to buy, sell, short, cover, or hold.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "description" => "Trade action: buy, sell, short, cover, or hold",
            "enum" => ["buy", "sell", "short", "cover", "hold"]
          },
          "stock" => %{
            "type" => "string",
            "description" => "Which stock to trade. Required for buy/sell, ignored for hold.",
            "enum" => stock_names
          },
          "quantity" => %{
            "type" => "integer",
            "description" =>
              "Number of shares to buy or sell. Must be > 0 for buy/sell. Ignored for hold.",
            "minimum" => 0
          }
        },
        "required" => ["action"],
        "additionalProperties" => false
      },
      label: "Place Trade",
      execute: fn _tool_call_id, params, _signal, _on_update ->
        action = Map.get(params, "action", Map.get(params, :action, "hold"))
        stock = Map.get(params, "stock", Map.get(params, :stock))
        quantity = Map.get(params, "quantity", Map.get(params, :quantity, 0))

        # Ensure quantity is an integer
        quantity =
          cond do
            is_integer(quantity) -> quantity
            is_float(quantity) -> trunc(quantity)
            is_binary(quantity) -> String.to_integer(quantity)
            true -> 0
          end

        event = Events.place_trade(actor_id, action, stock || "", quantity)

        message =
          case action do
            "hold" -> "You chose to hold - no trade this round."
            "buy" -> "You placed an order to buy #{quantity} shares of #{stock}."
            "sell" -> "You placed an order to sell #{quantity} shares of #{stock}."
            "short" -> "You placed an order to short #{quantity} shares of #{stock}."
            "cover" -> "You placed an order to cover #{quantity} shares of #{stock}."
            _ -> "Trade placed."
          end

        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content(message)],
           details: %{"event" => event},
           trust: :trusted
         }}
      end
    }
  end

  defp player_name(players, player_id) do
    players
    |> Map.get(player_id, %{})
    |> get(:name, player_id)
  end
end
