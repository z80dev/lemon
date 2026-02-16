defmodule LemonCore.RouterBridgeTest do
  use ExUnit.Case, async: false

  alias LemonCore.{RouterBridge, RunRequest}

  defmodule TestRunOrchestrator do
    @moduledoc false

    def submit(params) do
      send(self(), {:submitted, params})
      {:ok, "run_test"}
    end
  end

  defmodule TestRouter do
    @moduledoc false

    def abort(session_key, reason) do
      send(self(), {:aborted, session_key, reason})
      :ok
    end
  end

  setup do
    original = Application.get_env(:lemon_core, :router_bridge)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_core, :router_bridge)
      else
        Application.put_env(:lemon_core, :router_bridge, original)
      end
    end)

    :ok
  end

  describe "submit_run/1" do
    test "normalizes map params into RunRequest before submit" do
      :ok = RouterBridge.configure(run_orchestrator: TestRunOrchestrator)

      assert {:ok, "run_test"} =
               RouterBridge.submit_run(%{
                 "origin" => :control_plane,
                 "session_key" => "agent:bridge:main",
                 "prompt" => "hello"
               })

      assert_receive {:submitted,
                      %RunRequest{
                        origin: :control_plane,
                        session_key: "agent:bridge:main",
                        agent_id: "bridge",
                        prompt: "hello",
                        queue_mode: :collect
                      }}
    end

    test "accepts RunRequest struct directly" do
      :ok = RouterBridge.configure(run_orchestrator: TestRunOrchestrator)

      request =
        %RunRequest{
          origin: :channel,
          session_key: "agent:bridge:main",
          agent_id: "bridge",
          prompt: "hello",
          queue_mode: :interrupt,
          meta: %{channel_id: "telegram"}
        }

      assert {:ok, "run_test"} = RouterBridge.submit_run(request)
      assert_receive {:submitted, ^request}
    end

    test "returns unavailable when no orchestrator is configured" do
      :ok = RouterBridge.configure(router: TestRouter)
      assert {:error, :unavailable} = RouterBridge.submit_run(%{session_key: "agent:x:main"})
    end
  end

  describe "abort_session/2" do
    test "delegates to router abort when configured" do
      :ok = RouterBridge.configure(router: TestRouter)

      assert :ok = RouterBridge.abort_session("agent:bridge:main", :new_session)
      assert_receive {:aborted, "agent:bridge:main", :new_session}
    end

    test "returns unavailable when no router is configured" do
      :ok = RouterBridge.configure(run_orchestrator: TestRunOrchestrator)
      assert {:error, :unavailable} = RouterBridge.abort_session("agent:x:main")
    end
  end
end
