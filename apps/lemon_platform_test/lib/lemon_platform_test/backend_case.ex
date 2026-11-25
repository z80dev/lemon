# credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
# This is an ExUnit CaseTemplate: the `using/1` quote block is intentionally
# large because it injects the entire compliance suite into the including test
# module. Splitting it would obscure the contract it exists to express.
defmodule LemonPlatformTest.BackendCase do
  @moduledoc """
  Compliance suite for `LemonCore.Store.Backend` implementations.

  ## What a backend is

  `LemonCore.Store` is the platform's key/value store: a `GenServer` that owns a
  backend and serialises access to it. The backend is the part that actually
  persists, with no supervision or process of its own.
  `LemonCore.Store.EtsBackend` (ephemeral)
  and `LemonCore.Store.SqliteBackend` (durable) are the built-ins; a Redis or
  Postgres backend is a reasonable thing to write, and this suite is what tells
  you it will work.

  ## The contract

  A backend stores values under a `{table, key}` pair, where `table` is an atom
  chosen by the caller and `key` and `value` are arbitrary terms. Beyond the
  `@callback` signatures, implementations must obey these rules — each is a test
  in this suite.

  ### State is threaded, never global

  `init/1` returns opaque state; every other callback takes state and returns
  new state, including the read paths (`get/3`, `list/2`) which return
  `{:ok, result, state}` rather than `{:ok, result}`. The store always uses the
  returned state for the next call. A backend may keep its real data outside the
  state (`EtsBackend` keeps table references; `SqliteBackend` keeps a
  connection), but it must never require a caller to discard the state it was
  handed.

  ### Tables spring into existence

  Callers pass whatever table atom they like, including on the very first call
  and including for reads. A backend must not error on an unknown table: reading
  from one yields `nil`/`[]`, writing to one creates it. `init/1` cannot know
  the set of tables in advance.

  ### Reads are total

  `get/3` on a missing key returns `{:ok, nil, state}` — not `{:error, ...}`,
  not `:not_found`. Consequently a stored `nil` is indistinguishable from an
  absent key through `get/3`; `list/2` is where the difference shows up, and it
  must show up there.

  ### Writes are idempotent, deletes are forgiving

  `put/4` overwrites silently. `delete/3` on a key that is not there succeeds.
  `put_new/4` is the one conditional write: `{:ok, state}` when it inserted,
  `{:exists, state}` when it did not. `{:exists, state}` must leave the existing
  value untouched — it is the platform's only compare-and-set primitive, and
  idempotency keys depend on it.

  ### Terms round-trip

  Keys and values are Erlang terms, not strings. Binaries (including non-ASCII),
  atoms, integers, floats, tuples, nested maps and lists must come back equal to
  what went in. Backends that serialise (SQLite via `:erlang.term_to_binary/1`)
  inherit the limits of their encoding: pids, references and functions are
  **not** required to round-trip, and this suite does not test them.

  ### Optional callbacks degrade predictably

  `compare_and_delete_many/2`, `compare_and_swap/5`, `confirm_durable/1`,
  `list_recent/3`, `ping/1`, `reader/1` (with `read_keys/2`, `read_list/2`, `read_range/5`
  and `read_recent/3`), `sync/1` and `with_durability/2` are optional.
  Multi-delete validates every exact snapshot before deleting in caller-provided
  order; compare-and-swap writes only over an exact match (a missing key matching
  `nil`); `list_recent/3` returns at most `limit` real entries of that table;
  `read_list/2` through a `reader/1` handle returns, from any process, what
  `list/2` has. `ping/1`, `sync/1` and `confirm_durable/1` answer without
  disturbing data. Without these callbacks Store falls back to serialized
  validate/delete or compare/write, falls back to `list/2`, reads inside the
  Store process, reports the backend as unpingable, or answers `sync/1` with
  `:sync_unsupported`, respectively.

  `with_durability(state, operation)` runs the zero-arity mutation synchronously
  exactly once, returns its result unchanged, and restores ordinary write mode
  even if the operation raises or throws. Store serializes that entire scope.
  Without it, Store runs the mutation and then `sync/1`; a failed durable
  mutation/barrier is `:outcome_unknown`, not an automatically retryable write.
  `confirm_durable/1` confirms visible authority with `{:ok, state}` or refuses
  with `{:error, reason}`. Transaction-durable backends may avoid an additional
  barrier (SQLite releases cached statements without checkpointing); without
  this callback Store uses `sync/1` so a visible row from a previously failed
  barrier cannot falsely acknowledge success.

  This suite checks invocation, result/failure propagation, usable state and
  data preservation. Backend-specific tests must prove actual power-loss
  barriers and restoration of backend-specific synchronization settings.

  ## Minimal implementation

      defmodule MyApp.MapBackend do
        @behaviour LemonCore.Store.Backend

        @impl true
        def init(opts), do: {:ok, Keyword.get(opts, :seed, %{})}

        @impl true
        def put(state, table, key, value) do
          {:ok, Map.update(state, table, %{key => value}, &Map.put(&1, key, value))}
        end

        @impl true
        def put_new(state, table, key, value) do
          if Map.has_key?(Map.get(state, table, %{}), key) do
            {:exists, state}
          else
            put(state, table, key, value)
          end
        end

        @impl true
        def get(state, table, key), do: {:ok, state |> Map.get(table, %{}) |> Map.get(key), state}

        @impl true
        def delete(state, table, key) do
          {:ok, Map.update(state, table, %{}, &Map.delete(&1, key))}
        end

        @impl true
        def list(state, table), do: {:ok, state |> Map.get(table, %{}) |> Map.to_list(), state}
      end

  ## Running the suite

      defmodule MyApp.MapBackendComplianceTest do
        use LemonPlatformTest.BackendCase, async: true, backend: MyApp.MapBackend
      end

  A backend that needs a directory or a file gets one per test — the suite tags
  every test with `:tmp_dir`, so a `{Module, :function}` supplier can read
  `context.tmp_dir`:

      defmodule MyApp.DiskBackendComplianceTest do
        use LemonPlatformTest.BackendCase,
          async: true,
          backend: MyApp.DiskBackend,
          backend_opts: {__MODULE__, :backend_opts},
          persistent: true

        def backend_opts(context), do: [path: context.tmp_dir]
      end

  ## Options

    * `:backend` — required, the module under test.
    * `:backend_opts` — options passed to `init/1`. Either a literal keyword
      list (default `[]`) or `{Module, :function}`, called with the test context
      and returning a keyword list.
    * `:persistent` — set to `true` for a backend that survives re-`init/1` with
      the same options (SQLite, JSONL, anything on disk or over a network). Adds
      a test that data written through one state is visible through a second
      `init/1`. Default `false`.
    * `:tables` — the two table atoms the suite writes to. Default
      `[:lemon_platform_test_alpha, :lemon_platform_test_beta]`. Override if
      your backend only supports a fixed set of tables.

  ## Known gaps in the behaviour

  Recorded here because they bound what this suite can check, and because they
  are the places the contract is most likely to change:

    * **There is no teardown callback.** A backend that holds a connection or a
      file handle has nowhere to close it; `LemonCore.Store` never tells the
      backend it is going away. `SqliteBackend` exposes a `close/1` that is not
      part of the behaviour.
    * **Error reasons are convention, not contract.** The `{:error, term()}`
      returns are typed as `term()`, and the built-in SQLite backend answers
      with implementation-specific atoms such as `:sqlite_busy`. Callers cannot
      portably match on "temporarily unavailable", so this suite asserts the
      `{:error, _}` shape and nothing about the reason.
  """

  use ExUnit.CaseTemplate

  @default_tables [:lemon_platform_test_alpha, :lemon_platform_test_beta]

  using opts do
    LemonPlatformTest.require_dep!("BackendCase", LemonCore.Store.Backend, :lemon_core)

    backend = Keyword.fetch!(opts, :backend)
    backend_opts = Keyword.get(opts, :backend_opts, [])
    persistent? = Keyword.get(opts, :persistent, false)
    tables = Keyword.get(opts, :tables, @default_tables)
    label = Macro.to_string(backend)

    quote do
      @moduletag :tmp_dir

      @backend unquote(backend)
      @backend_opts_spec unquote(backend_opts)
      @tables unquote(tables)
      @alpha hd(@tables)
      @beta Enum.at(@tables, 1)
      @spare_table :lemon_platform_test_untouched

      setup context do
        opts = LemonPlatformTest.resolve(@backend_opts_spec, context)

        assert {:ok, state} = @backend.init(opts)
        {:ok, state: state, backend_opts: opts}
      end

      # Reads have to return usable state too, so the state-threading test
      # interleaves one into its write chain.
      defp lemon_backend_touch(state, n) do
        {:ok, _previous, state} = @backend.get(state, @beta, :counter)
        {:ok, state} = @backend.put(state, @beta, :counter, n)
        state
      end

      describe unquote(label <> " behaviour declaration") do
        test "declares LemonCore.Store.Backend" do
          assert LemonPlatformTest.declares_behaviour?(@backend, LemonCore.Store.Backend),
                 "#{inspect(@backend)} must declare `@behaviour LemonCore.Store.Backend`"
        end

        test "exports every required callback" do
          assert LemonPlatformTest.missing_callbacks(@backend, LemonCore.Store.Backend) == []
        end
      end

      describe unquote(label <> " init/1") do
        test "returns {:ok, state}", context do
          opts = LemonPlatformTest.resolve(@backend_opts_spec, context)
          assert {:ok, _state} = @backend.init(opts)
        end
      end

      describe unquote(label <> " reads") do
        test "get on an unknown key returns nil and usable state", %{state: state} do
          assert {:ok, nil, state} = @backend.get(state, @alpha, "never-written")
          assert {:ok, nil, _state} = @backend.get(state, @alpha, "never-written")
        end

        test "get on a table that was never written returns nil", %{state: state} do
          assert {:ok, nil, _state} = @backend.get(state, @spare_table, "k")
        end

        test "list on a table that was never written returns an empty list", %{state: state} do
          assert {:ok, [], _state} = @backend.list(state, @spare_table)
        end

        test "list returns every stored pair", %{state: state} do
          {:ok, state} = @backend.put(state, @alpha, "a", 1)
          {:ok, state} = @backend.put(state, @alpha, "b", 2)

          assert {:ok, entries, _state} = @backend.list(state, @alpha)
          assert Enum.sort(entries) == [{"a", 1}, {"b", 2}]
        end

        test "list reflects deletes", %{state: state} do
          {:ok, state} = @backend.put(state, @alpha, "a", 1)
          {:ok, state} = @backend.put(state, @alpha, "b", 2)
          {:ok, state} = @backend.delete(state, @alpha, "a")

          assert {:ok, [{"b", 2}], _state} = @backend.list(state, @alpha)
        end

        test "list distinguishes a stored nil from an absent key", %{state: state} do
          {:ok, state} = @backend.put(state, @alpha, "explicit-nil", nil)

          assert {:ok, nil, state} = @backend.get(state, @alpha, "explicit-nil")
          assert {:ok, [{"explicit-nil", nil}], _state} = @backend.list(state, @alpha)
        end
      end

      describe unquote(label <> " writes") do
        test "put then get round-trips", %{state: state} do
          assert {:ok, state} = @backend.put(state, @alpha, "k", %{v: 1})
          assert {:ok, %{v: 1}, _state} = @backend.get(state, @alpha, "k")
        end

        test "put overwrites an existing value", %{state: state} do
          {:ok, state} = @backend.put(state, @alpha, "k", "first")
          {:ok, state} = @backend.put(state, @alpha, "k", "second")

          assert {:ok, "second", state} = @backend.get(state, @alpha, "k")
          assert {:ok, [{"k", "second"}], _state} = @backend.list(state, @alpha)
        end

        test "put_new inserts when the key is absent", %{state: state} do
          assert {:ok, state} = @backend.put_new(state, @alpha, "k", "value")
          assert {:ok, "value", _state} = @backend.get(state, @alpha, "k")
        end

        test "put_new reports :exists and keeps the original value", %{state: state} do
          {:ok, state} = @backend.put_new(state, @alpha, "k", "original")

          assert {:exists, state} = @backend.put_new(state, @alpha, "k", "replacement")
          assert {:ok, "original", _state} = @backend.get(state, @alpha, "k")
        end

        test "delete removes the value", %{state: state} do
          {:ok, state} = @backend.put(state, @alpha, "k", "value")

          assert {:ok, state} = @backend.delete(state, @alpha, "k")
          assert {:ok, nil, _state} = @backend.get(state, @alpha, "k")
        end

        test "delete of an absent key succeeds", %{state: state} do
          assert {:ok, state} = @backend.delete(state, @alpha, "never-written")
          assert {:ok, _state} = @backend.delete(state, @spare_table, "k")
        end
      end

      describe unquote(label <> " table isolation") do
        test "the same key in two tables holds two values", %{state: state} do
          {:ok, state} = @backend.put(state, @alpha, "shared", "alpha value")
          {:ok, state} = @backend.put(state, @beta, "shared", "beta value")

          assert {:ok, "alpha value", state} = @backend.get(state, @alpha, "shared")
          assert {:ok, "beta value", state} = @backend.get(state, @beta, "shared")

          {:ok, state} = @backend.delete(state, @alpha, "shared")

          assert {:ok, nil, state} = @backend.get(state, @alpha, "shared")
          assert {:ok, "beta value", _state} = @backend.get(state, @beta, "shared")
        end

        test "listing one table never leaks another", %{state: state} do
          {:ok, state} = @backend.put(state, @alpha, "a", 1)
          {:ok, state} = @backend.put(state, @beta, "b", 2)

          assert {:ok, [{"a", 1}], state} = @backend.list(state, @alpha)
          assert {:ok, [{"b", 2}], _state} = @backend.list(state, @beta)
        end
      end

      describe unquote(label <> " state threading") do
        test "a long chain of operations stays consistent", %{state: state} do
          state =
            Enum.reduce(1..25, state, fn n, acc ->
              {:ok, acc} = @backend.put(acc, @alpha, {:key, n}, n * n)
              lemon_backend_touch(acc, n)
            end)

          assert {:ok, entries, state} = @backend.list(state, @alpha)
          assert length(entries) == 25
          assert {:ok, 400, state} = @backend.get(state, @alpha, {:key, 20})
          assert {:ok, 25, _state} = @backend.get(state, @beta, :counter)
        end
      end

      describe unquote(label <> " term round-trips") do
        test "key types", %{state: state} do
          keys = [
            "binary key",
            :atom_key,
            42,
            {:composite, "key", 3},
            %{nested: %{map: true}},
            ["list", :key]
          ]

          state =
            Enum.reduce(keys, state, fn key, acc ->
              {:ok, acc} = @backend.put(acc, @alpha, key, {:value_for, key})
              acc
            end)

          for key <- keys do
            assert {:ok, {:value_for, ^key}, _} = @backend.get(state, @alpha, key),
                   "key #{inspect(key)} did not round-trip"
          end
        end

        test "value types", %{state: state} do
          values = [
            nil,
            true,
            0,
            -17,
            3.5,
            :an_atom,
            "a binary",
            "üñïçø∂é ☃",
            String.duplicate("x", 64_000),
            {:tuple, [1, 2, 3]},
            %{a: %{b: %{c: [1, "2", :three]}}},
            [%{k: :v}, {:t, 1}, []]
          ]

          state =
            values
            |> Enum.with_index()
            |> Enum.reduce(state, fn {value, index}, acc ->
              {:ok, acc} = @backend.put(acc, @alpha, {:value, index}, value)
              acc
            end)

          for {value, index} <- Enum.with_index(values) do
            assert {:ok, ^value, _} = @backend.get(state, @alpha, {:value, index}),
                   "value #{inspect(value, limit: 5, printable_limit: 32)} did not round-trip"
          end
        end
      end

      # Optional callbacks are reached through apply/3: a direct call would make
      # the compiler warn about an undefined function for every backend that
      # legitimately does not implement them.
      describe unquote(label <> " optional callbacks") do
        test "compare_and_delete_many/2, when exported, validates before deleting", %{
          state: state
        } do
          if function_exported?(@backend, :compare_and_delete_many, 2) do
            {:ok, state} = @backend.put(state, @alpha, "first", %{version: 1})
            {:ok, state} = @backend.put(state, @beta, "fence", :claimed)

            mismatched = [
              {@alpha, "first", %{version: 1}},
              {@beta, "fence", :released}
            ]

            assert {:error, :mismatch, state} =
                     apply(@backend, :compare_and_delete_many, [state, mismatched])

            assert {:ok, %{version: 1}, state} = @backend.get(state, @alpha, "first")
            assert {:ok, :claimed, state} = @backend.get(state, @beta, "fence")

            exact = [
              {@alpha, "first", %{version: 1}},
              {@beta, "fence", :claimed}
            ]

            assert {:ok, state} =
                     apply(@backend, :compare_and_delete_many, [state, exact])

            assert {:ok, nil, state} = @backend.get(state, @alpha, "first")
            assert {:ok, nil, _state} = @backend.get(state, @beta, "fence")
          end
        end

        test "list_recent/3, when exported, returns at most `limit` real entries", %{state: state} do
          if function_exported?(@backend, :list_recent, 3) do
            state =
              Enum.reduce(1..5, state, fn n, acc ->
                {:ok, acc} = @backend.put(acc, @alpha, "k#{n}", n)
                acc
              end)

            assert {:ok, all, state} = @backend.list(state, @alpha)
            assert {:ok, recent, state} = apply(@backend, :list_recent, [state, @alpha, 3])
            assert length(recent) <= 3

            for entry <- recent do
              assert entry in all,
                     "list_recent/3 returned #{inspect(entry)}, which list/2 does not have"
            end

            assert {:ok, [], _state} = apply(@backend, :list_recent, [state, @spare_table, 3])
          end
        end

        test "reader/1, when exported, reads committed rows from another process", %{
          state: state
        } do
          if function_exported?(@backend, :reader, 1) do
            rows = [{"early", %{at_ms: 5}}, {"inside", %{at_ms: 10}}, {"untimed", %{at_ms: nil}}]

            state =
              Enum.reduce(rows, state, fn {key, value}, acc ->
                {:ok, acc} = @backend.put(acc, @alpha, key, value)
                acc
              end)

            reader = apply(@backend, :reader, [state])
            {:ok, all, _state} = @backend.list(state, @alpha)

            read = fn fun, args ->
              Task.async(fn -> apply(@backend, fun, [reader | args]) end) |> Task.await()
            end

            assert {:ok, listed} = read.(:read_list, [@alpha])
            assert Enum.sort(listed) == Enum.sort(all)
            assert {:ok, []} = read.(:read_list, [@spare_table])

            if function_exported?(@backend, :read_keys, 2) do
              assert {:ok, keys} = read.(:read_keys, [@alpha])
              assert Enum.sort(keys) == ["early", "inside", "untimed"]
            end

            if function_exported?(@backend, :read_range, 5) do
              assert {:ok, [{"inside", _}]} = read.(:read_range, [@alpha, 10, 11, false])
              assert {:ok, ranged} = read.(:read_range, [@alpha, 10, 11, true])
              assert ranged |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["inside", "untimed"]
            end
          end
        end

        test "ping/1, when exported, answers without disturbing the data", %{state: state} do
          if function_exported?(@backend, :ping, 1) do
            {:ok, state} = @backend.put(state, @alpha, "k", "v")

            assert {:ok, state} = apply(@backend, :ping, [state])
            assert {:ok, "v", _state} = @backend.get(state, @alpha, "k")
          end
        end

        test "compare_and_swap/5, when exported, writes only over an exact match", %{
          state: state
        } do
          if function_exported?(@backend, :compare_and_swap, 5) do
            {:ok, state} = @backend.put(state, @alpha, "cas", %{version: 1})

            assert {:error, :mismatch, state} =
                     apply(@backend, :compare_and_swap, [
                       state,
                       @alpha,
                       "cas",
                       %{version: 0},
                       %{version: 2}
                     ])

            assert {:ok, %{version: 1}, state} = @backend.get(state, @alpha, "cas")

            assert {:ok, state} =
                     apply(@backend, :compare_and_swap, [
                       state,
                       @alpha,
                       "cas",
                       %{version: 1},
                       %{version: 2}
                     ])

            assert {:ok, %{version: 2}, state} = @backend.get(state, @alpha, "cas")

            assert {:ok, state} =
                     apply(@backend, :compare_and_swap, [state, @alpha, "new", nil, :created])

            assert {:ok, :created, _state} = @backend.get(state, @alpha, "new")
          end
        end

        test "sync/1, when exported, answers without disturbing the data", %{state: state} do
          if function_exported?(@backend, :sync, 1) do
            {:ok, state} = @backend.put(state, @alpha, "k", "v")

            # `{:error, _}` is a legitimate answer where durability cannot be
            # confirmed on this host; either way the data must be untouched.
            state =
              case apply(@backend, :sync, [state]) do
                {:ok, state} -> state
                {:error, _reason} -> state
              end

            assert {:ok, "v", _state} = @backend.get(state, @alpha, "k")
          end
        end

        test "confirm_durable/1, when exported, preserves data and usable state", %{state: state} do
          if function_exported?(@backend, :confirm_durable, 1) do
            {:ok, state} = @backend.put(state, @alpha, "confirmed", %{version: 1})

            state =
              case apply(@backend, :confirm_durable, [state]) do
                {:ok, state} -> state
                {:error, _reason} -> state
              end

            assert {:ok, %{version: 1}, state} = @backend.get(state, @alpha, "confirmed")
            assert {:ok, state} = @backend.put(state, @alpha, "after-confirmation", true)
            assert {:ok, true, _state} = @backend.get(state, @alpha, "after-confirmation")
          end
        end

        test "with_durability/2, when exported, invokes once and returns the mutation result", %{
          state: state
        } do
          if function_exported?(@backend, :with_durability, 2) do
            marker = make_ref()

            operation = fn ->
              send(self(), {:durable_operation, marker})
              @backend.put(state, @alpha, "durable-operation", %{version: 1})
            end

            assert {:ok, state} = apply(@backend, :with_durability, [state, operation])
            assert_received {:durable_operation, ^marker}
            refute_received {:durable_operation, ^marker}
            assert {:ok, %{version: 1}, state} = @backend.get(state, @alpha, "durable-operation")
            assert {:ok, state} = @backend.put(state, @alpha, "ordinary-after-durable", true)
            assert {:ok, true, _state} = @backend.get(state, @alpha, "ordinary-after-durable")
          end
        end

        test "with_durability/2, when exported, preserves failures and remains usable", %{
          state: state
        } do
          if function_exported?(@backend, :with_durability, 2) do
            assert {:error, :injected_operation_failure} =
                     apply(@backend, :with_durability, [
                       state,
                       fn -> {:error, :injected_operation_failure} end
                     ])

            assert_raise RuntimeError, "injected durable operation failure", fn ->
              apply(@backend, :with_durability, [
                state,
                fn -> raise "injected durable operation failure" end
              ])
            end

            assert catch_throw(
                     apply(@backend, :with_durability, [
                       state,
                       fn -> throw(:injected_durable_throw) end
                     ])
                   ) ==
                     :injected_durable_throw

            assert {:ok, state} = @backend.put(state, @alpha, "after-failure", true)
            assert {:ok, true, _state} = @backend.get(state, @alpha, "after-failure")
          end
        end
      end

      if unquote(persistent?) do
        describe unquote(label <> " durability") do
          test "a second init/1 with the same options sees earlier writes", %{
            state: state,
            backend_opts: backend_opts
          } do
            {:ok, state} = @backend.put(state, @alpha, "durable", %{written: true})
            {:ok, _state} = @backend.put(state, @beta, {:tuple, :key}, "durable too")

            assert {:ok, reopened} = @backend.init(backend_opts)
            assert {:ok, %{written: true}, reopened} = @backend.get(reopened, @alpha, "durable")
            assert {:ok, "durable too", _} = @backend.get(reopened, @beta, {:tuple, :key})
          end
        end
      end
    end
  end
end
