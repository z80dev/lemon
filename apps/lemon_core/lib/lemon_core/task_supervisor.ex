defmodule LemonCore.TaskSupervisor do
  @moduledoc """
  Bounded task admission with explicit errors, without retrying work.

  The default cap of 1024 concurrent tasks per supervisor is a caller policy,
  not a measured throughput limit. Set `:max_children` in the child options or
  configure `:lemon_core, :task_supervisor_max_children` as a map keyed by the
  supervisor's registered name. Explicit child options take precedence. Caps
  must be positive integers; task children remain temporary.

  Admission rejection means the function did not run. Other exits (including
  supervisor termination during admission) are deliberately not translated:
  they do not prove that side effects never started. Callers retain their
  existing unknown-outcome contract for those failures.
  """

  @default_max_children 1024

  def child_spec(opts) do
    configured = Application.get_env(:lemon_core, :task_supervisor_max_children, %{})

    limit =
      Keyword.get(
        opts,
        :max_children,
        Map.get(configured, Keyword.get(opts, :name), @default_max_children)
      )

    unless is_integer(limit) and limit > 0 do
      raise ArgumentError, "task supervisor max_children must be a positive integer"
    end

    Task.Supervisor.child_spec(Keyword.put(opts, :max_children, limit))
  end

  def start_child(supervisor, fun, opts \\ []) do
    case Task.Supervisor.start_child(supervisor, fun, opts) do
      {:error, :max_children} -> {:error, :task_capacity_reached}
      result -> result
    end
  catch
    :exit, {:noproc, _} -> {:error, :task_supervisor_unavailable}
  end

  def async(supervisor, fun, opts \\ []),
    do: start_async(:async, supervisor, fun, opts)

  def async_nolink(supervisor, fun, opts \\ []),
    do: start_async(:async_nolink, supervisor, fun, opts)

  defp start_async(mode, supervisor, fun, opts) do
    {:ok, apply(Task.Supervisor, mode, [supervisor, fun, opts])}
  rescue
    error in RuntimeError ->
      if String.starts_with?(
           error.message,
           "reached the maximum number of tasks for this task supervisor."
         ) do
        {:error, :task_capacity_reached}
      else
        reraise error, __STACKTRACE__
      end
  catch
    :exit, {:noproc, _} -> {:error, :task_supervisor_unavailable}
  end
end
