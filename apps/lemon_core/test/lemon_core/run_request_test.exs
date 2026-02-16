defmodule LemonCore.RunRequestTest do
  use ExUnit.Case, async: true

  alias LemonCore.RunRequest

  describe "normalize/1" do
    test "applies defaults and derives agent_id from session_key" do
      request =
        RunRequest.normalize(%{
          session_key: "agent:test-agent:main",
          prompt: "hello"
        })

      assert request.origin == :unknown
      assert request.session_key == "agent:test-agent:main"
      assert request.agent_id == "test-agent"
      assert request.prompt == "hello"
      assert request.queue_mode == :collect
      assert request.engine_id == nil
      assert request.meta == %{}
      assert request.cwd == nil
      assert request.tool_policy == nil
    end

    test "reads atom and string keys" do
      request =
        RunRequest.normalize(%{
          "origin" => :control_plane,
          "session_key" => "agent:alpha:main",
          "agent_id" => "alpha",
          "prompt" => "go",
          "queue_mode" => :interrupt,
          "engine_id" => "openai:gpt-4o",
          "meta" => %{"foo" => "bar"},
          "cwd" => "/tmp",
          "tool_policy" => %{"sandbox" => true}
        })

      assert request.origin == :control_plane
      assert request.session_key == "agent:alpha:main"
      assert request.agent_id == "alpha"
      assert request.prompt == "go"
      assert request.queue_mode == :interrupt
      assert request.engine_id == "openai:gpt-4o"
      assert request.meta == %{"foo" => "bar"}
      assert request.cwd == "/tmp"
      assert request.tool_policy == %{"sandbox" => true}
    end

    test "normalizes struct input and applies defaults to nil fields" do
      request =
        RunRequest.normalize(%RunRequest{
          session_key: "agent:session-derived:main",
          agent_id: nil,
          queue_mode: nil,
          meta: nil,
          tool_policy: "invalid"
        })

      assert request.agent_id == "session-derived"
      assert request.queue_mode == :collect
      assert request.meta == %{}
      assert request.tool_policy == nil
    end

    test "falls back to default agent_id when session_key is missing/invalid" do
      assert RunRequest.normalize(%{}).agent_id == "default"
      assert RunRequest.normalize(%{session_key: "invalid"}).agent_id == "default"
    end
  end
end
