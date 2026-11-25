defmodule LemonAgent.Tools.AbortHelpers do
  @moduledoc """
  Shared abort-signal helpers used across tool implementations.

  Provides two styles of abort checking:

    * `aborted?/1` – boolean check, useful in `if` guards
    * `check_abort/1` – returns `:ok | {:error, "Operation aborted"}`,
      useful in `with` chains
  """

  alias LemonAgent.AbortSignal

  @doc """
  Returns `true` when the signal has been aborted, `false` otherwise.
  Safely handles `nil` (no signal).
  """
  @spec aborted?(AbortSignal.t() | nil) :: boolean()
  def aborted?(signal), do: AbortSignal.aborted?(signal)

  @doc """
  Returns `:ok` when the signal has not been aborted,
  or `{:error, "Operation aborted"}` when it has.
  Safely handles `nil` (no signal).
  """
  @spec check_abort(AbortSignal.t() | nil) :: :ok | {:error, String.t()}
  def check_abort(nil), do: :ok

  def check_abort(signal) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      :ok
    end
  end
end
