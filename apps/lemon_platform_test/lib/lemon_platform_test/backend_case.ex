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
  persists, and it is deliberately tiny — nine callbacks, no supervision, no
  process of its own. `LemonCore.Store.EtsBackend` (ephemeral),
  `LemonCore.Store.SqliteBackend` (durable) and `LemonCore.Store.JsonlBackend`
  (append-only files) are the built-ins; a Redis or Postgres backend is a
  reasonable thing to write, and this suite is what tells you it will work.

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
  what went in. Backends that serialise (SQLite via `:erlang.term_to_binary/1`,
  JSONL via a JSON encoding) inherit the limits of their encoding: pids,
  references and functions are **not** required to round-trip, and this suite
  does not test them.

  ### Optional callbacks degrade predictably

  `compare_and_delete_many/2`, `list_recent/3`, and `ping/1` are optional. If
  you export them they must honour their contracts: multi-delete validates
  every exact snapshot before deleting in caller-provided order,
  `list_recent/3` returns at most `limit` real entries of that table, and
  `ping/1` answers without disturbing data. If you do not export them the store
  falls back to its serialized validate/delete path, falls back to `list/2`, or
  reports the backend as unpingable, respectively.

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

        case @backend.init(opts) do
          {:ok, state} ->
            {:ok, state: state, backend_opts: opts}

          other ->
            flunk("#{inspect(@backend)}.init/1 must return {:ok, state}, got: #{inspect(other)}")
        end
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
              {@alpha, "first", %{version: 2}},
              {@beta, "fence", :claimed}
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

        test "ping/1, when exported, answers without disturbing the data", %{state: state} do
          if function_exported?(@backend, :ping, 1) do
            {:ok, state} = @backend.put(state, @alpha, "k", "v")

            assert {:ok, state} = apply(@backend, :ping, [state])
            assert {:ok, "v", _state} = @backend.get(state, @alpha, "k")
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
