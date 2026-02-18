defmodule LemonPoker.MatchControl do
  @moduledoc false

  @pause_index 1
  @stop_index 2

  @type t :: :atomics.atomic()

  @spec new() :: t()
  def new do
    ref = :atomics.new(2, signed: false)
    :atomics.put(ref, @pause_index, 0)
    :atomics.put(ref, @stop_index, 0)
    ref
  end

  @spec pause(t()) :: :ok
  def pause(ref) do
    :atomics.put(ref, @pause_index, 1)
    :ok
  end

  @spec resume(t()) :: :ok
  def resume(ref) do
    :atomics.put(ref, @pause_index, 0)
    :ok
  end

  @spec stop(t()) :: :ok
  def stop(ref) do
    :atomics.put(ref, @stop_index, 1)
    :ok
  end

  @spec paused?(t()) :: boolean()
  def paused?(ref), do: :atomics.get(ref, @pause_index) == 1

  @spec stopped?(t()) :: boolean()
  def stopped?(ref), do: :atomics.get(ref, @stop_index) == 1
end
