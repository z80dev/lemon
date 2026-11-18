defmodule LemonControlPlane.Methods.SessionLifecycleFence do
  @moduledoc """
  Shared admission fence and failure projection for destructive session
  lifecycle methods (`sessions.reset`, `sessions.delete`).

  The operation runs only while `LemonRouter.with_session_lifecycle_fence/3`
  holds the session's durable lifecycle fence and has proven it idle; the
  operation receives the fence generation and binds its mutation to it.
  Refusals before the operation report `mutationMayHaveApplied: false`. An
  outcome that cannot be verified is reported with `retrySafe: false` and is
  never retried; raw exception terms never reach the wire.
  """

  @doc "Run `fun` under the session's lifecycle fence; exceptions are unknown outcomes."
  @spec run(binary(), :reset | :delete, (String.t() -> result)) :: result | {:error, atom()}
        when result: term()
  def run(session_key, operation, fun) do
    LemonRouter.with_session_lifecycle_fence(session_key, operation, fun)
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _kind, _reason -> {:error, :outcome_unknown}
  end

  @doc "Project a fenced lifecycle failure; `noun` names the operation (\"reset\", \"deletion\")."
  @spec failure(term(), String.t()) :: {:error, {atom(), String.t(), map()}}
  def failure(:session_busy, noun) do
    refused(
      :conflict,
      "Session has an active, queued or unresolved run; stop it before #{noun}",
      "session_busy"
    )
  end

  def failure(:lifecycle_in_progress, _noun) do
    refused(
      :conflict,
      "A reset or deletion of this session is already in progress",
      "lifecycle_in_progress"
    )
  end

  # The fence was released before the mutation started: nothing was changed.
  def failure(:fence_lost, noun) do
    refused(
      :unavailable,
      "The session's lifecycle fence was lost; no session #{noun} was applied",
      "unavailable"
    )
  end

  def failure(:unavailable, noun) do
    refused(
      :unavailable,
      "Run admission state is unavailable; no session #{noun} was applied",
      "unavailable"
    )
  end

  def failure(:outcome_unknown, noun) do
    {:error,
     {:unavailable, "Session #{noun} outcome is unknown; reconcile before retrying",
      %{"reason" => "outcome_unknown", "retrySafe" => false, "mutationMayHaveApplied" => true}}}
  end

  # The lifecycle service restored recoverable state before a definite failure.
  def failure(_reason, noun) do
    {:error,
     {:internal_error, "Session #{noun} failed; prior state was restored",
      %{"reason" => "#{noun}_failed", "retrySafe" => false, "mutationMayHaveApplied" => false}}}
  end

  defp refused(code, message, reason) do
    {:error,
     {code, message,
      %{"reason" => reason, "retrySafe" => true, "mutationMayHaveApplied" => false}}}
  end
end
