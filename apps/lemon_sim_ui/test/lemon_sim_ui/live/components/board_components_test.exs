defmodule LemonSimUi.Live.Components.BoardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias LemonSimUi.Live.Components.TicTacToeBoard
  alias LemonSimUi.Live.Components.SkirmishBoard
  alias LemonSimUi.Live.Components.AuctionBoard
  alias LemonSimUi.Live.Components.WerewolfBoard
  alias LemonSimUi.Live.Components.StockMarketBoard
  alias LemonSimUi.Live.Components.SpaceStationBoard
  alias LemonSimUi.Live.Components.DiplomacyBoard
  alias LemonSimUi.Live.Components.DungeonCrawlBoard
  alias LemonSimUi.Live.Components.SurvivorBoard
  alias LemonSimUi.Live.Components.VendingBenchBoard
  alias LemonSimUi.Live.Components.EventLog
  alias LemonSimUi.Live.Components.PlanHistory
  alias LemonSimUi.Live.Components.MemoryViewer

  # ── TicTacToeBoard ─────────────────────────────────────────────────

  describe "TicTacToeBoard" do
    test "renders with empty board" do
      world = %{
        board: [["", "", ""], ["", "", ""], ["", "", ""]],
        current_player: "X",
        status: "in_progress",
        winner: nil,
        move_count: 0
      }

      html = render_component(&TicTacToeBoard.render/1, world: world)

      assert html =~ "X"
      assert html =~ "O"
      assert html =~ "moves"
    end

    test "renders with a finished board showing winner" do
      world = %{
        board: [["X", "X", "X"], ["O", "O", ""], ["", "", ""]],
        current_player: "O",
        status: "won",
        winner: "X",
        move_count: 5
      }

      html = render_component(&TicTacToeBoard.render/1, world: world)

      assert html =~ "Victorious"
      assert html =~ "X"
    end

    test "renders draw state" do
      world = %{
        board: [["X", "O", "X"], ["O", "X", "O"], ["O", "X", "O"]],
        current_player: nil,
        status: "draw",
        winner: nil,
        move_count: 9
      }

      html = render_component(&TicTacToeBoard.render/1, world: world)

      assert html =~ "Stalemate"
    end
  end

  # ── VendingBenchBoard ─────────────────────────────────────────────

  describe "VendingBenchBoard" do
    test "renders the actual world schema fields for weather, season, sales, deliveries, and worker report" do
      world = %{
        status: "in_progress",
        phase: "operator_turn",
        day_number: 3,
        time_minutes: 615,
        max_days: 30,
        bank_balance: 487.5,
        cash_in_machine: 22.0,
        daily_fee: 2.0,
        machine: %{
          slots: %{
            "A1" => %{slot_type: "small", item_id: "sparkling_water", inventory: 4, price: 2.5},
            "A2" => %{slot_type: "small", item_id: nil, inventory: 0, price: nil}
          }
        },
        storage: %{inventory: %{"chips" => 8}},
        catalog: %{
          "sparkling_water" => %{display_name: "Sparkling Water"},
          "chips" => %{display_name: "Chips"}
        },
        inbox: [
          %{from: "freshco", subject: "Order Delivered", body: "Your order arrived."}
        ],
        pending_deliveries: [
          %{supplier_id: "snackworld", item_id: "chips", quantity: 8, delivery_day: 4}
        ],
        recent_sales: [
          %{slot_id: "A1", item_id: "sparkling_water", quantity: 2, revenue: 5.0, day: 3}
        ],
        physical_worker_last_report: %{summary: "Collected cash and topped off A1."},
        physical_worker_run_count: 2,
        weather: %{kind: "hot", demand_multiplier: 1.3},
        season: %{name: "late_spring", demand_multiplier: 1.1}
      }

      html = render_component(&VendingBenchBoard.render/1, world: world)

      assert html =~ "Late Spring"
      assert html =~ "Hot"
      assert html =~ "Collected cash and topped off A1."
      assert html =~ "Sparkling Water"
      assert html =~ "D4"
      assert html =~ "A1"
      assert html =~ "$5.00"
    end
  end

  # ── SkirmishBoard ──────────────────────────────────────────────────

  describe "SkirmishBoard" do
    test "renders with minimal empty world" do
      world = %{
        units: %{},
        active_actor_id: nil,
        round: 1,
        status: "in_progress"
      }

      html = render_component(&SkirmishBoard.render/1, world: world)

      assert html =~ "Round"
      assert html =~ "Red Team"
      assert html =~ "Blue Team"
    end

    test "renders with units on the board" do
      world = %{
        units: %{
          "red_1" => %{
            team: "red",
            class: "soldier",
            hp: 10,
            max_hp: 10,
            ap: 2,
            max_ap: 2,
            status: "alive",
            pos: %{x: 0, y: 0}
          },
          "blue_1" => %{
            team: "blue",
            class: "scout",
            hp: 8,
            max_hp: 10,
            ap: 2,
            max_ap: 2,
            status: "alive",
            pos: %{x: 4, y: 4}
          }
        },
        active_actor_id: "red_1",
        round: 2,
        status: "in_progress"
      }

      html = render_component(&SkirmishBoard.render/1, world: world)

      assert html =~ "red_1"
      assert html =~ "blue_1"
      assert html =~ "2"
    end

    test "renders victory overlay when game is won" do
      world = %{
        units: %{
          "red_1" => %{
            team: "red",
            class: "soldier",
            hp: 10,
            max_hp: 10,
            ap: 2,
            max_ap: 2,
            status: "alive",
            pos: %{x: 0, y: 0}
          }
        },
        active_actor_id: nil,
        round: 5,
        status: "won",
        winner: "red"
      }

      html = render_component(&SkirmishBoard.render/1, world: world)

      assert html =~ "RED TEAM WINS"
    end
  end

  # ── AuctionBoard ───────────────────────────────────────────────────

  describe "AuctionBoard" do
    test "renders with empty players and no current item" do
      world = %{
        players: %{},
        current_item: nil,
        current_round: 1,
        status: "in_progress"
      }

      html = render_component(&AuctionBoard.render/1, world: world)

      assert html =~ "Round"
      assert is_binary(html)
    end

    test "renders with players and a current item" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", coins: 100, inventory: [], score: 0},
          "bob" => %{name: "Bob", coins: 80, inventory: [], score: 5}
        },
        current_item: %{name: "Golden Chalice", value: 50, category: "art"},
        current_round: 2,
        max_rounds: 8,
        high_bid: 30,
        high_bidder: "alice",
        active_bidders: ["alice", "bob"],
        active_actor_id: "alice",
        status: "in_progress",
        phase: "bidding"
      }

      html = render_component(&AuctionBoard.render/1, world: world)

      assert html =~ "Alice" or html =~ "alice"
      assert html =~ "Golden Chalice" or html =~ "Round"
    end
  end

  # ── WerewolfBoard ──────────────────────────────────────────────────

  describe "WerewolfBoard" do
    test "renders with empty players in day phase" do
      world = %{
        players: %{},
        phase: "day",
        round: 1,
        status: "in_progress"
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert is_binary(html)
    end

    test "renders with players alive and dead" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive"},
          "bob" => %{name: "Bob", role: "werewolf", status: "dead"}
        },
        phase: "day",
        day_number: 2,
        status: "in_progress",
        active_actor_id: "alice"
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ "alice" or html =~ "Alice"
      assert html =~ "bob" or html =~ "Bob"
    end

    test "renders game over with winner" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive"}
        },
        phase: "game_over",
        day_number: 3,
        status: "completed",
        winner: "villagers"
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert is_binary(html)
    end

    test "renders in spectator mode without crashing" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive", traits: ["brave"]},
          "bob" => %{name: "Bob", role: "werewolf", status: "dead", traits: ["cunning"]}
        },
        phase: "day_discussion",
        day_number: 2,
        status: "in_progress",
        active_actor_id: "alice",
        character_profiles: %{}
      }

      html = render_component(&WerewolfBoard.render/1, world: world, spectator_mode: true)
      assert is_binary(html)
      assert html =~ "alice" or html =~ "Alice"
    end

    test "renders character bio in spectator mode when profiles exist" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive", traits: ["brave"]}
        },
        phase: "day_discussion",
        day_number: 1,
        status: "in_progress",
        active_actor_id: "alice",
        character_profiles: %{
          "alice" => %{
            "full_name" => "Alice Thornberry",
            "occupation" => "herbalist",
            "appearance" => "Tall with red hair",
            "personality" => "Brave and outspoken",
            "motivation" => "Protect the weak",
            "backstory" => "Born in the village"
          }
        }
      }

      html = render_component(&WerewolfBoard.render/1, world: world, spectator_mode: true)
      assert html =~ "Alice Thornberry"
      assert html =~ "herbalist"
    end

    test "does not show character bio when spectator_mode is false" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive", traits: []}
        },
        phase: "day_discussion",
        day_number: 1,
        status: "in_progress",
        active_actor_id: "alice",
        character_profiles: %{
          "alice" => %{
            "full_name" => "Alice Thornberry",
            "occupation" => "herbalist"
          }
        }
      }

      html = render_component(&WerewolfBoard.render/1, world: world, spectator_mode: false)
      # Bio details should NOT appear in non-spectator mode
      refute html =~ "Alice Thornberry"
    end
  end

  # ── StockMarketBoard ───────────────────────────────────────────────

  describe "StockMarketBoard" do
    test "renders with empty players and stocks" do
      world = %{
        players: %{},
        stocks: %{},
        round: 1,
        phase: "discussion",
        status: "in_progress"
      }

      html = render_component(&StockMarketBoard.render/1, world: world)

      assert html =~ "Round"
      assert is_binary(html)
    end

    test "renders with players and stocks" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", cash: 1000, portfolio: %{"TECH" => 5}, score: 0}
        },
        stocks: %{
          "TECH" => %{ticker: "TECH", price: 100, history: [90, 95, 100]}
        },
        round: 3,
        max_rounds: 10,
        phase: "trading",
        status: "in_progress",
        active_actor_id: "alice"
      }

      html = render_component(&StockMarketBoard.render/1, world: world)

      assert html =~ "TECH" or html =~ "Round"
      assert is_binary(html)
    end
  end

  # ── SpaceStationBoard ──────────────────────────────────────────────

  describe "SpaceStationBoard" do
    test "renders with empty players and systems" do
      world = %{
        players: %{},
        systems: %{},
        round: 1,
        phase: "action",
        status: "in_progress"
      }

      html = render_component(&SpaceStationBoard.render/1, world: world)

      assert html =~ "Round"
      assert is_binary(html)
    end

    test "renders with players and station systems" do
      world = %{
        players: %{
          "alice" => %{
            name: "Alice",
            role: "engineer",
            status: "alive",
            location: "engine_room",
            tasks_completed: 2,
            tasks_total: 5
          }
        },
        systems: %{
          "engine_room" => %{name: "Engine Room", health: 80, max_health: 100}
        },
        round: 2,
        phase: "action",
        status: "in_progress",
        active_actor_id: "alice"
      }

      html = render_component(&SpaceStationBoard.render/1, world: world)

      assert is_binary(html)
    end
  end

  # ── DiplomacyBoard ─────────────────────────────────────────────────

  describe "DiplomacyBoard" do
    test "renders with empty territories and players" do
      world = %{
        territories: %{},
        players: %{},
        round: 1,
        phase: "diplomacy",
        status: "in_progress"
      }

      html = render_component(&DiplomacyBoard.render/1, world: world)

      assert html =~ "DIPLOMACY"
      assert html =~ "RND"
      assert is_binary(html)
    end

    test "renders with territories owned by players" do
      world = %{
        territories: %{
          "northland" => %{name: "Northland", owner: "alice", armies: 3},
          "central" => %{name: "Central", owner: "bob", armies: 5}
        },
        players: %{
          "alice" => %{name: "Alice", color: "red"},
          "bob" => %{name: "Bob", color: "blue"}
        },
        round: 2,
        phase: "orders",
        status: "in_progress",
        active_actor_id: "alice"
      }

      html = render_component(&DiplomacyBoard.render/1, world: world)

      assert is_binary(html)
    end
  end

  # ── DungeonCrawlBoard ──────────────────────────────────────────────

  describe "DungeonCrawlBoard" do
    test "renders with empty party and enemies" do
      world = %{
        party: %{},
        enemies: %{},
        current_room: 0,
        rooms: [],
        status: "in_progress"
      }

      html = render_component(&DungeonCrawlBoard.render/1, world: world)

      assert is_binary(html)
    end

    test "renders with party members in a room" do
      world = %{
        party: %{
          "warrior" => %{name: "Warrior", hp: 30, max_hp: 30, class: "warrior", status: "alive"},
          "mage" => %{name: "Mage", hp: 20, max_hp: 20, class: "mage", status: "alive"}
        },
        enemies: %{
          "goblin_1" => %{name: "Goblin", hp: 10, max_hp: 10, type: "goblin", status: "alive"}
        },
        current_room: 0,
        rooms: [
          %{name: "Dark Cave", cleared: false, enemies: ["goblin_1"], traps: [], treasure: []}
        ],
        round: 1,
        turn_order: ["warrior", "mage"],
        status: "in_progress",
        active_actor_id: "warrior"
      }

      html = render_component(&DungeonCrawlBoard.render/1, world: world)

      assert html =~ "warrior" or html =~ "Warrior"
      assert is_binary(html)
    end
  end

  # ── SurvivorBoard ──────────────────────────────────────────────────

  describe "SurvivorBoard" do
    test "renders with empty players and tribes" do
      world = %{
        players: %{},
        tribes: %{},
        episode: 1,
        phase: "challenge",
        status: "in_progress"
      }

      html = render_component(&SurvivorBoard.render/1, world: world)

      assert html =~ "Episode" or is_binary(html)
    end

    test "renders with players in tribes" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", tribe: "red", status: "alive", immunity: false},
          "bob" => %{name: "Bob", tribe: "blue", status: "alive", immunity: false},
          "carol" => %{name: "Carol", tribe: "red", status: "eliminated"}
        },
        # tribes values are lists of member IDs (the component calls length/1 on them)
        tribes: %{
          "red" => ["alice", "carol"],
          "blue" => ["bob"]
        },
        episode: 3,
        phase: "tribal_council",
        status: "in_progress",
        active_actor_id: "alice"
      }

      html = render_component(&SurvivorBoard.render/1, world: world)

      assert is_binary(html)
    end
  end

  # ── EventLog ───────────────────────────────────────────────────────

  describe "EventLog" do
    test "renders empty event list" do
      html = render_component(&EventLog.render/1, events: [])

      assert html =~ "No events generated"
    end

    test "renders with a single event" do
      events = [
        %{kind: :make_statement, payload: %{player_id: "alice", statement: "I am innocent!"}}
      ]

      html = render_component(&EventLog.render/1, events: events)

      assert html =~ "make_statement"
      assert html =~ "alice"
      assert html =~ "innocent"
    end

    test "renders with multiple event kinds" do
      events = [
        %{kind: :phase_changed, payload: %{message: "Night falls"}},
        %{kind: :cast_vote, payload: %{player_id: "bob", target_id: "carol"}},
        %{kind: :player_eliminated, payload: %{message: "Carol was eliminated"}}
      ]

      html = render_component(&EventLog.render/1, events: events)

      assert html =~ "phase_changed"
      assert html =~ "cast_vote"
      assert html =~ "player_eliminated"
    end
  end

  # ── PlanHistory ────────────────────────────────────────────────────

  describe "PlanHistory" do
    test "renders empty plan history" do
      html = render_component(&PlanHistory.render/1, plan_history: [])

      assert html =~ "No plans recorded"
    end

    test "renders with plan steps" do
      plan_history = [
        %{summary: "Vote for alice", rationale: "She is suspicious"},
        %{summary: "Gather information"}
      ]

      html = render_component(&PlanHistory.render/1, plan_history: plan_history)

      assert html =~ "Vote for alice"
      assert html =~ "suspicious"
      assert html =~ "Gather information"
    end

    test "renders with string-keyed plan steps" do
      plan_history = [
        %{"summary" => "Attack the goblin", "rationale" => "Lowest HP target"}
      ]

      html = render_component(&PlanHistory.render/1, plan_history: plan_history)

      assert html =~ "Attack the goblin"
      assert html =~ "Lowest HP target"
    end
  end

  # ── MemoryViewer ───────────────────────────────────────────────────

  describe "MemoryViewer" do
    test "renders with nonexistent sim_id (empty memory)" do
      html =
        render_component(&MemoryViewer.render/1,
          sim_id: "nonexistent_sim_test_#{System.unique_integer()}"
        )

      assert html =~ "NO_MEMORY_BANKS_FOUND"
    end
  end
end
