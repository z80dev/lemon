defmodule LemonBrowser.BackendRegistry do
  @moduledoc """
  Runtime registry for browser execution backends.

  Built-ins always win collisions. Third-party packages can register a backend
  without adding a compile-time dependency to `lemon_browser`.
  """

  @builtins %{
    local: LemonBrowser.Backends.Local,
    tern: LemonBrowser.Backends.Tern,
    browserbase: LemonBrowser.Backends.Browserbase,
    browser_use: LemonBrowser.Backends.BrowserUse,
    firecrawl: LemonBrowser.Backends.Firecrawl,
    camofox: LemonBrowser.Backends.Camofox
  }

  use LemonBrowser.Registry, key: :backends, builtin_error: :builtin_backend

  defp normalize_id(id) when is_atom(id), do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    normalized = String.trim(id)

    case Enum.find(Map.keys(all()), &(Atom.to_string(&1) == normalized)) do
      nil when normalized != "" ->
        try do
          {:ok, String.to_existing_atom(normalized)}
        rescue
          ArgumentError -> {:error, :invalid_backend_id}
        end

      nil ->
        {:error, :invalid_backend_id}

      existing ->
        {:ok, existing}
    end
  end

  defp normalize_id(_id), do: {:error, :invalid_backend_id}

  defp validate_module(module) do
    with {:module, _} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :id, 0),
         true <- function_exported?(module, :available?, 0),
         true <- function_exported?(module, :request, 4),
         true <- function_exported?(module, :status, 1) do
      :ok
    else
      _ -> {:error, :invalid_backend}
    end
  end
end
