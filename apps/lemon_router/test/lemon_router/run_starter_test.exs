defmodule LemonRouter.RunStarterTest do
  use ExUnit.Case, async: false

  alias LemonGateway.ExecutionRequest
  alias LemonRouter.{RunStarter, Submission}

  defmodule StarterCapturingRunProcess do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def child_spec(opts) do
      %{
        id: {__MODULE__, opts[:run_id]},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    @impl true
    def init(opts) do
      send(opts[:test_pid], {:started, opts[:run_id], opts})
      {:ok, opts}
    end
  end

  defmodule StarterBlockingRunProcess do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def child_spec(opts) do
      %{
        id: {__MODULE__, opts[:run_id]},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defmodule StarterAlreadyStartedRunProcess do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: {:global, {__MODULE__, opts[:run_id]}})
    end

    def child_spec(opts) do
      %{
        id: {__MODULE__, opts[:run_id]},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defmodule StarterFailingRunProcess do
    def start_link(_opts), do: {:error, :boom}

    def child_spec(opts) do
      %{
        id: {__MODULE__, opts[:run_id]},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end
  end

  test "starts a prepared submission and passes expected run opts to the child" do
    run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    submission =
      submission("run1", "session-1", run_supervisor, StarterCapturingRunProcess, %{
        test_pid: self(),
        custom: :value
      })

    assert {:ok, pid} =
             RunStarter.start(submission, self(), {:session, "session-1"})

    assert is_pid(pid)

    assert_receive {:started, "run1", opts}, 500
    assert opts[:run_id] == "run1"
    assert opts[:session_key] == "session-1"
    assert opts[:queue_mode] == :collect
    assert opts[:execution_request].run_id == "run1"
    assert opts[:coordinator_pid] == self()
    assert opts[:conversation_key] == {:session, "session-1"}
    assert opts[:manage_session_registry?] == false
    assert opts[:custom] == :value
  end

  test "maps a missing or dead supervisor to router_not_ready" do
    {:ok, run_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    GenServer.stop(run_supervisor, :normal)

    submission =
      submission("run1", "session-1", run_supervisor, StarterCapturingRunProcess, %{
        test_pid: self()
      })

    assert {:error, :router_not_ready} =
             RunStarter.start(submission, self(), {:session, "session-1"})
  end

  test "maps max_children saturation to run_capacity_reached" do
    run_supervisor =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, max_children: 1})

    first_submission =
      submission("run1", "session-1", run_supervisor, StarterBlockingRunProcess, %{
        test_pid: self()
      })

    second_submission =
      submission("run2", "session-2", run_supervisor, StarterBlockingRunProcess, %{
        test_pid: self()
      })

    assert {:ok, _pid} = RunStarter.start(first_submission, self(), {:session, "session-1"})

    assert {:error, :run_capacity_reached} =
             RunStarter.start(second_submission, self(), {:session, "session-2"})
  end

  test "maps already_started to the existing pid" do
    run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    submission =
      submission("run1", "session-1", run_supervisor, StarterAlreadyStartedRunProcess, %{
        test_pid: self()
      })

    assert {:ok, pid} = RunStarter.start(submission, self(), {:session, "session-1"})
    assert {:ok, ^pid} = RunStarter.start(submission, self(), {:session, "session-1"})
  end

  test "passes through unmapped child start errors" do
    run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    submission =
      submission("run1", "session-1", run_supervisor, StarterFailingRunProcess, %{
        test_pid: self()
      })

    assert {:error, :boom} = RunStarter.start(submission, self(), {:session, "session-1"})
  end

  defp submission(run_id, session_key, run_supervisor, run_process_module, run_process_opts) do
    request = %ExecutionRequest{
      run_id: run_id,
      session_key: session_key,
      prompt: "prompt for #{run_id}",
      engine_id: "codex",
      conversation_key: {:session, session_key},
      meta: %{}
    }

    Submission.new!(%{
      run_id: run_id,
      session_key: session_key,
      conversation_key: {:session, session_key},
      queue_mode: :collect,
      execution_request: request,
      run_supervisor: run_supervisor,
      run_process_module: run_process_module,
      run_process_opts: run_process_opts,
      meta: %{}
    })
  end
end
