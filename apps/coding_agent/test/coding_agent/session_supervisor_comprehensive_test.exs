defmodule CodingAgent.SessionSupervisorComprehensiveTest do
  @moduledoc """
  Concurrency and cleanup through the real `CodingAgent.SessionSupervisor`,
  scoped to a per-test supervisor and registry (`:supervisor`/`:registry`).
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Session
  alias CodingAgent.SessionSupervisor

  import CodingAgent.AsyncHelpers

  setup do
    unique = System.unique_integer([:positive])
    cwd = Path.join(System.tmp_dir!(), "#{__MODULE__}_#{unique}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)

    registry = Module.concat([__MODULE__, "Registry#{unique}"])
    supervisor = Module.concat([__MODULE__, "Supervisor#{unique}"])
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({SessionSupervisor, name: supervisor})
    {:ok, cwd: cwd, target: [supervisor: supervisor, registry: registry]}
  end

  defp start_session(%{cwd: cwd, target: target}, opts \\ []) do
    [
      cwd: cwd,
      workspace_dir: Path.join(cwd, "workspace"),
      model: mock_model(),
      tools: [],
      extension_inventory: {[], []},
      mcp_tools: []
    ]
    |> Keyword.merge(target)
    |> Keyword.merge(opts)
    |> SessionSupervisor.start_session()
  end

  defp mock_model do
    %LemonAi.Types.Model{
      id: "mock-model",
      name: "Mock Model",
      api: :mock_api,
      provider: :mock_provider,
      base_url: "",
      reasoning: false,
      input: [:text],
      cost: %LemonAi.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 10_000,
      max_tokens: 1_000,
      headers: %{},
      compat: nil
    }
  end

  test "concurrent starts and stops leave exactly the kept sessions", %{target: target} = ctx do
    parent = self()
    # Load the cwd's config once, so the wave contends on the supervisor rather
    # than on the shared config cache's first load.
    {:ok, first} = start_session(ctx)

    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          session_id = "concurrent-#{i}-#{System.unique_integer([:positive])}"
          {:ok, pid} = start_session(ctx, session_id: session_id)
          send(parent, {:started, self()})
          receive do: (:contend -> :ok)

          if rem(i, 2) == 0 do
            :ok = SessionSupervisor.stop_session(session_id, target)
            {:stopped, session_id, pid}
          else
            {:kept, session_id, pid}
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:started, _}, 30_000)
    Enum.each(tasks, &send(&1.pid, :contend))
    results = Task.await_many(tasks, 30_000)

    kept = [first | for({:kept, _id, pid} <- results, do: pid)]
    stopped = for {:stopped, id, pid} <- results, do: {id, pid}

    assert Enum.sort(SessionSupervisor.list_sessions(target)) == Enum.sort(kept)

    for {session_id, pid} <- stopped do
      refute Process.alive?(pid)

      assert_eventually(fn -> SessionSupervisor.lookup(session_id, target) == :error end,
        message: "stopped session id still registered"
      )
    end
  end

  test "stopping a session also stops its agent", %{target: target} = ctx do
    {:ok, pid} = start_session(ctx)
    agent = Session.get_state(pid).agent
    agent_ref = Process.monitor(agent)

    assert :ok = SessionSupervisor.stop_session(pid, target)
    assert_receive {:DOWN, ^agent_ref, :process, ^agent, _}, 5_000
    assert SessionSupervisor.list_sessions(target) == []
  end
end
