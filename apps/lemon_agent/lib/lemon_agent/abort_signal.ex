defmodule LemonAgent.AbortSignal do
  @moduledoc """
  Cooperative cancellation with an atomic level and message-driven wakeups.

  Signals are opaque references holding two atomic slots. They live as long as
  their holders; no global flag table or explicit cleanup is needed.
  `aborted?/1` remains a cheap level check for executing tools.

  Waiters call `subscribe/1` **before** checking the level, then receive
  `{:lemon_abort, signal, kind}` where kind is `:abort` or `:redirect`.
  This ordering closes the check-to-wait race. Subscriptions belong to the
  calling process and disappear on its exit; reusable waiters should call
  `unsubscribe/1` when finished.

  Redirect has an independent slot: it interrupts only the in-flight model
  request, not tools. Only `clear_redirect/1` resets that slot; abort is monotonic.
  """

  @registry LemonAgent.AbortSignal.Registry

  @spec new() :: reference()
  def new, do: :atomics.new(2, signed: false)

  @spec subscribe(reference() | nil) :: :ok
  def subscribe(nil), do: :ok

  def subscribe(ref) when is_reference(ref) do
    unless ref in Registry.keys(@registry, self()) do
      {:ok, _} = Registry.register(@registry, ref, nil)
    end

    :ok
  end

  @spec unsubscribe(reference() | nil) :: :ok
  def unsubscribe(nil), do: :ok

  def unsubscribe(ref) when is_reference(ref) do
    Registry.unregister(@registry, ref)
    :ok
  end

  @spec abort(reference()) :: :ok
  def abort(ref) when is_reference(ref) do
    :atomics.put(ref, 1, 1)
    notify(ref, :abort)
  end

  @spec aborted?(reference() | nil) :: boolean()
  def aborted?(nil), do: false
  def aborted?(ref) when is_reference(ref), do: :atomics.get(ref, 1) == 1

  @spec request_redirect(reference() | nil) :: :ok
  def request_redirect(nil), do: :ok

  def request_redirect(ref) when is_reference(ref) do
    :atomics.put(ref, 2, 1)
    notify(ref, :redirect)
  end

  @spec redirect_requested?(reference() | nil) :: boolean()
  def redirect_requested?(nil), do: false
  def redirect_requested?(ref) when is_reference(ref), do: :atomics.get(ref, 2) == 1

  @spec clear_redirect(reference() | nil) :: :ok
  def clear_redirect(nil), do: :ok

  def clear_redirect(ref) when is_reference(ref) do
    :atomics.put(ref, 2, 0)
    :ok
  end

  defp notify(ref, kind) do
    Registry.dispatch(@registry, ref, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:lemon_abort, ref, kind})
    end)

    :ok
  end
end
