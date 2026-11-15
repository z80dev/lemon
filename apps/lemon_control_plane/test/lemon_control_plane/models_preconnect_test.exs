defmodule LemonControlPlane.ModelsPreconnectTest do
  use ExUnit.Case, async: true
  alias LemonControlPlane.Methods.ModelsPreconnect

  test "hints require write scope and expose no arbitrary URL warming" do
    assert ModelsPreconnect.name() == "models.preconnect"
    assert ModelsPreconnect.scopes() == [:write]

    assert {:ok, %{"accepted" => false}} =
             ModelsPreconnect.handle(%{"model" => "https://127.0.0.1:1/private"}, %{})

    assert {:ok, %{"accepted" => false}} =
             ModelsPreconnect.handle(%{"model" => "unknown:unavailable"}, %{})
  end

  test "missing and oversized identifiers are refused" do
    assert {:error, :invalid_request, _, nil} = ModelsPreconnect.handle(%{}, %{})

    assert {:error, :invalid_request, _, nil} =
             ModelsPreconnect.handle(%{"model" => String.duplicate("x", 257)}, %{})
  end
end
