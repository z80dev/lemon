defmodule CodingAgent.ExecutionNode.BrowserInspectionTest do
  use ExUnit.Case, async: true
  alias CodingAgent.ExecutionNode.HostCommand

  @tag :tmp_dir
  test "measures executable presence without launching the browser or exposing endpoint data", %{
    tmp_dir: root
  } do
    marker = Path.join(root, "browser-was-started")
    executable = Path.join(root, "fake-browser")
    File.write!(executable, "#!/bin/sh\ntouch '#{marker}'\n")
    File.chmod!(executable, 0o700)
    File.write!(Path.join(root, "package.json"), ~s({"type":"module"}))

    File.write!(Path.join(root, "index.js"), """
    delete process.env.LEMON_BROWSER_EXECUTABLE;
    export function defaultChromeExecutable() { return #{Jason.encode!(executable)}; }
    export function cdpDiscoveryUrl(endpoint) { return new URL('/json/version', endpoint).toString(); }
    """)

    helper = Path.join(to_string(:code.priv_dir(:lemon_browser)), "node_browser_inspect.mjs")

    config = %{
      "driverPath" => Path.join(root, "local-driver.js"),
      "endpoint" => "",
      "port" => 9,
      "launchesBrowser" => true,
      "attachOnly" => false
    }

    assert {:ok, output} = HostCommand.run("node", [helper], input: Jason.encode!(config) <> "\n")
    assert {:ok, result} = Jason.decode(output)
    assert result["supported"]
    assert result["available"]
    assert result["configured"]
    assert result["reason"] in ["browser_executable_measured", "browser_cdp_measured"]
    refute File.exists?(marker)
    refute output =~ executable
    refute output =~ "127.0.0.1"
  end

  test "inspection failures return a classification rather than echoing credentials" do
    helper = Path.join(to_string(:code.priv_dir(:lemon_browser)), "node_browser_inspect.mjs")

    config = %{
      "driverPath" => "/missing/local-driver.js",
      "endpoint" => "ws://127.0.0.1:9?token=do-not-project"
    }

    assert {:ok, output} = HostCommand.run("node", [helper], input: Jason.encode!(config) <> "\n")
    assert Jason.decode!(output) == %{"error" => "inspection_unavailable"}
    refute output =~ "do-not-project"
  end
end
