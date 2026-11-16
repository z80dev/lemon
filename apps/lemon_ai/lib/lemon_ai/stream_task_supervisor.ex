defmodule LemonAi.StreamTaskSupervisor do
  @moduledoc false

  @default_max_children 1024

  # Keep provider task admission local: lemon_ai has no umbrella dependencies.
  def child_spec(opts) do
    configured = Application.get_env(:lemon_ai, :task_supervisor_max_children, %{})

    limit =
      Keyword.get(opts, :max_children, Map.get(configured, __MODULE__, @default_max_children))

    unless is_integer(limit) and limit > 0 do
      raise ArgumentError, "task supervisor max_children must be a positive integer"
    end

    Task.Supervisor.child_spec(name: __MODULE__, max_children: limit)
  end

  def start_child(fun) do
    case Task.Supervisor.start_child(__MODULE__, fun) do
      {:error, :max_children} -> {:error, :task_capacity_reached}
      result -> result
    end
  catch
    # Other exits may race with task startup; do not claim the callback never ran.
    :exit, {:noproc, _} -> {:error, :task_supervisor_unavailable}
  end
end
