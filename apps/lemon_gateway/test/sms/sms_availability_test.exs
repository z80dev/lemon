defmodule LemonGateway.Sms.AvailabilityTest do
  @moduledoc """
  The SMS inbox, its listener and therefore the agent SMS tools exist only in
  deployments with usable SMS ingress: webhook enabled and an auth token.
  """
  use ExUnit.Case, async: false

  alias LemonGateway.Sms.Inbox

  @env_vars ~w(TWILIO_AUTH_TOKEN LEMON_SMS_WEBHOOK_ENABLED LEMON_SMS_WEBHOOK_PORT)
  @replacement_key :"Elixir.LemonGateway.Config"

  setup do
    LemonGateway.Test.AppIsolation.isolate_gateway([@replacement_key], system_env: @env_vars)
    Enum.each(@env_vars, &System.delete_env/1)

    :ok
  end

  defp boot_with_ingress do
    Application.put_env(:lemon_gateway, @replacement_key, %{
      max_concurrent_runs: 2,
      ingress: %{enabled: true}
    })

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    assert is_pid(Process.whereis(LemonGateway.IngressSupervisor))
  end

  test "webhook/voice-only ingress (SMS not enabled) starts no inbox and offers no SMS tools" do
    System.put_env("TWILIO_AUTH_TOKEN", "sms-test-token")
    boot_with_ingress()

    assert Process.whereis(Inbox) == nil
    assert Process.whereis(LemonGateway.Sms.WebhookServer) == nil
    refute Inbox.available?()
  end

  test "SMS enabled without an auth token starts neither inbox nor listener" do
    System.put_env("LEMON_SMS_WEBHOOK_ENABLED", "true")
    System.put_env("LEMON_SMS_WEBHOOK_PORT", "0")
    boot_with_ingress()

    assert Process.whereis(Inbox) == nil
    assert Process.whereis(LemonGateway.Sms.WebhookServer) == nil
    refute Inbox.available?()
  end

  test "SMS enabled with an auth token starts inbox and listener and is available" do
    System.put_env("LEMON_SMS_WEBHOOK_ENABLED", "true")
    System.put_env("LEMON_SMS_WEBHOOK_PORT", "0")
    System.put_env("TWILIO_AUTH_TOKEN", "sms-test-token")
    boot_with_ingress()

    assert is_pid(Process.whereis(Inbox))
    assert is_pid(Process.whereis(LemonGateway.Sms.WebhookServer))
    assert Inbox.available?()
  end

  test "an inbox process alone (no listener) is not available" do
    System.put_env("LEMON_SMS_WEBHOOK_ENABLED", "true")
    System.put_env("TWILIO_AUTH_TOKEN", "sms-test-token")
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    start_supervised!(Inbox)

    refute Inbox.available?()
  end
end
