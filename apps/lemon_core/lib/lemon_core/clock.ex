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

  @doc """
  Get the current time in seconds.
  """
  @spec now_sec() :: non_neg_integer()
  def now_sec do
    System.system_time(:second)
  end

  @doc """
  Get the current UTC datetime.
  """
  @spec now_utc() :: DateTime.t()
  def now_utc do
    DateTime.utc_now()
  end

  @doc """
  Convert milliseconds to a DateTime.

  ## Examples

      iex> dt = LemonCore.Clock.from_ms(1_700_000_000_000)
      iex> dt.year
      2023

  """
  @spec from_ms(ms :: non_neg_integer()) :: DateTime.t()
  def from_ms(ms) do
    DateTime.from_unix!(ms, :millisecond)
  end

  @doc """
  Convert a DateTime to milliseconds.

  ## Examples

      iex> dt = DateTime.from_unix!(1_700_000_000, :second)
      iex> LemonCore.Clock.to_ms(dt)
      1_700_000_000_000

  """
  @spec to_ms(datetime :: DateTime.t()) :: non_neg_integer()
  def to_ms(datetime) do
    DateTime.to_unix(datetime, :millisecond)
  end

  @doc """
  Check if a timestamp has expired given a TTL in milliseconds.

  ## Examples

      iex> old_ts = LemonCore.Clock.now_ms() - 10_000
      iex> LemonCore.Clock.expired?(old_ts, 5_000)
      true

  """
  @spec expired?(timestamp_ms :: non_neg_integer(), ttl_ms :: non_neg_integer()) :: boolean()
  def expired?(timestamp_ms, ttl_ms) do
    now_ms() - timestamp_ms > ttl_ms
  end

  @doc """
  Calculate the time elapsed since a timestamp in milliseconds.
  """
  @spec elapsed_ms(timestamp_ms :: non_neg_integer()) :: integer()
  def elapsed_ms(timestamp_ms) do
    now_ms() - timestamp_ms
  end
end
