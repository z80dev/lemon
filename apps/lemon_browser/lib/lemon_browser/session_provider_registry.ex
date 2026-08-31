defmodule LemonBrowser.SessionProviderRegistry do
  @moduledoc "Runtime registry for hosted CDP session providers."

  @key {__MODULE__, :providers}
  @builtins %{
    browserbase: LemonBrowser.SessionProviders.Browserbase,
    browser_use: LemonBrowser.SessionProviders.BrowserUse,
    firecrawl: LemonBrowser.SessionProviders.Firecrawl
  }

  def register(id, module) when is_atom(module) do
    with {:ok, id} <- normalize_id(id),
         :ok <- validate_provider(module) do
      :global.trans({__MODULE__, :mutation}, fn ->
        if Map.has_key?(@builtins, id) do
          {:error, :builtin_provider}
        else
          put_runtime(Map.put(runtime(), id, module))
          :ok
        end
      end)
    end
  end

  def unregister(id) do
    with {:ok, id} <- normalize_id(id) do
      :global.trans({__MODULE__, :mutation}, fn ->
        if Map.has_key?(@builtins, id) do
          {:error, :builtin_provider}
        else
          put_runtime(Map.delete(runtime(), id))
          :ok
        end
      end)
    end
  end

  def fetch(id) do
    case normalize_id(id) do
      {:ok, normalized} -> Map.fetch(all(), normalized)
      _ -> :error
    end
  end

  def all, do: Map.merge(runtime(), @builtins)

  def status do
    all()
    |> Enum.sort_by(fn {id, _module} -> id end)
    |> Enum.map(fn {id, module} ->
      %{id: id, available: module.available?(), status: module.status()}
    end)
  end

  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  defp runtime, do: :persistent_term.get(@key, %{})
  defp put_runtime(value), do: :persistent_term.put(@key, value)

  defp normalize_id(id) when is_atom(id), do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    normalized = id |> String.trim() |> String.downcase() |> String.replace("-", "_")

    case Enum.find(Map.keys(all()), &(Atom.to_string(&1) == normalized)) do
      nil -> {:error, :invalid_provider_id}
      existing -> {:ok, existing}
    end
  end

  defp normalize_id(_), do: {:error, :invalid_provider_id}

  defp validate_provider(module) do
    required = [:id, :available?, :create_session, :close_session, :status]

    if Code.ensure_loaded?(module) and
         Enum.all?(required, fn
           :create_session -> function_exported?(module, :create_session, 2)
           :close_session -> function_exported?(module, :close_session, 2)
           callback -> function_exported?(module, callback, 0)
         end) do
      :ok
    else
      {:error, :invalid_provider}
    end
  end
end
