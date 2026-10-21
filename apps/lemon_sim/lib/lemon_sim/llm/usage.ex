defmodule LemonSim.LLM.Usage do
  @moduledoc false

  alias LemonAi.Types.{Model, ModelCost, Usage}
  alias LemonCore.MapHelpers
  alias LemonSim.LLM.Projectors.Toolkit

  @schema "lemon_sim.usage.v1"
  @zero_totals %{
    input_tokens: 0,
    output_tokens: 0,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    decisions: 0,
    latency_ms: 0,
    cost_usd: 0.0
  }

  def start_link(sim_id) when is_binary(sim_id) do
    Agent.start_link(fn -> new(sim_id) end)
  end

  def start_link(sim_id, nil) when is_binary(sim_id), do: start_link(sim_id)

  def start_link(sim_id, initial_usage) when is_binary(sim_id) and is_map(initial_usage) do
    Agent.start_link(fn -> initial_usage |> to_artifact() |> Map.put(:sim_id, sim_id) end)
  end

  def new(sim_id) when is_binary(sim_id) do
    %{schema: @schema, sim_id: sim_id, totals: @zero_totals, actors: %{}, cost_known?: true}
  end

  def record_response(collector, actor_id, model, usage),
    do: record_response(collector, actor_id, model, usage, 0)

  def record_response(nil, _actor_id, _model, _usage, _latency_ms), do: :ok

  def record_response(collector, actor_id, model, nil, latency_ms) do
    record_response(
      collector,
      actor_id,
      model,
      %Usage{
        input: nil,
        output: nil,
        cache_read: nil,
        cache_write: nil,
        cache_write_long: nil,
        total_tokens: nil,
        cost: nil
      },
      latency_ms
    )
  end

  def record_response(collector, actor_id, %Model{} = model, %Usage{} = usage, latency_ms)
      when is_pid(collector) do
    Agent.update(collector, &add_response(&1, actor_id, model, usage, latency_ms))
  end

  def record_response(_collector, _actor_id, _model, _usage, _latency_ms), do: :ok

  def record_decision(nil, _actor_id, _model), do: :ok

  def record_decision(collector, actor_id, %Model{} = model) when is_pid(collector) do
    Agent.update(collector, &add_decision(&1, actor_id, model))
  end

  def record_decision(_collector, _actor_id, _model), do: :ok

  def record_external_decision(nil, _actor_id, _model_id), do: :ok

  def record_external_decision(collector, actor_id, model_id) when is_pid(collector) do
    Agent.update(collector, &add_external_decision(&1, actor_id, model_id))
  end

  def record_external_decision(_collector, _actor_id, _model_id), do: :ok

  def artifact(nil, sim_id) when is_binary(sim_id), do: to_artifact(new(sim_id))

  def artifact(collector, _sim_id) when is_pid(collector),
    do: Agent.get(collector, &to_artifact/1)

  def artifact(%{} = state, _sim_id), do: to_artifact(state)

  def encode_artifact(usage) do
    usage
    |> to_artifact()
    |> Toolkit.stable_json()
    |> Kernel.<>("\n")
  end

  def summary_line(usage) do
    artifact = to_artifact(usage)
    totals = artifact.totals
    actor_count = map_size(artifact.actors)

    cost =
      case totals.cost_usd do
        nil -> "unknown cost"
        value -> "$#{format_cost(value)}"
      end

    "usage: #{format_tokens(totals.input_tokens)} in / #{format_tokens(totals.output_tokens)} out, #{cost} (#{actor_count} actors)"
  end

  defp add_response(state, actor_id, model, usage, latency_ms) do
    actor_id = normalize_actor_id(actor_id)
    cost = if pricing_known?(model), do: LemonAi.calculate_cost(model, usage).total
    cost_known? = is_number(cost)

    state
    |> update_in([:totals], &add_usage(&1, usage, cost, latency_ms))
    |> update_in([:actors], fn actors ->
      Map.update(
        actors,
        actor_id,
        add_usage(new_actor(model), usage, cost, latency_ms),
        &add_usage(&1, usage, cost, latency_ms)
      )
    end)
    |> update_cost_known(cost_known?)
  end

  defp add_decision(state, actor_id, model) do
    actor_id = normalize_actor_id(actor_id)

    state
    |> update_in([:totals, :decisions], &(&1 + 1))
    |> update_in([:actors], fn actors ->
      Map.update(
        actors,
        actor_id,
        %{new_actor(model) | decisions: 1},
        &%{&1 | decisions: &1.decisions + 1, model_id: model_id(model)}
      )
    end)
  end

  defp add_external_decision(state, actor_id, model_id) do
    actor_id = normalize_actor_id(actor_id)
    model_id = to_string(model_id || "external")

    state
    |> update_in([:totals, :decisions], &(&1 + 1))
    |> update_in([:actors], fn actors ->
      Map.update(
        actors,
        actor_id,
        %{external_actor(model_id) | decisions: 1},
        &%{&1 | decisions: &1.decisions + 1, model_id: model_id, cost_usd: nil}
      )
    end)
    |> update_cost_known(false)
  end

  defp add_usage(acc, %Usage{} = usage, cost, latency_ms) do
    acc
    |> Map.update!(:input_tokens, &add_known(&1, usage.input))
    |> Map.update!(:output_tokens, &add_known(&1, usage.output))
    |> Map.update!(:cache_read_tokens, &add_known(&1, usage.cache_read))
    |> Map.update!(:cache_write_tokens, &add_known(&1, usage.cache_write))
    |> Map.update!(:latency_ms, &(&1 + max(latency_ms, 0)))
    |> Map.update!(:cost_usd, &add_known(&1, cost))
  end

  defp add_known(nil, _value), do: nil
  defp add_known(_value, nil), do: nil
  defp add_known(left, right), do: left + right

  defp update_cost_known(state, true), do: state
  defp update_cost_known(state, false), do: %{state | cost_known?: false}

  defp new_actor(model) do
    %{
      model_id: model_id(model),
      decisions: 0,
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      latency_ms: 0,
      cost_usd: if(pricing_known?(model), do: 0.0, else: nil)
    }
  end

  defp external_actor(model_id) do
    %{
      model_id: model_id,
      decisions: 0,
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      cost_usd: nil
    }
  end

  defp to_artifact(%{schema: @schema} = artifact), do: normalize_artifact(artifact)
  defp to_artifact(%{"schema" => @schema} = artifact), do: normalize_artifact(artifact)

  defp normalize_artifact(artifact) do
    totals = normalize_totals(MapHelpers.get_key(artifact, :totals))

    actors =
      artifact
      |> MapHelpers.get_key(:actors)
      |> Enum.sort_by(fn {actor_id, _usage} -> actor_id end)
      |> Map.new(fn {actor_id, usage} -> {actor_id, finalize_actor(normalize_actor(usage))} end)

    cost_known? =
      Map.get(artifact, :cost_known?, Map.get(artifact, "cost_known?", true)) != false and
        is_number(totals.cost_usd) and
        Enum.all?(actors, fn {_actor_id, usage} -> is_number(usage.cost_usd) end)

    %{
      schema: @schema,
      sim_id: MapHelpers.get_key(artifact, :sim_id),
      cost_known?: cost_known?,
      totals: finalize_totals(totals, cost_known?),
      actors: actors
    }
  end

  defp normalize_totals(totals) do
    %{
      input_tokens: MapHelpers.get_key(totals, :input_tokens),
      output_tokens: MapHelpers.get_key(totals, :output_tokens),
      cache_read_tokens: MapHelpers.get_key(totals, :cache_read_tokens),
      cache_write_tokens: MapHelpers.get_key(totals, :cache_write_tokens),
      decisions: MapHelpers.get_key(totals, :decisions) || 0,
      latency_ms: MapHelpers.get_key(totals, :latency_ms) || 0,
      cost_usd: MapHelpers.get_key(totals, :cost_usd)
    }
  end

  defp normalize_actor(actor) do
    Map.merge(normalize_totals(actor), %{model_id: MapHelpers.get_key(actor, :model_id)})
  end

  defp finalize_totals(totals, true), do: finalize_cost(totals)
  defp finalize_totals(totals, false), do: %{finalize_cost(totals) | cost_usd: nil}
  defp finalize_actor(actor), do: finalize_cost(actor)

  defp finalize_cost(%{cost_usd: nil} = usage), do: usage
  defp finalize_cost(%{cost_usd: cost} = usage), do: %{usage | cost_usd: Float.round(cost / 1, 6)}

  defp pricing_known?(%Model{cost: %ModelCost{} = cost}) do
    Enum.any?([cost.input, cost.output, cost.cache_read, cost.cache_write], fn price ->
      is_number(price) and price > 0
    end)
  end

  defp pricing_known?(_model), do: false

  defp model_id(%Model{} = model), do: "#{model.provider}:#{model.id || model.name}"

  defp normalize_actor_id(nil), do: "operator"
  defp normalize_actor_id(actor_id) when is_atom(actor_id), do: Atom.to_string(actor_id)
  defp normalize_actor_id(actor_id), do: to_string(actor_id)

  defp format_tokens(nil), do: "unknown"

  defp format_tokens(value) when value >= 1_000_000 do
    "#{Float.round(value / 1_000_000, 1)}m"
  end

  defp format_tokens(value) when value >= 1_000 do
    "#{Float.round(value / 1_000, 1)}k"
  end

  defp format_tokens(value), do: Integer.to_string(value)

  defp format_cost(value), do: :erlang.float_to_binary(value, decimals: 2)
end
