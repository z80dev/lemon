defmodule LemonCore.Store.TableTest do
  use ExUnit.Case, async: true

  alias LemonCore.Store.Table

  defmodule DeclaredStore do
    use LemonCore.Store.Table,
      tables: [
        plain: [],
        cached: [cached: true, persistence: :ephemeral, version: 2],
        expiring: [retention: [expires_at: :expires_at]],
        aged: [retention: [max_age_ms: 1_000, timestamp: {__MODULE__, :timestamp}]]
      ]
  end

  test "use records owner, table names, defaults, and policy metadata" do
    assert [plain, cached, expiring, aged] = DeclaredStore.__store_tables__()

    assert %Table{
             name: :plain,
             owner: DeclaredStore,
             cached: false,
             retention: nil,
             persistence: :durable,
             version: 1
           } = plain

    assert %Table{
             name: :cached,
             owner: DeclaredStore,
             cached: true,
             persistence: :ephemeral,
             version: 2
           } = cached

    assert %Table{retention: [expires_at: :expires_at]} = expiring

    assert %Table{
             retention: [
               max_age_ms: 1_000,
               timestamp: {DeclaredStore, :timestamp}
             ]
           } = aged
  end

  test "declarations reject ambiguous or unsupported metadata" do
    assert_raise ArgumentError, ~r/table owner must be a module/, fn ->
      Table.declare!(nil, plain: [])
    end

    assert_raise ArgumentError, ~r/tables must be a keyword list/, fn ->
      Table.declare!(DeclaredStore, :plain)
    end

    assert_raise ArgumentError, ~r/declares no tables/, fn ->
      Table.declare!(DeclaredStore, [])
    end

    assert_raise ArgumentError, ~r/duplicate tables \[:same\]/, fn ->
      Table.declare!(DeclaredStore, same: [], same: [])
    end

    assert_raise ArgumentError, ~r/unknown options \[:ttl\]/, fn ->
      Table.declare!(DeclaredStore, bad: [ttl: 1])
    end

    assert_raise ArgumentError, ~r/duplicate options \[:cached\]/, fn ->
      Table.declare!(DeclaredStore, bad: [cached: true, cached: false])
    end

    assert_raise ArgumentError, ~r/cached must be a boolean/, fn ->
      Table.declare!(DeclaredStore, bad: [cached: :yes])
    end

    assert_raise ArgumentError, ~r/positive :max_age_ms/, fn ->
      Table.declare!(DeclaredStore, bad: [retention: [max_age_ms: 0, timestamp: :created]])
    end

    assert_raise ArgumentError,
                 ~r/:timestamp must be an atom field or \{module, function\}/,
                 fn ->
                   Table.declare!(DeclaredStore,
                     bad: [retention: [max_age_ms: 1, timestamp: "created"]]
                   )
                 end

    assert_raise ArgumentError, ~r/retention has unsupported options \[:expires_at\]/, fn ->
      Table.declare!(DeclaredStore,
        bad: [retention: [max_age_ms: 1, timestamp: :created, expires_at: :expires_at]]
      )
    end

    assert_raise ArgumentError, ~r/retention has duplicate options \[:timestamp\]/, fn ->
      Table.declare!(DeclaredStore,
        bad: [retention: [max_age_ms: 1, timestamp: :created, timestamp: :updated]]
      )
    end

    assert_raise ArgumentError,
                 ~r/:timestamp must be an atom field or \{module, function\}/,
                 fn ->
                   Table.declare!(DeclaredStore,
                     bad: [retention: [max_age_ms: 1, timestamp: {nil, nil}]]
                   )
                 end

    assert_raise ArgumentError, ~r/persistence must be :durable or :ephemeral/, fn ->
      Table.declare!(DeclaredStore, bad: [persistence: :memory])
    end

    assert_raise ArgumentError, ~r/version must be a positive integer/, fn ->
      Table.declare!(DeclaredStore, bad: [version: 0])
    end
  end
end
