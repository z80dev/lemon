defmodule CodingAgent.ExecutionNode.TokenStoreTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ExecutionNode.TokenStore

  @tag :tmp_dir
  test "stores node-ID-keyed credentials with private permissions", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "tokens")

    assert :ok =
             TokenStore.save(
               "newphy/../../unsafe",
               %{
                 "token" => "session-secret",
                 "nodeId" => "node-1",
                 "controller" => "wss://controller.example/ws",
                 "recoveryToken" => "recovery-secret"
               },
               root: root
             )

    assert {:ok, path} = TokenStore.node_path("node-1", root: root)
    assert Path.dirname(path) == root
    refute path =~ "newphy"

    assert {:ok, record} =
             TokenStore.load("newphy/../../unsafe",
               root: root,
               controller: "wss://controller.example/ws"
             )

    assert record["token"] == "session-secret"
    assert record["nodeId"] == "node-1"
    assert record["nodeName"] == "newphy/../../unsafe"
    assert record["localName"] == "newphy/../../unsafe"
    assert record["recoveryToken"] == "recovery-secret"

    assert {:ok, %{mode: file_mode}} = File.stat(path)
    assert Bitwise.band(file_mode, 0o777) == 0o600
    assert {:ok, %{mode: directory_mode}} = File.stat(root)
    assert Bitwise.band(directory_mode, 0o777) == 0o700
  end

  @tag :tmp_dir
  test "migrates a legacy name-keyed record to its durable node ID", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "tokens")
    File.mkdir_p!(root)
    assert {:ok, legacy_path} = TokenStore.path("newphy", root: root)

    File.write!(
      legacy_path,
      Jason.encode!(%{
        "nodeName" => "newphy",
        "nodeId" => "node-legacy",
        "token" => "legacy-session",
        "controller" => "wss://controller.example/ws"
      })
    )

    assert {:ok, record} =
             TokenStore.load("newphy", root: root, controller: "wss://controller.example/ws")

    assert record["nodeId"] == "node-legacy"
    assert {:ok, stable_path} = TokenStore.node_path("node-legacy", root: root)
    assert File.exists?(stable_path)
    refute File.exists?(legacy_path)
  end

  @tag :tmp_dir
  test "loads a stable credential by node ID after the launch name changes", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "tokens")

    assert :ok =
             TokenStore.save(
               "Before Rename",
               %{
                 "nodeId" => "renamed-node",
                 "token" => "session-token",
                 "controller" => "wss://controller.example/ws"
               },
               root: root
             )

    assert {:ok, record} = TokenStore.load_node("renamed-node", root: root)
    assert record["localName"] == "Before Rename"
    assert record["token"] == "session-token"
  end

  @tag :tmp_dir
  test "rejects missing tokens and mismatched node records", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "tokens")
    assert {:error, :missing_token} = TokenStore.save("ophy", %{}, root: root)
    assert {:error, :not_found} = TokenStore.load("ophy", root: root)

    assert :ok = TokenStore.save("ophy", %{"token" => "token"}, root: root)
    assert {:ok, path} = TokenStore.path("ophy", root: root)
    File.write!(path, Jason.encode!(%{"nodeName" => "other", "token" => "token"}))

    assert {:error, :node_name_mismatch} = TokenStore.load("ophy", root: root)
  end
end
