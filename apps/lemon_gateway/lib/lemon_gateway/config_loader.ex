defmodule LemonGateway.ConfigLoader do
  @moduledoc """
  Loads gateway configuration from the canonical Lemon TOML config.
  """

  alias LemonCore.Binding
  alias LemonGateway.Project
  alias LemonCore.Config, as: LemonConfig

  @spec load() :: map()
  def load do
    case override_config() do
      {:ok, config} ->
        parse_gateway(config)

      :error ->
        gateway = load_from_path() || load_gateway_from_canonical_toml()
        parse_gateway(gateway)
    end
  end

  defp override_config do
    case Application.get_env(:lemon_gateway, LemonGateway.Config) do
      nil ->
        :error

      config when is_map(config) ->
        {:ok, config}

      config when is_list(config) ->
        if Keyword.keyword?(config) do
          {:ok, Enum.into(config, %{})}
        else
          {:ok, %{bindings: config}}
        end

      _ ->
        :error
    end
  end

  defp load_from_path do
    case Application.get_env(:lemon_gateway, :config_path) do
      path when is_binary(path) and path != "" ->
        if File.exists?(path) do
          LemonConfig.load_file(path) |> Map.get("gateway")
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp load_gateway_from_canonical_toml do
    global =
      LemonConfig.global_path()
      |> LemonConfig.load_file()

    project =
      case File.cwd() do
        {:ok, cwd} ->
          cwd
          |> LemonConfig.project_path()
          |> LemonConfig.load_file()

        _ ->
          %{}
      end

    global
    |> deep_merge_maps(project)
    |> Map.get("gateway", %{})
  end

  defp deep_merge_maps(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge_maps(left_value, right_value)
    end)
  end

  defp deep_merge_maps(_left, right), do: right

  defp parse_gateway(gateway) when is_map(gateway) do
    projects = parse_projects(fetch(gateway, :projects) || %{})
    bindings = parse_bindings(fetch(gateway, :bindings) || [])

    queue =
      gateway
      |> fetch(:queue)
      |> parse_queue()

    sms =
      gateway
      |> fetch(:sms)
      |> parse_sms()

    telegram =
      gateway
      |> fetch(:telegram)
      |> parse_telegram()

    discord =
      gateway
      |> fetch(:discord)
      |> parse_discord()

    farcaster =
      gateway
      |> fetch(:farcaster)
      |> parse_farcaster()

    email =
      gateway
      |> fetch(:email)
      |> parse_email()

    xmtp =
      gateway
      |> fetch(:xmtp)
      |> parse_xmtp()

    webhook =
      gateway
      |> fetch(:webhook)
      |> parse_webhook()

    engines =
      gateway
      |> fetch(:engines)
      |> parse_engines()

    %{
      max_concurrent_runs: fetch(gateway, :max_concurrent_runs),
      default_engine: fetch(gateway, :default_engine),
      default_cwd: fetch(gateway, :default_cwd),
      auto_resume: fetch(gateway, :auto_resume),
      enable_telegram: fetch(gateway, :enable_telegram),
      enable_discord: fetch(gateway, :enable_discord),
      enable_farcaster: fetch(gateway, :enable_farcaster),
      enable_email: fetch(gateway, :enable_email),
      enable_xmtp: fetch(gateway, :enable_xmtp),
      enable_webhook: fetch(gateway, :enable_webhook),
      require_engine_lock: fetch(gateway, :require_engine_lock),
      engine_lock_timeout_ms: fetch(gateway, :engine_lock_timeout_ms)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.put(:projects, projects)
    |> Map.put(:bindings, bindings)
    |> Map.put(:queue, queue)
    |> Map.put(:sms, sms)
    |> Map.put(:telegram, telegram)
    |> Map.put(:discord, discord)
    |> Map.put(:farcaster, farcaster)
    |> Map.put(:email, email)
    |> Map.put(:xmtp, xmtp)
    |> Map.put(:webhook, webhook)
    |> Map.put(:engines, engines)
  end

  defp parse_gateway(_), do: %{}

  defp parse_projects(projects) when is_map(projects) do
    for {name, config} <- projects, into: %{} do
      project = %Project{
        id: to_string(name),
        root: fetch(config, :root),
        default_engine: fetch(config, :default_engine)
      }

      validate_project_root(project)
      {to_string(name), project}
    end
  end

  defp parse_projects(_), do: %{}

  defp parse_bindings(bindings) when is_list(bindings) do
    Enum.map(bindings, fn b ->
      %Binding{
        transport: parse_transport(fetch(b, :transport)),
        chat_id: fetch(b, :chat_id),
        topic_id: fetch(b, :topic_id),
        project: fetch(b, :project),
        agent_id: fetch(b, :agent_id),
        default_engine: fetch(b, :default_engine),
        queue_mode: parse_queue_mode(fetch(b, :queue_mode))
      }
    end)
  end

  defp parse_bindings(_), do: []

  defp parse_queue(queue) when is_map(queue) do
    %{
      mode: parse_queue_mode(fetch(queue, :mode)),
      cap: fetch(queue, :cap),
      drop: parse_drop_policy(fetch(queue, :drop))
    }
  end

  defp parse_queue(_), do: %{mode: nil, cap: nil, drop: nil}

  defp parse_sms(sms) when is_map(sms) do
    %{
      webhook_enabled: fetch(sms, :webhook_enabled),
      webhook_port: fetch(sms, :webhook_port),
      webhook_bind: fetch(sms, :webhook_bind),
      inbox_number: fetch(sms, :inbox_number),
      inbox_ttl_ms: fetch(sms, :inbox_ttl_ms),
      validate_webhook: fetch(sms, :validate_webhook),
      auth_token: fetch(sms, :auth_token),
      webhook_url: fetch(sms, :webhook_url)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_sms(_), do: %{}

  defp parse_telegram(telegram) when is_map(telegram) do
    %{
      bot_token: fetch(telegram, :bot_token),
      bot_id: fetch(telegram, :bot_id),
      bot_username: fetch(telegram, :bot_username),
      allowed_chat_ids: fetch(telegram, :allowed_chat_ids),
      deny_unbound_chats: fetch(telegram, :deny_unbound_chats),
      # When set (string) or enabled (true), send a startup message to bound chats on boot.
      startup_message: fetch(telegram, :startup_message),
      poll_interval_ms: fetch(telegram, :poll_interval_ms),
      edit_throttle_ms: fetch(telegram, :edit_throttle_ms),
      debounce_ms: fetch(telegram, :debounce_ms),
      # When enabled, append a short "resume" line to final answers.
      show_resume_line: fetch(telegram, :show_resume_line),
      # When enabled, outgoing text is treated as markdown and rendered using Telegram entities.
      use_markdown: fetch(telegram, :use_markdown),
      allow_queue_override: fetch(telegram, :allow_queue_override),
      account_id: fetch(telegram, :account_id),
      offset: fetch(telegram, :offset),
      drop_pending_updates: fetch(telegram, :drop_pending_updates),
      voice_transcription: fetch(telegram, :voice_transcription),
      voice_transcription_model: fetch(telegram, :voice_transcription_model),
      voice_transcription_base_url: fetch(telegram, :voice_transcription_base_url),
      voice_transcription_api_key: fetch(telegram, :voice_transcription_api_key),
      voice_max_bytes: fetch(telegram, :voice_max_bytes),
      compaction: parse_telegram_compaction(fetch(telegram, :compaction)),
      files: parse_telegram_files(fetch(telegram, :files))
    }
  end

  defp parse_telegram(_), do: %{}

  defp parse_discord(discord) when is_map(discord) do
    %{
      bot_token: fetch(discord, :bot_token),
      allowed_guild_ids: fetch(discord, :allowed_guild_ids),
      allowed_channel_ids: fetch(discord, :allowed_channel_ids),
      deny_unbound_channels: fetch(discord, :deny_unbound_channels)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_discord(_), do: %{}

  defp parse_farcaster(farcaster) when is_map(farcaster) do
    %{
      frame_enabled: fetch(farcaster, :frame_enabled),
      port: fetch(farcaster, :port),
      bind: fetch(farcaster, :bind),
      action_path: fetch(farcaster, :action_path),
      frame_base_url: fetch(farcaster, :frame_base_url),
      image_url: fetch(farcaster, :image_url),
      input_label: fetch(farcaster, :input_label),
      button_1: fetch(farcaster, :button_1),
      button_2: fetch(farcaster, :button_2),
      account_id: fetch(farcaster, :account_id),
      state_secret: fetch(farcaster, :state_secret),
      verify_trusted_data: default_true(fetch(farcaster, :verify_trusted_data)),
      hub_validate_url: fetch(farcaster, :hub_validate_url),
      api_key: fetch(farcaster, :api_key),
      signer_uuid: fetch(farcaster, :signer_uuid)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_farcaster(_), do: %{}

  defp parse_email(email) when is_map(email) do
    %{
      inbound_enabled: fetch(email, :inbound_enabled),
      webhook_enabled: fetch(email, :webhook_enabled),
      webhook_port: fetch(email, :webhook_port),
      webhook_bind: fetch(email, :webhook_bind),
      webhook_path: fetch(email, :webhook_path),
      webhook_token: fetch(email, :webhook_token),
      reply_to: fetch(email, :reply_to),
      from: fetch(email, :from),
      relay: fetch(email, :relay),
      smtp_relay: fetch(email, :smtp_relay),
      smtp_port: fetch(email, :smtp_port),
      smtp_username: fetch(email, :smtp_username),
      smtp_password: fetch(email, :smtp_password),
      smtp_tls: fetch(email, :smtp_tls),
      smtp_ssl: fetch(email, :smtp_ssl),
      smtp_auth: fetch(email, :smtp_auth),
      smtp_hostname: fetch(email, :smtp_hostname),
      inbound: parse_email_inbound(fetch(email, :inbound)),
      outbound: parse_email_outbound(fetch(email, :outbound))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_email(_), do: %{}

  defp parse_email_inbound(inbound) when is_map(inbound) do
    %{
      enabled: fetch(inbound, :enabled),
      bind: fetch(inbound, :bind),
      port: fetch(inbound, :port),
      path: fetch(inbound, :path),
      token: fetch(inbound, :token)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_email_inbound(_), do: %{}

  defp parse_email_outbound(outbound) when is_map(outbound) do
    %{
      from: fetch(outbound, :from),
      reply_to: fetch(outbound, :reply_to),
      relay: fetch(outbound, :relay),
      port: fetch(outbound, :port),
      username: fetch(outbound, :username),
      password: fetch(outbound, :password),
      tls: fetch(outbound, :tls),
      tls_versions: fetch(outbound, :tls_versions),
      ssl: fetch(outbound, :ssl),
      auth: fetch(outbound, :auth),
      hostname: fetch(outbound, :hostname)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_email_outbound(_), do: %{}

  defp parse_xmtp(xmtp) when is_map(xmtp) do
    %{
      env: fetch(xmtp, :env) || fetch(xmtp, :environment),
      api_url: resolve_env_ref(fetch(xmtp, :api_url)),
      poll_interval_ms: fetch(xmtp, :poll_interval_ms),
      connect_timeout_ms: fetch(xmtp, :connect_timeout_ms),
      require_live: fetch(xmtp, :require_live),
      wallet_address: resolve_env_ref(fetch(xmtp, :wallet_address)),
      wallet_key: resolve_env_ref(fetch(xmtp, :wallet_key)),
      private_key: resolve_env_ref(fetch(xmtp, :private_key)),
      inbox_id: resolve_env_ref(fetch(xmtp, :inbox_id)),
      db_path: resolve_env_ref(fetch(xmtp, :db_path)),
      bridge_script: resolve_env_ref(fetch(xmtp, :bridge_script)),
      mock_mode: fetch(xmtp, :mock_mode),
      sdk_module: resolve_env_ref(fetch(xmtp, :sdk_module))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_xmtp(_), do: %{}

  defp parse_webhook(webhook) when is_map(webhook) do
    %{
      bind: fetch(webhook, :bind),
      port: fetch(webhook, :port),
      mode: parse_webhook_mode(fetch(webhook, :mode)),
      timeout_ms: fetch(webhook, :timeout_ms),
      callback_wait_timeout_ms: fetch(webhook, :callback_wait_timeout_ms),
      callback_url: fetch(webhook, :callback_url),
      allow_callback_override: fetch(webhook, :allow_callback_override),
      allow_private_callback_hosts: fetch(webhook, :allow_private_callback_hosts),
      allow_query_token: fetch(webhook, :allow_query_token),
      allow_payload_token: fetch(webhook, :allow_payload_token),
      allow_payload_idempotency_key: fetch(webhook, :allow_payload_idempotency_key),
      callback_max_attempts: fetch(webhook, :callback_max_attempts),
      callback_backoff_ms: fetch(webhook, :callback_backoff_ms),
      callback_backoff_max_ms: fetch(webhook, :callback_backoff_max_ms),
      integrations:
        webhook
        |> fetch(:integrations)
        |> parse_webhook_integrations()
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_webhook(_), do: %{}

  defp parse_webhook_integrations(integrations) when is_map(integrations) do
    for {integration_id, integration} <- integrations, into: %{} do
      {to_string(integration_id), parse_webhook_integration(integration)}
    end
  end

  defp parse_webhook_integrations(_), do: %{}

  defp parse_webhook_integration(integration) when is_map(integration) do
    %{
      token: fetch(integration, :token),
      session_key: fetch(integration, :session_key),
      agent_id: fetch(integration, :agent_id),
      queue_mode: parse_webhook_queue_mode(fetch(integration, :queue_mode)),
      default_engine: fetch(integration, :default_engine),
      cwd: fetch(integration, :cwd),
      callback_url: fetch(integration, :callback_url),
      allow_callback_override: fetch(integration, :allow_callback_override),
      allow_private_callback_hosts: fetch(integration, :allow_private_callback_hosts),
      allow_query_token: fetch(integration, :allow_query_token),
      allow_payload_token: fetch(integration, :allow_payload_token),
      allow_payload_idempotency_key: fetch(integration, :allow_payload_idempotency_key),
      callback_max_attempts: fetch(integration, :callback_max_attempts),
      callback_backoff_ms: fetch(integration, :callback_backoff_ms),
      callback_backoff_max_ms: fetch(integration, :callback_backoff_max_ms),
      mode: parse_webhook_mode(fetch(integration, :mode)),
      timeout_ms: fetch(integration, :timeout_ms),
      callback_wait_timeout_ms: fetch(integration, :callback_wait_timeout_ms)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_webhook_integration(_), do: %{}

  defp parse_telegram_compaction(compaction) when is_map(compaction) do
    %{
      enabled: fetch(compaction, :enabled),
      context_window_tokens: fetch(compaction, :context_window_tokens),
      reserve_tokens: fetch(compaction, :reserve_tokens),
      trigger_ratio: fetch(compaction, :trigger_ratio)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_telegram_compaction(_), do: %{}

  defp parse_telegram_files(files) when is_map(files) do
    %{
      enabled: fetch(files, :enabled),
      auto_put: fetch(files, :auto_put),
      auto_put_mode: fetch(files, :auto_put_mode),
      auto_send_generated_images: fetch(files, :auto_send_generated_images),
      auto_send_generated_max_files: fetch(files, :auto_send_generated_max_files),
      uploads_dir: fetch(files, :uploads_dir),
      allowed_user_ids: fetch(files, :allowed_user_ids),
      deny_globs: fetch(files, :deny_globs),
      max_upload_bytes: fetch(files, :max_upload_bytes),
      max_download_bytes: fetch(files, :max_download_bytes),
      media_group_debounce_ms: fetch(files, :media_group_debounce_ms),
      outbound_send_delay_ms: fetch(files, :outbound_send_delay_ms)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp parse_telegram_files(_), do: %{}

  defp parse_engines(engines) when is_map(engines) do
    for {name, config} <- engines, into: %{} do
      engine = %{
        cli_path: fetch(config, :cli_path),
        enabled: fetch(config, :enabled)
      }

      {String.to_atom(to_string(name)), engine}
    end
  end

  defp parse_engines(_), do: %{}

  defp parse_transport(nil), do: nil
  defp parse_transport("telegram"), do: :telegram
  defp parse_transport(:telegram), do: :telegram
  defp parse_transport(other) when is_binary(other), do: String.to_atom(other)
  defp parse_transport(other) when is_atom(other), do: other

  defp parse_queue_mode(nil), do: nil
  defp parse_queue_mode("collect"), do: :collect
  defp parse_queue_mode("followup"), do: :followup
  defp parse_queue_mode("steer"), do: :steer
  defp parse_queue_mode("steer_backlog"), do: :steer_backlog
  defp parse_queue_mode("interrupt"), do: :interrupt
  defp parse_queue_mode(mode) when is_atom(mode), do: mode

  defp parse_webhook_queue_mode(nil), do: nil
  defp parse_webhook_queue_mode("collect"), do: :collect
  defp parse_webhook_queue_mode("followup"), do: :followup
  defp parse_webhook_queue_mode("steer"), do: :steer
  defp parse_webhook_queue_mode("steer_backlog"), do: :steer_backlog
  defp parse_webhook_queue_mode("interrupt"), do: :interrupt

  defp parse_webhook_queue_mode(mode)
       when mode in [:collect, :followup, :steer, :steer_backlog, :interrupt], do: mode

  defp parse_webhook_queue_mode(_), do: nil

  defp parse_webhook_mode(nil), do: nil
  defp parse_webhook_mode("sync"), do: :sync
  defp parse_webhook_mode("async"), do: :async
  defp parse_webhook_mode(:sync), do: :sync
  defp parse_webhook_mode(:async), do: :async
  defp parse_webhook_mode(_), do: nil

  defp parse_drop_policy(nil), do: nil
  defp parse_drop_policy("oldest"), do: :oldest
  defp parse_drop_policy("newest"), do: :newest
  defp parse_drop_policy(policy) when is_atom(policy), do: policy

  defp validate_project_root(%Project{id: id, root: root}) when is_binary(root) do
    expanded = Path.expand(root)

    unless File.dir?(expanded) do
      require Logger
      Logger.warning("Project '#{id}' root directory does not exist: #{expanded}")
    end
  end

  defp validate_project_root(_), do: :ok

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp fetch(list, key) when is_list(list) do
    Keyword.get(list, key) || Keyword.get(list, to_string(key))
  end

  defp resolve_env_ref(value) when is_binary(value) do
    value = String.trim(value)

    if String.starts_with?(value, "${") and String.ends_with?(value, "}") do
      var = String.slice(value, 2..-2//1) |> String.trim()
      System.get_env(var) || value
    else
      value
    end
  end

  defp resolve_env_ref(value), do: value

  defp default_true(nil), do: true
  defp default_true(value), do: value
end
