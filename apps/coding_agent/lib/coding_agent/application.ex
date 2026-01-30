defmodule CodingAgent.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: CodingAgent.SessionRegistry},
      CodingAgent.SessionSupervisor
    ]

    opts = [strategy: :one_for_one, name: CodingAgent.Supervisor]
    case Supervisor.start_link(children, opts) do
      {:ok, _supervisor} = ok ->
        maybe_start_primary_session()
        ok

      other ->
        other
    end
  end

  defp maybe_start_primary_session do
    case Application.get_env(:coding_agent, :primary_session) do
      nil ->
        :ok

      opts when is_list(opts) ->
        case CodingAgent.SessionSupervisor.start_session(opts) do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to start primary session: #{inspect(reason)}")
        end

      other ->
        Logger.warning("Invalid :primary_session config: #{inspect(other)}")
    end
  end
end
