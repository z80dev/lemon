defmodule CodingAgent.Tools.ExecuteCodeRpcTest do
  @moduledoc """
  Protocol-level tests for the execute_code RPC pump. No python3 involved: the
  test writes `req-*.json` files directly and reads the `res-*.json` the pump
  writes back, which is exactly what the generated shim does.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.ToolPolicy
  alias CodingAgent.Tools.ExecuteCode.Rpc
  alias LemonCore.ExecApprovalStore
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{ImageContent, TextContent}

  @moduletag :tmp_dir
  @token String.duplicate("a", 43)
  @stale_token String.duplicate("b", 43)

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

      # The published response is owner-only, exactly 0600.
      assert Bitwise.band(File.stat!(Path.join(rpc_dir, "res-1.json")).mode, 0o777) == 0o600

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.calls == 1
      assert stats.errors == 0
      assert stats.denied == 0
      assert stats.bytes == byte_size("hello")
      assert MapSet.to_list(stats.tools_used) == ["echo"]
    end

    test "a planted symlink at the response name is replaced, not followed", %{rpc_dir: rpc_dir} do
      victim =
        Path.join(Path.dirname(rpc_dir), "victim-#{System.unique_integer([:positive])}.txt")

      File.write!(victim, "untouched")
      on_exit(fn -> File.rm(victim) end)
      File.ln_s!(victim, Path.join(rpc_dir, "res-1.json"))

      pump = start_pump(ctx(rpc_dir))

      write_request(rpc_dir, 1, "echo", %{"value" => "hello"})
      # The planted symlink satisfies File.exists?/1 immediately, so wait for
      # the atomic replace itself: a regular file at the response path.
      path = Path.join(rpc_dir, "res-1.json")

      response =
        Enum.find_value(1..500, fn _ ->
          case File.lstat(path) do
            {:ok, %File.Stat{type: :regular}} -> Jason.decode!(File.read!(path))
            _other -> Process.sleep(10) && nil
          end
        end)

      assert %{"id" => 1, "ok" => true, "content" => "hello"} = response

      {:ok, :done, _stats} = finish_pump(pump)

      assert File.read!(victim) == "untouched"
      assert File.lstat!(Path.join(rpc_dir, "res-1.json")).type == :regular
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
      assert Path.wildcard(Path.join(rpc_dir, "req-*.json")) == []
      # Nothing is left half-written: no `.tmp` files and no hidden private
      # reservations survive the handshake.
      assert Path.wildcard(Path.join(rpc_dir, "*.tmp")) == []
      assert rpc_dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, ".")) == []
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

  describe "process_pending/2" do
    test "runs the same authenticated dispatch and accounting path without a task", %{
      rpc_dir: rpc_dir
    } do
      write_request(rpc_dir, 1, "echo", %{"value" => "persistent"})

      stats = Rpc.process_pending(ctx(rpc_dir), Rpc.initial_stats())

      assert %{"id" => 1, "ok" => true, "content" => "persistent"} =
               read_response(rpc_dir, 1)

      assert stats.calls == 1
      assert stats.bytes == byte_size("persistent")
      assert MapSet.to_list(stats.tools_used) == ["echo"]
      refute File.exists?(Path.join(rpc_dir, "req-1.json"))
    end
  end

  test "caps each sweep and continues through higher request ids", %{rpc_dir: rpc_dir} do
    for id <- 1..7, do: write_request(rpc_dir, id, "echo", %{"value" => "request #{id}"})

    ctx = ctx(rpc_dir, max_requests_per_sweep: 3)

    stats = Rpc.process_pending(ctx, Rpc.initial_stats())
    assert stats.calls == 3

    for id <- 1..3, do: assert(%{"id" => ^id, "ok" => true} = read_response(rpc_dir, id))
    for id <- 4..7, do: refute(File.exists?(Path.join(rpc_dir, "res-#{id}.json")))

    stats = Rpc.process_pending(ctx, stats)
    assert stats.calls == 6

    for id <- 4..6, do: assert(%{"id" => ^id, "ok" => true} = read_response(rpc_dir, id))
    refute File.exists?(Path.join(rpc_dir, "res-7.json"))

    stats = Rpc.process_pending(ctx, stats)
    assert stats.calls == 7
    assert %{"id" => 7, "ok" => true} = read_response(rpc_dir, 7)
    assert Path.wildcard(Path.join(rpc_dir, "req-*.json")) == []
  end

  test "caps wrong-token denials before request parsing can reach dispatch", %{rpc_dir: rpc_dir} do
    for id <- 1..7,
        do: write_request(rpc_dir, id, "echo", %{"value" => "ignored"}, @stale_token)

    ctx = ctx(rpc_dir, max_requests_per_sweep: 3)

    stats = Rpc.process_pending(ctx, Rpc.initial_stats())
    assert stats.calls == 0
    assert stats.denied == 3

    for id <- 1..3 do
      assert %{"id" => ^id, "ok" => false, "error" => "rpc authentication failed"} =
               read_response(rpc_dir, id)
    end

    for id <- 4..7, do: refute(File.exists?(Path.join(rpc_dir, "res-#{id}.json")))

    stats = Rpc.process_pending(ctx, stats)
    assert stats.denied == 6
    stats = Rpc.process_pending(ctx, stats)
    assert stats.denied == 7

    assert %{"id" => 7, "ok" => false, "error" => "rpc authentication failed"} =
             read_response(rpc_dir, 7)
  end

  describe "serve/2 rejections" do
    test "malformed json is denied without consuming a call", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir))

      File.write!(Path.join(rpc_dir, "req-1.json"), "{not json")

      assert %{"id" => 1, "ok" => false, "error" => "rpc authentication failed"} =
               await_response(rpc_dir, 1)

      # The pump keeps serving afterwards.
      write_request(rpc_dir, 2, "echo", %{"value" => "still here"})
      assert %{"ok" => true, "content" => "still here"} = await_response(rpc_dir, 2)

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.denied == 1
      assert stats.errors == 0
      assert stats.calls == 1
    end

    test "missing, wrong, stale, and malformed tokens share one bounded denial", %{
      rpc_dir: rpc_dir
    } do
      pump = start_pump(ctx(rpc_dir, max_calls: 1, max_result_bytes: 5))

      payloads = %{
        1 => %{"tool" => "not-available", "params" => %{}},
        2 => %{"token" => "wrong", "tool" => "not-available", "params" => %{}},
        3 => %{"token" => @stale_token, "tool" => "echo", "params" => %{"value" => "no"}},
        4 => %{"token" => nil, "tool" => "echo", "params" => %{}},
        5 => %{"token" => 42, "tool" => "echo", "params" => %{}},
        6 => %{"token" => %{"nested" => true}, "tool" => "echo", "params" => %{}}
      }

      for {id, payload} <- payloads, do: write_payload(rpc_dir, id, payload)

      errors =
        for {id, _payload} <- payloads do
          assert %{"id" => ^id, "ok" => false, "error" => error} =
                   await_response(rpc_dir, id)

          error
        end

      assert Enum.uniq(errors) == ["rpc authentication failed"]
      assert byte_size(hd(errors)) < 64

      # Denied authentication spends neither call nor result budget and never
      # reaches the unavailable-tool lookup.
      write_request(rpc_dir, 7, "echo", %{"value" => "hello"})
      assert %{"ok" => true, "content" => "hello"} = await_response(rpc_dir, 7)

      # Authentication still wins after both budgets are exhausted; a stale
      # caller cannot use cap errors as an oracle or reach tool lookup.
      write_request(rpc_dir, 8, "not-available", %{}, @stale_token)

      assert %{"id" => 8, "ok" => false, "error" => "rpc authentication failed"} =
               await_response(rpc_dir, 8)

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.calls == 1
      assert stats.bytes == 5
      assert stats.denied == map_size(payloads) + 1
      assert stats.errors == 0
      assert MapSet.to_list(stats.tools_used) == ["echo"]
      assert Path.wildcard(Path.join(rpc_dir, "req-*.json")) == []
      assert Path.wildcard(Path.join(rpc_dir, "*.tmp")) == []
    end

    test "an unconfigured server fails closed instead of accepting any request token", %{
      rpc_dir: rpc_dir
    } do
      pump = start_pump(ctx(rpc_dir, token: nil))

      write_request(rpc_dir, 1, "echo", %{"value" => "must not run"})

      assert %{"id" => 1, "ok" => false, "error" => "rpc authentication failed"} =
               await_response(rpc_dir, 1)

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.calls == 0
      assert stats.bytes == 0
      assert stats.denied == 1
      assert MapSet.size(stats.tools_used) == 0
    end

    test "an authenticated request id cannot be replayed after its response is removed", %{
      rpc_dir: rpc_dir
    } do
      pump = start_pump(ctx(rpc_dir))

      write_request(rpc_dir, 1, "order", %{"value" => "first"})
      assert %{"ok" => true, "content" => "first"} = await_response(rpc_dir, 1)
      assert_receive {:ordered, 1}

      File.rm!(Path.join(rpc_dir, "res-1.json"))
      write_request(rpc_dir, 1, "order", %{"value" => "replayed"})

      assert %{"id" => 1, "ok" => false, "error" => "rpc request already processed"} =
               await_response(rpc_dir, 1)

      refute_receive {:ordered, 1}, 50

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.calls == 1
      assert stats.errors == 1
      assert MapSet.to_list(stats.tools_used) == ["order"]
      refute File.exists?(Path.join(rpc_dir, "req-1.json"))
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

    test "the current abort signal reaches the inner tool unchanged", %{rpc_dir: rpc_dir} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)
      pump = start_pump(ctx(rpc_dir, signal: signal))

      write_request(rpc_dir, 1, "signal", %{})
      assert %{"ok" => true, "content" => "aborted"} = await_response(rpc_dir, 1)
      assert_received {:inner_signal, ^signal}

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.calls == 1
      assert MapSet.to_list(stats.tools_used) == ["signal"]
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

  describe "read_text_blocks/2" do
    test "returns blocks in id order regardless of creation order", %{rpc_dir: rpc_dir} do
      write_text_block(rpc_dir, 3, "third")
      write_text_block(rpc_dir, 1, "first")
      write_text_block(rpc_dir, 2, "second")

      assert Rpc.read_text_blocks(rpc_dir, max_text_bytes: 1_000) ==
               ["first", "second", "third"]
    end

    test "a planted symlink at a block name is skipped, not followed", %{rpc_dir: rpc_dir} do
      victim =
        Path.join(Path.dirname(rpc_dir), "text-victim-#{System.unique_integer([:positive])}.txt")

      File.write!(victim, "INJECTED VIA SYMLINK")
      on_exit(fn -> File.rm(victim) end)
      File.ln_s!(victim, Path.join(rpc_dir, "text-1.json"))

      assert Rpc.read_text_blocks(rpc_dir) == []
      assert File.read!(victim) == "INJECTED VIA SYMLINK"
    end

    test "an oversized block file is skipped without crashing", %{
      rpc_dir: rpc_dir
    } do
      write_text_block(rpc_dir, 1, String.duplicate("a", 10_000))

      assert Rpc.read_text_blocks(rpc_dir, max_text_bytes: 16) == []
    end

    test "blocks beyond the cumulative budget are skipped without crashing", %{rpc_dir: rpc_dir} do
      write_text_block(rpc_dir, 1, "0123456789")
      write_text_block(rpc_dir, 2, "0123456789")

      # The budget charges the ENCODED frame (the JSON envelope included),
      # exactly like the shim: one frame fits, the second does not.
      one_frame = Path.join(rpc_dir, "text-1.json") |> File.read!() |> byte_size()

      assert Rpc.read_text_blocks(rpc_dir, max_text_bytes: one_frame) == ["0123456789"]
    end
  end

  describe "notify collection" do
    test "notifications are consumed and forwarded in order through on_update", %{
      rpc_dir: rpc_dir
    } do
      test = self()

      write_notify(rpc_dir, 2, "second")
      write_notify(rpc_dir, 1, "first")
      write_request(rpc_dir, 1, "echo", %{"value" => "alongside"})

      stats =
        Rpc.process_pending(
          ctx(rpc_dir,
            on_update: fn %AgentToolResult{} = partial ->
              send(test, {:notify, hd(partial.content).text})
            end
          ),
          Rpc.initial_stats()
        )

      first = receive(do: ({:notify, m} -> m))
      second = receive(do: ({:notify, m} -> m))
      assert {first, second} == {"notify: first", "notify: second"}

      # Requests are unaffected by the side channel.
      assert stats.calls == 1
      assert Path.wildcard(Path.join(rpc_dir, "notify-*.json")) == []
    end

    test "a nil on_update consumes and drops notifications", %{rpc_dir: rpc_dir} do
      for n <- 1..3, do: write_notify(rpc_dir, n, "ignored-#{n}")

      stats = Rpc.process_pending(ctx(rpc_dir), Rpc.initial_stats())

      assert stats.calls == 0
      assert Path.wildcard(Path.join(rpc_dir, "notify-*.json")) == []
    end

    test "forwarding stops at 64 messages; the rest are still consumed", %{rpc_dir: rpc_dir} do
      test = self()

      for n <- 1..70, do: write_notify(rpc_dir, n, "flood-#{n}")

      ctx =
        ctx(rpc_dir,
          on_update: fn %AgentToolResult{} = partial ->
            send(test, {:notify, hd(partial.content).text})
          end
        )

      stats = Rpc.process_pending(ctx, Rpc.initial_stats())

      assert stats.notify_forwarded == 64
      assert collect_notifications(0) == 64
      assert Path.wildcard(Path.join(rpc_dir, "notify-*.json")) == []
    end

    test "the 64-message cap spans sweeps, not resets per sweep", %{rpc_dir: rpc_dir} do
      test = self()

      ctx =
        ctx(rpc_dir,
          on_update: fn %AgentToolResult{} = partial ->
            send(test, {:notify, hd(partial.content).text})
          end
        )

      # The first sweep forwards 40; without per-run accounting a second
      # sweep would reset the counter and forward 30 more.
      for n <- 1..40, do: write_notify(rpc_dir, n, "wave one #{n}")
      stats = Rpc.process_pending(ctx, Rpc.initial_stats())
      assert stats.notify_forwarded == 40

      for n <- 41..70, do: write_notify(rpc_dir, n, "wave two #{n}")
      stats = Rpc.process_pending(ctx, stats)

      assert stats.notify_forwarded == 64
      assert collect_notifications(0) == 64
      assert Path.wildcard(Path.join(rpc_dir, "notify-*.json")) == []
    end

    test "malformed frames are consumed without forwarding or spending the cap", %{
      rpc_dir: rpc_dir
    } do
      test = self()

      # Sixty-four malformed frames carrying the lowest ids: under
      # charge-then-forward accounting they would have spent the whole
      # per-run cap before the one honest message arrived.
      victim = Path.join(Path.dirname(rpc_dir), "notify-victim.txt")
      File.write!(victim, "symlinked")
      on_exit(fn -> File.rm(victim) end)

      malformed = %{
        1 => "{not json",
        2 => Jason.encode!(%{"wrong" => "shape"}),
        3 => Jason.encode!(%{"msg" => 123})
      }

      for {n, body} <- malformed, do: File.write!(Path.join(rpc_dir, "notify-#{n}.json"), body)

      File.write!(
        Path.join(rpc_dir, "notify-4.json"),
        Jason.encode!(%{"msg" => String.duplicate("x", 70_000)})
      )

      File.ln_s!(victim, Path.join(rpc_dir, "notify-5.json"))

      for n <- 10..72, do: File.write!(Path.join(rpc_dir, "notify-#{n}.json"), "not json at all")
      write_notify(rpc_dir, 100, "still delivered")

      ctx =
        ctx(rpc_dir,
          on_update: fn %AgentToolResult{} = partial ->
            send(test, {:notify, hd(partial.content).text})
          end
        )

      stats = Rpc.process_pending(ctx, Rpc.initial_stats())

      assert_received {:notify, "notify: still delivered"}
      assert stats.notify_forwarded == 1
      assert collect_notifications(0) == 0
      assert Path.wildcard(Path.join(rpc_dir, "notify-*.json")) == []
    end

    test "a notify flushed immediately before the script exits is forwarded by the final drain",
         %{rpc_dir: rpc_dir} do
      test = self()

      ctx =
        ctx(rpc_dir,
          on_update: fn %AgentToolResult{} = partial ->
            send(test, {:notify, hd(partial.content).text})
          end
        )

      # The frame lands after the last poll window and the script exits
      # immediately: only the terminal notification drain can forward it.
      pump =
        start_pump(ctx, fn ->
          Process.sleep(20)
          write_notify(rpc_dir, 1, "last words")
          :done
        end)

      {:ok, :done, stats} = finish_pump(pump)

      assert_received {:notify, "notify: last words"}
      assert stats.notify_forwarded == 1
    end

    test "a forwarded message is capped at 4 KiB", %{rpc_dir: rpc_dir} do
      test = self()

      write_notify(rpc_dir, 1, String.duplicate("x", 10_000))

      ctx =
        ctx(rpc_dir,
          on_update: fn %AgentToolResult{} = partial ->
            send(test, {:notify, hd(partial.content).text})
          end
        )

      _stats = Rpc.process_pending(ctx, Rpc.initial_stats())

      assert_received {:notify, message}
      assert byte_size(message) == byte_size("notify: ") + 4_096
    end
  end

  describe "parallel dispatch" do
    test "claimed requests run concurrently up to max_parallel_rpc", %{rpc_dir: rpc_dir} do
      test = self()

      blockers = %{
        "block" =>
          stub_tool("block", fn params ->
            send(test, {:inflight, params["value"], self()})
            receive(do: (:release -> text(params["value"])))
          end)
      }

      for id <- 1..3, do: write_request(rpc_dir, id, "block", %{"value" => "v#{id}"})

      pump =
        Task.async(fn ->
          Rpc.process_pending(ctx(rpc_dir, tools: blockers), Rpc.initial_stats())
        end)

      # All three are in flight together, before any is released: dispatch
      # genuinely overlapped (a serial pump would sit in the first blocker's
      # receive until its own deadline).
      pids =
        for _ <- 1..3,
            do: assert_receive({:inflight, _value, blocker}, 2_000) |> then(&elem(&1, 2))

      for pid <- pids, do: send(pid, :release)

      stats = Task.await(pump, 5_000)
      assert stats.calls == 3

      for id <- 1..3 do
        expected = "v" <> Integer.to_string(id)
        assert %{"ok" => true, "content" => ^expected} = read_response(rpc_dir, id)
      end
    end

    test "concurrency is bounded: the third request waits for a wave slot", %{rpc_dir: rpc_dir} do
      test = self()

      blockers = %{
        "block" =>
          stub_tool("block", fn params ->
            send(test, {:inflight, params["value"], self()})
            receive(do: (:release -> text(params["value"])))
          end)
      }

      for id <- 1..3, do: write_request(rpc_dir, id, "block", %{"value" => "v#{id}"})

      pump =
        Task.async(fn ->
          Rpc.process_pending(
            ctx(rpc_dir, tools: blockers, max_parallel_rpc: 2),
            Rpc.initial_stats()
          )
        end)

      first = assert_receive({:inflight, _value, blocker}, 2_000) |> then(&elem(&1, 2))
      second = assert_receive({:inflight, _value, blocker}, 2_000) |> then(&elem(&1, 2))
      refute_receive {:inflight, _, _}, 100

      # Dispatch is wave-based: the whole first wave must complete before the
      # third request claims the freed slots.
      send(first, :release)
      send(second, :release)
      third = assert_receive({:inflight, _value, blocker}, 2_000) |> then(&elem(&1, 2))
      send(third, :release)

      stats = Task.await(pump, 5_000)
      assert stats.calls == 3
    end

    test "a replayed id under parallel load is still refused exactly once", %{rpc_dir: rpc_dir} do
      tools = %{"order" => stub_tool("order", fn params -> text(params["value"] || "") end)}
      ctx = ctx(rpc_dir, tools: tools)

      for id <- 1..4, do: write_request(rpc_dir, id, "order", %{"value" => "first-wave-#{id}"})
      stats = Rpc.process_pending(ctx, Rpc.initial_stats())
      assert stats.calls == 4

      # The shim consumes responses, so remove them to expose the replay path.
      for id <- 1..4, do: File.rm!(Path.join(rpc_dir, "res-#{id}.json"))

      # After the parallel wave, the same ids are replays: answered in
      # writing, never re-dispatched, and the call budget is untouched.
      for id <- 1..4, do: write_request(rpc_dir, id, "order", %{"value" => "replay-#{id}"})
      stats = Rpc.process_pending(ctx, stats)

      assert stats.calls == 4
      assert stats.errors == 4

      for id <- 1..4 do
        assert %{"id" => ^id, "ok" => false, "error" => "rpc request already processed"} =
                 read_response(rpc_dir, id)
      end
    end
  end

  describe "sweep death and recovery" do
    @describetag :capture_log

    test "a killed sweep's claimed ids are answered by the successor sweep", %{rpc_dir: rpc_dir} do
      test = self()

      blockers = %{
        "block" =>
          stub_tool("block", fn params ->
            send(test, {:inflight, params["value"], self()})
            receive(do: (:release -> text(params["value"])))
          end)
      }

      ctx = ctx(rpc_dir, tools: blockers)

      for id <- 1..3, do: write_request(rpc_dir, id, "block", %{"value" => "v#{id}"})

      sweep = Task.async(fn -> Rpc.process_pending(ctx, Rpc.initial_stats()) end)

      # All three are claimed and in flight; the markers prove the claims
      # were durable before the kill.
      for _ <- 1..3, do: assert_receive({:inflight, _value, _pid}, 2_000)

      assert Enum.sort(Path.wildcard(Path.join(rpc_dir, "req-*.claim"))) ==
               Enum.map(1..3, &Path.join(rpc_dir, "req-#{&1}.claim"))

      # A real, untrappable kill — not a raised exception. The task is
      # unlinked first so the kill does not propagate into this test.
      Process.unlink(sweep.pid)
      monitor = Process.monitor(sweep.pid)
      Process.exit(sweep.pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :killed}, 2_000

      # Linked dispatch tasks died with the sweep; nobody completed.
      refute_receive {:inflight, _value, _pid}, 50

      # The successor pays the dead sweep's debts: every claimed id is
      # answered in writing — never re-dispatched.
      stats = Rpc.process_pending(ctx, Rpc.initial_stats())

      for id <- 1..3 do
        assert %{"id" => ^id, "ok" => false, "error" => "rpc dispatch interrupted"} =
                 read_response(rpc_dir, id)
      end

      assert Path.wildcard(Path.join(rpc_dir, "req-*.claim")) == []
      refute_received {:inflight, _value, _pid}

      # The reservations and replay memory the dead sweep would have kept
      # are reconstructed in the successor's stats.
      assert stats.calls == 3
      assert stats.errors == 3

      for id <- 1..3 do
        File.rm!(Path.join(rpc_dir, "res-#{id}.json"))
        write_request(rpc_dir, id, "block", %{"value" => "replay-#{id}"})
      end

      stats = Rpc.process_pending(ctx, stats)

      for id <- 1..3 do
        assert %{"id" => ^id, "ok" => false, "error" => "rpc request already processed"} =
                 read_response(rpc_dir, id)
      end

      assert stats.calls == 3
      # The three replay refusals add their own errors on top.
      assert stats.errors == 6
      refute_received {:inflight, _value, _pid}
    end

    test "an in-flight claim marker next to a published response restores the real accounting",
         %{
           rpc_dir: rpc_dir
         } do
      write_request(rpc_dir, 1, "echo", %{"value" => "served"})

      # The response was published but the sweep died before retiring the
      # marker: recovery must keep the answer and restore the REAL
      # accounting — the ok status, the result bytes, and the tool usage
      # (the marker is the renamed request, so it still names the tool) —
      # instead of inventing an error the script never saw.
      File.rename!(Path.join(rpc_dir, "req-1.json"), Path.join(rpc_dir, "req-1.claim"))

      File.write!(
        Path.join(rpc_dir, "res-1.json"),
        Jason.encode!(%{"id" => 1, "ok" => true, "content" => "served"})
      )

      stats = Rpc.recover_orphaned_claims(rpc_dir, Rpc.initial_stats())

      assert %{"id" => 1, "ok" => true, "content" => "served"} = read_response(rpc_dir, 1)
      assert Path.wildcard(Path.join(rpc_dir, "req-*.claim")) == []
      assert stats.calls == 1
      assert stats.errors == 0
      assert stats.bytes == byte_size("served")
      assert MapSet.to_list(stats.tools_used) == ["echo"]
      assert MapSet.to_list(stats.seen_ids) == [1]
    end

    test "a planted directory at a claim marker name is ignored, never charged", %{
      rpc_dir: rpc_dir
    } do
      File.mkdir_p!(Path.join(rpc_dir, "req-1.claim"))
      File.mkdir_p!(Path.join(rpc_dir, "req-not-a-number.claim"))

      stats = Rpc.recover_orphaned_claims(rpc_dir, Rpc.initial_stats())

      # Directories are not markers: nothing is answered, nothing is
      # charged, nothing is written — and no sweep re-examines them as debt.
      assert stats.calls == 0
      assert stats.errors == 0
      assert MapSet.to_list(stats.seen_ids) == []
      refute File.exists?(Path.join(rpc_dir, "res-1.json"))
      assert File.dir?(Path.join(rpc_dir, "req-1.claim"))
      assert File.dir?(Path.join(rpc_dir, "req-not-a-number.claim"))
    end

    test "a planted directory at the marker name answers the id and never dispatches", %{
      rpc_dir: rpc_dir
    } do
      File.mkdir_p!(Path.join(rpc_dir, "req-1.claim"))
      write_request(rpc_dir, 1, "order", %{"value" => "no dispatch", "id" => 1})

      stats = Rpc.process_pending(ctx(rpc_dir), Rpc.initial_stats())

      # Publication is the dispatch gate: the tool never ran, the call slot
      # the claim already reserved is spent, and the id is answered.
      assert %{"id" => 1, "ok" => false, "error" => "rpc dispatch could not be marked in-flight"} =
               read_response(rpc_dir, 1)

      refute_receive {:ordered, 1}, 25
      assert stats.calls == 1
      assert stats.errors == 1
      assert File.dir?(Path.join(rpc_dir, "req-1.claim"))
      refute File.exists?(Path.join(rpc_dir, "req-1.json"))
    end

    test "a symlinked request becomes a non-marker and is answered, never dispatched", %{
      rpc_dir: rpc_dir
    } do
      real =
        Path.join(Path.dirname(rpc_dir), "real-req-#{System.unique_integer([:positive])}.json")

      File.write!(
        real,
        Jason.encode!(%{
          "id" => 1,
          "token" => @token,
          "tool" => "order",
          "params" => %{"value" => "no dispatch", "id" => 1}
        })
      )

      on_exit(fn -> File.rm(real) end)
      File.ln_s!(real, Path.join(rpc_dir, "req-1.json"))

      stats = Rpc.process_pending(ctx(rpc_dir), Rpc.initial_stats())

      # The rename publishes a symlink, not a regular file: recovery would
      # never trust it, so dispatch is refused and the id answered.
      assert %{"id" => 1, "ok" => false, "error" => "rpc dispatch could not be marked in-flight"} =
               read_response(rpc_dir, 1)

      refute_receive {:ordered, 1}, 25
      assert stats.calls == 1
      assert stats.errors == 1
      assert Path.wildcard(Path.join(rpc_dir, "req-*")) == []
    end

    test "a marker whose deletion fails is never re-charged by a later sweep", %{
      rpc_dir: rpc_dir
    } do
      write_request(rpc_dir, 1, "echo", %{"value" => "served"})

      File.rename!(Path.join(rpc_dir, "req-1.json"), Path.join(rpc_dir, "req-1.claim"))

      File.write!(
        Path.join(rpc_dir, "res-1.json"),
        Jason.encode!(%{"id" => 1, "ok" => true, "content" => "served"})
      )

      # Without write permission on the rpc dir the marker cannot be
      # deleted: recovery still charges once (reads work), the marker stays.
      File.chmod!(rpc_dir, 0o500)
      stats = Rpc.recover_orphaned_claims(rpc_dir, Rpc.initial_stats())
      File.chmod!(rpc_dir, 0o700)

      assert stats.calls == 1
      assert stats.bytes == byte_size("served")
      assert stats.errors == 0
      assert File.exists?(Path.join(rpc_dir, "req-1.claim"))

      # The next sweep sees the surviving marker, but the id is already in
      # the replay memory: cleanup only — the budget is never re-charged.
      stats = Rpc.recover_orphaned_claims(rpc_dir, stats)

      assert stats.calls == 1
      assert stats.bytes == byte_size("served")
      assert stats.errors == 0
      assert Path.wildcard(Path.join(rpc_dir, "req-*.claim")) == []
      assert %{"ok" => true, "content" => "served"} = read_response(rpc_dir, 1)
    end

    test "killing a sweep cancels its pending approval so no late approval can install policy",
         %{rpc_dir: rpc_dir} do
      run_id = "rpc-f2-#{System.unique_integer([:positive])}"

      ctx =
        ctx(rpc_dir,
          tool_policy: ToolPolicy.custom(require_approval: ["echo"]),
          approval_context: %{run_id: run_id, session_key: "f2-session"}
        )

      write_request(rpc_dir, 1, "echo", %{"value" => "gated"})

      sweep = Task.async(fn -> Rpc.process_pending(ctx, Rpc.initial_stats()) end)

      # The dispatch task blocked on a real ExecApprovals prompt.
      {approval_id, _pending} = await_pending_approval(run_id)

      Process.unlink(sweep.pid)
      monitor = Process.monitor(sweep.pid)
      Process.exit(sweep.pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :killed}, 2_000

      # The claim's watcher cancels the orphaned prompt: the pending record
      # disappears, so a late approval LOSES the atomic transition and can
      # install no policy.
      assert :ok = await_no_pending(run_id)

      assert {:error, :not_pending} =
               LemonCore.ExecApprovals.resolve(approval_id, :approve_global)

      assert ExecApprovalStore.list_global_policies()
             |> Enum.reject(fn {{tool, _hash}, _value} -> tool != "echo" end)
             |> Enum.empty?()
    end

    test "a prompt registered after the sweep died cannot be orphaned", %{rpc_dir: rpc_dir} do
      run_id = "rpc-watcher-#{System.unique_integer([:positive])}"
      test = self()

      ctx =
        ctx(rpc_dir,
          tool_policy: ToolPolicy.custom(require_approval: ["echo"]),
          approval_context: %{
            run_id: run_id,
            session_key: "watcher-session",
            # Seam: the watcher reports each cancel attempt so the test can
            # wait for its first (sweep-death) cancel before releasing the
            # registration — pinning the interleaving instead of racing it.
            approval_watcher_on_cancel: fn -> send(test, :watcher_cancelled) end,
            approval_request_fun: fn params ->
              # Deliberately subvert teardown by outliving the sweep (the
              # watcher cannot rely on the task dying with it), then
              # register the prompt AFTER the watcher's first cancel has
              # already found nothing — the exact register-after-cancel
              # interleaving the watcher must close.
              Process.flag(:trap_exit, true)
              send(test, {:approval_path, params[:approval_id], self()})

              receive(do: (:register -> :ok))

              ExecApprovalStore.put_pending(params[:approval_id], %{
                "id" => params[:approval_id],
                "tool" => "echo",
                "run_id" => run_id
              })

              send(test, :registered)
              receive(do: (:finish -> :ok))
            end
          }
        )

      write_request(rpc_dir, 1, "echo", %{"value" => "gated"})

      sweep = Task.async(fn -> Rpc.process_pending(ctx, Rpc.initial_stats()) end)

      {approval_id, task_pid} =
        receive do
          {:approval_path, id, pid} -> {id, pid}
        after
          5_000 -> flunk("the approval path never ran")
        end

      # Kill the sweep first: the watcher's first cancel finds nothing,
      # because the registration is still parked in the receive above.
      Process.unlink(sweep.pid)
      monitor = Process.monitor(sweep.pid)
      Process.exit(sweep.pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, _pid, :killed}, 2_000
      # Pin the interleaving: wait for the watcher's first cancel (the one
      # triggered by the sweep's death) to complete BEFORE the registration
      # is released. Without this, that cancel races the registration; when
      # it lands after `:registered` it deletes the pending record and the
      # intermediate assert below flakes.
      assert_receive :watcher_cancelled, 2_000

      # The trapped dispatch task survives and registers the prompt late...
      send(task_pid, :register)
      assert_receive :registered, 2_000
      assert ExecApprovalStore.get_pending(approval_id) != nil

      # ...and only then dies. The watcher has stayed alive for exactly this
      # death; its second cancel must remove the late-registered prompt.
      Process.exit(task_pid, :kill)
      assert :ok = await_pending_gone(approval_id)

      assert {:error, :not_pending} =
               LemonCore.ExecApprovals.resolve(approval_id, :approve_global)

      assert ExecApprovalStore.list_global_policies()
             |> Enum.reject(fn {{tool, _hash}, _value} -> tool != "echo" end)
             |> Enum.empty?()
    end

    test "the claim ledger is fed at reservation time and before the marker is published", %{
      rpc_dir: rpc_dir
    } do
      # The reservation entry must fire before the request's fate branch —
      # fed BEFORE the call slot is spent, so no kill can spend a call the
      # ledger cannot prove — and the `:claimed` refinement must fire
      # BEFORE the rename: that is what makes the ledger cover every spent
      # slot (never re-spendable after a fault) and a superset of the
      # published claims (a sweep killed after the send has already
      # delivered its entry, whatever the script then does to the marker).
      test = self()

      ctx =
        ctx(rpc_dir,
          on_claim: fn id, kind, tool ->
            marker = Path.join(rpc_dir, "req-#{id}.claim")
            send(test, {:claim_ledger_entry, id, kind, tool, File.exists?(marker)})
          end
        )

      write_request(rpc_dir, 1, "echo", %{"value" => "served"})
      stats = Rpc.process_pending(ctx, Rpc.initial_stats())

      assert_received {:claim_ledger_entry, 1, :reserved, nil, false}
      assert_received {:claim_ledger_entry, 1, :claimed, "echo", false}
      assert %{"id" => 1, "ok" => true, "content" => "served"} = read_response(rpc_dir, 1)
      assert stats.calls == 1
    end

    test "a sweep killed between the reservation feed and the spend charges exactly once",
         %{rpc_dir: rpc_dir} do
      # The feed-to-spend kill window: the reservation entry is enqueued BEFORE
      # the sweep-local spend, so a brutal kill between the two leaves
      # "entry exists, stats never mutated" — the shape settlement
      # reconstructs — instead of losing the spend AND its evidence. The
      # on_claim hook runs in the sweep process itself; killing self()
      # right after the feed pins the window deterministically, and the
      # test plays the ledger owner the RpcServer normally plays.
      test = self()

      ctx =
        ctx(rpc_dir,
          on_claim: fn id, :reserved, nil ->
            send(test, {:reserved_fed, id})
            Process.exit(self(), :kill)
          end
        )

      write_request(rpc_dir, 1, "echo", %{"value" => "never dispatched"})

      # Spawned unlinked — never Task.async, whose link could deliver the
      # child's untrappable self-kill into this test process before an
      # unlink could race to remove it. The monitor is the sole, orderly
      # death observer.
      sweep_pid = spawn(fn -> Rpc.process_pending(ctx, Rpc.initial_stats()) end)
      monitor_ref = Process.monitor(sweep_pid)

      assert_receive {:reserved_fed, 1}, 2_000

      # The kill is untrappable and lands at the sweep's next instruction
      # boundary; the monitor's DOWN is the deterministic death proof.
      assert_receive {:DOWN, ^monitor_ref, :process, ^sweep_pid, :killed}, 2_000

      # Dead between the feed and the fate branch: nothing was answered,
      # nothing was marked, and the request file survives unconsumed.
      refute File.exists?(Path.join(rpc_dir, "res-1.json"))
      assert Path.wildcard(Path.join(rpc_dir, "req-*.claim")) == []
      assert File.exists?(Path.join(rpc_dir, "req-1.json"))

      # Settlement with the fed entry (what settle_failed_sweep does): one
      # exact call charge, one conservative error, the replay memory kept.
      stats =
        Rpc.recover_orphaned_claims(rpc_dir, Rpc.initial_stats(), %{
          1 => %{kind: :reserved, tool: nil}
        })

      assert stats.calls == 1
      assert stats.errors == 1
      assert MapSet.to_list(stats.seen_ids) == [1]

      # The leftover request is answered by replay refusal — never
      # re-dispatched, never re-charged.
      stats = Rpc.process_pending(ctx(rpc_dir), stats)

      assert %{"id" => 1, "ok" => false, "error" => "rpc request already processed"} =
               read_response(rpc_dir, 1)

      assert stats.calls == 1
    end

    test "a ledger entry whose marker and response were destroyed still answers, charges once, and flags the loss",
         %{rpc_dir: rpc_dir} do
      # The hostile script deleted both halves of the on-disk evidence after
      # the claim; the host-side ledger still proves the claim happened.
      stats =
        Rpc.recover_orphaned_claims(rpc_dir, Rpc.initial_stats(), %{
          1 => %{kind: :claimed, tool: "webfetch"}
        })

      assert %{"id" => 1, "ok" => false, "error" => "rpc dispatch interrupted"} =
               read_response(rpc_dir, 1)

      assert stats.calls == 1
      assert stats.errors == 1
      assert MapSet.to_list(stats.seen_ids) == [1]
      # Destroyed evidence means a lower bound: the tool may have executed
      # with side effects nothing can account for anymore.
      assert stats.accounting_loss == true

      # And the reconstructed replay memory refuses a replayed id even after
      # the script also consumed the recovery answer — no re-dispatch.
      File.rm!(Path.join(rpc_dir, "res-1.json"))
      write_request(rpc_dir, 1, "echo", %{"value" => "replay"})

      stats = Rpc.process_pending(ctx(rpc_dir), stats)

      assert %{"id" => 1, "ok" => false, "error" => "rpc request already processed"} =
               read_response(rpc_dir, 1)

      assert stats.calls == 1
      assert stats.errors == 2
      refute_receive {:ordered, 1}, 25
    end

    test "a ledger entry beside a surviving response restores the real accounting exactly",
         %{rpc_dir: rpc_dir} do
      # The script deleted the marker but the dead sweep's published answer
      # survives: response + ledger tool name restore the REAL accounting —
      # no loss flag, because nothing is actually missing.
      File.write!(
        Path.join(rpc_dir, "res-1.json"),
        Jason.encode!(%{"id" => 1, "ok" => true, "content" => "served"})
      )

      stats =
        Rpc.recover_orphaned_claims(rpc_dir, Rpc.initial_stats(), %{
          1 => %{kind: :claimed, tool: "webfetch"}
        })

      assert stats.calls == 1
      assert stats.errors == 0
      assert stats.bytes == byte_size("served")
      assert MapSet.to_list(stats.seen_ids) == [1]
      refute Map.get(stats, :accounting_loss)
      assert %{"id" => 1, "ok" => true, "content" => "served"} = read_response(rpc_dir, 1)
    end

    test "the ledger's tool identity beats a forged marker body on recovery", %{
      rpc_dir: rpc_dir
    } do
      # The marker body is script-writable, so a hostile script overwrote a
      # real webfetch claim marker with a body naming a harmless tool — and
      # the dead sweep's successful response survived. When BOTH halves name
      # the id, the host-owned ledger wins; the marker body is fallback
      # evidence only for ids the ledger never saw.
      File.write!(
        Path.join(rpc_dir, "res-1.json"),
        Jason.encode!(%{"id" => 1, "ok" => true, "content" => "served"})
      )

      File.write!(
        Path.join(rpc_dir, "req-1.claim"),
        Jason.encode!(%{"id" => 1, "tool" => "read", "params" => %{"path" => "/etc/hosts"}})
      )

      stats =
        Rpc.recover_orphaned_claims(rpc_dir, Rpc.initial_stats(), %{
          1 => %{kind: :claimed, tool: "webfetch"}
        })

      assert stats.calls == 1
      assert stats.errors == 0
      assert stats.bytes == byte_size("served")
      assert MapSet.to_list(stats.tools_used) == ["webfetch"]
      assert MapSet.to_list(stats.seen_ids) == [1]
      refute Map.get(stats, :accounting_loss)
      # The forged marker itself is retired like any paid debt.
      assert Path.wildcard(Path.join(rpc_dir, "req-*.claim")) == []
    end

    test "a marker-covered id is never double-charged through the ledger", %{rpc_dir: rpc_dir} do
      write_request(rpc_dir, 1, "echo", %{"value" => "served"})
      File.rename!(Path.join(rpc_dir, "req-1.json"), Path.join(rpc_dir, "req-1.claim"))

      stats =
        Rpc.recover_orphaned_claims(rpc_dir, Rpc.initial_stats(), %{
          1 => %{kind: :claimed, tool: "echo"}
        })

      assert stats.calls == 1
      assert stats.errors == 1
      assert MapSet.to_list(stats.seen_ids) == [1]
      assert Path.wildcard(Path.join(rpc_dir, "req-*.claim")) == []
    end

    test "a denied reservation entry reconstructs exactly and never rewrites its answer", %{
      rpc_dir: rpc_dir
    } do
      # The dead sweep answered the policy denial in writing before dying;
      # settlement re-applies the stats it lost — one call, one denial, the
      # replay memory — and never overwrites the surviving answer (the
      # sweep's own wording, with its exact policy reason, beats the
      # reconstruction).
      File.write!(
        Path.join(rpc_dir, "res-1.json"),
        Jason.encode!(%{"id" => 1, "ok" => false, "error" => "Tool 'webfetch' is in deny list"})
      )

      stats =
        Rpc.recover_orphaned_claims(rpc_dir, Rpc.initial_stats(), %{
          1 => %{kind: :denied, tool: "webfetch"}
        })

      assert stats.calls == 1
      assert stats.denied == 1
      assert stats.errors == 0
      assert stats.bytes == 0
      assert MapSet.to_list(stats.tools_used) == []
      assert MapSet.to_list(stats.seen_ids) == [1]
      # Exact reconstruction is not a loss: nothing is missing.
      refute Map.get(stats, :accounting_loss)

      assert %{"id" => 1, "ok" => false, "error" => "Tool 'webfetch' is in deny list"} =
               read_response(rpc_dir, 1)
    end

    test "a denied reservation with no surviving answer writes the denial", %{rpc_dir: rpc_dir} do
      # The sweep fed the :denied entry and died before its answer write. A
      # successor sweep would replay-refuse the leftover request, but on
      # abort there is no successor and the teardown deletes the files — so
      # recovery itself must write the kind's error and release the caller.
      # The exact policy reason died with the sweep; the tool-named
      # fallback wording is the reconstruction.
      write_request(rpc_dir, 1, "webfetch", %{"url" => "https://example.com"})

      stats =
        Rpc.recover_orphaned_claims(rpc_dir, Rpc.initial_stats(), %{
          1 => %{kind: :denied, tool: "webfetch"}
        })

      assert %{"id" => 1, "ok" => false, "error" => "tool 'webfetch' denied by policy"} =
               read_response(rpc_dir, 1)

      assert stats.calls == 1
      assert stats.denied == 1
      assert stats.errors == 0
      assert MapSet.to_list(stats.seen_ids) == [1]
      refute Map.get(stats, :accounting_loss)
    end

    test "invalid and unknown-tool reservation entries reconstruct as charged, answered errors",
         %{rpc_dir: rpc_dir} do
      # The sweep fed each disposition entry and died before its answer
      # write. On abort nobody else would answer these ids, so recovery
      # writes the kind's own error — exact wording — and charges exactly
      # one call, one error, and the replay memory per id.
      stats =
        Rpc.recover_orphaned_claims(rpc_dir, Rpc.initial_stats(), %{
          1 => %{kind: :invalid, tool: nil},
          2 => %{kind: :unknown_tool, tool: "nosuch"}
        })

      assert stats.calls == 2
      assert stats.errors == 2
      assert stats.denied == 0
      assert MapSet.to_list(stats.seen_ids) == [1, 2]
      refute Map.get(stats, :accounting_loss)

      assert %{"id" => 1, "ok" => false, "error" => "invalid rpc request"} =
               read_response(rpc_dir, 1)

      assert %{
               "id" => 2,
               "ok" => false,
               "error" => "tool 'nosuch' is not available inside execute_code scripts"
             } =
               read_response(rpc_dir, 2)
    end

    test "a bare reserved entry charges its call slot and a surviving request is replay-refused",
         %{rpc_dir: rpc_dir} do
      # The sweep died between feeding the reservation entry and taking the
      # fate branch: the entry still carries the spend, and the request file
      # the fault left behind must be answered by replay refusal — never
      # re-charged, never dispatched. A bare entry never writes a response
      # of its own: it does not say the sweep answered anything.
      write_request(rpc_dir, 1, "echo", %{"value" => "straggler"})

      stats =
        Rpc.recover_orphaned_claims(rpc_dir, Rpc.initial_stats(), %{
          1 => %{kind: :reserved, tool: nil}
        })

      assert stats.calls == 1
      assert stats.errors == 1
      assert MapSet.to_list(stats.seen_ids) == [1]

      stats = Rpc.process_pending(ctx(rpc_dir), stats)

      assert %{"id" => 1, "ok" => false, "error" => "rpc request already processed"} =
               read_response(rpc_dir, 1)

      assert stats.calls == 1
      refute_receive {:ordered, 1}, 25
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp ctx(rpc_dir, overrides \\ []) do
    %{
      tools: Keyword.get(overrides, :tools, stub_tools()),
      tool_policy: Keyword.get(overrides, :tool_policy),
      approval_context: Keyword.get(overrides, :approval_context),
      max_calls: Keyword.get(overrides, :max_calls, 100),
      max_result_bytes: Keyword.get(overrides, :max_result_bytes, 5_242_880),
      max_requests_per_sweep: Keyword.get(overrides, :max_requests_per_sweep, 100),
      max_parallel_rpc: Keyword.get(overrides, :max_parallel_rpc, 4),
      on_update: Keyword.get(overrides, :on_update),
      on_claim: Keyword.get(overrides, :on_claim),
      signal: Keyword.get(overrides, :signal),
      rpc_dir: rpc_dir,
      token: Keyword.get(overrides, :token, @token),
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
      "signal" => %AgentTool{
        name: "signal",
        description: "stub",
        label: "signal",
        parameters: %{"type" => "object", "properties" => %{}},
        execute: fn _id, _params, signal, _on_update ->
          send(test, {:inner_signal, signal})
          text(if AbortSignal.aborted?(signal), do: "aborted", else: "running")
        end
      },
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

  defp await_pending_gone(approval_id, attempts \\ 400) do
    if ExecApprovalStore.get_pending(approval_id) != nil do
      if attempts > 0 do
        Process.sleep(5)
        await_pending_gone(approval_id, attempts - 1)
      else
        flunk("pending approval #{approval_id} was never cancelled")
      end
    else
      :ok
    end
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

  defp write_request(rpc_dir, id, tool, params, token \\ @token) do
    params = Map.put_new(params, "id", id)

    write_payload(rpc_dir, id, %{
      "id" => id,
      "token" => token,
      "tool" => tool,
      "params" => params
    })
  end

  defp write_payload(rpc_dir, id, payload) do
    tmp = Path.join(rpc_dir, "req-#{id}.json.tmp")
    File.write!(tmp, Jason.encode!(payload))
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

  defp write_text_block(rpc_dir, n, body) do
    write_atomically(rpc_dir, "text-#{n}.json", %{"n" => n, "text" => body})
  end

  defp write_notify(rpc_dir, n, msg) do
    write_atomically(rpc_dir, "notify-#{n}.json", %{"n" => n, "msg" => msg})
  end

  defp write_atomically(rpc_dir, name, payload) do
    tmp = Path.join(rpc_dir, name <> ".tmp")
    File.write!(tmp, Jason.encode!(payload))
    File.rename!(tmp, Path.join(rpc_dir, name))
  end

  defp collect_notifications(seen) do
    receive do
      {:notify, _message} -> collect_notifications(seen + 1)
    after
      0 -> seen
    end
  end

  # Polls the real approval store until this run's prompt exists.
  defp await_pending_approval(run_id, attempts \\ 400) do
    pending =
      ExecApprovalStore.list_pending()
      |> Enum.find(fn {_id, pending} -> pending.run_id == run_id end)

    case pending do
      {id, map} ->
        {id, map}

      nil when attempts > 0 ->
        Process.sleep(5)
        await_pending_approval(run_id, attempts - 1)

      nil ->
        flunk("no pending approval appeared for run #{run_id}")
    end
  end

  defp await_no_pending(run_id, attempts \\ 400) do
    pending? =
      ExecApprovalStore.list_pending()
      |> Enum.any?(fn {_id, pending} -> pending.run_id == run_id end)

    if pending? do
      if attempts > 0 do
        Process.sleep(5)
        await_no_pending(run_id, attempts - 1)
      else
        flunk("pending approval for run #{run_id} was never cancelled")
      end
    else
      :ok
    end
  end
end
