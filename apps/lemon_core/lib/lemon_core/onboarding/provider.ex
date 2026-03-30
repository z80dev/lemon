defmodule LemonCore.Onboarding.Provider do
  @moduledoc false

  @type auth_mode :: :oauth | :api_key

  @enforce_keys [
    :id,
    :display_name,
    :provider_table,
    :default_secret_name,
    :api_key_secret_provider
  ]
  defstruct [
    :id,
    :display_name,
    :description,
    :provider_table,
    :default_secret_name,
    :default_secret_name_by_mode,
    :api_key_secret_provider,
    :oauth_secret_provider,
    :oauth_module,
    :default_auth_mode,
    :oauth_opts_builder,
    :oauth_missing_hint,
    :oauth_failure_label,
    :token_resolution_hint,
    :api_key_prompt,
    :api_key_choice_label,
    :oauth_choice_label,
    aliases: [],
    auth_modes: [:api_key],
    preferred_models: [],
    switches: [],
    auth_source_by_mode: %{},
    secret_config_key_by_mode: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          display_name: String.t(),
          description: String.t() | nil,
          provider_table: String.t(),
          default_secret_name: String.t(),
          default_secret_name_by_mode: %{optional(auth_mode()) => String.t()} | nil,
          api_key_secret_provider: String.t(),
          oauth_secret_provider: String.t() | nil,
          oauth_module: module() | nil,
          default_auth_mode: auth_mode() | nil,
          oauth_opts_builder: (keyword() -> keyword()) | nil,
          oauth_missing_hint: String.t() | nil,
          oauth_failure_label: String.t() | nil,
          token_resolution_hint: String.t() | nil,
          api_key_prompt: String.t() | nil,
          api_key_choice_label: String.t() | nil,
          oauth_choice_label: String.t() | nil,
          aliases: [String.t()],
          auth_modes: [auth_mode()],
          preferred_models: [String.t()],
          switches: keyword(),
          auth_source_by_mode: %{optional(auth_mode()) => String.t()},
          secret_config_key_by_mode: %{optional(auth_mode()) => String.t()}
        }
end
