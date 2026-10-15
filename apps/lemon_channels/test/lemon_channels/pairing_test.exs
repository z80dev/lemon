defmodule LemonChannels.PairingTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Pairing
  alias LemonCore.Store

  setup do
    clock = start_supervised!({Agent, fn -> 1_000_000 end})

    start_supervised!(
      {Store, name: __MODULE__.Store, backend: Store.EtsBackend, cached_tables: []}
    )

    server =
      start_supervised!(
        {Pairing,
         name: __MODULE__.Pairing,
         store: __MODULE__.Store,
         clock: fn -> Agent.get(clock, & &1) end}
      )

    %{opts: [server: server], clock: clock}
  end

  test "mints eight unambiguous characters and persists only its digest", %{opts: opts} do
    assert {:ok, code} = Pairing.request("telegram", "123456", "99", "Alice", opts)
    assert code =~ ~r/^[A-HJ-NP-Z2-9]{8}$/
    [{key, row}] = Store.list(__MODULE__.Store, :channel_pairing_requests)
    assert byte_size(key) == 64
    assert row.code_hash == key
    refute inspect(row) =~ code
    assert row.chat_id == "123456"
    assert row.user_id == "99"
    assert row.display_name == "Alice"
    assert row.expires_at - row.created_at == :timer.hours(1)
    assert {:ok, [%{masked_chat_id: "***3456", age_ms: 0} = safe]} = Pairing.list(opts)
    refute Map.has_key?(safe, :code_hash)
    refute inspect(safe) =~ code
  end

  test "reuses pending request and replies at most every ten minutes", %{opts: opts, clock: clock} do
    assert {:ok, code} = Pairing.request("telegram", 123, 99, "Alice", opts)
    assert :pending = Pairing.request("telegram", 123, 99, "Alice", opts)
    Agent.update(clock, &(&1 + :timer.minutes(10) - 1))
    assert :pending = Pairing.request("telegram", 123, 99, "Alice", opts)
    Agent.update(clock, &(&1 + 1))
    assert {:ok, ^code} = Pairing.request("telegram", 123, 99, "Alice", opts)
    assert length(Store.list(__MODULE__.Store, :channel_pairing_requests)) == 1
  end

  test "atomic single use and wrong-platform rejection", %{opts: opts} do
    assert {:ok, code} = Pairing.request("telegram", 123, 99, "Alice", opts)
    assert {:error, :not_found} = Pairing.consume("discord", code, opts)

    results =
      1..10
      |> Task.async_stream(fn _ -> Pairing.consume("telegram", code, opts) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :not_found})) == 9
    assert {:ok, []} = Pairing.list(opts)
  end

  test "expires at exactly one hour and sweeps stale records", %{opts: opts, clock: clock} do
    assert {:ok, code} = Pairing.request("telegram", 123, 99, "Alice", opts)
    Agent.update(clock, &(&1 + :timer.hours(1)))
    assert {:error, :not_found} = Pairing.consume("telegram", code, opts)
    assert {:ok, _code} = Pairing.request("discord", 456, 99, "Alice", opts)
    Agent.update(clock, &(&1 + :timer.hours(1)))
    assert {:ok, []} = Pairing.list(opts)
    assert [] = Store.list(__MODULE__.Store, :channel_pairing_requests)
  end

  test "caps pending requests at three per platform under concurrent admission", %{opts: opts} do
    results =
      1..12
      |> Task.async_stream(fn id -> Pairing.request("telegram", id, id, "Alice", opts) end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 3
    assert Enum.count(results, &(&1 == {:error, :too_many_pending})) == 9
    assert {:ok, _} = Pairing.request("discord", 1, 1, "Alice", opts)
  end

  test "pending requests survive process restart without persisting the code", %{
    opts: opts,
    clock: clock
  } do
    assert {:ok, code} = Pairing.request("telegram", 123, 99, "Alice", opts)
    :ok = stop_supervised(Pairing)

    server =
      start_supervised!(
        {Pairing,
         name: __MODULE__.Pairing,
         store: __MODULE__.Store,
         clock: fn -> Agent.get(clock, & &1) end}
      )

    assert :pending = Pairing.request("telegram", 123, 99, "Alice", server: server)
    assert {:ok, %{chat_id: "123"}} = Pairing.consume("telegram", code, server: server)
  end

  test "redaction removes pairing values and approval command codes", %{opts: opts} do
    assert {:ok, code} = Pairing.request("telegram", 123, 99, "Alice", opts)
    text = "Pairing code: #{code}\nlemon pairing approve telegram #{code}"
    refute LemonCore.Redact.text(text) =~ code
    assert LemonCore.Redact.map(%{"pairing_code" => code}) == %{"pairing_code" => "[REDACTED]"}
    refute inspect(:sys.get_status(opts[:server])) =~ code
  end
end
