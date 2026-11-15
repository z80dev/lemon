defmodule LemonBrowser.Registry do
  @moduledoc false

  defmacro __using__(opts) do
    quote do
      @registry_key {__MODULE__, unquote(Keyword.fetch!(opts, :key))}
      @registry_builtins @builtins
      @registry_builtin_error unquote(Keyword.fetch!(opts, :builtin_error))
      @spec register(atom() | String.t(), module()) :: :ok | {:error, term()}
      def register(id, module) when is_atom(module) do
        with {:ok, id} <- normalize_id(id),
             :ok <- validate_module(module) do
          :global.trans(
            {{__MODULE__, :mutation}, self()},
            fn ->
              if Map.has_key?(@registry_builtins, id) do
                {:error, @registry_builtin_error}
              else
                put_runtime(Map.put(runtime(), id, module))
                :ok
              end
            end,
            [node()],
            3
          )
          |> case do
            :aborted -> {:error, :registry_unavailable}
            result -> result
          end
        end
      end

      @spec unregister(atom() | String.t()) :: :ok | {:error, term()}
      def unregister(id) do
        with {:ok, id} <- normalize_id(id) do
          :global.trans(
            {{__MODULE__, :mutation}, self()},
            fn ->
              if Map.has_key?(@registry_builtins, id) do
                {:error, @registry_builtin_error}
              else
                put_runtime(Map.delete(runtime(), id))
                :ok
              end
            end,
            [node()],
            3
          )
          |> case do
            :aborted -> {:error, :registry_unavailable}
            result -> result
          end
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
      def all, do: Map.merge(runtime(), @registry_builtins)

      @spec reset() :: :ok
      def reset do
        :persistent_term.erase(@registry_key)
        :ok
      end

      defp runtime, do: :persistent_term.get(@registry_key, %{})
      defp put_runtime(backends), do: :persistent_term.put(@registry_key, backends)
    end
  end
end
