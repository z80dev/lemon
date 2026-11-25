defmodule LemonGateway.WebhookChannelProvenanceTestOrchestrator do
  @behaviour LemonCore.RouterBridge.RunOrchestrator

  def submit(request) do
    send(
      Application.fetch_env!(:lemon_gateway, :webhook_provenance_test_pid),
      {:provenance_submit, request}
    )

    {:ok, request.run_id}
  end
end

defmodule LemonGateway.WebhookChannelProvenanceTest do
  @moduledoc """
  A token-authenticated webhook request, received by the real webhook plug with
  integrations loaded from a real `~/.lemon/config.toml`, reaches the router with
  `webhook` channel provenance derived from the authenticated integration, never
  from the payload. An integration is classified for the group approval floor
  (`peer_kind: :automation`) unless the operator sets
  `trusted_automation = true` on it; the router turns that provenance into the
  floor (`LemonRouter.IngressProvenancePolicyTest`).
  """
  use ExUnit.Case, async: false

  alias LemonCore.RunRequest
  alias LemonGateway.Transports.Webhook
  alias LemonGateway.Transports.Webhook.Idempotency
  alias Plug.Conn
  alias Plug.Test

  @token "provenance-test-token"

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_core)
    if Process.whereis(Idempotency) == nil, do: start_supervised!(Idempotency)

    original_bridge = Application.get_env(:lemon_core, :router_bridge)
    original_pid = Application.get_env(:lemon_gateway, :webhook_provenance_test_pid)
    original_home = System.get_env("HOME")
    original_override = Application.get_env(:lemon_core, :gateway_test_config)
    original_config_path = Application.get_env(:lemon_gateway, :config_path)
    Application.put_env(:lemon_gateway, :webhook_provenance_test_pid, self())

    home =
      Path.join(
        System.tmp_dir!(),
        "lemon_webhook_provenance_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(home, ".lemon"))

    :ok =
      LemonCore.RouterBridge.configure(
        run_orchestrator: LemonGateway.WebhookChannelProvenanceTestOrchestrator,
        router: original_bridge && original_bridge[:router]
      )

    on_exit(fn ->
      LemonCore.ConfigCache.clear()
      restore_env(:lemon_core, :router_bridge, original_bridge)
      restore_env(:lemon_gateway, :webhook_provenance_test_pid, original_pid)
      restore_env(:lemon_core, :gateway_test_config, original_override)
      restore_env(:lemon_gateway, :config_path, original_config_path)

      if original_home,
        do: System.put_env("HOME", original_home),
        else: System.delete_env("HOME")

      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "an authenticated webhook run carries provenance derived from its integration", ctx do
    id = configure(ctx, "")
    request = post_authorized(id, %{prompt: "hello"})

    assert request.origin == :webhook

    assert request.meta[:channel_context] == %{
             channel_id: "webhook",
             account_id: id,
             peer_kind: :automation,
             peer_id: id,
             thread_id: nil
           }
  end

  test "only a literal trusted_automation = true opts an integration out of the floor", ctx do
    trusted = configure(ctx, "trusted_automation = true\n")
    assert post_authorized(trusted, %{prompt: "hello"}).meta.channel_context.peer_kind == :dm

    for setting <- ["trusted_automation = \"true\"\n", "trusted_automation = false\n"] do
      id = configure(ctx, setting)

      assert post_authorized(id, %{prompt: "hello"}).meta.channel_context.peer_kind ==
               :automation,
             "#{inspect(setting)} must not opt out of the approval floor"
    end
  end

  test "payload fields cannot supply or replace the webhook provenance", ctx do
    id = configure(ctx, "")

    request =
      post_authorized(id, %{
        prompt: "hello",
        trusted_automation: true,
        channel_context: %{channel_id: "telegram", peer_kind: :dm},
        metadata: %{channel_context: %{channel_id: "telegram", peer_kind: :dm}},
        meta: %{channel_context: %{channel_id: "telegram", peer_kind: :dm}}
      })

    assert %{channel_id: "webhook", account_id: ^id, peer_kind: :automation} =
             request.meta[:channel_context]
  end

  # Writes one integration into a real global config file that the webhook
  # then reads through the canonical config. Each call uses a fresh home so no
  # cached earlier file can be loaded instead.
  defp configure(ctx, integration_settings) do
    id = "provenance-#{System.unique_integer([:positive])}"
    home = Path.join(ctx.home, id)
    File.mkdir_p!(Path.join(home, ".lemon"))

    File.write!(Path.join(home, ".lemon/config.toml"), """
    [gateway.webhook.integrations.#{id}]
    token = "#{@token}"
    agent_id = "webhook-test"
    mode = "async"
    #{integration_settings}
    """)

    System.put_env("HOME", home)
    Application.delete_env(:lemon_core, :gateway_test_config)
    Application.delete_env(:lemon_gateway, :config_path)
    webhook = LemonCore.GatewayConfig.get(:webhook)
    assert Map.has_key?(webhook.integrations, id)
    id
  end

  defp post_authorized(integration_id, body) do
    conn =
      Test.conn(:post, "/webhooks/#{integration_id}", Jason.encode!(body))
      |> Conn.put_req_header("content-type", "application/json")
      |> Conn.put_req_header("authorization", "Bearer #{@token}")
      |> Webhook.call([])

    assert conn.status == 202, conn.resp_body
    assert_receive {:provenance_submit, %RunRequest{} = request}
    request
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
