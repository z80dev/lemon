defmodule LemonCore.Quality.ArchitectureRulesCheck do
  @moduledoc """
  Enforces explicit architecture guardrails that are easier to express as
  stable source-pattern checks than dependency graph rules.
  """

  @type issue :: %{
          code: atom(),
          message: String.t(),
          path: String.t()
        }

  @type report :: %{
          root: String.t(),
          issue_count: non_neg_integer(),
          issues: [issue()]
        }

  @router_session_registry "LemonRouter." <> "SessionRegistry"
  @router_session_read_model "LemonRouter." <> "SessionReadModel"
  @router_registry_lookup "Registry.lookup(" <> @router_session_registry

  @rules [
    %{
      code: :router_outbound_payload,
      message: "Router must not construct LemonChannels.OutboundPayload directly",
      files: ["apps/lemon_router/lib/**/*.ex"],
      patterns: ["LemonChannels.OutboundPayload", "OutboundPayload."]
    },
    %{
      code: :router_telegram_dependency,
      message: "Router must not depend on LemonChannels.Telegram modules directly",
      files: ["apps/lemon_router/lib/**/*.ex"],
      patterns: ["LemonChannels.Telegram."],
      exclude: ["apps/lemon_router/lib/lemon_router/agent_directory.ex"]
    },
    %{
      code: :router_channels_runtime_dependency,
      message: "Router must not depend on LemonChannels runtime/config helpers directly",
      files: ["apps/lemon_router/lib/**/*.ex"],
      patterns: ["LemonChannels.GatewayConfig", "LemonChannels.EngineRegistry"]
    },
    %{
      code: :router_gateway_engine_registry_dependency,
      message: "Router must validate engines through LemonCore.EngineCatalog, not gateway registry",
      files: ["apps/lemon_router/lib/**/*.ex"],
      patterns: ["LemonGateway.EngineRegistry"]
    },
    %{
      code: :router_gateway_cwd_dependency,
      message: "Router must use LemonCore.Cwd instead of LemonGateway.Cwd",
      files: ["apps/lemon_router/lib/**/*.ex"],
      patterns: ["LemonGateway.Cwd"]
    },
    %{
      code: :router_session_registry_boundary,
      message: "Apps outside lemon_router must not reference router-internal session state",
      files: ["apps/**/*.ex", "apps/**/*.exs"],
      exclude: [
        "apps/lemon_router/lib/**/*.ex",
        "apps/lemon_router/test/**/*.exs",
        "apps/lemon_core/test/lemon_core/quality/architecture_rules_check_test.exs"
      ],
      patterns: [
        @router_session_registry,
        @router_session_read_model,
        @router_registry_lookup
      ]
    },
    %{
      code: :router_resume_parser_leak,
      message: "Router must not parse free-form channel resume syntax",
      files: ["apps/lemon_router/lib/**/*.ex"],
      patterns: ["extract_resume_and_strip_prompt", "EngineRegistry.extract_resume"]
    },
    %{
      code: :router_telegram_store_leak,
      message: "Router must not own Telegram message-index or pending-compaction tables directly",
      files: ["apps/lemon_router/lib/**/*.ex"],
      patterns: [
        ":telegram_msg_resume",
        ":telegram_msg_session",
        ":telegram_pending_compaction",
        ":telegram_known_targets",
        "KnownTargetStore"
      ],
      exclude: ["apps/lemon_router/lib/lemon_router/agent_directory.ex"]
    },
    %{
      code: :gateway_execution_queue_mode,
      message: "Gateway execution contract must not include queue_mode",
      files: ["apps/lemon_gateway/lib/lemon_gateway/execution_request.ex"],
      patterns: ["queue_mode"]
    },
    %{
      code: :gateway_legacy_runtime_submit,
      message: "Gateway runtime must not reintroduce legacy submit/1 compatibility wrappers",
      files: ["apps/lemon_gateway/lib/lemon_gateway/runtime.ex"],
      patterns: ["def submit("]
    },
    %{
      code: :telegram_transport_pending_compaction,
      message: "Telegram transport must not mutate prompts for pending compaction",
      files: [
        "apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport.ex",
        "apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/**/*.ex"
      ],
      patterns: [
        ":telegram_pending_compaction",
        "auto_compacted",
        "build_pending_compaction_prompt"
      ]
    },
    %{
      code: :channels_engine_registry_format_validation,
      message:
        "Channels must use LemonCore.EngineCatalog and LemonCore.ResumeToken for validation/formatting; EngineRegistry is parsing-only",
      files: ["apps/lemon_channels/lib/**/*.ex"],
      exclude: ["apps/lemon_channels/lib/lemon_channels/engine_registry.ex"],
      patterns: [
        "EngineRegistry.get_engine(",
        "EngineRegistry.engine_known?(",
        "EngineRegistry.format_resume(",
        "LemonChannels.EngineRegistry.get_engine(",
        "LemonChannels.EngineRegistry.engine_known?(",
        "LemonChannels.EngineRegistry.format_resume("
      ]
    },
    %{
      code: :core_telegram_resume_index_leak,
      message: "LemonCore must not own Telegram message-id resume/session tables",
      files: ["apps/lemon_core/lib/lemon_core/**/*.ex"],
      patterns: [":telegram_msg_resume", ":telegram_msg_session"]
    },
    %{
      code: :wrapper_bypass,
      message:
        "Shared-domain modules must use typed store wrappers instead of raw run/chat/policy APIs",
      files: ["apps/lemon_core/lib/lemon_core/**/*.ex", "apps/lemon_control_plane/lib/**/*.ex"],
      patterns: [
        "LemonCore.Store.get_run(",
        "LemonCore.Store.get_run_history(",
        "LemonCore.Store.get_session_policy(",
        "LemonCore.Store.put_session_policy(",
        "LemonCore.Store.get_chat_state(",
        "LemonCore.Store.put_chat_state(",
        "LemonCore.Store.delete_chat_state("
      ]
    },
    %{
      code: :shared_domain_generic_store_bypass,
      message:
        "Shared-domain session/run modules must use typed store wrappers instead of raw generic store tables",
      files: [
        "apps/lemon_control_plane/lib/lemon_control_plane/methods/sessions_*.ex",
        "apps/lemon_router/lib/lemon_router/agent_directory.ex"
      ],
      patterns: [
        "LemonCore.Store.list(:sessions_index",
        "LemonCore.Store.delete(:sessions_index",
        "LemonCore.Store.list(:run_history",
        "LemonCore.Store.delete(:run_history",
        "LemonCore.Store.delete(:chat_state",
        "LemonCore.Store.delete(:session_overrides",
        "LemonCore.Store.list(:telegram_known_targets"
      ]
    },
    %{
      code: :shared_domain_store_wrapper_bypass,
      message:
        "Typed shared-domain storage must not be bypassed with raw generic or specialized store calls",
      files: ["apps/lemon_core/lib/lemon_core/**/*.ex", "apps/lemon_control_plane/lib/**/*.ex"],
      exclude: [
        "apps/lemon_core/lib/lemon_core/store.ex",
        "apps/lemon_core/lib/lemon_core/testing.ex",
        "apps/lemon_core/lib/lemon_core/chat_state_store.ex",
        "apps/lemon_core/lib/lemon_core/run_store.ex",
        "apps/lemon_core/lib/lemon_core/progress_store.ex",
        "apps/lemon_core/lib/lemon_core/policy_store.ex",
        "apps/lemon_core/lib/lemon_core/introspection_store.ex",
        "apps/lemon_core/lib/lemon_core/project_binding_store.ex",
        "apps/lemon_core/lib/lemon_core/model_policy_store.ex",
        "apps/lemon_core/lib/lemon_core/idempotency_store.ex"
      ],
      patterns: [
        "LemonCore.Store.append_introspection_event(",
        "LemonCore.Store.list_introspection_events(",
        "LemonCore.Store.get(:model_policies",
        "LemonCore.Store.put(:model_policies",
        "LemonCore.Store.delete(:model_policies",
        "LemonCore.Store.list(:model_policies",
        "LemonCore.Store.get(:idempotency",
        "LemonCore.Store.put(:idempotency",
        "LemonCore.Store.delete(:idempotency",
        "LemonCore.Store.list(:idempotency",
        "LemonCore.Store.get(:project_overrides",
        "LemonCore.Store.put(:project_overrides",
        "LemonCore.Store.delete(:project_overrides",
        "LemonCore.Store.list(:project_overrides",
        "LemonCore.Store.get(:projects_dynamic",
        "LemonCore.Store.put(:projects_dynamic",
        "LemonCore.Store.delete(:projects_dynamic",
        "LemonCore.Store.list(:projects_dynamic"
      ]
    },
    %{
      code: :telegram_known_targets_wrapper_bypass,
      message:
        "Telegram known-target storage must go through LemonChannels.Telegram.KnownTargetStore",
      files: [
        "apps/lemon_channels/lib/lemon_channels/**/*.ex",
        "apps/lemon_router/lib/lemon_router/**/*.ex"
      ],
      exclude: [
        "apps/lemon_channels/lib/lemon_channels/telegram/known_target_store.ex",
        "apps/lemon_core/lib/lemon_core/store.ex"
      ],
      patterns: [
        "LemonCore.Store.get(:telegram_known_targets",
        "LemonCore.Store.put(:telegram_known_targets",
        "LemonCore.Store.list(:telegram_known_targets",
        "CoreStore.get(:telegram_known_targets",
        "CoreStore.put(:telegram_known_targets"
      ]
    },
    %{
      code: :gateway_conversation_key_selection,
      message: "Gateway must not derive conversation keys internally; callers must supply them",
      files: [
        "apps/lemon_gateway/lib/lemon_gateway/scheduler.ex",
        "apps/lemon_gateway/lib/lemon_gateway/execution_request.ex"
      ],
      patterns: [
        "defp thread_key(%ExecutionRequest{session_key:",
        "defp thread_key(_)",
        "infer_conversation_key(",
        "conversation_key ="
      ]
    },
    %{
      code: :gateway_auto_resume_mutation,
      message: "Gateway must not read chat state to mutate inbound execution requests",
      files: ["apps/lemon_gateway/lib/**/*.ex"],
      patterns: [
        "LemonCore.ChatStateStore.get(",
        "LemonCore.Store.get_chat_state(",
        "resolve_auto_resume(",
        "maybe_apply_auto_resume("
      ]
    },
    %{
      code: :gateway_job_compatibility,
      message: "Gateway run handling must not keep legacy Job compatibility branches",
      files: ["apps/lemon_gateway/lib/lemon_gateway/run.ex"],
      patterns: ["def handle_cast({:steer, %Job", "def handle_cast({:steer_backlog, %Job"]
    },
    %{
      code: :heartbeat_store_wrapper_bypass,
      message: "Heartbeat state must go through LemonCore.HeartbeatStore",
      files: [
        "apps/lemon_automation/lib/**/*.ex",
        "apps/lemon_control_plane/lib/**/*.ex",
        "apps/lemon_core/lib/**/*.ex"
      ],
      exclude: [
        "apps/lemon_core/lib/lemon_core/heartbeat_store.ex",
        "apps/lemon_core/lib/lemon_core/store.ex"
      ],
      patterns: [
        "LemonCore.Store.get(:heartbeat_config",
        "LemonCore.Store.put(:heartbeat_config",
        "LemonCore.Store.delete(:heartbeat_config",
        "LemonCore.Store.list(:heartbeat_config",
        "LemonCore.Store.get(:heartbeat_last",
        "LemonCore.Store.put(:heartbeat_last",
        "LemonCore.Store.delete(:heartbeat_last",
        "LemonCore.Store.list(:heartbeat_last"
      ]
    },
    %{
      code: :exec_approval_store_wrapper_bypass,
      message: "Execution approval state must go through LemonCore.ExecApprovalStore",
      files: ["apps/lemon_core/lib/**/*.ex", "apps/lemon_control_plane/lib/**/*.ex"],
      exclude: [
        "apps/lemon_core/lib/lemon_core/exec_approval_store.ex",
        "apps/lemon_core/lib/lemon_core/store.ex"
      ],
      patterns: [
        "LemonCore.Store.get(:exec_approvals_policy",
        "LemonCore.Store.put(:exec_approvals_policy",
        "LemonCore.Store.list(:exec_approvals_policy",
        "LemonCore.Store.get(:exec_approvals_policy_agent",
        "LemonCore.Store.put(:exec_approvals_policy_agent",
        "LemonCore.Store.list(:exec_approvals_policy_agent",
        "LemonCore.Store.get(:exec_approvals_policy_session",
        "LemonCore.Store.put(:exec_approvals_policy_session",
        "LemonCore.Store.list(:exec_approvals_policy_session",
        "LemonCore.Store.get(:exec_approvals_policy_node",
        "LemonCore.Store.put(:exec_approvals_policy_node",
        "LemonCore.Store.list(:exec_approvals_policy_node",
        "LemonCore.Store.get(:exec_approvals_policy_map",
        "LemonCore.Store.put(:exec_approvals_policy_map",
        "LemonCore.Store.get(:exec_approvals_policy_node_map",
        "LemonCore.Store.put(:exec_approvals_policy_node_map",
        "LemonCore.Store.get(:exec_approvals_pending",
        "LemonCore.Store.put(:exec_approvals_pending",
        "LemonCore.Store.delete(:exec_approvals_pending",
        "LemonCore.Store.list(:exec_approvals_pending"
      ]
    },
    %{
      code: :router_agent_endpoint_store_bypass,
      message: "Agent endpoint storage must go through LemonRouter.AgentEndpointStore",
      files: ["apps/lemon_router/lib/**/*.ex", "apps/lemon_control_plane/lib/**/*.ex"],
      exclude: [
        "apps/lemon_router/lib/lemon_router/agent_endpoint_store.ex",
        "apps/lemon_core/lib/lemon_core/store.ex"
      ],
      patterns: [
        "LemonCore.Store.get(:agent_endpoints",
        "LemonCore.Store.put(:agent_endpoints",
        "LemonCore.Store.delete(:agent_endpoints",
        "LemonCore.Store.list(:agent_endpoints"
      ]
    },
    %{
      code: :sms_inbox_store_bypass,
      message: "SMS inbox storage must go through LemonGateway.Sms.InboxStore",
      files: ["apps/lemon_gateway/lib/**/*.ex"],
      exclude: [
        "apps/lemon_gateway/lib/lemon_gateway/sms/inbox_store.ex",
        "apps/lemon_core/lib/lemon_core/store.ex"
      ],
      patterns: [
        "LemonCore.Store.get(:sms_inbox",
        "LemonCore.Store.put(:sms_inbox",
        "LemonCore.Store.delete(:sms_inbox",
        "LemonCore.Store.list(:sms_inbox"
      ]
    },
    %{
      code: :control_plane_store_wrapper_bypass,
      message:
        "Control-plane persisted state must use typed wrappers instead of raw store tables",
      files: ["apps/lemon_control_plane/lib/**/*.ex"],
      exclude: [
        "apps/lemon_control_plane/lib/lemon_control_plane/config_store.ex",
        "apps/lemon_control_plane/lib/lemon_control_plane/tts_store.ex",
        "apps/lemon_control_plane/lib/lemon_control_plane/voicewake_store.ex",
        "apps/lemon_control_plane/lib/lemon_control_plane/wizard_store.ex",
        "apps/lemon_control_plane/lib/lemon_control_plane/usage_store.ex",
        "apps/lemon_control_plane/lib/lemon_control_plane/talk_mode_store.ex",
        "apps/lemon_control_plane/lib/lemon_control_plane/agent_file_store.ex",
        "apps/lemon_control_plane/lib/lemon_control_plane/device_pairing_store.ex",
        "apps/lemon_control_plane/lib/lemon_control_plane/agent_identity_store.ex",
        "apps/lemon_control_plane/lib/lemon_control_plane/update_store.ex",
        "apps/lemon_control_plane/lib/lemon_control_plane/skills_config_store.ex",
        "apps/lemon_control_plane/lib/lemon_control_plane/node_store.ex",
        "apps/lemon_core/lib/lemon_core/store.ex"
      ],
      patterns: [
        "LemonCore.Store.get(:agents",
        "LemonCore.Store.put(:agents",
        "LemonCore.Store.delete(:agents",
        "LemonCore.Store.list(:agents",
        "LemonCore.Store.get(:system_config",
        "LemonCore.Store.put(:system_config",
        "LemonCore.Store.list(:system_config",
        "LemonCore.Store.get(:update_config",
        "LemonCore.Store.put(:update_config",
        "LemonCore.Store.delete(:update_config",
        "LemonCore.Store.list(:update_config",
        "LemonCore.Store.get(:pending_update",
        "LemonCore.Store.put(:pending_update",
        "LemonCore.Store.delete(:pending_update",
        "LemonCore.Store.list(:pending_update",
        "LemonCore.Store.get(:skills_config",
        "LemonCore.Store.put(:skills_config",
        "LemonCore.Store.delete(:skills_config",
        "LemonCore.Store.list(:skills_config",
        "LemonCore.Store.get(:tts_config",
        "LemonCore.Store.put(:tts_config",
        "LemonCore.Store.get(:voicewake_config",
        "LemonCore.Store.put(:voicewake_config",
        "LemonCore.Store.get(:wizards",
        "LemonCore.Store.put(:wizards",
        "LemonCore.Store.get(:usage_records",
        "LemonCore.Store.put(:usage_records",
        "LemonCore.Store.get(:usage_data",
        "LemonCore.Store.put(:usage_data",
        "LemonCore.Store.get(:usage_stats",
        "LemonCore.Store.get(:talk_mode",
        "LemonCore.Store.put(:talk_mode",
        "LemonCore.Store.get(:agent_files",
        "LemonCore.Store.put(:agent_files",
        "LemonCore.Store.list(:agent_files",
        "LemonCore.Store.get(:device_pairing",
        "LemonCore.Store.put(:device_pairing",
        "LemonCore.Store.get(:device_pairing_challenges",
        "LemonCore.Store.put(:device_pairing_challenges",
        "LemonCore.Store.delete(:device_pairing_challenges",
        "LemonCore.Store.put(:devices",
        "LemonCore.Store.get(:nodes_pairing",
        "LemonCore.Store.put(:nodes_pairing",
        "LemonCore.Store.list(:nodes_pairing",
        "LemonCore.Store.get(:nodes_pairing_by_code",
        "LemonCore.Store.put(:nodes_pairing_by_code",
        "LemonCore.Store.get(:nodes_registry",
        "LemonCore.Store.put(:nodes_registry",
        "LemonCore.Store.list(:nodes_registry",
        "LemonCore.Store.get(:node_challenges",
        "LemonCore.Store.put(:node_challenges",
        "LemonCore.Store.delete(:node_challenges",
        "LemonCore.Store.get(:node_invocations",
        "LemonCore.Store.put(:node_invocations"
      ]
    },
    %{
      code: :games_raw_store_bypass,
      message: "LemonGames runtime modules must use app-local store wrappers",
      files: ["apps/lemon_games/lib/**/*.ex"],
      exclude: ["apps/lemon_games/lib/**/*store*.ex", "apps/lemon_core/lib/lemon_core/store.ex"],
      patterns: [
        "LemonCore.Store.get(",
        "LemonCore.Store.put(",
        "LemonCore.Store.delete(",
        "LemonCore.Store.list("
      ]
    },
    %{
      code: :forbidden_channels_transport_app_env,
      message:
        "Runtime modules must not read transport config from Application.get_env; use LemonCore.GatewayConfig",
      files: [
        "apps/lemon_channels/lib/**/*.ex",
        "apps/lemon_gateway/lib/**/*.ex",
        "apps/lemon_core/lib/**/*.ex"
      ],
      exclude: [
        "apps/lemon_core/lib/lemon_core/gateway_config.ex"
      ],
      patterns: [
        "Application.get_env(:lemon_channels, :telegram)",
        "Application.get_env(:lemon_channels, :discord)",
        "Application.get_env(:lemon_channels, :xmtp)",
        "Application.get_env(:lemon_channels, :gateway)"
      ]
    },
    %{
      code: :forbidden_router_policy_app_env,
      message:
        "Runtime modules must not read router policy from Application.get_env; use config defaults or PolicyStore",
      files: [
        "apps/lemon_router/lib/**/*.ex"
      ],
      exclude: [],
      patterns: [
        "Application.get_env(:lemon_router, :default_model)",
        "Application.get_env(:lemon_router, :agent_policies)",
        "Application.get_env(:lemon_router, :runtime_policy)"
      ]
    },
    %{
      code: :forbidden_provider_direct_env,
      message:
        "Provider modules must resolve config-backed provider env vars via LemonCore.ProviderConfigResolver",
      files: [
        "apps/ai/lib/ai/providers/google_vertex.ex",
        "apps/ai/lib/ai/providers/azure_openai_responses.ex",
        "apps/ai/lib/ai/providers/bedrock.ex"
      ],
      exclude: [],
      patterns: [
        ~s|System.get_env("GOOGLE_CLOUD_PROJECT")|,
        ~s|System.get_env("GCLOUD_PROJECT")|,
        ~s|System.get_env("GOOGLE_CLOUD_LOCATION")|,
        ~s|System.get_env("AZURE_OPENAI_DEPLOYMENT_NAME_MAP")|,
        ~s|System.get_env("AZURE_OPENAI_API_VERSION")|,
        ~s|System.get_env("AZURE_OPENAI_BASE_URL")|,
        ~s|System.get_env("AZURE_OPENAI_RESOURCE_NAME")|,
        ~s|System.get_env("AWS_REGION")|,
        ~s|System.get_env("AWS_DEFAULT_REGION")|
      ]
    }
  ]

  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())

    issues =
      @rules
      |> Enum.flat_map(&rule_issues(root, &1))
      |> Enum.sort_by(& &1.path)

    report = %{root: root, issue_count: length(issues), issues: issues}

    if issues == [], do: {:ok, report}, else: {:error, report}
  end

  defp rule_issues(root, rule) do
    root
    |> source_files(rule.files)
    |> reject_excluded(root, Map.get(rule, :exclude, []))
    |> Enum.reject(&(Path.basename(&1) == "architecture_rules_check.ex"))
    |> Enum.flat_map(fn file ->
      source = File.read!(file)

      rule.patterns
      |> Enum.filter(&String.contains?(source, &1))
      |> Enum.map(fn pattern ->
        %{
          code: rule.code,
          message: "#{rule.message} (matched #{inspect(pattern)})",
          path: Path.relative_to(file, root)
        }
      end)
    end)
  end

  defp source_files(root, globs) do
    globs
    |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(root, glob)) end)
    |> Enum.uniq()
  end

  defp reject_excluded(files, _root, []), do: files

  defp reject_excluded(files, root, globs) do
    excluded =
      globs
      |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(root, glob)) end)
      |> MapSet.new()

    Enum.reject(files, &MapSet.member?(excluded, &1))
  end
end
