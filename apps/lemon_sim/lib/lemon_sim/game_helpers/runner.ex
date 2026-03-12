defmodule LemonSim.GameHelpers.Runner do
  @moduledoc """
  Shared run/run_multi_model infrastructure for LemonSim games.

  Eliminates the ~200 lines of boilerplate per game for building default opts,
  running single-model games, running multi-model games with model switching
  and transcript logging.
  """

  import LemonSim.GameHelpers

  alias LemonSim.GameHelpers.{Config, Transcript}
  alias LemonSim.{Runner, Store}

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
    {run_opts, throttle_agent} =
      opts
      |> default_opts_fn.()
      |> Keyword.merge(opts)
      |> with_provider_throttle()

    try do
      Keyword.fetch!(callbacks, :print_setup).(state)

      case Runner.run_until_terminal(state, modules, run_opts) do
        {:ok, final_state} ->
          IO.puts("\n=== GAME OVER ===")
          Keyword.fetch!(callbacks, :print_result).(final_state.world)

          if Keyword.get(run_opts, :persist?, true) do
            _ = Store.put_state(final_state)
          end

          {:ok, final_state}

        {:error, reason} = error ->
          IO.puts("Game failed:")
          IO.inspect(reason)
          error
      end
    after
      stop_agent(throttle_agent)
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

    {default_model, default_key} = model_assignments |> Map.values() |> List.first()

    transcript =
      if transcript_path do
        Transcript.start(transcript_path, state.world, model_assignments)
      end

    {:ok, model_agent} = Agent.start_link(fn -> {default_model, default_key} end)

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
      |> with_provider_throttle()

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

          {:ok, final_state}

        {:error, reason} = error ->
          IO.puts("Game failed:")
          IO.inspect(reason)
          error
      end
    after
      stop_agent(throttle_agent)
      stop_agent(model_agent)
      stop_agent(step_meta_agent)
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

  defp with_provider_throttle(opts) do
    provider_min_interval_ms =
      opts
      |> Keyword.get(:provider_min_interval_ms, %{})
      |> normalize_provider_intervals()

    if map_size(provider_min_interval_ms) == 0 do
      {opts, nil}
    else
      {:ok, throttle_agent} = Agent.start_link(fn -> %{} end)
      base_complete_fn = Keyword.get(opts, :complete_fn, &Ai.complete/3)

      throttled_complete_fn = fn model, context, stream_options ->
        maybe_wait_for_provider(throttle_agent, model.provider, provider_min_interval_ms)
        base_complete_fn.(model, context, stream_options)
      end

      {Keyword.put(opts, :complete_fn, throttled_complete_fn), throttle_agent}
    end
  end

  defp normalize_provider_intervals(intervals) when is_map(intervals) do
    intervals
    |> Enum.reduce(%{}, fn
      {provider, interval_ms}, acc when is_integer(interval_ms) and interval_ms > 0 ->
        Map.put(acc, normalize_provider_key(provider), interval_ms)

      _, acc ->
        acc
    end)
  end

  defp normalize_provider_intervals(_), do: %{}

  defp maybe_wait_for_provider(_throttle_agent, _provider, provider_min_interval_ms)
       when map_size(provider_min_interval_ms) == 0,
       do: :ok

  defp maybe_wait_for_provider(throttle_agent, provider, provider_min_interval_ms) do
    provider_key = normalize_provider_key(provider)

    case Map.get(provider_min_interval_ms, provider_key) do
      interval_ms when is_integer(interval_ms) and interval_ms > 0 ->
        now_ms = System.monotonic_time(:millisecond)

        wait_ms =
          Agent.get_and_update(throttle_agent, fn state ->
            next_allowed_at = Map.get(state, provider_key, now_ms)
            wait_ms = max(next_allowed_at - now_ms, 0)
            scheduled_at = max(now_ms, next_allowed_at) + interval_ms
            {wait_ms, Map.put(state, provider_key, scheduled_at)}
          end)

        if wait_ms > 0, do: Process.sleep(wait_ms)
        :ok

      _ ->
        :ok
    end
  end

  defp normalize_provider_key(provider) when is_atom(provider), do: provider

  defp normalize_provider_key(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp stop_agent(nil), do: :ok

  defp stop_agent(agent) when is_pid(agent) do
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  end
end
