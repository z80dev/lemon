defmodule LemonSim.Examples.PhilosopherChat.Pacing do
  @moduledoc """
  Pure pacing policy for autonomous group conversation.

  All randomness flows through a `:rand` seed tuple so the hosted thread
  server can keep turns deterministic-ish and recoverable. Every random
  function returns `{value, next_rng_state}`; pure lookups return values.
  """

  import LemonSim.Examples.Helpers

  alias LemonSim.Examples.PhilosopherChat, as: Domain
  alias LemonSim.Examples.PhilosopherChat.Persona

  @max_retry_delay_ms 60_000

  @doc "Agent member ids of a world (everyone except the human user)."
  @spec agent_members(map()) :: [String.t()]
  def agent_members(world) do
    get(world, :members, [])
    |> Enum.reject(&(&1 == Domain.user_id()))
  end

  @doc "True when the most recent message mentions the agent by first name or id."
  @spec mentioned?(map(), String.t()) :: boolean()
  def mentioned?(world, agent_id) do
    case get(world, :messages, []) |> List.last() do
      nil ->
        false

      last ->
        text = get(last, :text, "") |> to_string()
        name = agent_name(agent_id)
        first_name = name |> String.split(" ") |> List.first()

        word_match?(text, first_name) or word_match?(text, agent_id)
    end
  end

  # Whole-word, case-insensitive match so "hume" does not match "human".
  defp word_match?(_text, nil), do: false
  defp word_match?(_text, ""), do: false

  defp word_match?(text, word) do
    Regex.match?(~r/(?<![\w-])#{Regex.escape(word)}(?![\w-])/i, text)
  end

  @doc """
  Picks which agent should speak next.

  Prefers agents mentioned in the latest message; otherwise falls back to the
  whole agent pool, excluding the last speaker when possible so no one
  monologues. Returns `{agent_id | nil, next_rng}`.
  """
  @spec pick_responder(map(), tuple()) :: {String.t() | nil, tuple()}
  def pick_responder(world, rng_state) do
    agents = agent_members(world)
    last_author = get(world, :last_author)

    pool =
      case Enum.filter(agents, &mentioned?(world, &1)) do
        [] -> agents
        mentioned -> mentioned
      end

    pool =
      if length(pool) > 1 and is_binary(last_author) and last_author != Domain.user_id() do
        case Enum.reject(pool, &(&1 == last_author)) do
          [] -> pool
          others -> others
        end
      else
        pool
      end

    case pool do
      [] ->
        {nil, rng_state}

      [only] ->
        {only, rng_state}

      _ ->
        {idx, next_rng} = rand_int(rng_state, length(pool))
        {Enum.at(pool, idx), next_rng}
    end
  end

  @doc "Picks a random agent (for idle chatter openings)."
  @spec random_agent(map(), tuple()) :: {String.t() | nil, tuple()}
  def random_agent(world, rng_state) do
    case agent_members(world) do
      [] ->
        {nil, rng_state}

      agents ->
        {idx, next_rng} = rand_int(rng_state, length(agents))
        {Enum.at(agents, idx), next_rng}
    end
  end

  @doc "Should another agent chime in after an agent just spoke?"
  @spec continue_chatter?(String.t(), tuple()) :: {boolean(), tuple()}
  def continue_chatter?(pace, rng_state) do
    chance?(rng_state, continue_chance(pace))
  end

  @doc "Should an agent open a new topic while the room has been quiet?"
  @spec idle_chatter?(String.t(), tuple()) :: {boolean(), tuple()}
  def idle_chatter?(pace, rng_state) do
    chance?(rng_state, idle_chance(pace))
  end

  @doc "Jittered delay before an agent replies, in milliseconds."
  @spec reply_delay_ms(String.t(), tuple()) :: {non_neg_integer(), tuple()}
  def reply_delay_ms(pace, rng_state) do
    {lo, hi} = delay_range(pace)
    {offset, next_rng} = rand_int(rng_state, hi - lo + 1)
    {lo + offset, next_rng}
  end

  @doc "Delay for an explicit user nudge (fast, but not instant)."
  @spec nudge_delay_ms(String.t(), tuple()) :: {non_neg_integer(), tuple()}
  def nudge_delay_ms(pace, rng_state) do
    base = if pace == "chatty", do: 1_500, else: 3_000
    {offset, next_rng} = rand_int(rng_state, 4_000)
    {base + offset, next_rng}
  end

  @doc """
  Jittered exponential backoff before retrying a failed agent turn.

  `attempt` is the 1-based retry number (the consecutive-failure count); the
  base delay doubles per attempt and is capped at #{@max_retry_delay_ms}ms.
  """
  @spec retry_delay_ms(String.t(), pos_integer(), tuple()) :: {non_neg_integer(), tuple()}
  def retry_delay_ms(pace, attempt, rng_state) do
    base = if pace == "chatty", do: 2_000, else: 3_000
    backoff = min(base * 2 ** max(attempt - 1, 0), @max_retry_delay_ms)
    {offset, next_rng} = rand_int(rng_state, 2_000)
    {backoff + offset, next_rng}
  end

  @doc "Minimum gap enforced between consecutive agent messages."
  @spec min_cooldown_ms(String.t()) :: non_neg_integer()
  def min_cooldown_ms(pace), do: if(pace == "chatty", do: 12_000, else: 20_000)

  @doc "Maximum chained agent replies after a single user message."
  @spec max_chain(String.t()) :: pos_integer()
  def max_chain(pace), do: if(pace == "chatty", do: 3, else: 2)

  @doc "Hourly agent-message cap per thread."
  @spec hourly_cap(String.t()) :: pos_integer()
  def hourly_cap(pace), do: if(pace == "chatty", do: 45, else: 30)

  @doc "Milliseconds of quiet before an idle-chatter check fires."
  @spec idle_after_ms(String.t()) :: pos_integer()
  def idle_after_ms(pace), do: if(pace == "chatty", do: 180_000, else: 300_000)

  @doc "Count of agent messages in the last 60 minutes."
  @spec recent_agent_count(map(), non_neg_integer()) :: non_neg_integer()
  def recent_agent_count(world, now_ms) do
    get(world, :messages, [])
    |> Enum.filter(fn m ->
      get(m, :author) != Domain.user_id() and get(m, :at_ms, 0) >= now_ms - 3_600_000
    end)
    |> length()
  end

  # -- internals --

  defp agent_name(agent_id) do
    case Persona.get(agent_id) do
      %Persona{name: name} -> name
      nil -> agent_id
    end
  end

  defp continue_chance("chatty"), do: 0.85
  defp continue_chance(_), do: 0.5

  defp idle_chance("chatty"), do: 0.6
  defp idle_chance(_), do: 0.35

  defp delay_range("chatty"), do: {15_000, 60_000}
  defp delay_range(_), do: {25_000, 90_000}

  defp chance?(rng_state, probability) do
    {roll, next_rng} = rand_int(rng_state, 1_000_000)
    {roll < round(probability * 1_000_000), next_rng}
  end

  @doc false
  # Advances the process RNG from the given seed and returns {value, new_seed}.
  def rand_int(rng_state, n) when n > 0 do
    :rand.seed(rng_state)
    value = :rand.uniform(n) - 1
    {value, :rand.export_seed()}
  end
end
