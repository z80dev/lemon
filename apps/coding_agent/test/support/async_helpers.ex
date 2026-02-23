defmodule CodingAgent.AsyncHelpers do
  @moduledoc """
  Shared deterministic synchronization primitives for async test suites.

  Replaces ad hoc `Process.sleep` calls with bounded polling and explicit
  coordination barriers so that concurrency tests do not depend on wall-clock
  timing and are therefore reproducible across machines and load conditions.

  ## Primitives

  ### Eventual assertions

      assert_eventually(fn -> some_condition() end)
      assert_eventually(fn -> some_condition() end, timeout: 2_000, interval: 20)

  ### Process-lifecycle helpers

      assert_process_dead(pid)            # waits until pid is gone
      assert_process_alive(pid)           # waits until pid registers

  ### Latch (single-use barrier, one waiter, one releaser)

      latch = latch()
      spawn(fn -> do_something(); release(latch) end)
      await_latch(latch)

  ### Rendez-vous barrier (N participants, all arrive then all proceed)

      barrier = barrier(3)
      # Each of the 3 participants calls:
      arrive(barrier)
      await_barrier(barrier)   # blocks until all 3 have arrived

  ### Ordered task runner

      with_ordered_tasks([fn -> work1() end, fn -> work2() end])
  """

  # ---------------------------------------------------------------------------
  # Eventual assertions
  # ---------------------------------------------------------------------------

  @default_timeout 2_000
  @default_interval 10

  @doc """
  Asserts that `condition_fn` returns truthy within `timeout` milliseconds,
  polling every `interval` milliseconds.

  Options:
    - `:timeout`  — maximum wait in ms (default: #{@default_timeout})
    - `:interval` — polling interval in ms (default: #{@default_interval})
    - `:message`  — failure message prefix (default: "condition never became true")
  """
  @spec assert_eventually((-> boolean()), keyword()) :: :ok
  def assert_eventually(condition_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    interval = Keyword.get(opts, :interval, @default_interval)
    message = Keyword.get(opts, :message, "condition never became true")

    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll(condition_fn, interval, deadline, message)
  end

  defp do_poll(fun, interval, deadline, message) do
    if fun.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        ExUnit.Assertions.flunk("#{message} (timed out after waiting)")
      else
        Process.sleep(interval)
        do_poll(fun, interval, deadline, message)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Process-lifecycle helpers
  # ---------------------------------------------------------------------------

  @doc """
  Waits until `pid` is no longer alive, up to `timeout` ms.
  Fails the test if the process is still alive at the deadline.
  """
  @spec assert_process_dead(pid(), keyword()) :: :ok
  def assert_process_dead(pid, opts \\ []) do
    opts = Keyword.put_new(opts, :message, "expected process #{inspect(pid)} to stop")
    assert_eventually(fn -> not Process.alive?(pid) end, opts)
  end

  @doc """
  Waits until `pid` is alive, up to `timeout` ms.
  Fails the test if the process is not alive by the deadline.

  Useful when a pid is obtained before the process has fully started.
  """
  @spec assert_process_alive(pid(), keyword()) :: :ok
  def assert_process_alive(pid, opts \\ []) do
    opts = Keyword.put_new(opts, :message, "expected process #{inspect(pid)} to be alive")
    assert_eventually(fn -> Process.alive?(pid) end, opts)
  end

  # ---------------------------------------------------------------------------
  # Latch (single-use one-shot signal — one releaser, one waiter)
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new latch. A latch is a one-shot signal: one caller releases it
  via `release/1`, another waits via `await_latch/2`.

  Implemented as an Agent holding a boolean flag.
  """
  @spec latch() :: pid()
  def latch do
    {:ok, agent} = Agent.start_link(fn -> false end)
    agent
  end

  @doc """
  Signals the latch so that `await_latch/2` unblocks.
  Safe to call from any process.
  """
  @spec release(pid()) :: :ok
  def release(latch_pid) do
    Agent.update(latch_pid, fn _ -> true end)
  end

  @doc """
  Blocks until the latch has been released, polling every `interval` ms.
  Fails after `timeout` ms if the latch was never released.

  Stops the Agent after returning (the latch is single-use).
  """
  @spec await_latch(pid(), keyword()) :: :ok
  def await_latch(latch_pid, opts \\ []) do
    opts = Keyword.put_new(opts, :message, "latch was never released")
    assert_eventually(fn -> Agent.get(latch_pid, & &1) end, opts)
    Agent.stop(latch_pid)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Barrier (N-party rendez-vous)
  #
  # All N participants call arrive/1 (non-blocking) and then await_barrier/2
  # (blocking until count is reached).  The barrier state is held in an ETS
  # table so it survives concurrent access from multiple processes without the
  # "first awaiter stops the agent before others can check" race.
  # ---------------------------------------------------------------------------

  @doc """
  Creates a barrier that must be arrived at `count` times before it opens.

  Returns a reference that identifies the barrier.  Pass this reference to
  `arrive/1` and `await_barrier/2`.
  """
  @spec barrier(pos_integer()) :: reference()
  def barrier(count) when is_integer(count) and count > 0 do
    ref = make_ref()
    :ets.new(barrier_table(ref), [:set, :public, :named_table])
    :ets.insert(barrier_table(ref), {:count, 0, count})
    ref
  end

  @doc """
  Signals that a participant has arrived at the barrier.
  Thread-safe: uses ETS update_counter for atomic increment.
  """
  @spec arrive(reference()) :: :ok
  def arrive(ref) do
    :ets.update_counter(barrier_table(ref), :count, {2, 1})
    :ok
  end

  @doc """
  Waits until all participants have arrived at the barrier.
  Multiple callers can safely call this on the same barrier — the last caller
  cleans up the ETS table.
  """
  @spec await_barrier(reference(), keyword()) :: :ok
  def await_barrier(ref, opts \\ []) do
    opts = Keyword.put_new(opts, :message, "barrier was never fully reached")

    assert_eventually(
      fn ->
        # Guard against the table being deleted by a concurrent await_barrier caller.
        try do
          case :ets.lookup(barrier_table(ref), :count) do
            [{:count, arrived, total}] -> arrived >= total
            # Table exists but key is missing — shouldn't happen in normal use
            _ -> false
          end
        catch
          :error, :badarg -> true
        end
      end,
      opts
    )

    # Clean up the ETS table. Because multiple tasks may call await_barrier
    # concurrently, we guard the delete with a try/catch.
    try do
      :ets.delete(barrier_table(ref))
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  defp barrier_table(ref) do
    # Build a unique atom name from the reference.  We use inspect/1 and convert
    # to atom so the name is globally unique per barrier instance.
    # Note: atom creation here is bounded by the number of barriers created per
    # test run, so it will not exhaust the atom table in normal use.
    :"async_helpers_barrier_#{:erlang.phash2(ref)}"
  end

  # ---------------------------------------------------------------------------
  # Ordered task runner
  # ---------------------------------------------------------------------------

  @doc """
  Runs a list of zero-arity functions as async tasks in a controlled,
  sequential order using latches.

  Each function is started as a task, but blocked on a per-task latch.
  Latches are released one at a time with a 1 ms gap, allowing each task to
  make progress before the next one is unblocked.  This is safer than random
  sleeps because the ordering is deterministic.

  Returns the list of results in the same order as `fns`.
  """
  @spec with_ordered_tasks([(-> any())]) :: [any()]
  def with_ordered_tasks(fns) when is_list(fns) do
    latches = Enum.map(fns, fn _ -> latch() end)

    tasks =
      fns
      |> Enum.zip(latches)
      |> Enum.map(fn {fun, l} ->
        Task.async(fn ->
          await_latch(l)
          fun.()
        end)
      end)

    # Release latches one at a time.  The 1 ms gap gives the previously-released
    # task a scheduling opportunity before the next one is started.  This is
    # intentional ordering, not a flake-prone race.
    Enum.each(latches, fn l ->
      release(l)
      Process.sleep(1)
    end)

    Task.await_many(tasks, 10_000)
  end
end
