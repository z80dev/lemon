defmodule LemonControlPlane.ACPTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias LemonControlPlane.ACP
  alias LemonControlPlane.ACP.NDJSON
  alias LemonControlPlane.HTTP.Router
  alias LemonCore.Store

  setup do
    keys = [:acp_submitter, :acp_waiter, :acp_canceller, :acp_api_token]
    previous = Map.new(keys, &{&1, Application.get_env(:lemon_control_plane, &1)})

    if :ets.whereis(:lemon_control_plane_acp_sessions) != :undefined do
      :ets.delete_all_objects(:lemon_control_plane_acp_sessions)
    end

    clear_acp_session_store()
    clear_exec_approvals()

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value) do
          Application.delete_env(:lemon_control_plane, key)
        else
          Application.put_env(:lemon_control_plane, key, value)
        end
      end

      if :ets.whereis(:lemon_control_plane_acp_sessions) != :undefined do
        :ets.delete_all_objects(:lemon_control_plane_acp_sessions)
      end

      clear_acp_session_store()
      clear_exec_approvals()
    end)

    :ok
  end

  test "initializes with honest preview capabilities" do
    {:ok, response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "1",
          "clientCapabilities" => %{
            "fs" => %{
              "readTextFile" => true,
              "writeTextFile" => false,
              "deleteFile" => true,
              "renameFile" => false
            }
          }
        }
      })

    result = response["result"]

    assert response["jsonrpc"] == "2.0"
    assert result["protocolVersion"] == "1"
    assert result["agentInfo"]["name"] == "Lemon"
    assert result["agentCapabilities"]["promptCapabilities"]["image"] == false
    assert result["agentCapabilities"]["promptCapabilities"]["embeddedContext"] == false
    assert result["agentCapabilities"]["loadSession"] == true
    assert result["agentCapabilities"]["sessionCapabilities"]["list"] == %{}
    assert result["_meta"]["lemon"]["beamSupervisedRuns"] == true
    assert result["_meta"]["lemon"]["clientCapabilities"]["fs"]["readTextFile"] == true
    assert result["_meta"]["lemon"]["clientCapabilities"]["fs"]["writeTextFile"] == false
    assert result["_meta"]["lemon"]["clientCapabilities"]["fs"]["deleteFile"] == true
    assert result["_meta"]["lemon"]["clientCapabilities"]["fs"]["renameFile"] == false
  end

  test "creates an ACP session and submits a prompt through the Lemon router boundary" do
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "run_acp_123"}
    end)

    Application.put_env(:lemon_control_plane, :acp_waiter, fn "run_acp_123", 25 ->
      {:ok, %{"runId" => "run_acp_123", "ok" => true, "answer" => "done", "error" => nil}}
    end)

    session_id = new_session()

    {:ok, response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "prompt-1",
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => session_id,
          "prompt" => [
            %{"type" => "text", "text" => "inspect this file"},
            %{
              "type" => "resource_link",
              "name" => "mix.exs",
              "uri" => "file:///home/z80/dev/lemon/mix.exs",
              "mimeType" => "text/x-elixir"
            }
          ],
          "_meta" => %{
            "lemon" => %{
              "timeoutMs" => 25,
              "model" => "openai:gpt-5",
              "toolPolicy" => %{"mode" => "review"}
            }
          }
        }
      })

    assert response["result"]["stopReason"] == "end_turn"
    assert response["result"]["_meta"]["lemon"]["runId"] == "run_acp_123"
    assert response["result"]["_meta"]["lemon"]["status"] == "completed"
    assert response["result"]["_meta"]["lemon"]["answer"] == "done"

    assert_receive {:submitted, request}
    assert request.origin == :control_plane
    assert request.model == "openai:gpt-5"
    assert request.cwd == "/home/z80/dev/lemon"
    assert request.prompt =~ "inspect this file"
    assert request.prompt =~ "[resource link: name=mix.exs uri=file:///home/z80/dev/lemon/mix.exs"
    assert request.meta.origin == :acp
    assert request.meta.acp_session_id == session_id
    assert request.meta.acp_resource_link_count == 1
    assert request.tool_policy == %{"mode" => "review"}
  end

  test "records safe ACP client filesystem capability summaries on sessions and prompts" do
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:submitted_with_capabilities, request})
      {:ok, "run_acp_capabilities"}
    end)

    session_id =
      new_session(
        client_capabilities: %{
          "fs" => %{
            "readTextFile" => true,
            "writeTextFile" => true,
            "deleteFile" => true,
            "renameFile" => true
          }
        }
      )

    {:ok, list_response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "list-capabilities",
        "method" => "session/list",
        "params" => %{"cwd" => "/home/z80/dev/lemon"}
      })

    listed =
      Enum.find(list_response["result"]["sessions"], &(&1["sessionId"] == session_id))

    assert listed["_meta"]["lemon"]["clientCapabilities"]["fs"]["readTextFile"] == true
    assert listed["_meta"]["lemon"]["clientCapabilities"]["fs"]["writeTextFile"] == true
    assert listed["_meta"]["lemon"]["clientCapabilities"]["fs"]["deleteFile"] == true
    assert listed["_meta"]["lemon"]["clientCapabilities"]["fs"]["renameFile"] == true

    {:ok, resume_response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "resume-capabilities",
        "method" => "session/resume",
        "params" => %{
          "sessionId" => session_id,
          "cwd" => "/home/z80/dev/lemon",
          "mcpServers" => []
        }
      })

    assert resume_response["result"]["_meta"]["lemon"]["clientCapabilities"]["fs"][
             "readTextFile"
           ] == true

    assert resume_response["result"]["_meta"]["lemon"]["clientCapabilities"]["fs"][
             "writeTextFile"
           ] == true

    assert resume_response["result"]["_meta"]["lemon"]["clientCapabilities"]["fs"][
             "deleteFile"
           ] == true

    assert resume_response["result"]["_meta"]["lemon"]["clientCapabilities"]["fs"][
             "renameFile"
           ] == true

    {:ok, prompt_response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "prompt-capabilities",
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => session_id,
          "prompt" => [%{"type" => "text", "text" => "inspect capability gates"}],
          "_meta" => %{"lemon" => %{"wait" => false}}
        }
      })

    fs = prompt_response["result"]["_meta"]["lemon"]["clientCapabilities"]["fs"]
    assert fs["readTextFile"] == true
    assert fs["writeTextFile"] == true
    assert fs["deleteFile"] == true
    assert fs["renameFile"] == true

    assert_receive {:submitted_with_capabilities, request}
    assert request.meta.acp_client_capabilities["fs"]["readTextFile"] == true
    assert request.meta.acp_client_capabilities["fs"]["writeTextFile"] == true
    assert request.meta.acp_client_capabilities["fs"]["deleteFile"] == true
    assert request.meta.acp_client_capabilities["fs"]["renameFile"] == true
    assert request.meta.acp_client_fs_read_text_file == true
    assert request.meta.acp_client_fs_write_text_file == true
    assert request.meta.acp_client_fs_delete_file == true
    assert request.meta.acp_client_fs_rename_file == true
  end

  test "can queue a prompt without waiting for completion" do
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "run_acp_queued"}
    end)

    session_id = new_session()

    {:ok, response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "prompt-queued",
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => session_id,
          "prompt" => [%{"type" => "text", "text" => "start work"}],
          "_meta" => %{"lemon" => %{"wait" => false}}
        }
      })

    assert response["result"]["stopReason"] == "end_turn"
    assert response["result"]["_meta"]["lemon"]["status"] == "queued"
    assert response["result"]["_meta"]["lemon"]["queued"] == true
    assert_receive {:submitted, request}
    assert request.meta.acp_wait_requested == false
  end

  test "rejects prompt media types it does not advertise" do
    session_id = new_session()

    {:ok, response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "prompt-image",
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => session_id,
          "prompt" => [%{"type" => "image", "data" => "abc"}]
        }
      })

    assert response["error"]["code"] == -32_602
    assert response["error"]["message"] =~ "image prompt blocks are not enabled"
  end

  test "lists, resumes, cancels, and closes ACP sessions" do
    cancelled = :ets.new(:acp_cancelled_runs, [:set, :public])

    Application.put_env(:lemon_control_plane, :acp_submitter, fn _request ->
      {:ok, "run_for_cancel"}
    end)

    Application.put_env(:lemon_control_plane, :acp_canceller, fn run_id, reason ->
      :ets.insert(cancelled, {run_id, reason})
      :ok
    end)

    session_id = new_session()
    queue_prompt(session_id)

    {:ok, list_response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "list",
        "method" => "session/list",
        "params" => %{"cwd" => "/home/z80/dev/lemon"}
      })

    assert Enum.any?(list_response["result"]["sessions"], &(&1["sessionId"] == session_id))

    {:ok, cancel_response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "cancel",
        "method" => "session/cancel",
        "params" => %{"sessionId" => session_id}
      })

    assert cancel_response["result"] == %{}
    assert :ets.lookup(cancelled, "run_for_cancel") == [{"run_for_cancel", :acp_cancel}]

    {:ok, close_response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "close",
        "method" => "session/close",
        "params" => %{"sessionId" => session_id}
      })

    assert close_response["result"] == %{}

    {:ok, resume_response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "resume",
        "method" => "session/resume",
        "params" => %{
          "sessionId" => session_id,
          "cwd" => "/home/z80/dev/lemon",
          "mcpServers" => []
        }
      })

    assert resume_response["result"]["_meta"]["lemon"]["sessionKey"] =~ "agent:default:acp-"

    {:ok, load_response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "load",
        "method" => "session/load",
        "params" => %{
          "sessionId" => session_id,
          "cwd" => "/home/z80/dev/lemon",
          "mcpServers" => []
        }
      })

    assert load_response["result"]["_meta"]["lemon"]["sessionKey"] =~ "agent:default:acp-"

    :ets.delete(cancelled)
  end

  test "persists ACP sessions beyond the process-local ETS cache" do
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:submitted_after_reload, request})
      {:ok, "run_after_reload"}
    end)

    session_id = new_session()
    :ets.delete(:lemon_control_plane_acp_sessions)

    {:ok, list_response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "list-after-reload",
        "method" => "session/list",
        "params" => %{"cwd" => "/home/z80/dev/lemon"}
      })

    assert Enum.any?(list_response["result"]["sessions"], &(&1["sessionId"] == session_id))

    {:ok, prompt_response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "prompt-after-reload",
        "method" => "session/prompt",
        "params" => %{
          "sessionId" => session_id,
          "prompt" => [%{"type" => "text", "text" => "continue"}],
          "_meta" => %{"lemon" => %{"wait" => false}}
        }
      })

    assert prompt_response["result"]["_meta"]["lemon"]["status"] == "queued"
    assert_receive {:submitted_after_reload, request}
    assert request.session_key =~ "agent:default:acp-"
    assert request.prompt == "continue"
  end

  test "serves ACP JSON-RPC over HTTP with optional bearer auth" do
    Application.put_env(:lemon_control_plane, :acp_api_token, "acp-secret")

    missing =
      :post
      |> json_conn("/acp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      |> Router.call([])

    assert missing.status == 401

    assert Jason.decode!(missing.resp_body)["error"]["message"] ==
             "authorization token is required"

    ok =
      :post
      |> json_conn("/acp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      |> put_req_header("authorization", "Bearer acp-secret")
      |> Router.call([])

    assert ok.status == 200
    assert Jason.decode!(ok.resp_body)["result"]["agentInfo"]["name"] == "Lemon"
  end

  test "serves ACP JSON-RPC over newline-delimited stdio messages" do
    [encoded] =
      NDJSON.responses_for_line(
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize"}) <> "\n"
      )

    assert Jason.decode!(encoded)["result"]["agentInfo"]["name"] == "Lemon"
    assert NDJSON.responses_for_line("\n") == []

    [parse_error] = NDJSON.responses_for_line("{not-json}\n")
    assert Jason.decode!(parse_error)["error"]["code"] == -32_700
  end

  test "emits ACP session/update notifications while stdio prompt waits" do
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:submitted_streaming, request})
      {:ok, "run_acp_stream"}
    end)

    session_id = new_session()

    task =
      Task.async(fn ->
        NDJSON.responses_for_line(
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => "prompt-stream",
            "method" => "session/prompt",
            "params" => %{
              "sessionId" => session_id,
              "prompt" => [%{"type" => "text", "text" => "stream please"}],
              "_meta" => %{"lemon" => %{"timeoutMs" => 1_000}}
            }
          }),
          session_update_callback: fn notification ->
            send(parent, {:acp_update, notification})
          end
        )
      end)

    assert_receive {:submitted_streaming, request}
    assert request.prompt == "stream please"
    Process.sleep(20)

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_stream"),
      LemonCore.Event.new(:delta, %{text: "hello"})
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_stream"),
      LemonCore.Event.new(:engine_action, %{
        action: %{id: "tool_1", kind: :exec, title: "Run command"},
        phase: :completed,
        ok: false,
        message: "failed"
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_stream"),
      LemonCore.Event.new(:run_completed, %{
        completed: %{ok: true, answer: "done", error: nil}
      })
    )

    assert_receive {:acp_update,
                    %{
                      "method" => "session/update",
                      "params" => %{
                        "sessionId" => ^session_id,
                        "update" => %{
                          "sessionUpdate" => "agent_message_chunk",
                          "content" => %{"text" => "hello"}
                        }
                      }
                    }}

    assert_receive {:acp_update,
                    %{
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "tool_call_update",
                          "toolCallId" => "tool_1",
                          "kind" => "execute",
                          "status" => "failed"
                        }
                      }
                    }}

    [encoded] = Task.await(task)
    result = Jason.decode!(encoded)["result"]

    assert result["stopReason"] == "end_turn"
    assert result["_meta"]["lemon"]["runId"] == "run_acp_stream"
    assert result["_meta"]["lemon"]["status"] == "completed"
    assert result["_meta"]["lemon"]["answer"] == "done"
  end

  test "performs ACP client file and permission requests while stdio prompt waits" do
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:submitted_client_request, request})
      {:ok, "run_acp_client_requests"}
    end)

    session_id = new_session()

    task =
      Task.async(fn ->
        ACP.handle_jsonrpc(
          %{
            "jsonrpc" => "2.0",
            "id" => "prompt-client-requests",
            "method" => "session/prompt",
            "params" => %{
              "sessionId" => session_id,
              "prompt" => [%{"type" => "text", "text" => "use editor client"}],
              "_meta" => %{"lemon" => %{"timeoutMs" => 1_000}}
            }
          },
          client_request_callback: fn request ->
            send(parent, {:acp_client_request, request})

            case request["method"] do
              "session/request_permission" ->
                {:ok,
                 %{
                   "result" => %{
                     "outcome" => %{"outcome" => "selected", "optionId" => "allow-once"}
                   }
                 }}

              "fs/read_text_file" ->
                {:ok, %{"result" => %{"content" => "unsaved editor buffer\n"}}}

              "fs/write_text_file" ->
                {:ok, %{"result" => nil}}

              "fs/delete_file" ->
                {:ok, %{"result" => nil}}

              "fs/rename_file" ->
                {:ok, %{"result" => nil}}
            end
          end
        )
      end)

    assert_receive {:submitted_client_request, request}
    assert request.prompt == "use editor client"
    Process.sleep(20)

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_client_requests"),
      LemonCore.Event.new(:acp_client_request, %{
        method: "session/request_permission",
        params: %{
          "toolCall" => %{"toolCallId" => "call_1", "title" => "Edit file", "kind" => "edit"},
          "options" => [%{"optionId" => "allow-once", "name" => "Allow once"}]
        }
      })
    )

    read_reply_ref = make_ref()

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_client_requests"),
      LemonCore.Event.new(:acp_client_request, %{
        method: "fs/read_text_file",
        params: %{"path" => "/tmp/editor-buffer.txt", "line" => 1, "limit" => 3},
        reply_to: self(),
        ref: read_reply_ref
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_client_requests"),
      LemonCore.Event.new(:acp_client_request, %{
        method: "fs/write_text_file",
        params: %{"path" => "/tmp/editor-buffer.txt", "content" => "updated"}
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_client_requests"),
      LemonCore.Event.new(:acp_client_request, %{
        method: "fs/delete_file",
        params: %{"path" => "/tmp/old-editor-buffer.txt"}
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_client_requests"),
      LemonCore.Event.new(:acp_client_request, %{
        method: "fs/rename_file",
        params: %{
          "path" => "/tmp/editor-buffer.txt",
          "targetPath" => "/tmp/renamed-editor-buffer.txt"
        }
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_client_requests"),
      LemonCore.Event.new(:run_completed, %{
        completed: %{ok: true, answer: "done", error: nil}
      })
    )

    assert_receive {:acp_client_request, %{"method" => "session/request_permission"}}
    assert_receive {:acp_client_request, %{"method" => "fs/read_text_file"}}

    assert_receive {:acp_client_response, ^read_reply_ref,
                    %{"result" => %{"content" => "unsaved editor buffer\n"}}}

    assert_receive {:acp_client_request, %{"method" => "fs/write_text_file"}}
    assert_receive {:acp_client_request, %{"method" => "fs/delete_file"}}
    assert_receive {:acp_client_request, %{"method" => "fs/rename_file"}}

    {:ok, response} = Task.await(task)
    summaries = response["result"]["_meta"]["lemon"]["clientRequests"]

    assert Enum.map(summaries, & &1["method"]) == [
             "session/request_permission",
             "fs/read_text_file",
             "fs/write_text_file",
             "fs/delete_file",
             "fs/rename_file"
           ]

    assert Enum.at(summaries, 0)["outcome"] == "selected"
    assert Enum.at(summaries, 0)["optionId"] == "allow-once"
    assert Enum.at(summaries, 1)["contentBytes"] == byte_size("unsaved editor buffer\n")
    assert is_binary(Enum.at(summaries, 1)["contentHash"])
    refute inspect(summaries) =~ "unsaved editor buffer"
    refute inspect(summaries) =~ "/tmp/editor-buffer.txt"
  end

  test "bridges matching exec approval requests to ACP session request permission" do
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:submitted_for_approval, request})
      {:ok, "run_acp_approval"}
    end)

    session_id = new_session()

    prompt_task =
      Task.async(fn ->
        ACP.handle_jsonrpc(
          %{
            "jsonrpc" => "2.0",
            "id" => "prompt-approval",
            "method" => "session/prompt",
            "params" => %{
              "sessionId" => session_id,
              "prompt" => [%{"type" => "text", "text" => "edit with approval"}],
              "_meta" => %{"lemon" => %{"timeoutMs" => 1_000}}
            }
          },
          client_request_callback: fn request ->
            send(parent, {:acp_permission_request, request})

            {:ok,
             %{
               "result" => %{
                 "outcome" => %{"outcome" => "selected", "optionId" => "allow-once"}
               }
             }}
          end
        )
      end)

    assert_receive {:submitted_for_approval, request}

    approval_task =
      Task.async(fn ->
        LemonCore.ExecApprovals.request(%{
          run_id: "run_acp_approval",
          session_key: request.session_key,
          tool: "edit",
          action: %{"path" => "/tmp/private.txt", "content" => "secret"},
          rationale: "Tool execution: edit",
          expires_in_ms: 1_000
        })
      end)

    assert_receive {:acp_permission_request,
                    %{
                      "method" => "session/request_permission",
                      "params" => %{
                        "sessionId" => ^session_id,
                        "toolCall" => %{
                          "kind" => "edit",
                          "status" => "pending"
                        },
                        "options" => options
                      }
                    }}

    assert Enum.any?(options, &(&1["optionId"] == "allow-once"))
    assert Enum.all?(options, &(&1["kind"] in ["allow_once", "allow_always", "reject_once"]))
    assert {:ok, :approved, :approve_once} = Task.await(approval_task)

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_approval"),
      LemonCore.Event.new(:run_completed, %{
        completed: %{ok: true, answer: "done", error: nil}
      })
    )

    {:ok, response} = Task.await(prompt_task)
    [summary] = response["result"]["_meta"]["lemon"]["clientRequests"]

    assert summary["method"] == "session/request_permission"
    assert summary["outcome"] == "selected"
    assert summary["optionId"] == "allow-once"
    refute inspect(summary) =~ "/tmp/private.txt"
    refute inspect(summary) =~ "secret"
  end

  defp new_session(opts \\ []) do
    client_capabilities = Keyword.get(opts, :client_capabilities)

    {:ok, response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => "new",
        "method" => "session/new",
        "params" =>
          %{
            "cwd" => "/home/z80/dev/lemon",
            "mcpServers" => []
          }
          |> maybe_put_client_capabilities(client_capabilities)
      })

    response["result"]["sessionId"]
  end

  defp maybe_put_client_capabilities(params, nil), do: params

  defp maybe_put_client_capabilities(params, capabilities),
    do: Map.put(params, "clientCapabilities", capabilities)

  defp queue_prompt(session_id) do
    ACP.handle_jsonrpc(%{
      "jsonrpc" => "2.0",
      "id" => "prompt",
      "method" => "session/prompt",
      "params" => %{
        "sessionId" => session_id,
        "prompt" => [%{"type" => "text", "text" => "work"}],
        "_meta" => %{"lemon" => %{"wait" => false}}
      }
    })
  end

  defp json_conn(method, path, body) do
    method
    |> conn(path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  defp clear_acp_session_store do
    for {session_id, _session} <- Store.list(:acp_sessions) do
      Store.delete(:acp_sessions, session_id)
    end
  end

  defp clear_exec_approvals do
    for table <- [
          :exec_approvals_pending,
          :exec_approvals_policy,
          :exec_approvals_policy_agent,
          :exec_approvals_policy_session,
          :exec_approvals_policy_node
        ],
        {key, _value} <- Store.list(table) do
      Store.delete(table, key)
    end
  end
end
