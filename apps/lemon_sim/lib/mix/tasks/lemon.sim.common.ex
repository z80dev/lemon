defmodule Mix.Tasks.Lemon.Sim.Common do
  @moduledoc false

  alias LemonSim.LLM.GameHelpers.Config

  @doc false
  @spec ensure_runtime_started!() :: :ok
  def ensure_runtime_started! do
    case Application.ensure_all_started(:lemon_sim) do
      {:ok, _started} -> :ok
      {:error, reason} -> Mix.raise("failed to start lemon_sim runtime: #{inspect(reason)}")
    end
  end

  @doc false
  @spec ensure_runtime_and_core_started() ::
          {:ok, [atom()]} | {:error, {atom(), term()}}
  def ensure_runtime_and_core_started do
    Application.ensure_all_started(:lemon_sim)
    Application.ensure_all_started(:lemon_core)
  end

  @doc false
  @spec resolve_model(nil | String.t()) :: LemonAi.Types.Model.t() | nil
  def resolve_model(nil), do: nil
  def resolve_model(""), do: nil

  def resolve_model(model_spec) when is_binary(model_spec) do
    trimmed = String.trim(model_spec)

    case String.split(trimmed, ":", parts: 2) do
      [provider, model_id] ->
        case resolve_provider(provider) do
          nil ->
            unknown_model!(provider, model_id)

          provider_atom ->
            LemonAi.Models.get_model(provider_atom, model_id) ||
              unknown_model!(provider, model_id)
        end

      [_model_id] ->
        LemonAi.Models.find_by_id(trimmed) || Mix.raise("unknown model #{inspect(trimmed)}")
    end
  end

  @doc false
  @spec resolve_provider(String.t()) :: atom() | nil
  def resolve_provider(provider) when is_binary(provider), do: Config.normalize_provider(provider)

  @doc false
  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp unknown_model!(provider, model_id) do
    Mix.raise("unknown model #{inspect(model_id)} for provider #{inspect(provider)}")
  end
end
