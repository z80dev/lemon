defmodule CodingAgent.Session.JobsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ProcessStore
  alias CodingAgent.Session.Jobs

  defmodule FakeSession do
    @moduledoc false
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(%{id: id, key: key} = state) do
      {:ok, _} = Registry.register(CodingAgent.SessionRegistry, id, %{session_key: key})
      {:ok, state}
    end

    @impl true
    def handle_call(:get_state, _from, state) do
      {:reply,
       %{
         session_key: state.key,
         session_manager: %{header: %{id: state.id}},
         task_child: Map.get(state, :task_child, false),
         run_id: Map.get(state, :run_id)
       }, state}
    end
  end

  setup do
    unless Process.whereis(CodingAgent.SessionRegistry) do
      start_supervised!({Registry, keys: :unique, name: CodingAgent.SessionRegistry})
    end

    suffix = System.unique_integer([:positive])
    key = "agent:jobs-#{suffix}:main"
    root = "root-#{suffix}"
    child = "child-#{suffix}"
    ids = Agent.start_link(fn -> [] end) |> elem(1)

    on_exit(fn ->
      for id <- Agent.get(ids, & &1), do: :ets.delete(:coding_agent_processes, id)
    end)

    {:ok, key: key, root: root, child: child, suffix: suffix, ids: ids}
  end

  defp session(attrs),
    do: start_supervised!(Supervisor.child_spec({FakeSession, attrs}, id: make_ref()))

  defp job(%{ids: ids}, name, attrs) do
    id = "#{name}-#{System.unique_integer([:positive])}"
    Agent.update(ids, &[id | &1])
    ^id = ProcessStore.new_process(Map.merge(%{id: id, status: :running}, attrs))
    id
  end

  test "a key without a live root owns nothing", %{key: key} do
    assert {:ok, %{root_id: nil, jobs: [], agents: [], total: 0, truncated: false}} =
             Jobs.list(key)
  end

  test "lists only jobs owned by the root and its live task children", ctx do
    session(%{id: ctx.root, key: ctx.key})
    session(%{id: ctx.child, key: ctx.key, task_child: true, run_id: "run-1"})
    mine = job(ctx, "mine", %{owner: ctx.root, command: "sleep 60", cwd: "/work"})
    kid = job(ctx, "kid", %{owner: ctx.child, command: "tail -f log"})
    _foreign = job(ctx, "foreign", %{owner: "someone-else", command: "rm -rf /"})
    _unowned = job(ctx, "unowned", %{owner: nil, command: "echo"})

    assert {:ok, listing} = Jobs.list(ctx.key)
    assert listing.root_id == ctx.root
    assert listing.jobs |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([mine, kid])
    assert listing.total == 2
    assert Enum.find(listing.jobs, &(&1.id == mine)).owner_id == ctx.root
    assert Enum.find(listing.jobs, &(&1.id == kid)).owner_id == ctx.child
    assert [%{id: child_id, parent_id: root_id}] = listing.agents
    assert child_id == ctx.child and root_id == ctx.root
  end

  test "lists are bounded to the newest 100 jobs and report the rest", ctx do
    session(%{id: ctx.root, key: ctx.key})
    for n <- 1..105, do: job(ctx, "bulk#{n}", %{owner: ctx.root, command: "job #{n}"})

    assert {:ok, listing} = Jobs.list(ctx.key)
    assert length(listing.jobs) == 100
    assert listing.total == 105
    assert listing.truncated
  end

  test "commands are redacted and bounded", ctx do
    session(%{id: ctx.root, key: ctx.key})
    long = String.duplicate("x", 5_000)
    command = "curl -H 'Authorization: Bearer sk-secret-1234567890abcdef' " <> long
    id = job(ctx, "cmd", %{owner: ctx.root, command: command})

    assert {:ok, %{jobs: [%{id: ^id, command: shown}]}} = Jobs.list(ctx.key)
    assert byte_size(shown) <= 2_048
    refute shown =~ "sk-secret-1234567890abcdef"
  end

  test "inspect returns facts and a bounded redacted tail without moving the read cursor", ctx do
    session(%{id: ctx.root, key: ctx.key})
    id = job(ctx, "out", %{owner: ctx.root, command: "make", cwd: "/work", os_pid: 4242})

    for n <- 1..50 do
      ProcessStore.append_log(id, "line #{n} API_KEY=sk-secret-1234567890abcdef")
    end

    {:ok, before_record, _} = ProcessStore.get(id)

    assert {:ok, detail} = Jobs.inspect_job(ctx.key, id, tail_bytes: 200)
    assert detail.id == id
    assert detail.cwd == "/work"
    assert detail.pids == [4242]
    assert byte_size(detail.output) <= 200
    assert detail.output =~ "line 50"
    refute detail.output =~ "sk-secret-1234567890abcdef"
    assert detail.output_truncated

    assert {:ok, %{output: ""}} = Jobs.inspect_job(ctx.key, id, tail_bytes: 0)
    {:ok, after_record, _} = ProcessStore.get(id)
    assert after_record.read_cursor == before_record.read_cursor
  end

  test "inspect hides jobs outside the session's owners", ctx do
    session(%{id: ctx.root, key: ctx.key})
    foreign = job(ctx, "foreign", %{owner: "someone-else", command: "secret work"})

    assert {:error, :not_found} = Jobs.inspect_job(ctx.key, foreign)
    assert {:error, :not_found} = Jobs.inspect_job(ctx.key, "../etc/passwd")
    assert {:error, :not_found} = Jobs.cancel(ctx.key, foreign)
  end

  test "cancel is limited to jobs the root owns", ctx do
    session(%{id: ctx.root, key: ctx.key})
    session(%{id: ctx.child, key: ctx.key, task_child: true, run_id: "run-1"})
    kid = job(ctx, "kid", %{owner: ctx.child, command: "tail -f log"})

    assert {:error, :not_found} = Jobs.cancel(ctx.key, kid)
  end

  test "cancel of a settled job conflicts and an unconfirmed kill is outcome_unknown", ctx do
    session(%{id: ctx.root, key: ctx.key})
    done = job(ctx, "done", %{owner: ctx.root, status: :completed, exit_code: 0, command: "true"})
    # No live process session backs this record: termination cannot be confirmed.
    held = job(ctx, "held", %{owner: ctx.root, status: :running, command: "sleep 600"})

    assert {:error, :already_terminal} = Jobs.cancel(ctx.key, done)
    assert {:error, :outcome_unknown} = Jobs.cancel(ctx.key, held)
    assert {:ok, %{status: :running}} = Jobs.inspect_job(ctx.key, held)
  end

  test "ambiguous roots fail closed", ctx do
    session(%{id: ctx.root, key: ctx.key})
    session(%{id: ctx.root <> "-twin", key: ctx.key})

    assert {:error, :unavailable} = Jobs.list(ctx.key)
  end
end
