defmodule CodingAgent.SessionHeartbeatTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session
  alias CodingAgent.Session.Heartbeat
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry
  alias CodingAgent.ControlPlaneProvider
  alias LemonAgent.Test.Mocks
  alias LemonAi.Types.{TextContent, UserMessage}

  @heartbeat_type "session_heartbeat"
  @provider_timeout 10_000

  defp capturing_stream(owner) do
    inner = Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))

    fn model, context, options ->
      send(owner, {:provider_prompt, last_user_content(context.messages)})
      inner.(model, context, options)
    end
  end

  defp start_session(tmp_dir, opts \\ []) do
    defaults = [
      cwd: tmp_dir,
      model: Mocks.mock_model(),
      stream_fn: capturing_stream(self()),
      register: false
    ]

    {:ok, session} = Session.start_link(Keyword.merge(defaults, opts))
    session
  end

  defp due_session_file(tmp_dir, id \\ nil) do
    id = id || "heartbeat-#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)

    data = %{
      "prompt" => "check the build queue",
      "interval_seconds" => 60,
      "status" => "active",
      "created_at_ms" => now - 120_000,
      "last_fired_at_ms" => now - 120_000,
      "fire_count" => 2
    }

    manager =
      tmp_dir
      |> SessionManager.new(id: id)
      |> SessionManager.append_entry(SessionEntry.custom(@heartbeat_type, data))

    path = Path.join(tmp_dir, "#{id}.jsonl")
    :ok = SessionManager.save_to_file(path, manager)
    path
  end

  defp last_user_content(messages) do
    messages
    |> Enum.filter(&match?(%UserMessage{}, &1))
    |> List.last()
    |> Map.fetch!(:content)
    |> content_text()
  end

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %TextContent{text: text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("")
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  @tag :tmp_dir
  test "a persisted overdue heartbeat resumes in the same transcript and records its fire", %{
    tmp_dir: tmp_dir
  } do
    session_file = due_session_file(tmp_dir)
    session = start_session(tmp_dir, session_file: session_file)

    assert_receive {:provider_prompt, prompt}, @provider_timeout
    assert prompt =~ "[Heartbeat — recurring instruction, fires every 1m]"
    assert prompt =~ "check the build queue"
    assert prompt =~ "do not invent work"

    assert eventually(fn ->
             {:ok, heartbeat} = Session.heartbeat_status(session)
             heartbeat.fire_count == 3 and heartbeat.status == :active
           end)

    {:ok, persisted} = SessionManager.load_from_file(session_file)
    assert %{fire_count: 3, status: :active} = Heartbeat.load(persisted)
    refute_receive {:provider_prompt, _second_tick}, 100
  end

  @tag :tmp_dir
  test "a queued real user prompt wins and the missed heartbeat coalesces behind it", %{
    tmp_dir: tmp_dir
  } do
    session_file = due_session_file(tmp_dir)
    session = start_session(tmp_dir, session_file: session_file)

    assert :ok = Session.prompt(session, "answer the user first")
    assert_receive {:provider_prompt, "answer the user first"}, @provider_timeout
    assert_receive {:provider_prompt, heartbeat_prompt}, @provider_timeout
    assert heartbeat_prompt =~ "[Heartbeat — recurring instruction"

    refute_receive {:provider_prompt, _duplicate_heartbeat}, 100
    {:ok, heartbeat} = Session.heartbeat_status(session)
    assert heartbeat.fire_count == 3
  end

  @tag :tmp_dir
  test "set pause resume and clear survive session restarts", %{tmp_dir: tmp_dir} do
    first = start_session(tmp_dir)

    assert {:ok, %{configured: true, status: :active, interval_seconds: 90}} =
             Session.heartbeat_set(first, "review open work", 90)

    assert {:ok, %{status: :paused, prompt: "review open work"}} =
             Session.heartbeat_pause(first)

    session_file = Session.get_state(first).session_file
    GenServer.stop(first)

    second = start_session(tmp_dir, session_file: session_file)
    assert {:ok, %{status: :paused, next_fire_at_ms: nil}} = Session.heartbeat_status(second)

    assert {:ok, %{status: :active, next_in_seconds: next_in}} =
             Session.heartbeat_resume(second)

    assert next_in in 89..90
    refute_receive {:provider_prompt, _}, 100

    assert {:ok, %{configured: false, status: :cleared}} = Session.heartbeat_clear(second)
    GenServer.stop(second)

    third = start_session(tmp_dir, session_file: session_file)
    assert {:ok, %{configured: false, status: :cleared}} = Session.heartbeat_status(third)
    refute_receive {:provider_prompt, _}, 100
  end

  @tag :tmp_dir
  test "validates prompt and interval without mutating the session", %{tmp_dir: tmp_dir} do
    session = start_session(tmp_dir)

    assert {:error, :empty_prompt} = Session.heartbeat_set(session, "  ", 60)
    assert {:error, :interval_too_small} = Session.heartbeat_set(session, "check", 59)
    assert {:error, :invalid_interval} = Session.heartbeat_set(session, "check", 60.5)
    assert {:error, :not_configured} = Session.heartbeat_pause(session)
    assert {:error, :not_configured} = Session.heartbeat_resume(session)
    assert {:error, :not_configured} = Session.heartbeat_clear(session)
    assert {:ok, %{configured: false}} = Session.heartbeat_status(session)
  end

  @tag :tmp_dir
  test "the control-plane adapter resolves a logical session key distinct from the JSONL id", %{
    tmp_dir: tmp_dir
  } do
    logical_key = "agent:default:heartbeat-#{System.unique_integer([:positive])}"
    session = start_session(tmp_dir, register: true, session_key: logical_key)
    persisted_id = Session.get_state(session).session_manager.header.id

    refute persisted_id == logical_key

    assert {:ok, %{configured: false}} =
             ControlPlaneProvider.session_heartbeat(logical_key, :status, %{})

    assert {:ok, %{status: :active, prompt: "watch the logical session"}} =
             ControlPlaneProvider.session_heartbeat(logical_key, :set, %{
               prompt: "watch the logical session",
               interval_seconds: 60
             })
  end

  @tag :tmp_dir
  test "reset rotates identity and tombstones the old persisted heartbeat", %{tmp_dir: tmp_dir} do
    session = start_session(tmp_dir)
    assert {:ok, %{status: :active}} = Session.heartbeat_set(session, "review after idle", 60)

    old_state = Session.get_state(session)
    old_session_id = old_state.session_manager.header.id
    old_session_file = old_state.session_file
    old_timer_token = old_state.heartbeat.timer_token

    assert :ok = Session.reset(session)

    new_state = Session.get_state(session)
    refute new_state.session_manager.header.id == old_session_id
    assert new_state.session_file == nil
    assert {:ok, %{configured: false, status: :cleared}} = Session.heartbeat_status(session)

    {:ok, old_persisted} = SessionManager.load_from_file(old_session_file)
    assert Heartbeat.load(old_persisted) == nil

    send(session, {:session_heartbeat_due, old_timer_token})
    refute_receive {:provider_prompt, _resurrected}, 100
  end

  @tag :tmp_dir
  test "reset refuses to rotate when the old heartbeat tombstone cannot be persisted", %{
    tmp_dir: tmp_dir
  } do
    session = start_session(tmp_dir)
    assert {:ok, %{status: :active}} = Session.heartbeat_set(session, "preserve on failure", 60)

    old_state = Session.get_state(session)
    old_session_id = old_state.session_manager.header.id
    blocker = Path.join(tmp_dir, "not-a-directory")
    :ok = File.write(blocker, "block nested session persistence")

    :sys.replace_state(session, fn state ->
      %{state | session_file: Path.join(blocker, "session.jsonl")}
    end)

    assert {:error, {:heartbeat_persistence_failed, _reason}} = Session.reset(session)

    after_failed_reset = Session.get_state(session)
    assert after_failed_reset.session_manager.header.id == old_session_id
    assert {:ok, %{configured: true, status: :active}} = Session.heartbeat_status(session)
  end

  @tag :tmp_dir
  test "a clear tombstone never resurrects an older active record", %{tmp_dir: tmp_dir} do
    now = System.system_time(:millisecond)

    active = %{
      "prompt" => "old instruction",
      "interval_seconds" => 60,
      "status" => "active",
      "created_at_ms" => now,
      "last_fired_at_ms" => 0,
      "fire_count" => 0
    }

    cleared = Map.put(active, "status", "cleared")

    manager =
      tmp_dir
      |> SessionManager.new()
      |> SessionManager.append_entry(SessionEntry.custom(@heartbeat_type, active))
      |> SessionManager.append_entry(SessionEntry.custom(@heartbeat_type, cleared))

    assert Heartbeat.load(manager) == nil
  end
end
