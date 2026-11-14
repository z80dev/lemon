defmodule LemonBrowser.SessionProviderRegistry do
  @moduledoc "Runtime registry for hosted CDP session providers."

  @builtins %{
    browserbase: LemonBrowser.SessionProviders.Browserbase,
    browser_use: LemonBrowser.SessionProviders.BrowserUse,
    firecrawl: LemonBrowser.SessionProviders.Firecrawl
  }

  use LemonBrowser.Registry, key: :providers, builtin_error: :builtin_provider

  def status do
    all()
    |> Enum.sort_by(fn {id, _module} -> id end)
    |> Enum.map(fn {id, module} ->
      %{id: id, available: module.available?(), status: module.status()}
    end)
  end

  defp normalize_id(id) when is_atom(id), do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    normalized = id |> String.trim() |> String.downcase() |> String.replace("-", "_")

    case Enum.find(Map.keys(all()), &(Atom.to_string(&1) == normalized)) do
      nil -> {:error, :invalid_provider_id}
      existing -> {:ok, existing}
    end
  end

  defp normalize_id(_), do: {:error, :invalid_provider_id}

  defp validate_module(module) do
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
