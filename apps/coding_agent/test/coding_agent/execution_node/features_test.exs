defmodule CodingAgent.ExecutionNode.FeaturesTest do
  use ExUnit.Case, async: true
  alias CodingAgent.ExecutionNode.Features

  @methods ~w(node.host.info node.capabilities.get node.runtime.features node.fs.list node.fs.stat node.fs.read node.fs.write node.fs.mkdir node.fs.move node.fs.delete.preview node.fs.delete node.secrets.set node.secrets.list node.secrets.delete node.secrets.receipt node.shell.open node.shell.input node.shell.resize node.shell.close node.mcp.discover node.profile.sync node.profile.sync.status node.profile.paths)
  @opts [
    platform: {:unix, :linux},
    python_supported: true,
    assets: %{"node_fs.py" => true, "node_pty.py" => true},
    native_execution_policy: true,
    secret_receipts: true
  ]

  defp capabilities do
    Map.new(@methods, &{&1, %{"version" => 1}})
    |> Map.put("coding_agent.run", %{
      "version" => 2,
      "executionContext" => %{"version" => 1},
      "nativePrivacyContext" => %{"version" => 1}
    })
    |> Map.put("node.invoke.event", %{"version" => 1, "maxBytes" => 65_536})
    |> Map.put("node.enrollment", %{"version" => 1, "repairInvites" => true})
  end

  test "readiness requires every installed API family, not a version string alone" do
    assert %{"protocol" => 1, "botReady" => true, "missingFeatures" => [], "features" => flags} =
             Features.snapshot(capabilities(), @opts)

    assert map_size(flags) == 10
    assert Enum.all?(Map.values(flags), &(&1 == true))

    for {method, flag} <- [
          {"node.secrets.receipt", "encryptedSecrets"},
          {"node.profile.paths", "profileSync"},
          {"node.fs.delete.preview", "deletePreviews"},
          {"node.invoke.event", "liveStreaming"}
        ] do
      snapshot = Features.snapshot(Map.delete(capabilities(), method), @opts)
      refute snapshot["botReady"]
      assert flag in snapshot["missingFeatures"]
      assert snapshot["features"][flag] == false
    end
  end

  test "missing helpers, policy budget support, unsupported platforms and stream bounds fail closed" do
    for override <- [
          [python_supported: false],
          [native_execution_policy: false],
          [secret_receipts: false],
          [platform: {:win32, :nt}],
          [assets: %{"node_fs.py" => false, "node_pty.py" => false}]
        ] do
      refute Features.snapshot(capabilities(), Keyword.merge(@opts, override))["botReady"]
    end

    for bound <- [nil, 0, -1, 65_537, "65536"] do
      caps = Map.put(capabilities(), "node.invoke.event", %{"version" => 1, "maxBytes" => bound})
      assert Features.snapshot(caps, @opts)["features"]["liveStreaming"] == false
    end

    for marker <- [nil, true, %{"version" => 0}, %{"version" => 2}] do
      caps =
        Map.put(capabilities(), "coding_agent.run", %{
          "version" => 1,
          "nativePrivacyContext" => marker
        })

      assert Features.snapshot(caps, @opts)["features"]["nativeExecutionPolicy"] == false
      refute Features.snapshot(caps, @opts)["botReady"]
    end

    snapshot = Features.snapshot(%{"coding_agent.run" => %{"version" => 1}}, @opts)
    refute snapshot["botReady"]
    assert snapshot["missingFeatures"] == Enum.sort(snapshot["missingFeatures"])
  end
end
