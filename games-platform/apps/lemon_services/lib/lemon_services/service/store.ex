defmodule LemonServices.Service.Store do
  @moduledoc """
  ETS-backed store for service definitions.

  This store holds the static and runtime service definitions.
  It is separate from the Registry, which tracks running processes.
  """
  use GenServer

  alias LemonServices.Service.Definition

  @table :lemon_services_definitions

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Lists all registered service definitions.
  """
  @spec list_definitions() :: [Definition.t()]
  def list_definitions do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, definition} -> definition end)
  end

  @doc """
  Gets a service definition by ID.
  """
  @spec get_definition(atom()) :: {:ok, Definition.t()} | {:error, :not_found}
  def get_definition(id) when is_atom(id) do
    case :ets.lookup(@table, id) do
      [{^id, definition}] -> {:ok, definition}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Registers a service definition.
  """
  @spec register_definition(Definition.t()) :: :ok | {:error, String.t()}
  def register_definition(%Definition{} = definition) do
    case Definition.validate(definition) do
      :ok ->
        :ets.insert(@table, {definition.id, definition})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Unregisters a service definition.
  """
  @spec unregister_definition(atom()) :: :ok
  def unregister_definition(id) when is_atom(id) do
    :ets.delete(@table, id)
    :ok
  end

  @doc """
  Checks if a definition exists.
  """
  @spec definition_exists?(atom()) :: boolean()
  def definition_exists?(id) when is_atom(id) do
    case :ets.lookup(@table, id) do
      [{^id, _}] -> true
      [] -> false
    end
  end

  # Server Callbacks

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
