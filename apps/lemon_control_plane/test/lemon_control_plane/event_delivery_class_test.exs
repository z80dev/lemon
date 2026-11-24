defmodule LemonControlPlane.EventDeliveryClassTest do
  @moduledoc """
  Contract for the delivery class table in `docs/platform/bus-events.md` (#87).

  Every registered `LemonCore.Events` type is classified exactly once. A durable
  row must name an exported authority read, so a missed event can be recovered
  from its owner; a transient row must name registered recovery methods.
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.Registry

  @doc_path Path.expand("../../../../docs/platform/bus-events.md", __DIR__)
  @classes ~w(durable transient best_effort)

  setup do
    if is_nil(Process.whereis(Registry)), do: start_supervised!(Registry)
    %{rows: rows(File.read!(@doc_path))}
  end

  test "every registered event type has exactly one known delivery class", %{rows: rows} do
    classified = Enum.flat_map(rows, & &1.types)
    registered = LemonCore.Events.registry() |> Map.keys() |> Enum.map(&Atom.to_string/1)

    assert classified -- Enum.uniq(classified) == [], "types classified more than once"
    assert Enum.sort(registered) -- classified == [], "registered types without a class"
    assert classified -- registered == [], "classified types that are not registered"
    assert Enum.reject(rows, &(&1.class in @classes)) == []
  end

  test "durable events name an exported owner read", %{rows: rows} do
    durable = Enum.filter(rows, &(&1.class == "durable"))
    assert durable != []

    for row <- durable do
      assert [{module, fun, arity} | _] = authorities(row.authority),
             "durable #{inspect(row.types)} names no Module.fun/arity authority"

      assert Code.ensure_loaded?(module), "#{inspect(module)} is not loaded"

      exported = for {name, n} <- module.__info__(:functions), do: {Atom.to_string(name), n}

      assert {fun, arity} in exported,
             "#{inspect(module)}.#{fun}/#{arity} is not exported"
    end
  end

  test "transient events name registered recovery methods", %{rows: rows} do
    transient = Enum.filter(rows, &(&1.class == "transient"))
    assert transient != []

    for row <- transient do
      methods = Regex.scan(~r/`([a-z]+\.[a-z]+)`/, row.authority, capture: :all_but_first)
      assert methods != [], "transient #{inspect(row.types)} names no recovery method"

      for [method] <- methods do
        assert {:ok, _module} = Registry.lookup(method), "#{method} is not registered"
      end
    end
  end

  test "the parser reads every row of the section and nothing after it" do
    doc = """
    ### Delivery class by event type

    | Event type | Class | Authority / recovery |
    | --- | --- | --- |
    | `run_completed`, `run_failed` | durable | `LemonCore.RunStore.fetch/1` |
    | `delta` | transient | `sessions.events` |

    ### Next
    | `ignored` | best_effort | none |
    """

    assert [
             %{types: ["run_completed", "run_failed"], class: "durable", authority: durable},
             %{types: ["delta"], class: "transient"}
           ] = rows(doc)

    assert authorities(durable) == [{LemonCore.RunStore, "fetch", 1}]
  end

  defp rows(doc) do
    [_, section] = String.split(doc, "### Delivery class by event type\n", parts: 2)
    [section | _] = String.split(section, "\n### ", parts: 2)

    for "| `" <> _ = line <- String.split(section, "\n") do
      [types, class, authority] =
        line |> String.trim() |> String.trim("|") |> String.split(" | ", parts: 3)

      %{
        types: Regex.scan(~r/`([a-z_]+)`/, types, capture: :all_but_first) |> List.flatten(),
        class: String.trim(class),
        authority: authority
      }
    end
  end

  defp authorities(text) do
    for [module, fun, arity] <-
          Regex.scan(~r/`((?:[A-Z]\w*\.)+)([a-z_]+[?!]?)\/(\d+)`/, text, capture: :all_but_first) do
      {Module.concat([String.trim_trailing(module, ".")]), fun, String.to_integer(arity)}
    end
  end
end
