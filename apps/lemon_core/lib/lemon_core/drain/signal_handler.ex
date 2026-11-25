defmodule LemonCore.Drain.SignalHandler do
  @moduledoc """
  `:erl_signal_server` handler that replaces OTP's `:erl_signal_handler`:
  SIGTERM runs the zero-arity callback it was installed with (`LemonCore.Drain`
  installs a drained stop); every other signal keeps OTP's default behaviour.
  """

  @behaviour :gen_event

  @impl true
  # `:gen_event.swap_handler/3` passes `{args, terminate_result}`.
  def init({on_sigterm, _swapped}) when is_function(on_sigterm, 0), do: init(on_sigterm)

  def init(on_sigterm) when is_function(on_sigterm, 0) do
    {:ok, otp_state} = :erl_signal_handler.init([])
    {:ok, {on_sigterm, otp_state}}
  end

  @impl true
  def handle_event(:sigterm, {on_sigterm, _otp_state} = state) do
    on_sigterm.()
    {:ok, state}
  end

  def handle_event(signal, {on_sigterm, otp_state}) do
    {:ok, otp_state} = :erl_signal_handler.handle_event(signal, otp_state)
    {:ok, {on_sigterm, otp_state}}
  end

  @impl true
  def handle_call(request, {on_sigterm, otp_state}) do
    {:ok, reply, otp_state} = :erl_signal_handler.handle_call(request, otp_state)
    {:ok, reply, {on_sigterm, otp_state}}
  end

  @impl true
  def handle_info(message, {on_sigterm, otp_state}) do
    {:ok, otp_state} = :erl_signal_handler.handle_info(message, otp_state)
    {:ok, {on_sigterm, otp_state}}
  end
end
