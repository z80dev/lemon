defmodule LemonGateway.SecretFailClosedTest do
  @moduledoc """
  An unreadable configured secret must never fall through to a later credential
  (plaintext config, ambient env var, or another stored alias).
  """
  use ExUnit.Case, async: false

  alias LemonGateway.Sms.TwilioSignature

  @gateway_config_key :gateway_test_config
  @env_vars ~w(LEMON_SECRETS_MASTER_KEY TWILIO_AUTH_TOKEN TWILIO_VALIDATE_WEBHOOK
               TWILIO_WEBHOOK_URL OPENAI_API_KEY)
  @ambient_token "ambient-tripwire-token"

  setup do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    old_gateway = Application.get_env(:lemon_core, @gateway_config_key)
    old_openai = Application.get_env(:lemon_gateway, :openai_api_key)
    Application.delete_env(:lemon_gateway, :openai_api_key)
    clear_secrets()

    on_exit(fn ->
      clear_secrets()

      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      if old_gateway,
        do: Application.put_env(:lemon_core, @gateway_config_key, old_gateway),
        else: Application.delete_env(:lemon_core, @gateway_config_key)

      restore_app_env(:openai_api_key, old_openai)
    end)

    :ok
  end

  defp clear_secrets do
    for {ref, _} <- LemonCore.Store.list(LemonCore.Secrets.table()),
        do: LemonCore.Store.delete(LemonCore.Secrets.table(), ref)
  end

  defp corrupt_secret(name),
    do: LemonCore.Store.put(LemonCore.Secrets.table(), {"default", name}, "corrupt")

  defp restore_app_env(key, nil), do: Application.delete_env(:lemon_gateway, key)
  defp restore_app_env(key, value), do: Application.put_env(:lemon_gateway, key, value)

  test "unreadable SMS auth_token_secret does not fall through to ambient TWILIO_AUTH_TOKEN" do
    corrupt_secret("sms_tripwire_token")
    System.put_env("TWILIO_AUTH_TOKEN", @ambient_token)
    start_supervised!(LemonGateway.Sms.Inbox)

    env_key = :gateway_test_config
    original = Application.get_env(:lemon_core, env_key)

    Application.put_env(
      :lemon_core,
      env_key,
      Map.put(Map.new(original || []), :sms, %{auth_token_secret: "sms_tripwire_token"})
    )

    on_exit(fn -> Application.put_env(:lemon_core, env_key, original) end)

    url = "http://www.example.com/webhooks/twilio/sms"
    sid = "SMtrip-#{System.unique_integer([:positive])}"
    params = %{"MessageSid" => sid, "From" => "+15551230100", "To" => "+1555", "Body" => "hi"}

    conn =
      Plug.Test.conn(:post, "/webhooks/twilio/sms", params)
      |> Plug.Conn.put_req_header(
        "x-twilio-signature",
        TwilioSignature.signature(@ambient_token, url, params)
      )
      |> LemonGateway.Sms.WebhookRouter.call([])

    assert conn.status == 403
    assert LemonGateway.Sms.Config.auth_token() == nil
  end

  test "unreadable voice twilio_auth_token_secret does not fall through to ambient env" do
    corrupt_secret("voice_tripwire_token")
    System.put_env("TWILIO_AUTH_TOKEN", @ambient_token)

    Application.put_env(:lemon_core, @gateway_config_key, %{
      voice: %{
        twilio_auth_token_secret: "voice_tripwire_token",
        public_url: "https://voice.example.test"
      }
    })

    params = %{"CallSid" => "CA1", "From" => "+15550000000", "To" => "+15551111111"}
    url = "https://voice.example.test/webhooks/twilio/voice"

    conn =
      Plug.Test.conn(:post, "/webhooks/twilio/voice", params)
      |> Plug.Conn.put_req_header("x-forwarded-host", "voice.example.test")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> Plug.Conn.put_req_header(
        "x-twilio-signature",
        TwilioSignature.signature(@ambient_token, url, params)
      )
      |> LemonGateway.Voice.WebhookRouter.call([])

    assert conn.status == 403
    assert LemonGateway.Voice.Config.twilio_auth_token() == nil
  end

  test "unreadable first AI secret alias does not fall through to a readable second alias" do
    assert {:ok, _} = LemonCore.Secrets.set("OPENAI_API_KEY", "sk-tripwire")
    corrupt_secret("openai_api_key")

    assert LemonGateway.AI.chat_completion("gpt-4o-mini", [%{role: "user", content: "hi"}]) ==
             {:error, :missing_api_key}
  end
end
