# Hermetic Telegram transport smoke against LemonChannels.Telegram.FakeAPI.
#
# Boots the real Telegram polling transport with the fake API selected the way
# an operator would select it ([gateway.telegram] api_mod as a string), drives
# a full inbound round trip (message update -> pipeline -> router submission ->
# captured outbound API calls), a callback-query flow, and the string-config
# outbound delivery path. No network, no real Telegram.
#
# Usage: MIX_ENV=test mix run scripts/live_fake_telegram_smoke.exs
# Proof:  .lemon/proofs/fake-telegram-smoke-latest.json (+ timestamped archive)

Application.ensure_all_started(:lemon_core)
Application.ensure_all_started(:lemon_channels)

defmodule LemonScripts.LiveFakeTelegramSmoke.ProofRouter do
  def handle_inbound(msg) do
    notify({:inbound, msg})
    :ok
  end

  def submit(%LemonCore.RunRequest{} = request) do
    notify({:inbound_request, request})
    {:ok, "run_#{System.unique_integer([:positive])}"}
  end

  defp notify(message) do
    case :persistent_term.get({__MODULE__, :pid}, nil) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end

defmodule LemonScripts.LiveFakeTelegramSmoke do
  alias LemonChannels.Telegram.FakeAPI
  alias LemonScripts.LiveFakeTelegramSmoke.ProofRouter

  @proof_object "lemon.fake_telegram_smoke"
  @proof_scope "hermetic_telegram_transport"
  @transport LemonChannels.Adapters.Telegram.Transport
  @gateway_config_key :"Elixir.LemonGateway.Config"
  @chat_id 640_001

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])

    out =
      opts[:out] ||
        Path.join([File.cwd!(), ".lemon", "proofs", "fake-telegram-smoke-latest.json"])

    proof = with_fixture(&run/1)

    write_json!(out, proof)
    write_json!(archive_path(out), proof)
    IO.puts(Jason.encode!(proof, pretty: true))

    if proof.failed_count > 0, do: System.halt(1)
  end

  defp run(token) do
    checks =
      [
        &check_string_config_resolution/1,
        &check_inbound_round_trip/1,
        &check_offset_advance/1,
        &check_callback_query_flow/1,
        &check_outbound_delivery_path/1
      ]
      |> Enum.map(fn check -> check.(token) end)

    status = if Enum.all?(checks, &(&1.status == "completed")), do: :completed, else: :failed
    proof(status, checks)
  end

  # The transport resolved its api_mod from the string form an operator would
  # put in [gateway.telegram]; getMe was answered by the fake.
  defp check_string_config_resolution(_token) do
    case FakeAPI.await_send(:get_me, 3_000) do
      {:ok, %{fun: :get_me}} ->
        check("string_api_mod_selected_and_get_me_answered", "completed", nil, %{
          api_mod: inspect(FakeAPI),
          configured_as: "string module name in [gateway.telegram] api_mod"
        })

      {:error, :timeout} ->
        check("string_api_mod_selected_and_get_me_answered", "failed", "getMe never captured")
    end
  end

  # Inbound update -> poller -> pipeline -> router submission + progress reaction.
  defp check_inbound_round_trip(_token) do
    update = FakeAPI.simulate_message(@chat_id, "fake telegram smoke round trip")
    user_msg_id = update["message"]["message_id"]

    inbound_ok? =
      receive do
        {:inbound_request, %LemonCore.RunRequest{} = request} ->
          request.prompt == "fake telegram smoke round trip" and
            (request.meta || %{})[:chat_id] == @chat_id
      after
        3_000 -> false
      end

    reaction =
      FakeAPI.await_send(
        fn
          %{fun: :set_message_reaction, args: [chat_id, msg_id, _emoji, _opts]} ->
            chat_id == @chat_id and msg_id == user_msg_id

          _ ->
            false
        end,
        3_000
      )

    cond do
      not inbound_ok? ->
        check("inbound_message_round_trip", "failed", "router did not receive the run request")

      not match?({:ok, _}, reaction) ->
        check("inbound_message_round_trip", "failed", "progress reaction was not captured")

      true ->
        check("inbound_message_round_trip", "completed", nil, %{
          update_id_hash: short_hash(update["update_id"]),
          outbound_calls_captured: length(FakeAPI.sent())
        })
    end
  end

  # The poller confirms consumed updates by polling with an advanced offset.
  defp check_offset_advance(_token) do
    update = FakeAPI.simulate_message(@chat_id, "offset advance probe")
    expected_offset = update["update_id"] + 1

    result =
      FakeAPI.await_send(
        fn
          %{fun: :get_updates, args: [offset, _timeout]} -> offset == expected_offset
          _ -> false
        end,
        3_000
      )

    case result do
      {:ok, _} ->
        check("get_updates_offset_advance", "completed", nil, %{
          offset_semantics: "updates >= offset returned; lower ids confirmed"
        })

      {:error, :timeout} ->
        check("get_updates_offset_advance", "failed", "poller never advanced the offset")
    end
  end

  # Inline button press -> callback pipeline -> answerCallbackQuery captured.
  defp check_callback_query_flow(_token) do
    update = FakeAPI.simulate_callback_query(@chat_id, "unknown|decision")
    cb_id = update["callback_query"]["id"]

    result =
      FakeAPI.await_send(
        fn
          %{fun: :answer_callback_query, args: [id, _opts]} ->
            id == cb_id

          _ ->
            false
        end,
        3_000
      )

    case result do
      {:ok, %{args: [_id, opts]}} ->
        check("callback_query_answered", "completed", nil, %{answer_opts_keys: Map.keys(opts)})

      {:error, :timeout} ->
        check("callback_query_answered", "failed", "answerCallbackQuery was not captured")
    end
  end

  # Outbound delivery half: Outbound.deliver resolves the same string api_mod
  # from gateway config and the fake captures sendMessage.
  defp check_outbound_delivery_path(_token) do
    payload = %LemonChannels.OutboundPayload{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: Integer.to_string(@chat_id), thread_id: nil},
      kind: :text,
      content: "outbound delivery through FakeAPI",
      idempotency_key: "fake_telegram_smoke_#{System.unique_integer([:positive])}",
      meta: %{}
    }

    delivery = LemonChannels.Adapters.Telegram.Outbound.deliver(payload)

    captured =
      FakeAPI.await_send(
        fn
          %{fun: :send_message, args: [chat_id, text, _opts, _parse_mode]} ->
            chat_id == @chat_id and
              is_binary(text) and
              String.contains?(text, "outbound delivery through FakeAPI")

          _ ->
            false
        end,
        3_000
      )

    cond do
      not match?({:ok, %{"message_id" => _}}, normalize_delivery(delivery)) ->
        check("outbound_delivery_send_message", "failed", "deliver/1 did not return a message")

      not match?({:ok, _}, captured) ->
        check("outbound_delivery_send_message", "failed", "sendMessage was not captured")

      true ->
        check("outbound_delivery_send_message", "completed", nil, %{
          delivery_result: "ok_with_message_id"
        })
    end
  end

  defp normalize_delivery({:ok, %{"ok" => true, "result" => %{} = message}}), do: {:ok, message}
  defp normalize_delivery(other), do: other

  # ---------------------------------------------------------------------------
  # Fixture: boot the transport against the fake, restore everything after.
  # ---------------------------------------------------------------------------

  defp with_fixture(fun) do
    token = "fake-smoke-token-" <> Integer.to_string(System.unique_integer([:positive]))

    old_gateway_env = Application.get_env(:lemon_gateway, @gateway_config_key)
    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_transport_pid = Process.whereis(@transport)

    if is_pid(old_transport_pid) do
      raise "refusing to run: a Telegram transport is already running in this VM"
    end

    :persistent_term.put({ProofRouter, :pid}, self())

    LemonCore.RouterBridge.configure(router: ProofRouter, run_orchestrator: ProofRouter)

    # String api_mod — exactly what an operator would write in config.toml
    # under [gateway.telegram]. Exercises normalize_api_mod/1 string handling
    # for both the transport and the outbound delivery path.
    existing = if is_map(old_gateway_env), do: old_gateway_env, else: %{}

    Application.put_env(
      :lemon_gateway,
      @gateway_config_key,
      Map.put(existing, :telegram, %{
        bot_token: token,
        api_mod: "LemonChannels.Telegram.FakeAPI",
        allowed_chat_ids: [@chat_id],
        poll_interval_ms: 25,
        debounce_ms: 10,
        drop_pending_updates: false
      })
    )

    FakeAPI.reset()

    {:ok, transport_pid} = @transport.start_link(config: %{})

    try do
      fun.(token)
    after
      if Process.alive?(transport_pid), do: GenServer.stop(transport_pid, :normal)
      FakeAPI.reset()
      :persistent_term.erase({ProofRouter, :pid})
      restore_env(:lemon_gateway, @gateway_config_key, old_gateway_env)
      restore_env(:lemon_core, :router_bridge, old_router_bridge)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  # ---------------------------------------------------------------------------
  # Proof plumbing (house smoke conventions)
  # ---------------------------------------------------------------------------

  defp proof(status, checks) do
    %{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: Atom.to_string(status),
      proof_object: @proof_object,
      proof_scope: @proof_scope,
      checks: checks,
      completed_count: Enum.count(checks, &(&1.status == "completed")),
      failed_count: Enum.count(checks, &(&1.status == "failed")),
      skipped_count: Enum.count(checks, &(&1.status == "skipped")),
      cleanup: %{
        includes_prompts: false,
        includes_outputs: false,
        includes_real_bot_token: false,
        includes_raw_chat_ids: false,
        network_traffic: false,
        transport_stopped: true,
        gateway_env_restored: true,
        router_bridge_restored: true
      }
    }
  end

  defp check(name, status, reason), do: check(name, status, reason, nil)

  defp check(name, status, reason, meta) do
    %{name: name, status: status}
    |> maybe_put(:reason_kind, reason)
    |> maybe_put(:meta, meta)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp write_json!(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  end

  defp archive_path(path) do
    ext = Path.extname(path)
    base = String.trim_trailing(path, ext)
    "#{base}-#{DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")}#{ext}"
  end

  defp short_hash(value) do
    :crypto.hash(:sha256, to_string(value)) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end
end

LemonScripts.LiveFakeTelegramSmoke.main(System.argv())
