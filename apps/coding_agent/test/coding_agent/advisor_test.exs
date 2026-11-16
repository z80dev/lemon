defmodule CodingAgent.AdvisorTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Advisor, BudgetTracker, RunGraph}
  alias LemonCore.ToolPolicy

  defmodule Primary do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call(message, _, owner) do
      send(owner, {:primary_call, message})
      {:reply, :ok, owner}
    end

    def handle_cast(message, owner) do
      send(owner, {:primary_cast, message})
      {:noreply, owner}
    end
  end

  defmodule Source do
    use GenServer
    def start_link(context), do: GenServer.start_link(__MODULE__, context)
    def init(context), do: {:ok, context}
    def handle_call(:advisor_context, _, context), do: {:reply, context, context}

    def handle_call({:subscribe, _, :direct, _}, _, context),
      do: {:reply, fn -> :ok end, context}
  end

  setup do
    primary = start_supervised!({Primary, self()})
    run_id = RunGraph.new_run(%{type: :advisor_test})
    on_exit(fn -> RunGraph.delete_run(run_id) end)
    :ok = BudgetTracker.store_budget(run_id, BudgetTracker.create_budget(max_tokens: 1000))

    source =
      start_supervised!(
        {Source,
         %{
           agent: primary,
           model: nil,
           cwd: File.cwd!(),
           run_id: run_id,
           tool_policy: ToolPolicy.from_profile(:full_access)
         }}
      )

    %{source: source, primary: primary, run_id: run_id}
  end

  test "read-only intersection retains parent denials and approval requirements" do
    parent = ToolPolicy.custom(deny: ["read"], require_approval: ["grep"])
    assert {:ok, policy} = Advisor.policy(parent)
    refute ToolPolicy.allowed?(policy, "read")
    assert ToolPolicy.allowed?(policy, "grep")
    assert ToolPolicy.requires_approval?(policy, "grep")

    for name <- ~w(write edit bash eval task checkpoint rewind),
        do: refute(ToolPolicy.allowed?(policy, name))
  end

  test "real advisor model responses charge the primary budget", %{source: source, run_id: run_id} do
    owner = self()

    response = %LemonAi.Types.AssistantMessage{
      role: :assistant,
      content: [%LemonAi.Types.TextContent{text: "No concerns"}],
      api: :openai_completions,
      provider: :openai,
      model: "advisor-test",
      stop_reason: :stop,
      usage: %LemonAi.Types.Usage{
        input: 10,
        output: 5,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 15,
        cost: %LemonAi.Types.Cost{total: 0.25}
      }
    }

    stream_fn = fn _, _, _ ->
      send(owner, {:model_waiting, self()})

      receive do
        :continue -> :ok
      end

      {:ok, stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.push(stream, {:done, :stop, response})
      LemonAi.EventStream.complete(stream, response)
      {:ok, stream}
    end

    model = %LemonAi.Types.Model{
      id: "advisor-test",
      name: "Advisor test",
      api: :openai_completions,
      provider: :openai,
      base_url: "http://unused",
      reasoning: false,
      input: [:text],
      context_window: 4096,
      max_tokens: 100
    }

    {:ok, advisor} =
      Advisor.start(source,
        model: model,
        agent_options: [stream_fn: stream_fn, get_api_key: fn _ -> "test" end]
      )

    send(advisor, {:session_event, "session", {:turn_end, nil, []}, %{"seq" => 1}})
    assert_receive {:model_waiting, worker}
    task = :sys.get_state(advisor).task
    monitor = Process.monitor(task.pid)
    send(worker, :continue)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}
    assert %{tokens: 15, cost: 0.25} = BudgetTracker.get_usage(run_id)
    GenServer.stop(advisor)
  end

  test "crashed review cannot terminate or block primary", %{source: source, primary: primary} do
    owner = self()

    {:ok, advisor} =
      Advisor.start(source,
        review: fn _, _, _, _ ->
          send(owner, :review_started)
          raise "advisor failure"
        end
      )

    ref = Process.monitor(advisor)
    send(advisor, {:session_event, "session", {:turn_end, nil, []}, %{"seq" => 1}})
    assert_receive :review_started
    assert_receive {:DOWN, ^ref, :process, ^advisor, :normal}
    assert Process.alive?(source)
    assert :ok = GenServer.call(primary, :primary_turn)
  end

  test "delta delivery, normalized dedupe, per-update cap and severity", %{source: source} do
    owner = self()

    review = fn advisor, token, delta, _ ->
      send(owner, {:review, self(), advisor, token, delta})

      receive do
        :finish -> :ok
      end
    end

    {:ok, advisor} = Advisor.start(source, review: review, max_notes: 1)
    send(advisor, {:session_event, "session", {:turn_end, :first, []}, %{"seq" => 1}})
    assert_receive {:review, worker, ^advisor, token, [{:turn_end, :first, []}]}
    assert :ok = Advisor.advise(advisor, token, "critical", "  Fix   this ")
    assert_receive {:primary_cast, {:steer, _}}
    assert :suppressed = Advisor.advise(advisor, token, "info", "another")
    send(advisor, {:session_event, "session", {:turn_end, :second, []}, %{"seq" => 2}})
    send(worker, :finish)
    assert_receive {:review, worker2, ^advisor, token2, [{:turn_end, :second, []}]}
    assert :suppressed = Advisor.advise(advisor, token2, "warning", "fix this")
    assert :ok = Advisor.advise(advisor, token2, "warning", "different")
    assert_receive {:primary_call, {:steer, %{preempt: false}}}
    send(worker2, :finish)
    GenServer.stop(advisor)
  end
end
