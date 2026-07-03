defmodule LemonSim.LLM.Usage do
  @moduledoc false

  alias Ai.Types.{Model, ModelCost, Usage}
  alias LemonSim.LLM.Projectors.Toolkit

  @schema "lemon_sim.usage.v1"
  @zero_totals %{
    input_tokens: 0,
    output_tokens: 0,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    decisions: 0,
    cost_usd: 0.0
  }

  def start_link(sim_id) when is_binary(sim_id) do
    Agent.start_link(fn -> new(sim_id) end)
  end

  def new(sim_id) when is_binary(sim_id) do
    %{schema: @schema, sim_id: sim_id, totals: @zero_totals, actors: %{}, cost_known?: true}
  end

  def record_response(nil, _actor_id, _model, _usage), do: :ok
  def record_response(_collector, _actor_id, _model, nil), do: :ok

  def record_response(collector, actor_id, %Model{} = model, %Usage{} = usage)
      when is_pid(collector) do
    Agent.update(collector, &add_response(&1, actor_id, model, usage))
  end

  def record_response(_collector, _actor_id, _model, _usage), do: :ok

  def record_decision(nil, _actor_id, _model), do: :ok

  def record_decision(collector, actor_id, %Model{} = model) when is_pid(collector) do
    Agent.update(collector, &add_decision(&1, actor_id, model))
  end

  def record_decision(_collector, _actor_id, _model), do: :ok

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

  defp add_response(state, actor_id, model, usage) do
    actor_id = normalize_actor_id(actor_id)
    pricing_known? = pricing_known?(model)
    cost = if pricing_known?, do: Ai.calculate_cost(model, usage).total

    state
    |> update_in([:totals], &add_usage(&1, usage, cost, pricing_known?))
    |> update_in([:actors], fn actors ->
      Map.update(
        actors,
        actor_id,
        add_usage(new_actor(model), usage, cost, pricing_known?),
        &add_usage(&1, usage, cost, pricing_known?)
      )
    end)
    |> update_cost_known(pricing_known?)
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

  defp add_usage(acc, %Usage{} = usage, cost, pricing_known?) do
    acc
    |> Map.update!(:input_tokens, &(&1 + usage.input))
    |> Map.update!(:output_tokens, &(&1 + usage.output))
    |> Map.update!(:cache_read_tokens, &(&1 + usage.cache_read))
    |> Map.update!(:cache_write_tokens, &(&1 + usage.cache_write))
    |> add_cost(cost, pricing_known?)
  end

  defp add_cost(acc, cost, true) when is_number(cost) do
    Map.update!(acc, :cost_usd, fn
      nil -> nil
      value -> value + cost
    end)
  end

  defp add_cost(acc, _cost, false), do: %{acc | cost_usd: nil}

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
      cost_usd: if(pricing_known?(model), do: 0.0, else: nil)
    }
  end

  defp to_artifact(%{schema: @schema, cost_known?: _cost_known?} = state) do
    %{
      schema: @schema,
      sim_id: state.sim_id,
      totals: finalize_totals(state.totals, state.cost_known?),
      actors:
        state.actors
        |> Enum.sort_by(fn {actor_id, _usage} -> actor_id end)
        |> Map.new(fn {actor_id, usage} -> {actor_id, finalize_actor(usage)} end)
    }
  end

  defp to_artifact(%{schema: @schema, totals: _totals, actors: _actors} = artifact), do: artifact

  defp to_artifact(%{"schema" => @schema, "totals" => totals, "actors" => actors} = artifact) do
    %{
      schema: @schema,
      sim_id: artifact["sim_id"],
      totals: normalize_totals(totals),
      actors: Map.new(actors, fn {actor_id, usage} -> {actor_id, normalize_actor(usage)} end)
    }
  end

  defp normalize_totals(totals) do
    %{
      input_tokens: totals["input_tokens"] || 0,
      output_tokens: totals["output_tokens"] || 0,
      cache_read_tokens: totals["cache_read_tokens"] || 0,
      cache_write_tokens: totals["cache_write_tokens"] || 0,
      decisions: totals["decisions"] || 0,
      cost_usd: totals["cost_usd"]
    }
  end

  defp normalize_actor(actor) do
    %{
      model_id: actor["model_id"],
      decisions: actor["decisions"] || 0,
      input_tokens: actor["input_tokens"] || 0,
      output_tokens: actor["output_tokens"] || 0,
      cache_read_tokens: actor["cache_read_tokens"] || 0,
      cache_write_tokens: actor["cache_write_tokens"] || 0,
      cost_usd: actor["cost_usd"]
    }
  end

  defp finalize_totals(totals, true), do: finalize_cost(totals)
  defp finalize_totals(totals, false), do: %{finalize_cost(totals) | cost_usd: nil}
  defp finalize_actor(actor), do: finalize_cost(actor)

  defp finalize_cost(%{cost_usd: nil} = usage), do: usage
  defp finalize_cost(%{cost_usd: cost} = usage), do: %{usage | cost_usd: Float.round(cost, 6)}

  defp pricing_known?(%Model{cost: %ModelCost{} = cost}) do
    Enum.any?([cost.input, cost.output, cost.cache_read, cost.cache_write], &(&1 > 0))
  end

  defp pricing_known?(_model), do: false

  defp model_id(%Model{} = model), do: "#{model.provider}:#{model.id || model.name}"

  defp normalize_actor_id(nil), do: "operator"
  defp normalize_actor_id(actor_id) when is_atom(actor_id), do: Atom.to_string(actor_id)
  defp normalize_actor_id(actor_id), do: to_string(actor_id)

  defp format_tokens(value) when value >= 1_000_000 do
    "#{Float.round(value / 1_000_000, 1)}m"
  end

  defp format_tokens(value) when value >= 1_000 do
    "#{Float.round(value / 1_000, 1)}k"
  end

  defp format_tokens(value), do: Integer.to_string(value)

  defp format_cost(value), do: :erlang.float_to_binary(value, decimals: 2)
end
