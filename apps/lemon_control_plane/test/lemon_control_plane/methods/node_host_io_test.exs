defmodule LemonControlPlane.Methods.NodeHostIOTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods

  test "every destination handler declares asynchronous operator authorization" do
    assert Methods.NodeHostInfo.scopes() == [:read]
    for handler <- [Methods.NodeHostInfo, Methods.NodeFsList, Methods.NodeFsStat,
                    Methods.NodeFsRead, Methods.NodeFsWrite, Methods.NodeFsMkdir,
                    Methods.NodeFsMove, Methods.NodeFsDelete, Methods.NodeSecretsSet,
                    Methods.NodeSecretsList, Methods.NodeSecretsDelete] do
      assert handler.dispatch_mode() == :async
      unless handler == Methods.NodeHostInfo, do: assert(handler.scopes() == [:admin])
    end
  end

  test "delete confirmation binds the exact caller path before invoking a worker" do
    params = %{"nodeId" => "node-test", "path" => "files/result.txt"}
    assert {:error, {:invalid_request, _}} = Methods.NodeFsDelete.handle(params, %{})
    assert {:error, {:invalid_request, _}} =
             Methods.NodeFsDelete.handle(Map.put(params, "confirm", "/home/user/files/result.txt"), %{})
  end

  test "move requires the architecture path/destination shape" do
    assert {:error, {:invalid_request, _}} = Methods.NodeFsMove.handle(
      %{"nodeId" => "node-test", "source" => "from.txt", "destination" => "to.txt"}, %{})
    assert {:error, {:invalid_request, _}} = Methods.NodeFsMove.handle(
      %{"nodeId" => "node-test", "path" => "from.txt", "target" => "to.txt"}, %{})
  end

  test "file transfer bounds are admitted before invocation" do
    assert {:error, {:invalid_request, _}} = Methods.NodeFsRead.handle(
      %{"nodeId" => "node-test", "path" => "file", "length" => 1_048_577}, %{})
    assert {:error, {:invalid_request, _}} = Methods.NodeFsWrite.handle(
      %{"nodeId" => "node-test", "path" => "file", "dataBase64" => "", "offset" => -1}, %{})
    assert {:error, {:invalid_request, _}} = Methods.NodeFsWrite.handle(
      %{"nodeId" => "node-test", "path" => "file", "dataBase64" => "", "truncate" => "true"}, %{})
  end

  test "secret request errors contain no submitted values" do
    value = "credential-must-never-appear"
    assert {:error, reason} = Methods.NodeSecretsSet.handle(
      %{"nodeId" => "node-test", "name" => "", "value" => value}, %{})
    refute inspect(reason) =~ value
    assert {:error, _} = Methods.NodeSecretsList.handle([], %{})
  end
end
