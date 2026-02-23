defmodule LemonGateway.AsyncHelpers do
  @moduledoc """
  Deterministic synchronization primitives for the lemon_gateway async test suite.

  Replaces ad hoc `Process.sleep` calls with bounded polling and explicit
  coordination helpers so that concurrency tests do not depend on wall-clock
  timing.

  ## Primitives

  ### Eventual assertions

      assert_eventually(fn -> some_condition() end)
      assert_eventually(fn -> some_condition() end, timeout: 2_000, interval: 20)

  ### Process-lifecycle helpers

      assert_process_dead(pid)     # waits until pid is gone
      assert_process_alive(pid)    # waits until pid is alive

  ### Latch (single-use barrier, one releaser + one waiter)

      latch = latch()
      spawn(fn -> do_something(); release(latch) end)
      await_latch(latch)
  """

  @default_timeout 2_000
  @default_interval 10

  # ---------------------------------------------------------------------------
  # Eventual assertions
  # ---------------------------------------------------------------------------

  @doc """
  Polls `condition_fn` every `interval` ms until it returns truthy or `timeout`
  elapses.  Fails the test with `message` if the deadline is reached.
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
        ExUnit.Assertions.flunk("#{message} (timed out)")
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
  Waits until `pid` is no longer alive.
  Fails the test if the process is still alive after `timeout` ms.
  """
  @spec assert_process_dead(pid(), keyword()) :: :ok
  def assert_process_dead(pid, opts \\ []) do
    opts = Keyword.put_new(opts, :message, "expected process #{inspect(pid)} to stop")
    assert_eventually(fn -> not Process.alive?(pid) end, opts)
  end

  @doc """
  Waits until `pid` is alive.
  Fails if the process is not alive within `timeout` ms.
  """
  @spec assert_process_alive(pid(), keyword()) :: :ok
  def assert_process_alive(pid, opts \\ []) do
    opts = Keyword.put_new(opts, :message, "expected process #{inspect(pid)} to be alive")
    assert_eventually(fn -> Process.alive?(pid) end, opts)
  end

  # ---------------------------------------------------------------------------
  # Latch (single-use one-shot signal)
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new latch (an Agent holding a boolean).
  """
  @spec latch() :: pid()
  def latch do
    {:ok, agent} = Agent.start_link(fn -> false end)
    agent
  end

  @doc """
  Releases the latch so that `await_latch/2` unblocks.
  """
  @spec release(pid()) :: :ok
  def release(latch_pid) do
    Agent.update(latch_pid, fn _ -> true end)
  end

  @doc """
  Blocks until the latch has been released, then stops the Agent.
  """
  @spec await_latch(pid(), keyword()) :: :ok
  def await_latch(latch_pid, opts \\ []) do
    opts = Keyword.put_new(opts, :message, "latch was never released")
    assert_eventually(fn -> Agent.get(latch_pid, & &1) end, opts)
    Agent.stop(latch_pid)
    :ok
  end
end
