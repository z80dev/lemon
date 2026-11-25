defmodule LemonCore.Config.Validator do
  @moduledoc """
  Validation utilities for Lemon configuration.

  Provides functions to validate configuration values and return detailed
  error messages for invalid configurations.

  ## Usage

      config = LemonCore.Config.Modular.load()
      case LemonCore.Config.Validator.validate(config) do
        :ok -> config
        {:error, errors} -> handle_errors(errors)
      end

  ## Validation Rules

  - Agent: valid model names, provider names
  - Gateway: valid port numbers, boolean flags
  - Channels: each registered `LemonCore.Config.Gateway.Channel` validates its
    own `[gateway.<id>]` section, so platform-specific rules (token formats,
    id lists, per-platform limits) live with the app that implements them
  - Web Dashboard: port, host, secret key base, access token
  - Email: SMTP relay, inbound webhook, TLS/auth settings
  - Logging: valid log levels, writable paths
  - Providers: valid API key formats
  - Tools: valid timeout values
  - TUI: a non-blank theme name (the terminal client owns the names)

  The generic scalar checks (`validate_boolean/3`, `validate_positive_integer/3`,
  `validate_ratio/3`, `env_var_reference?/1`, ...) are public so channel
  implementations produce messages in the same shape.
  """

  alias LemonCore.Config.{Automation, Features, LegacyAgentMigration, Memory, Modular, Providers}
  alias LemonCore.Config.Gateway.Channel
  alias LemonCore.Config.Tools.Bash

  @valid_log_levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]
  @doc """
  Validates a complete modular configuration.

  Returns `:ok` if valid, or `{:error, errors}` with a list of validation errors.

  ## Examples

      iex> Validator.validate(config)
      :ok

      iex> Validator.validate(invalid_config)
      {:error, [
        "agent.default_model: cannot be empty",
        "gateway.web_port: must be between 1 and 65535"
      ]}
  """
  @spec validate(Modular.t() | LemonCore.Config.t()) :: :ok | {:error, [String.t()]}
  def validate(%Modular{} = config) do
    errors = []
    errors = model_role_errors(config.model_roles) ++ errors
    errors = budget_errors(config.budgets) ++ errors
    errors = validate_agent(config.agent, errors)
    errors = validate_gateway(config.gateway, errors)
    errors = validate_logging(config.logging, errors)
    errors = validate_providers(config.providers, errors)
    errors = validate_secrets(config.secrets, errors)
    errors = validate_tools(config.tools, errors)
    errors = validate_tui(config.tui, errors)
    errors = validate_features(config.features, errors)
    errors = validate_memory(config.memory, errors)

    errors =
      validate_write_approval(errors, config.skills.write_approval, "skills.write_approval")

    errors =
      validate_private_git_hosts(
        errors,
        Map.get(config.skills, :allowed_private_git_hosts, []),
        "skills.allowed_private_git_hosts"
      )

    errors = validate_learning_nudge(errors, Map.get(config.skills, :learning_nudge, %{}))

    errors = validate_automation(config.automation, errors)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(%LemonCore.Config{} = config) do
    errors = []
    errors = model_role_errors(config.model_roles) ++ errors
    errors = budget_errors(config.budgets) ++ errors
    errors = validate_agent(config.agent, errors)
    errors = validate_gateway(config.gateway, errors)
    errors = validate_logging(config.logging, errors)
    errors = validate_legacy_providers(config.providers, errors)
    errors = validate_tui(config.tui, errors)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  @doc "Validates the canonical string-valued model role table without provider dependencies."
  @spec validate_model_roles(term()) :: :ok | {:error, [String.t()]}
  def validate_model_roles(roles), do: errors_to_result(model_role_errors(roles))

  @doc "Validates optional cumulative token and estimated dollar caps; zero blocks requests."
  def validate_budgets(budgets), do: errors_to_result(budget_errors(budgets))

  defp budget_errors(budgets) when is_map(budgets) do
    Enum.flat_map(
      [:max_run_tokens, :max_run_cost_usd, :max_session_tokens, :max_session_cost_usd],
      fn key ->
        value = Map.get(budgets, key)
        tokens? = key in [:max_run_tokens, :max_session_tokens]

        cond do
          is_nil(value) -> []
          tokens? and is_integer(value) and value >= 0 -> []
          not tokens? and is_number(value) and value >= 0 -> []
          tokens? -> ["budgets.#{key}: must be a nonnegative integer"]
          true -> ["budgets.#{key}: must be a finite nonnegative number"]
        end
      end
    )
  end

  defp budget_errors(_budgets), do: ["budgets: must be a table"]

  defp model_role_errors(roles) when is_map(roles) do
    Enum.flat_map(roles, fn {role, selector} ->
      cond do
        not is_binary(role) or role == "" or String.contains?(role, "@") or
            String.match?(role, ~r/\s/u) ->
          ["model_roles: keys must be non-empty role names without @ or whitespace"]

        not is_binary(selector) or String.trim(selector) == "" ->
          ["model_roles.#{role}: must be a non-empty model selector string"]

        true ->
          []
      end
    end)
  end

  defp model_role_errors(_), do: ["model_roles: must be a table of model selector strings"]

  @doc """
  Validates settings for removed configuration sections and engine-routing keys,
  returning an ok/error tuple.

  The legacy `[agent]` table is not an error: loaders map it onto the canonical
  sections with `LemonCore.Config.LegacyAgentMigration` first and report it
  through `deprecation_warnings/1`.

  Returns `:ok` if no removed settings are found, or `{:error, errors}`.
  """
  @spec validate_deprecated_sections(map()) :: :ok | {:error, [String.t()]}
  def validate_deprecated_sections(settings) when is_map(settings) do
    deprecated_errors =
      []
      |> check_deprecated(
        is_map(settings["agents"]),
        "[agents.<id>] is deprecated. Use [profiles.<id>] instead."
      )
      |> check_deprecated(
        is_map(settings["tools"]),
        "[tools.*] is deprecated. Use [runtime.tools.*] instead."
      )
      |> check_deprecated(
        runtime_cli_present?(settings),
        "The [runtime.cli] section has been removed; all subagent tasks run natively."
      )
      |> Enum.reverse()

    (deprecated_errors ++ removed_engine_config_errors(settings))
    |> errors_to_result()
  end

  @doc """
  Returns non-fatal warnings for legacy settings that still load.
  """
  @spec deprecation_warnings(map()) :: [String.t()]
  def deprecation_warnings(settings) when is_map(settings) do
    legacy_agent =
      if LegacyAgentMigration.legacy?(settings) do
        [
          "[agent] is deprecated and is read as [defaults], [runtime] and [tui]. " <>
            "Run `lemon config migrate` to rewrite it (the original is kept as a backup)."
        ]
      else
        []
      end

    legacy_agent ++ removed_gateway_queue_warnings(settings)
  end

  # Nothing ever read `[gateway.queue]`; it is ignored rather than rejected so
  # existing configs keep loading.
  defp removed_gateway_queue_warnings(%{"gateway" => %{"queue" => _}}),
    do: ["[gateway.queue] has no effect and was removed; delete the section."]

  defp removed_gateway_queue_warnings(_settings), do: []

  @removed_engine_keys ~w(
    engine
    default_engine
    engine_preference
    preferred_engine
    preferred_engines
    preferred-engine
    preferred-engines
    preferredEngine
    preferredEngines
    known_engine
    known_engines
    custom_engine
    custom_engines
    engine_registry
    engine_module
    engine_modules
    engines
    gateway_engines
  )

  defp removed_engine_config_errors(settings) do
    settings
    |> collect_removed_engine_config_errors([], [])
    |> Enum.reverse()
  end

  defp collect_removed_engine_config_errors(settings, path, errors) when is_map(settings) do
    settings
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.reduce(errors, fn {key, value}, errors ->
      key = to_string(key)
      current_path = path ++ [key]

      cond do
        key in @removed_engine_keys ->
          [removed_engine_config_message(format_config_path(current_path)) | errors]

        true ->
          collect_removed_engine_config_errors(value, current_path, errors)
      end
    end)
  end

  defp collect_removed_engine_config_errors(settings, path, errors) when is_list(settings) do
    settings
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {value, index}, errors ->
      collect_removed_engine_config_errors(value, path ++ [index], errors)
    end)
  end

  defp collect_removed_engine_config_errors(_settings, _path, errors), do: errors

  defp format_config_path(path) do
    Enum.reduce(path, "", fn
      index, "" when is_integer(index) -> "[#{index}]"
      index, path when is_integer(index) -> "#{path}[#{index}]"
      key, "" -> key
      key, path -> "#{path}.#{key}"
    end)
  end

  defp removed_engine_config_message(path) do
    "#{path} is no longer supported. Lemon runs natively; remove this engine-routing setting."
  end

  defp runtime_cli_present?(%{"runtime" => runtime}) when is_map(runtime),
    do: Map.has_key?(runtime, "cli")

  defp runtime_cli_present?(_settings), do: false

  defp check_deprecated(errors, true, message), do: [message | errors]
  defp check_deprecated(errors, false, _message), do: errors

  defp errors_to_result([]), do: :ok
  defp errors_to_result(errors), do: {:error, errors}

  @doc """
  Validates agent configuration.
  """
  @spec validate_agent(map(), [String.t()]) :: [String.t()]
  def validate_agent(agent, errors) do
    errors
    |> validate_non_empty_string(Map.get(agent, :default_model), "agent.default_model")
    |> validate_non_empty_string(Map.get(agent, :default_provider), "agent.default_provider")
    |> validate_custom_enum(
      Map.get(agent, :default_thinking_level),
      "defaults.thinking_level",
      &(&1 in [
          "off",
          "minimal",
          "low",
          "medium",
          "high",
          "xhigh",
          "auto",
          :off,
          :minimal,
          :low,
          :medium,
          :high,
          :xhigh,
          :auto
        ]),
      "off | minimal | low | medium | high | xhigh | auto"
    )
    |> validate_task_config(Map.get(agent, :task))
    |> validate_compaction_thresholds(Map.get(agent, :compaction))
    |> validate_git_path(Map.get(agent, :git_path))
    |> validate_max_tool_turns(Map.get(agent, :max_tool_turns, :infinity))
  end

  defp validate_max_tool_turns(errors, :infinity), do: errors
  defp validate_max_tool_turns(errors, turns) when is_integer(turns) and turns > 0, do: errors

  defp validate_max_tool_turns(errors, _turns) do
    ["runtime.max_tool_turns: must be a non-negative integer (0 or unset = unlimited)" | errors]
  end

  @doc """
  Validates the raw `[profiles.<id>]` tables: a `tool_policy` or
  `tool_policy_json` that does not parse is an error rather than a silent
  `deny_all` policy. Returns the error list (empty when valid).
  """
  @spec profile_errors(map()) :: [String.t()]
  def profile_errors(settings) when is_map(settings) do
    case settings["profiles"] do
      nil ->
        []

      profiles when is_map(profiles) ->
        profiles
        |> Enum.sort_by(fn {id, _cfg} -> to_string(id) end)
        |> Enum.flat_map(fn {id, cfg} -> profile_policy_errors(to_string(id), cfg) end)

      _ ->
        ["profiles: must be a table"]
    end
  end

  defp profile_policy_errors(id, cfg) when is_map(cfg) do
    cond do
      Map.has_key?(cfg, "tool_policy_json") ->
        tool_policy_json_errors(id, cfg["tool_policy_json"])

      is_nil(cfg["tool_policy"]) ->
        []

      true ->
        tool_policy_errors(id, "tool_policy", cfg["tool_policy"])
    end
  end

  defp profile_policy_errors(id, _cfg), do: ["profiles.#{id}: must be a table"]

  defp tool_policy_json_errors(id, json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, policy} when is_map(policy) -> tool_policy_errors(id, "tool_policy_json", policy)
      _ -> ["profiles.#{id}.tool_policy_json: must be a JSON tool policy object"]
    end
  end

  defp tool_policy_json_errors(id, _json),
    do: ["profiles.#{id}.tool_policy_json: must be a JSON tool policy object"]

  defp tool_policy_errors(id, key, policy) do
    case LemonCore.ToolPolicy.parse(policy) do
      {:ok, _policy} -> []
      {:error, reason} -> ["profiles.#{id}.#{key}: invalid tool policy (#{inspect(reason)})"]
    end
  end

  defp validate_git_path(errors, nil), do: errors

  defp validate_git_path(errors, path) do
    if is_binary(path) and Path.type(path) == :absolute,
      do: errors,
      else: ["runtime.git_path: must be an absolute executable path" | errors]
  end

  defp validate_compaction_thresholds(errors, %{} = compaction) do
    percent = Map.get(compaction, :threshold_percent)

    errors =
      if is_nil(percent) or (is_integer(percent) and percent in 1..100),
        do: errors,
        else: ["agent.compaction.threshold_percent: must be an integer from 1 to 100" | errors]

    validate_positive_integer(
      errors,
      Map.get(compaction, :threshold_tokens),
      "agent.compaction.threshold_tokens"
    )
  end

  defp validate_compaction_thresholds(errors, _compaction), do: errors

  defp validate_task_config(errors, nil), do: errors

  defp validate_task_config(errors, task) when is_map(task) do
    max_depth = Map.get(task, :max_depth)
    max_runtime_ms = Map.get(task, :max_runtime_ms)
    idle_ttl_ms = Map.get(task, :idle_ttl_ms)
    request_budget = Map.get(task, :request_budget)
    request_budget_notice = Map.get(task, :request_budget_notice)
    speculative_launch = Map.get(task, :speculative_launch)
    merge = Map.get(task, :worktree_merge)
    disabled = Map.get(task, :disabled_agents)
    models = Map.get(task, :agent_models)
    per_call_model = Map.get(task, :per_call_model, "off")
    per_call_allow = Map.get(task, :per_call_model_allow)

    [
      {is_integer(max_depth) and max_depth >= -1,
       "runtime.task.max_depth: must be an integer >= -1"},
      {is_integer(max_runtime_ms) and max_runtime_ms >= 0,
       "runtime.task.max_runtime_ms: must be a nonnegative integer"},
      {is_integer(idle_ttl_ms) and idle_ttl_ms >= 0,
       "runtime.task.idle_ttl_ms: must be a nonnegative integer"},
      {is_integer(request_budget) and request_budget >= 0,
       "runtime.task.request_budget: must be a nonnegative integer"},
      {is_boolean(request_budget_notice),
       "runtime.task.request_budget_notice: must be a boolean"},
      {is_boolean(speculative_launch), "runtime.task.speculative_launch: must be a boolean"},
      {merge in ["none", "patch", "branch"],
       "runtime.task.worktree_merge: must be one of none, patch, branch"},
      {is_list(disabled) and Enum.all?(disabled, &(is_binary(&1) and &1 != "")),
       "runtime.task.disabled_agents: must be a list of persona IDs"},
      {is_map(models) and
         Enum.all?(models, fn {id, model} ->
           is_binary(id) and is_binary(model) and String.trim(model) != ""
         end), "runtime.task.agent_models: must map persona IDs to model strings"},
      {per_call_model in ["off", "on"], "runtime.task.per_call_model: must be off or on"},
      {is_nil(per_call_allow) or
         (is_list(per_call_allow) and Enum.all?(per_call_allow, &per_call_model_selector?/1)),
       "runtime.task.per_call_model_allow: must be a list of \"provider/model\" or \"@role\" strings"}
    ]
    |> Enum.reduce(errors, fn
      {true, _message}, acc -> acc
      {false, message}, acc -> [message | acc]
    end)
  end

  defp validate_task_config(errors, _task), do: ["runtime.task: must be a table" | errors]

  defp per_call_model_selector?(value) when is_binary(value),
    do: Regex.match?(~r{\A(@[^@\s/]+|[^\s/@]+/\S+)\z}u, String.trim(value))

  defp per_call_model_selector?(_value), do: false

  @doc """
  Validates gateway configuration.

  Per-platform sections are validated by the modules registered under
  `config :lemon_core, :gateway_channels`; see
  `LemonCore.Config.Gateway.Channel`.
  """
  @spec validate_gateway(map(), [String.t()]) :: [String.t()]
  def validate_gateway(gateway, errors) do
    errors
    |> validate_positive_integer(
      Map.get(gateway, :max_concurrent_runs),
      "gateway.max_concurrent_runs"
    )
    |> validate_boolean(Map.get(gateway, :auto_resume), "gateway.auto_resume")
    |> validate_boolean(Map.get(gateway, :enable_webhook), "gateway.enable_webhook")
    |> validate_ingress(Map.get(gateway, :ingress))
    |> validate_channel_flags(gateway)
    |> validate_channel_sections(gateway)
    |> validate_email_config(Map.get(gateway, :email))
    |> validate_sms_config(Map.get(gateway, :sms))
    |> validate_voice_config(Map.get(gateway, :voice))
    |> validate_webhook_section(Map.get(gateway, :webhook))
  end

  defp validate_ingress(errors, nil), do: errors

  defp validate_ingress(errors, ingress) when is_map(ingress) do
    errors = validate_boolean(errors, toml_value(ingress, :enabled), "gateway.ingress.enabled")

    if Enum.all?(Map.keys(ingress), &(&1 in [:enabled, "enabled"])),
      do: errors,
      else: ["gateway.ingress: only the enabled key is supported" | errors]
  end

  defp validate_ingress(errors, _), do: ["gateway.ingress: must be a table" | errors]

  defp validate_webhook_section(errors, webhook) when is_nil(webhook) or is_map(webhook),
    do: errors

  defp validate_webhook_section(errors, _webhook), do: ["gateway.webhook: must be a map" | errors]

  # `Modular` keeps the flags in `enabled_channels`; the legacy map flattens
  # them to `enable_<id>`. Both shapes are validated by asking the registered
  # channels for their ids rather than by naming a platform here.
  defp validate_channel_flags(errors, gateway) do
    enabled = Map.get(gateway, :enabled_channels)

    Enum.reduce(Channel.ids(), errors, fn id, acc ->
      value =
        if is_map(enabled),
          do: Map.get(enabled, id),
          else: Map.get(gateway, :"enable_#{id}")

      validate_boolean(acc, value, "gateway.enable_#{id}")
    end)
  end

  defp validate_channel_sections(errors, gateway) do
    sections = Map.get(gateway, :channels)

    Enum.reduce(Channel.registered(), errors, fn module, acc ->
      id = module.id()

      case section_value(sections, gateway, id) do
        nil ->
          acc

        section when is_map(section) ->
          acc
          |> then(&module.validate(section, &1))
          |> validate_voice_replies(section[:voice_replies], "gateway.#{id}.voice_replies")

        _ ->
          ["gateway.#{id}: must be a map" | acc]
      end
    end)
  end

  defp validate_voice_replies(errors, nil, _path), do: errors

  defp validate_voice_replies(errors, replies, path) when is_map(replies) do
    errors = validate_boolean(errors, replies[:enabled], "#{path}.enabled")

    price = replies[:price_per_million_characters]

    errors =
      if is_nil(price) or (is_number(price) and price >= 0),
        do: errors,
        else: ["#{path}.price_per_million_characters: must be a non-negative number" | errors]

    Enum.reduce([:provider, :model, :base_url, :api_key, :api_key_secret, :voice], errors, fn key,
                                                                                              acc ->
      validate_non_empty_string(acc, replies[key], "#{path}.#{key}")
    end)
  end

  defp validate_voice_replies(errors, _replies, path),
    do: ["#{path}: must be a map" | errors]

  defp section_value(sections, _gateway, id) when is_map(sections), do: Map.get(sections, id)
  defp section_value(_sections, gateway, id), do: Map.get(gateway, id)

  @doc """
  Validates `[gateway.sms]`: the fields `LemonGateway.Sms.Config` reads.

  The section keeps TOML's string keys, so each field is read as an atom key
  first and then as its string form.
  """
  @spec validate_sms_config([String.t()], map() | nil) :: [String.t()]
  def validate_sms_config(errors, nil), do: errors

  def validate_sms_config(errors, sms) when is_map(sms) do
    errors =
      errors
      |> validate_boolean(toml_value(sms, :webhook_enabled), "gateway.sms.webhook_enabled")
      |> validate_port(toml_value(sms, :webhook_port), "gateway.sms.webhook_port")
      |> validate_positive_integer(toml_value(sms, :inbox_ttl_ms), "gateway.sms.inbox_ttl_ms")
      |> validate_positive_integer(
        toml_value(sms, :handoff_grace_ms),
        "gateway.sms.handoff_grace_ms"
      )
      |> validate_absolute_url(toml_value(sms, :webhook_url), "gateway.sms.webhook_url", [
        "http",
        "https"
      ])

    Enum.reduce(
      [:webhook_bind, :inbox_number, :auth_token, :auth_token_secret],
      errors,
      &validate_optional_string(&2, toml_value(sms, &1), "gateway.sms.#{&1}")
    )
  end

  def validate_sms_config(errors, _), do: ["gateway.sms: must be a map" | errors]

  @voice_string_fields [
    :twilio_account_sid,
    :twilio_account_sid_secret,
    :twilio_auth_token,
    :twilio_auth_token_secret,
    :twilio_phone_number,
    :deepgram_api_key,
    :deepgram_api_key_secret,
    :elevenlabs_api_key,
    :elevenlabs_api_key_secret,
    :elevenlabs_voice_id,
    :elevenlabs_output_format,
    :llm_model,
    :system_prompt
  ]

  @doc """
  Validates `[gateway.voice]`: the fields `LemonGateway.Voice.Config` reads.

  `public_url` is where Twilio is told to open the call's media stream, so it
  must be an absolute `https` URL.
  """
  @spec validate_voice_config([String.t()], map() | nil) :: [String.t()]
  def validate_voice_config(errors, nil), do: errors

  def validate_voice_config(errors, voice) when is_map(voice) do
    errors =
      errors
      |> validate_boolean(toml_value(voice, :enabled), "gateway.voice.enabled")
      |> validate_port(toml_value(voice, :websocket_port), "gateway.voice.websocket_port")
      |> validate_absolute_url(toml_value(voice, :public_url), "gateway.voice.public_url", [
        "https"
      ])
      |> validate_positive_integer(
        toml_value(voice, :max_call_duration_seconds),
        "gateway.voice.max_call_duration_seconds"
      )
      |> validate_positive_integer(
        toml_value(voice, :silence_timeout_ms),
        "gateway.voice.silence_timeout_ms"
      )

    Enum.reduce(
      @voice_string_fields,
      errors,
      &validate_optional_string(&2, toml_value(voice, &1), "gateway.voice.#{&1}")
    )
  end

  def validate_voice_config(errors, _), do: ["gateway.voice: must be a map" | errors]

  # Validates the exact value the consumer receives: no trimming, and the
  # scheme must appear literally (lowercase) because consumers build URLs from
  # the raw string.
  defp validate_absolute_url(errors, nil, _path, _schemes), do: errors

  defp validate_absolute_url(errors, value, path, schemes) when is_binary(value) do
    literal_scheme? = Enum.any?(schemes, &String.starts_with?(value, &1 <> "://"))

    case literal_scheme? && URI.new(value) do
      {:ok, %URI{host: host, userinfo: nil}} when is_binary(host) and host != "" ->
        errors

      _ ->
        ["#{path}: must be an absolute #{Enum.join(schemes, " or ")} URL" | errors]
    end
  end

  defp validate_absolute_url(errors, _value, path, _schemes),
    do: ["#{path}: must be a string" | errors]

  # Optional free-form string field: nil, or a non-blank binary. Unlike
  # `validate_non_empty_string/3` it does not accept atoms (TOML booleans).
  defp validate_optional_string(errors, nil, _path), do: errors

  defp validate_optional_string(errors, value, path) when is_binary(value) do
    if String.trim(value) == "", do: ["#{path}: cannot be empty" | errors], else: errors
  end

  defp validate_optional_string(errors, _value, path),
    do: ["#{path}: must be a string" | errors]

  @doc """
  Validates Email configuration.

  The `email` section is resolved as a passthrough, so its nested `inbound`
  and `outbound` tables keep TOML's string keys while hand-built maps use
  atoms. Every lookup here reads both forms (atom first, as the email adapter
  does), so no field escapes validation because of how it was keyed.

  The fields checked are the ones `LemonChannels.Adapters.Email` reads,
  including the flat `smtp_*` aliases it falls back to. `tls` and `auth`
  accept only the modes the adapter honors; any other string would be
  silently replaced by the adapter's default (opportunistic TLS).
  """
  @spec validate_email_config([String.t()], map() | nil) :: [String.t()]
  def validate_email_config(errors, nil), do: errors

  def validate_email_config(errors, email) when is_map(email) do
    errors
    |> validate_email_inbound_config(toml_value(email, :inbound))
    |> validate_email_outbound_config(toml_value(email, :outbound))
    |> validate_positive_integer(
      toml_value(email, :attachment_max_bytes),
      "gateway.email.attachment_max_bytes"
    )
    |> validate_boolean(toml_value(email, :inbound_enabled), "gateway.email.inbound_enabled")
    |> validate_boolean(toml_value(email, :webhook_enabled), "gateway.email.webhook_enabled")
    |> validate_port(toml_value(email, :webhook_port), "gateway.email.webhook_port")
    |> validate_optional_string(toml_value(email, :webhook_bind), "gateway.email.webhook_bind")
    |> validate_optional_string(toml_value(email, :webhook_path), "gateway.email.webhook_path")
    |> validate_optional_string(
      toml_value(email, :webhook_token),
      "gateway.email.webhook_token"
    )
    |> validate_email_smtp_fields(email, "gateway.email", %{
      relay: :smtp_relay,
      port: :smtp_port,
      username: :smtp_username,
      password: :smtp_password,
      tls: :smtp_tls,
      auth: :smtp_auth,
      ssl: :smtp_ssl,
      hostname: :smtp_hostname,
      timeout: :smtp_timeout,
      tls_versions: :smtp_tls_versions
    })
    |> validate_optional_string(toml_value(email, :relay), "gateway.email.relay")
    |> validate_optional_string(toml_value(email, :from), "gateway.email.from")
    |> validate_optional_string(toml_value(email, :reply_to), "gateway.email.reply_to")
  end

  def validate_email_config(errors, _),
    do: ["gateway.email: must be a map" | errors]

  defp validate_email_inbound_config(errors, nil), do: errors

  defp validate_email_inbound_config(errors, inbound) when is_map(inbound) do
    errors
    |> validate_boolean(toml_value(inbound, :enabled), "gateway.email.inbound.enabled")
    |> validate_optional_string(toml_value(inbound, :bind), "gateway.email.inbound.bind")
    |> validate_port(toml_value(inbound, :port), "gateway.email.inbound.port")
    |> validate_optional_string(toml_value(inbound, :path), "gateway.email.inbound.path")
    |> validate_optional_string(toml_value(inbound, :token), "gateway.email.inbound.token")
    |> validate_email_allowed_senders(toml_value(inbound, :allowed_senders))
    |> validate_email_authserv_id(toml_value(inbound, :authserv_id))
    |> validate_email_sender_auth(toml_value(inbound, :sender_auth))
  end

  defp validate_email_inbound_config(errors, _),
    do: ["gateway.email.inbound: must be a map" | errors]

  defp validate_email_sender_auth(errors, value)
       when value in [nil, "authentication_results", "from_only_unsafe"],
       do: errors

  defp validate_email_sender_auth(errors, _value),
    do: [
      "gateway.email.inbound.sender_auth: invalid value. Valid: authentication_results, from_only_unsafe"
      | errors
    ]

  defp toml_value(map, key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp validate_email_allowed_senders(errors, nil), do: errors

  defp validate_email_allowed_senders(errors, senders) when is_list(senders) do
    if Enum.all?(senders, &bare_email_address?/1) do
      errors
    else
      [
        "gateway.email.inbound.allowed_senders: must be a list of bare email addresses (user@domain)"
        | errors
      ]
    end
  end

  defp validate_email_allowed_senders(errors, _senders),
    do: ["gateway.email.inbound.allowed_senders: must be a list of email addresses" | errors]

  defp bare_email_address?(value) when is_binary(value),
    do: Regex.match?(~r/\A[^@\s<>"(),;]+@[^@\s<>"(),;]+\z/, String.trim(value))

  defp bare_email_address?(_value), do: false

  defp validate_email_authserv_id(errors, nil), do: errors

  defp validate_email_authserv_id(errors, value) when is_binary(value) do
    if String.trim(value) == "" or String.match?(String.trim(value), ~r/[\s;()"]/) do
      ["gateway.email.inbound.authserv_id: must be a single authserv-id token" | errors]
    else
      errors
    end
  end

  defp validate_email_authserv_id(errors, _value),
    do: ["gateway.email.inbound.authserv_id: must be a string" | errors]

  defp validate_email_outbound_config(errors, nil), do: errors

  defp validate_email_outbound_config(errors, outbound) when is_map(outbound) do
    errors
    |> validate_email_smtp_fields(outbound, "gateway.email.outbound", %{
      relay: :relay,
      port: :port,
      username: :username,
      password: :password,
      tls: :tls,
      auth: :auth,
      ssl: :ssl,
      hostname: :hostname,
      timeout: :timeout,
      tls_versions: :tls_versions
    })
    |> validate_optional_string(toml_value(outbound, :from), "gateway.email.outbound.from")
    |> validate_optional_string(
      toml_value(outbound, :reply_to),
      "gateway.email.outbound.reply_to"
    )
  end

  defp validate_email_outbound_config(errors, _),
    do: ["gateway.email.outbound: must be a map" | errors]

  # The SMTP settings exist both nested under `outbound` and as flat `smtp_*`
  # aliases on the email table; `keys` maps each setting to its key in `map`.
  defp validate_email_smtp_fields(errors, map, prefix, keys) do
    value = fn name -> toml_value(map, Map.fetch!(keys, name)) end
    path = fn name -> "#{prefix}.#{Map.fetch!(keys, name)}" end

    errors
    |> validate_optional_string(value.(:relay), path.(:relay))
    |> validate_port(value.(:port), path.(:port))
    |> validate_optional_string(value.(:username), path.(:username))
    |> validate_optional_string(value.(:password), path.(:password))
    |> validate_email_smtp_mode(value.(:tls), path.(:tls))
    |> validate_email_smtp_mode(value.(:auth), path.(:auth))
    |> validate_boolean(value.(:ssl), path.(:ssl))
    |> validate_optional_string(value.(:hostname), path.(:hostname))
    |> validate_positive_integer(value.(:timeout), path.(:timeout))
    |> validate_email_tls_versions(value.(:tls_versions), path.(:tls_versions))
  end

  @email_smtp_modes ["always", "never", "if_available"]

  defp validate_email_smtp_mode(errors, nil, _path), do: errors

  defp validate_email_smtp_mode(errors, mode, _path)
       when mode in [:always, :never, :if_available],
       do: errors

  defp validate_email_smtp_mode(errors, mode, path) when is_binary(mode) do
    if String.downcase(String.trim(mode)) in @email_smtp_modes do
      errors
    else
      ["#{path}: invalid value '#{mode}'. Valid: #{Enum.join(@email_smtp_modes, ", ")}" | errors]
    end
  end

  defp validate_email_smtp_mode(errors, _mode, path),
    do: ["#{path}: must be one of: #{Enum.join(@email_smtp_modes, ", ")}" | errors]

  @email_tls_versions ["tlsv1", "tlsv1.1", "tlsv1.2", "tlsv1.3"]

  defp validate_email_tls_versions(errors, nil, _path), do: errors

  defp validate_email_tls_versions(errors, versions, path)
       when is_list(versions) and versions != [] do
    if Enum.all?(
         versions,
         &(is_binary(&1) and String.downcase(String.trim(&1)) in @email_tls_versions)
       ) do
      errors
    else
      ["#{path}: must list only #{Enum.join(@email_tls_versions, ", ")}" | errors]
    end
  end

  defp validate_email_tls_versions(errors, _versions, path),
    do: ["#{path}: must be a non-empty list of TLS versions" | errors]

  defp validate_port(errors, nil, _path), do: errors

  defp validate_port(errors, port, path) when is_integer(port) do
    if port > 0 and port <= 65_535 do
      errors
    else
      ["#{path}: must be between 1 and 65535" | errors]
    end
  end

  defp validate_port(errors, _port, path) do
    ["#{path}: must be an integer" | errors]
  end

  @doc """
  Validates logging configuration.
  """
  @spec validate_logging(map(), [String.t()]) :: [String.t()]
  def validate_logging(logging, errors) do
    errors
    |> validate_log_level(Map.get(logging, :level), "logging.level")
    |> validate_optional_path(Map.get(logging, :file), "logging.file")
    |> validate_positive_integer(Map.get(logging, :max_no_bytes), "logging.max_no_bytes")
    |> validate_positive_integer(Map.get(logging, :max_no_files), "logging.max_no_files")
    |> validate_boolean(Map.get(logging, :compress_on_rotate), "logging.compress_on_rotate")
  end

  @doc """
  Validates providers configuration.
  """
  @spec validate_providers(map(), [String.t()]) :: [String.t()]
  def validate_providers(providers, errors) do
    errors
    |> validate_providers_map(Map.get(providers, :providers))
  end

  @doc "Validates external secret-source configuration exactly."
  @spec validate_secrets(LemonCore.Config.Secrets.t() | nil, [String.t()]) :: [String.t()]
  def validate_secrets(nil, errors), do: errors

  def validate_secrets(%LemonCore.Config.Secrets{} = secrets, errors) do
    Enum.reduce(secrets.errors, errors, &[&1 | &2])
  end

  def validate_secrets(_secrets, errors), do: ["secrets: must be a map" | errors]

  @doc """
  Validates tools configuration.
  """
  @spec validate_tools(map(), [String.t()]) :: [String.t()]
  def validate_tools(tools, errors) do
    errors
    |> validate_boolean(Map.get(tools, :auto_resize_images), "tools.auto_resize_images")
    |> validate_boolean(Map.get(tools, :intent_tracing), "tools.intent_tracing")
    |> validate_boolean(Map.get(tools, :vendor_dialects), "tools.vendor_dialects")
    |> validate_tool_approval_mode(Map.get(tools, :approval_mode))
    |> validate_edit(Map.get(tools, :edit))
    |> Bash.validate(Map.get(tools, :bash))
    |> validate_browser(Map.get(tools, :browser))
    |> validate_lsp(Map.get(tools, :lsp))
    |> validate_positive_integer(
      get_in(tools, [Access.key(:web, %{}), :fetch, :max_body_bytes]),
      "tools.web.fetch.max_body_bytes"
    )
    |> validate_boolean(
      get_in(tools, [Access.key(:checkpoint, %{}), :enabled]),
      "tools.checkpoint.enabled"
    )
    |> validate_semantic_find(Map.get(tools, :semantic_find))
    |> validate_computer_use(Map.get(tools, :computer_use))
  end

  defp validate_browser(errors, nil), do: errors

  defp validate_browser(errors, %{} = browser) do
    errors = validate_boolean(errors, browser[:tern], "runtime.tools.browser.tern")

    if browser[:provider] in LemonCore.BrowserProvider.providers() do
      errors
    else
      [
        "runtime.tools.browser.provider: must be one of #{Enum.join(LemonCore.BrowserProvider.providers(), ", ")}"
        | errors
      ]
    end
  end

  defp validate_browser(errors, _), do: ["runtime.tools.browser: must be a table" | errors]

  defp validate_edit(errors, nil), do: errors

  defp validate_edit(errors, %{} = edit) do
    errors
    |> validate_boolean(edit[:enforce_seen_lines], "runtime.tools.edit.enforce_seen_lines")
    |> validate_boolean(edit[:repo_local_tools], "runtime.tools.edit.repo_local_tools")
  end

  defp validate_edit(errors, _), do: ["runtime.tools.edit: must be a table" | errors]

  defp validate_semantic_find(errors, nil), do: errors

  defp validate_semantic_find(errors, %{} = section) do
    errors
    |> validate_boolean(section[:enabled], "runtime.tools.semantic_find.enabled")
    |> validate_non_empty_string(section[:model], "runtime.tools.semantic_find.model")
    |> validate_semantic_find_max_tokens(section[:max_tokens])
  end

  defp validate_semantic_find(errors, _),
    do: ["runtime.tools.semantic_find: must be a table" | errors]

  defp validate_semantic_find_max_tokens(errors, nil), do: errors

  defp validate_semantic_find_max_tokens(errors, value)
       when is_integer(value) and value in 512..200_000,
       do: errors

  defp validate_semantic_find_max_tokens(errors, _value),
    do: ["runtime.tools.semantic_find.max_tokens: must be an integer from 512 to 200000" | errors]

  defp validate_lsp(errors, nil), do: errors

  defp validate_lsp(errors, %{} = lsp) do
    ttl = Map.get(lsp, "idle_timeout_ms", 30_000)

    errors =
      if is_integer(ttl) and ttl >= 0,
        do: errors,
        else: ["runtime.tools.lsp.idle_timeout_ms: must be a non-negative integer" | errors]

    case Map.get(lsp, "servers", %{}) do
      servers when is_map(servers) ->
        Enum.reduce(servers, errors, fn {id, entry}, errors ->
          path = "runtime.tools.lsp.servers.#{id}"
          errors = validate_lsp_server(errors, entry, path)

          if is_map(entry) and id not in lsp_builtin_ids() and
               (not is_binary(entry["command"]) or
                  Map.get(entry, "extensions", Map.get(entry, "file_types", [])) == []) do
            ["#{path}: custom servers require command and extensions" | errors]
          else
            errors
          end
        end)

      _ ->
        ["runtime.tools.lsp.servers: must be a table" | errors]
    end
  end

  defp validate_lsp(errors, _), do: ["runtime.tools.lsp: must be a table" | errors]

  defp lsp_builtin_ids do
    catalog = Application.get_env(:lemon_core, :lsp_catalog)

    if is_atom(catalog) and not is_nil(catalog) and Code.ensure_loaded?(catalog),
      do: catalog.builtin_ids(),
      else: []
  end

  defp validate_lsp_server(errors, %{} = entry, path) do
    Enum.reduce(entry, errors, fn {field, value}, errors ->
      valid? =
        case field do
          key when key in ["command", "language_id"] ->
            is_binary(value) and String.trim(value) != ""

          key when key in ["args", "root_markers", "extensions", "file_types"] ->
            is_list(value) and Enum.all?(value, &is_binary/1)

          "disabled" ->
            is_boolean(value)

          "initialization_options" ->
            is_map(value)

          "env" ->
            is_map(value) and Enum.all?(value, fn {k, v} -> is_binary(k) and is_binary(v) end)

          _ ->
            false
        end

      if valid?, do: errors, else: ["#{path}.#{field}: invalid type or unknown field" | errors]
    end)
  end

  defp validate_lsp_server(errors, _, path), do: ["#{path}: must be a table" | errors]

  defp validate_tool_approval_mode(errors, mode) when mode in [nil, "ask", "write", "yolo"],
    do: errors

  defp validate_tool_approval_mode(errors, _mode),
    do: ["tools.approval_mode: must be ask, write, or yolo" | errors]

  defp validate_computer_use(errors, nil), do: errors

  defp validate_computer_use(errors, %{} = computer_use) do
    errors
    |> validate_boolean(computer_use[:enabled], "tools.computer_use.enabled")
    |> validate_non_empty_string(computer_use[:lcu_root], "tools.computer_use.lcu_root")
    |> validate_non_empty_string(computer_use[:node], "tools.computer_use.node")
    |> validate_origin_list(computer_use[:declined_origins])
    |> validate_app_list(computer_use[:lasting_grant_apps])
  end

  defp validate_computer_use(errors, _), do: ["tools.computer_use: must be a table" | errors]

  defp validate_app_list(errors, nil), do: errors

  defp validate_app_list(errors, apps) when is_list(apps) do
    if Enum.all?(apps, &(is_binary(&1) and String.trim(&1) != "")),
      do: errors,
      else: ["tools.computer_use.lasting_grant_apps: must be a list of app ids" | errors]
  end

  defp validate_app_list(errors, _),
    do: ["tools.computer_use.lasting_grant_apps: must be a list of app ids" | errors]

  defp validate_origin_list(errors, nil), do: errors

  defp validate_origin_list(errors, origins) when is_list(origins) do
    if Enum.all?(origins, &(is_binary(&1) and String.match?(&1, ~r{\Ahttps?://[^/\s]+/?\z}))),
      do: errors,
      else: [
        "tools.computer_use.declined_origins: must be a list of http(s) origins" | errors
      ]
  end

  defp validate_origin_list(errors, _),
    do: ["tools.computer_use.declined_origins: must be a list of http(s) origins" | errors]

  @doc """
  Validates feature flag configuration.
  """
  @spec validate_features(Features.t() | nil, [String.t()]) :: [String.t()]
  def validate_features(nil, errors), do: errors

  def validate_features(%Features{} = features, errors) do
    case Features.validate(features) do
      :ok -> errors
      {:error, feature_errors} -> Enum.reduce(feature_errors, errors, &[&1 | &2])
    end
  end

  def validate_features(_, errors) do
    ["features: must be a map" | errors]
  end

  @doc """
  Validates the `[memory]` section.
  """
  @spec validate_memory(Memory.t() | nil, [String.t()]) :: [String.t()]
  def validate_memory(%Memory{} = memory, errors) do
    errors
    |> validate_boolean(memory.auto_recall, "memory.auto_recall")
    |> validate_write_approval(memory.write_approval, "memory.write_approval")
  end

  def validate_memory(_memory, errors), do: errors

  defp validate_write_approval(errors, value, _path) when is_boolean(value), do: errors
  defp validate_write_approval(errors, _value, path), do: ["#{path}: must be a boolean" | errors]

  defp validate_private_git_hosts(errors, hosts, path) when is_list(hosts) do
    if Enum.all?(hosts, &git_host?/1),
      do: errors,
      else: ["#{path}: must be a list of host names" | errors]
  end

  defp validate_private_git_hosts(errors, _hosts, path),
    do: ["#{path}: must be a list of host names" | errors]

  defp git_host?(host),
    do: is_binary(host) and Regex.match?(~r/\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}\z/, host)

  @learning_nudge_keys ~w(enabled memory_turn_interval skill_tool_threshold background_review)
  @background_review_keys ~w(enabled model min_interval_ms timeout_ms max_tool_turns max_digest_bytes)

  defp validate_learning_nudge(errors, %{} = nudge) do
    path = "skills.learning_nudge"

    errors
    |> validate_known_keys(nudge, @learning_nudge_keys, path)
    |> validate_boolean(nudge["enabled"], "#{path}.enabled")
    |> validate_positive_integer(nudge["memory_turn_interval"], "#{path}.memory_turn_interval")
    |> validate_positive_integer(nudge["skill_tool_threshold"], "#{path}.skill_tool_threshold")
    |> validate_background_review(nudge["background_review"], "#{path}.background_review")
  end

  defp validate_learning_nudge(errors, _nudge),
    do: ["skills.learning_nudge: must be a table" | errors]

  defp validate_background_review(errors, nil, _path), do: errors

  defp validate_background_review(errors, %{} = review, path) do
    errors
    |> validate_known_keys(review, @background_review_keys, path)
    |> validate_boolean(review["enabled"], "#{path}.enabled")
    |> validate_non_empty_string(review["model"], "#{path}.model")
    |> validate_positive_integer(review["timeout_ms"], "#{path}.timeout_ms")
    |> validate_positive_integer(review["max_tool_turns"], "#{path}.max_tool_turns")
    |> validate_positive_integer(review["max_digest_bytes"], "#{path}.max_digest_bytes")
    |> validate_positive_integer(review["min_interval_ms"], "#{path}.min_interval_ms")
  end

  defp validate_background_review(errors, _review, path),
    do: ["#{path}: must be a table" | errors]

  defp validate_known_keys(errors, table, known, path) do
    table
    |> Map.keys()
    |> Enum.reject(&(&1 in known))
    |> Enum.sort()
    |> Enum.reduce(errors, &["#{path}.#{&1}: unknown key" | &2])
  end

  @doc """
  Validates the `[automation]` section.
  """
  @spec validate_automation(Automation.t() | nil, [String.t()]) :: [String.t()]
  def validate_automation(nil, errors), do: errors

  def validate_automation(%Automation{} = automation, errors),
    do: Automation.validate(automation, errors)

  @doc """
  Validates TUI configuration.
  """
  @spec validate_tui(map(), [String.t()]) :: [String.t()]
  def validate_tui(tui, errors) do
    errors
    |> validate_theme(Map.get(tui, :theme), "tui.theme")
    |> validate_boolean(Map.get(tui, :debug), "tui.debug")
  end

  # Generic validation helpers. The scalar checks below are public so
  # `LemonCore.Config.Gateway.Channel` implementations, which validate their own
  # section from another application, emit messages in the same shape.

  defp validate_non_empty_string(errors, nil, _path) do
    errors
  end

  defp validate_non_empty_string(errors, value, path) when is_binary(value) do
    if String.trim(value) == "" do
      ["#{path}: cannot be empty" | errors]
    else
      errors
    end
  end

  defp validate_non_empty_string(errors, value, _path) when is_atom(value) do
    # Atoms are valid for enum-like fields (thinking_level, provider, etc.)
    errors
  end

  defp validate_non_empty_string(errors, _value, path) do
    ["#{path}: must be a string" | errors]
  end

  @doc "Prepends an error unless `value` is `nil` or a positive integer."
  @spec validate_positive_integer([String.t()], term(), String.t()) :: [String.t()]
  def validate_positive_integer(errors, nil, _path), do: errors

  def validate_positive_integer(errors, value, path) when is_integer(value) do
    if value > 0 do
      errors
    else
      ["#{path}: must be a positive integer" | errors]
    end
  end

  def validate_positive_integer(errors, _value, path) do
    ["#{path}: must be a positive integer" | errors]
  end

  @doc "Prepends an error unless `value` is `nil` or a non-negative integer."
  @spec validate_non_negative_integer([String.t()], term(), String.t()) :: [String.t()]
  def validate_non_negative_integer(errors, nil, _path), do: errors

  def validate_non_negative_integer(errors, value, path) when is_integer(value) do
    if value >= 0 do
      errors
    else
      ["#{path}: must be a non-negative integer" | errors]
    end
  end

  def validate_non_negative_integer(errors, _value, path) do
    ["#{path}: must be a non-negative integer" | errors]
  end

  @doc "Prepends an error unless `value` is `nil` or a number in `0.0..1.0`."
  @spec validate_ratio([String.t()], term(), String.t()) :: [String.t()]
  def validate_ratio(errors, nil, _path), do: errors

  def validate_ratio(errors, value, path) when is_float(value) or is_integer(value) do
    if value >= 0.0 and value <= 1.0 do
      errors
    else
      ["#{path}: must be between 0.0 and 1.0" | errors]
    end
  end

  def validate_ratio(errors, _value, path) do
    ["#{path}: must be a number between 0.0 and 1.0" | errors]
  end

  @doc "Prepends an error unless `value` is `nil` or a boolean."
  @spec validate_boolean([String.t()], term(), String.t()) :: [String.t()]
  def validate_boolean(errors, nil, _path), do: errors

  def validate_boolean(errors, value, _path) when is_boolean(value), do: errors

  def validate_boolean(errors, _value, path) do
    ["#{path}: must be a boolean" | errors]
  end

  defp validate_log_level(errors, nil, _path), do: errors

  defp validate_log_level(errors, value, path) when is_atom(value) do
    if value in @valid_log_levels do
      errors
    else
      valid_levels = Enum.join(@valid_log_levels, ", ")
      ["#{path}: invalid level. Valid: #{valid_levels}" | errors]
    end
  end

  defp validate_log_level(errors, value, path) when is_binary(value) do
    if String.downcase(value) in Enum.map(@valid_log_levels, &Atom.to_string/1),
      do: errors,
      else: ["#{path}: invalid level. Valid: #{Enum.join(@valid_log_levels, ", ")}" | errors]
  end

  defp validate_log_level(errors, _value, path) do
    ["#{path}: must be a valid log level" | errors]
  end

  defp validate_optional_path(errors, nil, _path), do: errors

  defp validate_optional_path(errors, value, path) when is_binary(value) do
    if String.trim(value) == "" do
      ["#{path}: cannot be empty string" | errors]
    else
      errors
    end
  end

  defp validate_optional_path(errors, _value, path) do
    ["#{path}: must be a string" | errors]
  end

  # The terminal client owns theme names (`/theme`, clients/tui): core only
  # requires a non-blank name, so a value the client adds can never make config
  # loading fail. See test/fixtures/tui_theme_values.json.
  defp validate_theme(errors, nil, _path), do: errors
  defp validate_theme(errors, value, _path) when is_atom(value), do: errors

  defp validate_theme(errors, value, path) when is_binary(value) do
    if String.trim(value) == "", do: ["#{path}: cannot be empty" | errors], else: errors
  end

  defp validate_theme(errors, _value, path), do: ["#{path}: must be a string" | errors]

  defp validate_providers_map(errors, nil), do: errors

  defp validate_providers_map(errors, providers) when is_map(providers) do
    Enum.reduce(providers, errors, fn {name, config}, acc ->
      validate_provider_config(acc, name, config)
    end)
  end

  defp validate_providers_map(errors, _value) do
    ["providers: must be a table" | errors]
  end

  @doc """
  Validates legacy providers configuration (map format).
  """
  @spec validate_legacy_providers(map(), [String.t()]) :: [String.t()]
  def validate_legacy_providers(providers, errors) when is_map(providers) do
    Enum.reduce(providers, errors, fn {name, config}, acc ->
      validate_provider_config(acc, name, config)
    end)
  end

  def validate_legacy_providers(_providers, errors), do: errors

  defp validate_provider_config(errors, name, config) when is_map(config) do
    # Validate API key if present
    errors =
      case Map.get(config, :api_key) do
        nil -> errors
        "" -> ["providers.#{name}.api_key: cannot be empty" | errors]
        _ -> errors
      end

    # Validate base URL if present
    errors =
      case Map.get(config, :base_url) do
        nil ->
          errors

        "" ->
          ["providers.#{name}.base_url: cannot be empty" | errors]

        url when is_binary(url) ->
          if String.starts_with?(url, ["http://", "https://"]) do
            errors
          else
            ["providers.#{name}.base_url: must start with http:// or https://" | errors]
          end

        _ ->
          ["providers.#{name}.base_url: must be a string" | errors]
      end

    errors
    |> validate_provider_secret_refs(name, config, "providers")
    |> validate_provider_auth_source(name, config, "providers")
    |> validate_provider_omp_path(name, config, "providers")
    |> validate_provider_omp_broker(name, config, "providers")
    |> validate_custom_provider(name, config, "providers")
  end

  defp validate_provider_config(errors, name, _config) do
    ["providers.#{name}: must be a table" | errors]
  end

  # Custom provider/model definitions parsed by `LemonCore.Config.Providers`:
  # invalid enum values are kept verbatim there so they can be reported here.
  defp validate_custom_provider(errors, name, config, prefix) do
    path = "#{prefix}.#{name}"
    api = Map.get(config, :api)
    discovery = Map.get(config, :discovery)

    errors
    |> validate_custom_enum(api, "#{path}.api", &Providers.canonical_api/1, api_choices())
    |> validate_custom_enum(
      Map.get(config, :auth),
      "#{path}.auth",
      &Providers.canonical_auth/1,
      "api_key | none"
    )
    |> validate_custom_enum(
      discovery,
      "#{path}.discovery",
      &Providers.canonical_discovery/1,
      "openai | ollama"
    )
    |> validate_positive_integer(
      Map.get(config, :discovery_timeout_ms),
      "#{path}.discovery.timeout_ms"
    )
    |> validate_custom_base_url(path, config, api || discovery)
    |> validate_header_map(Map.get(config, :headers), "#{path}.headers")
    |> validate_custom_models(Map.get(config, :models), "#{path}.models")
  end

  defp api_choices, do: Enum.join(Providers.custom_apis(), " | ")

  defp validate_custom_enum(errors, nil, _path, _canonical, _choices), do: errors

  defp validate_custom_enum(errors, value, path, canonical, choices) do
    if canonical.(value) do
      errors
    else
      ["#{path}: invalid value (#{describe_type(value)}; expected #{choices})" | errors]
    end
  end

  defp validate_custom_base_url(errors, _path, _config, nil), do: errors

  defp validate_custom_base_url(errors, path, config, _custom) do
    if is_nil(Map.get(config, :base_url)) do
      [
        "#{path}.base_url: required when api or discovery is set; add base_url = \"https://...\" to this provider"
        | errors
      ]
    else
      errors
    end
  end

  defp validate_header_map(errors, nil, _path), do: errors

  defp validate_header_map(errors, headers, path) when is_map(headers) do
    if Enum.all?(headers, fn {_key, value} -> is_binary(value) end) do
      errors
    else
      ["#{path}: header values must be strings" | errors]
    end
  end

  defp validate_header_map(errors, _headers, path), do: ["#{path}: must be a table" | errors]

  defp validate_custom_models(errors, nil, _path), do: errors

  defp validate_custom_models(errors, models, path) when is_list(models) do
    models
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {model, index}, acc ->
      validate_custom_model(acc, model, "#{path}[#{index}]")
    end)
  end

  defp validate_custom_models(errors, _models, path),
    do: ["#{path}: must be an array of tables ([[...models]])" | errors]

  defp validate_custom_model(errors, model, path) when is_map(model) do
    errors =
      if is_binary(Map.get(model, :id)),
        do: errors,
        else: ["#{path}.id: is required" | errors]

    errors
    |> validate_custom_enum(
      Map.get(model, :api),
      "#{path}.api",
      &Providers.canonical_api/1,
      api_choices()
    )
    |> validate_positive_integer(Map.get(model, :context_window), "#{path}.context_window")
    |> validate_positive_integer(Map.get(model, :max_tokens), "#{path}.max_tokens")
    |> validate_boolean(Map.get(model, :reasoning), "#{path}.reasoning")
    |> validate_model_input(Map.get(model, :input), "#{path}.input")
    |> validate_model_cost(Map.get(model, :cost), "#{path}.cost")
    |> validate_header_map(Map.get(model, :headers), "#{path}.headers")
  end

  defp validate_custom_model(errors, _model, path), do: ["#{path}: must be a table" | errors]

  defp validate_model_input(errors, nil, _path), do: errors

  defp validate_model_input(errors, input, path) when is_list(input) do
    if input != [] and Enum.all?(input, &(&1 in ["text", "image"])),
      do: errors,
      else: [~s(#{path}: must list "text" and/or "image") | errors]
  end

  defp validate_model_input(errors, _input, path),
    do: [~s(#{path}: must list "text" and/or "image") | errors]

  defp validate_model_cost(errors, nil, _path), do: errors

  defp validate_model_cost(errors, cost, path) when is_map(cost) do
    if Enum.all?(cost, fn {_key, value} -> is_number(value) and value >= 0 end),
      do: errors,
      else: ["#{path}: prices must be non-negative numbers" | errors]
  end

  defp validate_model_cost(errors, _cost, path), do: ["#{path}: must be a table" | errors]

  @doc """
  Returns true when the string references an environment variable, e.g. `"${MY_VAR}"`.

  Secret-bearing fields skip format validation for these, because the value is
  only known at runtime.
  """
  @spec env_var_reference?(term()) :: boolean()
  def env_var_reference?(str) when is_binary(str) do
    String.starts_with?(str, "${") and String.ends_with?(str, "}")
  end

  def env_var_reference?(_), do: false

  defp validate_provider_secret_refs(errors, name, config, path_prefix) do
    [
      :api_key_secret,
      :oauth_secret,
      :project_secret,
      :location_secret,
      :service_account_json_secret,
      :access_key_id_secret,
      :secret_access_key_secret,
      :session_token_secret
    ]
    |> Enum.reduce(errors, fn field, acc ->
      validate_provider_secret_ref(acc, name, config, path_prefix, field)
    end)
  end

  defp validate_provider_secret_ref(errors, name, config, path_prefix, field) do
    case Map.get(config, field, Map.get(config, Atom.to_string(field))) do
      nil ->
        errors

      value when is_binary(value) ->
        if String.trim(value) == "" do
          ["#{path_prefix}.#{name}.#{field}: cannot be empty" | errors]
        else
          errors
        end

      other ->
        [
          "#{path_prefix}.#{name}.#{field}: must be a string (got #{describe_type(other)})"
          | errors
        ]
    end
  end

  defp validate_provider_auth_source(errors, name, config, path_prefix) do
    provider = name |> to_string() |> String.trim() |> String.downcase()
    path = "#{path_prefix}.#{name}.auth_source"

    choices =
      case provider do
        "openai-codex" ->
          ["oauth", "api_key", "omp_broker"]

        "anthropic" ->
          ["oauth", "api_key", "omp_broker"]

        kimi when kimi in ["kimi_coding", "kimi-coding", "kimi-for-coding"] ->
          ["oauth", "api_key", "omp", "omp_broker"]

        _ ->
          nil
      end

    case Map.get(config, :auth_source, Map.get(config, "auth_source")) do
      nil when provider == "openai-codex" ->
        [~s(#{path}: required; set auth_source = "oauth" or "api_key") | errors]

      nil ->
        errors

      source when is_binary(source) ->
        normalized = LemonCore.Config.Providers.normalize_auth_source(source)

        cond do
          is_list(choices) and normalized not in choices ->
            ["#{path}: invalid value (expected #{Enum.join(choices, " | ")})" | errors]

          is_nil(choices) and normalized == "omp" ->
            ["#{path}: omp is only supported for kimi_coding" | errors]

          true ->
            errors
        end

      other when is_list(choices) ->
        ["#{path}: must be a string (got #{describe_type(other)})" | errors]

      _other ->
        errors
    end
  end

  # `omp_provider` / `omp_account` select the broker credential and mean nothing
  # under another credential source.
  defp validate_provider_omp_broker(errors, name, config, path_prefix) do
    broker? =
      LemonCore.Config.Providers.normalize_auth_source(
        Map.get(config, :auth_source, Map.get(config, "auth_source"))
      ) == "omp_broker"

    Enum.reduce([:omp_provider, :omp_account], errors, fn field, acc ->
      path = "#{path_prefix}.#{name}.#{field}"

      case Map.get(config, field, Map.get(config, Atom.to_string(field))) do
        nil ->
          acc

        value when is_binary(value) ->
          cond do
            String.trim(value) == "" -> ["#{path}: cannot be empty" | acc]
            not broker? -> [~s(#{path}: requires auth_source = "omp_broker") | acc]
            true -> acc
          end

        other ->
          ["#{path}: must be a string (got #{describe_type(other)})" | acc]
      end
    end)
  end

  defp validate_provider_omp_path(errors, name, config, path_prefix) do
    path = "#{path_prefix}.#{name}.omp_path"

    case Map.get(config, :omp_path, Map.get(config, "omp_path")) do
      nil ->
        errors

      value when is_binary(value) ->
        if String.valid?(value) and not String.contains?(value, <<0>>) and
             Path.type(value) == :absolute and not String.ends_with?(value, "/") do
          errors
        else
          ["#{path}: must be an absolute executable path" | errors]
        end

      other ->
        ["#{path}: must be a string (got #{describe_type(other)})" | errors]
    end
  end

  defp describe_type(value) when is_binary(value), do: "string"
  defp describe_type(value) when is_boolean(value), do: "boolean"
  defp describe_type(value) when is_integer(value), do: "integer"
  defp describe_type(value) when is_float(value), do: "float"
  defp describe_type(value) when is_map(value), do: "table"
  defp describe_type(value) when is_list(value), do: "array"
  defp describe_type(_value), do: "unsupported type"
end
