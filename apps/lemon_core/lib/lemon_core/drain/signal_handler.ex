defmodule LemonCore.Drain.SignalHandler do
  @moduledoc """
  `:erl_signal_server` handler that replaces OTP's `:erl_signal_handler`:
  SIGTERM requests a drained stop (`LemonCore.Drain.request_stop/1`); every
  other signal keeps OTP's default behaviour.
  """

  @behaviour :gen_event

  @impl true
  def init(_args) do
    {:ok, otp_state} = :erl_signal_handler.init([])
    {:ok, otp_state}
  end

  @impl true
  def handle_event(:sigterm, state) do
    LemonCore.Drain.request_stop(reason: :sigterm)
    {:ok, state}
  end

  def handle_event(signal, state), do: :erl_signal_handler.handle_event(signal, state)

  @impl true
  def handle_call(request, state), do: :erl_signal_handler.handle_call(request, state)

  @impl true
  def handle_info(message, state), do: :erl_signal_handler.handle_info(message, state)
end
