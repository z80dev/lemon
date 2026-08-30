defmodule LemonBrowser.DeveloperModeTest do
  use ExUnit.Case, async: true

  defmodule FakeBackend do
    @behaviour LemonBrowser.Backend

    def id, do: :developer_test
    def available?, do: true
    def available?(_opts), do: true
    def status(_opts), do: %{available: true}
    def request(method, args, timeout, opts), do: {:ok, {method, args, timeout, opts}}
  end

  setup do
    LemonBrowser.BackendRegistry.register(:developer_test, FakeBackend)
    on_exit(fn -> LemonBrowser.BackendRegistry.unregister(:developer_test) end)
  end

  test "raw CDP requires developer mode and blocks browser-lifecycle commands" do
    args = %{"method" => "Runtime.evaluate", "params" => %{"expression" => "6 * 7"}}

    assert {:error, :browser_developer_mode_required} =
             LemonBrowser.request("browser.cdp", args, 500, backend: :developer_test)

    assert {:ok, {"browser.cdp", ^args, 500, opts}} =
             LemonBrowser.request("browser.cdp", args, 500,
               backend: :developer_test,
               developer_mode: true
             )

    assert opts[:developer_mode]

    assert {:error, {:blocked_cdp_method, "Browser.close"}} =
             LemonBrowser.request(
               "browser.cdp",
               %{"method" => "Browser.close", "params" => %{}},
               500,
               backend: :developer_test,
               developer_mode: true
             )
  end
end
