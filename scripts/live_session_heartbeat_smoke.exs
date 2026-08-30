{:ok, _} = Application.ensure_all_started(:lemon_control_plane)
{:ok, _} = Application.ensure_all_started(:coding_agent)

defmodule LemonScripts.LiveSessionHeartbeatSmoke do
  alias CodingAgent.Session
  alias CodingAgent.Session.Heartbeat
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry
  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.Registry

  alias LemonAi.Types.{
    AssistantMessage,
    Model,
    ModelCost,
    TextContent,
    Usage,
    UserMessage
  }

  @custom_type "session_heartbeat"

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])

    proof_path =
      opts[:out] ||
        Path.join([File.cwd!(), ".lemon", "proofs", "session-heartbeat-smoke-latest.json"])

    suffix = System.unique_integer([:positive, :monotonic])
    temp_dir = Path.join(System.tmp_dir!(), "lemon-session-heartbeat-smoke-#{suffix}")
    File.mkdir_p!(temp_dir)

    proof =
      try do
        run(temp_dir, suffix)
      rescue
        exception ->
          build_proof([
            check("session_heartbeat_smoke", :failed, %{reason: Exception.message(exception)})
          ])
      after
        File.rm_rf(temp_dir)
      end

    write_json!(proof_path, proof)
    write_json!(archive_path(proof_path), proof)
    IO.puts(Jason.encode!(proof, pretty: true))

    if proof.failed_count > 0, do: System.halt(1)
  end

  defp run(temp_dir, suffix) do
    session_id = "session-heartbeat-smoke-#{suffix}"
    logical_session_key = "agent:default:heartbeat-smoke-#{suffix}"
    session_file = seed_overdue_session(temp_dir, session_id)
    owner = self()

    stream_fn = fn _model, context, _options ->
      messages = context.messages
      last_user = messages |> Enum.filter(&match?(%UserMessage{}, &1)) |> List.last()

      send(owner, {
        :heartbeat_provider_request,
        length(messages),
        last_user && last_user.content
      })

      {:ok, response_stream()}
    end

    {:ok, session} =
      Session.start_link(
        cwd: temp_dir,
        session_file: session_file,
        model: model(),
        stream_fn: stream_fn,
        register: true,
        session_key: logical_session_key
      )

    try do
      request_check = provider_request_check()

      status_result = rpc!(%{"sessionKey" => logical_session_key})
      pause_result = rpc!(%{"sessionKey" => logical_session_key, "action" => "pause"})
      resume_result = rpc!(%{"sessionKey" => logical_session_key, "action" => "resume"})
      clear_result = rpc!(%{"sessionKey" => logical_session_key, "action" => "clear"})

      {:ok, persisted} = SessionManager.load_from_file(session_file)

      reset_set_result =
        rpc!(%{
          "sessionKey" => logical_session_key,
          "action" => "set",
          "intervalSeconds" => 60,
          "prompt" => "prove reset cannot revive this heartbeat"
        })

      before_reset = Session.get_state(session)
      old_session_id = before_reset.session_manager.header.id
      old_session_file = before_reset.session_file
      stale_timer_token = before_reset.heartbeat_timer_token
      :ok = Session.reset(session)
      after_reset = Session.get_state(session)
      {:ok, reset_persisted} = SessionManager.load_from_file(old_session_file)
      send(session, {:session_heartbeat_due, stale_timer_token})

      stale_timer_check = stale_timer_check(session)

      checks = [
        request_check,
        equality_check("sessions_heartbeat_rpc_dispatch", status_result["action"], "status"),
        equality_check(
          "logical_session_key_resolution",
          status_result["sessionKey"],
          logical_session_key
        ),
        equality_check(
          "session_heartbeat_fire_claim_persisted",
          status_result["heartbeat"]["fireCount"],
          1
        ),
        equality_check(
          "session_heartbeat_pause",
          pause_result["heartbeat"]["status"],
          "paused"
        ),
        equality_check(
          "session_heartbeat_resume",
          resume_result["heartbeat"]["status"],
          "active"
        ),
        equality_check(
          "session_heartbeat_clear",
          clear_result["heartbeat"]["configured"],
          false
        ),
        equality_check("session_heartbeat_clear_tombstone", Heartbeat.load(persisted), nil),
        equality_check(
          "reset_precondition_active",
          reset_set_result["heartbeat"]["status"],
          "active"
        ),
        inequality_check(
          "reset_rotates_session_identity",
          after_reset.session_manager.header.id,
          old_session_id
        ),
        equality_check("reset_persists_clear_tombstone", Heartbeat.load(reset_persisted), nil),
        stale_timer_check
      ]

      build_proof(checks)
    after
      if Process.alive?(session), do: GenServer.stop(session)
    end
  end

  defp provider_request_check do
    receive do
      {:heartbeat_provider_request, message_count, content} ->
        rendered = content_text(content)

        if message_count == 1 and String.contains?(rendered, "[Heartbeat — recurring instruction") and
             String.contains?(rendered, "do not invent work") do
          check("same_session_idle_dispatch", :completed, %{
            model_request_message_count: message_count,
            injected_prompt_sha256: sha256(rendered)
          })
        else
          check("same_session_idle_dispatch", :failed, %{
            reason: "provider request did not contain one heartbeat user turn"
          })
        end
    after
      5_000 ->
        check("same_session_idle_dispatch", :failed, %{reason: "provider request timed out"})
    end
  end

  defp seed_overdue_session(temp_dir, session_id) do
    now = System.system_time(:millisecond)

    heartbeat = %{
      "prompt" => "inspect the live runtime and report only meaningful changes",
      "interval_seconds" => 60,
      "status" => "active",
      "created_at_ms" => now - 120_000,
      "last_fired_at_ms" => now - 120_000,
      "fire_count" => 0
    }

    manager =
      temp_dir
      |> SessionManager.new(id: session_id)
      |> SessionManager.append_entry(SessionEntry.custom(@custom_type, heartbeat))

    path = Path.join(temp_dir, "#{session_id}.jsonl")
    :ok = SessionManager.save_to_file(path, manager)
    path
  end

  defp rpc!(params) do
    ctx = %{
      conn_id: "session-heartbeat-live-smoke",
      conn_pid: self(),
      auth: Authorize.default_operator()
    }

    case Registry.dispatch("sessions.heartbeat", params, ctx) do
      {:ok, result} -> result
      {:error, reason} -> raise "sessions.heartbeat failed: #{inspect(reason)}"
    end
  end

  defp response_stream do
    response = %AssistantMessage{
      content: [%TextContent{text: "live heartbeat acknowledged"}],
      api: :mock,
      provider: :smoke,
      model: "heartbeat-smoke",
      usage: %Usage{},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }

    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, response})
      LemonAi.EventStream.push(stream, {:text_start, 0, response})
      LemonAi.EventStream.push(stream, {:text_delta, 0, "live heartbeat acknowledged", response})
      LemonAi.EventStream.push(stream, {:text_end, 0, "live heartbeat acknowledged", response})
      LemonAi.EventStream.push(stream, {:done, :stop, response})
      LemonAi.EventStream.complete(stream, response)
    end)

    stream
  end

  defp model do
    %Model{
      id: "heartbeat-smoke",
      name: "Heartbeat Smoke",
      api: :mock,
      provider: :smoke,
      base_url: "http://127.0.0.1",
      input: [:text],
      cost: %ModelCost{},
      context_window: 32_000,
      max_tokens: 128
    }
  end

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %TextContent{text: text} -> text
      _other -> ""
    end)
    |> Enum.join("")
  end

  defp equality_check(name, actual, expected) do
    if actual == expected do
      check(name, :completed)
    else
      check(name, :failed, %{reason: "expected #{inspect(expected)}, got #{inspect(actual)}"})
    end
  end

  defp inequality_check(name, actual, rejected) do
    if actual != rejected do
      check(name, :completed)
    else
      check(name, :failed, %{reason: "value unexpectedly remained #{inspect(rejected)}"})
    end
  end

  defp stale_timer_check(session) do
    Process.sleep(50)
    {:ok, status} = Session.heartbeat_status(session)

    receive do
      {:heartbeat_provider_request, _message_count, _content} ->
        check("reset_stale_timer_ignored", :failed, %{
          reason: "stale pre-reset timer reached the provider"
        })
    after
      50 ->
        equality_check("reset_stale_timer_ignored", status.configured, false)
    end
  end

  defp check(name, status, details \\ %{}) do
    %{name: name, status: Atom.to_string(status), details: details}
  end

  defp build_proof(checks) do
    completed_count = Enum.count(checks, &(&1.status == "completed"))
    failed_count = Enum.count(checks, &(&1.status == "failed"))

    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      proof_object: "lemon.session_heartbeat_smoke",
      proof_scope: "local_deterministic_same_session_runtime",
      status: if(failed_count == 0, do: "completed", else: "failed"),
      checks: checks,
      completed_count: completed_count,
      failed_count: failed_count,
      skipped_count: 0,
      cleanup: %{
        includes_prompts: false,
        includes_provider_responses: false,
        includes_credentials: false,
        includes_secret_values: false,
        temporary_session_removed: true
      }
    }
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp write_json!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true) <> "\n")
  end

  defp archive_path(path) do
    ext = Path.extname(path)
    root = String.trim_trailing(path, ext)
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    "#{root}-#{timestamp}#{ext}"
  end
end

LemonScripts.LiveSessionHeartbeatSmoke.main(System.argv())
