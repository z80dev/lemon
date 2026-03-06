defmodule LemonCore.Quality.ArchitectureRulesCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.ArchitectureRulesCheck

  @repo_root Path.expand("../../../../..", __DIR__)

  test "passes for the current repository" do
    assert {:ok, report} = ArchitectureRulesCheck.run(root: @repo_root)
    assert report.issue_count == 0
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

  test "flags telegram message-index ownership leaks in lemon_core" do
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

      assert {:error, report} = ArchitectureRulesCheck.run(root: tmp_dir)

      assert Enum.any?(report.issues, fn issue ->
               issue.code == :core_telegram_resume_index_leak and
                 issue.path == "apps/lemon_core/lib/lemon_core/bad.ex"
             end)
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
