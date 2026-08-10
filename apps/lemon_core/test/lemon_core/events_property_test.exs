defmodule LemonCore.EventsPropertyTest do
  @moduledoc """
  Property-based invariants for the typed `LemonCore.Events` payload contract,
  asserted against the real registered payload modules (no synthetic stand-in).

  For every *registered* payload whose `from_map/1` is the generic one supplied
  by `LemonCore.Events.Payload`:

    * `new/1 |> Map.from_struct/1 |> from_map/1` returns the original struct;
    * `from_map/1` drops arbitrary extra string keys;
    * `false`/`nil` values survive `from_map/1` through both atom and string keys
      (the class of bug where `Map.get(m, k) || Map.get(m, "k")` silently turns a
      real `false` into `nil`);
    * `new/1` raises on any unknown key.

  The five modules that override `from_map/1` to rebuild a nested payload
  (`Completion`/`Action`) are asserted at the struct-passthrough level and carry
  their own example tests; a generic value round-trip does not apply to them by
  design.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias LemonCore.Events

  # Payload modules that redefine from_map/1 to coerce a nested struct.
  @nested_override [
    Events.Action,
    Events.ApprovalRequested,
    Events.ApprovalResolved,
    Events.EngineAction,
    Events.RunCompleted
  ]

  # GoalChanged is a generic module carrying a boolean field, which makes it the
  # natural probe for false/nil survival.
  @bool_module Events.GoalChanged
  @bool_field :loop_auto_enabled

  defp scalar do
    one_of([
      string(:printable),
      integer(),
      boolean(),
      constant(nil),
      atom(:alphanumeric)
    ])
  end

  defp generic_modules do
    Enum.reject(Events.modules(), &(&1 in @nested_override))
  end

  # Alphanumeric keys prefixed so they can never collide with a real field name.
  defp unknown_key do
    map(string(:alphanumeric, min_length: 1), &("zz_unknown_" <> &1))
  end

  defp attrs_for(module, values) do
    module.fields() |> Enum.zip(Stream.cycle(values)) |> Map.new()
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  property "generic modules round-trip new/1 |> Map.from_struct |> from_map" do
    check all(
            module <- member_of(generic_modules()),
            values <- list_of(scalar(), length: 12)
          ) do
      struct = module.new(attrs_for(module, values))
      round = struct |> Map.from_struct() |> module.from_map()

      assert round == struct
    end
  end

  property "generic modules tolerate arbitrary extra string keys" do
    check all(
            module <- member_of(generic_modules()),
            values <- list_of(scalar(), length: 12),
            extra <- map_of(unknown_key(), scalar(), max_length: 4)
          ) do
      struct = module.new(attrs_for(module, values))
      polluted = Map.merge(stringify_keys(Map.from_struct(struct)), extra)

      assert module.from_map(polluted) == struct
    end
  end

  property "new/1 raises on any unknown key" do
    check all(
            module <- member_of(generic_modules()),
            values <- list_of(scalar(), length: 12),
            bad_key <- unknown_key()
          ) do
      attrs = Map.put(attrs_for(module, values), String.to_atom(bad_key), 1)

      assert_raise ArgumentError, fn -> module.new(attrs) end
    end
  end

  property "false and nil booleans survive from_map through atom and string keys" do
    check all(
            flag <- one_of([boolean(), constant(nil)]),
            use_string_keys <- boolean()
          ) do
      attrs =
        if use_string_keys do
          %{"goal_id" => "g", Atom.to_string(@bool_field) => flag}
        else
          %{:goal_id => "g", @bool_field => flag}
        end

      assert %{@bool_field => ^flag} = @bool_module.from_map(attrs)
    end
  end

  property "every payload module passes its own struct through from_map unchanged" do
    check all(
            module <- member_of(Events.modules()),
            values <- list_of(scalar(), length: 12)
          ) do
      struct = struct(module, attrs_for(module, values))

      assert module.from_map(struct) == struct
    end
  end
end
