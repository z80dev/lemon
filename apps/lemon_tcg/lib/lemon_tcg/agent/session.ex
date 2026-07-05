defmodule LemonTcg.Agent.Session do
  @moduledoc """
  Runs an LLM agent loop against a live `LemonTcg.Desk`.

  This is the live counterpart of `LemonSim.Examples.TcgShop.run/1`: the
  same kernel runner, projector, decider, and tool policy, but the world
  is a mirror of a real desk instead of a simulation. Each driver turn the
  agent may inspect the desk with support tools, then must take exactly
  one terminal action (buy, sell, halt, wait, or close the session).

  ## Options

    * `:desk` — a running desk pid; if omitted, one is started from
      `:desk_opts` and stopped when the session ends
    * `:max_turns` — market turns before the session auto-completes
      (default 10; each `tcg_live_wait` consumes one)
    * `:turn_interval_ms` — wall-clock pause inside `tcg_live_wait`,
      for pacing real market re-checks (default 0)
    * `:model` / `:stream_options` / `:complete_fn` — as in sim games;
      resolved from Lemon config when omitted
    * `:driver_max_turns`, `:decision_max_turns` — loop bounds

  Paper venue + fixture source makes this fully offline; paper venue +
  Magic Eden source trades paper against live quotes.
  """

  alias LemonCore.Config.Modular
  alias LemonCore.MapHelpers
  alias LemonSim.Kernel.DecisionAdapters.ExecutedCallEvents
  alias LemonSim.Kernel.{Runner, State}
  alias LemonSim.LLM.Deciders.ToolLoopDecider
  alias LemonSim.LLM.Deciders.ToolPolicies.SingleTerminal
  alias LemonSim.LLM.GameHelpers.Config
  alias LemonSim.LLM.Projectors.SectionedProjector
  alias LemonTcg.Agent.{ActionSpace, Updater}
  alias LemonTcg.Desk

  @default_max_turns 10
  @default_driver_max_turns 60

  def modules do
    %{
      action_space: ActionSpace,
      projector: SectionedProjector,
      decider: ToolLoopDecider,
      updater: Updater,
      decision_adapter: ExecutedCallEvents
    }
  end

  def initial_state(desk, opts \\ []) do
    session_id =
      Keyword.get(opts, :session_id, "tcg_live_#{:erlang.unique_integer([:positive])}")

    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    snapshot = Desk.snapshot(desk)

    State.new(
      sim_id: session_id,
      world: %{
        mode: "tcg_live",
        status: "in_progress",
        turn: 1,
        max_turns: max_turns,
        watchlist: snapshot.watchlist,
        snapshot: snapshot,
        action_history: [],
        invalid_action_count: 0
      },
      intent: %{
        goal:
          "Operate a live tokenized trading-card desk for #{max_turns} market turns. " <>
            "Buy tokens listed meaningfully below their collection floor, take profits when " <>
            "the exit spread allows, and never fight the risk policy. Maximize net worth."
      },
      meta: %{desk: desk}
    )
  end

  def projector_opts do
    [
      system_prompt: """
      You are the operator of a live trading desk for tokenized graded
      trading cards. Quotes are real market data; fills go through a
      venue with fees and an exit spread, and every order passes a risk
      policy (trade caps, daily spend, allowlist, kill switch).
      Round trips cost real spread: only buy when the discount to floor
      clearly exceeds fees plus the exit haircut. Before any buy, price
      the token against its physical comp with tcg_live_price_basis —
      a discount to comp can still be a negative-edge trade after fees,
      redemption, and shipping. Waiting is a position.
      Use support tools to inspect, then take exactly one terminal action.
      """,
      section_builders: %{
        desk: fn frame, _tools, _opts ->
          world = frame.world
          snapshot = MapHelpers.get_key(world, :snapshot) || %{}

          %{
            id: :desk,
            title: "Desk State",
            format: :json,
            content: %{
              turn: MapHelpers.get_key(world, :turn),
              max_turns: MapHelpers.get_key(world, :max_turns),
              mark: Map.get(snapshot, :mark),
              positions: Map.get(snapshot, :positions),
              policy: Map.get(snapshot, :policy),
              venue: Map.get(snapshot, :venue)
            }
          }
        end,
        market: fn frame, _tools, _opts ->
          snapshot = MapHelpers.get_key(frame.world, :snapshot) || %{}

          %{
            id: :market,
            title: "Market",
            format: :json,
            content: %{
              watchlist: Map.get(snapshot, :watchlist),
              floors_usd: Map.get(snapshot, :floors_usd)
            }
          }
        end,
        activity: fn frame, _tools, _opts ->
          world = frame.world

          %{
            id: :activity,
            title: "Recent Activity",
            format: :json,
            content: %{
              actions: world |> MapHelpers.get_key(:action_history) |> List.wrap() |> Enum.take(-10),
              invalid_action_count: MapHelpers.get_key(world, :invalid_action_count) || 0
            }
          }
        end
      }
    ]
  end

  def default_opts(overrides \\ []) do
    model =
      Keyword.get_lazy(overrides, :model, fn ->
        config = Modular.load(project_dir: File.cwd!())
        Config.resolve_configured_model!(config, "TCG Live")
      end)

    stream_options =
      Keyword.get_lazy(overrides, :stream_options, fn ->
        config = Modular.load(project_dir: File.cwd!())
        %{api_key: Config.resolve_provider_api_key!(model.provider, config, "tcg live")}
      end)

    projector_opts()
    |> Kernel.++(
      model: model,
      stream_options: stream_options,
      driver_max_turns: Keyword.get(overrides, :driver_max_turns, @default_driver_max_turns),
      decision_max_turns: Keyword.get(overrides, :decision_max_turns, 4),
      terminal?: &terminal?/1,
      tool_policy: SingleTerminal,
      support_tool_matcher: &ActionSpace.support_tool?/1,
      require_executed_call_events?: true
    )
    |> maybe_put(:complete_fn, Keyword.get(overrides, :complete_fn))
  end

  @doc """
  Runs the session loop until the world completes or turn limits hit.

  Returns `{:ok, final_state}`; when the session started its own desk, the
  final desk snapshot is in `final_state.world.snapshot` and the desk is
  stopped before returning.
  """
  def run(opts \\ []) do
    {desk, owned?} = ensure_desk(opts)

    run_opts =
      opts
      |> default_opts()
      |> Keyword.merge(Keyword.drop(opts, [:desk, :desk_opts]))

    try do
      state = initial_state(desk, opts)
      Runner.run_until_terminal(state, modules(), run_opts)
    after
      if owned?, do: GenServer.stop(desk, :normal, 5_000)
    end
  end

  def terminal?(%State{world: world}) do
    (MapHelpers.get_key(world, :status) || "in_progress") != "in_progress"
  end

  defp ensure_desk(opts) do
    case Keyword.get(opts, :desk) do
      nil ->
        {:ok, desk} = Desk.start_link(Keyword.get(opts, :desk_opts, []))
        {desk, true}

      desk ->
        {desk, false}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
