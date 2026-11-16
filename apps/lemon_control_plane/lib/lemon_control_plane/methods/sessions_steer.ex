defmodule LemonControlPlane.Methods.SessionsSteer do
  @moduledoc """
  Accepts a stable-ID steer for an exact live native run. Acceptance is journaled
  before acknowledgement. This method never creates or redirects a run; named
  execution must continue through its invocation-bound routing authority.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.NativeSessions
  alias LemonCore.AgentRuntime

  # Operator message policy matches the Agent Hub's 32 KiB input bound.
  @max_prompt_bytes 32 * 1024

  @impl true
  def name, do: "sessions.steer"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) when is_map(params) do
    with {:ok, key} <- NativeSessions.string(params, "sessionKey", 1024),
         {:ok, run_id} <- NativeSessions.string(params, "runId", 256),
         {:ok, id} <- NativeSessions.string(params, "messageId", 256),
         {:ok, prompt} <- NativeSessions.string(params, "prompt", @max_prompt_bytes) do
      case mutate(:session_steer, [key, run_id, prompt, id]) do
        {:ok, %{id: ^id, accepted_after_turn: turn}} when is_integer(turn) and turn >= 0 ->
          {:ok,
           %{
             "sessionKey" => key,
             "runId" => run_id,
             "messageId" => id,
             "acceptedAfterTurn" => turn
           }}

        {:error, reason} ->
          failure(reason)

        _ ->
          failure(:outcome_unknown)
      end
    end
  end

  def handle(_, _), do: NativeSessions.invalid("params must be an object")

  @doc false
  def mutate(function, args) do
    provider = AgentRuntime.provider()

    if provider && Code.ensure_loaded?(provider) &&
         function_exported?(provider, function, length(args)) do
      AgentRuntime.call(function, args, {:error, :outcome_unknown})
    else
      {:error, :unavailable}
    end
  end

  @doc false
  def failure(reason) when reason in [:not_found, :session_not_found] do
    {:error,
     {:not_found, "No matching live session or queued, unbound steer", %{"reason" => "not_found"}}}
  end

  def failure(reason) when reason in [:stale_run, :idle, :not_streaming, :busy] do
    {:error, {:conflict, "The target run is no longer accepting steering", nil}}
  end

  def failure(:forbidden), do: {:error, {:forbidden, "Native steering is not permitted", nil}}

  def failure(:unavailable), do: NativeSessions.failure(:unavailable)
  def failure(_), do: NativeSessions.failure(:outcome_unknown)
end

defmodule LemonControlPlane.Methods.SessionsSteerWithdraw do
  @moduledoc "Withdraws a queued, unbound steer by its journal identity, never a whole run."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.{NativeSessions, SessionsSteer}

  @impl true
  def name, do: "sessions.steer.withdraw"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) when is_map(params) do
    with {:ok, key} <- NativeSessions.string(params, "sessionKey", 1024),
         {:ok, id} <- NativeSessions.string(params, "messageId", 256) do
      case SessionsSteer.mutate(:session_withdraw_steer, [key, id]) do
        :ok -> {:ok, %{"sessionKey" => key, "messageId" => id, "withdrawn" => true}}
        {:error, reason} -> SessionsSteer.failure(reason)
        _ -> SessionsSteer.failure(:outcome_unknown)
      end
    end
  end

  def handle(_, _), do: NativeSessions.invalid("params must be an object")
end

defmodule LemonControlPlane.Methods.SessionsSteerPending do
  @moduledoc """
  Reads queued, unbound steering identities from the native session journal.
  This operator queue view returns bounded previews, not full prompt history.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.NativeSessions
  alias LemonCore.AgentRuntime

  # Queue-panel policy: at most 100 identities with 512-character previews per read.
  @max_items 100
  @preview_chars 512

  @impl true
  def name, do: "sessions.steer.pending"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) when is_map(params) do
    with {:ok, key} <- NativeSessions.string(params, "sessionKey", 1024),
         {:ok, limit} <- NativeSessions.integer(params, "limit", @max_items, 1, @max_items) do
      case AgentRuntime.call(:session_pending_steers, [key], {:error, :unavailable}) do
        {:ok, items} when is_list(items) ->
          projected = items |> Enum.take(limit) |> Enum.map(&project/1)

          if Enum.all?(projected, &is_map/1) do
            {:ok,
             %{
               "sessionKey" => key,
               "items" => projected,
               "truncated" => length(items) > limit
             }}
          else
            NativeSessions.failure(:unavailable)
          end

        _ ->
          NativeSessions.failure(:unavailable)
      end
    end
  end

  def handle(_, _), do: NativeSessions.invalid("params must be an object")

  defp project(%{id: id, text: text, accepted_after_turn: turn})
       when is_binary(id) and is_binary(text) and is_integer(turn) and turn >= 0 do
    with {:ok, _} <- NativeSessions.string(%{"messageId" => id}, "messageId", 256),
         true <- String.valid?(text) do
      %{
        "messageId" => id,
        "preview" => String.slice(text, 0, @preview_chars),
        "acceptedAfterTurn" => turn
      }
    else
      _ -> :invalid
    end
  end

  defp project(_), do: :invalid
end
