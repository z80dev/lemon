defmodule LemonBrowser.BackendRegistry do
  @moduledoc """
  Runtime registry for browser execution backends.

  Built-ins always win collisions. Third-party packages can register a backend
  without adding a compile-time dependency to `lemon_browser`.
  """

  @key {__MODULE__, :backends}
  @builtins %{
    local: LemonBrowser.Backends.Local,
    controller: LemonBrowser.Backends.Controller
  }

  @spec register(atom() | String.t(), module()) :: :ok | {:error, term()}
  def register(id, module) when is_atom(module) do
    with {:ok, id} <- normalize_id(id),
         :ok <- validate_backend(module) do
      :global.trans({__MODULE__, :mutation}, fn ->
        if Map.has_key?(@builtins, id) do
          {:error, :builtin_backend}
        else
          put_runtime(Map.put(runtime(), id, module))
          :ok
        end
      end)
    end
  end

  @spec unregister(atom() | String.t()) :: :ok | {:error, term()}
  def unregister(id) do
    with {:ok, id} <- normalize_id(id) do
      :global.trans({__MODULE__, :mutation}, fn ->
        if Map.has_key?(@builtins, id) do
          {:error, :builtin_backend}
        else
          put_runtime(Map.delete(runtime(), id))
          :ok
        end
      end)
    end
  end

  @spec fetch(atom() | String.t()) :: {:ok, module()} | :error
  def fetch(id) do
    case normalize_id(id) do
      {:ok, id} -> Map.fetch(all(), id)
      _error -> :error
    end
  end

  @spec all() :: %{atom() => module()}
  def all, do: Map.merge(runtime(), @builtins)

  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  defp runtime, do: :persistent_term.get(@key, %{})
  defp put_runtime(backends), do: :persistent_term.put(@key, backends)

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

  defp validate_backend(module) do
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
