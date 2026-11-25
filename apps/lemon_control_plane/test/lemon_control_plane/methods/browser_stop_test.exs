defmodule LemonControlPlane.Methods.BrowserStopTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{BrowserStop, Registry}
  alias LemonControlPlane.Protocol.Schemas

  test "browser.stop is an admin method with an empty-object schema" do
    assert {:ok, BrowserStop} = Registry.lookup("browser.stop")
    assert BrowserStop.scopes() == [:admin]
    assert Schemas.get("browser.stop") == %{optional: %{}}
  end

  test "stops the supervised local browser driver" do
    assert {:ok, %{"stopped" => true}} = BrowserStop.handle(%{}, %{})
    assert {:ok, %{"stopped" => true}} = BrowserStop.handle(nil, %{})
    assert %{running: false} = LemonBrowser.LocalServer.status()
  end

  test "rejects parameters" do
    assert {:error, {:invalid_request, _, nil}} = BrowserStop.handle(%{"force" => true}, %{})
  end
end
