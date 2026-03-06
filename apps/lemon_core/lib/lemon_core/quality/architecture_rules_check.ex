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
      patterns: ["LemonChannels.Telegram."]
    },
    %{
      code: :router_channels_runtime_dependency,
      message: "Router must not depend on LemonChannels runtime/config helpers directly",
      files: ["apps/lemon_router/lib/**/*.ex"],
      patterns: ["LemonChannels.GatewayConfig", "LemonChannels.EngineRegistry"]
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
      patterns: [":telegram_msg_resume", ":telegram_msg_session", ":telegram_pending_compaction"]
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
        "LemonCore.Store.delete(:session_overrides"
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
end
