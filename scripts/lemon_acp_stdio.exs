defmodule Lemon.ACPStdioRuntime do
  def maybe_install_fake_runtime do
    if System.get_env("LEMON_ACP_STDIO_FAKE_RUNTIME") in ["1", "true", "TRUE"] do
      Logger.configure(level: :none)
      {:ok, _apps} = Application.ensure_all_started(:lemon_core)
      Application.put_env(:lemon_control_plane, :acp_submitter, &submit/1)
      Application.put_env(:lemon_control_plane, :acp_waiter, &wait/2)
      Application.put_env(:lemon_control_plane, :acp_canceller, fn _run_id, _reason -> :ok end)
    end
  end

  defp submit(request) do
    run_id =
      cond do
        request.prompt =~ "approval bridge" -> "run_acp_external_approval_bridge"
        request.prompt =~ "client request" -> "run_acp_external_client_requests"
        request.prompt =~ "sdk request" -> "run_acp_official_sdk_client_requests"
        request.prompt =~ "stream" -> "run_acp_external_stream"
        true -> "run_acp_external_#{System.unique_integer([:positive])}"
      end

    cond do
      request.prompt =~ "approval bridge" ->
        spawn(fn -> broadcast_approval_bridge(run_id, request.session_key) end)

      request.prompt =~ "client request" ->
        spawn(fn -> broadcast_client_requests(run_id) end)

      request.prompt =~ "sdk request" ->
        spawn(fn -> broadcast_sdk_requests(run_id) end)

      request.prompt =~ "stream" ->
        spawn(fn -> broadcast_stream(run_id) end)

      true ->
        :ok
    end

    {:ok, run_id}
  end

  defp wait(run_id, _timeout_ms) do
    {:ok, %{"runId" => run_id, "ok" => true, "answer" => "done", "error" => nil}}
  end

  defp broadcast_approval_bridge(run_id, session_key) do
    Process.sleep(50)

    LemonCore.ExecApprovals.request(%{
      run_id: run_id,
      session_key: session_key,
      tool: "edit",
      action: %{"path" => "/virtual/editor-buffer.txt", "content" => "updated"},
      rationale: "Tool execution: edit",
      expires_in_ms: 1_000
    })

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:run_completed, %{completed: %{ok: true, answer: "done", error: nil}})
    )
  end

  defp broadcast_client_requests(run_id) do
    Process.sleep(50)

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:acp_client_request, %{
        method: "session/request_permission",
        params: %{
          "toolCall" => %{
            "toolCallId" => "call_permission",
            "title" => "Write editor buffer",
            "kind" => "edit",
            "status" => "pending"
          },
          "options" => [
            %{"optionId" => "allow-once", "name" => "Allow once", "kind" => "allow_once"},
            %{"optionId" => "reject-once", "name" => "Reject", "kind" => "reject_once"}
          ]
        }
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:acp_client_request, %{
        method: "fs/read_text_file",
        params: %{"path" => "/virtual/editor-buffer.txt", "line" => 1, "limit" => 5}
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:acp_client_request, %{
        method: "fs/write_text_file",
        params: %{"path" => "/virtual/editor-buffer.txt", "content" => "updated"}
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:acp_client_request, %{
        method: "fs/delete_file",
        params: %{"path" => "/virtual/old-buffer.txt"}
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:acp_client_request, %{
        method: "fs/rename_file",
        params: %{
          "path" => "/virtual/editor-buffer.txt",
          "targetPath" => "/virtual/new-buffer.txt"
        }
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:run_completed, %{completed: %{ok: true, answer: "done", error: nil}})
    )
  end

  defp broadcast_sdk_requests(run_id) do
    Process.sleep(50)

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:acp_client_request, %{
        method: "session/request_permission",
        params: %{
          "toolCall" => %{
            "toolCallId" => "call_permission",
            "title" => "Write editor buffer",
            "kind" => "edit",
            "status" => "pending"
          },
          "options" => [
            %{"optionId" => "allow-once", "name" => "Allow once", "kind" => "allow_once"},
            %{"optionId" => "reject-once", "name" => "Reject", "kind" => "reject_once"}
          ]
        }
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:acp_client_request, %{
        method: "fs/read_text_file",
        params: %{"path" => "/virtual/editor-buffer.txt", "line" => 1, "limit" => 5}
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:acp_client_request, %{
        method: "fs/write_text_file",
        params: %{"path" => "/virtual/editor-buffer.txt", "content" => "updated"}
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:run_completed, %{completed: %{ok: true, answer: "done", error: nil}})
    )
  end

  defp broadcast_stream(run_id) do
    Process.sleep(50)

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:delta, %{text: "hello"})
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:engine_action, %{
        action: %{id: "tool_1", kind: :exec, title: "Run command"},
        phase: :completed,
        ok: true,
        message: "done"
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(run_id),
      LemonCore.Event.new(:run_completed, %{completed: %{ok: true, answer: "done", error: nil}})
    )
  end
end

Lemon.ACPStdioRuntime.maybe_install_fake_runtime()
LemonControlPlane.ACP.NDJSON.run()
