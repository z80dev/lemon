defmodule CodingAgent.Tools.ExecuteCodeRpcTest do
  @moduledoc """
  Protocol-level tests for the execute_code RPC pump. No python3 involved: the
  test writes `req-*.json` files directly and reads the `res-*.json` the pump
  writes back, which is exactly what the generated shim does.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.ToolPolicy
  alias CodingAgent.Tools.ExecuteCode.Rpc
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{ImageContent, TextContent}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    rpc_dir = Path.join(tmp_dir, "rpc")
    File.mkdir_p!(rpc_dir)
    {:ok, rpc_dir: rpc_dir}
  end

  describe "serve/2 happy path" do
    test "round trips a request and counts it", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir))

      write_request(rpc_dir, 1, "echo", %{"value" => "hello"})
      assert %{"id" => 1, "ok" => true, "content" => "hello"} = await_response(rpc_dir, 1)

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.calls == 1
      assert stats.errors == 0
      assert stats.denied == 0
      assert stats.bytes == byte_size("hello")
      assert MapSet.to_list(stats.tools_used) == ["echo"]
    end

    test "responses land atomically and requests with a response are never reprocessed", %{
      rpc_dir: rpc_dir
    } do
      # A pre-existing response means the pump has already answered this id.
      File.write!(
        Path.join(rpc_dir, "res-2.json"),
        Jason.encode!(%{"id" => 2, "ok" => true, "content" => "preexisting"})
      )

      pump = start_pump(ctx(rpc_dir))

      write_request(rpc_dir, 2, "echo", %{"value" => "fresh"})
      write_request(rpc_dir, 1, "echo", %{"value" => "served"})
      assert %{"content" => "served"} = await_response(rpc_dir, 1)

      {:ok, :done, stats} = finish_pump(pump)

      assert %{"content" => "preexisting"} = read_response(rpc_dir, 2)
      assert stats.calls == 1
      # Nothing is left half-written: no `.tmp` files survive the handshake.
      assert Path.wildcard(Path.join(rpc_dir, "*.tmp")) == []
    end

    test "concurrently written requests are all served, lowest id first", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir))

      write_request(rpc_dir, 3, "order", %{"value" => "three"})
      write_request(rpc_dir, 2, "order", %{"value" => "two"})

      assert %{"content" => "two"} = await_response(rpc_dir, 2)
      assert %{"content" => "three"} = await_response(rpc_dir, 3)

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.calls == 2
      assert [next_ordered(), next_ordered()] == [2, 3]
    end

    test "non-text content blocks are flagged rather than forwarded", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir))

      write_request(rpc_dir, 1, "mixed", %{})
      assert %{"ok" => true, "content" => content} = await_response(rpc_dir, 1)
      assert content == "before\n[non-text content omitted]\nafter"

      finish_pump(pump)
    end
  end

  describe "serve/2 rejections" do
    test "malformed json is answered, not crashed on", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir))

      File.write!(Path.join(rpc_dir, "req-1.json"), "{not json")
      assert %{"ok" => false, "error" => "invalid rpc request"} = await_response(rpc_dir, 1)

      # The pump keeps serving afterwards.
      write_request(rpc_dir, 2, "echo", %{"value" => "still here"})
      assert %{"ok" => true, "content" => "still here"} = await_response(rpc_dir, 2)

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.errors == 1
      assert stats.calls == 2
    end

    test "a tool outside the script allowlist is rejected", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir))

      write_request(rpc_dir, 1, "bash", %{"command" => "rm -rf /"})
      assert %{"ok" => false, "error" => error} = await_response(rpc_dir, 1)
      assert error =~ "tool 'bash' is not available inside execute_code scripts"

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.errors == 1
    end

    test "policy denial uses the policy's own reason", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir, tool_policy: ToolPolicy.custom(deny: ["echo"])))

      write_request(rpc_dir, 1, "echo", %{"value" => "nope"})
      assert %{"ok" => false, "error" => error} = await_response(rpc_dir, 1)
      assert error =~ "deny list"

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.denied == 1
      assert stats.errors == 0
    end

    test "an inner tool that raises becomes a ToolError, and the pump survives", %{
      rpc_dir: rpc_dir
    } do
      pump = start_pump(ctx(rpc_dir))

      write_request(rpc_dir, 1, "boom", %{})
      assert %{"ok" => false, "error" => error} = await_response(rpc_dir, 1)
      assert error =~ "boom went off"

      write_request(rpc_dir, 2, "echo", %{"value" => "alive"})
      assert %{"ok" => true, "content" => "alive"} = await_response(rpc_dir, 2)

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.errors == 1
      assert stats.calls == 2
    end

    test "an inner tool returning {:error, reason} becomes a ToolError", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir))

      write_request(rpc_dir, 1, "failing", %{})
      assert %{"ok" => false, "error" => "no such file"} = await_response(rpc_dir, 1)

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.errors == 1
    end
  end

  describe "serve/2 approval" do
    test "an approved call runs", %{rpc_dir: rpc_dir} do
      pump =
        start_pump(
          ctx(rpc_dir,
            tool_policy: ToolPolicy.custom(require_approval: ["echo"]),
            approval_context: %{approval_request_fun: fn _ -> {:ok, :approved, :test} end}
          )
        )

      write_request(rpc_dir, 1, "echo", %{"value" => "approved"})
      assert %{"ok" => true, "content" => "approved"} = await_response(rpc_dir, 1)

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.denied == 0
      assert stats.calls == 1
    end

    test "a denied call becomes a ToolError and counts as denied", %{rpc_dir: rpc_dir} do
      pump =
        start_pump(
          ctx(rpc_dir,
            tool_policy: ToolPolicy.custom(require_approval: ["echo"]),
            approval_context: %{approval_request_fun: fn _ -> {:ok, :denied} end}
          )
        )

      write_request(rpc_dir, 1, "echo", %{"value" => "nope"})
      assert %{"ok" => false, "error" => error} = await_response(rpc_dir, 1)
      assert error =~ "approval denied for 'echo'"

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.denied == 1
    end

    test "an approval timeout becomes a ToolError", %{rpc_dir: rpc_dir} do
      pump =
        start_pump(
          ctx(rpc_dir,
            tool_policy: ToolPolicy.custom(require_approval: ["echo"]),
            approval_context: %{
              timeout_ms: 30_000,
              approval_request_fun: fn _ -> {:error, :timeout} end
            }
          )
        )

      write_request(rpc_dir, 1, "echo", %{"value" => "waiting"})
      assert %{"ok" => false, "error" => error} = await_response(rpc_dir, 1)
      assert error =~ "approval timed out for 'echo'"

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.denied == 1
    end

    test "an approval-layer crash is contained instead of stalling the script", %{
      rpc_dir: rpc_dir
    } do
      # `CodingAgent.ToolExecutor` builds its timeout message with
      # `div(timeout_ms, 1000)`, which raises when the context carries the
      # default `:infinity`. The pump must still answer the request -- an
      # unanswered request would hang the script until its wall clock ran out.
      pump =
        start_pump(
          ctx(rpc_dir,
            tool_policy: ToolPolicy.custom(require_approval: ["echo"]),
            approval_context: %{approval_request_fun: fn _ -> {:error, :timeout} end}
          )
        )

      write_request(rpc_dir, 1, "echo", %{"value" => "waiting"})
      assert %{"ok" => false, "error" => error} = await_response(rpc_dir, 1)
      assert is_binary(error)

      write_request(rpc_dir, 2, "big", %{"size" => 5})
      assert %{"ok" => true, "content" => "xxxxx"} = await_response(rpc_dir, 2)

      {:ok, :done, _stats} = finish_pump(pump)
    end
  end

  describe "serve/2 caps" do
    test "the call cap admits exactly max_calls requests", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir, max_calls: 3))

      for id <- 1..5, do: write_request(rpc_dir, id, "echo", %{"value" => "call#{id}"})

      for id <- 1..3 do
        assert %{"ok" => true, "content" => content} = await_response(rpc_dir, id)
        assert content == "call#{id}"
      end

      for id <- 4..5 do
        assert %{"ok" => false, "error" => error} = await_response(rpc_dir, id)
        assert error =~ "rpc call limit exceeded (max 3 calls per script)"
      end

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.calls == 3
      assert stats.errors == 2
    end

    test "an over-budget result is refused without consuming the budget", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir, max_result_bytes: 100))

      write_request(rpc_dir, 1, "big", %{"size" => 150})
      assert %{"ok" => false, "error" => error} = await_response(rpc_dir, 1)
      assert error =~ "rpc result byte budget exceeded"
      assert error =~ "150 bytes"
      assert error =~ "100 bytes remaining of 100"

      write_request(rpc_dir, 2, "echo", %{"value" => "small"})
      assert %{"ok" => true, "content" => "small"} = await_response(rpc_dir, 2)

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.errors == 1
      assert stats.bytes == byte_size("small")
    end
  end

  describe "serve/2 task lifecycle" do
    @tag :capture_log
    test "a crashed script task is reported as :exit with the stats so far", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir), fn -> receive(do: (:die -> exit(:kaboom))) end)

      write_request(rpc_dir, 1, "echo", %{"value" => "before the crash"})
      await_response(rpc_dir, 1)

      send(pump.script_pid, :die)
      assert {:exit, :kaboom, stats} = Task.await(pump.runner, 5_000)
      assert stats.calls == 1
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp ctx(rpc_dir, overrides \\ []) do
    %{
      tools: stub_tools(),
      tool_policy: Keyword.get(overrides, :tool_policy),
      approval_context: Keyword.get(overrides, :approval_context),
      max_calls: Keyword.get(overrides, :max_calls, 100),
      max_result_bytes: Keyword.get(overrides, :max_result_bytes, 5_242_880),
      signal: nil,
      rpc_dir: rpc_dir,
      poll_interval_ms: 5
    }
  end

  defp stub_tools do
    test = self()

    %{
      "echo" => stub_tool("echo", fn params -> text(params["value"] || "") end),
      "order" =>
        stub_tool("order", fn params ->
          send(test, {:ordered, params["id"]})
          text(params["value"] || "")
        end),
      "big" =>
        stub_tool("big", fn params -> text(String.duplicate("x", params["size"] || 10)) end),
      "boom" => stub_tool("boom", fn _params -> raise "boom went off" end),
      "failing" => stub_tool("failing", fn _params -> {:error, "no such file"} end),
      "mixed" =>
        stub_tool("mixed", fn _params ->
          %AgentToolResult{
            content: [
              %TextContent{text: "before"},
              %ImageContent{data: "abc", mime_type: "image/png"},
              %TextContent{text: "after"}
            ]
          }
        end)
    }
  end

  defp stub_tool(name, fun) do
    %AgentTool{
      name: name,
      description: "stub",
      label: name,
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _id, params, _signal, _on_update -> fun.(params) end
    }
  end

  defp text(value), do: %AgentToolResult{content: [%TextContent{text: value}]}

  # The pump must run in the process that owns the task (`Task.yield/2`
  # requires ownership), so the runner Task both starts the script task and
  # serves it -- the same arrangement `ExecuteCode.execute/6` uses.
  defp start_pump(ctx, script_fun \\ nil) do
    test = self()
    script_fun = script_fun || fn -> receive(do: ({:finish, result} -> result)) end

    runner =
      Task.async(fn ->
        script = Task.Supervisor.async_nolink(CodingAgent.TaskSupervisor, script_fun)
        send(test, {:script_pid, script.pid})
        Rpc.serve(script, ctx)
      end)

    script_pid =
      receive do
        {:script_pid, pid} -> pid
      after
        5_000 -> flunk("script task never started")
      end

    %{runner: runner, script_pid: script_pid}
  end

  defp finish_pump(pump, result \\ :done) do
    send(pump.script_pid, {:finish, result})
    Task.await(pump.runner, 5_000)
  end

  defp write_request(rpc_dir, id, tool, params) do
    params = Map.put_new(params, "id", id)
    tmp = Path.join(rpc_dir, "req-#{id}.json.tmp")
    File.write!(tmp, Jason.encode!(%{"id" => id, "tool" => tool, "params" => params}))
    File.rename!(tmp, Path.join(rpc_dir, "req-#{id}.json"))
  end

  defp await_response(rpc_dir, id, attempts \\ 400) do
    path = Path.join(rpc_dir, "res-#{id}.json")

    cond do
      File.exists?(path) ->
        read_response(rpc_dir, id)

      attempts <= 0 ->
        flunk("no response for request #{id}")

      true ->
        Process.sleep(5)
        await_response(rpc_dir, id, attempts - 1)
    end
  end

  defp read_response(rpc_dir, id) do
    rpc_dir |> Path.join("res-#{id}.json") |> File.read!() |> Jason.decode!()
  end

  defp next_ordered do
    receive do
      {:ordered, id} -> id
    after
      5_000 -> flunk("expected another ordered rpc request")
    end
  end
end
