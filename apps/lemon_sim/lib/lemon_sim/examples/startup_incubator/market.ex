defmodule LemonSim.Examples.StartupIncubator.Market do
  @moduledoc """
  Sector configurations, valuation logic, and random market events for the
  Startup Incubator simulation.

  Each round a market event fires that adjusts sector multipliers — some sectors
  boom while others bust.  Startup valuations are recomputed from traction,
  employees, and the current sector multiplier after each operations phase.
  """

  @sectors ~w(ai fintech healthtech edtech climatetech ecommerce)

  @base_multipliers %{
    "ai" => 12.0,
    "fintech" => 8.0,
    "healthtech" => 9.0,
    "edtech" => 6.0,
    "climatetech" => 7.0,
    "ecommerce" => 5.0
  }

  @market_events [
    %{
      name: "AI Hype Wave",
      description: "Generative AI captures headlines; valuations skyrocket.",
      changes: %{
        "ai" => 1.5,
        "fintech" => 1.0,
        "healthtech" => 1.1,
        "edtech" => 0.9,
        "climatetech" => 1.0,
        "ecommerce" => 0.9
      }
    },
    %{
      name: "Fintech Regulatory Crackdown",
      description: "Regulators tighten rules; fintech multiples compress.",
      changes: %{
        "ai" => 1.1,
        "fintech" => 0.6,
        "healthtech" => 1.0,
        "edtech" => 1.0,
        "climatetech" => 1.0,
        "ecommerce" => 1.0
      }
    },
    %{
      name: "Healthcare Boom",
      description: "Post-pandemic health spending drives healthtech investment.",
      changes: %{
        "ai" => 1.0,
        "fintech" => 1.0,
        "healthtech" => 1.5,
        "edtech" => 1.0,
        "climatetech" => 1.1,
        "ecommerce" => 0.9
      }
    },
    %{
      name: "Education Stimulus",
      description: "Government grants pour into edtech platforms.",
      changes: %{
        "ai" => 1.0,
        "fintech" => 1.0,
        "healthtech" => 1.0,
        "edtech" => 1.4,
        "climatetech" => 1.0,
        "ecommerce" => 0.9
      }
    },
    %{
      name: "Green Energy Mandate",
      description: "Carbon legislation makes climatetech the darling of LPs.",
      changes: %{
        "ai" => 1.0,
        "fintech" => 0.9,
        "healthtech" => 1.0,
        "edtech" => 1.0,
        "climatetech" => 1.6,
        "ecommerce" => 0.9
      }
    },
    %{
      name: "E-Commerce Renaissance",
      description: "Consumer spending shifts online; e-commerce multiples rise.",
      changes: %{
        "ai" => 1.0,
        "fintech" => 1.0,
        "healthtech" => 0.9,
        "edtech" => 0.9,
        "climatetech" => 1.0,
        "ecommerce" => 1.5
      }
    },
    %{
      name: "Interest Rate Hike",
      description: "Central banks raise rates; growth stocks hammered across the board.",
      changes: %{
        "ai" => 0.7,
        "fintech" => 0.7,
        "healthtech" => 0.8,
        "edtech" => 0.8,
        "climatetech" => 0.8,
        "ecommerce" => 0.7
      }
    },
    %{
      name: "Bull Market Euphoria",
      description: "Risk-on sentiment; investors write cheques to everyone.",
      changes: %{
        "ai" => 1.3,
        "fintech" => 1.2,
        "healthtech" => 1.2,
        "edtech" => 1.2,
        "climatetech" => 1.2,
        "ecommerce" => 1.2
      }
    },
    %{
      name: "Crypto Winter Spillover",
      description: "Fintech and AI take heat from the crypto collapse.",
      changes: %{
        "ai" => 0.8,
        "fintech" => 0.65,
        "healthtech" => 1.1,
        "edtech" => 1.0,
        "climatetech" => 1.0,
        "ecommerce" => 1.0
      }
    },
    %{
      name: "Quiet Market",
      description: "Nothing dramatic — slow quarter with modest movements.",
      changes: %{
        "ai" => 1.0,
        "fintech" => 1.0,
        "healthtech" => 1.0,
        "edtech" => 1.0,
        "climatetech" => 1.0,
        "ecommerce" => 1.0
      }
    }
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Returns the list of valid sector names."
  @spec sectors() :: [String.t()]
  def sectors, do: @sectors

  @doc "Returns the base revenue multiplier for a sector."
  @spec base_multiplier(String.t()) :: float()
  def base_multiplier(sector), do: Map.get(@base_multipliers, sector, 6.0)

  @doc "Returns the initial market conditions map (sector => multiplier)."
  @spec initial_conditions() :: map()
  def initial_conditions do
    Map.new(@sectors, fn sector -> {sector, Map.get(@base_multipliers, sector, 6.0)} end)
  end

  @doc "Randomly draws and applies a market event; returns {updated_conditions, event_map}."
  @spec apply_random_event(map()) :: {map(), map()}
  def apply_random_event(current_conditions) do
    event = Enum.random(@market_events)
    updated = apply_event_changes(current_conditions, event.changes)
    {updated, event}
  end

  @doc """
  Computes a startup's valuation from its metrics and current market conditions.

  Valuation = (traction * sector_multiplier * 1_000) + (employees * 50_000)
  The sector_multiplier is the current market conditions value for the startup's sector.
  """
  @spec compute_valuation(map(), map()) :: non_neg_integer()
  def compute_valuation(startup, market_conditions) do
    sector = Map.get(startup, :sector, Map.get(startup, "sector", "ecommerce"))
    traction = Map.get(startup, :traction, Map.get(startup, "traction", 1))
    employees = Map.get(startup, :employees, Map.get(startup, "employees", 1))

    multiplier = Map.get(market_conditions, sector, 6.0)
    round(traction * multiplier * 1_000 + employees * 50_000)
  end

  @doc "Assigns a random sector to a player."
  @spec random_sector() :: String.t()
  def random_sector, do: Enum.random(@sectors)

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp apply_event_changes(conditions, changes) do
    Enum.reduce(changes, conditions, fn {sector, factor}, acc ->
      current = Map.get(acc, sector, 6.0)
      # Apply factor but clamp to a reasonable range
      updated = Float.round(current * factor, 2)
      clamped = max(1.0, min(30.0, updated))
      Map.put(acc, sector, clamped)
    end)
  end
end
