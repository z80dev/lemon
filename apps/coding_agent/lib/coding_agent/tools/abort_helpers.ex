defmodule CodingAgent.Tools.AbortHelpers do
  @moduledoc """
  Shared abort-signal helpers used across tool implementations.

  Provides two styles of abort checking:

    * `aborted?/1` – boolean check, useful in `if` guards
    * `check_abort/1` – returns `:ok | {:error, "Operation aborted"}`,
      useful in `with` chains
    * `check_aborted/1` – returns `:ok | {:error, :aborted}`,
      used by tools that pattern-match on the atom
  """

  alias AgentCore.AbortSignal

  @doc """
  Returns `true` when the signal has been aborted, `false` otherwise.
  Safely handles `nil` (no signal).
  """
  @spec aborted?(reference() | nil) :: boolean()
  def aborted?(nil), do: false
  def aborted?(signal), do: AbortSignal.aborted?(signal)

  @doc """
  Returns `:ok` when the signal has not been aborted,
  or `{:error, "Operation aborted"}` when it has.
  Safely handles `nil` and non-reference values.
  """
  @spec check_abort(reference() | nil) :: :ok | {:error, String.t()}
  def check_abort(nil), do: :ok

  def check_abort(signal) when is_reference(signal) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      :ok
    end
  end

  def check_abort(_), do: :ok

  @doc """
  Returns `:ok` when the signal has not been aborted,
  or `{:error, :aborted}` when it has.
  Safely handles `nil` and non-reference values.
  """
  @spec check_aborted(reference() | nil) :: :ok | {:error, :aborted}
  def check_aborted(nil), do: :ok

  def check_aborted(signal) when is_reference(signal) do
    if AbortSignal.aborted?(signal) do
      {:error, :aborted}
    else
      :ok
    end
  end

  def check_aborted(_), do: :ok
end
