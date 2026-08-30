defmodule CodingAgent.BackgroundRun.Registry do
  @moduledoc false

  @registry __MODULE__

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(id), do: {:via, Registry, {@registry, id}}

  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _} | _] -> {:ok, pid}
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
