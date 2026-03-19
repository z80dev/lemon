defmodule LemonSim.Examples.VendingBenchTest do
  use ExUnit.Case, async: true

  alias Ai.Types.{AssistantMessage, Model, TextContent, ToolCall}
  alias LemonSim.Runner
  alias LemonSim.Examples.VendingBench
  alias LemonSim.Examples.VendingBench.ActionSpace
  alias LemonSim.Examples.VendingBench.PhysicalWorker

  test "initial_state propagates the sim id into memory namespaces" do
    state = VendingBench.initial_state()

    assert state.world.operator_memory_namespace == "#{state.sim_id}/operator"
    assert state.world.physical_worker_memory_namespace == "#{state.sim_id}/physical_worker"
  end

  test "support-tool events are preserved alongside the terminal action" do
    state =
      VendingBench.initial_state(sim_id: "vb_support_terminal")
      |> put_in([Access.key(:world), :inbox], [
        %{from: "freshco", subject: "hello", body: "restock"}
      ])

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-read-inbox",
             name: "read_inbox",
             arguments: %{}
           },
           %ToolCall{
             type: :tool_call,
             id: "call-order",
             name: "send_supplier_email",
             arguments: %{
               "supplier_id" => "freshco",
               "item_id" => "sparkling_water",
               "quantity" => 6
             }
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    opts = [
      model: fake_model("operator"),
      complete_fn: complete_fn,
      stream_options: %{},
      persist?: false,
      tool_policy: VendingBench.ToolPolicy,
      support_tool_matcher: fn tool ->
        String.starts_with?(tool.name, "memory_") or
          tool.name in ~w(read_inbox check_balance check_storage inspect_supplier_directory review_recent_sales)
      end
    ]

    assert {:ok, result} = Runner.step(state, VendingBench.modules(), opts)

    assert Enum.map(result.events, & &1.kind) == ["operator_read_inbox", "supplier_email_sent"]
    assert result.state.world.time_minutes == 570
    assert length(result.state.world.pending_deliveries) == 1
  end

  test "invalid terminal actions become action_rejected events instead of step failures" do
    state = VendingBench.initial_state(sim_id: "vb_invalid_terminal")

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-invalid-order",
             name: "send_supplier_email",
             arguments: %{
               "supplier_id" => "unknown_supplier",
               "item_id" => "sparkling_water",
               "quantity" => 6
             }
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, result} =
             Runner.step(
               state,
               VendingBench.modules(),
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               tool_policy: VendingBench.ToolPolicy
             )

    assert Enum.map(result.events, & &1.kind) == ["action_rejected"]
    assert result.state.world.bank_balance == 500.0
    assert result.state.world.pending_deliveries == []
    assert result.state.world.coordination_failures == 1
  end

  test "run_physical_worker uses the dedicated worker model and stream options" do
    state = VendingBench.initial_state(sim_id: "vb_worker_model")
    {:ok, captured} = Agent.start_link(fn -> nil end)

    runner = fn _world, worker_opts ->
      Agent.update(captured, fn _ -> worker_opts end)

      {:ok,
       %{
         events: [VendingBench.Events.physical_worker_finished("Collected cash.", [])],
         summary: "Collected cash.",
         tool_calls: []
       }}
    end

    assert {:ok, tools} =
             ActionSpace.tools(
               state,
               model: fake_model("operator"),
               stream_options: %{api_key: "operator-key"},
               physical_worker_model: fake_model("worker"),
               physical_worker_stream_options: %{api_key: "worker-key"},
               physical_worker_runner: runner
             )

    tool = Enum.find(tools, &(&1.name == "run_physical_worker"))

    assert {:ok, result} =
             tool.execute.(
               "call-worker",
               %{"instructions" => "Collect cash and report."},
               nil,
               fn _ -> :ok end
             )

    worker_opts = Agent.get(captured, & &1)

    assert worker_opts[:model].id == "worker"
    assert worker_opts[:stream_options] == %{api_key: "worker-key"}

    assert Enum.map(result.details["events"], & &1.kind) == [
             "physical_worker_run_requested",
             "physical_worker_finished"
           ]

    [_, finished_event] = result.details["events"]
    assert finished_event.payload["tool_calls"] == []
    assert finished_event.payload["memory_namespace"] == "vb_worker_model/physical_worker"
    assert finished_event.payload["turn_count"] == nil
  end

  test "run_physical_worker rejects dispatches that would run past 17:00" do
    state =
      VendingBench.initial_state(sim_id: "vb_worker_cutoff")
      |> put_in([Access.key(:world), :time_minutes], 16 * 60)

    {:ok, called?} = Agent.start_link(fn -> false end)

    runner = fn _world, _worker_opts ->
      Agent.update(called?, fn _ -> true end)

      {:ok,
       %{
         events: [VendingBench.Events.physical_worker_finished("Should not run.", [])],
         summary: "Should not run.",
         tool_calls: []
       }}
    end

    assert {:ok, tools} =
             ActionSpace.tools(
               state,
               model: fake_model("operator"),
               stream_options: %{},
               physical_worker_runner: runner
             )

    tool = Enum.find(tools, &(&1.name == "run_physical_worker"))

    assert {:ok, result} =
             tool.execute.(
               "call-worker",
               %{"instructions" => "Collect cash and report."},
               nil,
               fn _ -> :ok end
             )

    refute Agent.get(called?, & &1)
    assert Enum.map(result.details["events"], & &1.kind) == ["action_rejected"]
    assert AgentCore.get_text(result) =~ "Worker dispatch rejected"
  end

  test "physical worker run captures real subagent tool events" do
    world =
      VendingBench.initial_world(sim_id: "vb_real_worker")
      |> put_in([:storage, :inventory], %{"sparkling_water" => 3})

    stream_fn =
      scripted_stream_fn([
        assistant_tool_message([
          tool_call("stock_products", %{
            "slot_id" => "A1",
            "item_id" => "sparkling_water",
            "quantity" => 3
          }),
          tool_call("finish_visit", %{"summary" => "Stocked A1."})
        ]),
        assistant_text_message("Visit completed.")
      ])

    assert {:ok, result} =
             PhysicalWorker.run(
               world,
               model: fake_model("worker"),
               stream_options: %{},
               stream_fn: stream_fn,
               sim_id: "vb_real_worker"
             )

    assert Enum.map(result.events, & &1.kind) == [
             "physical_worker_started",
             "machine_stocked",
             "physical_worker_finished"
           ]

    assert Enum.map(result.tool_calls, & &1.tool_name) == ["stock_products", "finish_visit"]
  end

  test "next day rollover delivers items scheduled for the next morning" do
    state =
      VendingBench.initial_state(sim_id: "vb_delivery_timing")
      |> put_in([Access.key(:world), :pending_deliveries], [
        %{
          supplier_id: "freshco",
          item_id: "sparkling_water",
          quantity: 6,
          cost: 6.6,
          delivery_day: 2,
          ordered_day: 1
        }
      ])

    assert {:ok, next_state, {:decide, "Day 2 begins. Weather: " <> _}} =
             Runner.ingest_events(
               state,
               [VendingBench.Events.next_day_waited()],
               VendingBench.modules().updater
             )

    assert next_state.world.day_number == 2
    assert next_state.world.pending_deliveries == []
    assert next_state.world.storage.inventory["sparkling_water"] == 6

    assert Enum.any?(next_state.world.inbox, fn msg ->
             msg.day == 2 and msg.subject == "Order Delivered"
           end)
  end

  test "invalid worker events are rejected by the updater and counted as coordination failures" do
    state = VendingBench.initial_state(sim_id: "vb_invalid_worker_event")

    runner = fn _world, _worker_opts ->
      {:ok,
       %{
         events: [
           VendingBench.Events.machine_stocked("Z9", "sparkling_water", 3, 3),
           VendingBench.Events.physical_worker_finished("Tried to stock invalid slot.", [])
         ],
         summary: "Tried to stock invalid slot.",
         tool_calls: []
       }}
    end

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-worker",
             name: "run_physical_worker",
             arguments: %{"instructions" => "Stock slot Z9."}
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, result} =
             Runner.step(
               state,
               VendingBench.modules(),
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               tool_policy: VendingBench.ToolPolicy,
               physical_worker_runner: runner
             )

    assert result.state.world.physical_worker_run_count == 1
    assert result.state.world.coordination_failures == 1
    refute get_in(result.state.world, [:machine, :slots, "Z9"])

    assert Enum.any?(result.state.recent_events, fn event ->
             event.kind == "action_rejected" and event.payload["actor_id"] == "physical_worker"
           end)
  end

  test "late physical worker dispatch events are rejected by the updater" do
    state =
      VendingBench.initial_state(sim_id: "vb_late_worker_event")
      |> put_in([Access.key(:world), :time_minutes], 16 * 60)

    assert {:ok, next_state, :skip} =
             Runner.ingest_events(
               state,
               [VendingBench.Events.physical_worker_run_requested("Collect cash.")],
               VendingBench.modules().updater
             )

    assert next_state.world.physical_worker_run_count == 0
    assert next_state.world.time_minutes == 16 * 60
    assert next_state.world.coordination_failures == 1

    assert Enum.any?(next_state.recent_events, fn event ->
             event.kind == "action_rejected" and event.payload["actor_id"] == "operator"
           end)
  end

  test "completed runs keep the final reported day at max_days" do
    state = VendingBench.initial_state(sim_id: "vb_terminal_day", max_days: 1)

    assert {:ok, next_state, :skip} =
             Runner.ingest_events(
               state,
               [VendingBench.Events.next_day_waited()],
               VendingBench.modules().updater
             )

    assert next_state.world.status == "complete"
    assert next_state.world.day_number == 1
  end

  test "worker report metadata is persisted in authoritative state" do
    state = VendingBench.initial_state(sim_id: "vb_worker_report")

    runner = fn _world, _worker_opts ->
      {:ok,
       %{
         events: [VendingBench.Events.physical_worker_finished("Collected cash.", [])],
         summary: "Collected cash.",
         tool_calls: [
           %{
             tool_name: "collect_cash",
             result_text: "Collected $12.50 from the machine",
             result_details: %{},
             is_error: false
           }
         ],
         turn_count: 2
       }}
    end

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "call-worker-report",
             name: "run_physical_worker",
             arguments: %{"instructions" => "Collect cash and report."}
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, result} =
             Runner.step(
               state,
               VendingBench.modules(),
               model: fake_model("operator"),
               complete_fn: complete_fn,
               stream_options: %{},
               persist?: false,
               tool_policy: VendingBench.ToolPolicy,
               physical_worker_runner: runner
             )

    assert result.state.world.physical_worker_last_report == %{
             summary: "Collected cash.",
             day: 1,
             time: 615,
             tool_calls: [
               %{
                 tool_name: "collect_cash",
                 result_text: "Collected $12.50 from the machine",
                 result_details: %{},
                 is_error: false
               }
             ],
             memory_namespace: "vb_worker_report/physical_worker",
             turn_count: 2
           }
  end

  defp fake_model(id) do
    %Model{
      id: id,
      name: id,
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end

  defp assistant_text_message(text) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp assistant_tool_message(tool_calls) do
    %AssistantMessage{
      role: :assistant,
      content: tool_calls,
      stop_reason: :tool_use,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp tool_call(name, arguments) do
    %ToolCall{
      type: :tool_call,
      id: "call_#{name}_#{System.unique_integer([:positive])}",
      name: name,
      arguments: arguments
    }
  end

  defp scripted_stream_fn(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn _model, _context, _options ->
      response =
        Agent.get_and_update(agent, fn
          [next | rest] -> {next, rest}
          [] -> {assistant_text_message(""), []}
        end)

      {:ok, response_to_event_stream(response)}
    end
  end

  defp response_to_event_stream(response) do
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.push(stream, {:start, response})

      Enum.with_index(response.content)
      |> Enum.each(fn {content, idx} ->
        case content do
          %TextContent{text: text} ->
            Ai.EventStream.push(stream, {:text_start, idx, response})
            Ai.EventStream.push(stream, {:text_delta, idx, text, response})
            Ai.EventStream.push(stream, {:text_end, idx, response})

          %ToolCall{} = tool_call ->
            Ai.EventStream.push(stream, {:tool_call_start, idx, tool_call, response})
            Ai.EventStream.push(stream, {:tool_call_end, idx, tool_call, response})
        end
      end)

      Ai.EventStream.push(stream, {:done, response.stop_reason, response})
      Ai.EventStream.complete(stream, response)
    end)

    stream
  end
end
