defmodule LemonCli.Onboarding.Provider do
  @moduledoc false

  # `:device` is a headless device-code sign-in offered beside a browser `:oauth` flow.
  @type auth_mode :: :oauth | :device | :api_key | :codex_cli

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
    :base_url,
    local: false,
    custom: false,
    aliases: [],
    auth_modes: [:api_key],
    preferred_models: [],
    switches: [],
    auth_source_by_mode: %{},
    secret_config_key_by_mode: %{},
    # `:api_key` when the sign-in yields a durable API key rather than an OAuth payload.
    oauth_result: :secret
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
          base_url: String.t() | nil,
          local: boolean(),
          custom: boolean(),
          aliases: [String.t()],
          auth_modes: [auth_mode()],
          preferred_models: [String.t()],
          switches: keyword(),
          auth_source_by_mode: %{optional(auth_mode()) => String.t()},
          secret_config_key_by_mode: %{optional(auth_mode()) => String.t()},
          oauth_result: :secret | :api_key
        }

  @doc """
  Spec for a provider whose only sign-in is a pasted API key stored as
  `llm_<id>_api_key` and referenced from `[providers.<id>].api_key_secret`.
  """
  @spec api_key(String.t(), String.t(), String.t(), keyword()) :: t()
  def api_key(id, display_name, description, opts \\ []) do
    %__MODULE__{
      id: id,
      display_name: display_name,
      description: description,
      provider_table: "providers.#{id}",
      default_secret_name: "llm_#{id}_api_key",
      api_key_secret_provider: "onboarding_#{id}",
      auth_modes: [:api_key],
      default_auth_mode: :api_key,
      aliases: Keyword.get(opts, :aliases, []),
      preferred_models: Keyword.get(opts, :preferred_models, []),
      api_key_prompt: "Enter your #{display_name} API key: ",
      api_key_choice_label: "Paste API key",
      auth_source_by_mode: %{api_key: "api_key"}
    }
  end

  @doc false
  def local(id, display_name, opts \\ []) do
    spec = api_key(id, display_name, "Local OpenAI-compatible server", opts)

    %{
      spec
      | local: true,
        custom: Keyword.get(opts, :custom, false),
        base_url: Keyword.get(opts, :base_url)
    }
  end
end
