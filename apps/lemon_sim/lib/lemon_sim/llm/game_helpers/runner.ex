defmodule LemonSim.LLM.GameHelpers.Runner do
  @moduledoc """
  Shared run/run_multi_model infrastructure for LemonSim games.

  Eliminates the ~200 lines of boilerplate per game for building default opts,
  running single-model games, running multi-model games with model switching
  and transcript logging.
  """

  import LemonSim.Examples.Helpers

  alias LemonSim.Kernel.{Runner, Store}
  alias LemonSim.LLM.GameHelpers.{Config, ProviderThrottle, Transcript}
  alias LemonSim.LLM.Usage

  @doc """
  Builds the standard opts keyword list for a game.

  ## Game options (keyword list)
    * `:game_name` (required) - name for error messages
    * `:max_turns` - maximum driver turns (default 200)
    * `:provider_min_interval_ms` - optional per-provider request spacing, e.g. `%{google_gemini_cli: 5_000}`
    * `:terminal?` (required) - fn(state) -> boolean
    * `:on_before_step` (required) - fn(turn, state) -> :ok
    * `:on_after_step` (required) - fn(turn, result) -> :ok
  """
  def build_default_opts(projector_opts, overrides, game_opts) do
    game_name = Keyword.fetch!(game_opts, :game_name)
    max_turns = Keyword.get(game_opts, :max_turns, 200)

    config = LemonCore.Config.Modular.load(project_dir: File.cwd!())

    model =
      Keyword.get_lazy(overrides, :model, fn ->
        Config.resolve_configured_model!(config, game_name)
      end)

    stream_options =
      Keyword.get_lazy(overrides, :stream_options, fn ->
        %{api_key: Config.resolve_provider_api_key!(model.provider, config, game_name)}
      end)

    projector_opts
    |> Kernel.++(
      model: model,
      stream_options: stream_options,
      driver_max_turns: max_turns,
      persist?: true,
      provider_min_interval_ms: Keyword.get(overrides, :provider_min_interval_ms, %{}),
      terminal?: Keyword.fetch!(game_opts, :terminal?),
      on_before_step: Keyword.fetch!(game_opts, :on_before_step),
      on_after_step: Keyword.fetch!(game_opts, :on_after_step)
    )
    |> maybe_put(:complete_fn, Keyword.get(overrides, :complete_fn))
  end

  @doc """
  Runs a single-model game.

  ## Callbacks (keyword list)
    * `:print_setup` (required) - fn(state) -> :ok
    * `:print_result` (required) - fn(world) -> :ok
  """
  def run(state, modules, default_opts_fn, opts, callbacks) do
    {usage_collector, owns_usage_collector?} = usage_collector(state.sim_id, opts)

    {run_opts, throttle_agent} =
      opts
      |> default_opts_fn.()
      |> Keyword.merge(opts)
      |> Keyword.put(:usage_collector, usage_collector)
      |> Keyword.put_new(:usage_actor_id, "operator")
      |> ProviderThrottle.wrap_opts()

    try do
      Keyword.fetch!(callbacks, :print_setup).(state)

      case Runner.run_until_terminal(state, modules, run_opts) do
        {:ok, final_state} ->
          IO.puts("\n=== GAME OVER ===")
          Keyword.fetch!(callbacks, :print_result).(final_state.world)

          if Keyword.get(run_opts, :persist?, true) do
            _ = Store.put_state(final_state)
          end

          maybe_return_usage({:ok, final_state}, usage_collector, opts)

        {:error, reason} = error ->
          IO.puts("Game failed: #{inspect(reason)}")
          error
      end
    after
      ProviderThrottle.stop(throttle_agent)
      stop_usage_collector(usage_collector, owns_usage_collector?)
    end
  end

  @doc """
  Runs a multi-model game with per-player model switching and optional
  transcript logging.

  ## Callbacks (keyword list)
    * `:print_setup` (required) - fn(state) -> :ok
    * `:print_result` (required) - fn(world) -> :ok
    * `:announce_turn` (required) - fn(turn, state) -> :ok
    * `:print_step` (required) - fn(turn, result) -> :ok
    * `:transcript_step_meta` - fn(world) -> map() (default: empty map)
    * `:transcript_step_entry` - fn(turn, world, model_assignments) -> map() | nil
    * `:transcript_result_entry` - fn(turn, step_meta, result) -> map() | nil
    * `:transcript_detail` - fn(world) -> map() (default: empty map)
    * `:transcript_game_over_extra` - fn(world) -> map() (default: empty map)
  """
  def run_multi_model(state, modules, default_opts_fn, opts, callbacks) do
    model_assignments = Keyword.fetch!(opts, :model_assignments)
    transcript_path = Keyword.get(opts, :transcript_path)
    {usage_collector, owns_usage_collector?} = usage_collector(state.sim_id, opts)

    {default_model, default_key} = model_assignments |> Map.values() |> List.first()

    transcript =
      if transcript_path do
        Transcript.start(transcript_path, state.world, model_assignments)
      end

    {:ok, model_agent} = Agent.start_link(fn -> {default_model, default_key} end)
    {:ok, active_actor_agent} = Agent.start_link(fn -> nil end)

    complete_fn = fn _model, context, stream_options ->
      {actual_model, api_key} = Agent.get(model_agent, & &1)

      actual_stream_options =
        stream_options
        |> Map.new()
        |> Map.put(:api_key, api_key)

      Ai.complete(actual_model, context, actual_stream_options)
    end

    {:ok, step_meta_agent} = Agent.start_link(fn -> %{} end)

    announce_turn = Keyword.fetch!(callbacks, :announce_turn)
    print_step_fn = Keyword.fetch!(callbacks, :print_step)
    transcript_step_meta = Keyword.get(callbacks, :transcript_step_meta, fn _ -> %{} end)
    transcript_step_entry = Keyword.get(callbacks, :transcript_step_entry)
    transcript_result_entry = Keyword.get(callbacks, :transcript_result_entry)
    transcript_detail = Keyword.get(callbacks, :transcript_detail, fn _ -> %{} end)

    on_before_step = fn turn, step_state ->
      actor_id = get(step_state.world, :active_actor_id)
      step_meta = transcript_step_meta.(step_state.world)
      Agent.update(active_actor_agent, fn _ -> actor_id end)

      case Map.get(model_assignments, actor_id) do
        {model, key} -> Agent.update(model_agent, fn _ -> {model, key} end)
        nil -> :ok
      end

      Agent.update(step_meta_agent, fn _ -> step_meta end)

      if transcript do
        case transcript_step_entry do
          nil ->
            Transcript.log_step(transcript, turn, step_state.world, model_assignments)

          builder ->
            case builder.(turn, step_state.world, model_assignments) do
              nil -> :ok
              entry -> Transcript.log_entry(transcript, entry)
            end
        end
      end

      announce_turn.(turn, step_state)
    end

    on_after_step = fn turn, result ->
      case result do
        %{state: next_state} ->
          step_meta = Agent.get(step_meta_agent, & &1)

          if transcript do
            case transcript_result_entry do
              nil ->
                Transcript.log_result(transcript, turn, next_state.world, transcript_detail)

              builder ->
                case builder.(turn, step_meta, result) do
                  nil -> :ok
                  entry -> Transcript.log_entry(transcript, entry)
                end
            end
          end

          print_step_fn.(turn, result)

        _ ->
          :ok
      end
    end

    {run_opts, throttle_agent} =
      default_opts_fn.(
        opts
        |> Keyword.put(:model, default_model)
        |> Keyword.put(:stream_options, %{api_key: default_key})
      )
      |> Keyword.merge(opts)
      |> Keyword.put(:complete_fn, complete_fn)
      |> Keyword.put(:on_before_step, on_before_step)
      |> Keyword.put(:on_after_step, on_after_step)
      |> Keyword.put(:usage_collector, usage_collector)
      |> Keyword.put(:usage_actor_id, fn -> Agent.get(active_actor_agent, & &1) end)
      |> Keyword.put(:usage_model, fn -> Agent.get(model_agent, fn {model, _key} -> model end) end)
      |> ProviderThrottle.wrap_opts()

    try do
      Keyword.fetch!(callbacks, :print_setup).(state)
      print_model_assignments(model_assignments)

      case Runner.run_until_terminal(state, modules, run_opts) do
        {:ok, final_state} ->
          IO.puts("\n=== GAME OVER ===")
          Keyword.fetch!(callbacks, :print_result).(final_state.world)

          if transcript do
            extra_fn =
              Keyword.get(callbacks, :transcript_game_over_extra, fn _ -> %{} end)

            Transcript.log_game_over(transcript, final_state.world, model_assignments,
              extra: extra_fn.(final_state.world)
            )
          end

          if Keyword.get(run_opts, :persist?, true) do
            _ = Store.put_state(final_state)
          end

          maybe_return_usage({:ok, final_state}, usage_collector, opts)

        {:error, reason} = error ->
          IO.puts("Game failed: #{inspect(reason)}")
          error
      end
    after
      ProviderThrottle.stop(throttle_agent)
      stop_agent(model_agent)
      stop_agent(active_actor_agent)
      stop_agent(step_meta_agent)
      stop_usage_collector(usage_collector, owns_usage_collector?)
      if transcript, do: File.close(transcript)
    end
  end

  @doc """
  Prints model-to-player assignments (used by run_multi_model).
  """
  def print_model_assignments(model_assignments) do
    IO.puts("Model assignments:")

    model_assignments
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.each(fn {id, {model, _key}} ->
      IO.puts("  #{id}: #{model.provider}/#{model.id}")
    end)

    IO.puts("")
  end

  defp stop_agent(nil), do: :ok

  defp stop_agent(agent) when is_pid(agent) do
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  end

  defp usage_collector(sim_id, opts) do
    case Keyword.get(opts, :usage_collector) do
      collector when is_pid(collector) ->
        {collector, false}

      _ ->
        {:ok, collector} = Usage.start_link(sim_id)
        {collector, true}
    end
  end

  defp maybe_return_usage({:ok, state}, collector, opts) do
    if Keyword.get(opts, :return_usage?, false) do
      {:ok, %{state: state, usage: Usage.artifact(collector, state.sim_id)}}
    else
      {:ok, state}
    end
  end

  defp stop_usage_collector(collector, true), do: stop_agent(collector)
  defp stop_usage_collector(_collector, false), do: :ok
end
