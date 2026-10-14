defmodule LemonSkills.McpDiscoveryTest do
  use ExUnit.Case, async: false

  alias LemonSkills.{Config, McpConfig, McpDiscovery}

  @moduletag :tmp_dir

  @app_keys [:mcp_external_discovery, :mcp_external_user_discovery, :mcp_discovery_home]
  @env_keys [
    "LEMON_AGENT_DIR",
    "LEMON_MCP_SERVERS",
    "LEMON_MCP_EXTERNAL_DISCOVERY",
    "LEMON_MCP_EXTERNAL_USER_DISCOVERY",
    "CLAUDE_CONFIG_DIR",
    "MCP_DISC_VAR",
    "MCP_DISC_TOKEN",
    "MCP_DISC_EMPTY"
  ]

  setup %{tmp_dir: root} do
    saved_app = Map.new(@app_keys, &{&1, Application.fetch_env(:lemon_skills, &1)})
    saved_env = Map.new(@env_keys, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved_app, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_skills, key, value)
        {key, :error} -> Application.delete_env(:lemon_skills, key)
      end)

      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Enum.each(@env_keys, &System.delete_env/1)
    project = Path.join(root, "project")
    home = Path.join(root, "home")
    File.mkdir_p!(project)
    File.mkdir_p!(home)
    System.put_env("LEMON_AGENT_DIR", Path.join(root, "agent"))
    System.put_env("LEMON_MCP_SERVERS", "[]")
    Application.put_env(:lemon_skills, :mcp_external_discovery, true)
    Application.put_env(:lemon_skills, :mcp_discovery_home, home)
    Application.delete_env(:lemon_skills, :mcp_external_user_discovery)

    %{project: project, home: home}
  end

  test "translates every provider format in omp priority order", %{project: p, home: h} do
    System.put_env("MCP_DISC_VAR", "from-env")
    System.put_env("MCP_DISC_TOKEN", "tok")
    Application.put_env(:lemon_skills, :mcp_external_user_discovery, true)

    json(p, ".omp/mcp.json", %{
      "mcpServers" => %{
        "omp-p" => %{
          "command" => "omp-cmd",
          "args" => ["a"],
          "env" => %{"K" => "${MCP_DISC_VAR}"}
        }
      }
    })

    json(h, ".omp/agent/mcp.json", %{
      "mcpServers" => %{
        "omp-u" => %{
          "type" => "http",
          "url" => "https://omp.example/mcp",
          "headers" => %{"A" => "${MCP_DISC_MISSING:-dflt}", "B" => "${MCP_DISC_MISSING}"}
        }
      }
    })

    json(p, ".claude/.mcp.json", %{"mcpServers" => %{"claude-p" => %{"command" => "c"}}})
    json(p, ".claude/mcp.json", %{"mcpServers" => %{"claude-shadowed" => %{"command" => "c"}}})

    json(h, ".claude.json", %{
      "mcpServers" => %{"claude-u" => %{"type" => "sse", "url" => "https://c.example/sse"}},
      "projects" => %{p => %{"mcpServers" => %{"claude-local" => %{"command" => "local"}}}}
    })

    json(h, ".claude/mcp.json", %{"mcpServers" => %{"claude-shadowed-u" => %{"command" => "c"}}})

    write(p, ".codex/config.toml", """
    [mcp_servers.codex-p]
    command = "./bin/server"
    cwd = "srv"
    args = ["--x"]
    env_vars = ["MCP_DISC_VAR", "MCP_DISC_UNSET"]
    tool_timeout_sec = 2
    startup_timeout_sec = 1.5
    enabled_tools = ["read"]
    disabled_tools = ["write"]
    """)

    write(h, ".codex/config.toml", """
    [mcp_servers.codex-u]
    url = "https://x.example/mcp"
    bearer_token_env_var = "MCP_DISC_TOKEN"
    enabled = false
    """)

    json(p, ".gemini/settings.json", %{
      "mcpServers" => %{
        "gem-http" => %{"httpUrl" => "https://g.example/mcp", "includeTools" => ["a"]},
        "gem-sse" => %{"url" => "https://g.example/sse", "excludeTools" => ["b"]}
      }
    })

    json(h, ".gemini/settings.json", %{"mcpServers" => %{"gem-u" => %{"command" => "g"}}})

    json(h, ".config/opencode/opencode.json", %{
      "mcp" => %{
        "oc" => %{
          "type" => "local",
          "command" => ["node", "srv.js"],
          "environment" => %{"A" => "{env:MCP_DISC_VAR}"}
        }
      }
    })

    write(p, "token.txt", "secret-token\n")

    write(p, "opencode.jsonc", """
    // OpenCode project config
    {
      "mcp": {
        "oc": {"enabled": false, /* partial override */},
        "oc-remote": {
          "type": "remote",
          "url": "https://o.example/mcp",
          "headers": {"Authorization": "Bearer {file:token.txt}", "X": "a//b"},
        },
      },
    }
    """)

    json(p, ".cursor/mcp.json", %{"mcpServers" => %{"cur-p" => %{"command" => "cur"}}})

    json(h, ".cursor/mcp.json", %{
      "mcpServers" => %{"cur-u" => %{"type" => "http", "url" => "https://cu.example/mcp"}}
    })

    json(p, ".windsurf/mcp_config.json", %{
      "mcpServers" => %{"wind-p" => %{"serverUrl" => "https://w.example/mcp"}}
    })

    json(h, ".codeium/windsurf/mcp_config.json", %{
      "mcpServers" => %{"wind-u" => %{"command" => "w", "disabled" => true}}
    })

    json(p, ".vscode/mcp.json", %{
      "servers" => %{
        "vs" => %{"type" => "stdio", "command" => "vs", "args" => ["${workspaceFolder}/x"]}
      }
    })

    json(p, "mcp.json", %{"mcpServers" => %{"root-a" => %{"command" => "a"}}})
    json(p, ".mcp.json", %{"mcpServers" => %{"root-b" => %{"command" => "b"}}})

    servers = McpDiscovery.discover(p)

    assert Enum.map(servers, &{&1.name, &1.source.provider, &1.source.scope}) == [
             {"omp-p", "omp", :project},
             {"omp-u", "omp", :global},
             {"claude-local", "claude", :global},
             {"claude-p", "claude", :project},
             {"claude-u", "claude", :global},
             {"codex-p", "codex", :project},
             {"codex-u", "codex", :global},
             {"gem-http", "gemini", :project},
             {"gem-sse", "gemini", :project},
             {"gem-u", "gemini", :global},
             {"oc", "opencode", :project},
             {"oc-remote", "opencode", :project},
             {"cur-p", "cursor", :project},
             {"cur-u", "cursor", :global},
             {"wind-p", "windsurf", :project},
             {"wind-u", "windsurf", :global},
             {"vs", "vscode", :project},
             {"root-a", "mcp-json", :project},
             {"root-b", "mcp-json", :project}
           ]

    by_name = Map.new(servers, &{&1.name, &1})

    assert by_name["omp-p"].entry == %{
             "name" => "omp-p",
             "type" => "stdio",
             "command" => "omp-cmd",
             "args" => ["a"],
             "env" => %{"K" => "from-env"}
           }

    assert by_name["omp-u"].entry["headers"] == %{"A" => "dflt", "B" => "${MCP_DISC_MISSING}"}
    assert by_name["claude-u"].entry["type"] == "sse"

    codex_dir = Path.join(p, ".codex")

    assert by_name["codex-p"].entry == %{
             "name" => "codex-p",
             "type" => "stdio",
             "command" => Path.join([codex_dir, "srv", "bin", "server"]),
             "args" => ["--x"],
             "cwd" => Path.join(codex_dir, "srv"),
             "env" => %{"MCP_DISC_VAR" => "from-env"},
             "timeout_ms" => 2000,
             "ready_timeout_ms" => 1500,
             "allow_tools" => ["read"],
             "block_tools" => ["write"]
           }

    assert by_name["codex-u"].entry["headers"] == %{"Authorization" => "Bearer tok"}
    refute by_name["codex-u"].enabled

    assert by_name["gem-http"].entry["type"] == "http"
    assert by_name["gem-http"].entry["allow_tools"] == ["a"]
    assert by_name["gem-sse"].entry["type"] == "sse"
    assert by_name["gem-sse"].entry["block_tools"] == ["b"]

    assert by_name["oc"].entry["command"] == "node"
    assert by_name["oc"].entry["args"] == ["srv.js"]
    assert by_name["oc"].entry["env"] == %{"A" => "from-env"}
    refute by_name["oc"].enabled

    assert by_name["oc-remote"].entry["headers"] == %{
             "Authorization" => "Bearer secret-token",
             "X" => "a//b"
           }

    assert by_name["wind-p"].entry["type"] == "http"
    assert by_name["wind-p"].entry["url"] == "https://w.example/mcp"
    refute by_name["wind-u"].enabled
    assert by_name["vs"].entry["args"] == [p <> "/x"]

    for {_name, server} <- by_name, server.name != "codex-u" and server.name != "wind-u" do
      assert [_config] = Config.parse_mcp_server_config(server.entry)
    end
  end

  test "other tools' user files are opt-in; omp user files and CLAUDE_CONFIG_DIR are not", %{
    project: p,
    home: h,
    tmp_dir: root
  } do
    json(h, ".omp/agent/.mcp.json", %{"mcpServers" => %{"omp-u" => %{"command" => "o"}}})
    json(h, ".cursor/mcp.json", %{"mcpServers" => %{"cur-u" => %{"command" => "c"}}})
    json(h, ".claude.json", %{"mcpServers" => %{"claude-home" => %{"command" => "c"}}})
    json(h, ".claude/mcp.json", %{"mcpServers" => %{"claude-mcp" => %{"command" => "c"}}})
    json(h, ".gemini/settings.json", %{"mcpServers" => %{"gem-u" => %{"command" => "g"}}})
    write(h, ".codex/config.toml", "[mcp_servers.codex-u]\ncommand = \"c\"\n")

    json(h, ".config/opencode/opencode.json", %{
      "mcp" => %{"oc-u" => %{"type" => "local", "command" => ["node", "server.js"]}}
    })

    claude_dir = Path.join(root, "claude-config")
    json(claude_dir, ".claude.json", %{"mcpServers" => %{"claude-env" => %{"command" => "c"}}})

    assert names(McpDiscovery.discover(p)) == ["omp-u"]
    assert names(McpDiscovery.discover(nil)) == ["omp-u"]
    assert names(McpDiscovery.discover(h)) == ["omp-u"]
    assert names(McpDiscovery.discover(Path.join(h, ".config/opencode"))) == ["omp-u"]

    System.put_env("CLAUDE_CONFIG_DIR", claude_dir)
    assert names(McpDiscovery.discover(p)) == ["omp-u", "claude-env"]

    System.delete_env("CLAUDE_CONFIG_DIR")
    System.put_env("LEMON_MCP_EXTERNAL_USER_DISCOVERY", "yes")

    assert names(McpDiscovery.discover(p)) ==
             ["omp-u", "claude-home", "codex-u", "gem-u", "oc-u", "cur-u"]

    # Isolated runtimes without an explicit discovery home read no user files.
    Application.delete_env(:lemon_skills, :mcp_discovery_home)
    assert Config.mcp_discovery_home() == nil
    assert McpDiscovery.discover(p) == []
  end

  test "Lemon files win, first name claims even when disabled, invalid entries do not claim",
       %{project: p} do
    json(p, ".lemon/mcp.json", %{
      "servers" => [%{"name" => "shared", "type" => "stdio", "command" => "lemon"}]
    })

    json(p, ".claude/.mcp.json", %{
      "mcpServers" => %{
        "off" => %{"command" => "claude-off", "enabled" => false},
        "broken" => %{"command" => "x", "url" => "https://both.example"},
        "bad\nname" => %{"command" => "x"}
      }
    })

    json(p, ".cursor/mcp.json", %{
      "mcpServers" => %{
        "shared" => %{"command" => "cursor"},
        "off" => %{"command" => "cursor-on"},
        "broken" => %{"command" => "cursor-fixed"},
        "cursor-only" => %{"type" => "http", "url" => "https://cursor.example/mcp"}
      }
    })

    servers = Config.mcp_config(p).servers

    assert [
             {:stdio, "lemon", [], shared},
             {:stdio, "cursor-fixed", [], broken},
             {:http, "https://cursor.example/mcp", cursor_only}
           ] = servers

    assert shared[:name] == "shared"
    refute Keyword.has_key?(shared, :source)
    assert broken[:source] == %{provider: "cursor", scope: :project}
    assert cursor_only[:name] == "cursor-only"
    assert {:ok, _} = Config.validate_mcp_servers(servers)

    entries = Config.mcp_server_entries(p)
    off = Enum.find(entries, &(&1.name == "off"))
    assert {:stdio, "claude-off", [], _} = off.config
    assert %{enabled: false, source_enabled: false, override: nil} = off
  end

  test "enable/disable lists apply to every source with project over global", %{project: p} do
    json(p, ".claude/.mcp.json", %{
      "mcpServers" => %{
        "off" => %{"command" => "off", "enabled" => false},
        "on" => %{"command" => "on"}
      }
    })

    assert :ok = McpConfig.add(lemon_entry("mine"), cwd: p)
    assert enabled_names(p) == ["mine", "on"]

    assert :ok = McpConfig.set_enabled("off", true, cwd: p)
    assert enabled_names(p) == ["mine", "off", "on"]

    assert :ok = McpConfig.set_enabled("on", false, global: true)
    assert :ok = McpConfig.set_enabled("mine", false, global: true)
    assert enabled_names(p) == ["off"]

    assert :ok = McpConfig.set_enabled("on", true, cwd: p)
    assert enabled_names(p) == ["off", "on"]

    assert :ok = McpConfig.set_enabled("off", false, cwd: p)
    assert enabled_names(p) == ["on"]

    document = p |> Config.project_mcp_config_file() |> File.read!() |> Jason.decode!()
    assert document["disabled_servers"] == ["off"]
    assert document["enabled_servers"] == ["on"]
    assert [%{"name" => "mine"}] = document["servers"]

    global = Config.global_mcp_config_file() |> File.read!() |> Jason.decode!()
    assert global["disabled_servers"] == ["mine", "on"]
    refute Map.has_key?(global, "enabled_servers")

    # Within one file the denylist wins over the allowlist.
    File.write!(
      Config.project_mcp_config_file(p),
      Jason.encode!(Map.put(document, "enabled_servers", ["off", "on"]))
    )

    assert enabled_names(p) == ["on"]

    entry = Enum.find(Config.mcp_server_entries(p), &(&1.name == "off"))
    assert %{override: :disabled, enabled: false, source_enabled: false} = entry

    File.write!(
      Config.project_mcp_config_file(p),
      Jason.encode!(Map.put(document, "disabled_servers", ["off", "off"]))
    )

    assert :ok = McpConfig.set_enabled("off", true, cwd: p)
    assert enabled_names(p) == ["off", "on"]

    assert {:error, :invalid_entry} = McpConfig.set_enabled("bad\nname", true, cwd: p)
    File.write!(Config.project_mcp_config_file(p), ~s({"disabled_servers": "off"}))
    assert {:error, :invalid_config} = McpConfig.set_enabled("off", true, cwd: p)
  end

  test "effective list is redacted and reports source and state", %{project: p} do
    secret = "never-print-this"

    json(p, ".cursor/mcp.json", %{
      "mcpServers" => %{
        "remote" => %{
          "type" => "http",
          "url" => "https://#{secret}.example/mcp",
          "headers" => %{"Authorization" => secret}
        },
        "local" => %{"command" => secret, "args" => [secret], "env" => %{"K" => secret}}
      }
    })

    assert :ok = McpConfig.set_enabled("remote", false, cwd: p)
    assert {:ok, rows} = McpConfig.list(cwd: p, all: true)
    refute Jason.encode!(rows) =~ secret

    assert [
             %{
               "name" => "local",
               "type" => "stdio",
               "provider" => "cursor",
               "scope" => "project",
               "enabled" => true,
               "environment_count" => 1
             },
             %{
               "name" => "remote",
               "type" => "http",
               "enabled" => false,
               "override" => "disabled",
               "header_count" => 1
             }
           ] = rows
  end

  test "kill switch stops all external discovery", %{project: p, home: h} do
    json(p, ".mcp.json", %{"mcpServers" => %{"root" => %{"command" => "r"}}})
    json(h, ".omp/agent/mcp.json", %{"mcpServers" => %{"omp-u" => %{"command" => "o"}}})
    assert length(Config.mcp_config(p).servers) == 2

    System.put_env("LEMON_MCP_EXTERNAL_DISCOVERY", "0")
    refute McpDiscovery.enabled?()
    assert Config.mcp_config(p).servers == []

    System.delete_env("LEMON_MCP_EXTERNAL_DISCOVERY")
    Application.put_env(:lemon_skills, :mcp_external_discovery, false)
    assert Config.mcp_config(p).servers == []
  end

  defp names(servers), do: Enum.map(servers, & &1.name)

  defp enabled_names(cwd) do
    cwd |> Config.mcp_config() |> Map.fetch!(:servers) |> Enum.map(&name/1) |> Enum.sort()
  end

  defp name({:stdio, _, _, opts}), do: opts[:name]
  defp name({_, _, opts}), do: opts[:name]

  defp lemon_entry(name),
    do: %{
      "name" => name,
      "type" => "stdio",
      "command" => "server",
      "args" => [],
      "approval" => "always"
    }

  defp json(dir, relative, document), do: write(dir, relative, Jason.encode!(document))

  defp write(dir, relative, content) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
