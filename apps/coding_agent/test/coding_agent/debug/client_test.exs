defmodule CodingAgent.Debug.ClientTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Debug.Client

  @fake_adapter Path.expand("../../support/fake_dap_adapter.py", __DIR__)
  @python System.find_executable("python3")

  if is_nil(@python), do: @moduletag(skip: "python3 is required for the fake DAP adapter")

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    log = Path.join(tmp_dir, "requests.jsonl")

    adapter = %{
      name: "fake",
      command: @python,
      args: [@fake_adapter, log],
      connect_mode: :stdio
    }

    %{adapter: adapter, log: log, cwd: tmp_dir}
  end

  defp start_client!(adapter, cwd) do
    {:ok, client} = Client.start_link(adapter: adapter, cwd: cwd)

    on_exit(fn -> Client.stop(client) end)
    client
  end

  defp log_entries(log) do
    log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "rejects runInTerminal and startDebugging reverse requests", %{
    adapter: adapter,
    cwd: cwd,
    log: log
  } do
    client = start_client!(adapter, cwd)
    {:ok, _} = Client.request(client, "launch", %{"program" => "x", "fakeMode" => "reverse"})

    assert_receive {:dap, ^client, {:reverse_request, "runInTerminal"}}, 5_000
    assert_receive {:dap, ^client, {:reverse_request, "startDebugging"}}, 5_000
    assert_receive {:dap, ^client, {:event, "initialized", _}}, 5_000

    reverse_responses = fn ->
      Enum.filter(log_entries(log), &Map.has_key?(&1, "reverse_response"))
    end

    assert eventually(fn -> length(reverse_responses.()) == 2 end)
    responses = reverse_responses.()

    assert [
             %{"reverse_response" => "runInTerminal", "success" => false, "message" => rit},
             %{"reverse_response" => "startDebugging", "success" => false, "message" => sd}
           ] = responses

    assert rit =~ "runInTerminal is not supported"
    assert sd =~ "startDebugging"
  end

  test "reports adapter exit with captured stderr", %{adapter: adapter, cwd: cwd} do
    {:ok, client} = Client.start_link(adapter: adapter, cwd: cwd)
    ref = Process.monitor(client)
    {:ok, _} = Client.request(client, "launch", %{"program" => "x", "fakeMode" => "crash"})

    assert_receive {:dap, ^client, {:exit, reason}}, 5_000
    assert reason =~ "exited (code 3)"
    assert reason =~ "fatal adapter error"
    assert_receive {:DOWN, ^ref, :process, ^client, :normal}, 5_000
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(100) && eventually(fun, attempts - 1)
    end
  end
end
