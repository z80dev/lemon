defmodule LemonControlPlane.Methods.SessionsFork do
  @moduledoc "Forks a native session and registers its independent durable child."
  @behaviour LemonControlPlane.Method

  alias LemonCore.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions
  alias LemonCore.{SessionKey, SessionLifecycle}

  @impl true
  def name, do: "sessions.fork"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, source, cwd} <- NativeSessions.target(params),
         {:ok, entry_id} <- entry_id(params),
         {:ok, agent_id} <- SessionLifecycle.fork_agent_id(source) do
      destination =
        SessionKey.channel_peer(%{
          agent_id: agent_id,
          channel_id: "fork",
          account_id: "local",
          peer_kind: :unknown,
          peer_id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        })

      with {:ok, _} <- NativeSessions.string(%{"sessionKey" => destination}, "sessionKey", 1024) do
        args =
          if entry_id,
            do: [source, cwd, destination, [entry_id: entry_id]],
            else: [source, cwd, destination]

        case AgentRuntime.call(:session_fork, args, {:error, :outcome_unknown}) do
          :ok ->
            case SessionLifecycle.register_fork(source, destination) do
              :ok -> {:ok, %{"sessionKey" => destination, "sourceSessionKey" => source}}
              {:error, _} -> uncertain(destination, source)
            end

          {:error, :outcome_unknown} ->
            uncertain(destination, source)

          {:error, reason} ->
            NativeSessions.failure(reason)

          _ ->
            uncertain(destination, source)
        end
      end
    else
      {:error, {_, _, _}} = error -> error
      {:error, reason} -> NativeSessions.failure(reason)
    end
  end

  defp entry_id(%{"entryId" => _} = params), do: NativeSessions.string(params, "entryId", 256)
  defp entry_id(_params), do: {:ok, nil}

  defp uncertain(destination, source) do
    {:error,
     {:unavailable, "Fork outcome requires reconciliation; do not retry automatically",
      %{"sessionKey" => destination, "sourceSessionKey" => source, "retrySafe" => false}}}
  end
end
