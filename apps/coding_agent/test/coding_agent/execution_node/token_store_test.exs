defmodule CodingAgent.ExecutionNode.TokenStoreTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ExecutionNode.TokenStore

  @tag :tmp_dir
  test "stores node-name keyed credentials with private permissions", %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "tokens")

    assert :ok =
             TokenStore.save(
               "newphy/../../unsafe",
               %{
                 "token" => "session-secret",
                 "nodeId" => "node-1",
                 "controller" => "ws://controller:4040/ws"
               },
               root: root
             )

    assert {:ok, path} = TokenStore.path("newphy/../../unsafe", root: root)
    assert Path.dirname(path) == root
    refute path =~ "newphy"

    assert {:ok, record} = TokenStore.load("newphy/../../unsafe", root: root)
    assert record["token"] == "session-secret"
    assert record["nodeId"] == "node-1"
    assert record["nodeName"] == "newphy/../../unsafe"

    assert {:ok, %{mode: file_mode}} = File.stat(path)
    assert Bitwise.band(file_mode, 0o777) == 0o600
    assert {:ok, %{mode: directory_mode}} = File.stat(root)
    assert Bitwise.band(directory_mode, 0o777) == 0o700
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
