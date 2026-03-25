defmodule LemonAiRuntime do
  @moduledoc """
  Lemon-owned AI runtime boundary.

  This app is the Lemon-owned boundary for AI auth, credential resolution, and
  provider-specific stream option shaping during the extraction from `apps/ai`.
  """

  alias Ai.Types.StreamOptions

  @spec build_get_api_key(map() | nil) :: (atom() | String.t() -> String.t() | nil)
  defdelegate build_get_api_key(providers_map), to: LemonAiRuntime.Credentials

  @spec resolve_provider_api_key(atom() | String.t(), map() | nil, keyword()) :: String.t() | nil
  defdelegate resolve_provider_api_key(provider, providers_or_cfg, opts \\ []),
    to: LemonAiRuntime.Credentials

  @spec resolve_secret_api_key(String.t(), keyword()) :: String.t() | nil
  defdelegate resolve_secret_api_key(secret_name, opts \\ []),
    to: LemonAiRuntime.Credentials

  @spec provider_has_credentials?(atom() | String.t(), map() | nil, keyword()) :: boolean()
  defdelegate provider_has_credentials?(provider, providers_map_or_cfg, opts \\ []),
    to: LemonAiRuntime.Credentials

  @spec build_stream_options(Ai.Types.Model.t(), map() | nil, map() | StreamOptions.t() | nil, String.t() | nil) ::
          StreamOptions.t()
  defdelegate build_stream_options(model, providers_map, existing_opts, cwd),
    to: LemonAiRuntime.StreamOptions
end
