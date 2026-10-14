defmodule CodingAgent.Eval.KernelSupervisor do
  @moduledoc """
  Supervises `eval` kernel slots (`CodingAgent.Eval.Kernel`), one per
  `{owner, language}` and registered in `CodingAgent.Eval.Registry`.

  The owner is the coding session id, or `{:cwd, expanded_cwd}` for callers
  without a session. A slot monitors its owning session pid and kills its
  kernel when that session exits.
  """

  use DynamicSupervisor

  alias CodingAgent.Eval.Kernel

  @registry CodingAgent.Eval.Registry

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Returns the slot for `key`, starting it with `opts` (see
  `CodingAgent.Eval.Kernel.start_link/1`) when none is registered.
  """
  @spec ensure_slot(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_slot(key, opts) do
    case lookup(key) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        opts = Keyword.merge(opts, key: key, name: {:via, Registry, {@registry, key}})

        case DynamicSupervisor.start_child(__MODULE__, {Kernel, opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "Looks up the slot registered for `key`."
  @spec lookup(term()) :: {:ok, pid()} | :error
  def lookup(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end
end
