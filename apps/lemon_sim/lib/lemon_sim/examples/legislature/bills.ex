defmodule LemonSim.Examples.Legislature.Bills do
  @moduledoc """
  Bill definitions, generation, and scoring for the Legislature simulation.
  """

  @bills [
    %{
      id: "infrastructure",
      title: "National Infrastructure Act",
      description:
        "A sweeping plan to rebuild roads, bridges, and public transit systems across the nation.",
      topic: "infrastructure"
    },
    %{
      id: "healthcare",
      title: "Universal Healthcare Reform Act",
      description:
        "Expands public health coverage and introduces price controls on essential medications.",
      topic: "healthcare"
    },
    %{
      id: "defense",
      title: "National Defense Appropriations Act",
      description:
        "Increases military spending, funds new weapons programs, and expands veteran benefits.",
      topic: "defense"
    },
    %{
      id: "education",
      title: "Education Investment and Opportunity Act",
      description:
        "Increases federal funding for public schools, expands student loan forgiveness, and funds research grants.",
      topic: "education"
    },
    %{
      id: "environment",
      title: "Clean Energy Transition Act",
      description:
        "Mandates a shift to renewable energy sources, funds green technology, and imposes carbon pricing.",
      topic: "environment"
    }
  ]

  @factions [
    %{
      id: "rural",
      name: "Rural Caucus",
      description: "Represents farming communities and small towns",
      preferred_topics: ["infrastructure", "defense"],
      opposed_topics: ["environment"]
    },
    %{
      id: "progressive",
      name: "Progressive Coalition",
      description: "Advocates for social reform and environmental justice",
      preferred_topics: ["healthcare", "environment", "education"],
      opposed_topics: ["defense"]
    },
    %{
      id: "conservative",
      name: "Conservative Alliance",
      description: "Focuses on fiscal discipline and traditional values",
      preferred_topics: ["defense", "infrastructure"],
      opposed_topics: ["healthcare", "environment"]
    },
    %{
      id: "centrist",
      name: "Moderate Democrats",
      description: "Seeks pragmatic compromise across party lines",
      preferred_topics: ["healthcare", "education"],
      opposed_topics: []
    },
    %{
      id: "libertarian",
      name: "Liberty Caucus",
      description: "Prioritizes individual freedom and limited government",
      preferred_topics: ["infrastructure"],
      opposed_topics: ["healthcare", "environment", "education"]
    },
    %{
      id: "labor",
      name: "Labor Federation",
      description: "Represents workers, unions, and manufacturing interests",
      preferred_topics: ["infrastructure", "healthcare", "education"],
      opposed_topics: []
    },
    %{
      id: "tech",
      name: "Innovation Alliance",
      description: "Champions technology investment and digital economy",
      preferred_topics: ["education", "environment"],
      opposed_topics: ["defense"]
    }
  ]

  @doc """
  Returns the list of all available bills as a map keyed by bill id.
  """
  @spec all_bills() :: map()
  def all_bills do
    Enum.into(@bills, %{}, fn bill ->
      {bill.id,
       %{
         id: bill.id,
         title: bill.title,
         description: bill.description,
         topic: bill.topic,
         amendments: [],
         lobby_support: %{},
         status: "pending"
       }}
    end)
  end

  @doc """
  Returns list of all bill ids.
  """
  @spec bill_ids() :: [String.t()]
  def bill_ids do
    Enum.map(@bills, & &1.id)
  end

  @doc """
  Returns factions for the given number of players.
  """
  @spec factions_for(pos_integer()) :: [map()]
  def factions_for(player_count) do
    Enum.take(@factions, player_count)
  end

  @doc """
  Generates a preference ranking for a faction.
  Bills that match the faction's preferred topics rank higher.
  """
  @spec preference_ranking(String.t()) :: [String.t()]
  def preference_ranking(faction_id) do
    faction = Enum.find(@factions, &(&1.id == faction_id))

    if faction do
      @bills
      |> Enum.sort_by(fn bill ->
        cond do
          bill.topic in faction.preferred_topics -> 0
          bill.topic in faction.opposed_topics -> 2
          true -> 1
        end
      end)
      |> Enum.map(& &1.id)
    else
      Enum.map(@bills, & &1.id)
    end
  end

  @doc """
  Calculates the score delta for a player given which bills passed.
  Returns a map of player_id => points_earned.
  """
  @spec score_passed_bills(map(), [String.t()]) :: map()
  def score_passed_bills(players, passed_bill_ids) do
    rank_scores = [10, 7, 5, 3, 1]

    Enum.into(players, %{}, fn {player_id, player_data} ->
      ranking = Map.get(player_data, :preference_ranking, Map.get(player_data, "preference_ranking", []))

      points =
        passed_bill_ids
        |> Enum.reduce(0, fn bill_id, acc ->
          rank = Enum.find_index(ranking, &(&1 == bill_id))

          bonus =
            if rank != nil do
              Enum.at(rank_scores, rank, 0)
            else
              0
            end

          acc + bonus
        end)

      {player_id, points}
    end)
  end

  @doc """
  Calculates the amendment bonus for a player.
  +5 for each successful amendment they proposed.
  """
  @spec score_amendments(map(), [map()]) :: map()
  def score_amendments(players, resolved_amendments) do
    successful =
      Enum.filter(resolved_amendments, fn a ->
        Map.get(a, :passed, Map.get(a, "passed", false))
      end)

    base = Enum.into(players, %{}, fn {player_id, _} -> {player_id, 0} end)

    Enum.reduce(successful, base, fn amendment, acc ->
      proposer = Map.get(amendment, :proposer_id, Map.get(amendment, "proposer_id"))

      if proposer && Map.has_key?(acc, proposer) do
        Map.update!(acc, proposer, &(&1 + 5))
      else
        acc
      end
    end)
  end

  @doc """
  Calculates the capital bonus for a player (1:1 ratio with remaining capital).
  """
  @spec score_capital(map()) :: map()
  def score_capital(players) do
    Enum.into(players, %{}, fn {player_id, player_data} ->
      capital = Map.get(player_data, :political_capital, Map.get(player_data, "political_capital", 0))
      {player_id, capital}
    end)
  end
end
