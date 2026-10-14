defmodule LemonControlPlane.Methods.McpExecutionNamesTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.McpExecutionNames


  test "projection requires an authenticated operator with read authority" do
    for auth <- [%{role: :node, scopes: [:read]}, %{role: :operator, scopes: [:write]}, %{role: :unsupported, scopes: [:read]}] do
      assert {:error, {:forbidden, _}} = McpExecutionNames.handle(params(), %{auth: auth})
    end
    assert {:error, {:forbidden, _}} = McpExecutionNames.handle(params(), %{})
  end

  test "unusual raw names retain exact identities without sanitized-name collisions" do
    names = ["tool.name", "tool-name", "tool_name", "tool/name", "literal*", "über"]
    request = %{params() | "toolNames" => names}
    assert {:ok, result} = McpExecutionNames.handle(request, ctx())
    assert Enum.map(result["tools"], & &1["name"]) == names
    aliases = Enum.map(result["tools"], & &1["executionName"])
    assert MapSet.size(MapSet.new(aliases)) == length(names)
    for tool <- result["tools"] do
      assert byte_size(tool["executionName"]) <= 64
    end
  end

  test "canonical host and default port share identities but public endpoint changes do not collide" do
    names = ["tool-name", "tool_name"]
    project = fn name, url ->
      assert {:ok, result} = McpExecutionNames.handle(
        %{"server" => %{"name" => name, "url" => url}, "toolNames" => names}, ctx())
      Enum.map(result["tools"], & &1["executionName"])
    end
    canonical = project.("public-adapter", "https://example.test/mcp?tenant=one")
    assert canonical == project.("public-adapter", "https://EXAMPLE.TEST:443/mcp?tenant=one")
    for {name, url} <- [
          {"public-adapter", "https://example.test/mcp?tenant=two"},
          {"public-adapter", "https://example.test/other?tenant=one"},
          {"other-adapter", "https://example.test/mcp?tenant=one"}
        ] do
      changed = project.(name, url)
      assert MapSet.disjoint?(MapSet.new(canonical), MapSet.new(changed))
    end
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
