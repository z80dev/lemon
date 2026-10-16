defmodule LemonControlPlane.ACPTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias LemonControlPlane.ACP
  alias LemonControlPlane.HTTP.Router
  alias LemonCore.Store

  defmodule InterruptedHistory do
    def session_history(_session_key, _cwd) do
      {:ok,
       [
         %{
           type: :message,
           id: "assistant_interrupted",
           message: %{
             role: "assistant",
             content: [
               %{
                 type: "tool_call",
                 id: "call_interrupted",
                 name: "bash",
                 arguments: %{"command" => "sleep 90"}
               }
             ]
           }
         }
       ]}
    end
  end

  defmodule PlanRuntime do
    def session_plan(key, _cwd, action, _opts) do
      plan =
        case :ets.lookup(__MODULE__, key) do
          [{^key, value}] -> value
          [] -> %{"mode" => "code", "path" => nil, "content" => nil}
        end

      case action do
        :status -> {:ok, plan}
        :enter -> save(key, %{plan | "mode" => "plan"})
        :exit -> save(key, %{plan | "mode" => "code"})
      end
    end

    def tool_policy(:read_only), do: %{profile: :read_only, allow: ["read"], deny: []}

    def compact_session(_key, opts) do
      [{:observer, pid}] = :ets.lookup(__MODULE__, :observer)
      send(pid, {:compact_focus, opts[:custom_instructions]})
      :ok
    end

    defp save(key, plan) do
      :ets.insert(__MODULE__, {key, plan})
      {:ok, plan}
    end
  end

  def pause_permission_resolution(_event, _measurements, %{run_id: run_id} = metadata, {
        run_id,
        owner,
        continuation
      }) do
    monitor = Process.monitor(owner)
    send(owner, {:permission_resolution_paused, self(), metadata})

    receive do
      {:continue_permission_resolution, ^continuation} -> :ok
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
    end

    Process.demonitor(monitor, [:flush])
  end

  def pause_permission_resolution(_event, _measurements, _metadata, _config), do: :ok

  setup do
    keys =
      Enum.map(
        [:acp_submitter, :acp_waiter, :acp_canceller, :acp_api_token],
        &{:lemon_control_plane, &1}
      ) ++ [{:lemon_core, :agent_runtime_provider}]

    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)

    clear_acp_session_store()
    clear_exec_approvals()

    on_exit(fn ->
      for {{app, key}, value} <- previous do
        if is_nil(value) do
          Application.delete_env(app, key)
        else
          Application.put_env(app, key, value)
        end
      end

      clear_acp_session_store()
      clear_exec_approvals()
    end)

    :ok
  end

  test "negotiates numeric ACP protocol and honest prompt capabilities" do
    {:ok, response} =
      ACP.handle_jsonrpc(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => 1,
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
    assert result["protocolVersion"] == 1
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
              "model" => "openai:gpt-5"
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
    assert "edit" in request.tool_policy.require_approval
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

  test "persists ACP sessions beyond the creating process" do
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:submitted_after_reload, request})
      {:ok, "run_after_reload"}
    end)

    session_id = Task.async(fn -> new_session() end) |> Task.await()

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

    assert Jason.decode!(missing.resp_body)["error"]["code"] == "UNAUTHORIZED"
    assert Jason.decode!(missing.resp_body)["error"]["message"] =~ "Authorization: Bearer <token>"
    assert Jason.decode!(missing.resp_body)["error"]["message"] =~ "LEMON_ACP_API_TOKEN"

    ok =
      :post
      |> json_conn("/acp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      |> put_req_header("authorization", "Bearer acp-secret")
      |> Router.call([])

    assert ok.status == 200
    assert Jason.decode!(ok.resp_body)["result"]["agentInfo"]["name"] == "Lemon"
  end

  test "emits ACP session/update notifications while stdio prompt waits" do
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      LemonCore.Bus.broadcast(
        LemonCore.Bus.run_topic(request.run_id),
        LemonCore.Event.new(:engine_action, %{
          action: %{id: "tool_1", kind: :exec, title: "Run command"},
          phase: :started
        })
      )

      send(parent, {:submitted_streaming, request})

      {:ok, request.run_id}
    end)

    session_id = new_session()

    task =
      Task.async(fn ->
        ACP.handle_jsonrpc(
          %{
            "jsonrpc" => "2.0",
            "id" => "prompt-stream",
            "method" => "session/prompt",
            "params" => %{
              "sessionId" => session_id,
              "prompt" => [%{"type" => "text", "text" => "stream please"}],
              "_meta" => %{"lemon" => %{"timeoutMs" => 1_000}}
            }
          },
          session_update_callback: fn notification ->
            send(parent, {:acp_update, notification})
          end
        )
      end)

    assert_receive {:submitted_streaming, request}
    assert request.prompt == "stream please"

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(request.run_id),
      LemonCore.Event.new(:delta, %{text: "hello"})
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(request.run_id),
      LemonCore.Event.new(:engine_action, %{
        action: %{id: "tool_1", kind: :exec, title: "Run command"},
        phase: :completed,
        ok: false,
        message: "failed"
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic(request.run_id),
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
                          "sessionUpdate" => "tool_call",
                          "toolCallId" => "tool_1",
                          "kind" => "execute"
                        }
                      }
                    }}

    assert_receive {:acp_update,
                    %{
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "tool_call_update",
                          "toolCallId" => "tool_1",
                          "status" => "failed"
                        }
                      }
                    }}

    {:ok, response} = Task.await(task)
    result = response["result"]

    assert result["stopReason"] == "end_turn"
    assert result["_meta"]["lemon"]["runId"] == request.run_id
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

    # The prompt turn registers itself as the ACP client bridge for the run once
    # it starts waiting; wait for that rather than sleeping a fixed interval.
    wait_for_acp_registration("run_acp_client_requests")

    # Drive the exchange the way a coding-agent filesystem tool now does: a direct
    # synchronous call against the registered handler, not a bus broadcast. Each
    # call blocks until the handler runs the client callback and replies, so
    # issuing them in sequence reproduces sequential tool execution and pins the
    # order the summaries must appear in.
    assert {:ok, %{"result" => %{"outcome" => %{"optionId" => "allow-once"}}}} =
             LemonCore.ACPClientBridge.request(
               "run_acp_client_requests",
               "session/request_permission",
               %{
                 "toolCall" => %{
                   "toolCallId" => "call_1",
                   "title" => "Edit file",
                   "kind" => "edit"
                 },
                 "options" => [%{"optionId" => "allow-once", "name" => "Allow once"}]
               },
               1_000
             )

    assert {:ok, %{"result" => %{"content" => "unsaved editor buffer\n"}}} =
             LemonCore.ACPClientBridge.request(
               "run_acp_client_requests",
               "fs/read_text_file",
               %{"path" => "/tmp/editor-buffer.txt", "line" => 1, "limit" => 3},
               1_000
             )

    assert {:ok, %{"result" => nil}} =
             LemonCore.ACPClientBridge.request(
               "run_acp_client_requests",
               "fs/write_text_file",
               %{"path" => "/tmp/editor-buffer.txt", "content" => "updated"},
               1_000
             )

    assert {:ok, %{"result" => nil}} =
             LemonCore.ACPClientBridge.request(
               "run_acp_client_requests",
               "fs/delete_file",
               %{"path" => "/tmp/old-editor-buffer.txt"},
               1_000
             )

    assert {:ok, %{"result" => nil}} =
             LemonCore.ACPClientBridge.request(
               "run_acp_client_requests",
               "fs/rename_file",
               %{
                 "path" => "/tmp/editor-buffer.txt",
                 "targetPath" => "/tmp/renamed-editor-buffer.txt"
               },
               1_000
             )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_client_requests"),
      LemonCore.Event.new(:run_completed, %{
        completed: %{ok: true, answer: "done", error: nil}
      })
    )

    assert_receive {:acp_client_request, %{"method" => "session/request_permission"}}
    assert_receive {:acp_client_request, %{"method" => "fs/read_text_file"}}
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

  test "prompt deadline withdraws a permission callback and fails closed" do
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:permission_deadline_run, request})
      {:ok, request.run_id}
    end)

    session_id = new_session()

    prompt =
      Task.async(fn ->
        ACP.prompt(
          %{
            "sessionId" => session_id,
            "prompt" => [%{"type" => "text", "text" => "wait for permission"}],
            "_meta" => %{"lemon" => %{"timeoutMs" => 300}}
          },
          client_request_callback: fn _request ->
            send(parent, {:permission_blocked, self()})

            receive do
              :never -> %{}
            end
          end
        )
      end)

    assert_receive {:permission_deadline_run, request}

    approval =
      Task.async(fn ->
        LemonCore.ExecApprovals.request(%{
          run_id: request.run_id,
          session_key: request.session_key,
          tool: "bash",
          tool_call_id: "native_wait",
          action: %{"command" => "true"}
        })
      end)

    assert_receive {:permission_blocked, callback}

    pending =
      Enum.find_value(LemonCore.ExecApprovalStore.list_pending(), fn {_id, pending} ->
        if pending.run_id == request.run_id, do: pending
      end)

    LemonCore.Bus.broadcast(
      "exec_approvals",
      LemonCore.Event.new(:approval_requested, %{pending: pending})
    )

    refute_receive {:permission_blocked, _duplicate_callback}
    monitor = Process.monitor(callback)
    assert {:error, -32_001, _} = Task.await(prompt, 1_000)
    assert_receive {:DOWN, ^monitor, :process, ^callback, :killed}
    assert {:ok, :denied} = Task.await(approval, 1_000)
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
          tool: "bash",
          tool_call_id: "call_permission_identity",
          action: %{"command" => "printf secret"},
          rationale: "Tool execution: bash",
          expires_in_ms: 1_000
        })
      end)

    assert_receive {:acp_permission_request,
                    %{
                      "method" => "session/request_permission",
                      "params" => %{
                        "sessionId" => ^session_id,
                        "toolCall" => %{
                          "toolCallId" => "call_permission_identity",
                          "title" => "$ printf secret",
                          "rawInput" => %{"command" => "printf secret"},
                          "kind" => "execute",
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
    refute inspect(summary) =~ "secret"
  end

  test "session configuration reaches the real router contract and survives resume" do
    start_plan_runtime()
    previous_api_key = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", "acp-model-selection-test-key")

    on_exit(fn ->
      if previous_api_key,
        do: System.put_env("OPENAI_API_KEY", previous_api_key),
        else: System.delete_env("OPENAI_API_KEY")
    end)

    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:configured_request, request})
      {:ok, "configured-run"}
    end)

    id = new_session()
    model_id = "openai:gpt-4o"

    assert {:ok, %{"result" => _}} =
             rpc("session/set_model", %{"sessionId" => id, "modelId" => model_id})

    assert {:ok, %{"result" => _}} =
             rpc("session/set_config_option", %{
               "sessionId" => id,
               "configId" => "thinking",
               "value" => "high"
             })

    assert {:ok, %{"result" => _}} =
             rpc("session/set_config_option", %{
               "sessionId" => id,
               "configId" => "approval",
               "value" => "never"
             })

    assert {:ok, %{"error" => %{"code" => -32_602}}} =
             rpc("session/set_model", %{
               "sessionId" => id,
               "modelId" => "minimax:MiniMax-M2.7-highspeed"
             })

    queue_prompt(id)
    assert_receive {:configured_request, request}
    assert request.model == model_id
    assert request.meta.thinking_level == "high"
    assert request.tool_policy.profile == :read_only

    assert {:ok, %{"result" => result}} =
             rpc("session/resume", %{"sessionId" => id, "cwd" => "/home/z80/dev/lemon"})

    refute Map.has_key?(result, "modes")
    assert Enum.map(result["configOptions"], & &1["id"]) == ["model", "thinking", "approval"]
    assert Enum.find(result["configOptions"], &(&1["id"] == "model"))["currentValue"] == model_id
  end

  test "/plan toggles native plan mode and no plan mode selector is advertised" do
    start_plan_runtime()
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "plan-run"}
    end)

    {:ok, %{"result" => created}} =
      ACP.handle_jsonrpc(
        %{
          "jsonrpc" => "2.0",
          "id" => "new",
          "method" => "session/new",
          "params" => %{"cwd" => "/home/z80/dev/lemon", "mcpServers" => []}
        },
        session_update_callback: &send(parent, {:bootstrap, &1})
      )

    id = created["sessionId"]
    session = Store.get(:acp_sessions, id)
    refute Map.has_key?(created, "modes")
    assert Enum.map(created["configOptions"], & &1["id"]) == ["model", "thinking", "approval"]

    assert_receive {:bootstrap, %{"params" => %{"update" => %{"availableCommands" => commands}}}}

    names = Enum.map(commands, & &1["name"])
    assert "plan" in names
    refute "approve-plan" in names
    refute "discard-plan" in names

    assert {:ok, %{"error" => %{"code" => -32_601}}} =
             rpc("session/set_mode", %{"sessionId" => id, "modeId" => "plan"})

    assert {:ok, %{"error" => _}} =
             rpc("session/set_config_option", %{
               "sessionId" => id,
               "configId" => "mode",
               "value" => "plan"
             })

    assert {:ok, %{"stopReason" => "end_turn"}} =
             plan_prompt(id, "/plan", &send(parent, {:plan_on, &1}))

    assert_receive {:plan_on, %{"params" => %{"update" => %{"content" => %{"text" => on}}}}}
    assert on =~ "Plan mode on"
    assert {:ok, %{"mode" => "plan"}} = plan_status(session)
    refute_received {:submitted, _}

    queue_prompt(id)
    assert_receive {:submitted, request}
    refute request.tool_policy[:profile] == :read_only
    assert "write" in request.tool_policy.require_approval

    assert {:ok, %{"stopReason" => "end_turn"}} =
             plan_prompt(id, "/plan", &send(parent, {:plan_off, &1}))

    assert_receive {:plan_off, %{"params" => %{"update" => %{"content" => %{"text" => off}}}}}
    assert off =~ "Plan mode off. Nothing was approved"
    assert {:ok, %{"mode" => "code"}} = plan_status(session)

    persisted = Store.get(:acp_sessions, id)
    refute Map.has_key?(persisted, :mode)
    refute Map.has_key?(persisted, :plan)

    assert {:ok, %{"stopReason" => "end_turn"}} =
             ACP.prompt(%{
               "sessionId" => id,
               "prompt" => [
                 %{"type" => "text", "text" => "/compact preserve the approved constraints"}
               ]
             })

    assert_receive {:compact_focus, "preserve the approved constraints"}
  end

  test "/plan with a request enters plan mode once and submits the request" do
    start_plan_runtime()
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "plan-run"}
    end)

    id = new_session()
    session = Store.get(:acp_sessions, id)

    assert {:ok, _} = plan_prompt(id, "/plan  add retries to the fetcher", &send(parent, &1))
    assert_receive %{"params" => %{"update" => %{"content" => %{"text" => "Plan mode on" <> _}}}}
    assert_receive {:submitted, %{prompt: "add retries to the fetcher"}}
    assert {:ok, %{"mode" => "plan"}} = plan_status(session)

    assert {:ok, _} = plan_prompt(id, "/plan refine step two", &send(parent, &1))
    assert_receive {:submitted, %{prompt: "refine step two"}}
    refute_received %{"params" => %{"update" => %{"content" => %{"text" => "Plan mode" <> _}}}}
    assert {:ok, %{"mode" => "plan"}} = plan_status(session)

    assert {:ok, _} = plan_prompt(id, "/planner please", &send(parent, &1))
    assert_receive {:submitted, %{prompt: "/planner please"}}
    assert {:ok, %{"mode" => "plan"}} = plan_status(session)
  end

  test "propose_plan permission offers only approve-and-execute or refine" do
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn _ ->
      send(parent, :plan_run_submitted)
      {:ok, "run_acp_plan"}
    end)

    session_id = new_session()
    session = Store.get(:acp_sessions, session_id)
    continuation = make_ref()
    handler = {__MODULE__, :permission_resolution, continuation}

    :ok =
      :telemetry.attach(
        handler,
        [:lemon, :approvals, :resolved],
        &__MODULE__.pause_permission_resolution/4,
        {"run_acp_plan", parent, continuation}
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    prompt_task =
      Task.async(fn ->
        ACP.handle_jsonrpc(
          %{
            "jsonrpc" => "2.0",
            "id" => "prompt-plan",
            "method" => "session/prompt",
            "params" => %{
              "sessionId" => session_id,
              "prompt" => [%{"type" => "text", "text" => "plan it"}],
              "_meta" => %{"lemon" => %{"timeoutMs" => 1_000}}
            }
          },
          client_request_callback: fn request ->
            send(parent, {:acp_permission_request, request})

            {:ok,
             %{
               "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "reject-once"}}
             }}
          end
        )
      end)

    assert_receive :plan_run_submitted

    approval =
      Task.async(fn ->
        LemonCore.ExecApprovals.request(%{
          run_id: "run_acp_plan",
          session_key: session.session_key,
          tool: "propose_plan",
          tool_call_id: "call_propose",
          action: %{
            "title" => "Fetcher retries",
            "path" => "/private/plans/fetcher-retries-plan.md",
            "plan" => "# Fetcher retries\n1. Add backoff."
          },
          rationale: "Approve plan \"Fetcher retries\" and start implementation?",
          expires_in_ms: 1_000
        })
      end)

    assert_receive {:acp_permission_request,
                    %{
                      "method" => "session/request_permission",
                      "params" => %{
                        "toolCall" => %{
                          "toolCallId" => "call_propose",
                          "title" => "Approve plan: Fetcher retries",
                          "kind" => "other",
                          "content" => [%{"content" => %{"text" => "# Fetcher retries" <> _}}]
                        },
                        "options" => options
                      }
                    }},
                   1_000

    assert Enum.map(options, &{&1["optionId"], &1["name"]}) == [
             {"allow-once", "Approve and execute"},
             {"reject-once", "Refine plan"}
           ]

    assert_receive {:permission_resolution_paused, resolver,
                    %{approval_id: approval_id, decision: :deny}}

    assert {:ok, %{resolution: %{outcome: :denied, decision: :deny}}} =
             LemonCore.ExecApprovalStore.fetch_record(approval_id)

    monitor = Process.monitor(resolver)

    try do
      # Force the broadcast prefix where ACP sees the notification before the
      # native waiter. The real publisher is paused before its Bus broadcast,
      # so killing it here would leave a persisted denial but no waiter reply.
      send(
        prompt_task.pid,
        LemonCore.Event.new(:approval_resolved, %{approval_id: approval_id, decision: :deny})
      )

      refute_receive {:DOWN, ^monitor, :process, ^resolver, _reason}
    after
      send(resolver, {:continue_permission_resolution, continuation})
      Process.demonitor(monitor, [:flush])
    end

    assert {:ok, :denied} = Task.await(approval)

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_plan"),
      LemonCore.Event.new(:run_completed, %{completed: %{ok: true, answer: "done", error: nil}})
    )

    assert {:ok, _} = Task.await(prompt_task)
  end

  test "legacy ACP mode metadata loads without exposing or entering plan mode" do
    start_plan_runtime()
    id = new_session()
    session = Store.get(:acp_sessions, id)

    Store.put(:acp_sessions, id, Map.put(session, :mode, "plan"))
    assert {:ok, result} = ACP.resume_session(%{"sessionId" => id, "cwd" => session.cwd})
    refute Map.has_key?(result, "modes")
    refute Map.has_key?(Store.get(:acp_sessions, id), :mode)
    assert {:ok, %{"mode" => "code"}} = plan_status(session)
  end

  test "an unavailable planning runtime cannot toggle plan mode" do
    Application.delete_env(:lemon_core, :agent_runtime_provider)
    id = new_session()

    assert {:error, -32_000, "native session planning is unavailable"} =
             plan_prompt(id, "/plan", fn _ -> :ok end)
  end

  defp plan_prompt(id, text, callback) do
    ACP.prompt(
      %{
        "sessionId" => id,
        "prompt" => [%{"type" => "text", "text" => text}],
        "_meta" => %{"lemon" => %{"wait" => false}}
      },
      session_update_callback: callback
    )
  end

  defp plan_status(session),
    do: PlanRuntime.session_plan(session.session_key, session.cwd, :status, [])

  defmodule ContextRuntime do
    def session_context_usage(key, cwd) do
      send(:persistent_term.get({__MODULE__, :observer}), {:context_request, key, cwd})

      case :persistent_term.get({__MODULE__, :result}) do
        :report ->
          ids = ~w(system_prompt tool_definitions skills context_files memory user_messages
                   assistant_messages tool_results summaries)a

          tokens = [2_000, 6_000, 0, 1_000, 0, 500, 1_500, 9_000, 0]

          {:ok,
           %{
             live: false,
             overhead: :snapshot,
             model: %{provider: "anthropic", id: "claude-sonnet-4-5"},
             window: 100_000,
             used_tokens: 20_000,
             source: "usage",
             estimated_tokens: 18_000,
             auto_compaction: %{
               enabled: true,
               threshold_tokens: 84_000,
               reserve_tokens: 16_000,
               headroom_tokens: 64_000
             },
             categories:
               Enum.zip_with(ids, tokens, &%{id: &1, tokens: &2, percent: nil, items: 1}),
             top: [%{category: :tool_results, label: "bash result #4", tokens: 9_000}],
             message_count: 4,
             measured_at: 1
           }}

        error ->
          error
      end
    end
  end

  test "/context shows the server breakdown and a matching usage update" do
    :persistent_term.put({ContextRuntime, :observer}, self())
    :persistent_term.put({ContextRuntime, :result}, :report)
    :ok = LemonCore.AgentRuntime.register(ContextRuntime)
    parent = self()

    {:ok, %{"result" => %{"sessionId" => id}}} =
      ACP.handle_jsonrpc(
        %{
          "jsonrpc" => "2.0",
          "id" => "new",
          "method" => "session/new",
          "params" => %{"cwd" => "/home/z80/dev/lemon", "mcpServers" => []}
        },
        session_update_callback: &send(parent, {:bootstrap, &1})
      )

    assert_receive {:bootstrap,
                    %{
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "available_commands_update",
                          "availableCommands" => commands
                        }
                      }
                    }}

    assert %{"description" => "Show context-window usage by category"} =
             Enum.find(commands, &(&1["name"] == "context"))

    session = Store.get(:acp_sessions, id)

    assert {:ok, %{"stopReason" => "end_turn"}} =
             ACP.prompt(
               %{"sessionId" => id, "prompt" => [%{"type" => "text", "text" => "/context"}]},
               session_update_callback: &send(parent, {:context, &1})
             )

    key = session.session_key
    cwd = session.cwd
    assert_receive {:context_request, ^key, ^cwd}

    assert_receive {:context,
                    %{
                      "params" => %{
                        "update" => %{"sessionUpdate" => "usage_update"} = usage
                      }
                    }}

    assert usage["size"] == 100_000
    assert usage["used"] == 20_000
    assert usage["_meta"]["lemon"]["context"]["usedTokens"] == 20_000

    assert_receive {:context,
                    %{
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "agent_message_chunk",
                          "content" => %{"text" => text}
                        }
                      }
                    }}

    assert text =~ "20.0k / 100.0k tokens (20.0%)"
    assert text =~ "provider-reported"
    assert text =~ "| Tool results | 9.0k | 9.0% |"
    assert text =~ "| Free space | 80.0k | 80.0% |"
    refute text =~ "| Skills |"
    assert text =~ "1. bash result #4 — 9.0k"
    assert text =~ "measured when the last turn ended"

    :persistent_term.put({ContextRuntime, :result}, {:error, :session_not_found})

    assert {:ok, %{"stopReason" => "end_turn"}} =
             ACP.prompt(
               %{"sessionId" => id, "prompt" => [%{"type" => "text", "text" => "/context"}]},
               session_update_callback: &send(parent, {:empty, &1})
             )

    assert_receive {:empty, %{"params" => %{"update" => %{"content" => %{"text" => empty}}}}}
    assert empty =~ "No context recorded yet"

    assert {:error, -32_602, _} =
             ACP.prompt(%{
               "sessionId" => id,
               "prompt" => [%{"type" => "text", "text" => "/context extra"}]
             })
  after
    :persistent_term.erase({ContextRuntime, :observer})
    :persistent_term.erase({ContextRuntime, :result})
  end

  defmodule CommandsRuntime do
    def slash_commands(cwd) do
      send(:persistent_term.get({__MODULE__, :observer}), {:commands_cwd, cwd})

      [
        %{name: "git:review", description: "Review a change", argument_hint: "[path]"},
        %{name: "compact-notes", description: "", argument_hint: nil},
        %{name: "plan", description: "Shadowed by the built-in", argument_hint: nil},
        %{name: "skill:fake", description: "Shadowed by skills", argument_hint: nil}
      ]
    end
  end

  test "file commands are advertised after built-ins and submitted verbatim" do
    :persistent_term.put({CommandsRuntime, :observer}, self())
    :ok = LemonCore.AgentRuntime.register(CommandsRuntime)
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "file-command-run"}
    end)

    {:ok, %{"result" => %{"sessionId" => id}}} =
      ACP.handle_jsonrpc(
        %{
          "jsonrpc" => "2.0",
          "id" => "new",
          "method" => "session/new",
          "params" => %{"cwd" => "/home/z80/dev/lemon", "mcpServers" => []}
        },
        session_update_callback: &send(parent, {:bootstrap, &1})
      )

    assert_receive {:commands_cwd, "/home/z80/dev/lemon"}
    assert_receive {:bootstrap, %{"params" => %{"update" => %{"availableCommands" => commands}}}}

    assert Enum.map(commands, & &1["name"]) |> Enum.take(5) ==
             ["plan", "compact", "context", "git:review", "compact-notes"]

    assert Enum.count(commands, &(&1["name"] == "plan")) == 1
    refute Enum.any?(commands, &(&1["name"] == "skill:fake"))

    assert %{"description" => "Review a change", "input" => %{"hint" => "[path]"}} =
             Enum.find(commands, &(&1["name"] == "git:review"))

    for text <- ["/git:review lib/app.ex", "/compact-notes keep tests"] do
      assert {:ok, _} =
               ACP.prompt(%{
                 "sessionId" => id,
                 "prompt" => [%{"type" => "text", "text" => text}],
                 "_meta" => %{"lemon" => %{"wait" => false}}
               })

      assert_receive {:submitted, %{prompt: ^text, origin: :control_plane}}
    end
  after
    :persistent_term.erase({CommandsRuntime, :observer})
  end

  defp start_plan_runtime do
    :ets.new(PlanRuntime, [:named_table, :public, :set])
    :ets.insert(PlanRuntime, {:observer, self()})
    :ok = LemonCore.AgentRuntime.register(PlanRuntime)
  end

  test "unknown sessions and unsupported configuration fail closed" do
    assert {:ok, %{"error" => _}} =
             rpc("session/load", %{"sessionId" => "unknown", "cwd" => "/tmp"})

    assert {:ok, %{"error" => _}} = rpc("session/new", %{"cwd" => "relative", "mcpServers" => []})

    assert {:ok, %{"error" => _}} =
             rpc("session/new", %{
               "cwd" => "/tmp",
               "mcpServers" => [%{"name" => "ignored-before"}]
             })

    id = new_session()

    assert {:ok, %{"error" => _}} =
             rpc("session/set_model", %{"sessionId" => id, "modelId" => "unknown:secret"})

    assert {:ok, %{"error" => _}} =
             rpc("session/set_config_option", %{
               "sessionId" => id,
               "configId" => "approval",
               "value" => "typo"
             })

    assert {:ok, %{"error" => _}} = rpc("session/set_model", nil)
  end

  test "invalid run receipts cannot be reported as successful prompts" do
    id = new_session()

    for invalid <- [nil, "", :ok] do
      Application.put_env(:lemon_control_plane, :acp_submitter, fn _ -> {:ok, invalid} end)
      assert {:ok, %{"error" => %{"code" => -32_000}}} = queue_prompt(id)
    end
  end

  test "close retains resumable identity but prevents new turns until load" do
    id = new_session()
    assert {:ok, %{"result" => %{}}} = rpc("session/close", %{"sessionId" => id})
    assert {:ok, %{"error" => _}} = queue_prompt(id)

    assert {:ok, %{"result" => _}} =
             rpc("session/load", %{"sessionId" => id, "cwd" => "/home/z80/dev/lemon"})

    assert {:ok, %{"result" => listing}} = rpc("session/list", %{})
    assert Enum.any?(listing["sessions"], &(&1["sessionId"] == id))
  end

  test "load replays durable conversation via notifications" do
    id = new_session()
    session = Store.get(:acp_sessions, id)
    run_id = "replay-" <> LemonCore.Id.uuid()

    :ok =
      LemonCore.RunStore.finalize(run_id, %{
        session_key: session.session_key,
        agent_id: "default",
        origin: :control_plane,
        prompt: "remember the blue lighthouse",
        started_at: 1,
        completed: %{ok: true, answer: "The lighthouse is blue."}
      })

    parent = self()

    assert {:ok, %{"result" => _}} =
             ACP.handle_jsonrpc(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 1,
                 "method" => "session/load",
                 "params" => %{"sessionId" => id, "cwd" => session.cwd}
               },
               session_update_callback: &send(parent, {:replayed, &1})
             )

    assert_receive {:replayed,
                    %{
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "user_message_chunk",
                          "content" => %{"text" => "remember the blue lighthouse"}
                        }
                      }
                    }}

    assert_receive {:replayed,
                    %{
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "agent_message_chunk",
                          "content" => %{"text" => "The lighthouse is blue."}
                        }
                      }
                    }}

    LemonCore.RunStore.delete_session(session.session_key)
  end

  test "replay reconciles interrupted tools only from finalized durable runs" do
    :ok = LemonCore.AgentRuntime.register(InterruptedHistory)
    id = new_session()
    session = Store.get(:acp_sessions, id)
    run_id = LemonCore.Id.run_id()
    parent = self()
    on_exit(fn -> LemonCore.RunStore.delete_session(session.session_key) end)

    :ok =
      LemonCore.RunStore.append_event(run_id, %{
        __event__: :action_event,
        phase: :updated,
        action: %{
          id: "tool_call_interrupted",
          kind: :command,
          title: "sleep 90",
          detail: %{
            name: "bash",
            args: %{"command" => "sleep 90"},
            partial_result: %{content: [%{type: "text", text: "STARTED\n"}], details: %{}}
          }
        }
      })

    params = %{"sessionId" => id, "cwd" => session.cwd, "mcpServers" => []}

    assert {:ok, _} =
             ACP.resume_session(params,
               replay: true,
               session_update_callback: &send(parent, {:active_replay, &1})
             )

    assert_receive {:active_replay,
                    %{
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "tool_call",
                          "toolCallId" => "call_interrupted"
                        }
                      }
                    }}

    refute_receive {:active_replay, %{"params" => %{"update" => %{"status" => "failed"}}}}

    :ok =
      LemonCore.RunStore.finalize(run_id, %{
        session_key: session.session_key,
        agent_id: "default",
        origin: :control_plane,
        prompt: "run sleep",
        started_at: 1,
        completed: %{ok: false, answer: "", error: :acp_cancel}
      })

    assert {:ok, _} =
             ACP.resume_session(params,
               replay: true,
               session_update_callback: &send(parent, {:ended_replay, &1})
             )

    assert_receive {:ended_replay,
                    %{
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "tool_call_update",
                          "toolCallId" => "call_interrupted",
                          "status" => "failed",
                          "content" => content
                        }
                      }
                    }}

    assert Enum.any?(content, &(get_in(&1, ["content", "text"]) == "STARTED\n"))
  end

  test "uncertain submission preserves the fixed run ID and forbids retry" do
    parent = self()

    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      send(parent, {:uncertain_run, request.run_id})
      {:error, :outcome_unknown}
    end)

    id = new_session()

    assert {:ok, %{"error" => %{"data" => %{"runId" => run_id, "retrySafe" => false}}}} =
             queue_prompt(id)

    assert is_binary(run_id) and run_id != ""
    assert_receive {:uncertain_run, ^run_id}
    assert Store.get(:acp_sessions, id).last_run_id == run_id
  end

  defp rpc(method, params),
    do:
      ACP.handle_jsonrpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})

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

  defp wait_for_acp_registration(run_id, attempts \\ 200)

  defp wait_for_acp_registration(_run_id, 0),
    do: flunk("ACP client bridge never registered for run")

  defp wait_for_acp_registration(run_id, attempts) do
    case LemonCore.ACPClientBridge.whereis(run_id) do
      pid when is_pid(pid) ->
        pid

      nil ->
        Process.sleep(5)
        wait_for_acp_registration(run_id, attempts - 1)
    end
  end

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
