defmodule LemonControlPlane.Methods.RunOutcome do
  @moduledoc false

  def aborted?(error) when error in [:aborted, :user_requested, :interrupted], do: true

  def aborted?(error) when is_binary(error) do
    label = String.downcase(error)
    label in ["aborted", "user_requested", "interrupted"] or String.contains?(label, "abort")
  end

  def aborted?(error) when is_map(error),
    do: aborted?(Map.get(error, :error, Map.get(error, "error")))

  def aborted?(_), do: false
end
