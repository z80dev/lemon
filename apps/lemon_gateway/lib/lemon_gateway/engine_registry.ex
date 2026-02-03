defmodule LemonGateway.EngineRegistry do
  @moduledoc false
  use GenServer

  @type engine_id :: String.t()
  @type engine_mod :: module()

  @reserved_ids ~w(default help)
  @id_regex ~r/^[a-z][a-z0-9_-]*$/

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec list_engines() :: [engine_id()]
  def list_engines, do: GenServer.call(__MODULE__, :list)

  @spec get_engine!(engine_id()) :: engine_mod()
  def get_engine!(id), do: GenServer.call(__MODULE__, {:get, id})

  @spec get_engine(engine_id()) :: engine_mod() | nil
  def get_engine(id), do: GenServer.call(__MODULE__, {:get_or_nil, id})

  @doc """
  Iterates all registered engines and calls extract_resume/1 on each until one returns
  a non-nil ResumeToken. Returns `{:ok, token}` if found, `:none` otherwise.
  """
  @spec extract_resume(String.t()) :: {:ok, LemonGateway.Types.ResumeToken.t()} | :none
  def extract_resume(text) do
    GenServer.call(__MODULE__, {:extract_resume, text})
  end

  @impl true
  def init(_opts) do
    engines =
      Application.get_env(:lemon_gateway, :engines, [
        LemonGateway.Engines.Lemon,
        LemonGateway.Engines.Echo,
        LemonGateway.Engines.Codex,
        LemonGateway.Engines.Claude
      ])

    map =
      engines
      |> Enum.reduce(%{}, fn mod, acc ->
        id = mod.id()
        validate_id!(id)
        Map.put(acc, id, mod)
      end)

    {:ok, map}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Map.keys(state), state}
  end

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state, id) do
      {:ok, mod} -> {:reply, mod, state}
      :error -> raise ArgumentError, "unknown engine id: #{inspect(id)}"
    end
  end

  def handle_call({:get_or_nil, id}, _from, state) do
    {:reply, Map.get(state, id), state}
  end

  def handle_call({:extract_resume, text}, _from, state) do
    result =
      state
      |> Map.values()
      |> Enum.find_value(:none, fn mod ->
        case mod.extract_resume(text) do
          %LemonGateway.Types.ResumeToken{} = token -> {:ok, token}
          _ -> nil
        end
      end)

    {:reply, result, state}
  end

  defp validate_id!(id) when id in @reserved_ids do
    raise ArgumentError, "engine id reserved: #{id}"
  end

  defp validate_id!(id) do
    if Regex.match?(@id_regex, id) do
      :ok
    else
      raise ArgumentError, "invalid engine id: #{inspect(id)}"
    end
  end
end
