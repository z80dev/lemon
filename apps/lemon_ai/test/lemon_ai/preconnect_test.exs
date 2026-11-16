defmodule LemonAi.PreconnectTest do
  use ExUnit.Case, async: false
  alias LemonAi.{Preconnect, Types.Model}

  test "origin strips paths and query and refuses credential-bearing URLs" do
    assert {:ok, "https://example.com/"} =
             Preconnect.origin(%Model{base_url: "https://example.com/v1/chat?secret=value#frag"})

    assert {:error, :unsupported_origin} =
             Preconnect.origin(%Model{base_url: "https://user:secret@example.com"})

    assert {:error, :unsupported_origin} = Preconnect.origin(%Model{base_url: ""})
  end

  test "duplicate hints coalesce and distinct origins are bounded" do
    owner = self()
    {:ok, state} = Preconnect.init(request: fn origin -> send(owner, {:warm, origin}) end)
    {:noreply, state} = Preconnect.handle_cast({:hint, "https://one.example/"}, state)
    assert_receive {:warm, "https://one.example/"}
    {:noreply, state} = Preconnect.handle_cast({:hint, "https://one.example/"}, state)
    refute_receive {:warm, _}

    full = %{
      state
      | origins: Map.new(1..8, &{to_string(&1), System.monotonic_time(:millisecond) + 30_000})
    }

    assert {:noreply, ^full} = Preconnect.handle_cast({:hint, "https://nine.example/"}, full)
    refute_receive {:warm, _}
  end

  test "unpaid HEAD warms the same default Finch connection used by Req" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    owner = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)

        for method <- [:HEAD, :GET] do
          assert {:ok, {:http_request, ^method, {:abs_path, "/"}, _}} =
                   :gen_tcp.recv(socket, 0, 5_000)

          drain_headers(socket)
          send(owner, {:request, method})
          :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
        end

        :gen_tcp.close(socket)
      end)

    url = "http://127.0.0.1:#{port}/"
    assert :ok = LemonAi.preconnect(%Model{base_url: url <> "paid/completion?private=true"})
    assert_receive {:request, :HEAD}, 5_000

    for pid <- Task.Supervisor.children(LemonAi.PreconnectTasks) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    assert {:ok, %{status: 200}} = Req.get(url, retry: false)
    assert_receive {:request, :GET}
    Task.await(server)
  end

  defp drain_headers(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _, _, _, _}} -> drain_headers(socket)
    end
  end
end
