defmodule AgentCore.CliRunners.KimiSubagentTest do
  @moduledoc """
  Unit tests for KimiSubagent.
  """

  use ExUnit.Case, async: true

  alias AgentCore.CliRunners.KimiSubagent
  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent, Action}
  alias AgentCore.EventStream

  defp create_mock_session(opts \\ []) do
    token = Keyword.get(opts, :token)
    token_agent_pid = Keyword.get(opts, :token_agent)

    token_agent =
      case token_agent_pid do
        nil ->
          {:ok, agent} = Agent.start_link(fn -> token end)
          agent

        pid ->
          pid
      end

    %{
      pid: Keyword.get(opts, :pid, self()),
      stream: Keyword.get(opts, :stream),
      resume_token: token,
      token_agent: token_agent,
      cwd: Keyword.get(opts, :cwd, "/tmp")
    }
  end

  defp create_mock_stream(events) do
    {:ok, stream} = EventStream.start_link(owner: self())

    Task.start(fn ->
      Enum.each(events, fn event ->
        EventStream.push(stream, event)
        Process.sleep(1)
      end)

      EventStream.complete(stream, [])
    end)

    stream
  end

  describe "events/1" do
    test "normalizes started/action/completed events" do
      token = ResumeToken.new("kimi", "session_123")
      started = %StartedEvent{engine: "kimi", resume: token}
      action = %ActionEvent{engine: "kimi", action: Action.new("a1", :tool, "Do thing"), phase: :started, ok: nil}
      completed = %CompletedEvent{engine: "kimi", answer: "done", ok: true, resume: token}

      stream =
        create_mock_stream([
          {:cli_event, started},
          {:cli_event, action},
          {:cli_event, completed}
        ])

      session = create_mock_session(stream: stream, token: nil)
      events = KimiSubagent.events(session) |> Enum.to_list()

      assert Enum.any?(events, fn
               {:started, ^token} -> true
               _ -> false
             end)

      assert {:action, %{id: "a1"}, :started, _} = Enum.find(events, &match?({:action, _, _, _}, &1))

      assert Enum.any?(events, fn
               {:completed, "done", _} -> true
               _ -> false
             end)
    end
  end

  describe "resume_token/1" do
    test "returns token from agent when available" do
      token = ResumeToken.new("kimi", "session_abc")
      {:ok, agent} = Agent.start_link(fn -> token end)
      session = create_mock_session(token_agent: agent, token: nil)

      assert KimiSubagent.resume_token(session) == token
    end
  end

  describe "collect_answer/1" do
    test "returns final answer" do
      completed = %CompletedEvent{engine: "kimi", answer: "final answer", ok: true, resume: nil}
      stream = create_mock_stream([{:cli_event, completed}])
      session = create_mock_session(stream: stream, token: nil)

      assert KimiSubagent.collect_answer(session) == "final answer"
    end
  end
end
