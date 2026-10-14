defmodule LemonControlPlane.Methods.McpExecutionNamesTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{McpExecutionNames, Registry}
  alias LemonControlPlane.Protocol.Schemas
  alias LemonSkills.McpSource

  setup do
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    :ok
  end

  test "pure projection is registered synchronously with operator read access" do
    assert Registry.lookup("mcp.execution_names") == {:ok, McpExecutionNames}
    assert Registry.dispatch_mode("mcp.execution_names") == :sync
    assert Schemas.get("mcp.execution_names").required == %{"server" => :map, "toolNames" => :list}
    for auth <- [%{role: :node, scopes: [:read]}, %{role: :operator, scopes: [:write]}, %{role: :unsupported, scopes: [:read]}] do
      assert {:error, {:forbidden, _}} = McpExecutionNames.handle(params(), %{auth: auth})
    end
    assert {:error, {:forbidden, _}} = McpExecutionNames.handle(params(), %{})
  end

  test "names match the owning native alias without a profile, node, DNS or credentials" do
    server = %{"name" => "lemon-bot", "url" => "https://no-dns-required.invalid/mcp"}
    names = ["send_message", "list_threads", "ask_user"]
    assert {:ok, result} = Registry.dispatch("mcp.execution_names", %{"server" => server, "toolNames" => names}, ctx())
    assert result == %{"server" => %{"name" => "lemon-bot"}, "tools" => Enum.map(names, fn name ->
      %{"name" => name, "executionName" => McpSource.execution_name(server["name"], server["url"], name)}
    end), "count" => 3}
    refute Map.has_key?(result["server"], "url")
    refute Map.has_key?(result["server"], "headers")
  end

  test "a listening endpoint receives no HTTP initialization during name projection" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    request = %{params() | "server" => %{"name" => "local-public-identity", "url" => "http://127.0.0.1:#{port}/mcp"}}
    assert {:ok, %{"count" => 1}} = McpExecutionNames.handle(request, ctx())
    assert {:error, :timeout} = :gen_tcp.accept(listener, 50)
  end

  test "credential configuration, extra fields and malformed names reject without projections" do
    for invalid <- [
      Map.put(params(), "nodeId", "unneeded-node"),
      Map.put(params(), "profileId", "unneeded-profile"),
      Map.put(params(), "server", %{"name" => "lemon-bot", "url" => "https://bot.example/mcp", "headers" => %{"Authorization" => "private-bearer"}}),
      Map.put(params(), "server", %{"name" => "lemon-bot", "url" => "file:///private-bearer"}),
      Map.put(params(), "toolNames", ["valid", "invalid name"]),
      Map.put(params(), "toolNames", [123]),
      Map.put(params(), "toolNames", List.duplicate("duplicate", 257))
    ] do
      assert {:error, {:invalid_request, _} = error} = McpExecutionNames.handle(invalid, ctx())
      refute inspect(error) =~ "private-bearer"
    end
  end

  defp params, do: %{"server" => %{"name" => "lemon-bot", "url" => "https://bot.example/mcp"}, "toolNames" => ["send_message"]}
  defp ctx, do: %{auth: %{role: :operator, scopes: [:read]}}
end
