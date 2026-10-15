defmodule LemonChannels.SupervisionTest do
  use ExUnit.Case, async: false

  alias LemonChannels.{Supervision, SupervisionNotice, SupervisionStore}
  alias LemonCore.{ChannelSupervision, Store}

  @store __MODULE__.Store

  setup do
    original_provider = Application.fetch_env(:lemon_core, :channel_supervision_provider)

    on_exit(fn ->
      case original_provider do
        {:ok, provider} ->
          Application.put_env(:lemon_core, :channel_supervision_provider, provider)

        :error ->
          Application.delete_env(:lemon_core, :channel_supervision_provider)
      end
    end)

    start_supervised!({Store, name: @store, backend: Store.EtsBackend, cached_tables: []})
    :ok
  end

  test "isolated workers never register a global provider" do
    Application.delete_env(:lemon_core, :channel_supervision_provider)
    worker()
    assert ChannelSupervision.provider() == nil
    stop_supervised!(Supervision)
    worker(name: __MODULE__.IsolatedWorker)
    assert ChannelSupervision.provider() == nil
  end

  test "default startup registers the provider and worker downtime preserves store operations" do
    supervisor = Process.whereis(LemonChannels.Supervisor)

    if supervisor && Process.whereis(Supervision) do
      :ok = Supervisor.terminate_child(supervisor, Supervision)
      on_exit(fn -> Supervisor.restart_child(supervisor, Supervision) end)
    end

    Application.delete_env(:lemon_core, :channel_supervision_provider)
    worker(name: Supervision)
    assert ChannelSupervision.provider() == Supervision
    stop_supervised!(Supervision)
    assert Process.whereis(Supervision) == nil
    assert ChannelSupervision.provider() == Supervision

    run_id = "bridge-#{System.unique_integer([:positive, :monotonic])}"
    session = "agent:operator:main"
    target = target()
    notice = %{notice() | run_id: run_id}
    {:ok, identity} = SupervisionNotice.identity(notice)

    on_exit(fn ->
      binding_key = :crypto.hash(:sha256, :erlang.term_to_binary(run_id)) |> Base.encode16()
      notice_key = :crypto.hash(:sha256, :erlang.term_to_binary(identity)) |> Base.encode16()
      Store.delete(:channels_supervision_bindings, binding_key)
      Store.delete(:channels_supervision_notices, notice_key)
    end)

    assert :ok = ChannelSupervision.bind_run(run_id, session, target)
    assert {:ok, ^target} = ChannelSupervision.target_for_run(run_id, session)

    assert {:error, :session_mismatch} =
             ChannelSupervision.target_for_run(run_id, session <> ":sub:other")

    assert {:error, :supervision_unavailable} = ChannelSupervision.notify(target, notice)

    assert {:ok, %{delivery_state: :pending, attempts: 0}} =
             SupervisionStore.notice(Store, identity)

    assert {:ok, %{delivery_state: :pending}} = Supervision.status(notice)
    refute_receive {:enqueue, _}
  end

  test "bindings are immutable and require the exact bound session, including threads" do
    server = worker()
    target = target()
    session = "agent:operator:telegram:work:group:-100:thread:77"
    assert :ok = Supervision.bind_run(server, "run-1", session, target)
    assert :ok = Supervision.bind_run(server, "run-1", session, target)
    assert {:ok, ^target} = Supervision.target_for_run(server, "run-1", session)

    assert {:error, :binding_conflict} =
             Supervision.bind_run(server, "run-1", session, put_in(target.peer.thread_id, "78"))

    assert {:error, :binding_conflict} =
             Supervision.bind_run(server, "run-1", session <> ":sub:other", target)

    assert {:error, :session_mismatch} =
             Supervision.target_for_run(server, "run-1", "agent:operator:main")

    stop_supervised!(Supervision)
    server = worker()
    assert {:ok, ^target} = Supervision.target_for_run(server, "run-1", session)
  end

  test "unbound canonical origins preserve platform, account, kind, chat and thread" do
    server = worker()

    for channel <- ["telegram", "discord"] do
      session = "agent:operator:#{channel}:named:channel:123:thread:456:sub:child"
      assert {:ok, resolved} = Supervision.target_for_run(server, "unbound", session)
      assert resolved == target(channel, "named", :channel, "123", "456")
    end

    assert :none = Supervision.target_for_run(server, "unbound", "agent:operator:main")
    assert {:error, :invalid_session} = Supervision.target_for_run(server, "unbound", "garbage")

    assert {:error, :invalid_target} =
             Supervision.target_for_run(server, "unbound", "agent:a:telegram::group:-100")
  end

  test "missing store is not absence and never derives an origin or sends" do
    server = worker(store: __MODULE__.MissingStore)
    session = "agent:operator:telegram:work:group:-100:thread:77"
    assert {:error, :store_unavailable} = Supervision.target_for_run(server, "run-1", session)
    assert {:error, :store_unavailable} = Supervision.bind_run(server, "run-1", session, target())
    assert {:error, :store_unavailable} = Supervision.notify(server, target(), notice())
    refute_receive {:enqueue, _}
  end

  test "all terminal kinds render clear identity and settle successful receipts" do
    server = worker()

    for kind <- [:goal, :kanban, :cron], status <- [:completed, :failed, :cancelled] do
      notice = %{notice(kind, status) | id: "#{kind}-#{status}"}
      assert :ok = Supervision.notify(server, target(), notice)
      assert_receive {:enqueue, payload}
      assert payload.channel_id == "telegram"
      assert payload.account_id == "work"
      assert payload.peer == %{kind: :group, id: "-100", thread_id: "77"}
      assert payload.content =~ "#{String.capitalize(to_string(kind))} `#{notice.id}`: #{status}"
      assert payload.content =~ "Run: `run-1`"
      assert payload.content =~ "Commit: abcdef0123456789"
      assert payload.content =~ "PR: https://github.com/example/repo/pull/42"
      assert byte_size(payload.content) < 2_000

      send(
        server,
        {:supervision_receipt, payload.notify_ref, {:ok, %{private_response: "never persist"}}}
      )

      assert {:ok, metadata} = Supervision.status(server, notice)
      assert metadata.delivery_state == :delivered

      assert Map.keys(metadata) |> Enum.sort() ==
               Enum.sort([
                 :kind,
                 :id,
                 :run_id,
                 :status,
                 :delivery_state,
                 :attempts,
                 :reason,
                 :updated_at_ms
               ])

      refute inspect(metadata) =~ "never persist"
    end
  end

  test "all kinds report definite delivery failures without receipt contents or replay" do
    server = worker()

    for kind <- [:goal, :kanban, :cron] do
      notice = notice(kind)
      assert :ok = Supervision.notify(server, target(), notice)
      assert_receive {:enqueue, payload}

      send(
        server,
        {:supervision_receipt, payload.notify_ref, {:error, {:http_error, 403, "private token"}}}
      )

      assert {:ok, %{delivery_state: :failed, reason: :delivery_failed}} =
               Supervision.status(server, notice)

      assert {:error, :delivery_failed} = Supervision.notify(server, target(), notice)
    end

    refute_receive {:enqueue, _}
  end

  test "identity deduplicates and conflicting targets or content cannot replace an intent" do
    server = worker()
    assert :ok = Supervision.notify(server, target(), notice())
    assert_receive {:enqueue, _}
    assert :ok = Supervision.notify(server, target(), notice())

    assert {:error, :notice_conflict} =
             Supervision.notify(server, put_in(target().peer.thread_id, "999"), notice())

    assert {:error, :notice_conflict} =
             Supervision.notify(server, target(), Map.put(notice(), :summary, "different"))

    refute_receive {:enqueue, _}
  end

  test "a bound run cannot notify a different account or thread" do
    server = worker()
    assert :ok = Supervision.bind_run(server, "run-1", "agent:a:main", target())

    assert {:error, :binding_conflict} =
             Supervision.notify(server, %{target() | account_id: "other"}, notice())

    refute_receive {:enqueue, _}
  end

  test "invalid targets and notices are rejected without an owner fallback" do
    server = worker()

    for invalid <- [
          nil,
          %{},
          %{target() | channel_id: "email"},
          %{target() | account_id: ""},
          put_in(target().peer.kind, :unknown),
          put_in(target().peer.thread_id, " ")
        ] do
      assert {:error, :invalid_target} = Supervision.notify(server, invalid, notice())
    end

    for invalid <- [
          %{},
          %{notice() | status: :running},
          %{notice() | id: "bad\nidentity"},
          Map.put(notice(), :pr_url, "https://secret@example.com/repo/pull/1"),
          Map.put(notice(), :pr_url, "https://example.com/repo/pull/1?token=secret")
        ] do
      assert {:error, :invalid_notice} = Supervision.notify(server, target(), invalid)
    end

    refute_receive {:enqueue, _}
  end

  test "intent is persisted before enqueue and definite rejection has bounded admission attempts" do
    parent = self()
    notice = notice()
    {:ok, identity} = SupervisionNotice.identity(notice)

    server =
      worker(
        enqueue: fn payload ->
          assert {:ok, %{delivery_state: :submitting, attempts: attempts}} =
                   SupervisionStore.notice(@store, identity)

          send(parent, {:attempt, attempts, payload})
          {:error, :channels_outbox_unavailable}
        end
      )

    assert {:error, :channels_outbox_unavailable} = Supervision.notify(server, target(), notice)
    assert_receive {:attempt, 1, _}
    send(server, {:submit, identity})
    assert {:ok, %{delivery_state: :pending, attempts: 2}} = Supervision.status(server, notice)
    assert_receive {:attempt, 2, _}
    send(server, {:submit, identity})
    assert {:ok, %{delivery_state: :rejected, attempts: 3}} = Supervision.status(server, notice)
    assert_receive {:attempt, 3, _}
    send(server, {:submit, identity})
    assert {:error, :admission_exhausted} = Supervision.notify(server, target(), notice)
    refute_receive {:attempt, _, _}
  end

  test "known-unsubmitted queue rejection recovers after restart without resetting attempts" do
    server = worker(enqueue: fn _ -> {:error, :queue_full} end)
    assert {:error, :queue_full} = Supervision.notify(server, target(), notice())
    stop_supervised!(Supervision)
    server = worker()
    assert_receive {:enqueue, payload}
    assert {:ok, %{delivery_state: :queued, attempts: 2}} = Supervision.status(server, notice())
    send(server, {:supervision_receipt, payload.notify_ref, {:ok, :sent}})
    assert {:ok, %{delivery_state: :delivered}} = Supervision.status(server, notice())
  end

  test "enqueue timeout never retries and a late receipt may settle it" do
    parent = self()

    server =
      worker(
        enqueue: fn payload ->
          send(parent, {:enqueue, payload})
          {:error, {:outcome_unknown, :enqueue_timeout}}
        end
      )

    assert {:error, :outcome_unknown} = Supervision.notify(server, target(), notice())
    assert_receive {:enqueue, payload}
    assert {:ok, %{delivery_state: :unknown}} = Supervision.status(server, notice())
    assert {:error, :outcome_unknown} = Supervision.notify(server, target(), notice())
    send(server, {:supervision_receipt, payload.notify_ref, {:ok, :late_receipt}})
    assert {:ok, %{delivery_state: :delivered}} = Supervision.status(server, notice())
    refute_receive {:enqueue, _}
  end

  test "receipt timeout, ambiguous receipt and interrupted admission are never replayed" do
    server = worker()
    assert :ok = Supervision.notify(server, target(), notice())
    assert_receive {:enqueue, payload}
    send(server, {:receipt_timeout, payload.notify_ref})

    assert {:ok, %{delivery_state: :unknown, reason: :receipt_timeout}} =
             Supervision.status(server, notice())

    second = %{notice(:cron) | run_id: "run-2"}
    assert :ok = Supervision.notify(server, target(), second)
    assert_receive {:enqueue, payload}
    send(server, {:supervision_receipt, payload.notify_ref, {:error, {:worker_exit, "private"}}})
    assert {:ok, %{delivery_state: :unknown}} = Supervision.status(server, second)

    third = %{notice(:kanban) | run_id: "run-3"}
    assert :ok = Supervision.notify(server, target(), third)
    assert_receive {:enqueue, _}
    stop_supervised!(Supervision)
    server = worker()

    assert {:ok, %{delivery_state: :unknown, reason: :interrupted}} =
             Supervision.status(server, third)

    assert {:error, :outcome_unknown} = Supervision.notify(server, target(), third)
    refute_receive {:enqueue, _}
  end

  test "submitting crash boundary recovers unknown while pristine intent is submitted" do
    {:ok, identity, text} = SupervisionNotice.render(notice())

    record = %{
      identity: identity,
      text: text,
      target: target(),
      delivery_state: :submitting,
      attempts: 1,
      reason: nil,
      updated_at_ms: 0
    }

    :ok = SupervisionStore.replace_notice(@store, identity, nil, record)
    pending_notice = %{notice() | run_id: "pristine"}
    {:ok, pending_identity, pending_text} = SupervisionNotice.render(pending_notice)

    pending = %{
      record
      | identity: pending_identity,
        text: pending_text,
        delivery_state: :pending,
        attempts: 0
    }

    :ok = SupervisionStore.replace_notice(@store, pending_identity, nil, pending)
    server = worker()
    assert {:ok, %{delivery_state: :unknown}} = Supervision.status(server, notice())
    assert_receive {:enqueue, payload}
    assert payload.content =~ "Run: `pristine`"
    refute_receive {:enqueue, _}
  end

  test "rendering bounds Unicode and redacts credentials before persistence" do
    {:ok, _, text} =
      SupervisionNotice.render(
        Map.merge(notice(), %{
          title: String.duplicate("😀", 150),
          summary: "api_key=sk-private-value " <> String.duplicate("😀", 10_000)
        })
      )

    assert String.valid?(text)
    assert byte_size(text) < 2_000
    refute text =~ "sk-private-value"
  end

  test "coding summaries preserve operators and test identifiers" do
    summary = "multiply(a, b) returns a * b; a < b; test_maths.py: REMOTE_APPROVED_CODING_OK"
    assert {:ok, _, text} = SupervisionNotice.render(Map.put(notice(), :summary, summary))
    assert text =~ summary
  end

  defp worker(opts \\ []) do
    parent = self()

    enqueue = fn payload ->
      send(parent, {:enqueue, payload})
      {:ok, make_ref()}
    end

    options = [
      name: nil,
      store: @store,
      enqueue: enqueue,
      retry_ms: 60_000,
      receipt_timeout_ms: 60_000
    ]

    start_supervised!({Supervision, Keyword.merge(options, opts)})
  end

  defp target(
         channel \\ "telegram",
         account \\ "work",
         kind \\ :group,
         id \\ "-100",
         thread \\ "77"
       ),
       do: %{
         channel_id: channel,
         account_id: account,
         peer: %{kind: kind, id: id, thread_id: thread}
       }

  defp notice(kind \\ :goal, status \\ :completed) do
    %{
      kind: kind,
      id: "item-1",
      run_id: "run-1",
      status: status,
      title: "Public title",
      summary: "Public summary",
      commit_sha: "abcdef0123456789",
      pr_url: "https://github.com/example/repo/pull/42"
    }
  end
end
