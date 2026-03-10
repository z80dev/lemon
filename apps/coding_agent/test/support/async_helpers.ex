defmodule CodingAgent.AsyncHelpers do
  @moduledoc """
  Delegates to `LemonCore.Testing.AsyncHelpers` for shared async test primitives.
  """

  defdelegate assert_eventually(condition_fn, opts \\ []), to: LemonCore.Testing.AsyncHelpers
  defdelegate assert_process_dead(pid, opts \\ []), to: LemonCore.Testing.AsyncHelpers
  defdelegate assert_process_alive(pid, opts \\ []), to: LemonCore.Testing.AsyncHelpers
  defdelegate latch(), to: LemonCore.Testing.AsyncHelpers
  defdelegate release(latch_pid), to: LemonCore.Testing.AsyncHelpers
  defdelegate await_latch(latch_pid, opts \\ []), to: LemonCore.Testing.AsyncHelpers
  defdelegate barrier(count), to: LemonCore.Testing.AsyncHelpers
  defdelegate arrive(ref), to: LemonCore.Testing.AsyncHelpers
  defdelegate await_barrier(ref, opts \\ []), to: LemonCore.Testing.AsyncHelpers
  defdelegate with_ordered_tasks(fns), to: LemonCore.Testing.AsyncHelpers
end
