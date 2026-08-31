defmodule CodingAgent.Tools.ExecuteCodeRpcServerTest do
  @moduledoc """
  Lifecycle tests for the per-cell `RpcServer`, driven through a faithful
  fake of the shared pump contract (no python3, no real policy/approval
  machinery): the test writes `req-*.json` files directly and reads the
  `res-*.json` files back, exactly like the generated shim does.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.ExecuteCode.{Rpc, RpcServer}
  alias LemonCore.ExecApprovalStore
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  # 256-bit hex token, the shape every cell gets.
  @token String.duplicate("ab", 32)

  defmodule FakeRpc do
    @moduledoc """
    Faithful stand-in for the shared `Rpc` contract: same stats shape, same
    file protocol, same accounting decisions (constant-time token comparison
    is the real pump's concern; plain equality suffices here).
    """

    alias LemonAgent.Types.AgentToolResult
    alias LemonAi.Types.TextContent

    def initial_stats do
      %{
        calls: 0,
        denied: 0,
        errors: 0,
        bytes: 0,
        tools_used: MapSet.new(),
        seen_ids: MapSet.new(),
        notify_forwarded: 0
      }
    end

    def process_pending(ctx, stats) do
      ctx.rpc_dir
      |> pending_ids()
      |> Enum.reduce(stats, fn id, acc -> process_request(id, ctx, acc) end)
    end

    # Faithful marker model: answer every unanswered in-flight claim and
    # reconstruct its call reservation, like the real pump. The `claimed`
    # ledger covers ids whose marker the "script" deleted: the real pump's
    # host-side half of the claim evidence.
    def recover_orphaned_claims(rpc_dir, stats, claimed \\ %{}) do
      stats
      |> recover_markers(rpc_dir)
      |> recover_ledger(rpc_dir, claimed)
    end

    defp recover_markers(stats, rpc_dir) do
      rpc_dir
      |> Path.join("req-*.claim")
      |> Path.wildcard()
      |> Enum.reduce(stats, fn marker, acc ->
        case Integer.parse(Path.basename(marker, ".claim") |> String.replace_prefix("req-", "")) do
          {id, ""} ->
            unless File.exists?(response_path(rpc_dir, id)) do
              respond_error(rpc_dir, id, "rpc dispatch interrupted")
            end

            File.rm(marker)

            acc
            |> Map.update!(:calls, &(&1 + 1))
            |> Map.update!(:errors, &(&1 + 1))
            |> Map.update!(:seen_ids, &MapSet.put(&1, id))

          :error ->
            File.rm(marker)
            acc
        end
      end)
    end

    defp recover_ledger(stats, rpc_dir, claimed) do
      claimed
      |> Enum.sort()
      |> Enum.reduce(stats, fn {id, _tool}, acc ->
        if MapSet.member?(acc.seen_ids, id) do
          acc
        else
          unless File.exists?(response_path(rpc_dir, id)) do
            respond_error(rpc_dir, id, "rpc dispatch interrupted")
          end

          acc
          |> Map.update!(:calls, &(&1 + 1))
          |> Map.update!(:errors, &(&1 + 1))
          |> Map.update!(:seen_ids, &MapSet.put(&1, id))
          |> Map.put(:accounting_loss, true)
        end
      end)
    end

    def drain_notifications(ctx, stats) do
      forwarded = Map.get(stats, :notify_forwarded, 0)

      frames =
        ctx.rpc_dir
        |> Path.join("notify-*.json")
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          case Integer.parse(Path.basename(path, ".json") |> String.replace_prefix("notify-", "")) do
            {n, ""} -> [{n, path}]
            _ -> []
          end
        end)
        |> Enum.sort()

      forwarded =
        Enum.reduce(frames, forwarded, fn {_n, path}, acc ->
          message =
            with {:ok, body} <- File.read(path),
                 {:ok, %{"msg" => msg}} when is_binary(msg) <- Jason.decode(body) do
              msg
            else
              _ -> nil
            end

          File.rm(path)

          if is_binary(message) and acc < 64, do: acc + 1, else: acc
        end)

      Map.put(stats, :notify_forwarded, forwarded)
    end

    def process_request(id, ctx, stats) do
      cond do
        MapSet.member?(stats.seen_ids, id) ->
          respond_error(ctx, id, "duplicate rpc request id")
          %{stats | errors: stats.errors + 1}

        stats.calls >= ctx.max_calls ->
          respond_error(ctx, id, "rpc call limit exceeded (max #{ctx.max_calls} calls per cell)")
          %{stats | errors: stats.errors + 1}

        true ->
          case read_request(ctx.rpc_dir, id) do
            {:ok, %{"token" => token} = request} when token == ctx.token ->
              stats = %{stats | calls: stats.calls + 1, seen_ids: MapSet.put(stats.seen_ids, id)}
              dispatch(id, request, ctx, stats)

            _other ->
              respond_error(ctx, id, "rpc authentication failed")
              %{stats | denied: stats.denied + 1, seen_ids: MapSet.put(stats.seen_ids, id)}
          end
      end
    end

    defp dispatch(id, request, ctx, stats) do
      tool_name = Map.get(request, "tool")
      params = Map.get(request, "params") || %{}

      case Map.fetch(ctx.tools, tool_name || "") do
        :error ->
          respond_error(
            ctx,
            id,
            "tool '#{tool_name}' is not available inside execute_code scripts"
          )

          %{stats | errors: stats.errors + 1}

        {:ok, tool} ->
          execute(id, tool, tool_name, params, ctx, stats)
      end
    end

    defp execute(id, tool, tool_name, params, ctx, stats) do
      result =
        try do
          tool.execute.("exec_code_rpc_#{id}", params, ctx.signal, nil)
        rescue
          error -> {:error, Exception.message(error)}
        end

      case result do
        %AgentToolResult{} = tool_result ->
          account(id, tool_name, content_text(tool_result.content), ctx, stats)

        {:error, message} ->
          respond_error(ctx, id, message)
          %{stats | errors: stats.errors + 1}
      end
    end

    defp account(id, tool_name, content, ctx, stats) do
      remaining = ctx.max_result_bytes - stats.bytes

      if byte_size(content) > remaining do
        respond_error(ctx, id, "rpc result byte budget exceeded")
        %{stats | errors: stats.errors + 1}
      else
        respond_ok(ctx, id, content)

        %{
          stats
          | bytes: stats.bytes + byte_size(content),
            tools_used: MapSet.put(stats.tools_used, tool_name)
        }
      end
    end

    defp content_text(blocks) when is_list(blocks) do
      blocks
      |> Enum.map(fn
        %TextContent{text: text} when is_binary(text) -> text
        _ -> "[non-text content omitted]"
      end)
      |> Enum.join("\n")
    end

    defp content_text(_), do: ""

    defp read_request(rpc_dir, id) do
      with {:ok, body} <- File.read(request_path(rpc_dir, id)),
           {:ok, decoded} <- Jason.decode(body),
           %{"tool" => tool} when is_binary(tool) <- decoded do
        {:ok, decoded}
      else
        _ -> :error
      end
    end

    defp pending_ids(rpc_dir) do
      rpc_dir
      |> Path.join("req-*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        case Integer.parse(path |> Path.basename(".json") |> String.replace_prefix("req-", "")) do
          {id, ""} -> [id]
          _ -> []
        end
      end)
      |> Enum.sort()
      |> Enum.reject(&File.exists?(response_path(rpc_dir, &1)))
    end

    defp respond_ok(ctx, id, content) do
      write_response(ctx.rpc_dir, id, %{"id" => id, "ok" => true, "content" => content})
    end

    defp respond_error(ctx, id, message) do
      write_response(ctx.rpc_dir, id, %{"id" => id, "ok" => false, "error" => message})
    end

    defp write_response(rpc_dir, id, payload) do
      final = response_path(rpc_dir, id)
      tmp = final <> ".tmp"
      File.write!(tmp, Jason.encode!(payload))
      File.rename!(tmp, final)
      :ok
    end

    def request_path(rpc_dir, id), do: Path.join(rpc_dir, "req-#{id}.json")
    def response_path(rpc_dir, id), do: Path.join(rpc_dir, "res-#{id}.json")
  end

  defmodule FlakyRpc do
    @moduledoc """
    `FakeRpc` that raises while a `.raise-sweep` marker file exists in the
    rpc dir, to prove a broken sweep is contained by the server.
    """

    def initial_stats, do: FakeRpc.initial_stats()

    def recover_orphaned_claims(rpc_dir, stats, _claimed),
      do: FakeRpc.recover_orphaned_claims(rpc_dir, stats)

    def drain_notifications(ctx, stats), do: FakeRpc.drain_notifications(ctx, stats)

    def process_pending(ctx, stats) do
      if File.exists?(Path.join(ctx.rpc_dir, ".raise-sweep")) do
        File.touch(Path.join(ctx.rpc_dir, ".raise-sweep-hit"))
        raise "sweep exploded"
      end

      FakeRpc.process_pending(ctx, stats)
    end
  end

  defmodule DrainCountingRpc do
    @moduledoc """
    `FakeRpc` whose `drain_notifications/2` reports the stats it was called
    with and the stats it returns, so a test can prove the stop path keeps
    the drain's accounting in the server state.
    """

    def initial_stats, do: FakeRpc.initial_stats()

    def recover_orphaned_claims(rpc_dir, stats, _claimed),
      do: FakeRpc.recover_orphaned_claims(rpc_dir, stats)

    def process_pending(ctx, stats), do: FakeRpc.process_pending(ctx, stats)

    def drain_notifications(ctx, stats) do
      test_pid = Map.get(ctx, :test_pid)
      send(test_pid, {:drain_called, %{notify_forwarded: stats.notify_forwarded}})
      drained = FakeRpc.drain_notifications(ctx, stats)
      send(test_pid, {:drain_returned, %{notify_forwarded: drained.notify_forwarded}})
      drained
    end
  end

  defmodule BlockingApprovalRpc do
    @moduledoc false

    def initial_stats, do: FakeRpc.initial_stats()

    def recover_orphaned_claims(rpc_dir, stats, _claimed),
      do: FakeRpc.recover_orphaned_claims(rpc_dir, stats)

    def drain_notifications(ctx, stats), do: FakeRpc.drain_notifications(ctx, stats)

    def process_pending(%{test_pid: test_pid}, stats) do
      send(test_pid, {:approval_pending, self()})

      receive do
        :approve ->
          send(test_pid, :post_approval_tool_executed)
          stats
      end
    end
  end

  setup %{tmp_dir: tmp_dir} do
    rpc_dir = Path.join(tmp_dir, "rpc")
    File.mkdir_p!(rpc_dir)
    {:ok, rpc_dir: rpc_dir}
  end

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

  describe "abort and claim recovery" do
    @tag :capture_log
    test "abort mid-dispatch answers the claimed ids and preserves their accounting", %{
      rpc_dir: rpc_dir
    } do
      ctx = %{ctx(rpc_dir) | tools: blocking_tools(self())}
      {:ok, server} = start_server(ctx, rpc: Rpc, poll_interval_ms: 5)

      for id <- 1..2, do: write_request(rpc_dir, id, "block", %{})

      for id <- 1..2 do
        call_id = "exec_code_rpc_#{id}"
        assert_receive {:blocking_dispatch, ^call_id, _sweep_pid}, 2_000
      end

      assert Enum.sort(Path.wildcard(Path.join(rpc_dir, "req-*.claim"))) ==
               Enum.map(1..2, &Path.join(rpc_dir, "req-#{&1}.claim"))

      # The cancel path kills the sweep; its claimed ids must still end
      # answered — in writing, never by running their blocked tools.
      :ok = RpcServer.abort(server)

      for id <- 1..2 do
        assert %{"id" => ^id, "ok" => false, "error" => "rpc dispatch interrupted"} =
                 read_response(rpc_dir, id)
      end

      assert Path.wildcard(Path.join(rpc_dir, "req-*.claim")) == []
      refute_receive {:blocking_dispatch, _, _}, 25

      stats = RpcServer.stats(server)
      assert stats.calls == 2
      assert stats.errors == 2

      # The sweep was genuinely killed mid-flight: its stats are a lower
      # bound and the loss is flagged so trust classification falls back to
      # untrusted.
      assert stats.accounting_loss == true

      assert :ok = RpcServer.stop(server)
    end

    @tag :capture_log
    test "abort preserves a just-completed sweep's accounting", %{rpc_dir: rpc_dir} do
      ctx = %{ctx(rpc_dir) | tools: blocking_tools(self())}
      {:ok, server} = start_server(ctx, rpc: Rpc, poll_interval_ms: 5)

      write_request(rpc_dir, 1, "block", %{})

      assert_receive {:blocking_dispatch, "exec_code_rpc_1", sweep_pid}, 2_000
      send(sweep_pid, :release)

      # The sweep has published its answer and is only a heartbeat from
      # returning its stats; aborting now races the cancel against that
      # return. Whichever way the race lands, the completed call's
      # accounting must survive — never revert to the stale snapshot.
      assert %{"id" => 1, "ok" => true, "content" => "released"} = await_response(rpc_dir, 1)
      :ok = RpcServer.abort(server)

      stats = RpcServer.stats(server)
      assert stats.calls == 1
      assert stats.errors == 0
      assert stats.bytes == byte_size("released")
      assert MapSet.to_list(stats.tools_used) == ["block"]
      # A completed sweep lost nothing: no loss flag.
      refute Map.get(stats, :accounting_loss)

      assert :ok = RpcServer.stop(server)
    end

    @tag :capture_log
    test "abort cancels a pending ExecApprovals prompt from a killed sweep", %{rpc_dir: rpc_dir} do
      run_id = "server-f2-#{System.unique_integer([:positive])}"

      ctx =
        ctx(rpc_dir,
          tool_policy: CodingAgent.ToolPolicy.custom(require_approval: ["echo"]),
          approval_context: %{run_id: run_id, session_key: "server-f2"}
        )

      {:ok, server} = start_server(ctx, rpc: Rpc, poll_interval_ms: 5)

      write_request(rpc_dir, 1, "echo", %{"value" => "gated"})

      # The dispatch task is blocked on a real approval prompt.
      {approval_id, _pending} = await_pending_approval(run_id)

      :ok = RpcServer.abort(server)

      # The claim's watcher cancelled the orphaned prompt; a late approval
      # loses the atomic transition and installs no policy.
      assert :ok = await_no_pending(run_id)

      assert {:error, :not_pending} =
               LemonCore.ExecApprovals.resolve(approval_id, :approve_global)

      assert ExecApprovalStore.list_global_policies()
             |> Enum.reject(fn {{tool, _hash}, _value} -> tool != "echo" end)
             |> Enum.empty?()

      assert %{"id" => 1, "ok" => false, "error" => "rpc dispatch interrupted"} =
               read_response(rpc_dir, 1)

      assert :ok = RpcServer.stop(server)
    end

    @tag :capture_log
    test "abort answers a claim whose marker the script deleted after the gate", %{
      rpc_dir: rpc_dir
    } do
      ctx = %{ctx(rpc_dir) | tools: blocking_tools(self())}
      {:ok, server} = start_server(ctx, rpc: Rpc, poll_interval_ms: 5)

      write_request(rpc_dir, 1, "block", %{})

      assert_receive {:blocking_dispatch, "exec_code_rpc_1", _sweep_pid}, 2_000

      # The hostile script removes its own in-flight marker after the
      # publication gate passed: on-disk evidence gone.
      File.rm!(Path.join(rpc_dir, "req-1.claim"))
      assert Path.wildcard(Path.join(rpc_dir, "req-*.claim")) == []

      :ok = RpcServer.abort(server)

      # The host-side claim ledger still proves the claim: answered in
      # writing, charged once, and the loss flagged (the tool ran under a
      # sweep that was killed — its accounting is a lower bound).
      assert %{"id" => 1, "ok" => false, "error" => "rpc dispatch interrupted"} =
               read_response(rpc_dir, 1)

      stats = RpcServer.stats(server)
      assert stats.calls == 1
      assert stats.errors == 1
      assert stats.accounting_loss == true

      assert :ok = RpcServer.stop(server)
    end
  end

  describe "abnormal sweep death" do
    @tag :capture_log
    test "a sweep killed after publishing a response flags the loss and recovers immediately",
         %{rpc_dir: rpc_dir} do
      # Waves of one: request 1 (echo) is answered and its marker retired
      # before the sweep blocks awaiting request 2 (block). Killing the
      # sweep exactly there means its stats — which account request 1 — die
      # with it, and no marker for 1 survives.
      ctx = %{
        ctx(rpc_dir, max_parallel_rpc: 1)
        | tools: Map.merge(stub_tools(), blocking_tools(self()))
      }

      {:ok, server} = start_server(ctx, rpc: Rpc, poll_interval_ms: 5)

      write_request(rpc_dir, 1, "echo", %{"value" => "one"})
      write_request(rpc_dir, 2, "block", %{})

      assert %{"id" => 1, "ok" => true, "content" => "one"} = await_response(rpc_dir, 1)
      assert_receive {:blocking_dispatch, "exec_code_rpc_2", _task_pid}, 2_000

      sweep_pid = await_sweep_pid(server)
      Process.exit(sweep_pid, :kill)

      # The abnormal :DOWN is treated as accounting loss, and recovery runs
      # immediately: the still-marked claim 2 is answered in writing, and
      # the destroyed-evidence claim 1 is reconstructed from its response
      # plus the ledger.
      stats = await_flagged_stats(server)
      assert stats.accounting_loss == true
      assert stats.calls == 2
      assert stats.errors == 1
      assert stats.bytes == byte_size("one")
      assert MapSet.to_list(stats.tools_used) == ["echo"]

      assert %{"id" => 2, "ok" => false, "error" => "rpc dispatch interrupted"} =
               read_response(rpc_dir, 2)

      assert %{"id" => 1, "ok" => true, "content" => "one"} = read_response(rpc_dir, 1)

      # The server recovered and keeps serving: a successor sweep answers a
      # fresh request, and a replay of the dead sweep's answered id is
      # refused — never re-dispatched.
      write_request(rpc_dir, 3, "echo", %{"value" => "after death"})
      assert %{"id" => 3, "ok" => true, "content" => "after death"} = await_response(rpc_dir, 3)

      File.rm!(Path.join(rpc_dir, "res-1.json"))
      write_request(rpc_dir, 1, "echo", %{"value" => "replay"})

      assert %{"id" => 1, "ok" => false, "error" => "rpc request already processed"} =
               await_response(rpc_dir, 1)

      assert :ok = RpcServer.stop(server)
    end
  end

  describe "start_link/2" do
    test "rejects an invalid ctx without starting a process", %{rpc_dir: rpc_dir} do
      assert {:error, {:invalid_ctx, :rpc_dir}} = RpcServer.start_link(%{})

      assert {:error, {:invalid_ctx, :token}} =
               RpcServer.start_link(ctx(rpc_dir, token: ""), rpc: FakeRpc)

      assert {:error, {:invalid_ctx, :max_calls}} =
               RpcServer.start_link(ctx(rpc_dir, max_calls: 0), rpc: FakeRpc)

      for invalid_cap <- [0, -1, "3"] do
        assert {:error, {:invalid_ctx, :max_requests_per_sweep}} =
                 RpcServer.start_link(
                   ctx(rpc_dir, max_requests_per_sweep: invalid_cap),
                   rpc: FakeRpc
                 )
      end

      for invalid_parallel <- [0, -1, "4"] do
        assert {:error, {:invalid_ctx, :max_parallel_rpc}} =
                 RpcServer.start_link(
                   ctx(rpc_dir, max_parallel_rpc: invalid_parallel),
                   rpc: FakeRpc
                 )
      end

      assert {:error, {:invalid_ctx, :poll_interval_ms}} =
               RpcServer.start_link(ctx(rpc_dir), rpc: FakeRpc, poll_interval_ms: 0)
    end

    test "starts with zeroed stats", %{rpc_dir: rpc_dir} do
      {:ok, server} = start_server(ctx(rpc_dir))

      stats = RpcServer.stats(server)
      assert stats.calls == 0
      assert stats.denied == 0
      assert stats.errors == 0
      assert stats.bytes == 0
      assert MapSet.to_list(stats.tools_used) == []

      assert :ok = RpcServer.stop(server)
    end

    test "enforces the optional per-sweep cap through the real pump", %{rpc_dir: rpc_dir} do
      ctx = %{ctx(rpc_dir, max_requests_per_sweep: 3) | tools: blocking_tools(self())}

      {:ok, server} = start_server(ctx, rpc: Rpc, poll_interval_ms: 50)

      for id <- 1..4, do: write_request(rpc_dir, id, "block", %{})

      for id <- 1..3 do
        call_id = "exec_code_rpc_#{id}"
        assert_receive {:blocking_dispatch, ^call_id, sweep_pid}, 2_000
        send(sweep_pid, :release)
        assert %{"id" => ^id, "ok" => true} = await_response(rpc_dir, id)
      end

      refute_receive {:blocking_dispatch, "exec_code_rpc_4", _sweep_pid}, 25
      refute File.exists?(Path.join(rpc_dir, "res-4.json"))
      assert :ok = RpcServer.stop(server)
    end
  end

  describe "polling" do
    test "serves authenticated requests and accumulates stats across polls", %{
      rpc_dir: rpc_dir
    } do
      {:ok, server} = start_server(ctx(rpc_dir))

      write_request(rpc_dir, 1, "echo", %{"value" => "hello"})
      write_request(rpc_dir, 2, "echo", %{"value" => "world"})

      assert %{"id" => 1, "ok" => true, "content" => "hello"} = await_response(rpc_dir, 1)
      assert %{"id" => 2, "ok" => true, "content" => "world"} = await_response(rpc_dir, 2)
      assert_receive {:dispatched, "exec_code_rpc_1"}
      assert_receive {:dispatched, "exec_code_rpc_2"}

      stats = RpcServer.stats(server)
      assert stats.calls == 2
      assert stats.denied == 0
      assert stats.errors == 0
      assert stats.bytes == byte_size("hello") + byte_size("world")
      assert MapSet.to_list(stats.tools_used) == ["echo"]

      assert :ok = RpcServer.stop(server)
    end

    test "a notify frame that lands just before stop is still forwarded", %{
      rpc_dir: rpc_dir
    } do
      test = self()

      {:ok, server} =
        start_server(
          ctx(rpc_dir,
            on_update: fn %AgentToolResult{} = partial ->
              send(test, {:notify, hd(partial.content).text})
            end
          ),
          rpc: Rpc,
          poll_interval_ms: 1_000
        )

      # With polls a second apart, the frame written now can only be
      # forwarded by the stop path's final notification drain — whose
      # returned stats become the server's final state (see terminate/2).
      tmp = Path.join(rpc_dir, "notify-1.json.tmp")
      File.write!(tmp, Jason.encode!(%{"n" => 1, "msg" => "at the bitter end"}))
      File.rename!(tmp, Path.join(rpc_dir, "notify-1.json"))

      assert :ok = RpcServer.stop(server)

      assert_received {:notify, "notify: at the bitter end"}
      assert File.ls(rpc_dir) == {:ok, []}
    end

    test "the stop path keeps the drained notification accounting", %{rpc_dir: rpc_dir} do
      test = self()

      {:ok, server} =
        start_server(
          ctx(rpc_dir,
            test_pid: test,
            on_update: fn %AgentToolResult{} = partial ->
              send(test, {:notify, hd(partial.content).text})
            end
          ),
          rpc: DrainCountingRpc,
          poll_interval_ms: 1_000
        )

      tmp = Path.join(rpc_dir, "notify-7.json.tmp")
      File.write!(tmp, Jason.encode!(%{"n" => 7, "msg" => "drained at stop"}))
      File.rename!(tmp, Path.join(rpc_dir, "notify-7.json"))

      # The drain runs inside terminate/2 and its return value is kept in
      # the server state — observable here as the stats the drain reports
      # back to the test after being called with the pre-drain stats.
      assert :ok = RpcServer.stop(server)

      assert_received {:drain_called, %{notify_forwarded: 0}}
      assert_received {:drain_returned, %{notify_forwarded: 1}}
    end

    test "drain_and_stats forwards and counts stop-time notifications through the public path",
         %{rpc_dir: rpc_dir} do
      test = self()

      {:ok, server} =
        start_server(
          ctx(rpc_dir,
            on_update: fn %AgentToolResult{} = partial ->
              send(test, {:notify, hd(partial.content).text})
            end
          ),
          rpc: Rpc,
          poll_interval_ms: 1_000
        )

      # With polls a second apart, the frame written now can only be
      # forwarded by the teardown drain — which must be observable in the
      # stats the CALLER receives, not only inside the dying terminate/2.
      tmp = Path.join(rpc_dir, "notify-9.json.tmp")
      File.write!(tmp, Jason.encode!(%{"n" => 9, "msg" => "last gasp"}))
      File.rename!(tmp, Path.join(rpc_dir, "notify-9.json"))

      stats = RpcServer.drain_and_stats(server)

      assert stats.notify_forwarded == 1
      assert_received {:notify, "notify: last gasp"}
      # The count persists in the server's stats too.
      assert RpcServer.stats(server).notify_forwarded == 1

      assert :ok = RpcServer.stop(server)
    end

    test "wrong or missing tokens are denied and never dispatched", %{rpc_dir: rpc_dir} do
      {:ok, server} = start_server(ctx(rpc_dir))

      write_request(rpc_dir, 1, "echo", %{"value" => "nope"}, String.duplicate("cd", 32))
      write_request(rpc_dir, 2, "echo", %{"value" => "nope"}, nil)

      assert %{"ok" => false, "error" => "rpc authentication failed"} =
               await_response(rpc_dir, 1)

      assert %{"ok" => false, "error" => "rpc authentication failed"} =
               await_response(rpc_dir, 2)

      refute_receive {:dispatched, _}, 100

      stats = RpcServer.stats(server)
      assert stats.calls == 0
      assert stats.denied == 2
      assert stats.bytes == 0

      assert :ok = RpcServer.stop(server)
    end

    test "a request id replayed after its response was consumed is refused", %{
      rpc_dir: rpc_dir
    } do
      {:ok, server} = start_server(ctx(rpc_dir))

      write_request(rpc_dir, 1, "echo", %{"value" => "first"})
      assert %{"ok" => true, "content" => "first"} = await_response(rpc_dir, 1)
      assert_receive {:dispatched, "exec_code_rpc_1"}

      # The shim consumed the response; an adversarial script replays the id.
      File.rm!(Path.join(rpc_dir, "res-1.json"))
      write_request(rpc_dir, 1, "echo", %{"value" => "replay"})

      assert %{"ok" => false, "error" => "duplicate rpc request id"} =
               await_response(rpc_dir, 1)

      refute_receive {:dispatched, _}, 100

      stats = RpcServer.stats(server)
      assert stats.calls == 1
      assert stats.errors == 1

      assert :ok = RpcServer.stop(server)
    end

    test "a request with a pre-existing response is never reprocessed", %{rpc_dir: rpc_dir} do
      File.write!(
        Path.join(rpc_dir, "res-2.json"),
        Jason.encode!(%{"id" => 2, "ok" => true, "content" => "preexisting"})
      )

      {:ok, server} = start_server(ctx(rpc_dir))
      write_request(rpc_dir, 2, "echo", %{"value" => "fresh"})

      # Several polls pass; the pre-existing answer must stand untouched.
      Process.sleep(50)
      assert %{"content" => "preexisting"} = read_response(rpc_dir, 2)
      assert RpcServer.stats(server).calls == 0
      refute_receive {:dispatched, _}, 10

      assert :ok = RpcServer.stop(server)
    end
  end

  describe "notify side channel" do
    test "the real pump forwards notify frames through the server's ctx on_update", %{
      rpc_dir: rpc_dir
    } do
      test = self()

      {:ok, server} =
        start_server(
          ctx(rpc_dir,
            on_update: fn %AgentToolResult{} = partial ->
              send(test, {:notify, hd(partial.content).text})
            end
          ),
          rpc: Rpc
        )

      for n <- 1..2 do
        tmp = Path.join(rpc_dir, "notify-#{n}.json.tmp")
        File.write!(tmp, Jason.encode!(%{"n" => n, "msg" => "progress #{n}"}))
        File.rename!(tmp, Path.join(rpc_dir, "notify-#{n}.json"))
      end

      first = receive(do: ({:notify, m} -> m))
      second = receive(do: ({:notify, m} -> m))
      assert {first, second} == {"notify: progress 1", "notify: progress 2"}

      assert :ok = RpcServer.stop(server)
      assert File.ls(rpc_dir) == {:ok, []}
    end
  end

  describe "abort and caller death" do
    test "abort retains final stats until explicit cleanup", %{rpc_dir: rpc_dir} do
      signal = AbortSignal.new()
      {:ok, server} = start_server(ctx(rpc_dir, signal: signal))

      write_request(rpc_dir, 1, "echo", %{"value" => "before abort"})
      assert %{"ok" => true, "content" => "before abort"} = await_response(rpc_dir, 1)
      assert_receive {:dispatched, "exec_code_rpc_1"}

      File.write!(Path.join(rpc_dir, "junk.txt"), "x")
      :ok = AbortSignal.abort(signal)
      Process.sleep(25)

      assert Process.alive?(server)
      assert RpcServer.stats(server).calls == 1
      assert File.exists?(Path.join(rpc_dir, "junk.txt"))

      assert :ok = RpcServer.stop(server)
      assert File.ls(rpc_dir) == {:ok, []}
    end

    test "aborting a timed-out cell cancels pending approval before it can dispatch", %{
      rpc_dir: rpc_dir
    } do
      signal = AbortSignal.new()

      {:ok, server} =
        start_server(ctx(rpc_dir, signal: signal, test_pid: self()), rpc: BlockingApprovalRpc)

      assert_receive {:approval_pending, approval_task}
      :ok = AbortSignal.abort(signal)
      assert :ok = RpcServer.abort(server)
      assert Process.alive?(server)

      send(approval_task, :approve)
      refute_receive :post_approval_tool_executed, 100
      assert RpcServer.stats(server).calls == 0

      assert :ok = RpcServer.stop(server)
    end

    test "stops when the monitored caller dies", %{rpc_dir: rpc_dir} do
      caller =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      {:ok, server} = start_server(ctx(rpc_dir), caller: caller)
      monitor = Process.monitor(server)

      Process.exit(caller, :boom)
      assert_receive {:DOWN, ^monitor, :process, ^server, :normal}, 2_000
    end

    test "stops when the linked starter exits", %{rpc_dir: rpc_dir} do
      test = self()

      starter =
        spawn(fn ->
          {:ok, server} = start_server(ctx(rpc_dir))
          send(test, {:server, server})
        end)

      server =
        receive do
          {:server, pid} -> pid
        after
          2_000 -> flunk("server never started")
        end

      monitor = Process.monitor(server)
      # The starter is linked to the server and has already exited normally.
      refute Process.alive?(starter)
      assert_receive {:DOWN, ^monitor, :process, ^server, _reason}, 2_000
    end
  end

  describe "failure isolation" do
    @tag :capture_log
    test "a raising sweep is contained and the server resumes serving", %{rpc_dir: rpc_dir} do
      File.touch(Path.join(rpc_dir, ".raise-sweep"))
      {:ok, server} = start_server(ctx(rpc_dir), rpc: FlakyRpc)

      await_file(Path.join(rpc_dir, ".raise-sweep-hit"))
      assert Process.alive?(server)
      assert RpcServer.stats(server).calls == 0

      File.rm!(Path.join(rpc_dir, ".raise-sweep"))
      write_request(rpc_dir, 1, "echo", %{"value" => "after the storm"})

      assert %{"ok" => true, "content" => "after the storm"} = await_response(rpc_dir, 1)
      assert RpcServer.stats(server).calls == 1

      assert :ok = RpcServer.stop(server)
    end
  end

  describe "stop/1 and cleanup" do
    test "stop is synchronous and idempotent and removes every dropped file", %{
      rpc_dir: rpc_dir
    } do
      {:ok, server} = start_server(ctx(rpc_dir))

      write_request(rpc_dir, 1, "echo", %{"value" => "served"})
      assert %{"ok" => true} = await_response(rpc_dir, 1)

      # Protocol leftovers and arbitrary junk the cell dropped in the dir.
      File.write!(Path.join(rpc_dir, "req-9.json.tmp"), "{}")
      File.write!(Path.join(rpc_dir, ".hidden"), "x")
      File.write!(Path.join(rpc_dir, "junk.txt"), "x")

      assert :ok = RpcServer.stop(server)
      refute Process.alive?(server)
      assert File.ls(rpc_dir) == {:ok, []}

      assert :ok = RpcServer.stop(server)
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
      max_requests_per_sweep: Keyword.get(overrides, :max_requests_per_sweep, 100),
      max_parallel_rpc: Keyword.get(overrides, :max_parallel_rpc),
      on_update: Keyword.get(overrides, :on_update),
      signal: Keyword.get(overrides, :signal),
      rpc_dir: rpc_dir,
      token: Keyword.get(overrides, :token, @token),
      poll_interval_ms: 5,
      test_pid: Keyword.get(overrides, :test_pid)
    }
  end

  defp start_server(ctx, opts \\ []) do
    RpcServer.start_link(ctx, Keyword.merge([rpc: FakeRpc, poll_interval_ms: 5], opts))
  end

  defp stub_tools do
    test = self()

    %{
      "echo" => %AgentTool{
        name: "echo",
        description: "stub",
        label: "echo",
        parameters: %{"type" => "object", "properties" => %{}},
        execute: fn call_id, params, _signal, _on_update ->
          send(test, {:dispatched, call_id})

          %AgentToolResult{
            content: [%TextContent{text: params["value"] || ""}]
          }
        end
      }
    }
  end

  defp blocking_tools(test) do
    %{
      "block" => %AgentTool{
        name: "block",
        description: "block",
        label: "block",
        parameters: %{"type" => "object", "properties" => %{}},
        execute: fn call_id, _params, _signal, _on_update ->
          send(test, {:blocking_dispatch, call_id, self()})

          receive do
            :release -> %AgentToolResult{content: [%TextContent{text: "released"}]}
          end
        end
      }
    }
  end

  # Writes the request exactly like the generated shim does: `.tmp` file
  # atomically renamed into place, carrying the current cell token.
  defp write_request(rpc_dir, id, tool, params, token \\ @token) do
    payload = %{"id" => id, "tool" => tool, "params" => params}
    payload = if token, do: Map.put(payload, "token", token), else: payload

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

  defp await_file(path, attempts \\ 400) do
    cond do
      File.exists?(path) ->
        :ok

      attempts <= 0 ->
        flunk("timed out waiting for #{path}")

      true ->
        Process.sleep(5)
        await_file(path, attempts - 1)
    end
  end

  # The sweep task's pid while a dispatch is holding it open. The struct is
  # not opaque to the test: the server owns sweep_task as a %Task{}.
  defp await_sweep_pid(server, attempts \\ 400) do
    case :sys.get_state(server) do
      %{sweep_task: %Task{pid: pid}} when is_pid(pid) ->
        pid

      _none when attempts > 0 ->
        Process.sleep(5)
        await_sweep_pid(server, attempts - 1)

      _none ->
        flunk("no sweep task was running")
    end
  end

  # Polls until the server's stats carry the accounting-loss flag, so a test
  # never races the :DOWN handling.
  defp await_flagged_stats(server, attempts \\ 400) do
    stats = RpcServer.stats(server)

    if Map.get(stats, :accounting_loss) == true or attempts <= 0 do
      stats
    else
      Process.sleep(5)
      await_flagged_stats(server, attempts - 1)
    end
  end
end
