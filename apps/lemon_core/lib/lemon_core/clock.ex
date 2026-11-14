defmodule LemonCore.Clock do
  @moduledoc """
  Time utilities for Lemon.

  Provides consistent time handling across the umbrella.
  """

  @doc """
  Get the current time in milliseconds.
  """
  @spec now_ms() :: non_neg_integer()
  def now_ms do
    System.system_time(:millisecond)
  end
end
