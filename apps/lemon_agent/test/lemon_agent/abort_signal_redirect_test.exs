defmodule LemonAgent.AbortSignalRedirectTest do
  @moduledoc """
  Tests for the redirect bit on LemonAgent.AbortSignal.

  The redirect state lives alongside — not inside — the abort bit: it must
  never change what `aborted?/1` reports, since that predicate means "stop
  everything" to the loop and to every tool that polls it.
  """
  use ExUnit.Case, async: true

  alias LemonAgent.AbortSignal

  test "request_redirect sets only the redirect bit" do
    signal = AbortSignal.new()

    refute AbortSignal.redirect_requested?(signal)
    assert :ok = AbortSignal.request_redirect(signal)

    assert AbortSignal.redirect_requested?(signal)
    refute AbortSignal.aborted?(signal)
  end

  test "abort does not set or clear the redirect bit" do
    signal = AbortSignal.new()

    AbortSignal.abort(signal)
    assert AbortSignal.aborted?(signal)
    refute AbortSignal.redirect_requested?(signal)

    AbortSignal.request_redirect(signal)
    assert AbortSignal.aborted?(signal)
    assert AbortSignal.redirect_requested?(signal)
  end

  test "clear_redirect clears only the redirect bit" do
    signal = AbortSignal.new()

    AbortSignal.request_redirect(signal)
    AbortSignal.abort(signal)

    assert :ok = AbortSignal.clear_redirect(signal)

    refute AbortSignal.redirect_requested?(signal)
    assert AbortSignal.aborted?(signal)
  end

  test "clear/1 clears both the abort and redirect bits" do
    signal = AbortSignal.new()

    AbortSignal.abort(signal)
    AbortSignal.request_redirect(signal)

    assert :ok = AbortSignal.clear(signal)

    refute AbortSignal.aborted?(signal)
    refute AbortSignal.redirect_requested?(signal)
  end

  test "redirect bits are independent across signals" do
    signal1 = AbortSignal.new()
    signal2 = AbortSignal.new()

    AbortSignal.request_redirect(signal1)

    assert AbortSignal.redirect_requested?(signal1)
    refute AbortSignal.redirect_requested?(signal2)
  end

  test "nil signal is a no-op for all redirect functions" do
    assert :ok = AbortSignal.request_redirect(nil)
    refute AbortSignal.redirect_requested?(nil)
    assert :ok = AbortSignal.clear_redirect(nil)
  end

  test "request_redirect is idempotent" do
    signal = AbortSignal.new()

    AbortSignal.request_redirect(signal)
    AbortSignal.request_redirect(signal)

    assert AbortSignal.redirect_requested?(signal)
    AbortSignal.clear_redirect(signal)
    refute AbortSignal.redirect_requested?(signal)
  end
end
