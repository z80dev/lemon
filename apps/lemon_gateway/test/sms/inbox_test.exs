defmodule LemonGateway.Sms.ReadFailureBackend do
  # Store backend whose reads fail while writes, insert-if-absent and lists work.
  @behaviour LemonCore.Store.Backend

  @impl true
  def init(_opts), do: {:ok, %{data: %{}}}

  @impl true
  def put(state, table, key, value), do: {:ok, put_in(state, [:data, {table, key}], value)}

  @impl true
  def put_new(state, table, key, value) do
    if Map.has_key?(state.data, {table, key}),
      do: {:exists, state},
      else: put(state, table, key, value)
  end

  @impl true
  def get(_state, _table, _key), do: {:error, :injected_read_failure}

  @impl true
  def delete(state, table, key), do: {:ok, %{state | data: Map.delete(state.data, {table, key})}}

  @impl true
  def list(state, table) do
    {:ok, for({{^table, key}, value} <- state.data, do: {key, value}), state}
  end
end

defmodule LemonGateway.Sms.WriteFailureBackend do
  # Store backend whose writes fail.
  @behaviour LemonCore.Store.Backend

  @impl true
  def init(_opts), do: {:ok, %{data: %{}}}

  @impl true
  def put(_state, _table, _key, _value), do: {:error, :injected_write_failure}

  @impl true
  def put_new(_state, _table, _key, _value), do: {:error, :injected_write_failure}

  @impl true
  def get(state, table, key), do: {:ok, Map.get(state.data, {table, key}), state}

  @impl true
  def delete(state, _table, _key), do: {:ok, state}

  @impl true
  def list(state, _table), do: {:ok, [], state}
end

defmodule LemonGateway.Sms.InboxTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Sms.{Inbox, InboxStore}

  @tables [:sms_inbox, :sms_inbox_reservation]

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    prev = System.get_env("TWILIO_INBOX_NUMBER")
    System.put_env("TWILIO_INBOX_NUMBER", "+15551239999")
    clear_tables()
    start_supervised!(Inbox)

    on_exit(fn ->
      if is_nil(prev),
        do: System.delete_env("TWILIO_INBOX_NUMBER"),
        else: System.put_env("TWILIO_INBOX_NUMBER", prev)

      clear_tables()
    end)

    :ok
  end

  defp clear_tables do
    for table <- @tables,
        {k, _v} <- LemonCore.Store.list(table),
        do: LemonCore.Store.delete(table, k)
  end

  defp sms(body, extra \\ %{}) do
    sid = "SM#{System.unique_integer([:positive])}"

    params =
      Map.merge(
        %{"MessageSid" => sid, "From" => "+15551230001", "To" => "+15551239999", "Body" => body},
        extra
      )

    assert {:ok, :stored} = Inbox.ingest_twilio_sms(params)
    sid
  end

  # A lease carrying a long-past expiry from the retired time-window design; it
  # must stay bound to its holder.
  defp age_lease_without_release(session) do
    :ok =
      InboxStore.put_reservation(%{
        "session_key" => session,
        "released_at_ms" => nil,
        "lease_id" => "aged",
        "expires_at_ms" => System.system_time(:millisecond) - 24 * 60 * 60 * 1000
      })
  end

  # Moves an explicit release back past the handoff grace period.
  defp end_grace_period(session) do
    released = System.system_time(:millisecond) - LemonGateway.Sms.Config.handoff_grace_ms() - 1

    :ok =
      InboxStore.put_reservation(%{
        "session_key" => session,
        "released_at_ms" => released,
        "lease_id" => "released"
      })
  end

  defp operator_clear!(holder) do
    assert {:ok, %{holder: ^holder, confirm_token: token}} = Inbox.preview_clear()
    assert :ok = Inbox.confirm_clear(holder, token)
  end

  defp swap_store_backend(backend, data) do
    original = :sys.get_state(LemonCore.Store)
    on_exit(fn -> :sys.replace_state(LemonCore.Store, fn _ -> original end) end)

    :sys.replace_state(LemonCore.Store, fn state ->
      %{state | backend: backend, backend_state: %{data: data}}
    end)
  end

  defp await_waiter(0), do: flunk("SMS waiter did not register")

  defp await_waiter(attempts) do
    if map_size(:sys.get_state(Inbox).waiters) == 0 do
      Process.sleep(10)
      await_waiter(attempts - 1)
    end
  end

  describe "matching" do
    test "expensive custom patterns reject stored messages without claiming them" do
      assert :ok = Inbox.reserve("s")
      sms(String.duplicate("a", 100) <> "! Code: 123456")

      assert {:error, :regex_match_limit} =
               Inbox.wait_for_code("s", regex: "(a+)+$", timeout_ms: 1_000)

      assert {:ok, %{code: "123456"}} = Inbox.wait_for_code("s", timeout_ms: 1_000)
      assert {:error, :invalid_regex} = Inbox.wait_for_code("s", regex: "(", timeout_ms: 1_000)
    end

    test "pending matcher exhaustion replies explicitly and leaves default matching usable" do
      assert :ok = Inbox.reserve("s")
      task = Task.async(fn -> Inbox.wait_for_code("s", regex: "(a+)+$", timeout_ms: 5_000) end)
      await_waiter(100)

      sms(String.duplicate("a", 100) <> "! Code: 654321")

      assert {:error, :regex_match_limit} = Task.await(task)
      assert :sys.get_state(Inbox).waiters == %{}
      assert {:ok, %{code: "654321"}} = Inbox.wait_for_code("s", timeout_ms: 1_000)
    end

    test "ingest_twilio_sms dedupes by MessageSid" do
      params = %{"MessageSid" => "SMdup", "To" => "+15551239999", "Body" => "Your code 123456"}
      assert {:ok, :stored} = Inbox.ingest_twilio_sms(params)
      assert {:ok, :duplicate} = Inbox.ingest_twilio_sms(params)
      assert [%{"message_sid" => "SMdup"}] = Inbox.list_messages(limit: 10, include_claimed: true)
    end

    test "wait_for_code returns a stored bound message and claims it" do
      assert :ok = Inbox.reserve("session-a")
      sid = sms("Verification: 7777")

      assert {:ok, %{code: "7777", message: msg}} =
               Inbox.wait_for_code("session-a", timeout_ms: 2_000)

      assert msg["message_sid"] == sid
      assert msg["claimed_by"] == "session-a"
      assert {:ok, [%{"claimed_by" => "session-a"}]} = Inbox.list_session_messages("session-a")
    end

    test "wait_for_code blocks until a message arrives" do
      task = Task.async(fn -> Inbox.wait_for_code("session-b", timeout_ms: 5_000) end)
      await_waiter(100)
      sid = sms("Code: 888888")

      assert {:ok, %{code: "888888", message: %{"message_sid" => ^sid}}} = Task.await(task)
    end

    test "a pending waiter is not fulfilled by a message below its since_ms floor" do
      floor = System.system_time(:millisecond) + 60_000

      task =
        Task.async(fn -> Inbox.wait_for_code("s", since_ms: floor, timeout_ms: 300) end)

      await_waiter(100)
      sid = sms("Code: 121212")

      assert {:error, :timeout} = Task.await(task)
      assert InboxStore.get(sid)["claimed_by"] == nil
    end

    test "operator list filters by to/from_contains/body_contains" do
      sid1 = sms("Acme code 111111", %{"From" => "+15551230010"})
      sid2 = sms("Beta code 222222", %{"From" => "+15551230011"})

      assert [%{"message_sid" => ^sid1}] = Inbox.list_messages(from_contains: "0010")
      assert [%{"message_sid" => ^sid2}] = Inbox.list_messages(body_contains: "Beta")
      assert length(Inbox.list_messages(to: "+15551239999")) == 2
    end
  end

  describe "reservations" do
    test "only the lease holder sees messages that arrive during its lease" do
      assert :ok = Inbox.reserve("a")
      mine = sms("A code 111111")

      assert {:error, :inbox_reserved} = Inbox.reserve("b")
      assert {:error, :inbox_reserved} = Inbox.list_session_messages("b")
      assert {:error, :inbox_reserved} = Inbox.wait_for_code("b", timeout_ms: 100)
      assert {:error, :inbox_reserved} = Inbox.claim_message("b", mine)
      assert {:error, :inbox_reserved} = Inbox.release("b")

      assert {:ok, [%{"message_sid" => ^mine}]} = Inbox.list_session_messages("a")

      assert :ok = Inbox.release("a")
      assert {:error, :inbox_reserved} = Inbox.reserve("b")
      end_grace_period("a")
      assert :ok = Inbox.reserve("b")

      # A's message stays A's: B cannot list, wait for or claim it.
      assert {:ok, []} = Inbox.list_session_messages("b")
      assert {:error, :not_found} = Inbox.claim_message("b", mine)
      assert {:error, :timeout} = Inbox.wait_for_code("b", since_ms: 0, timeout_ms: 100)
      assert InboxStore.get(mine)["claimed_by"] == nil
    end

    test "messages arriving with no lease are visible to no session" do
      orphan = sms("Nobody's code 333333")

      assert {:ok, []} = Inbox.list_session_messages("a")
      assert {:error, :not_found} = Inbox.claim_message("a", orphan)
      assert {:error, :timeout} = Inbox.wait_for_code("a", since_ms: 0, timeout_ms: 100)
    end

    test "a lease never expires: without release B can never acquire the number" do
      assert :ok = Inbox.reserve("a")
      age_lease_without_release("a")

      assert {:error, :inbox_reserved} = Inbox.reserve("b")
      assert {:error, :inbox_reserved} = Inbox.wait_for_code("b", timeout_ms: 100)
      late = sms("A's late code 444444")
      assert InboxStore.get(late)["reserved_for"] == "a"
      assert {:error, :inbox_reserved} = Inbox.list_session_messages("b")

      assert {:ok, %{code: "444444"}} = Inbox.wait_for_code("a", timeout_ms: 500)
    end

    test "after release the number stays bound to the releaser for the grace period" do
      assert :ok = Inbox.reserve("a")
      assert :ok = Inbox.release("a")

      assert {:error, :inbox_reserved} = Inbox.reserve("b")
      assert {:error, :inbox_reserved} = Inbox.wait_for_code("b", timeout_ms: 100)
      late = sms("A's late code 717171")
      assert InboxStore.get(late)["reserved_for"] == "a"

      # After the grace period B may reserve, but never sees A's late code.
      end_grace_period("a")
      assert :ok = Inbox.reserve("b")
      assert {:ok, []} = Inbox.list_session_messages("b")
      assert {:error, :not_found} = Inbox.claim_message("b", late)
      assert {:error, :timeout} = Inbox.wait_for_code("b", since_ms: 0, timeout_ms: 100)
      assert InboxStore.get(late)["claimed_by"] == nil
    end

    test "the releaser may re-reserve during its grace period and get its late code" do
      assert :ok = Inbox.reserve("a")
      assert :ok = Inbox.release("a")
      late = sms("A's late code 727272")

      assert :ok = Inbox.reserve("a")

      assert {:ok, %{code: "727272", message: %{"message_sid" => ^late}}} =
               Inbox.wait_for_code("a", timeout_ms: 500)
    end

    test "a configured zero grace period is ignored in favour of the default" do
      original = Application.get_env(:lemon_core, :gateway_test_config)
      on_exit(fn -> Application.put_env(:lemon_core, :gateway_test_config, original) end)

      Application.put_env(:lemon_core, :gateway_test_config, %{
        sms: %{handoff_grace_ms: 0}
      })

      assert LemonGateway.Sms.Config.handoff_grace_ms() == 10 * 60 * 1000
      assert :ok = Inbox.reserve("a")
      assert :ok = Inbox.release("a")
      assert {:error, :inbox_reserved} = Inbox.reserve("b")
    end

    test "config validation rejects a zero or negative handoff grace" do
      previous = Application.get_env(:lemon_core, :gateway_test_config)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:lemon_core, :gateway_test_config, previous),
          else: Application.delete_env(:lemon_core, :gateway_test_config)
      end)

      for bad <- [0, -5, "600000"] do
        assert {:error, errors} =
                 LemonCore.Config.Modular.validate_settings(%{
                   "gateway" => %{"sms" => %{"handoff_grace_ms" => bad}}
                 })

        assert Enum.any?(errors, &String.starts_with?(&1, "gateway.sms.handoff_grace_ms"))
      end

      Application.put_env(:lemon_core, :gateway_test_config, %{
        "sms" => %{"handoff_grace_ms" => 30_000}
      })

      assert LemonGateway.Sms.Config.handoff_grace_ms() == 30_000
    end
  end

  describe "operator clear" do
    test "preview then confirm frees the number at once; A's later text goes to B (accepted)" do
      assert :ok = Inbox.reserve("a")
      before_clear = sms("A's code 818181")
      operator_clear!("a")

      assert :ok = Inbox.reserve("b")
      # Documented, operator-accepted cost of a forced clear: a text for A that
      # arrives after B reserves is attributed to B.
      late_for_a = sms("A's late code 828282")
      assert InboxStore.get(late_for_a)["reserved_for"] == "b"
      assert {:ok, %{code: "828282"}} = Inbox.wait_for_code("b", timeout_ms: 500)

      # Texts bound before the clear stay A's.
      assert InboxStore.get(before_clear)["reserved_for"] == "a"
      assert {:error, :not_found} = Inbox.claim_message("b", before_clear)
    end

    test "confirmation is bound to the exact holder, lease and a single use" do
      assert :ok = Inbox.reserve("a")
      assert {:ok, %{holder: "a", released: false, confirm_token: token}} = Inbox.preview_clear()

      assert {:error, :confirmation_mismatch} = Inbox.confirm_clear("someone-else", token)
      # A failed confirmation consumes the token.
      assert {:error, :confirmation_required} = Inbox.confirm_clear("a", token)
      assert {:error, :confirmation_required} = Inbox.confirm_clear("a", "made-up-token")

      # The lease changing hands after a preview voids that preview.
      assert {:ok, %{confirm_token: stale}} = Inbox.preview_clear()
      operator_clear!("a")
      assert :ok = Inbox.reserve("b")
      assert {:error, :confirmation_mismatch} = Inbox.confirm_clear("a", stale)

      assert {:ok, %{confirm_token: b_token}} = Inbox.preview_clear()
      assert :ok = Inbox.release("b")
      assert :ok = Inbox.reserve("b")
      assert {:error, :confirmation_mismatch} = Inbox.confirm_clear("b", b_token)
      assert {:error, :inbox_reserved} = Inbox.reserve("c")
    end

    test "preview with no reservation returns no token" do
      assert {:ok, %{holder: nil, confirm_token: nil}} = Inbox.preview_clear()
    end
  end

  describe "reservation basics" do
    test "a pending waiter of a non-holder never receives the holder's message" do
      assert :ok = Inbox.reserve("victim")

      # The attacker's call is refused outright; it never becomes a waiter.
      assert {:error, :inbox_reserved} = Inbox.wait_for_code("attacker", timeout_ms: 500)

      victim = Task.async(fn -> Inbox.wait_for_code("victim", timeout_ms: 2_000) end)
      await_waiter(100)
      sms("Victim OTP 909090")

      assert {:ok, %{code: "909090", message: %{"claimed_by" => "victim"}}} = Task.await(victim)
    end

    test "concurrent reservations grant exactly one holder" do
      results =
        1..20
        |> Enum.map(fn n -> Task.async(fn -> Inbox.reserve("racer-#{n}") end) end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :inbox_reserved})) == 19
    end

    test "the lease and bound messages persist across inbox restarts (cross-run receipt)" do
      assert :ok = Inbox.reserve("a")
      stop_supervised!(Inbox)
      start_supervised!(Inbox)

      sid = sms("Arrived between turns 676767")

      assert {:error, :inbox_reserved} = Inbox.reserve("b")

      assert {:ok, %{code: "676767", message: %{"message_sid" => ^sid}}} =
               Inbox.wait_for_code("a", timeout_ms: 500)
    end

    test "session calls require a session key" do
      assert {:error, :missing_session_key} = Inbox.reserve(nil)
      assert {:error, :missing_session_key} = Inbox.wait_for_code(nil, timeout_ms: 100)
      assert {:error, :missing_session_key} = Inbox.list_session_messages("")
      assert {:error, :missing_session_key} = Inbox.claim_message(nil, "SMx")
    end
  end

  describe "replayed deliveries" do
    test "a replay during a store read failure keeps the claimed record and is not re-offered" do
      assert :ok = Inbox.reserve("victim")
      sid = sms("Victim OTP 135790")
      assert {:ok, %{code: "135790"}} = Inbox.wait_for_code("victim", timeout_ms: 500)
      claimed = InboxStore.get(sid)
      assert claimed["claimed_by"] == "victim"

      waiter = Task.async(fn -> Inbox.wait_for_code("victim", timeout_ms: 400) end)
      await_waiter(100)

      data =
        for table <- [:sms_inbox, :sms_inbox_reservation],
            {k, v} <- LemonCore.Store.list(table),
            into: %{},
            do: {{table, k}, v}

      swap_store_backend(LemonGateway.Sms.ReadFailureBackend, data)

      replay = %{
        "MessageSid" => sid,
        "From" => "+15551230001",
        "To" => "+15551239999",
        "Body" => "Victim OTP 135790"
      }

      assert {:ok, :duplicate} = Inbox.ingest_twilio_sms(replay)
      assert {:error, :timeout} = Task.await(waiter)

      backend_data = :sys.get_state(LemonCore.Store).backend_state.data
      assert backend_data[{:sms_inbox, sid}] == claimed
    end

    test "a store write failure is reported and stores nothing" do
      swap_store_backend(LemonGateway.Sms.WriteFailureBackend, %{})

      assert {:error, :store_unavailable} =
               Inbox.ingest_twilio_sms(%{"MessageSid" => "SMwritefail", "Body" => "c 1111"})

      assert :sys.get_state(LemonCore.Store).backend_state.data == %{}
    end

    test "the webhook answers 503 (so Twilio retries) when the text could not be stored" do
      prev = System.get_env("TWILIO_AUTH_TOKEN")
      System.put_env("TWILIO_AUTH_TOKEN", "inbox-test-token")

      on_exit(fn ->
        if prev,
          do: System.put_env("TWILIO_AUTH_TOKEN", prev),
          else: System.delete_env("TWILIO_AUTH_TOKEN")
      end)

      params = %{"MessageSid" => "SMrouterfail", "Body" => "c 1111"}

      signature =
        LemonGateway.Sms.TwilioSignature.signature(
          "inbox-test-token",
          "http://www.example.com/webhooks/twilio/sms",
          params
        )

      swap_store_backend(LemonGateway.Sms.WriteFailureBackend, %{})

      conn =
        Plug.Test.conn(:post, "/webhooks/twilio/sms", params)
        |> Plug.Conn.put_req_header("x-twilio-signature", signature)
        |> LemonGateway.Sms.WebhookRouter.call([])

      assert conn.status == 503
    end
  end
end
