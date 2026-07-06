defmodule LemonSimUi.ArenaDomains do
  @moduledoc """
  Presentation config for the always-on arena domains.

  Pure data consumed by the arena LiveViews: display names, taglines, icons,
  role-specialist definitions (team games), and stat-leader definitions
  (games without fixed roles). Runtime behavior lives in `LemonSimUi.Arena`.
  """

  @type role_spec :: {String.t(), String.t(), String.t(), String.t(), String.t()}
  @type stat_spec :: {String.t(), String.t(), String.t()}

  @domains %{
    werewolf: %{
      title: "Werewolf",
      tagline: "Which model is the best liar, detective, and survivor?",
      icon: "🐺",
      accent: "red",
      # {role_key, label, icon, metric_key, metric_label}
      roles: [
        {"werewolf", "Werewolf", "🐺", "successful_kills", "kills"},
        {"seer", "Seer", "🔮", "wolf_checks_found", "wolves found"},
        {"doctor", "Doctor", "🩺", "doctor_saves", "saves"},
        {"villager", "Villager", "🏘️", "votes_for_werewolf", "wolf votes"}
      ],
      stats: [],
      winner_labels: %{"werewolves" => "🐺 Wolves", "villagers" => "🏘️ Village"}
    },
    space_station: %{
      title: "Space Station Crisis",
      tagline: "One saboteur hides among the crew. Who do the models trust?",
      icon: "🛰️",
      accent: "violet",
      roles: [
        {"saboteur", "Saboteur", "🕵️", "fake_repairs", "fake repairs"},
        {"engineer", "Engineer", "🔧", "repairs", "repairs"},
        {"captain", "Captain", "🧑‍✈️", "correct_votes", "correct votes"},
        {"crew", "Crew", "🧑‍🚀", "correct_votes", "correct votes"}
      ],
      stats: [],
      winner_labels: %{"crew" => "🧑‍🚀 Crew", "saboteur" => "🕵️ Saboteur"}
    },
    stock_market: %{
      title: "Stock Market Arena",
      tagline: "Public calls move prices. Whispers move everything else.",
      icon: "📈",
      accent: "emerald",
      roles: [],
      # {metric_key, label, icon}
      stats: [
        {"accurate_calls", "Accurate market calls", "🎯"},
        {"profitable_trades", "Profitable trades", "💰"},
        {"whispers_sent", "Whispers sent", "🤫"}
      ],
      winner_labels: %{}
    },
    survivor: %{
      title: "Survivor",
      tagline: "Alliances, blindsides, and a jury with a long memory.",
      icon: "🏝️",
      accent: "amber",
      roles: [],
      stats: [
        {"jury_votes_received", "Jury votes", "🗳️"},
        {"challenge_wins", "Challenge wins", "🏆"},
        {"whispers_sent", "Whispers sent", "🤫"}
      ],
      winner_labels: %{}
    }
  }

  @spec get(atom()) :: map() | nil
  def get(domain), do: Map.get(@domains, domain)

  @spec domain_atom(String.t()) :: {:ok, atom()} | :error
  def domain_atom(slug) when is_binary(slug) do
    Enum.find_value(Map.keys(@domains), :error, fn domain ->
      if Atom.to_string(domain) == slug, do: {:ok, domain}
    end)
  end

  @spec winner_label(atom(), String.t() | nil) :: String.t()
  def winner_label(domain, winner) do
    labels = get(domain)[:winner_labels] || %{}
    Map.get(labels, winner, to_string(winner || "?"))
  end
end
