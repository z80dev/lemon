defmodule LemonBrowser.LocalInspectionTest do
  use ExUnit.Case, async: true
  alias LemonBrowser.LocalServer

  @tag :tmp_dir
  test "worker-local configuration inspection never starts the driver or projects credentials into status", %{tmp_dir: root} do
    driver = Path.join(root, "local-driver.js")
    File.write!(driver, "process.exit(99);")
    endpoint = "ws://127.0.0.1:9224/cdp?token=private-inspection-token"
    server = start_supervised!({LocalServer, name: nil, driver_path: driver, cdp_endpoint: endpoint, attach_only: true})
    refute LocalServer.status(server).running
    assert {:ok, config} = LocalServer.inspection_config(server)
    assert config["driverPath"] == driver
    assert config["endpoint"] == endpoint
    assert config["attachOnly"]
    refute config["launchesBrowser"]
    status = LocalServer.status(server)
    refute status.running
    assert status.request_count == 0
    refute inspect(status) =~ "private-inspection-token"
    refute inspect(status) =~ driver
  end
end
