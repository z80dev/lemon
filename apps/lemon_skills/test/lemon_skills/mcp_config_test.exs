defmodule LemonSkills.McpConfigTest do
  use ExUnit.Case, async: false

  alias LemonSkills.{Config, McpConfig, McpDiscovery}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = System.get_env("LEMON_AGENT_DIR")
    previous_servers = System.get_env("LEMON_MCP_SERVERS")
    System.put_env("LEMON_AGENT_DIR", Path.join(root, "global"))
    System.put_env("LEMON_MCP_SERVERS", "[]")

    on_exit(fn ->
      restore_env("LEMON_AGENT_DIR", previous)
      restore_env("LEMON_MCP_SERVERS", previous_servers)
    end)

    %{opts: [cwd: root]}
  end

  test "add refuses duplicates, replace preserves unknown fields and credentials", %{opts: opts} do
    original =
      Map.merge(entry("one"), %{"env" => %{"TOKEN" => "private"}, "extension" => %{"x" => 1}})

    path = McpConfig.path(opts)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{"enabled" => false, "future" => [1], "servers" => [original]})
    )

    # A pre-existing project file is repository content: the operator trusts it
    # before their own edits keep that trust bound to what they write.
    cwd = opts[:cwd]
    assert {:error, :untrusted_project} = McpConfig.fetch("one", opts)
    assert :ok = McpConfig.trust_project(cwd, McpDiscovery.project_status(cwd).digest)
    bytes = File.read!(path)

    assert {:error, :duplicate_name} = McpConfig.add(entry("one"), opts)
    assert File.read!(path) == bytes
    updated = Map.put(entry("one"), "env", %{"OTHER" => "value"})
    assert :ok = McpConfig.add(updated, Keyword.put(opts, :replace, true))
    assert {:ok, saved, %{digest: _}} = McpConfig.fetch("one", opts)
    assert saved["extension"] == %{"x" => 1}
    assert saved["env"] == %{"TOKEN" => "private", "OTHER" => "value"}
    document = path |> File.read!() |> Jason.decode!()
    assert document["enabled"] == false
    assert document["future"] == [1]
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
  end

  test "remove is exact and does not disturb unnamed or unrelated entries", %{opts: opts} do
    assert :ok = McpConfig.add(entry("one"), opts)
    assert :ok = McpConfig.add(entry("one-more"), opts)
    assert {:error, :not_found} = McpConfig.remove("on", opts)
    assert :ok = McpConfig.remove("one", opts)
    assert {:ok, [%{"name" => "one-more"}]} = McpConfig.list(opts)
  end

  test "invalid input files are never replaced and cooperating writers fail busy", %{opts: opts} do
    path = McpConfig.path(opts)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not json: private")
    assert {:error, :invalid_config} = McpConfig.add(entry("one"), opts)
    assert File.read!(path) == "not json: private"
    File.mkdir!(path <> ".lock")
    assert {:error, :busy} = McpConfig.add(entry("one"), opts)
    assert File.read!(path) == "not json: private"
  end

  test "list redacts commands, arguments, URLs, credentials and unknown extensions", %{opts: opts} do
    secret = "never-print-this"

    config =
      Map.merge(entry("one"), %{
        "command" => secret,
        "args" => [secret],
        "env" => %{"KEY" => secret},
        "extension" => secret
      })

    assert :ok = McpConfig.add(config, opts)
    assert {:ok, summaries} = McpConfig.list(opts)
    refute Jason.encode!(summaries) =~ secret
    assert hd(summaries)["environment_count"] == 1
  end

  test "named project overrides global and updates are visible on the next read", %{
    tmp_dir: root,
    opts: opts
  } do
    assert :ok = McpConfig.add(entry("same"), global: true)
    assert :ok = McpConfig.add(Map.put(entry("same"), "command", "project"), opts)
    assert [{:stdio, "project", [], metadata}] = Config.mcp_config(root).servers
    assert metadata[:name] == "same"
    assert metadata[:approval] == :always
    assert :ok = McpConfig.remove("same", opts)
    assert [{:stdio, "server", [], _}] = Config.mcp_config(root).servers
  end

  test "parser preserves policy metadata and invalid policies for fail-closed validation" do
    for type <- ["stdio", "http", "sse"] do
      json = %{
        "type" => type,
        "name" => "named",
        "command" => "server",
        "url" => "https://example.test/mcp",
        "approval" => "never",
        "tool_approvals" => %{"exact.tool" => "always", "bad" => "invalid"}
      }

      [config] = Config.parse_mcp_server_config(json)
      opts = elem(config, tuple_size(config) - 1)
      assert opts[:name] == "named"
      assert opts[:approval] == :never
      assert opts[:tool_approvals] == %{"exact.tool" => :always, "bad" => "invalid"}
      assert {:error, _} = Config.validate_mcp_servers([config])
    end
  end

  test "metadata validation rejects invalid present values instead of silently dropping policy" do
    for opts <- [
          [name: ""],
          [name: "bad\nname"],
          [approval: nil],
          [approval: "allow"],
          [tool_approvals: nil],
          [tool_approvals: %{"tool" => "allow"}],
          [tool_approvals: %{"bad\nname" => :always}]
        ] do
      assert {:error, _} = Config.validate_mcp_metadata(opts)
    end

    assert :ok = Config.validate_mcp_metadata([])

    assert :ok =
             Config.validate_mcp_metadata(
               name: "named",
               approval: :never,
               tool_approvals: %{"exact.tool" => :always}
             )
  end

  defp entry(name),
    do: %{
      "name" => name,
      "type" => "stdio",
      "command" => "server",
      "args" => [],
      "approval" => "always"
    }

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
