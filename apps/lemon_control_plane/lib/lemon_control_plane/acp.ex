defmodule LemonControlPlane.ACP do
  @moduledoc """
  Preview Agent Client Protocol JSON-RPC bridge.

  The bridge maps ACP sessions and prompt turns onto Lemon's existing supervised
  router run graph. It intentionally advertises only text and resource-link
  prompt support until Lemon has a safe raw media artifact contract.
  """

  alias LemonControlPlane.Methods.AgentWait
  alias LemonCore.Store
  alias LemonCore.RunRequest

  @protocol_version "1"
  @default_agent_id "default"
  @default_wait_timeout_ms 60_000
  @session_table :lemon_control_plane_acp_sessions
  @session_store_table :acp_sessions

  def capabilities do
    %{
      "loadSession" => true,
      "mcpCapabilities" => %{"http" => false, "sse" => false},
      "promptCapabilities" => %{
        "audio" => false,
        "embeddedContext" => false,
        "image" => false
      },
      "sessionCapabilities" => %{
        "close" => %{},
        "list" => %{},
        "resume" => %{}
      }
    }
  end

  def normalize_client_capabilities(capabilities) when is_map(capabilities) do
    fs = capabilities |> map_get_any(["fs", :fs]) |> ensure_map()

    %{
      fs: %{
        read_text_file:
          truthy?(
            map_get_any(fs, ["readTextFile", :readTextFile, "read_text_file", :read_text_file])
          ),
        write_text_file:
          truthy?(
            map_get_any(fs, ["writeTextFile", :writeTextFile, "write_text_file", :write_text_file])
          ),
        delete_file:
          truthy?(map_get_any(fs, ["deleteFile", :deleteFile, "delete_file", :delete_file])),
        rename_file:
          truthy?(map_get_any(fs, ["renameFile", :renameFile, "rename_file", :rename_file]))
      }
    }
  end

  def normalize_client_capabilities(_capabilities), do: empty_client_capabilities()

  def handle_jsonrpc(requests, opts \\ [])

  def handle_jsonrpc(requests, opts) when is_list(requests) do
    responses =
      requests
      |> Enum.map(&handle_jsonrpc(&1, opts))
      |> Enum.reject(&(&1 == :noreply))

    {:ok, responses}
  end

  def handle_jsonrpc(%{"jsonrpc" => "2.0", "method" => method} = request, opts) do
    id = Map.get(request, "id")
    params = Map.get(request, "params", %{})

    case dispatch(method, params, opts) do
      {:ok, _result} when is_nil(id) -> :noreply
      {:ok, result} -> {:ok, response(id, result)}
      {:error, _code, _message} when is_nil(id) -> :noreply
      {:error, code, message} -> {:ok, error_response(id, code, message)}
    end
  end

  def handle_jsonrpc(%{"id" => id}, _opts) do
    {:ok, error_response(id, -32_600, "invalid JSON-RPC request")}
  end

  def handle_jsonrpc(_request, _opts),
    do: {:ok, error_response(nil, -32_600, "invalid JSON-RPC request")}

  def initialize(params) when is_map(params) do
    version = string_param(params, "protocolVersion", @protocol_version)

    client_capabilities =
      params |> Map.get("clientCapabilities") |> normalize_client_capabilities()

    {:ok,
     %{
       "protocolVersion" => version,
       "agentInfo" => %{
         "name" => "Lemon",
         "version" => lemon_version()
       },
       "agentCapabilities" => capabilities(),
       "authMethods" => [],
       "_meta" => %{
         "lemon" => %{
           "status" => "preview",
           "beamSupervisedRuns" => true,
           "rawMediaPromptSupport" => false,
           "clientCapabilities" => client_capabilities_json(client_capabilities)
         }
       }
     }}
  end

  def initialize(_params), do: {:error, -32_602, "params must be an object"}

  def new_session(params, opts \\ [])

  def new_session(params, opts) when is_map(params) do
    with {:ok, cwd} <- required_string(params, "cwd"),
         {:ok, _servers} <- required_list(params, "mcpServers") do
      agent_id = lemon_meta_string(params, "agentId", @default_agent_id)
      client_capabilities = client_capabilities(params, opts)
      session_id = "acp_" <> UUID.uuid4()
      session_key = "agent:#{agent_id}:acp-#{short_hash(session_id)}"
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      put_session(session_id, %{
        cwd: cwd,
        session_key: session_key,
        agent_id: agent_id,
        title: nil,
        updated_at: now,
        last_run_id: nil,
        client_capabilities: client_capabilities
      })

      {:ok,
       %{
         "sessionId" => session_id,
         "modes" => nil,
         "configOptions" => [],
         "_meta" => %{
           "lemon" => %{
             "sessionKey" => session_key,
             "cwdHash" => short_hash(cwd),
             "clientCapabilities" => client_capabilities_json(client_capabilities)
           }
         }
       }}
    end
  end

  def new_session(_params, _opts), do: {:error, -32_602, "params must be an object"}

  def resume_session(params, opts \\ [])

  def resume_session(params, opts) when is_map(params) do
    with {:ok, session_id} <- required_string(params, "sessionId"),
         {:ok, cwd} <- required_string(params, "cwd") do
      agent_id = lemon_meta_string(params, "agentId", @default_agent_id)
      session_key = session_key_for(session_id, agent_id)
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      existing = get_session(session_id) || %{}
      client_capabilities = client_capabilities(params, opts, existing)

      session =
        Map.merge(existing, %{
          cwd: cwd,
          session_key: session_key,
          agent_id: agent_id,
          title: nil,
          updated_at: now,
          last_run_id: nil,
          client_capabilities: client_capabilities
        })

      put_session(session_id, session)

      {:ok,
       %{
         "modes" => nil,
         "configOptions" => [],
         "_meta" => %{
           "lemon" => %{
             "sessionKey" => session_key,
             "cwdHash" => short_hash(cwd),
             "clientCapabilities" => client_capabilities_json(client_capabilities)
           }
         }
       }}
    end
  end

  def resume_session(_params, _opts), do: {:error, -32_602, "params must be an object"}

  def list_sessions(params) when is_map(params) do
    cwd = Map.get(params, "cwd")

    sessions =
      all_sessions()
      |> Enum.map(fn {session_id, session} -> session_info(session_id, session) end)
      |> Enum.filter(fn session -> is_nil(cwd) or session["cwd"] == cwd end)

    {:ok, %{"sessions" => sessions}}
  end

  def list_sessions(_params), do: {:error, -32_602, "params must be an object"}

  def close_session(params) when is_map(params) do
    with {:ok, session_id} <- required_string(params, "sessionId") do
      session = get_session(session_id)
      cancel_last_run(session)
      delete_session(session_id)
      {:ok, %{}}
    end
  end

  def close_session(_params), do: {:error, -32_602, "params must be an object"}

  def cancel_session(params) when is_map(params) do
    with {:ok, session_id} <- required_string(params, "sessionId"),
         {:ok, session} <- existing_session(session_id) do
      cancel_last_run(session)
      {:ok, %{}}
    end
  end

  def cancel_session(_params), do: {:error, -32_602, "params must be an object"}

  def prompt(params, opts \\ [])

  def prompt(params, opts) when is_map(params) do
    with {:ok, session_id} <- required_string(params, "sessionId"),
         {:ok, session} <- existing_session(session_id),
         {:ok, blocks} <- required_list(params, "prompt"),
         {:ok, prompt} <- prompt_text(blocks),
         {:ok, result} <- submit_prompt(session_id, session, params, prompt),
         {:ok, result} <- maybe_wait(result, params, opts) do
      {:ok, prompt_response(result)}
    end
  end

  def prompt(_params, _opts), do: {:error, -32_602, "params must be an object"}

  def session_update(session_id, %LemonCore.Event{} = event) when is_binary(session_id) do
    case event.type do
      :delta -> delta_update(session_id, event.payload)
      :engine_action -> tool_update(session_id, event.payload)
      :run_completed -> nil
      _ -> nil
    end
  end

  def session_update(session_id, %{type: type, payload: payload}) when is_binary(session_id) do
    session_update(session_id, LemonCore.Event.new(type, payload))
  end

  def session_update(_session_id, _event), do: nil

  defp dispatch("initialize", params, _opts), do: initialize(params)
  defp dispatch("session/new", params, opts), do: new_session(params, opts)
  defp dispatch("session/load", params, opts), do: resume_session(params, opts)
  defp dispatch("session/resume", params, opts), do: resume_session(params, opts)
  defp dispatch("session/list", params, _opts), do: list_sessions(params)
  defp dispatch("session/close", params, _opts), do: close_session(params)
  defp dispatch("session/cancel", params, _opts), do: cancel_session(params)
  defp dispatch("session/prompt", params, opts), do: prompt(params, opts)
  defp dispatch(_method, _params, _opts), do: {:error, -32_601, "method not found"}

  defp submit_prompt(session_id, session, params, prompt) do
    queue_only? = lemon_meta(params, "wait") == false
    model = lemon_meta(params, "model")
    tool_policy = lemon_meta(params, "toolPolicy")
    client_capabilities = session_client_capabilities(session)
    client_fs_capabilities = client_capabilities.fs

    request =
      RunRequest.new(%{
        origin: :control_plane,
        session_key: session.session_key,
        agent_id: session.agent_id,
        prompt: prompt,
        queue_mode: :collect,
        model: model,
        cwd: session.cwd,
        tool_policy: tool_policy,
        meta: %{
          origin: :acp,
          acp_session_id: session_id,
          acp_wait_requested: not queue_only?,
          acp_resource_link_count: resource_link_count(params["prompt"]),
          acp_client_capabilities: client_capabilities_json(client_capabilities),
          acp_client_fs_read_text_file: client_fs_capabilities.read_text_file,
          acp_client_fs_write_text_file: client_fs_capabilities.write_text_file,
          acp_client_fs_delete_file: client_fs_capabilities.delete_file,
          acp_client_fs_rename_file: client_fs_capabilities.rename_file
        }
      })

    case submitter().(request) do
      {:ok, run_id} ->
        put_session(session_id, %{
          session
          | updated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            last_run_id: run_id,
            title: session.title || title_from_prompt(prompt)
        })

        {:ok,
         %{
           run_id: run_id,
           session_id: session_id,
           session_key: session.session_key,
           client_capabilities: client_capabilities,
           status: if(queue_only?, do: "queued", else: "submitted"),
           wait?: not queue_only?
         }}

      {:error, reason} ->
        {:error, -32_000, "failed to submit Lemon run: #{inspect(reason)}"}
    end
  end

  defp maybe_wait(result, params, opts) do
    if Keyword.has_key?(opts, :session_update_callback) or
         Keyword.has_key?(opts, :client_request_callback) do
      wait_with_updates(result, params, opts)
    else
      maybe_wait(result, params)
    end
  end

  defp maybe_wait(%{wait?: false} = result, _params), do: {:ok, result}

  defp maybe_wait(%{run_id: run_id} = result, params) do
    case waiter().(run_id, wait_timeout_ms(params)) do
      {:ok, wait_result} ->
        {:ok,
         result
         |> Map.put(:status, wait_status(wait_result))
         |> Map.put(:wait_result, wait_result)}

      {:error, {:timeout, message, _run_id}} ->
        {:error, -32_001, message}

      {:error, :timeout} ->
        {:error, -32_001, "Run did not complete within timeout"}

      {:error, reason} ->
        {:error, -32_000, "failed to wait for Lemon run: #{inspect(reason)}"}
    end
  end

  defp wait_with_updates(%{wait?: false} = result, _params, _opts), do: {:ok, result}

  defp wait_with_updates(%{run_id: run_id} = result, params, opts) do
    topic = LemonCore.Bus.run_topic(run_id)
    :ok = LemonCore.Bus.subscribe(topic)
    :ok = LemonCore.Bus.subscribe("exec_approvals")
    session_update_callback = Keyword.get(opts, :session_update_callback)
    client_request_callback = Keyword.get(opts, :client_request_callback)

    try do
      update_wait_loop(
        result,
        session_update_callback,
        client_request_callback,
        deadline_ms(wait_timeout_ms(params))
      )
    after
      LemonCore.Bus.unsubscribe(topic)
      LemonCore.Bus.unsubscribe("exec_approvals")
    end
  end

  defp update_wait_loop(result, session_update_callback, client_request_callback, deadline_ms) do
    case remaining_timeout_ms(deadline_ms) do
      0 ->
        {:error, -32_001, "Run did not complete within timeout"}

      timeout_ms ->
        receive do
          %LemonCore.Event{type: :run_completed, payload: payload} ->
            {:ok, complete_streamed_result(result, payload)}

          %LemonCore.Event{type: :acp_client_request, payload: payload} ->
            result = perform_client_request(result, payload, client_request_callback)
            update_wait_loop(result, session_update_callback, client_request_callback, deadline_ms)

          %LemonCore.Event{type: :approval_requested, payload: payload} ->
            result = maybe_perform_approval_request(result, payload, client_request_callback)
            update_wait_loop(result, session_update_callback, client_request_callback, deadline_ms)

          %LemonCore.Event{} = event ->
            maybe_emit_update(result.session_id, event, session_update_callback)
            update_wait_loop(result, session_update_callback, client_request_callback, deadline_ms)

          %{type: :run_completed, payload: payload} ->
            {:ok, complete_streamed_result(result, payload)}

          %{type: :acp_client_request, payload: payload} ->
            result = perform_client_request(result, payload, client_request_callback)
            update_wait_loop(result, session_update_callback, client_request_callback, deadline_ms)

          %{type: :approval_requested, payload: payload} ->
            result = maybe_perform_approval_request(result, payload, client_request_callback)
            update_wait_loop(result, session_update_callback, client_request_callback, deadline_ms)

          %{type: _type} = event ->
            maybe_emit_update(result.session_id, event, session_update_callback)
            update_wait_loop(result, session_update_callback, client_request_callback, deadline_ms)
        after
          timeout_ms ->
            {:error, -32_001, "Run did not complete within timeout"}
        end
    end
  end

  defp deadline_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    System.monotonic_time(:millisecond) + timeout_ms
  end

  defp deadline_ms(_timeout_ms), do: System.monotonic_time(:millisecond)

  defp remaining_timeout_ms(deadline_ms) do
    max(deadline_ms - System.monotonic_time(:millisecond), 0)
  end

  defp maybe_perform_approval_request(result, payload, callback) do
    pending = payload |> map_get(:pending) |> ensure_map()

    if map_get(pending, :session_key) == result.session_key do
      perform_approval_request(result, pending, callback)
    else
      result
    end
  end

  defp perform_approval_request(result, pending, callback) when is_function(callback, 1) do
    approval_id = map_get(pending, :id) || map_get(pending, :approval_id)
    tool = map_get(pending, :tool) || "tool"

    request =
      client_request("session/request_permission", %{
        "sessionId" => result.session_id,
        "toolCall" => %{
          "toolCallId" => approval_id || "approval_#{short_hash(inspect(pending))}",
          "title" => "Approve #{tool}",
          "kind" => acp_tool_kind(tool),
          "status" => "pending",
          "content" => approval_content(pending)
        },
        "options" => approval_options()
      })

    summary =
      case callback.(request) do
        {:ok, response} ->
          resolve_approval_from_response(approval_id, response)
          summarize_client_response("session/request_permission", response)

        {:error, reason} ->
          if is_binary(approval_id), do: LemonCore.ExecApprovals.resolve(approval_id, :deny)

          %{
            "method" => "session/request_permission",
            "status" => "failed",
            "reason" => inspect(reason)
          }

        response ->
          resolve_approval_from_response(approval_id, response)
          summarize_client_response("session/request_permission", response)
      end

    add_client_request_result(result, summary)
  end

  defp perform_approval_request(result, pending, _callback) do
    approval_id = map_get(pending, :id) || map_get(pending, :approval_id)
    if is_binary(approval_id), do: LemonCore.ExecApprovals.resolve(approval_id, :deny)

    add_client_request_result(result, %{
      "method" => "session/request_permission",
      "status" => "skipped",
      "reason" => "client request callback unavailable"
    })
  end

  defp approval_content(pending) do
    case map_get(pending, :rationale) do
      rationale when is_binary(rationale) and rationale != "" ->
        [%{"type" => "content", "content" => %{"type" => "text", "text" => truncate(rationale)}}]

      _ ->
        nil
    end
  end

  defp approval_options do
    [
      %{"optionId" => "allow-once", "name" => "Allow once", "kind" => "allow_once"},
      %{"optionId" => "allow-session", "name" => "Allow for session", "kind" => "allow_always"},
      %{"optionId" => "reject-once", "name" => "Reject", "kind" => "reject_once"}
    ]
  end

  defp resolve_approval_from_response(approval_id, response) when is_binary(approval_id) do
    outcome = response |> response_result() |> map_get(:outcome) |> ensure_map()

    decision =
      case {Map.get(outcome, "outcome"), Map.get(outcome, "optionId")} do
        {"selected", "allow-once"} -> :approve_once
        {"selected", "allow-session"} -> :approve_session
        {"selected", "allow-agent"} -> :approve_agent
        {"selected", "allow-global"} -> :approve_global
        _ -> :deny
      end

    LemonCore.ExecApprovals.resolve(approval_id, decision)
  end

  defp resolve_approval_from_response(_approval_id, _response), do: :ok

  defp perform_client_request(result, _payload, callback) when not is_function(callback, 1) do
    add_client_request_result(result, %{
      "method" => "unknown",
      "status" => "skipped",
      "reason" => "client request callback unavailable"
    })
  end

  defp perform_client_request(result, payload, callback) when is_map(payload) do
    method = map_get(payload, :method)
    params = payload |> map_get(:params) |> ensure_map()
    request = client_request(method, Map.put_new(params, "sessionId", result.session_id))

    {summary, response} =
      case callback.(request) do
        {:ok, response} ->
          {summarize_client_response(method, response), response}

        {:error, reason} ->
          summary = %{
            "method" => method || "unknown",
            "status" => "failed",
            "reason" => inspect(reason)
          }

          {summary, %{"error" => %{"message" => inspect(reason)}}}

        response ->
          {summarize_client_response(method, response), response}
      end

    maybe_reply_client_request(payload, response)
    add_client_request_result(result, summary)
  end

  defp perform_client_request(result, _payload, _callback), do: result

  defp maybe_reply_client_request(payload, response) do
    with reply_to when is_pid(reply_to) <- map_get(payload, :reply_to),
         ref when is_reference(ref) <- map_get(payload, :ref) do
      send(reply_to, {:acp_client_response, ref, response})
    else
      _ -> :ok
    end
  end

  defp client_request(method, params) when is_binary(method) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  defp client_request(_method, params) do
    %{"jsonrpc" => "2.0", "method" => "unknown", "params" => params}
  end

  defp add_client_request_result(result, summary) do
    Map.update(result, :client_requests, [summary], &(&1 ++ [summary]))
  end

  defp summarize_client_response("session/request_permission", response) do
    outcome = response |> response_result() |> map_get(:outcome) |> ensure_map()

    %{
      "method" => "session/request_permission",
      "status" => response_status(response),
      "outcome" => Map.get(outcome, "outcome"),
      "optionId" => Map.get(outcome, "optionId")
    }
    |> reject_nil_values()
  end

  defp summarize_client_response("fs/read_text_file", response) do
    content =
      response
      |> response_result()
      |> map_get(:content)

    %{
      "method" => "fs/read_text_file",
      "status" => response_status(response),
      "contentBytes" => if(is_binary(content), do: byte_size(content)),
      "contentHash" => if(is_binary(content), do: short_hash(content))
    }
    |> reject_nil_values()
  end

  defp summarize_client_response("fs/write_text_file", response) do
    %{"method" => "fs/write_text_file", "status" => response_status(response)}
  end

  defp summarize_client_response("fs/delete_file", response) do
    %{"method" => "fs/delete_file", "status" => response_status(response)}
  end

  defp summarize_client_response("fs/rename_file", response) do
    %{"method" => "fs/rename_file", "status" => response_status(response)}
  end

  defp summarize_client_response(method, response) do
    %{"method" => method || "unknown", "status" => response_status(response)}
  end

  defp response_result(%{"result" => result}), do: result
  defp response_result(%{result: result}), do: result
  defp response_result(result) when is_map(result), do: result
  defp response_result(_result), do: %{}

  defp response_status(%{"error" => _error}), do: "failed"
  defp response_status(%{error: _error}), do: "failed"
  defp response_status(_response), do: "completed"

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_value), do: %{}

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_emit_update(session_id, event, callback) do
    case session_update(session_id, event) do
      nil -> :ok
      update when is_function(callback, 1) -> callback.(update)
      _update -> :ok
    end
  end

  defp complete_streamed_result(result, payload) do
    completed =
      case map_get(payload, :completed) do
        nil -> payload
        value -> value
      end

    result
    |> Map.put(:status, wait_status(completed))
    |> Map.put(:wait_result, %{
      "runId" => result.run_id,
      "ok" => completed_ok(completed),
      "answer" => map_get(completed, :answer),
      "error" => map_get(completed, :error)
    })
  end

  defp prompt_response(result) do
    %{
      "stopReason" => stop_reason(result),
      "_meta" => %{
        "lemon" => %{
          "runId" => result.run_id,
          "sessionId" => result.session_id,
          "sessionKey" => result.session_key,
          "status" => result.status,
          "queued" => result.status == "queued",
          "ok" => wait_ok(result[:wait_result]),
          "answer" => wait_answer(result[:wait_result]),
          "clientCapabilities" =>
            result
            |> Map.get(:client_capabilities)
            |> normalize_client_capabilities()
            |> client_capabilities_json(),
          "clientRequests" => Map.get(result, :client_requests, [])
        }
      }
    }
  end

  defp delta_update(session_id, payload) do
    text = map_get(payload, :text)

    if is_binary(text) and text != "" do
      update_notification(session_id, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => text}
      })
    end
  end

  defp tool_update(session_id, payload) do
    action = map_get(payload, :action) || %{}
    tool_call_id = map_get(action, :id) || "tool_#{short_hash(inspect(action))}"

    update_notification(session_id, %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => tool_call_id,
      "title" => map_get(action, :title) || "Tool progress",
      "kind" => acp_tool_kind(map_get(action, :kind)),
      "status" => acp_tool_status(map_get(payload, :phase), map_get(payload, :ok)),
      "content" => tool_update_content(payload),
      "_meta" => %{
        "lemon" => %{
          "phase" => atom_to_string(map_get(payload, :phase)),
          "ok" => map_get(payload, :ok)
        }
      }
    })
  end

  defp update_notification(session_id, update) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => session_id,
        "update" => update
      }
    }
  end

  defp tool_update_content(payload) do
    case map_get(payload, :message) do
      message when is_binary(message) and message != "" ->
        [%{"type" => "content", "content" => %{"type" => "text", "text" => truncate(message)}}]

      _ ->
        nil
    end
  end

  defp acp_tool_kind(kind) when kind in [:read, "read"], do: "read"

  defp acp_tool_kind(kind) when kind in [:edit, "edit", :write, "write", :patch, "patch"],
    do: "edit"

  defp acp_tool_kind(kind) when kind in [:delete, "delete"], do: "delete"
  defp acp_tool_kind(kind) when kind in [:move, "move"], do: "move"
  defp acp_tool_kind(kind) when kind in [:search, "search"], do: "search"
  defp acp_tool_kind(kind) when kind in [:exec, "exec", :process, "process"], do: "execute"
  defp acp_tool_kind(kind) when kind in [:fetch, "fetch", :web, "web"], do: "fetch"
  defp acp_tool_kind(_kind), do: "other"

  defp acp_tool_status(phase, false) when phase in [:completed, "completed"], do: "failed"
  defp acp_tool_status(phase, _ok) when phase in [:completed, "completed"], do: "completed"

  defp acp_tool_status(phase, _ok) when phase in [:started, "started", :running, "running"],
    do: "in_progress"

  defp acp_tool_status(_phase, _ok), do: "pending"

  defp prompt_text(blocks) do
    blocks
    |> Enum.reduce_while({:ok, []}, fn
      %{"type" => "text", "text" => text}, {:ok, acc} when is_binary(text) ->
        {:cont, {:ok, [text | acc]}}

      %{"type" => "resource_link", "name" => name, "uri" => uri} = block, {:ok, acc}
      when is_binary(name) and is_binary(uri) ->
        {:cont, {:ok, [resource_link_prompt(name, uri, block) | acc]}}

      %{"type" => type}, _acc when type in ["image", "audio", "resource"] ->
        {:halt, {:error, -32_602, "#{type} prompt blocks are not enabled in this preview"}}

      _block, _acc ->
        {:halt, {:error, -32_602, "prompt blocks must be text or resource_link content"}}
    end)
    |> case do
      {:ok, parts} ->
        parts
        |> Enum.reverse()
        |> Enum.join("\n")
        |> case do
          "" -> {:error, -32_602, "prompt must include text or resource_link content"}
          prompt -> {:ok, prompt}
        end

      {:error, code, message} ->
        {:error, code, message}
    end
  end

  defp resource_link_prompt(name, uri, block) do
    details =
      [
        "name=#{name}",
        "uri=#{uri}",
        block["mimeType"] && "mime=#{block["mimeType"]}",
        block["title"] && "title=#{block["title"]}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    "[resource link: #{details}]"
  end

  defp required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, -32_602, "#{key} is required"}
    end
  end

  defp required_list(params, key) do
    case Map.get(params, key) do
      value when is_list(value) -> {:ok, value}
      _ -> {:error, -32_602, "#{key} must be an array"}
    end
  end

  defp existing_session(session_id) do
    case get_session(session_id) do
      nil -> {:error, -32_602, "session not found"}
      session -> {:ok, session}
    end
  end

  defp get_session(session_id) do
    ensure_table(@session_table)

    case :ets.lookup(@session_table, session_id) do
      [{^session_id, session}] ->
        session

      [] ->
        case Store.get(@session_store_table, session_id) do
          session when is_map(session) ->
            :ets.insert(@session_table, {session_id, session})
            session

          _ ->
            nil
        end
    end
  end

  defp put_session(session_id, session) do
    ensure_table(@session_table)
    :ets.insert(@session_table, {session_id, session})
    Store.put(@session_store_table, session_id, session)
    :ok
  end

  defp delete_session(session_id) do
    ensure_table(@session_table)
    :ets.delete(@session_table, session_id)
    Store.delete(@session_store_table, session_id)
    :ok
  end

  defp all_sessions do
    ensure_table(@session_table)

    stored_sessions =
      @session_store_table
      |> Store.list()
      |> Enum.filter(fn {session_id, session} -> is_binary(session_id) and is_map(session) end)

    @session_table
    |> :ets.tab2list()
    |> Enum.concat(stored_sessions)
    |> Map.new()
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined -> :ets.new(table, [:named_table, :public, read_concurrency: true])
      tid -> tid
    end

    table
  rescue
    ArgumentError -> table
  end

  defp session_info(session_id, session) do
    client_capabilities = session_client_capabilities(session)

    %{
      "sessionId" => session_id,
      "cwd" => session.cwd,
      "title" => session.title,
      "updatedAt" => session.updated_at,
      "_meta" => %{
        "lemon" => %{
          "sessionKey" => session.session_key,
          "lastRunId" => session.last_run_id,
          "clientCapabilities" => client_capabilities_json(client_capabilities)
        }
      }
    }
  end

  defp cancel_last_run(%{last_run_id: run_id}) when is_binary(run_id) and run_id != "" do
    canceller().(run_id, :acp_cancel)
  end

  defp cancel_last_run(_session), do: :ok

  defp session_key_for(session_id, agent_id),
    do: "agent:#{agent_id}:acp-#{short_hash(session_id)}"

  defp resource_link_count(blocks) when is_list(blocks),
    do: Enum.count(blocks, &(is_map(&1) and &1["type"] == "resource_link"))

  defp resource_link_count(_blocks), do: 0

  defp lemon_meta(params, key), do: get_in(params, ["_meta", "lemon", key])

  defp client_capabilities(params, opts, existing \\ %{}) do
    from_opts = Keyword.get(opts, :client_capabilities)

    from_params =
      Map.get(params, "clientCapabilities") || lemon_meta(params, "clientCapabilities")

    from_existing = map_get_any(existing, [:client_capabilities, "client_capabilities"])

    cond do
      is_map(from_params) -> normalize_client_capabilities(from_params)
      is_map(from_opts) -> normalize_client_capabilities(from_opts)
      is_map(from_existing) -> normalize_client_capabilities(from_existing)
      true -> empty_client_capabilities()
    end
  end

  defp session_client_capabilities(session) do
    session
    |> map_get_any([:client_capabilities, "client_capabilities"])
    |> normalize_client_capabilities()
  end

  defp empty_client_capabilities do
    %{
      fs: %{read_text_file: false, write_text_file: false, delete_file: false, rename_file: false}
    }
  end

  defp client_capabilities_json(capabilities) do
    capabilities = normalize_client_capabilities(capabilities)

    %{
      "fs" => %{
        "readTextFile" => capabilities.fs.read_text_file,
        "writeTextFile" => capabilities.fs.write_text_file,
        "deleteFile" => capabilities.fs.delete_file,
        "renameFile" => capabilities.fs.rename_file
      }
    }
  end

  defp lemon_meta_string(params, key, default) do
    case lemon_meta(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp string_param(params, key, default) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp wait_timeout_ms(params) do
    case lemon_meta(params, "timeoutMs") do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_wait_timeout_ms
    end
  end

  defp wait_status(%{"ok" => false}), do: "failed"
  defp wait_status(%{ok: false}), do: "failed"
  defp wait_status(_wait_result), do: "completed"

  defp stop_reason(%{status: "failed"}), do: "refusal"
  defp stop_reason(_result), do: "end_turn"

  defp wait_ok(nil), do: nil
  defp wait_ok(%{"ok" => ok}), do: ok
  defp wait_ok(%{ok: ok}), do: ok
  defp wait_ok(_), do: nil

  defp wait_answer(nil), do: nil
  defp wait_answer(%{"answer" => answer}) when is_binary(answer), do: answer
  defp wait_answer(%{answer: answer}) when is_binary(answer), do: answer
  defp wait_answer(_), do: nil

  defp completed_ok(nil), do: nil
  defp completed_ok(completed), do: map_get(completed, :ok)

  defp map_get(nil, _key), do: nil

  defp map_get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error when is_atom(key) -> Map.get(map, Atom.to_string(key))
      :error -> nil
    end
  end

  defp map_get_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp map_get_any(_map, _keys), do: nil

  defp truthy?(true), do: true
  defp truthy?(_value), do: false

  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value), do: value

  defp truncate(text, max \\ 240)
  defp truncate(text, max) when is_binary(text) and byte_size(text) <= max, do: text
  defp truncate(text, max) when is_binary(text), do: String.slice(text, 0, max) <> "..."
  defp truncate(value, _max), do: value

  defp title_from_prompt(prompt) do
    prompt
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 80)
  end

  defp submitter do
    Application.get_env(:lemon_control_plane, :acp_submitter, &LemonRouter.submit/1)
  end

  defp waiter do
    Application.get_env(:lemon_control_plane, :acp_waiter, fn run_id, timeout_ms ->
      AgentWait.handle(%{"runId" => run_id, "timeoutMs" => timeout_ms}, %{})
    end)
  end

  defp canceller do
    Application.get_env(:lemon_control_plane, :acp_canceller, &LemonRouter.abort_run/2)
  end

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp lemon_version do
    Application.spec(:lemon_control_plane, :vsn)
    |> to_string()
  end
end
