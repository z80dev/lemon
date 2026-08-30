defmodule LemonControlPlane.Methods.CommandsCatalogTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.CommandsCatalog
  alias LemonControlPlane.Methods.Registry
  alias LemonControlPlane.Protocol.Schemas

  test "exposes the portable command catalog as a read-only method" do
    assert CommandsCatalog.name() == "commands.catalog"
    assert CommandsCatalog.scopes() == [:read]
    assert :ok = Schemas.validate(CommandsCatalog.name(), %{})
    assert {:ok, CommandsCatalog} = Registry.lookup(CommandsCatalog.name())

    assert {:ok, response} = CommandsCatalog.handle(%{}, %{})
    assert response["summary"]["version"] == 1
    assert response["summary"]["count"] == length(response["commands"])
    assert Enum.any?(response["commands"], &(&1["command"] == "/queue"))

    assert Enum.any?(
             response["commands"],
             &("/reset" in &1["aliases"] or &1["command"] == "/reset")
           )

    assert {:ok, _json} = Jason.encode(response)
  end
end
