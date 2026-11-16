defmodule LemonCore.RpcClientTest do
  use ExUnit.Case, async: true
  alias LemonCore.Rpc.Client

  for framing <- [LemonCore.Rpc.JsonLines, LemonCore.Rpc.ContentLength] do
    @framing framing
    describe inspect(framing) do
      setup do
        owner = self()

        peer =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        {:ok, client} =
          Client.start_link(
            owner: owner,
            peer: peer,
            framing: @framing,
            send: fn bytes ->
              send(owner, {:wire, bytes})
              :ok
            end
          )

        on_exit(fn ->
          monitor = Process.monitor(client)
          Process.exit(client, :shutdown)
          assert_receive {:DOWN, ^monitor, :process, ^client, _reason}
          send(peer, :stop)
        end)

        %{client: client, peer: peer}
      end

      test "request deadline expires and late response is ignored", %{client: client} do
        tag = make_ref()
        assert :ok = Client.dispatch(client, "deadline", %{"id" => "deadline"}, {self(), tag}, 0)
        assert_receive {:wire, _}
        assert_receive {:rpc_finished, "deadline", :timeout}
        assert_receive {^tag, {:error, :timeout}}
        assert 0 == Client.pending_count(client)
        assert {:error, :not_found} = Client.complete(client, "deadline", :late)
        refute_receive {^tag, :late}, 0
      end

      test "transport teardown can take an unfinished frame exactly once", %{client: client} do
        Client.feed(client, "C")
        assert "C" == Client.take_buffer(client)
        assert "" == Client.take_buffer(client)
      end

      test "caller death releases request without waiting for deadline", %{client: client} do
        parent = self()

        caller =
          spawn(fn ->
            :ok =
              Client.dispatch(
                client,
                "caller",
                %{"id" => "caller"},
                {parent, make_ref()},
                :infinity,
                self()
              )

            send(parent, :registered)

            receive do
              :stop -> :ok
            end
          end)

        assert_receive :registered
        assert 1 == Client.pending_count(client)
        Process.exit(caller, :kill)
        assert_receive {:rpc_finished, "caller", :caller_down}
        assert 0 == Client.pending_count(client)
      end

      test "peer exit fails every waiting caller", %{client: client, peer: peer} do
        a = make_ref()
        b = make_ref()
        assert :ok = Client.dispatch(client, 1, %{"id" => 1}, {self(), a}, :infinity)
        assert :ok = Client.dispatch(client, 2, %{"id" => 2}, {self(), b}, :infinity)
        monitor = Process.monitor(client)
        send(peer, :stop)
        assert_receive {^a, {:error, :connection_closed}}
        assert_receive {^b, {:error, :connection_closed}}
        assert_receive {:DOWN, ^monitor, :process, ^client, :normal}
      end

      test "fragmented frames and out-of-order responses retain identity", %{client: client} do
        a = make_ref()
        b = make_ref()
        assert :ok = Client.dispatch(client, 1, %{"id" => 1}, {self(), a}, :infinity)
        assert :ok = Client.dispatch(client, 2, %{"id" => 2}, {self(), b}, :infinity)
        {:ok, second} = @framing.encode(%{"id" => 2, "result" => "second"})
        {:ok, first} = @framing.encode(%{"id" => 1, "result" => "first"})
        <<head::binary-size(1), tail::binary>> = second <> first
        Client.feed(client, head)
        assert 2 == Client.pending_count(client)
        Client.feed(client, tail)
        assert_receive {:rpc_message, %{"id" => 2, "result" => "second"}}
        assert :ok = Client.complete(client, 2, {:ok, "second"})
        assert_receive {^b, {:ok, "second"}}
        assert_receive {:rpc_message, %{"id" => 1, "result" => "first"}}
        assert :ok = Client.complete(client, 1, {:ok, "first"})
        assert_receive {^a, {:ok, "first"}}
        assert 0 == Client.pending_count(client)
      end
    end
  end

  test "handshake has a state timeout" do
    previous = Process.flag(:trap_exit, true)

    try do
      {:ok, client} =
        Client.start_link(
          framing: LemonCore.Rpc.JsonLines,
          send: fn _ -> :ok end,
          ready: false,
          connect_timeout: 0
        )

      assert_receive {:EXIT, ^client, :normal}
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "reverse handlers run in supervised tasks without blocking deadlines" do
    tasks = start_supervised!({Task.Supervisor, []})
    owner = self()

    handler = fn message, reply ->
      send(owner, {:handler_started, self(), message})

      receive do
        :release -> reply.(%{"id" => 10, "result" => "approved"})
      end
    end

    {:ok, client} =
      Client.start_link(
        framing: LemonCore.Rpc.JsonLines,
        handler: handler,
        task_supervisor: tasks,
        send: fn bytes ->
          send(owner, {:handler_wire, bytes})
          :ok
        end
      )

    Client.feed(client, ~s({"id":10,"method":"reverse"}\n))
    assert_receive {:handler_started, worker, %{"method" => "reverse"}}
    refute worker == client
    tag = make_ref()
    assert :ok = Client.dispatch(client, 20, %{"id" => 20}, {self(), tag}, 0)
    assert_receive {^tag, {:error, :timeout}}
    send(worker, :release)
    assert_receive {:handler_wire, ~s({"id":20}\n)}
    assert_receive {:handler_wire, bytes}
    assert {:ok, %{"id" => 10, "result" => "approved"}} = Jason.decode(String.trim(bytes))
    :gen_statem.stop(client)
  end

  test "management status excludes private requests and callbacks" do
    {:ok, client} = Client.start_link(framing: LemonCore.Rpc.JsonLines, send: fn _ -> :ok end)

    assert :ok =
             Client.dispatch(
               client,
               "private-id",
               %{"secret" => "private-value"},
               {self(), make_ref()},
               :infinity
             )

    status = :sys.get_status(client) |> inspect()
    refute status =~ "private-id"
    refute status =~ "private-value"
    assert status =~ "redacted"
    :gen_statem.stop(client)
  end
end
