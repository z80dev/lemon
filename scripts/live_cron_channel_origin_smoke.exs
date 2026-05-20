Application.ensure_all_started(:lemon_core)
Application.ensure_all_started(:lemon_channels)
Application.ensure_all_started(:lemon_automation)

defmodule LemonScripts.LiveCronChannelOriginSmoke.ProofPlugin do
  defmacro __using__(id: id, label: label) do
    quote do
      @behaviour LemonChannels.Plugin

      @impl true
      def id, do: unquote(id)

      @impl true
      def meta do
        %{
          label: unquote(label),
          capabilities: %{chunk_limit: 4096},
          docs: nil
        }
      end

      @impl true
      def child_spec(_opts), do: %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}

      @impl true
      def normalize_inbound(_raw), do: {:error, :not_implemented}

      @impl true
      def deliver(payload) do
        case :persistent_term.get({__MODULE__, :notify_pid}, nil) do
          pid when is_pid(pid) -> send(pid, {:cron_channel_origin_payload, payload})
          _ -> :ok
        end

        {:ok, {:proof_delivery, unquote(id), payload.idempotency_key}}
      end

      @impl true
      def gateway_methods, do: []
    end
  end
end

defmodule LemonScripts.LiveCronChannelOriginSmoke.TelegramPlugin do
  use LemonScripts.LiveCronChannelOriginSmoke.ProofPlugin,
    id: "telegram",
    label: "Cron Channel Origin Telegram Proof"
end

defmodule LemonScripts.LiveCronChannelOriginSmoke.DiscordPlugin do
  use LemonScripts.LiveCronChannelOriginSmoke.ProofPlugin,
    id: "discord",
    label: "Cron Channel Origin Discord Proof"
end

defmodule LemonScripts.LiveCronChannelOriginSmoke do
  alias LemonAutomation.{CronManager, CronRun, CronStore}
  alias LemonChannels.OutboundPayload
  alias LemonCore.{Clock, SessionKey, Store}

  @proof_object "lemon.cron_channel_origin_smoke"
  @proof_scope "cron_channel_origin_delivery"

  def main(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])

    out =
      opts[:out] ||
        Path.join([File.cwd!(), ".lemon", "proofs", "cron-channel-origin-latest.json"])

    token = unique_token()

    proof =
      with_registered_plugins(fn ->
        run(token)
      end)

    write_json!(out, proof)
    write_json!(archive_path(out), proof)
    IO.puts(Jason.encode!(proof, pretty: true))

    if proof.failed_count > 0, do: System.halt(1)
  end

  defp run(token) do
    scenarios = [
      %{
        channel_id: "telegram",
        peer_kind: :group,
        peer_id: "-100#{token}",
        thread_id: "#{token}",
        plugin: LemonScripts.LiveCronChannelOriginSmoke.TelegramPlugin,
        check_name: "telegram_channel_origin_cron_delivery"
      },
      %{
        channel_id: "discord",
        peer_kind: :channel,
        peer_id: "discord-channel-#{token}",
        thread_id: "discord-thread-#{token}",
        plugin: LemonScripts.LiveCronChannelOriginSmoke.DiscordPlugin,
        check_name: "discord_channel_origin_cron_delivery"
      }
    ]

    checks =
      Enum.map(scenarios, fn scenario ->
        run_scenario(scenario, token)
      end)

    status = if Enum.all?(checks, &(&1.status == "completed")), do: :completed, else: :failed
    proof(status, checks)
  end

  defp run_scenario(scenario, token) do
    :persistent_term.put({scenario.plugin, :notify_pid}, self())

    session_key =
      SessionKey.channel_peer(%{
        agent_id: "cron_origin_#{token}",
        channel_id: scenario.channel_id,
        account_id: "default",
        peer_kind: scenario.peer_kind,
        peer_id: scenario.peer_id,
        thread_id: scenario.thread_id
      })

    run =
      %CronRun{
        id: "cron_origin_run_#{scenario.channel_id}_#{token}",
        job_id: "cron_origin_job_#{scenario.channel_id}_#{token}",
        run_id: "router_origin_run_#{scenario.channel_id}_#{token}",
        status: :running,
        started_at_ms: Clock.now_ms() - 1_000,
        completed_at_ms: nil,
        duration_ms: nil,
        triggered_by: :schedule,
        output: nil,
        error: nil,
        suppressed: false,
        meta: %{
          session_key: session_key,
          job_name: "cron channel origin #{scenario.channel_id}",
          agent_id: "cron_origin_#{token}"
        }
      }

    :ok = CronStore.put_run(run)

    send(
      CronManager,
      {:run_complete, run.id, {:ok, "CRON CHANNEL ORIGIN #{scenario.channel_id}"}}
    )

    payload = await_payload(scenario.channel_id, run.id, 3_000)
    history = await_history(session_key, run.id, 3_000)
    persisted_run = CronStore.get_run(run.id)

    cleanup_fixture(run, scenario.plugin)

    cond do
      not match?(%CronRun{status: :completed}, persisted_run) ->
        check(scenario.check_name, "failed", "cron run did not complete")

      not match?(%OutboundPayload{}, payload) ->
        check(scenario.check_name, "failed", "channel payload was not delivered")

      not valid_payload?(payload, scenario, run) ->
        check(
          scenario.check_name,
          "failed",
          "delivered payload shape did not match channel origin"
        )

      not valid_history?(history, session_key, run) ->
        check(scenario.check_name, "failed", "forwarded run history was not persisted")

      true ->
        check(scenario.check_name, "completed", nil, %{
          channel_id: scenario.channel_id,
          peer_kind: Atom.to_string(scenario.peer_kind),
          thread_present: is_binary(scenario.thread_id),
          cron_run_id_hash: short_hash(run.id),
          job_id_hash: short_hash(run.job_id),
          forwarded_run_id_hash: short_hash("cron_notify_" <> run.id)
        })
    end
  rescue
    exception ->
      cleanup_fixture(Map.get(binding(), :run), scenario.plugin)
      check(scenario.check_name, "failed", exception.__struct__ |> inspect())
  end

  defp valid_payload?(%OutboundPayload{} = payload, scenario, %CronRun{} = run) do
    payload.channel_id == scenario.channel_id and
      payload.account_id == "default" and
      payload.peer.kind == scenario.peer_kind and
      payload.peer.id == scenario.peer_id and
      payload.peer.thread_id == scenario.thread_id and
      payload.kind == :text and
      payload.idempotency_key == "cron_notify_#{run.id}" and
      payload.meta.cron_forwarded_summary == true and
      payload.meta.cron_run_id == run.id and
      payload.meta.cron_job_id == run.job_id and
      String.contains?(payload.content, "CRON CHANNEL ORIGIN") and
      String.contains?(payload.content, "cron_run_id: #{run.id}")
  end

  defp valid_payload?(_, _, _), do: false

  defp valid_history?({forwarded_run_id, data}, session_key, %CronRun{} = run) do
    summary = data[:summary] || %{}
    completed = summary[:completed] || %{}
    meta = summary[:meta] || %{}

    forwarded_run_id == "cron_notify_" <> run.id and
      summary[:session_key] == session_key and
      completed[:ok] == true and
      is_binary(completed[:answer]) and
      meta[:cron_forwarded_summary] == true and
      meta[:cron_run_id] == run.id
  end

  defp valid_history?(_, _, _), do: false

  defp await_payload(channel_id, run_id, timeout_ms) do
    receive do
      {:cron_channel_origin_payload, %OutboundPayload{} = payload} ->
        if payload.channel_id == channel_id and payload.meta.cron_run_id == run_id do
          payload
        else
          await_payload(channel_id, run_id, timeout_ms)
        end
    after
      timeout_ms -> nil
    end
  end

  defp await_history(session_key, run_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_history(session_key, run_id, deadline)
  end

  defp do_await_history(session_key, run_id, deadline) do
    found =
      Store.get_run_history(session_key, limit: 20)
      |> Enum.find(fn {candidate_id, data} ->
        summary = data[:summary] || %{}
        meta = summary[:meta] || %{}
        candidate_id == "cron_notify_" <> run_id and meta[:cron_forwarded_summary] == true
      end)

    cond do
      found ->
        found

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        Process.sleep(25)
        do_await_history(session_key, run_id, deadline)
    end
  end

  defp with_registered_plugins(fun) do
    saved = %{
      "telegram" => LemonChannels.Registry.get_plugin("telegram"),
      "discord" => LemonChannels.Registry.get_plugin("discord")
    }

    try do
      _ = LemonChannels.Registry.unregister("telegram")
      _ = LemonChannels.Registry.unregister("discord")

      :ok =
        LemonChannels.Registry.register(LemonScripts.LiveCronChannelOriginSmoke.TelegramPlugin)

      :ok = LemonChannels.Registry.register(LemonScripts.LiveCronChannelOriginSmoke.DiscordPlugin)

      fun.()
    rescue
      exception ->
        proof(:failed, [
          check("cron_channel_origin_smoke", "failed", Exception.message(exception))
        ])
    after
      :persistent_term.erase(
        {LemonScripts.LiveCronChannelOriginSmoke.TelegramPlugin, :notify_pid}
      )

      :persistent_term.erase({LemonScripts.LiveCronChannelOriginSmoke.DiscordPlugin, :notify_pid})
      restore_plugin("telegram", saved["telegram"])
      restore_plugin("discord", saved["discord"])
    end
  end

  defp restore_plugin(id, plugin) do
    _ = LemonChannels.Registry.unregister(id)

    if is_atom(plugin) and not is_nil(plugin) do
      _ = LemonChannels.Registry.register(plugin)
    end
  end

  defp cleanup_fixture(nil, plugin) do
    :persistent_term.erase({plugin, :notify_pid})
  end

  defp cleanup_fixture(%CronRun{} = run, plugin) do
    _ = CronStore.delete_run(run.id)
    _ = CronStore.delete_audit_event("cron_notify_#{run.id}")
    _ = Store.delete(:runs, "cron_notify_" <> run.id)
    _ = Store.delete(:runs, run.run_id)
    :persistent_term.erase({plugin, :notify_pid})
    :ok
  end

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
        includes_raw_session_ids: false,
        includes_raw_channel_ids: false,
        includes_raw_peer_ids: false,
        includes_raw_cron_ids: false,
        proof_plugins_restored: true
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

  defp unique_token do
    "#{System.system_time(:millisecond)}#{System.unique_integer([:positive, :monotonic])}"
  end
end

LemonScripts.LiveCronChannelOriginSmoke.main(System.argv())
