defmodule CodingAgent.Session.RootLifecycle do
  @moduledoc """
  Bounded retention of idle executor roots. Like task children, roots park by
  saving their journal and stopping their temporary process; the next request
  restores that journal. Tool resources belong to the live process and expire
  with it, not with an individual turn.

  The five-minute TTL matches the task caller's idle policy. The 32-root cap is
  a conservative caller resource budget, not a measured memory guarantee. Both
  bounds apply only to idle executor roots, never running turns or task children.
  """

  alias CodingAgent.SessionRegistry

  @idle_ttl_ms 300_000
  @max_idle_roots 32

  def idle_ttl_ms, do: @idle_ttl_ms
  def max_idle_roots, do: @max_idle_roots

  # No singleton owns session state or waits for journal I/O. Serialize admission
  # and cap eviction on this node so a checked-out root cannot be evicted.
  def checkout(id, opts) do
    locked(fn ->
      case SessionRegistry.lookup(id) do
        {:ok, pid} ->
          case call(pid, {:prepare_root_turn, opts}) do
            :ok -> {:ok, pid}
            {:error, :session_lost} -> :missing
            error -> error
          end

        :error ->
          :missing
      end
    end)
  end

  def retain(pid) do
    locked(fn ->
      with :ok <- call(pid, {:retain_root, @idle_ttl_ms}) do
        enforce_cap(@max_idle_roots)
      end
    end)
  end

  @doc false
  def enforce_cap(cap) when is_integer(cap) and cap >= 0 do
    idle_roots()
    |> Enum.sort_by(fn {_pid, order} -> order end)
    |> then(fn roots -> Enum.take(roots, max(length(roots) - cap, 0)) end)
    |> Enum.each(fn {pid, order} -> call(pid, {:park_root, order}) end)

    :ok
  end

  defp idle_roots do
    Registry.select(CodingAgent.SessionRegistry, [
      {{:_, :"$1", %{root_idle: :"$2"}}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  defp call(pid, message) do
    GenServer.call(pid, message, :infinity)
  catch
    :exit, {:noproc, _} -> {:error, :session_lost}
    :exit, {:normal, _} -> {:error, :session_lost}
    :exit, {:shutdown, _} -> {:error, :session_lost}
  end

  defp locked(fun) do
    case :global.trans({__MODULE__, self()}, fun, [node()], 3) do
      :aborted -> {:error, :lock_timeout}
      result -> result
    end
  end
end
