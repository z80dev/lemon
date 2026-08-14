defmodule LemonCore.Quality.ArchitectureRulesCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.ArchitectureRulesCheck

  @repo_root Path.expand("../../../../..", __DIR__)

  test "passes for the current repository" do
    assert {:ok, report} = ArchitectureRulesCheck.run(root: @repo_root)
    assert report.issue_count == 0
  end

  test "ignores app scratch directories" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/coding_agent/tmp/scratch.ex",
        """
        defmodule Scratch do
          LemonRouter.SessionRegistry
        end
        """
      )

      assert {:ok, report} = ArchitectureRulesCheck.run(root: tmp_dir)
      assert report.issue_count == 0
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "does not traverse ignored symlink loops" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/coding_agent/tmp/loop/a/bad.ex",
        """
        defmodule BadScratch do
          LemonRouter.SessionRegistry
        end
        """
      )

      File.ln_s!(
        Path.join(tmp_dir, "apps/coding_agent/tmp/loop"),
        Path.join(tmp_dir, "apps/coding_agent/tmp/loop/a/back")
      )

      assert {:ok, report} = ArchitectureRulesCheck.run(root: tmp_dir)
      assert report.issue_count == 0
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags forbidden router outbound payload construction" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_router/lib/lemon_router/bad.ex",
        """
        defmodule LemonRouter.Bad do
          alias LemonChannels.OutboundPayload
          def bad, do: %OutboundPayload{}
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :router_outbound_payload and
                 issue.path == "apps/lemon_router/lib/lemon_router/bad.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags queue_mode in the gateway execution contract" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_gateway/lib/lemon_gateway/execution_request.ex",
        """
        defmodule LemonGateway.ExecutionRequest do
          defstruct [:run_id, :queue_mode]
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :gateway_execution_queue_mode
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags legacy gateway runtime submit wrappers" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_gateway/lib/lemon_gateway/runtime.ex",
        """
        defmodule LemonGateway.Runtime do
          def submit(request), do: request
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :gateway_legacy_runtime_submit
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags raw shared-domain store access in control plane code" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_control_plane/lib/lemon_control_plane/methods/bad.ex",
        """
        defmodule LemonControlPlane.Methods.Bad do
          def bad(run_id), do: LemonCore.Store.get_run(run_id)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :wrapper_bypass and
                 issue.path == "apps/lemon_control_plane/lib/lemon_control_plane/methods/bad.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags router-internal session registry access outside lemon_router" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_channels/lib/lemon_channels/bad_session_state.ex",
        """
        defmodule LemonChannels.BadSessionState do
          def bad(session_key), do: Registry.lookup(LemonRouter.SessionRegistry, session_key)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :router_session_registry_boundary and
                 issue.path == "apps/lemon_channels/lib/lemon_channels/bad_session_state.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags router use of gateway cwd and engine registry" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_router/lib/lemon_router/bad_boundary.ex",
        """
        defmodule LemonRouter.BadBoundary do
          def bad(engine_id) do
            LemonGateway.Cwd.default_cwd()
            LemonGateway.EngineRegistry.get_engine(engine_id)
          end
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, &(&1.code == :router_gateway_cwd_dependency))
      assert Enum.any?(report.issues, &(&1.code == :router_gateway_engine_registry_dependency))
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags channels validation or formatting via EngineRegistry" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_channels/lib/lemon_channels/bad_engine_usage.ex",
        """
        defmodule LemonChannels.BadEngineUsage do
          def bad(token) do
            LemonChannels.EngineRegistry.get_engine("claude")
            LemonChannels.EngineRegistry.format_resume(token)
          end
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :channels_engine_registry_format_validation and
                 issue.path == "apps/lemon_channels/lib/lemon_channels/bad_engine_usage.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags raw generic shared-domain session store access" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_control_plane/lib/lemon_control_plane/methods/sessions_list.ex",
        """
        defmodule LemonControlPlane.Methods.SessionsList do
          def bad, do: LemonCore.Store.list(:sessions_index)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :shared_domain_generic_store_bypass and
                 issue.path ==
                   "apps/lemon_control_plane/lib/lemon_control_plane/methods/sessions_list.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags project binding store bypasses outside typed wrappers" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_control_plane/lib/lemon_control_plane/methods/bad_project.ex",
        """
        defmodule LemonControlPlane.Methods.BadProject do
          def bad(project_id), do: LemonCore.Store.get(:project_overrides, project_id)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :shared_domain_store_wrapper_bypass and
                 issue.path ==
                   "apps/lemon_control_plane/lib/lemon_control_plane/methods/bad_project.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags raw model-policy and idempotency storage bypasses outside typed wrappers" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_core/lib/lemon_core/bad_core_store.ex",
        """
        defmodule LemonCore.BadCoreStore do
          def bad(route_key, scope, key) do
            LemonCore.Store.get(:model_policies, route_key)
            LemonCore.Store.put(:idempotency, "\#{scope}:\#{key}", :ok)
          end
        end
        """
      )

      write_file!(
        tmp_dir,
        "apps/lemon_channels/lib/lemon_channels/bad_model_policy_store.ex",
        """
        defmodule LemonChannels.BadModelPolicyStore do
          def bad(route_key), do: LemonCore.Store.get(:model_policies, route_key)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :shared_domain_store_wrapper_bypass and
                 issue.path == "apps/lemon_core/lib/lemon_core/bad_core_store.ex"
             end)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :model_policy_store_wrapper_bypass and
                 issue.path ==
                   "apps/lemon_channels/lib/lemon_channels/bad_model_policy_store.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "allows typed project binding wrapper to use raw store internally" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_core/lib/lemon_core/project_binding_store.ex",
        """
        defmodule LemonCore.ProjectBindingStore do
          def get(project_id), do: LemonCore.Store.get(:project_overrides, project_id)
        end
        """
      )

      assert {:ok, report} = ArchitectureRulesCheck.run(root: tmp_dir)
      assert report.issue_count == 0
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "allows typed model-policy and idempotency wrappers to use raw store internally" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_channels/lib/lemon_channels/model_policy_store.ex",
        """
        defmodule LemonChannels.ModelPolicyStore do
          def get(route_key), do: LemonCore.Store.get(:model_policies, route_key)
        end
        """
      )

      write_file!(
        tmp_dir,
        "apps/lemon_core/lib/lemon_core/idempotency_store.ex",
        """
        defmodule LemonCore.IdempotencyStore do
          def put(scope, key, value), do: LemonCore.Store.put(:idempotency, "\#{scope}:\#{key}", value)
        end
        """
      )

      assert {:ok, report} = ArchitectureRulesCheck.run(root: tmp_dir)
      assert report.issue_count == 0
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags raw control-plane agent/update/skills storage bypasses outside typed wrappers" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_control_plane/lib/lemon_control_plane/methods/bad_control_store.ex",
        """
        defmodule LemonControlPlane.Methods.BadControlStore do
          def bad(agent_id) do
            LemonCore.Store.get(:agents, agent_id)
            LemonCore.Store.get(:update_config, :global)
            LemonCore.Store.put(:pending_update, :current, %{})
            LemonCore.Store.put(:skills_config, {nil, "skill", :enabled}, true)
          end
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :control_plane_store_wrapper_bypass and
                 issue.path ==
                   "apps/lemon_control_plane/lib/lemon_control_plane/methods/bad_control_store.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "allows typed control-plane agent/update/skills wrappers to use raw store internally" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_control_plane/lib/lemon_control_plane/agent_identity_store.ex",
        """
        defmodule LemonControlPlane.AgentIdentityStore do
          def get(agent_id), do: LemonCore.Store.get(:agents, agent_id)
        end
        """
      )

      write_file!(
        tmp_dir,
        "apps/lemon_control_plane/lib/lemon_control_plane/update_store.ex",
        """
        defmodule LemonControlPlane.UpdateStore do
          def get_config, do: LemonCore.Store.get(:update_config, :global)
          def put_pending(value), do: LemonCore.Store.put(:pending_update, :current, value)
        end
        """
      )

      write_file!(
        tmp_dir,
        "apps/lemon_control_plane/lib/lemon_control_plane/skills_config_store.ex",
        """
        defmodule LemonControlPlane.SkillsConfigStore do
          def put_enabled(cwd, skill_key, enabled),
            do: LemonCore.Store.put(:skills_config, {cwd, skill_key, :enabled}, enabled)
        end
        """
      )

      assert {:ok, report} = ArchitectureRulesCheck.run(root: tmp_dir)
      assert report.issue_count == 0
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags scheduler-side conversation key fallback" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_gateway/lib/lemon_gateway/scheduler.ex",
        """
        defmodule LemonGateway.Scheduler do
          defp thread_key(%ExecutionRequest{session_key: session_key}), do: {:session, session_key}
          defp thread_key(_), do: {:session, "default"}
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :gateway_conversation_key_selection
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags execution-request conversation key inference helpers" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_gateway/lib/lemon_gateway/execution_request.ex",
        """
        defmodule LemonGateway.ExecutionRequest do
          def ensure_conversation_key(request) do
            conversation_key = infer_conversation_key(request)
            %{request | conversation_key: conversation_key}
          end

          defp infer_conversation_key(request), do: request
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :gateway_conversation_key_selection
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags gateway auto-resume request mutation" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_gateway/lib/lemon_gateway/bad_resume.ex",
        """
        defmodule LemonGateway.BadResume do
          def bad(session_key), do: LemonCore.ChatStateStore.get(session_key)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :gateway_auto_resume_mutation and
                 issue.path == "apps/lemon_gateway/lib/lemon_gateway/bad_resume.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags telegram pending compaction prompt mutation in helper modules" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/bad_helper.ex",
        """
        defmodule LemonChannels.Adapters.Telegram.Transport.BadHelper do
          def bad(meta), do: Map.put(meta, :auto_compacted, true)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :telegram_transport_pending_compaction and
                 issue.path ==
                   "apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/bad_helper.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags a chat platform named anywhere in lemon_core lib sources" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_core/lib/lemon_core/bad.ex",
        """
        defmodule LemonCore.Bad do
          def bad, do: {:telegram_msg_resume, :telegram_msg_session}
        end
        """
      )

      write_file!(
        tmp_dir,
        "apps/lemon_core/lib/lemon_core/store/bad_cache.ex",
        """
        defmodule LemonCore.Store.BadCache do
          @cached [:sessions_index, :discord_known_targets]
          def cached, do: @cached
        end
        """
      )

      write_file!(
        tmp_dir,
        "apps/lemon_core/lib/lemon_core/bad_doc.ex",
        """
        defmodule LemonCore.BadDoc do
          @moduledoc "Redacted XMTP launch-gate readiness."
          def noop, do: :ok
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      flagged =
        report.issues
        |> Enum.filter(&(&1.code == :core_vendor_channel_reference))
        |> Enum.map(& &1.path)
        |> Enum.uniq()
        |> Enum.sort()

      assert flagged == [
               "apps/lemon_core/lib/lemon_core/bad.ex",
               "apps/lemon_core/lib/lemon_core/bad_doc.ex",
               "apps/lemon_core/lib/lemon_core/store/bad_cache.ex"
             ]
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags the channel-owned known-target store named in lemon_core lib sources" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_core/lib/lemon_core/bad_wrapper.ex",
        """
        defmodule LemonCore.BadWrapper do
          def bad, do: KnownTargetStore.list()
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :core_known_target_store_leak and
                 issue.path == "apps/lemon_core/lib/lemon_core/bad_wrapper.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "allows lemon_core to name its own store tables" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_core/lib/lemon_core/store/fine_cache.ex",
        """
        defmodule LemonCore.Store.FineCache do
          @cached [:sessions_index, :chat, :runs, :progress]
          def cached, do: @cached
        end
        """
      )

      assert {:ok, report} = ArchitectureRulesCheck.run(root: tmp_dir)
      refute Enum.any?(report.issues, &(&1.code == :core_vendor_channel_reference))
      refute Enum.any?(report.issues, &(&1.code == :core_known_target_store_leak))
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags raw telegram known-target access outside the channels wrapper" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_router/lib/lemon_router/bad_targets.ex",
        """
        defmodule LemonRouter.BadTargets do
          def bad, do: LemonCore.Store.list(:telegram_known_targets)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :telegram_known_targets_wrapper_bypass and
                 issue.path == "apps/lemon_router/lib/lemon_router/bad_targets.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "allows the telegram known-target typed wrapper" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_channels/lib/lemon_channels/telegram/known_target_store.ex",
        """
        defmodule LemonChannels.Telegram.KnownTargetStore do
          def list, do: LemonCore.Store.list(:telegram_known_targets)
        end
        """
      )

      assert {:ok, report} = ArchitectureRulesCheck.run(root: tmp_dir)
      assert report.issue_count == 0
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags heartbeat raw store bypasses outside the typed wrapper" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_automation/lib/lemon_automation/bad_heartbeat.ex",
        """
        defmodule LemonAutomation.BadHeartbeat do
          def bad(agent_id), do: LemonCore.Store.get(:heartbeat_config, agent_id)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :heartbeat_store_wrapper_bypass and
                 issue.path == "apps/lemon_automation/lib/lemon_automation/bad_heartbeat.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags control-plane node storage bypasses outside typed wrappers" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_control_plane/lib/lemon_control_plane/methods/bad_node.ex",
        """
        defmodule LemonControlPlane.Methods.BadNode do
          def bad(node_id), do: LemonCore.Store.get(:nodes_registry, node_id)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :control_plane_store_wrapper_bypass and
                 issue.path ==
                   "apps/lemon_control_plane/lib/lemon_control_plane/methods/bad_node.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags direct Application.get_env for channels transport config in runtime modules" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_channels/lib/lemon_channels/adapters/telegram/bad_config.ex",
        """
        defmodule LemonChannels.Adapters.Telegram.BadConfig do
          def bad do
            Application.get_env(:lemon_channels, :telegram)
          end
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :forbidden_channels_transport_app_env and
                 issue.path ==
                   "apps/lemon_channels/lib/lemon_channels/adapters/telegram/bad_config.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags direct Application.get_env for discord transport config in runtime modules" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_channels/lib/lemon_channels/adapters/discord/bad_config.ex",
        """
        defmodule LemonChannels.Adapters.Discord.BadConfig do
          def bad do
            Application.get_env(:lemon_channels, :discord)
          end
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :forbidden_channels_transport_app_env
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags direct Application.get_env for xmtp transport config in runtime modules" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_channels/lib/lemon_channels/adapters/xmtp/bad_config.ex",
        """
        defmodule LemonChannels.Adapters.Xmtp.BadConfig do
          def bad do
            Application.get_env(:lemon_channels, :xmtp)
          end
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :forbidden_channels_transport_app_env
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags direct Application.get_env for gateway transport overlay in runtime modules" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_channels/lib/lemon_channels/bad_gateway_overlay.ex",
        """
        defmodule LemonChannels.BadGatewayOverlay do
          def bad do
            Application.get_env(:lemon_channels, :gateway)
          end
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :forbidden_channels_transport_app_env
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "allows LemonCore.GatewayConfig to read config_test_mode app env" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_core/lib/lemon_core/gateway_config.ex",
        """
        defmodule LemonCore.GatewayConfig do
          defp test_env? do
            Application.get_env(:lemon_core, :config_test_mode, false)
          end
        end
        """
      )

      assert {:ok, report} = ArchitectureRulesCheck.run(root: tmp_dir)
      assert report.issue_count == 0
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags direct Application.get_env for router default_model in runtime modules" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_router/lib/lemon_router/bad_model_config.ex",
        """
        defmodule LemonRouter.BadModelConfig do
          def bad do
            Application.get_env(:lemon_router, :default_model)
          end
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :forbidden_router_policy_app_env and
                 issue.path == "apps/lemon_router/lib/lemon_router/bad_model_config.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags direct Application.get_env for router agent_policies in runtime modules" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_router/lib/lemon_router/bad_policy_config.ex",
        """
        defmodule LemonRouter.BadPolicyConfig do
          def bad do
            Application.get_env(:lemon_router, :agent_policies)
          end
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :forbidden_router_policy_app_env
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags direct Application.get_env for router runtime_policy in runtime modules" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_router/lib/lemon_router/bad_runtime_policy.ex",
        """
        defmodule LemonRouter.BadRuntimePolicy do
          def bad do
            Application.get_env(:lemon_router, :runtime_policy)
          end
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :forbidden_router_policy_app_env
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags direct provider env reads for config-backed provider values" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_ai/lib/lemon_ai/providers/google_vertex.ex",
        """
        defmodule LemonAi.Providers.GoogleVertex do
          def bad do
            System.get_env("GOOGLE_CLOUD_PROJECT")
          end
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :forbidden_provider_direct_env and
                 issue.path == "apps/lemon_ai/lib/lemon_ai/providers/google_vertex.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "allows platform-auth env fallback for GOOGLE_APPLICATION_CREDENTIALS" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_ai/lib/lemon_ai/providers/google_vertex.ex",
        """
        defmodule LemonAi.Providers.GoogleVertex do
          def ok do
            System.get_env("GOOGLE_APPLICATION_CREDENTIALS")
          end
        end
        """
      )

      assert {:ok, report} = ArchitectureRulesCheck.run(root: tmp_dir)
      assert report.issue_count == 0
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags CodingAgent references outside the coding-agent product apps" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_web/lib/lemon_web/bad_coding_agent.ex",
        """
        defmodule LemonWeb.BadCodingAgent do
          def bad(pid), do: CodingAgent.Session.compact(pid, [])
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :coding_agent_boundary and
                 issue.path == "apps/lemon_web/lib/lemon_web/bad_coding_agent.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "allows CodingAgent references in the apps that ship with the coding agent" do
    tmp_dir = tmp_repo!()

    try do
      for app <- ~w(coding_agent coding_agent_ui lemon_mcp lemon_evals) do
        write_file!(
          tmp_dir,
          "apps/#{app}/lib/#{app}/ok.ex",
          """
          defmodule #{Macro.camelize(app)}.Ok do
            def ok(pid), do: CodingAgent.Session.compact(pid, [])
          end
          """
        )
      end

      assert {:ok, report} = ArchitectureRulesCheck.run(root: tmp_dir)
      assert report.issue_count == 0
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "ignores cross-boundary module names mentioned only in docs, comments or strings" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_web/lib/lemon_web/docs_only.ex",
        ~S'''
        defmodule LemonWeb.DocsOnly do
          @moduledoc """
          Sessions are persisted by CodingAgent.SessionManager and posted via XApi.Client.
          """

          # CodingAgent.Session is the in-process engine.
          def label, do: "CodingAgent.Session"
        end
        '''
      )

      assert {:ok, report} = ArchitectureRulesCheck.run(root: tmp_dir)
      assert report.issue_count == 0
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags XApi references outside the x_api satellite" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_skills/lib/lemon_skills/tools/bad_x_tool.ex",
        """
        defmodule LemonSkills.Tools.BadXTool do
          alias XApi.Client

          def bad(query), do: Client.search(query)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :x_api_boundary and
                 issue.path == "apps/lemon_skills/lib/lemon_skills/tools/bad_x_tool.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags router references to LemonGateway modules" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_router/lib/lemon_router/bad_gateway_call.ex",
        """
        defmodule LemonRouter.BadGatewayCall do
          def bad(request), do: LemonGateway.Runtime.execute(request)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :router_gateway_boundary and
                 issue.path == "apps/lemon_router/lib/lemon_router/bad_gateway_call.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags dynamic-atom gateway back-references from channels and control plane" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_channels/lib/lemon_channels/bad_gateway_atom.ex",
        """
        defmodule LemonChannels.BadGatewayAtom do
          @gateway_config_key :"Elixir.LemonGateway.Config"

          def bad, do: Process.whereis(@gateway_config_key)
        end
        """
      )

      write_file!(
        tmp_dir,
        "apps/lemon_control_plane/lib/lemon_control_plane/methods/bad_gateway_peek.ex",
        """
        defmodule LemonControlPlane.Methods.BadGatewayPeek do
          def bad, do: LemonGateway.TransportRegistry.list()
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :gateway_backref_boundary and
                 issue.path == "apps/lemon_channels/lib/lemon_channels/bad_gateway_atom.ex"
             end)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :gateway_backref_boundary and
                 issue.path ==
                   "apps/lemon_control_plane/lib/lemon_control_plane/methods/bad_gateway_peek.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "flags router run internals referenced from other apps" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_automation/lib/lemon_automation/bad_run_internals.ex",
        """
        defmodule LemonAutomation.BadRunInternals do
          def bad, do: Process.whereis(LemonRouter.RunSupervisor)
        end
        """
      )

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :router_internals_boundary and
                 issue.path == "apps/lemon_automation/lib/lemon_automation/bad_run_internals.ex"
             end)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "allows lemon_router to use its own run internals" do
    tmp_dir = tmp_repo!()

    try do
      write_file!(
        tmp_dir,
        "apps/lemon_router/lib/lemon_router/run_facade.ex",
        """
        defmodule LemonRouter.RunFacade do
          def active_runs, do: Registry.select(LemonRouter.RunRegistry, [])
        end
        """
      )

      assert {:ok, report} = ArchitectureRulesCheck.run(root: tmp_dir)
      assert report.issue_count == 0
    after
      File.rm_rf!(tmp_dir)
    end
  end

  describe "grandfathered allowlist" do
    test "every entry still points at a live reference" do
      for entry <- ArchitectureRulesCheck.grandfathered() do
        path = Path.join(@repo_root, entry.file)

        assert File.exists?(path),
               "stale grandfather entry: #{entry.file} no longer exists — remove it"

        assert File.read!(path) =~ entry.pattern,
               "stale grandfather entry: #{entry.file} no longer references #{entry.pattern} — remove it"
      end
    end

    test "every entry names the app that owns its file" do
      for entry <- ArchitectureRulesCheck.grandfathered() do
        assert String.starts_with?(entry.file, "apps/#{entry.app}/"),
               "grandfather entry for #{entry.file} is filed under app #{entry.app}"
      end
    end
  end

  defp tmp_repo! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "architecture_rules_check_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp write_file!(root, relative_path, contents) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
