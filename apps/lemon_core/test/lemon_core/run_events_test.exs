defmodule LemonCore.RunEventsTest do
  use ExUnit.Case, async: true

  alias LemonCore.ResumeToken

  alias LemonCore.RunEvents.{
    Action,
    ActionEvent,
    CompletedEvent,
    EventFactory,
    StartedEvent
  }

  describe "Action" do
    test "creates action with default detail" do
      action = Action.new("cmd_1", :command, "ls -la")
      assert action.id == "cmd_1"
      assert action.kind == :command
      assert action.title == "ls -la"
      assert action.detail == %{}
    end

    test "creates action with detail" do
      detail = %{exit_code: 0, duration: 100}
      action = Action.new("cmd_1", :command, "ls -la", detail)
      assert action.detail == detail
    end
  end

  describe "StartedEvent" do
    test "creates event with required fields" do
      token = ResumeToken.new("codex", "thread_123")
      event = StartedEvent.new("codex", token)
      assert event.type == :started
      assert event.engine == "codex"
      assert event.resume == token
      assert event.title == nil
      assert event.meta == nil
    end

    test "implements Jason.Encoder (including nested ResumeToken)" do
      token = ResumeToken.new("codex", "thread_123")
      event = StartedEvent.new("codex", token)

      assert Jason.encode!(event) |> Jason.decode!() == %{
               "engine" => "codex",
               "meta" => nil,
               "resume" => %{"engine" => "codex", "value" => "thread_123"},
               "title" => nil,
               "type" => "started"
             }
    end

    test "creates event with optional fields" do
      token = ResumeToken.new("codex", "thread_123")
      event = StartedEvent.new("codex", token, title: "My Session", meta: %{foo: "bar"})
      assert event.title == "My Session"
      assert event.meta == %{foo: "bar"}
    end
  end

  describe "ActionEvent" do
    test "creates action event" do
      action = Action.new("cmd_1", :command, "ls -la")
      event = ActionEvent.new("codex", action, :started)
      assert event.type == :action
      assert event.engine == "codex"
      assert event.action == action
      assert event.phase == :started
    end

    test "creates completed action event with ok status" do
      action = Action.new("cmd_1", :command, "ls -la")
      event = ActionEvent.new("codex", action, :completed, ok: true)
      assert event.ok == true
    end
  end

  describe "CompletedEvent" do
    test "creates successful completion" do
      event = CompletedEvent.ok("codex", "Done!")
      assert event.type == :completed
      assert event.engine == "codex"
      assert event.ok == true
      assert event.answer == "Done!"
      assert event.error == nil
    end

    test "creates successful completion with resume" do
      token = ResumeToken.new("codex", "thread_123")
      event = CompletedEvent.ok("codex", "Done!", resume: token)
      assert event.resume == token
    end

    test "creates error completion" do
      event = CompletedEvent.error("codex", "Something went wrong")
      assert event.ok == false
      assert event.error == "Something went wrong"
      assert event.answer == ""
    end

    test "creates error completion with partial answer" do
      event = CompletedEvent.error("codex", "Failed", answer: "Partial result")
      assert event.answer == "Partial result"
    end
  end

  describe "EventFactory" do
    test "creates factory for engine" do
      factory = EventFactory.new("codex")
      assert factory.engine == "codex"
      assert factory.resume == nil
      assert factory.note_seq == 0
    end

    test "started caches resume token" do
      factory = EventFactory.new("codex")
      token = ResumeToken.new("codex", "thread_123")

      {event, factory} = EventFactory.started(factory, token, title: "Test")

      assert event.type == :started
      assert event.resume == token
      assert factory.resume == token
    end

    test "started validates engine match" do
      factory = EventFactory.new("codex")
      token = ResumeToken.new("claude", "session_123")

      assert_raise RuntimeError, ~r/engine mismatch/, fn ->
        EventFactory.started(factory, token)
      end
    end

    test "action_started creates started action" do
      factory = EventFactory.new("codex")
      {event, _factory} = EventFactory.action_started(factory, "cmd_1", :command, "ls")

      assert event.phase == :started
      assert event.action.id == "cmd_1"
      assert event.action.kind == :command
      assert event.action.title == "ls"
    end

    test "action_completed creates completed action" do
      factory = EventFactory.new("codex")
      {event, _factory} = EventFactory.action_completed(factory, "cmd_1", :command, "ls", true)

      assert event.phase == :completed
      assert event.ok == true
    end

    test "note creates warning note with auto-incrementing id" do
      factory = EventFactory.new("codex")

      {event1, factory} = EventFactory.note(factory, "First note")
      {event2, _factory} = EventFactory.note(factory, "Second note")

      assert event1.action.id == "note_0"
      assert event2.action.id == "note_1"
    end

    test "completed_ok uses cached resume token" do
      factory = EventFactory.new("codex")
      token = ResumeToken.new("codex", "thread_123")

      {_started, factory} = EventFactory.started(factory, token)
      {completed, _factory} = EventFactory.completed_ok(factory, "Done!")

      assert completed.resume == token
    end

    test "completed_ok allows overriding resume token" do
      factory = EventFactory.new("codex")
      token1 = ResumeToken.new("codex", "thread_123")
      token2 = ResumeToken.new("codex", "thread_456")

      {_started, factory} = EventFactory.started(factory, token1)
      {completed, _factory} = EventFactory.completed_ok(factory, "Done!", resume: token2)

      assert completed.resume == token2
    end
  end
end
