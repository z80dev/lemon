defmodule CodingAgent.Eval.KernelSupervisor do
  @moduledoc """
  Supervises `eval` kernel slots (`CodingAgent.Eval.Kernel`), one per
  `{owner, language}` and registered in `CodingAgent.Eval.Registry`.

  The owner is the durable coding session id, or `{:cwd, expanded_cwd}` for
  standalone callers. Successful executor turns explicitly detach and later
  rebind the transient Session pid; unexpected owner death still kills the kernel.
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
        with :ok <- CodingAgent.ToolResources.bind(pid, Keyword.get(opts, :owner_pid)),
             do: {:ok, pid}

      :error ->
        value = %{
          session_key: Keyword.get(opts, :session_key),
          started_at: System.monotonic_time()
        }

        opts = Keyword.merge(opts, key: key, name: {:via, Registry, {@registry, key, value}})

        case DynamicSupervisor.start_child(__MODULE__, {Kernel, opts}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            with :ok <- CodingAgent.ToolResources.bind(pid, Keyword.get(opts, :owner_pid)),
                 do: {:ok, pid}

          {:error, reason} ->
            {:error, reason}
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
