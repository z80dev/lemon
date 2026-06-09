defmodule LemonSim.GameHelpers.Config do
  @moduledoc false

  defdelegate resolve_configured_model!(config, game_name \\ "game"),
    to: LemonSim.LLM.GameHelpers.Config

  defdelegate resolve_provider_api_key!(provider, config, game_name \\ "game"),
    to: LemonSim.LLM.GameHelpers.Config

  defdelegate resolve_model_spec(provider, model_spec), to: LemonSim.LLM.GameHelpers.Config
  defdelegate lookup_model(provider, model_id), to: LemonSim.LLM.GameHelpers.Config
  defdelegate apply_provider_base_url(model, config), to: LemonSim.LLM.GameHelpers.Config
  defdelegate provider_name(provider), to: LemonSim.LLM.GameHelpers.Config
  defdelegate normalize_provider(provider_name), to: LemonSim.LLM.GameHelpers.Config
end
