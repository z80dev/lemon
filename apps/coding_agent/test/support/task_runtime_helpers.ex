defmodule CodingAgent.TaskRuntimeHelpers do
  @moduledoc """
  Registers native task children without launching a model session and reads
  their owner state, for task runtime tests.
  """

  alias CodingAgent.TaskRuntime
  alias CodingAgent.Tools.Task.Control
  alias LemonAgent.AbortSignal

  @doc """
  Register an owner for `id`. Options: `:signal`, `:parent_signal`,
  `:owner_pid` and `:finalize` (called at most once, with the turn's outcome,
  by whichever of the worker and the owner claims the turn).
  """
  def register(id, parent, opts \\ []) do
    claim = :atomics.new(1, [])
    finalize = Keyword.get(opts, :finalize, fn _outcome -> :ok end)

    Control.register(id, %{
      signal: Keyword.get_lazy(opts, :signal, &AbortSignal.new/0),
      parent_signal: opts[:parent_signal],
      parent: parent,
      owner_pid: opts[:owner_pid],
      claim: claim,
      finalize: fn outcome ->
        if :atomics.compare_exchange(claim, 1, 0, 1) == :ok, do: finalize.(outcome)
        :ok
      end
    })
  end

  @doc "Start a worker for `id` that runs `fun` (default: wait for `:finish`)."
  def launch(id, fun \\ &wait_for_finish/0),
    do: Control.launch(id, CodingAgent.TaskSupervisor, fun)

  @doc "The owner's `{phase, data}`, or nil when it has no owner."
  def state(id) do
    case TaskRuntime.whereis(id) do
      nil -> nil
      owner -> :sys.get_state(owner)
    end
  end

  @doc "The owner's data, or nil when it has no owner."
  def entry(id) do
    case state(id) do
      {_phase, data} -> data
      nil -> nil
    end
  end

  @doc "Stop the owner of `id`, if any, as a parent exit would."
  def stop(id) do
    case TaskRuntime.whereis(id) do
      nil -> :ok
      owner -> :gen_statem.stop(owner)
    end
  catch
    :exit, _ -> :ok
  end

  defp wait_for_finish do
    receive do
      :finish -> :ok
    end
  end
end
