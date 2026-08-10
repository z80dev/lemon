defmodule LemonCore.ACPClientBridgeTest do
  use ExUnit.Case, async: true

  alias LemonCore.ACPClientBridge

  defp run_id(prefix), do: "run_acp_#{prefix}_#{System.unique_integer([:positive])}"

  # A minimal handler: registers for the run, then answers one client request the
  # way the real ACP wait loop does — echoing the reply back to the requester.
  defp start_handler(run_id, responder) do
    test = self()

    spawn(fn ->
      :ok = ACPClientBridge.register(run_id)
      send(test, {:registered, self()})

      receive do
        {:acp_client_request, %{method: method, params: params, reply_to: reply_to, ref: ref}} ->
          send(reply_to, {:acp_client_response, ref, responder.(method, params)})
      after
        2_000 -> :ok
      end
    end)

    assert_receive {:registered, handler_pid}
    handler_pid
  end

  test "request/4 delivers a synchronous reply from the registered handler" do
    run_id = run_id("reply")

    start_handler(run_id, fn method, params ->
      %{"echoed_method" => method, "echoed_params" => params}
    end)

    assert {:ok, %{"echoed_method" => "fs/read_text_file", "echoed_params" => %{"path" => "/x"}}} =
             ACPClientBridge.request(run_id, "fs/read_text_file", %{"path" => "/x"}, 1_000)
  end

  test "request/4 returns {:error, :no_client} immediately when nothing is registered" do
    run_id = run_id("absent")

    # No handler ever registers; the call must fail fast rather than block for the
    # timeout. A generous timeout would make this test slow if it regressed.
    assert {:error, :no_client} =
             ACPClientBridge.request(run_id, "fs/read_text_file", %{}, 5_000)
  end

  test "request/4 returns {:error, :client_down} when the handler dies mid-request" do
    run_id = run_id("down")
    test = self()

    # A handler that registers, signals ready, then exits without replying.
    handler =
      spawn(fn ->
        :ok = ACPClientBridge.register(run_id)
        send(test, {:registered, self()})

        receive do
          :die -> :ok
        after
          2_000 -> :ok
        end
      end)

    assert_receive {:registered, ^handler}

    task =
      Task.async(fn ->
        ACPClientBridge.request(run_id, "fs/write_text_file", %{}, 2_000)
      end)

    # Let the request land, then kill the handler.
    Process.sleep(20)
    send(handler, :die)

    assert {:error, :client_down} = Task.await(task)
  end

  test "request/4 returns {:error, :timeout} when the handler never replies" do
    run_id = run_id("timeout")
    test = self()

    # Registers and stays alive but ignores the request.
    handler =
      spawn(fn ->
        :ok = ACPClientBridge.register(run_id)
        send(test, {:registered, self()})
        Process.sleep(1_000)
      end)

    assert_receive {:registered, ^handler}

    assert {:error, :timeout} =
             ACPClientBridge.request(run_id, "fs/read_text_file", %{}, 50)
  end

  test "unregister/1 removes the handler so subsequent requests fail fast" do
    run_id = run_id("unreg")
    :ok = ACPClientBridge.register(run_id)

    assert ACPClientBridge.whereis(run_id) == self()

    :ok = ACPClientBridge.unregister(run_id)
    assert ACPClientBridge.whereis(run_id) == nil
    assert {:error, :no_client} = ACPClientBridge.request(run_id, "fs/read_text_file", %{}, 100)
  end

  test "register/1 is idempotent for the same process and rejects a competing one" do
    run_id = run_id("dup")
    test = self()

    assert :ok = ACPClientBridge.register(run_id)
    assert :ok = ACPClientBridge.register(run_id)

    other =
      spawn(fn ->
        send(test, {:result, ACPClientBridge.register(run_id)})
        Process.sleep(200)
      end)

    assert_receive {:result, {:error, {:already_registered, pid}}}
    assert pid == self()
    _ = other
  end
end
