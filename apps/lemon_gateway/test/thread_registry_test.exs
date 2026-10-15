defmodule LemonGateway.ThreadRegistryTest do
  @moduledoc """
  Comprehensive tests for LemonGateway.ThreadRegistry.

  The ThreadRegistry is a simple Elixir Registry wrapper that provides
  unique key registration for thread workers. It supports:
  - Process registration with unique keys
  - Looking up processes by key
  - Automatic cleanup when processes die
  """
  use ExUnit.Case, async: false
  import LemonGateway.AsyncHelpers, only: [assert_eventually: 1]

  alias LemonGateway.ThreadRegistry

  defmodule ThreadRegistryFixtureExecutor do
    @behaviour LemonGateway.Executor

    alias LemonCore.ResumeToken
    alias LemonGateway.{Event, ExecutionRequest}

    @impl true
    def start_run(%ExecutionRequest{} = request, _opts, sink_pid) do
      run_ref = make_ref()
      resume = request.resume || %ResumeToken{engine: "lemon", value: request.run_id}

      send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: "lemon", resume: resume})})

      send(
        sink_pid,
        {:engine_event, run_ref,
         Event.completed(%{
           engine: "lemon",
           resume: resume,
           ok: true,
           answer: "Test: #{request.prompt}"
         })}
      )

      {:ok, run_ref, %{}}
    end

    @impl true
    def cancel(_context), do: :ok

    @impl true
    def steer(_context, _text), do: {:error, :unsupported}

    @impl true
    def redirect(_context, _text), do: {:error, :unsupported}
  end

  # ============================================================================
  # Setup and helpers
  # ============================================================================

  setup do
    # Stop the app to reset state
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :executor, ThreadRegistryFixtureExecutor)

    Application.put_env(:lemon_gateway, :transports, [])
    Application.put_env(:lemon_gateway, :commands, [])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    :ok
  end

  defp unique_key do
    {:thread, System.unique_integer([:positive])}
  end

  defp spawn_registering_process(key) do
    test_pid = self()

    spawn(fn ->
      result = ThreadRegistry.register(key)
      send(test_pid, {:registered, self(), result})

      receive do
        :stop -> :ok
      end
    end)
  end

  defp wait_for_registration(pid, timeout \\ 1000) do
    receive do
      {:registered, ^pid, result} -> result
    after
      timeout -> raise "Timeout waiting for registration"
    end
  end

  # ============================================================================
  # 1. Basic registration tests
  # ============================================================================

  describe "basic registration" do
    test "register/1 succeeds for new key" do
      key = unique_key()
      pid = spawn_registering_process(key)
      result = wait_for_registration(pid)

      assert result == {:ok, pid}
      send(pid, :stop)
    end

    test "register/1 can register different keys from same process" do
      key1 = unique_key()
      key2 = unique_key()

      # A process can register multiple keys
      test_pid = self()

      spawn(fn ->
        result1 = ThreadRegistry.register(key1)
        result2 = ThreadRegistry.register(key2)
        send(test_pid, {:results, result1, result2})

        receive do
          :stop -> :ok
        end
      end)

      receive do
        {:results, result1, result2} ->
          assert {:ok, _} = result1
          assert {:ok, _} = result2
      after
        1000 -> flunk("Timeout")
      end
    end

    test "register/1 accepts tuple, atom, string, and integer keys" do
      for key <- [
            {:scope, %{transport: :telegram, chat_id: 123}},
            :my_unique_thread,
            "thread:123:456",
            12_345
          ] do
        pid = spawn_registering_process(key)
        assert wait_for_registration(pid) == {:ok, pid}
        assert ThreadRegistry.whereis(key) == pid
        send(pid, :stop)
      end
    end
  end

  # ============================================================================
  # 2. Thread lookup tests
  # ============================================================================

  describe "thread lookup with whereis/1" do
    test "whereis/1 returns pid for registered key" do
      key = unique_key()
      pid = spawn_registering_process(key)
      :ok = wait_for_registration(pid) |> elem(0) && :ok

      assert ThreadRegistry.whereis(key) == pid
      send(pid, :stop)
    end

    test "whereis/1 returns nil for unregistered key" do
      key = unique_key()

      assert ThreadRegistry.whereis(key) == nil
    end

    test "whereis/1 returns nil for key that was never registered" do
      key = {:never_registered, System.unique_integer()}

      assert ThreadRegistry.whereis(key) == nil
    end

    test "whereis/1 is consistent across multiple calls" do
      key = unique_key()
      pid = spawn_registering_process(key)
      _ = wait_for_registration(pid)

      result1 = ThreadRegistry.whereis(key)
      result2 = ThreadRegistry.whereis(key)
      result3 = ThreadRegistry.whereis(key)

      assert result1 == pid
      assert result2 == pid
      assert result3 == pid
      send(pid, :stop)
    end

    test "whereis/1 with complex nested key" do
      key =
        {:scope,
         %{
           transport: :telegram,
           chat_id: 123_456_789,
           topic_id: nil,
           metadata: %{user: "test"}
         }}

      pid = spawn_registering_process(key)
      _ = wait_for_registration(pid)

      assert ThreadRegistry.whereis(key) == pid
      send(pid, :stop)
    end
  end

  # ============================================================================
  # 3. Thread unregistration / process death cleanup
  # ============================================================================

  describe "thread unregistration on process death" do
    test "registration is removed when process exits normally" do
      key = unique_key()

      pid =
        spawn(fn ->
          ThreadRegistry.register(key)

          receive do
            :stop -> :ok
          end
        end)

      assert_eventually(fn -> ThreadRegistry.whereis(key) == pid end)

      send(pid, :stop)
      assert_eventually(fn -> ThreadRegistry.whereis(key) == nil end)
    end

    test "registration is removed when process crashes" do
      key = unique_key()

      pid =
        spawn(fn ->
          ThreadRegistry.register(key)

          receive do
            :crash -> raise "Intentional crash"
          end
        end)

      assert_eventually(fn -> ThreadRegistry.whereis(key) == pid end)

      send(pid, :crash)
      assert_eventually(fn -> ThreadRegistry.whereis(key) == nil end)
    end

    test "registration is removed when process is killed" do
      key = unique_key()

      pid =
        spawn(fn ->
          ThreadRegistry.register(key)

          receive do
            _ -> :ok
          end
        end)

      assert_eventually(fn -> ThreadRegistry.whereis(key) == pid end)

      Process.exit(pid, :kill)
      assert_eventually(fn -> ThreadRegistry.whereis(key) == nil end)
    end

    test "key can be re-registered after process dies" do
      key = unique_key()

      # First process
      pid1 =
        spawn(fn ->
          ThreadRegistry.register(key)

          receive do
            :stop -> :ok
          end
        end)

      assert_eventually(fn -> ThreadRegistry.whereis(key) == pid1 end)

      send(pid1, :stop)
      assert_eventually(fn -> ThreadRegistry.whereis(key) == nil end)

      # Second process can now register the same key
      pid2 = spawn_registering_process(key)
      _ = wait_for_registration(pid2)

      assert ThreadRegistry.whereis(key) == pid2
      send(pid2, :stop)
    end

    test "cleanup handles rapid process death" do
      key = unique_key()

      # Rapidly spawn and kill processes
      for _ <- 1..10 do
        pid =
          spawn(fn ->
            ThreadRegistry.register(key)

            receive do
              _ -> :ok
            end
          end)

        assert_eventually(fn -> ThreadRegistry.whereis(key) == pid end)
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
      end

      # Key should be unregistered
      assert_eventually(fn -> ThreadRegistry.whereis(key) == nil end)
    end
  end

  # ============================================================================
  # 4. Duplicate registration handling
  # ============================================================================

  describe "duplicate registration handling" do
    test "register/1 returns error for already registered key" do
      key = unique_key()

      # First process registers
      pid1 = spawn_registering_process(key)
      result1 = wait_for_registration(pid1)
      assert {:ok, _} = result1

      # Second process tries to register same key
      pid2 = spawn_registering_process(key)
      result2 = wait_for_registration(pid2)

      assert {:error, {:already_registered, ^pid1}} = result2

      send(pid1, :stop)
      send(pid2, :stop)
    end

    test "same process cannot register same key twice" do
      key = unique_key()
      test_pid = self()

      spawn(fn ->
        result1 = ThreadRegistry.register(key)
        result2 = ThreadRegistry.register(key)
        send(test_pid, {:results, result1, result2})

        receive do
          :stop -> :ok
        end
      end)

      receive do
        {:results, result1, result2} ->
          assert {:ok, _} = result1
          # Second registration of same key from same process should fail
          assert {:error, {:already_registered, _}} = result2
      after
        1000 -> flunk("Timeout")
      end
    end

    test "error includes the pid that owns the registration" do
      key = unique_key()

      pid1 = spawn_registering_process(key)
      _ = wait_for_registration(pid1)

      pid2 = spawn_registering_process(key)
      result = wait_for_registration(pid2)

      assert {:error, {:already_registered, owner_pid}} = result
      assert owner_pid == pid1

      send(pid1, :stop)
      send(pid2, :stop)
    end
  end

  # ============================================================================
  # 5. Concurrent registration tests
  # ============================================================================

  describe "concurrent registration" do
    test "concurrent registrations for different keys all succeed" do
      keys = for i <- 1..20, do: {:concurrent, i}
      test_pid = self()

      pids =
        Enum.map(keys, fn key ->
          spawn(fn ->
            result = ThreadRegistry.register(key)
            send(test_pid, {:registered, key, self(), result})

            receive do
              :stop -> :ok
            end
          end)
        end)

      # Collect all results
      results =
        for _ <- keys do
          receive do
            {:registered, key, pid, result} -> {key, pid, result}
          after
            1000 -> flunk("Timeout waiting for registration")
          end
        end

      # All should succeed
      for {_key, _pid, result} <- results do
        assert {:ok, _} = result
      end

      # All keys should be resolvable
      for {key, pid, _} <- results do
        assert ThreadRegistry.whereis(key) == pid
      end

      Enum.each(pids, &send(&1, :stop))
    end

    test "race condition: multiple processes racing to register same key" do
      key = unique_key()
      test_pid = self()

      # Spawn 10 processes that all try to register the same key
      pids =
        for _ <- 1..10 do
          spawn(fn ->
            result = ThreadRegistry.register(key)
            send(test_pid, {:registered, self(), result})

            receive do
              :stop -> :ok
            end
          end)
        end

      # Collect results
      results =
        for _ <- 1..10 do
          receive do
            {:registered, pid, result} -> {pid, result}
          after
            1000 -> flunk("Timeout")
          end
        end

      # Exactly one should succeed
      successes = Enum.filter(results, fn {_pid, result} -> match?({:ok, _}, result) end)
      failures = Enum.filter(results, fn {_pid, result} -> match?({:error, _}, result) end)

      assert length(successes) == 1
      assert length(failures) == 9

      # The successful one should be findable
      [{winner_pid, _}] = successes
      assert ThreadRegistry.whereis(key) == winner_pid

      # All failures should reference the winner
      for {_pid, {:error, {:already_registered, owner}}} <- failures do
        assert owner == winner_pid
      end

      Enum.each(pids, &send(&1, :stop))
    end

    test "concurrent lookups are safe" do
      key = unique_key()
      pid = spawn_registering_process(key)
      _ = wait_for_registration(pid)

      # Spawn many processes doing concurrent lookups
      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            ThreadRegistry.whereis(key)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should return the same pid
      assert Enum.all?(results, &(&1 == pid))
      send(pid, :stop)
    end

    test "concurrent registration and lookup" do
      base_key = System.unique_integer([:positive])
      test_pid = self()

      # Start some registering processes
      register_pids =
        for i <- 1..5 do
          key = {:concurrent_lookup, base_key, i}

          spawn(fn ->
            result = ThreadRegistry.register(key)
            send(test_pid, {:registered, key, self(), result})

            receive do
              :stop -> :ok
            end
          end)
        end

      # Collect registrations
      registrations =
        for _ <- 1..5 do
          receive do
            {:registered, key, pid, result} -> {key, pid, result}
          after
            1000 -> flunk("Timeout")
          end
        end

      # Now do concurrent lookups while processes are still running
      for {key, expected_pid, _} <- registrations do
        tasks =
          for _ <- 1..10 do
            Task.async(fn -> ThreadRegistry.whereis(key) end)
          end

        results = Task.await_many(tasks, 1000)
        assert Enum.all?(results, &(&1 == expected_pid))
      end

      Enum.each(register_pids, &send(&1, :stop))
    end
  end

  # ============================================================================
  # 6. Registry queries
  # ============================================================================

  describe "registry state inspection" do
    test "empty registry returns nil for all queries" do
      # Use keys that definitely don't exist
      for i <- 1..10 do
        key = {:nonexistent, System.unique_integer(), i}
        assert ThreadRegistry.whereis(key) == nil
      end
    end

    test "registry handles many concurrent registrations" do
      # Register many processes
      test_pid = self()
      count = 50

      pids =
        for i <- 1..count do
          key = {:many, i}

          spawn(fn ->
            ThreadRegistry.register(key)
            send(test_pid, {:ready, i})

            receive do
              :stop -> :ok
            end
          end)
        end

      # Wait for all to register
      for _ <- 1..count do
        receive do
          {:ready, _} -> :ok
        after
          1000 -> flunk("Timeout")
        end
      end

      # Verify all are registered
      for i <- 1..count do
        key = {:many, i}
        assert ThreadRegistry.whereis(key) != nil
      end

      Enum.each(pids, &send(&1, :stop))
    end
  end

  # ============================================================================
  # 7. Edge cases
  # ============================================================================

  describe "edge cases" do
    test "whereis with nil key" do
      # Registry should handle nil key gracefully
      result = ThreadRegistry.whereis(nil)
      assert result == nil
    end

    test "register with nil key" do
      test_pid = self()

      spawn(fn ->
        result = ThreadRegistry.register(nil)
        send(test_pid, {:result, result})

        receive do
          :stop -> :ok
        end
      end)

      receive do
        {:result, result} ->
          # Should succeed - nil is a valid key
          assert {:ok, _} = result
      after
        1000 -> flunk("Timeout")
      end
    end

    test "register with empty tuple key" do
      key = {}
      pid = spawn_registering_process(key)
      result = wait_for_registration(pid)

      assert {:ok, _} = result
      assert ThreadRegistry.whereis(key) == pid
      send(pid, :stop)
    end

    test "register with deeply nested key" do
      key = {:a, {:b, {:c, {:d, {:e, :f}}}}}
      pid = spawn_registering_process(key)
      result = wait_for_registration(pid)

      assert {:ok, _} = result
      assert ThreadRegistry.whereis(key) == pid
      send(pid, :stop)
    end

    test "register with binary data key" do
      key = <<1, 2, 3, 4, 5>>
      pid = spawn_registering_process(key)
      result = wait_for_registration(pid)

      assert {:ok, _} = result
      assert ThreadRegistry.whereis(key) == pid
      send(pid, :stop)
    end

    test "register with list key" do
      key = [1, 2, 3, "four", :five]
      pid = spawn_registering_process(key)
      result = wait_for_registration(pid)

      assert {:ok, _} = result
      assert ThreadRegistry.whereis(key) == pid
      send(pid, :stop)
    end

    test "register with map key" do
      key = %{a: 1, b: 2, c: %{nested: true}}
      pid = spawn_registering_process(key)
      result = wait_for_registration(pid)

      assert {:ok, _} = result
      assert ThreadRegistry.whereis(key) == pid
      send(pid, :stop)
    end

    test "registry handles process that never sends messages" do
      key = unique_key()

      pid =
        spawn(fn ->
          ThreadRegistry.register(key)
          # Just loop forever without communicating
          loop = fn loop_fn ->
            receive do
              :stop -> :ok
            after
              60_000 -> loop_fn.(loop_fn)
            end
          end

          loop.(loop)
        end)

      assert_eventually(fn -> ThreadRegistry.whereis(key) == pid end)

      send(pid, :stop)
      assert_eventually(fn -> ThreadRegistry.whereis(key) == nil end)
    end
  end

  # ============================================================================
  # 9. child_spec and start_link tests
  # ============================================================================

  describe "child_spec and start_link" do
    test "child_spec returns correct specification" do
      spec = ThreadRegistry.child_spec([])

      assert spec.id == ThreadRegistry
      assert spec.type == :supervisor
      assert spec.start == {ThreadRegistry, :start_link, [[]]}
    end

    test "child_spec with opts passes them through" do
      spec = ThreadRegistry.child_spec(some_opt: :value)

      assert spec.start == {ThreadRegistry, :start_link, [[some_opt: :value]]}
    end
  end

  # ============================================================================
  # 10. Stress tests
  # ============================================================================

  describe "stress tests" do
    test "handles rapid registration/unregistration cycles" do
      key = unique_key()

      for _ <- 1..100 do
        pid =
          spawn(fn ->
            ThreadRegistry.register(key)

            receive do
              :stop -> :ok
            end
          end)

        assert_eventually(fn -> ThreadRegistry.whereis(key) == pid end)
        ref = Process.monitor(pid)
        send(pid, :stop)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}
      end

      # Should be clean after all cycles
      assert_eventually(fn -> ThreadRegistry.whereis(key) == nil end)
    end

    test "handles many different keys" do
      test_pid = self()

      pids =
        for i <- 1..200 do
          key = {:stress_test, i, :unique}

          spawn(fn ->
            ThreadRegistry.register(key)
            send(test_pid, {:registered, i})

            receive do
              :stop -> :ok
            end
          end)
        end

      # Wait for all registrations
      for _ <- 1..200 do
        receive do
          {:registered, _} -> :ok
        after
          2000 -> flunk("Timeout")
        end
      end

      # Verify all are findable
      for i <- 1..200 do
        key = {:stress_test, i, :unique}
        assert ThreadRegistry.whereis(key) != nil, "Key #{i} not found"
      end

      # Cleanup
      Enum.each(pids, &send(&1, :stop))
      # All should be unregistered
      for i <- 1..200 do
        key = {:stress_test, i, :unique}
        assert_eventually(fn -> ThreadRegistry.whereis(key) == nil end)
      end
    end

    test "handles interleaved register and lookup operations" do
      base = System.unique_integer([:positive])
      test_pid = self()

      # Start registration processes
      register_pids =
        for i <- 1..20 do
          spawn(fn ->
            key = {:interleaved, base, i}
            ThreadRegistry.register(key)
            send(test_pid, {:registered, i})

            receive do
              :stop -> :ok
            end
          end)
        end

      # Start lookup tasks immediately (racing with registrations)
      lookup_tasks =
        for i <- 1..20 do
          Task.async(fn ->
            key = {:interleaved, base, i}
            # Try multiple times as registration may not be complete
            result =
              Enum.reduce_while(1..500, nil, fn _, _ ->
                case ThreadRegistry.whereis(key) do
                  nil ->
                    Process.sleep(10)
                    {:cont, nil}

                  pid ->
                    {:halt, pid}
                end
              end)

            {i, result}
          end)
        end

      # Wait for registrations
      for _ <- 1..20 do
        receive do
          {:registered, _} -> :ok
        after
          1000 -> :ok
        end
      end

      # Get lookup results
      results = Task.await_many(lookup_tasks, 5000)

      # Most lookups should eventually succeed
      successful = Enum.filter(results, fn {_, result} -> is_pid(result) end)
      assert length(successful) >= 15, "Expected at least 15 successful lookups"

      Enum.each(register_pids, &send(&1, :stop))
    end
  end
end
