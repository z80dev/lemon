defmodule LemonCore.BrowserProviderTest do
  use ExUnit.Case, async: false

  alias LemonCore.BrowserProvider

  defmodule Probe do
    def available?("relay"), do: {:ok, "private module reason"}
  end

  setup do
    keys = [:browser_provider_probe, :browser_provider_lcu_probe]
    previous = Map.new(keys, &{&1, Application.fetch_env(:lemon_core, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_core, key, value)
        {key, :error} -> Application.delete_env(:lemon_core, key)
      end)
    end)

    :ok
  end

  test "runtime module probes use the same provider-string contract" do
    result = BrowserProvider.resolve(config: %{provider: "relay"}, probe: Probe)
    assert result.provider == "relay"
    refute result.reason =~ "private module reason"
  end

  test "auto resolves all available, unavailable, and timed-out combinations in order" do
    states = [:available, :unavailable, :timeout]

    for lcu <- states, relay <- states, local <- states do
      availability = %{"lcu" => lcu, "relay" => relay, "local" => local}
      caller = self()

      callback = fn id ->
        send(caller, {:checked, id})

        case availability[id] do
          :available -> {:ok, "ignored"}
          :unavailable -> {:error, "ignored"}
          :timeout -> receive do: (:never -> :ok)
        end
      end

      result =
        BrowserProvider.resolve(
          config: %{provider: "auto"},
          timeout_ms: 50,
          probe: callback,
          lcu_probe: fn -> callback.("lcu") end
        )

      expected = Enum.find(~w(lcu relay local), &(availability[&1] == :available))

      evaluated =
        Enum.take_while(~w(lcu relay local), &(&1 != expected)) ++
          if(expected, do: [expected], else: [])

      assert result.requested == "auto"
      assert result.provider == expected
      assert Enum.sort(Map.keys(result.checks)) == Enum.sort(evaluated)
      assert is_binary(result.reason)
      assert byte_size(result.reason) < 1_500

      for id <- evaluated do
        assert_receive {:checked, ^id}
        assert result.checks[id].available == (availability[id] == :available)
        refute result.checks[id].reason =~ "ignored"
        if availability[id] == :timeout, do: assert(result.checks[id].reason =~ "timed out")
      end

      refute_receive {:checked, _}, 0
    end
  end

  test "every explicit provider fails closed and never probes an alternative" do
    for provider <- BrowserProvider.providers() -- ["auto"], available <- [false, true] do
      caller = self()

      callback = fn id ->
        send(caller, {:checked, id})
        if available, do: {:ok, "private details"}, else: {:error, "private details"}
      end

      result =
        BrowserProvider.resolve(
          config: %{provider: provider},
          probe: callback,
          lcu_probe: fn -> callback.("lcu") end
        )

      assert result.requested == provider
      assert result.provider == if(available, do: provider, else: nil)
      assert Map.keys(result.checks) == [provider]
      assert_receive {:checked, ^provider}
      refute_receive {:checked, _}, 0
      refute result.reason =~ "private details"
    end
  end

  test "provider option pins requests even when configured auto or a different provider" do
    for config <- [%{provider: "auto"}, %{provider: "lcu"}] do
      result =
        BrowserProvider.resolve(
          config: config,
          provider: "relay",
          probe: fn "relay" -> {:error, "disconnected"} end,
          lcu_probe: fn -> raise "must not probe LCU" end
        )

      assert result.requested == "relay"
      assert result.provider == nil
      assert Map.keys(result.checks) == ["relay"]
    end
  end

  test "config extraction accepts modular, facade, Tools, raw runtime and browser maps" do
    tools = %LemonCore.Config.Tools{browser: %{provider: "relay"}}

    configs = [
      %{provider: "relay"},
      %{"provider" => "relay"},
      tools,
      %LemonCore.Config.Modular{tools: tools},
      %LemonCore.Config{agent: %{tools: %{browser: %{provider: "relay"}}}},
      %{"runtime" => %{"tools" => %{"browser" => %{"provider" => "relay"}}}}
    ]

    for config <- configs do
      assert %{requested: "relay", provider: "relay"} =
               BrowserProvider.resolve(
                 config: config,
                 probe: fn "relay" -> {:ok, "connected"} end
               )
    end
  end

  test "runtime probe callbacks can be injected without loading a browser runtime" do
    Application.put_env(:lemon_core, :browser_provider_probe, fn "relay" ->
      {:ok, "sensitive runtime response"}
    end)

    Application.put_env(:lemon_core, :browser_provider_lcu_probe, fn ->
      {:error, "sensitive LCU response"}
    end)

    result = BrowserProvider.resolve(config: %{provider: "auto"})
    assert result.provider == "relay"
    assert result.reason =~ "LCU not selected"
    assert result.reason =~ "Relay selected"
    refute inspect(result) =~ "sensitive"
  end

  test "unknown selections are redacted and do not invoke probes" do
    for invalid <- ["https://secret.example/token", false, 12, %{}, ["local"]] do
      result =
        BrowserProvider.resolve(
          config: %{provider: invalid},
          probe: fn _ -> flunk("must not probe") end
        )

      assert result.requested == "invalid"
      assert result.provider == nil
      assert result.checks == %{}
      refute inspect(result) =~ "secret.example"
    end
  end

  test "probe exceptions, throws, exits, and malformed results fail closed and redact details" do
    callbacks = [
      fn _ -> raise "private token" end,
      fn _ -> throw("private token") end,
      fn _ -> exit("private token") end,
      fn _ -> %{"private token" => true} end,
      fn _ -> :ok end
    ]

    for callback <- callbacks do
      result = BrowserProvider.resolve(config: %{provider: "local"}, probe: callback)
      assert result.provider == nil
      assert result.checks["local"].available == false
      refute inspect(result) =~ "private token"
    end
  end

  test "all explicit provider timeouts terminate the probe and never fall back" do
    for provider <- BrowserProvider.providers() -- ["auto"] do
      caller = self()

      callback = fn id ->
        send(caller, {:blocked, id, self()})
        receive do: (:never -> {:ok, "not reached"})
      end

      result =
        BrowserProvider.resolve(
          config: %{provider: provider},
          timeout_ms: 30,
          probe: callback,
          lcu_probe: fn -> callback.("lcu") end
        )

      assert_receive {:blocked, ^provider, worker}
      monitor = Process.monitor(worker)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}
      assert result.provider == nil
      assert result.reason =~ "timed out"
      assert Map.keys(result.checks) == [provider]
    end
  end

  test "auto continues after a timed-out LCU and relay, but never tries hosted providers" do
    result =
      BrowserProvider.resolve(
        config: %{provider: "auto"},
        timeout_ms: 30,
        lcu_probe: fn -> receive do: (:never -> :ok) end,
        probe: fn
          "relay" -> receive do: (:never -> :ok)
          "local" -> {:ok, "available"}
          _ -> flunk("auto must not use paid or explicit-only providers")
        end
      )

    assert result.provider == "local"
    assert result.checks["lcu"].reason =~ "timed out"
    assert result.checks["relay"].reason =~ "timed out"
    assert result.checks["local"].available
    assert result.reason =~ "LCU not selected"
  end

  test "missing optional runtime is unavailable, not an implicit local success" do
    Application.delete_env(:lemon_core, :browser_provider_probe)
    result = BrowserProvider.resolve(config: %{provider: "local"})
    assert result.provider == nil
    refute result.checks["local"].available
  end

  test "known local reasons name the prerequisite; other reasons stay generic" do
    reason = fn probe_result ->
      BrowserProvider.resolve(config: %{provider: "local"}, probe: fn "local" -> probe_result end).reason
    end

    assert reason.({:error, :node_missing}) =~ "Node.js 24"
    assert reason.({:error, :driver_missing}) =~ "driver is not installed"
    assert reason.({:error, :driver_incompatible}) =~ "outdated"
    assert reason.({:error, :browser_missing}) =~ "LEMON_BROWSER_EXECUTABLE"

    generic = reason.({:error, :unavailable})
    assert generic == reason.({:error, "/private/path token=secret"})
    refute generic =~ "private"
  end
end
