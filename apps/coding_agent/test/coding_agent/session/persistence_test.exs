defmodule CodingAgent.Session.PersistenceTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.Persistence
  alias CodingAgent.SessionManager

  test "persist_message appends supported message types" do
    session_manager = SessionManager.new("/tmp")

    state = %{session_manager: session_manager}

    next_state =
      Persistence.persist_message(state, %Ai.Types.UserMessage{
        role: :user,
        content: "hello",
        timestamp: 1
      })

    assert SessionManager.entry_count(next_state.session_manager) == 1
  end

  test "restore_messages_from_session rebuilds serialized messages" do
    session_manager =
      SessionManager.new("/tmp")
      |> SessionManager.append_message(%{
        "role" => "user",
        "content" => "hello",
        "timestamp" => 1
      })

    [message] = Persistence.restore_messages_from_session(session_manager)
    assert %Ai.Types.UserMessage{content: "hello", timestamp: 1} = message
  end

  test "save persists session file and updates session_file on state" do
    cwd =
      Path.join(System.tmp_dir!(), "coding-agent-session-#{System.unique_integer([:positive])}")

    session_manager = SessionManager.new(cwd)
    state = %{cwd: cwd, session_file: nil, session_manager: session_manager}

    assert {:ok, next_state} = Persistence.save(state)
    assert is_binary(next_state.session_file)
    assert File.exists?(next_state.session_file)

    File.rm_rf!(cwd)
  end
end
