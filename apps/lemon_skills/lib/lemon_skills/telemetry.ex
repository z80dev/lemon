defmodule LemonSkills.Telemetry do
  @moduledoc false

  alias LemonCore.Introspection
  alias LemonCore.Telemetry

  @introspection_handler_id "lemon-skills-introspection-bridge"
  @skill_events [
    [:lemon_skills, :skill, :load],
    [:lemon_skills, :skill, :write],
    [:lemon_skills, :skill, :prompt_render]
  ]
  @max_reason_chars 500

  def skill_load(metadata) do
    emit([:lemon_skills, :skill, :load], metadata)
  end

  def skill_write(metadata) do
    emit([:lemon_skills, :skill, :write], metadata)
  end

  def skill_prompt_render(metadata) do
    emit([:lemon_skills, :skill, :prompt_render], metadata)
  end

  def attach_introspection_bridge(handler_id \\ @introspection_handler_id) do
    _ = :telemetry.detach(handler_id)

    :telemetry.attach_many(
      handler_id,
      @skill_events,
      &__MODULE__.handle_introspection_event/4,
      nil
    )
  end

  def handle_introspection_event([:lemon_skills, :skill, :load], _measurements, metadata, _config) do
    record_introspection(:skill_load_observed, metadata)
  end

  def handle_introspection_event(
        [:lemon_skills, :skill, :write],
        _measurements,
        metadata,
        _config
      ) do
    record_introspection(:skill_write_observed, metadata)
  end

  def handle_introspection_event(
        [:lemon_skills, :skill, :prompt_render],
        _measurements,
        metadata,
        _config
      ) do
    record_introspection(:skill_prompt_render_observed, metadata)
  end

  defp emit(event, metadata) do
    Telemetry.emit(event, %{count: 1, system_time: System.system_time()}, normalize(metadata))
  end

  defp normalize(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, normalize_value(key, value)} end)
  end

  defp normalize_value(:reason, value) do
    value
    |> to_string()
    |> String.slice(0, @max_reason_chars)
  end

  defp normalize_value(_key, value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(_key, value), do: value

  defp record_introspection(event_type, metadata) do
    record_usage(event_type, metadata)

    Introspection.record(
      event_type,
      Map.drop(metadata, [:run_id, :session_key, :session_id, :agent_id]),
      run_id: metadata[:run_id],
      session_key: metadata[:session_key] || metadata[:session_id],
      agent_id: metadata[:agent_id],
      engine: "lemon",
      provenance: :direct
    )
  end

  defp record_usage(:skill_load_observed, metadata), do: LemonSkills.Usage.record_load(metadata)
  defp record_usage(:skill_write_observed, metadata), do: LemonSkills.Usage.record_write(metadata)
  defp record_usage(_event_type, _metadata), do: :ok
end
