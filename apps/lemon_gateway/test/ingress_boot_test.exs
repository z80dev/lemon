defmodule LemonGateway.IngressBootTest do
  use ExUnit.Case, async: false

  alias LemonCore.Config.Modular
  alias LemonGateway.Sms.{InboxStore, TwilioSignature}
  alias LemonGateway.{IngressSupervisor, TransportSupervisor, Voice}
  alias LemonGateway.Transports.Webhook

  @example Path.expand("../../../examples/config.example.toml", __DIR__)
  @ingress_off "[gateway.ingress]\nenabled = false"
  @ingress_on "[gateway.ingress]\nenabled = true"
  @ingress_env "LEMON_GATEWAY_INGRESS_ENABLED"
  @env_vars ~w(HOME LEMON_GATEWAY_INGRESS_ENABLED LEMON_GATEWAY_ENABLE_WEBHOOK
               LEMON_SMS_WEBHOOK_ENABLED LEMON_SMS_WEBHOOK_PORT LEMON_SMS_WEBHOOK_BIND
               TWILIO_AUTH_TOKEN TWILIO_WEBHOOK_URL)
  @sms_listener LemonGateway.Sms.WebhookServer
  @voice_listener Voice.Server
  @token "local-ingress-test-token"

  setup do
    running? = List.keymember?(Application.started_applications(), :lemon_gateway, 0)
    saved_env = Enum.map(@env_vars, &{&1, System.get_env(&1)})

    saved_app_env =
      [
        {:lemon_core, :gateway_test_config},
        {:lemon_gateway, :transports},
        {:lemon_gateway, :voice_ip}
      ]
      |> Enum.map(fn {app, key} -> {app, key, Application.fetch_env(app, key)} end)

    home = Path.join(System.tmp_dir!(), "lemon_ingress_#{System.unique_integer([:positive])}")
    path = Path.join(home, ".lemon/config.toml")
    File.mkdir_p!(Path.dirname(path))

    on_exit(fn ->
      _ = Application.stop(:lemon_gateway)

      Enum.each(saved_app_env, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)

      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      LemonCore.ConfigCache.clear()
      File.rm_rf!(home)
      if running?, do: assert({:ok, _} = Application.ensure_all_started(:lemon_gateway))
    end)

    _ = Application.stop(:lemon_gateway)
    Enum.each(@env_vars, &System.delete_env/1)
    Enum.each(saved_app_env, fn {app, key, _} -> Application.delete_env(app, key) end)
    System.put_env("HOME", home)
    LemonCore.ConfigCache.clear()

    example = File.read!(@example)
    assert example =~ @ingress_off

    %{
      path: path,
      example: example,
      enabled_example: String.replace(example, @ingress_off, @ingress_on)
    }
  end

  test "shipped config defaults to execution-only", %{path: path, example: example} do
    boot_gateway(path, example)
    refute Process.whereis(IngressSupervisor)
  end

  test "environment can enable ingress on the shipped default", %{path: path, example: example} do
    System.put_env(@ingress_env, "true")
    boot_gateway(path, example)
    assert is_pid(Process.whereis(IngressSupervisor))
    assert_no_other_listeners(nil)
  end

  test "environment can disable TOML-enabled ingress", %{path: path, enabled_example: config} do
    System.put_env(@ingress_env, "false")
    boot_gateway(path, config)
    refute Process.whereis(IngressSupervisor)
  end

  test "gateway ingress rejects a non-table, non-boolean flag and unknown keys" do
    for {ingress, error} <- [
          {true, "gateway.ingress: must be a table"},
          {%{"enabled" => "true"}, "gateway.ingress.enabled: must be a boolean"},
          {%{"enable" => true}, "gateway.ingress: only the enabled key is supported"}
        ] do
      assert {:error, errors} = Modular.validate_settings(%{"gateway" => %{"ingress" => ingress}})
      assert error in errors
    end
  end

  test "TOML-only generic webhook accepts a bearer-authenticated run", %{
    path: path,
    enabled_example: config
  } do
    config = String.replace(config, "enable_webhook = false", "enable_webhook = true")

    boot_gateway(
      path,
      config <>
        """

        [gateway.webhook]
        port = 0

        [gateway.webhook.integrations.ingress-smoke]
        token = "#{@token}"
        mode = "async"
        agent_id = "default"
        """
    )

    assert {:ok, started} = Application.ensure_all_started(:lemon_router)
    on_exit(fn -> Enum.each(Enum.reverse(started), &Application.stop/1) end)

    assert_no_other_listeners(Webhook)
    port = listener_port(TransportSupervisor, Webhook)
    body = Jason.encode!(%{prompt: "Ingress smoke test"})
    assert {401, _} = post(port, "/webhooks/ingress-smoke", "application/json", body, [])

    assert {202, response} =
             post(port, "/webhooks/ingress-smoke", "application/json", body,
               authorization: "Bearer #{@token}"
             )

    assert %{"status" => "accepted", "run_id" => run_id} = Jason.decode!(response)
    assert is_binary(run_id) and run_id != ""
    _ = LemonCore.RouterBridge.abort_run(run_id)
  end

  test "TOML-only SMS accepts and stores a signed message", %{path: path, enabled_example: config} do
    url = "https://sms.example.com/webhooks/twilio/sms"
    port = unused_port()

    boot_gateway(
      path,
      config <>
        """

        [gateway.sms]
        webhook_enabled = true
        webhook_port = #{port}
        webhook_url = "#{url}"
        auth_token = "#{@token}"
        """
    )

    assert_no_other_listeners(@sms_listener)
    assert ^port = listener_port(IngressSupervisor, @sms_listener)
    sid = "SM-ingress-#{System.unique_integer([:positive])}"
    on_exit(fn -> InboxStore.delete(sid) end)
    params = %{"MessageSid" => sid, "Body" => "Your code is 123456"}

    assert {403, _} = post_form(port, "/webhooks/twilio/sms", params, [])
    assert InboxStore.get(sid) == nil

    assert {200, "<Response></Response>"} =
             post_form(port, "/webhooks/twilio/sms", params, twilio_headers(url, params))

    assert %{"message_sid" => ^sid, "body" => "Your code is 123456"} = InboxStore.get(sid)
  end

  test "TOML-only voice accepts a signed call and returns streaming TwiML", %{
    path: path,
    enabled_example: config
  } do
    origin = "https://voice.example.com"
    port = unused_port()

    boot_gateway(
      path,
      config <>
        """

        [gateway.voice]
        enabled = true
        websocket_port = #{port}
        public_url = "#{origin}"
        twilio_auth_token = "#{@token}"
        """
    )

    assert_no_other_listeners(@voice_listener)
    assert ^port = listener_port(IngressSupervisor, @voice_listener)
    route = "/webhooks/twilio/voice"
    params = %{"CallSid" => "CA-smoke"}
    assert {403, _} = post_form(port, route, params, [])
    assert {200, twiml} = post_form(port, route, params, twilio_headers(origin <> route, params))
    assert twiml =~ ~s(<Stream url="wss://voice.example.com/webhooks/twilio/voice/stream">)
    assert twiml =~ ~s(name="token" value=")
  end

  defp boot_gateway(path, config) do
    File.write!(path, config)
    assert {:ok, _} = Application.ensure_all_started(:lemon_gateway)
  end

  defp assert_no_other_listeners(enabled) do
    for {supervisor, id} <- [
          {IngressSupervisor, @sms_listener},
          {IngressSupervisor, @voice_listener},
          {TransportSupervisor, Webhook}
        ],
        id != enabled do
      refute List.keymember?(Supervisor.which_children(supervisor), id, 0)
    end
  end

  defp listener_port(supervisor, id) do
    assert {^id, pid, :supervisor, _} = List.keyfind(Supervisor.which_children(supervisor), id, 0)
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp unused_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp twilio_headers(url, params),
    do: [{:"x-twilio-signature", TwilioSignature.signature(@token, url, params)}]

  defp post_form(port, route, params, headers) do
    post(port, route, "application/x-www-form-urlencoded", URI.encode_query(params), headers)
  end

  defp post(port, route, type, body, headers) do
    headers = Enum.map(headers, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
    request = {~c"http://127.0.0.1:#{port}#{route}", headers, to_charlist(type), body}

    assert {:ok, {{_, status, _}, _, response}} =
             :httpc.request(:post, request, [timeout: 5_000], body_format: :binary)

    {status, response}
  end
end
