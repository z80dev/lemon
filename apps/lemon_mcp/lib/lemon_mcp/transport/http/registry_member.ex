defmodule LemonMCP.Transport.HTTP.RegistryMember do
  @moduledoc false

  use GenServer

  @entries_key {__MODULE__, :entries}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  @spec supervisors() :: [Supervisor.supervisor()]
  def supervisors do
    update_entries(fn entries ->
      live_entries = Enum.filter(entries, &entry_live?/1)

      supervisors =
        live_entries
        |> Enum.sort_by(&elem(&1, 0), :desc)
        |> Enum.map(&elem(&1, 1))

      {supervisors, live_entries}
    end)
  end

  @impl true
  def init(opts) do
    entry = {
      Keyword.fetch!(opts, :generation),
      Keyword.fetch!(opts, :supervisor),
      self()
    }

    register(entry)
    {:ok, entry}
  end

  @impl true
  def terminate(_reason, entry) do
    unregister(entry)
    :ok
  end

  defp register({_generation, supervisor, _member} = entry) do
    update_entries(fn entries ->
      entries =
        Enum.reject(entries, fn existing ->
          not entry_live?(existing) or elem(existing, 1) == supervisor
        end)

      {:ok, [entry | entries]}
    end)
  end

  defp unregister(entry) do
    update_entries(fn entries ->
      remaining =
        Enum.reject(entries, fn existing -> existing == entry or not entry_live?(existing) end)

      {:ok, remaining}
    end)
  end

  defp entry_live?({_generation, supervisor, member}) do
    Process.alive?(supervisor) and Process.alive?(member)
  end

  defp update_entries(fun) do
    lock = {{__MODULE__, :entries, node()}, self()}

    :global.trans(
      lock,
      fn ->
        entries = :persistent_term.get(@entries_key, [])
        {result, updated_entries} = fun.(entries)
        :persistent_term.put(@entries_key, updated_entries)
        result
      end,
      [node()]
    )
  end
end
