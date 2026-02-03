defmodule LemonGateway.CommandRegistry do
  @moduledoc false
  use GenServer

  @type command_name :: String.t()
  @type command_mod :: module()

  @reserved_names ~w(help start stop)
  @name_regex ~r/^[a-z][a-z0-9_]*$/

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec list_commands() :: [command_name()]
  def list_commands, do: GenServer.call(__MODULE__, :list)

  @spec get_command!(command_name()) :: command_mod()
  def get_command!(name), do: GenServer.call(__MODULE__, {:get, name})

  @spec get_command(command_name()) :: command_mod() | nil
  def get_command(name), do: GenServer.call(__MODULE__, {:get_or_nil, name})

  @spec all_commands() :: [{command_name(), command_mod()}]
  def all_commands, do: GenServer.call(__MODULE__, :all)

  @impl true
  def init(_opts) do
    commands =
      Application.get_env(:lemon_gateway, :commands, [
        LemonGateway.Commands.Cancel
      ])

    map =
      commands
      |> Enum.reduce(%{}, fn mod, acc ->
        name = mod.name()
        validate_name!(name)
        Map.put(acc, name, mod)
      end)

    {:ok, map}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Map.keys(state), state}
  end

  def handle_call({:get, name}, _from, state) do
    case Map.fetch(state, name) do
      {:ok, mod} -> {:reply, mod, state}
      :error -> raise ArgumentError, "unknown command: #{inspect(name)}"
    end
  end

  def handle_call({:get_or_nil, name}, _from, state) do
    {:reply, Map.get(state, name), state}
  end

  def handle_call(:all, _from, state) do
    {:reply, Enum.into(state, []), state}
  end

  defp validate_name!(name) when name in @reserved_names do
    raise ArgumentError, "command name reserved: #{name}"
  end

  defp validate_name!(name) do
    if Regex.match?(@name_regex, name) do
      :ok
    else
      raise ArgumentError, "invalid command name: #{inspect(name)}"
    end
  end
end
