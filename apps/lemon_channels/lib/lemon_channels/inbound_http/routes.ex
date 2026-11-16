defmodule LemonChannels.InboundHttp.Routes do
  @moduledoc false

  use GenServer

  require Logger

  @snapshot_key {__MODULE__, :snapshot}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register(segment, handler) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:register, segment, handler})
    end
  end

  def handlers do
    case :persistent_term.get(@snapshot_key, nil) do
      {owner, handlers} ->
        if Process.whereis(__MODULE__) == owner, do: handlers, else: %{}

      nil ->
        %{}
    end
  end

  @impl true
  def init(_opts) do
    :persistent_term.put(@snapshot_key, {self(), %{}})
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, segment, handler}, _from, handlers) do
    existing = Map.get(handlers, segment)

    if existing != nil and existing != handler do
      Logger.warning(
        "inbound http segment #{inspect(segment)} re-registered: " <>
          "#{inspect(existing)} replaced by #{inspect(handler)}; " <>
          "requests to /#{segment} will now go to the latter"
      )
    end

    handlers =
      if existing == handler do
        handlers
      else
        updated = Map.put(handlers, segment, handler)
        :persistent_term.put(@snapshot_key, {self(), updated})
        updated
      end

    {:reply, :ok, handlers}
  end
end
