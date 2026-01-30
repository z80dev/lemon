defmodule CodingAgent.SessionRegistry do
  @moduledoc false

  @registry __MODULE__

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(session_id) when is_binary(session_id) do
    {:via, Registry, {@registry, session_id}}
  end

  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(session_id) when is_binary(session_id) do
    if Process.whereis(@registry) do
      case Registry.lookup(@registry, session_id) do
        [{pid, _value}] -> {:ok, pid}
        [] -> :error
      end
    else
      :error
    end
  end

  @spec list_ids() :: [String.t()]
  def list_ids do
    if Process.whereis(@registry) do
      Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    else
      []
    end
  end
end
