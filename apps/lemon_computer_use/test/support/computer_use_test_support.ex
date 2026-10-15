defmodule LemonComputerUse.TestSupport do
  @moduledoc false

  import ExUnit.Callbacks

  @keys [:node, :command, :bridge_script, :lcu_root, :connect_timeout_ms]

  @doc "Point the app at the fake bridge and start a server under the default name."
  def start_fake_server(context \\ %{}) do
    saved = Enum.map(@keys, &{&1, Application.fetch_env(:lemon_computer_use, &1)})
    fake = Path.expand("fake_bridge.mjs", __DIR__)
    dir = Path.join(System.tmp_dir!(), "lemon_cua_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    log = Path.join(dir, "requests.jsonl")

    Application.put_env(:lemon_computer_use, :node, System.find_executable("node"))
    Application.put_env(:lemon_computer_use, :command, [fake])
    Application.put_env(:lemon_computer_use, :bridge_script, fake)
    Application.put_env(:lemon_computer_use, :lcu_root, dir)
    Application.put_env(:lemon_computer_use, :connect_timeout_ms, 10_000)
    System.put_env("LCU_FAKE_LOG", log)
    if context[:connect_fail], do: System.put_env("LCU_FAKE_CONNECT_FAIL", "1")

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_computer_use, key, value)
        {key, :error} -> Application.delete_env(:lemon_computer_use, key)
      end)

      System.delete_env("LCU_FAKE_LOG")
      System.delete_env("LCU_FAKE_CONNECT_FAIL")
      File.rm_rf(dir)
    end)

    pid = start_supervised!({LemonComputerUse.Server, []})
    %{server: pid, log: log}
  end

  @doc "Requests the fake bridge received, decoded."
  def requests(log) do
    case File.read(log) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      _ -> []
    end
  end

  @doc "Poll until `fun` returns truthy or the deadline passes."
  def eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      fun.() ||
        if System.monotonic_time(:millisecond) > deadline,
          do: :timeout,
          else: Process.sleep(25) && nil
    end)
    |> Enum.find(& &1)
  end
end
