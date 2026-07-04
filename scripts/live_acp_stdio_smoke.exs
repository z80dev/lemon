defmodule Lemon.LiveACPStdioSmoke do
  @proof_path Path.join([File.cwd!(), ".lemon", "proofs", "acp-stdio-smoke-latest.json"])

  alias LemonControlPlane.ACP.NDJSON
  alias LemonCore.Store

  def run do
    previous = save_env()
    parent = self()

    try do
      reset_sessions()
      install_fake_runtime(parent)

      checks = [
        check("initialize", &check_initialize/0),
        check("session_new", &check_session_new/0),
        check("queued_prompt", &check_queued_prompt/0),
        check("wait_prompt_updates", &check_wait_prompt_updates/0),
        check("session_list_resume_close", &check_list_resume_close/0),
        check("parse_error", &check_parse_error/0)
      ]

      proof = proof(checks)
      write_proof(proof)
      IO.puts(Jason.encode!(proof, pretty: true))

      if proof.failed_count > 0, do: System.halt(1)
    after
      restore_env(previous)
      reset_sessions()
    end
  end

  defp check(name, fun) do
    case fun.() do
      {:ok, details} -> %{name: name, status: "completed", details: details}
      :ok -> %{name: name, status: "completed"}
      {:error, reason} -> %{name: name, status: "failed", reason: inspect(reason)}
    end
  rescue
    error -> %{name: name, status: "failed", reason: Exception.message(error)}
  catch
    kind, reason -> %{name: name, status: "failed", reason: inspect({kind, reason})}
  end

  defp check_initialize do
    response = request!("init", "initialize", %{"protocolVersion" => "1"})
    result = response["result"]

    with :ok <- require_value(result["agentInfo"]["name"], "Lemon"),
         :ok <- require_value(result["agentCapabilities"]["promptCapabilities"]["image"], false),
         :ok <- require_value(result["_meta"]["lemon"]["beamSupervisedRuns"], true) do
      {:ok, %{protocol_version: result["protocolVersion"]}}
    end
  end

  defp check_session_new do
    session_id = new_session!()
    {:ok, %{session_id_hash: hash(session_id)}}
  end

  defp check_queued_prompt do
    session_id = new_session!()

    response =
      request!("queued", "session/prompt", %{
        "sessionId" => session_id,
        "prompt" => [%{"type" => "text", "text" => "queued smoke"}],
        "_meta" => %{"lemon" => %{"wait" => false}}
      })

    with :ok <- require_value(response["result"]["stopReason"], "end_turn"),
         :ok <- require_value(response["result"]["_meta"]["lemon"]["status"], "queued"),
         :ok <- require_value(response["result"]["_meta"]["lemon"]["queued"], true) do
      {:ok, %{run_id_hash: hash(response["result"]["_meta"]["lemon"]["runId"])}}
    end
  end

  defp check_wait_prompt_updates do
    session_id = new_session!()
    parent = self()

    task =
      Task.async(fn ->
        NDJSON.responses_for_line(
          encode(%{
            "jsonrpc" => "2.0",
            "id" => "wait",
            "method" => "session/prompt",
            "params" => %{
              "sessionId" => session_id,
              "prompt" => [%{"type" => "text", "text" => "stream smoke"}],
              "_meta" => %{"lemon" => %{"timeoutMs" => 1_000}}
            }
          }),
          session_update_callback: fn notification -> send(parent, {:update, notification}) end
        )
      end)

    receive do
      {:submitted, "run_acp_stdio_stream"} -> :ok
    after
      500 -> throw({:missing_submission, :wait_prompt_updates})
    end

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_stdio_stream"),
      LemonCore.Event.new(:delta, %{text: "hello"})
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_stdio_stream"),
      LemonCore.Event.new(:engine_action, %{
        action: %{id: "tool_1", kind: :exec, title: "Run command"},
        phase: :completed,
        ok: true,
        message: "done"
      })
    )

    LemonCore.Bus.broadcast(
      LemonCore.Bus.run_topic("run_acp_stdio_stream"),
      LemonCore.Event.new(:run_completed, %{completed: %{ok: true, answer: "done", error: nil}})
    )

    updates = collect_updates([])
    [encoded] = Task.await(task, 1_000)
    result = Jason.decode!(encoded)["result"]

    with :ok <- require_value(result["_meta"]["lemon"]["status"], "completed"),
         :ok <- require_value(result["_meta"]["lemon"]["runId"], "run_acp_stdio_stream"),
         true <- Enum.any?(updates, &agent_message_update?/1) || {:error, :missing_agent_update},
         true <- Enum.any?(updates, &tool_update?/1) || {:error, :missing_tool_update} do
      {:ok, %{update_count: length(updates), run_id_hash: hash("run_acp_stdio_stream")}}
    end
  end

  defp check_list_resume_close do
    session_id = new_session!()
    list = request!("list", "session/list", %{"cwd" => File.cwd!()})

    unless Enum.any?(list["result"]["sessions"], &(&1["sessionId"] == session_id)) do
      throw({:missing_session, hash(session_id)})
    end

    resume =
      request!("resume", "session/resume", %{
        "sessionId" => session_id,
        "cwd" => File.cwd!(),
        "mcpServers" => []
      })

    close = request!("close", "session/close", %{"sessionId" => session_id})

    with true <-
           is_binary(resume["result"]["_meta"]["lemon"]["sessionKey"]) ||
             {:error, :missing_session_key},
         :ok <- require_value(close["result"], %{}) do
      {:ok, %{session_id_hash: hash(session_id)}}
    end
  end

  defp check_parse_error do
    [encoded] = NDJSON.responses_for_line("{not-json}\n")
    response = Jason.decode!(encoded)
    require_value(response["error"]["code"], -32_700)
  end

  defp request!(id, method, params) do
    [encoded] =
      NDJSON.responses_for_line(
        encode(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
      )

    Jason.decode!(encoded)
  end

  defp new_session! do
    response =
      request!("new", "session/new", %{
        "cwd" => File.cwd!(),
        "mcpServers" => [],
        "_meta" => %{"lemon" => %{"agentId" => "default"}}
      })

    response["result"]["sessionId"]
  end

  defp collect_updates(acc) do
    receive do
      {:update, notification} -> collect_updates([notification | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp agent_message_update?(%{"method" => "session/update", "params" => %{"update" => update}}) do
    update["sessionUpdate"] == "agent_message_chunk"
  end

  defp agent_message_update?(_), do: false

  defp tool_update?(%{"method" => "session/update", "params" => %{"update" => update}}) do
    update["sessionUpdate"] == "tool_call_update" and update["kind"] == "execute"
  end

  defp tool_update?(_), do: false

  defp install_fake_runtime(parent) do
    Application.put_env(:lemon_control_plane, :acp_submitter, fn request ->
      run_id =
        if request.prompt =~ "stream smoke",
          do: "run_acp_stdio_stream",
          else: "run_acp_stdio_#{System.unique_integer([:positive])}"

      send(parent, {:submitted, run_id})
      {:ok, run_id}
    end)

    Application.put_env(:lemon_control_plane, :acp_waiter, fn run_id, _timeout_ms ->
      {:ok, %{"runId" => run_id, "ok" => true, "answer" => "done", "error" => nil}}
    end)

    Application.put_env(:lemon_control_plane, :acp_canceller, fn _run_id, _reason -> :ok end)
  end

  defp proof(checks) do
    %{
      object: "lemon.acp_stdio_smoke",
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      completed_count: Enum.count(checks, &(&1.status == "completed")),
      failed_count: Enum.count(checks, &(&1.status == "failed")),
      results: checks,
      cleanup: %{
        includes_raw_api_keys: false,
        includes_raw_prompts: false,
        includes_raw_answers: false,
        includes_raw_events: false
      }
    }
  end

  defp write_proof(proof) do
    File.mkdir_p!(Path.dirname(@proof_path))
    File.write!(@proof_path, Jason.encode!(proof, pretty: true) <> "\n")

    archive =
      Path.join(
        Path.dirname(@proof_path),
        "acp-stdio-smoke-#{DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")}.json"
      )

    File.write!(archive, Jason.encode!(proof, pretty: true) <> "\n")
  end

  defp save_env do
    [:acp_submitter, :acp_waiter, :acp_canceller]
    |> Map.new(&{&1, Application.get_env(:lemon_control_plane, &1)})
  end

  defp restore_env(previous) do
    for {key, value} <- previous do
      if is_nil(value),
        do: Application.delete_env(:lemon_control_plane, key),
        else: Application.put_env(:lemon_control_plane, key, value)
    end
  end

  defp reset_sessions do
    if :ets.whereis(:lemon_control_plane_acp_sessions) != :undefined do
      :ets.delete_all_objects(:lemon_control_plane_acp_sessions)
    end

    for {session_id, _session} <- Store.list(:acp_sessions) do
      Store.delete(:acp_sessions, session_id)
    end
  end

  defp require_value(actual, expected) do
    if actual == expected, do: :ok, else: {:error, {:expected, expected, :got, actual}}
  end

  defp encode(value), do: Jason.encode!(value) <> "\n"

  defp hash(value) do
    :crypto.hash(:sha256, to_string(value))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end

Lemon.LiveACPStdioSmoke.run()
