defmodule CodingAgent.CodeReloadTest do
  use ExUnit.Case, async: false

  test "refreshes idle sessions and counts busy and exiting sessions" do
    unless Process.whereis(CodingAgent.SessionRegistry) do
      start_supervised!({Registry, keys: :unique, name: CodingAgent.SessionRegistry})
    end

    assert CodingAgent.SessionRegistry.list_ids() == []
    parent = self()

    pids =
      for {id, response} <- [
            {"reload-idle", {:ok, %{}}},
            {"reload-busy", {:error, :already_streaming}},
            {"reload-exit", :exit}
          ] do
        pid =
          spawn(fn ->
            {:ok, _} = Registry.register(CodingAgent.SessionRegistry, id, nil)
            send(parent, {:registered, self()})

            receive do
              {:"$gen_call", from, :reload_extensions} ->
                if response == :exit do
                  exit(:normal)
                else
                  GenServer.reply(from, response)

                  receive do
                    :stop -> :ok
                  end
                end
            end
          end)

        assert_receive {:registered, ^pid}
        pid
      end

    on_exit(fn ->
      Enum.each(pids, fn pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        end
      end)
    end)

    assert CodingAgent.CodeReload.refresh_sessions() == %{refreshed: 1, busy: 1, failed: 1}
  end
end
