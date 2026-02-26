defmodule LemonRouter.ModelSelection do
  @moduledoc """
  Resolves model + engine selection independently from profile binding.

  This module keeps profile defaults useful (engine, system prompt, tool policy)
  while allowing model selection to be overridden at request/session layers.

  Precedence (highest to lowest):

  - model: request-level explicit model -> meta model -> session model -> profile model -> router default model
  - engine: resume engine -> explicit engine_id -> model-implied engine -> profile default engine

  If an explicit `engine_id` conflicts with a model-implied engine, we keep the
  explicit engine (caller intent wins) and emit a warning.
  """

  @type t :: %{
          model: String.t() | nil,
          engine_id: String.t() | nil,
          model_engine: String.t() | nil,
          warning: String.t() | nil
        }

  @spec resolve(map()) :: t()
  def resolve(input) when is_map(input) do
    explicit_model = normalize_string(input[:explicit_model])
    meta_model = normalize_string(input[:meta_model])
    session_model = normalize_string(input[:session_model])
    profile_model = normalize_string(input[:profile_model])
    default_model = normalize_string(input[:default_model])

    explicit_engine_id = normalize_string(input[:explicit_engine_id])
    profile_default_engine = normalize_string(input[:profile_default_engine])
    resume_engine = normalize_string(input[:resume_engine])

    resolved_model =
      explicit_model || meta_model || session_model || profile_model || default_model

    model_engine = map_model_to_engine(resolved_model)

    warning =
      model_engine_mismatch_warning(
        explicit_engine_id,
        model_engine,
        resolved_model
      )

    engine_id =
      cond do
        is_binary(resume_engine) -> resume_engine
        is_binary(explicit_engine_id) -> explicit_engine_id
        is_binary(model_engine) -> model_engine
        is_binary(profile_default_engine) -> profile_default_engine
        true -> nil
      end

    %{
      model: resolved_model,
      engine_id: engine_id,
      model_engine: model_engine,
      warning: warning
    }
  end

  def resolve(_), do: %{model: nil, engine_id: nil, model_engine: nil, warning: nil}

  @doc false
  @spec map_model_to_engine(String.t() | nil) :: String.t() | nil
  def map_model_to_engine(model) when is_binary(model) do
    normalized = String.trim(model)

    cond do
      normalized == "" ->
        nil

      known_engine_id?(normalized) ->
        normalized

      true ->
        case String.split(normalized, ":", parts: 2) do
          [prefix, _rest] when is_binary(prefix) and byte_size(prefix) > 0 ->
            if known_engine_id?(prefix), do: normalized, else: nil

          _ ->
            nil
        end
    end
  end

  def map_model_to_engine(_), do: nil

  defp model_engine_mismatch_warning(nil, _model_engine, _resolved_model), do: nil
  defp model_engine_mismatch_warning(_explicit_engine, nil, _resolved_model), do: nil

  defp model_engine_mismatch_warning(explicit_engine, model_engine, resolved_model) do
    explicit_prefix = engine_prefix(explicit_engine)
    model_prefix = engine_prefix(model_engine)

    if explicit_prefix != model_prefix do
      "model #{inspect(resolved_model)} implies engine #{inspect(model_engine)} but explicit engine_id is #{inspect(explicit_engine)}"
    else
      nil
    end
  end

  defp engine_prefix(engine_id) when is_binary(engine_id) do
    engine_id
    |> String.trim()
    |> String.split(":", parts: 2)
    |> List.first()
    |> normalize_string()
  end

  defp engine_prefix(_), do: nil

  defp known_engine_id?(engine_id) when is_binary(engine_id) do
    case LemonGateway.EngineRegistry.get_engine(engine_id) do
      nil -> false
      _ -> true
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp known_engine_id?(_), do: false

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil
end
