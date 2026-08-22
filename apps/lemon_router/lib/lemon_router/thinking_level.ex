defmodule LemonRouter.ThinkingLevel do
  @moduledoc """
  Canonical thinking-level values accepted by router submission and control-plane
  session patches.
  """

  @levels %{
    "off" => :off,
    "minimal" => :minimal,
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "xhigh" => :xhigh
  }

  @allowed_strings Map.keys(@levels) |> Enum.sort()

  @doc "Strings accepted by `sessions.patch` and router submission."
  @spec allowed_strings() :: [String.t()]
  def allowed_strings, do: @allowed_strings

  @doc "Returns true when `level` is a supported string value."
  @spec valid_string?(term()) :: boolean()
  def valid_string?(level) when is_binary(level), do: Map.has_key?(@levels, level)
  def valid_string?(_), do: false

  @doc """
  Normalizes a string thinking level to its router atom, or `nil` when unknown.
  """
  @spec normalize(term()) :: atom() | nil
  def normalize(level) when is_binary(level), do: Map.get(@levels, level)
  def normalize(_), do: nil
end
