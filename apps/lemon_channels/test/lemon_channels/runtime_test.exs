defmodule LemonChannels.RuntimeTest do
  # Mutates the router bridge configuration.
  use ExUnit.Case, async: false

  alias LemonChannels.Runtime
  alias LemonCore.RouterBridge

  defmodule RecordingRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def abort(session_key, reason), do: record({:abort, session_key, reason})
    def abort_run(run_id, reason), do: record({:abort_run, run_id, reason})
    def keep_run_alive(run_id, decision), do: record({:keep_run_alive, run_id, decision})
    def session_busy?(session_key), do: session_key == "agent:busy:main"

    defp record(event) do
      send(:persistent_term.get({__MODULE__, :test_pid}), event)
      :ok
    end
  end

  setup do
    previous = Application.get_env(:lemon_core, :router_bridge)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:lemon_core, :router_bridge)
      else
        Application.put_env(:lemon_core, :router_bridge, previous)
      end
    end)

    :persistent_term.put({RecordingRouter, :test_pid}, self())
    :ok
  end

  describe "with no router configured" do
    setup do
      Application.delete_env(:lemon_core, :router_bridge)
      :ok
    end

    test "run control reports the router as unavailable instead of pretending" do
      assert Runtime.cancel_by_run_id("run_1", :user_requested) == {:error, :unavailable}
      assert Runtime.cancel_session("agent:a:main", :user_requested) == {:error, :unavailable}
      assert Runtime.cancel_by_progress_msg("agent:a:main", 42) == {:error, :unavailable}
      assert Runtime.keep_run_alive("run_1", :continue) == {:error, :unavailable}
      assert Runtime.session_busy?("agent:a:main") == {:error, :unavailable}
    end
  end

  describe "with a router configured" do
    setup do
      :ok = RouterBridge.configure(router: RecordingRouter, run_orchestrator: RecordingRouter)
      :ok
    end

    test "run control is forwarded and answers :ok" do
      assert Runtime.cancel_by_run_id("run_1", :user_requested) == :ok
      assert_receive {:abort_run, "run_1", :user_requested}

      assert Runtime.cancel_session("agent:a:main", :timeout) == :ok
      assert_receive {:abort, "agent:a:main", :timeout}

      assert Runtime.cancel_by_progress_msg("agent:a:main", 42) == :ok
      assert_receive {:abort, "agent:a:main", :user_requested}

      assert Runtime.keep_run_alive("run_1", :cancel) == :ok
      assert_receive {:keep_run_alive, "run_1", :cancel}
    end

    test "session_busy? answers the router's boolean" do
      assert Runtime.session_busy?("agent:busy:main") == {:ok, true}
      assert Runtime.session_busy?("agent:idle:main") == {:ok, false}
    end

    test "invalid arguments are errors, not silent successes" do
      assert Runtime.cancel_by_run_id("", :user_requested) == {:error, {:invalid_run_id, ""}}
      assert Runtime.cancel_session(nil, :user_requested) == {:error, {:invalid_session_key, nil}}

      assert Runtime.keep_run_alive("run_1", :maybe) ==
               {:error, {:invalid_keep_alive, "run_1", :maybe}}
    end
  end
end
