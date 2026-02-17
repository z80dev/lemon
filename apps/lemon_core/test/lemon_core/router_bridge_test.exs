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

    def abort_run(run_id, reason) do
      send(self(), {:run_aborted, run_id, reason})
      :ok
    end
  end

  defmodule AlternativeRunOrchestrator do
    @moduledoc false

    def submit(_params), do: {:ok, "run_alt"}
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
    test "forwards RunRequest params to orchestrator" do
      :ok = RouterBridge.configure(run_orchestrator: TestRunOrchestrator)

      request =
        RunRequest.new(%{
          origin: :control_plane,
          session_key: "agent:bridge:main",
          prompt: "hello"
        })

      assert {:ok, "run_test"} = RouterBridge.submit_run(request)

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

      request =
        %RunRequest{
          origin: :channel,
          session_key: "agent:x:main",
          agent_id: "x",
          prompt: "ping"
        }

      assert {:error, :unavailable} = RouterBridge.submit_run(request)
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

  describe "abort_run/2" do
    test "delegates to router abort_run when configured" do
      :ok = RouterBridge.configure(router: TestRouter)

      assert :ok = RouterBridge.abort_run("run-123", :user_requested)
      assert_receive {:run_aborted, "run-123", :user_requested}
    end

    test "returns unavailable when no router is configured" do
      :ok = RouterBridge.configure(run_orchestrator: TestRunOrchestrator)
      assert {:error, :unavailable} = RouterBridge.abort_run("run-x")
    end
  end

  describe "configure guardrails" do
    test "configure_guarded/1 rejects conflicting non-nil overrides" do
      :ok =
        RouterBridge.configure(
          run_orchestrator: TestRunOrchestrator,
          router: TestRouter
        )

      assert {:error, {:already_configured, :run_orchestrator, TestRunOrchestrator, AlternativeRunOrchestrator}} =
               RouterBridge.configure_guarded(run_orchestrator: AlternativeRunOrchestrator)
    end

    test "merge mode preserves unspecified keys" do
      :ok =
        RouterBridge.configure(
          run_orchestrator: TestRunOrchestrator,
          router: TestRouter
        )

      :ok = RouterBridge.configure([router: TestRouter], mode: :merge)

      request =
        %RunRequest{
          origin: :channel,
          session_key: "agent:merge:main",
          agent_id: "merge",
          prompt: "test"
        }

      assert {:ok, "run_test"} = RouterBridge.submit_run(request)
      assert_receive {:submitted, %RunRequest{}}
    end
  end
end
