defmodule LemonControlPlane.Methods.NodeHostIOTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods

  test "every destination handler declares asynchronous operator authorization" do
    assert Methods.NodeHostInfo.scopes() == [:read]
    for handler <- [Methods.NodeHostInfo, Methods.NodeFsList, Methods.NodeFsStat,
                    Methods.NodeFsRead, Methods.NodeFsWrite, Methods.NodeFsMkdir,
                    Methods.NodeFsMove, Methods.NodeFsDeletePreview, Methods.NodeFsDelete, Methods.NodeSecretsSet,
                    Methods.NodeSecretsList, Methods.NodeSecretsDelete, Methods.NodeSecretsReceipt] do
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

  test "revision overwrite preview and token fields are validated before invocation" do
    base = %{"nodeId" => "node-test", "path" => "file"}
    for revision <- [-1, 1.5, "123", nil] do
      assert {:error, {:invalid_request, _}} = Methods.NodeFsWrite.handle(
        Map.merge(base, %{"dataBase64" => "", "expectedModifiedAtMs" => revision}), %{})
    end
    assert {:error, {:invalid_request, _}} = Methods.NodeFsMove.handle(
      Map.put(base, "destination", "other"), %{})
    assert {:error, {:invalid_request, _}} = Methods.NodeFsMove.handle(
      Map.merge(base, %{"destination" => "other", "expectedModifiedAtMs" => 123, "overwrite" => "false"}), %{})
    assert {:error, {:invalid_request, _}} = Methods.NodeFsDeletePreview.handle(
      Map.put(base, "recursive", "true"), %{})
    for token <- [nil, "", 123, String.duplicate("x", 257)] do
      assert {:error, {:invalid_request, _}} = Methods.NodeFsDelete.handle(
        Map.merge(base, %{"confirm" => "file", "confirmationToken" => token}), %{})
    end
  end

  test "secret request errors contain no submitted values" do
    value = "credential-must-never-appear"
    assert {:error, reason} = Methods.NodeSecretsSet.handle(
      %{"nodeId" => "node-test", "name" => "", "value" => value}, %{})
    refute inspect(reason) =~ value
    assert {:error, _} = Methods.NodeSecretsList.handle([], %{})
  end

  test "fixed secret IDs are bounded ASCII and receipt queries require them" do
    base = %{"nodeId" => "node-test", "name" => "private-name", "value" => "private-value"}
    for id <- [nil, "", "invalid/id", "a b", "é", String.duplicate("a", 129)] do
      assert {:error, {:invalid_request, _} = reason} =
               Methods.NodeSecretsSet.handle(Map.put(base, "operationId", id), %{})
      refute inspect(reason) =~ base["name"]
      refute inspect(reason) =~ base["value"]
      assert {:error, {:invalid_request, _}} =
               Methods.NodeSecretsReceipt.handle(%{"nodeId" => "node-test", "operationId" => id}, %{})
    end
    assert {:error, {:invalid_request, _}} = Methods.NodeSecretsReceipt.handle(%{"nodeId" => "node-test"}, %{})
    assert Methods.NodeSecretsReceipt.name() == "node.secrets.receipt"
  end
end
