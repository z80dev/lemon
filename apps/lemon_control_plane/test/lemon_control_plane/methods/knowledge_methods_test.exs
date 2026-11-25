defmodule LemonControlPlane.Methods.KnowledgeMethodsTest do
  @moduledoc """
  `skills.list`/`skills.enable`/`skills.disable`, `mcp.servers.list`/`refresh`
  and `nodes.list`/`nodes.revoke`: registration, scopes, allowlist projections
  and the owning-service effects.
  """

  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.{Authorize, TokenStore}
  alias LemonControlPlane.Methods.Registry
  alias LemonControlPlane.NodeStore

  @operator %{auth: Authorize.default_operator(), conn_id: "knowledge-test", conn_pid: nil}
  @reader %{
    auth: %{role: :operator, scopes: [:read], client_id: "reader"},
    conn_id: "knowledge-reader",
    conn_pid: nil
  }

  defmodule RefreshUnavailableSource do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:refresh, _from, state),
      do: {:reply, {:error, :task_capacity_reached}, state}
  end

  test "bounded MCP refresh worker failures return unavailable rather than crashing" do
    previous = Application.get_env(:lemon_control_plane, :mcp_source)
    start_supervised!(RefreshUnavailableSource)
    Application.put_env(:lemon_control_plane, :mcp_source, RefreshUnavailableSource)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:lemon_control_plane, :mcp_source),
        else: Application.put_env(:lemon_control_plane, :mcp_source, previous)
    end)

    assert {:error, {:unavailable, "MCP refresh is unavailable"}} =
             call("mcp.servers.refresh", %{})
  end

  defp call(method, params, ctx \\ @operator),
    do: Registry.dispatch(method, params, Map.put(ctx, :conn_pid, self()))

  defp await_loaded(_source, 0), do: flunk("MCP source never committed its configuration")

  defp await_loaded(source, attempts) do
    unless LemonSkills.McpSource.inventory(source, []).loaded do
      Process.sleep(10)
      await_loaded(source, attempts - 1)
    end
  end

  test "methods are registered with read/admin scopes" do
    methods = Registry.list_methods()

    for method <- ~w(skills.list skills.enable skills.disable mcp.servers.list
                     mcp.servers.refresh nodes.list nodes.revoke) do
      assert method in methods
    end

    assert Registry.dispatch_mode("mcp.servers.refresh") == :async

    for {method, params} <- [
          {"skills.enable", %{"skillKey" => "a"}},
          {"skills.disable", %{"skillKey" => "a"}},
          {"mcp.servers.refresh", %{}},
          {"nodes.revoke", %{"nodeId" => "n", "confirmName" => "n"}}
        ] do
      assert {:error, {:forbidden, _}} = call(method, params, @reader)
    end
  end

  describe "skills" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "knowledge-skills-#{System.unique_integer([:positive])}")

      agent_dir = Path.join(root, "agent")
      harness = Path.join(root, "harness")
      File.mkdir_p!(harness)
      previous = Map.new(~w(LEMON_AGENT_DIR LEMON_HARNESS_SKILLS_DIR), &{&1, System.get_env(&1)})
      System.put_env("LEMON_AGENT_DIR", agent_dir)
      System.put_env("LEMON_HARNESS_SKILLS_DIR", harness)

      write_skill(agent_dir, "alpha-skill", """
      ---
      name: Alpha Skill
      description: Helps with alpha tasks
      requires:
        bins: [definitely-missing-binary-xyz]
      metadata:
        lemon:
          category: testing
      ---
      Body text with a secret path #{root}
      """)

      write_skill(agent_dir, "beta-skill", """
      ---
      name: Beta
      description: Beta helper
      ---
      Beta body
      """)

      LemonSkills.Registry.refresh()

      on_exit(fn ->
        Enum.each(previous, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)

        LemonSkills.Registry.refresh()
        File.rm_rf!(root)
      end)

      %{root: root, agent_dir: agent_dir}
    end

    test "skills.list projects an allowlist without paths or bodies", %{root: root} do
      assert {:ok, %{"skills" => skills, "summary" => summary}} = call("skills.list", %{})
      alpha = Enum.find(skills, &(&1["key"] == "alpha-skill"))

      assert alpha["name"] == "Alpha Skill"
      assert alpha["description"] == "Helps with alpha tasks"
      assert alpha["scope"] == "global"
      assert alpha["enabled"] == true
      assert alpha["activation"] == "not_ready"
      assert alpha["category"] == "testing"
      assert alpha["missing"]["bins"] == ["definitely-missing-binary-xyz"]
      assert summary["count"] >= 2
      refute inspect(skills) =~ root
      refute Map.has_key?(alpha, "path")
      refute Map.has_key?(alpha, "sourceId")
    end

    test "skills.disable and skills.enable round-trip through skills config" do
      assert {:ok, %{"enabled" => false, "scope" => "global"}} =
               call("skills.disable", %{"skillKey" => "beta-skill"})

      assert LemonSkills.Config.skill_disabled?("beta-skill")
      {:ok, %{"skills" => skills}} = call("skills.list", %{})
      beta = Enum.find(skills, &(&1["key"] == "beta-skill"))
      assert beta["enabled"] == false
      assert beta["activation"] == "hidden"

      assert {:ok, %{"enabled" => true}} = call("skills.enable", %{"skillKey" => "beta-skill"})
      refute LemonSkills.Config.skill_disabled?("beta-skill")
    end

    test "skills.enable refuses to lift a curator archive" do
      assert {:ok, _} = call("skills.disable", %{"skillKey" => "beta-skill"})
      assert :ok = LemonSkills.Usage.set_state("beta-skill", :archived)

      assert {:error, {:conflict, "Skill is archived; restore it before enabling"}} =
               call("skills.enable", %{"skillKey" => "beta-skill"})

      assert LemonSkills.Config.skill_disabled?("beta-skill")
    end

    test "an unreadable skills.json is an error, not an empty disabled list", %{
      agent_dir: agent_dir
    } do
      File.write!(Path.join(agent_dir, "skills.json"), "{corrupt")

      assert {:error, {:unavailable, message}} = call("skills.list", %{})
      assert message =~ "lemon doctor"

      assert {:error, {:unavailable, _}} =
               call("skills.enable", %{"skillKey" => "beta-skill"})

      assert File.read!(Path.join(agent_dir, "skills.json")) == "{corrupt"
    end

    test "toggle validates the key and refuses unknown skills" do
      assert {:error, {:not_found, "Skill not found"}} =
               call("skills.enable", %{"skillKey" => "no-such-skill"})

      assert {:error, {:invalid_request, _}} =
               call("skills.disable", %{"skillKey" => "../escape"})

      assert {:error, {:invalid_request, _}} = call("skills.list", %{"cwd" => "relative"})
    end
  end

  describe "mcp" do
    setup do
      root = Path.join(System.tmp_dir!(), "knowledge-mcp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      script = Path.join(root, "server.exs")
      File.write!(script, fixture_script())
      disabled = Application.get_env(:lemon_skills, :mcp_disabled)
      Application.put_env(:lemon_skills, :mcp_disabled, false)
      name = :"knowledge_mcp_#{System.unique_integer([:positive])}"

      configs = [
        {:stdio, System.find_executable("elixir"), ["--erl", "+S 1:1", script, "--secret-arg"],
         name: "fixture", env: [{"FIXTURE_TOKEN", "sk-test-secret"}], approval: :always},
        {:stdio, Path.join(root, "missing-mcp-binary"), ["--private"], name: "broken"},
        {:http, "https://user:pass@mcp.example.test:8443/private/path?key=secret",
         name: "remote", headers: [{"Authorization", "Bearer secret"}], ready_timeout_ms: 200}
      ]

      start_supervised!(
        {LemonSkills.McpSource, name: name, configs: configs, refresh_interval_ms: 3_600_000}
      )

      # Configuration loads in the source's first worker job (#587); reads
      # serve the last committed snapshot, which is unloaded until it lands.
      await_loaded(name, 500)

      Application.put_env(:lemon_control_plane, :mcp_source, name)

      on_exit(fn ->
        Application.delete_env(:lemon_control_plane, :mcp_source)

        if is_nil(disabled),
          do: Application.delete_env(:lemon_skills, :mcp_disabled),
          else: Application.put_env(:lemon_skills, :mcp_disabled, disabled)

        File.rm_rf!(root)
      end)

      %{root: root}
    end

    test "list is a pure read and refresh connects, with redacted identity", %{root: root} do
      assert {:ok, %{"available" => true, "servers" => servers}} = call("mcp.servers.list", %{})
      assert Enum.map(servers, & &1["status"]) == ["pending", "pending", "pending"]

      assert {:ok, %{"servers" => servers, "summary" => summary}} =
               call("mcp.servers.refresh", %{})

      [fixture, broken, remote] = servers
      assert fixture["name"] == "fixture"
      assert fixture["label"] == "elixir"
      assert fixture["transport"] == "stdio"
      assert fixture["status"] == "connected"
      assert fixture["approval"] == "always"
      assert fixture["toolCount"] == 1

      assert [%{"remoteName" => "echo", "kind" => "tool", "description" => "Fixture echo"} = tool] =
               fixture["tools"]

      assert String.starts_with?(tool["name"], "mcp_fixture_echo_")

      assert broken["status"] == "failed"
      assert broken["errorClass"] == "connection_failed"
      assert broken["label"] == "missing-mcp-binary"

      assert remote["transport"] == "http"
      assert remote["label"] == "mcp.example.test:8443"
      assert remote["status"] == "failed"

      assert summary["connected"] == 1
      assert summary["failed"] == 2

      encoded = Jason.encode!(servers)

      for secret <- [
            "--secret-arg",
            "sk-test-secret",
            "user:pass",
            "/private/path",
            "key=secret",
            "Bearer",
            root
          ] do
        refute encoded =~ secret
      end
    end

    test "list projects loaded project trust without connecting or granting it", %{root: root} do
      project = Path.join(root, "project")
      marker = Path.join(root, "spawned")
      saved = Map.new(["LEMON_AGENT_DIR", "LEMON_MCP_SERVERS"], &{&1, System.get_env(&1)})

      on_exit(fn ->
        Enum.each(saved, fn
          {key, nil} -> System.delete_env(key)
          {key, value} -> System.put_env(key, value)
        end)
      end)

      System.put_env("LEMON_AGENT_DIR", Path.join(root, "agent"))
      System.put_env("LEMON_MCP_SERVERS", "[]")
      File.mkdir_p!(Path.join(project, ".lemon"))

      File.write!(
        Path.join(project, ".lemon/mcp.json"),
        Jason.encode!(%{
          "servers" => [
            %{
              "name" => "native",
              "type" => "stdio",
              "command" => System.find_executable("sh"),
              "args" => [
                "-c",
                "printf x > \"$0\"",
                marker,
                "--api-key=sk-abcdefghijklmnop",
                "--token",
                "OPAQUE_ARG_7Q2X9"
              ]
            },
            %{
              "name" => "remote",
              "type" => "http",
              "url" => "https://r.example/hooks/OPAQUE_PATH_7Q2X9/mcp"
            },
            %{
              "name" => "oauth",
              "type" => "http",
              "url" => "https://o.example/mcp",
              "oauth" => %{"client_id" => "c", "client_secret_secret" => "HOST_SECRET"}
            }
          ]
        })
      )

      name = :"knowledge_project_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {LemonSkills.McpSource, name: name, refresh_interval_ms: 3_600_000},
          id: name
        )
      )

      assert [] = LemonSkills.McpSource.discover_tools(name, cwd: project)
      Application.put_env(:lemon_control_plane, :mcp_source, name)

      assert {:ok, %{"projectTrust" => [entry]}} = call("mcp.servers.list", %{})
      assert entry["trust"] == "untrusted"
      assert entry["files"] == [".lemon/mcp.json"]

      assert [
               %{"name" => "native", "provider" => "lemon", "transport" => "stdio"} = native,
               %{"name" => "remote", "transport" => "http"}
             ] = entry["servers"]

      refute native["preview"] =~ "sk-abcdefghijklmnop"
      # Admin callers see the configured command and URL previews.
      assert native["preview"] =~ "OPAQUE_ARG_7Q2X9"

      # Read scope gets name, transport and trust metadata, never command
      # arguments or URL paths.
      assert {:ok, %{"projectTrust" => [read_entry]} = read} =
               call("mcp.servers.list", %{}, @reader)

      refute Jason.encode!(read) =~ "OPAQUE_ARG_7Q2X9"
      refute Jason.encode!(read) =~ "OPAQUE_PATH_7Q2X9"
      assert read_entry["trust"] == "untrusted"
      assert read["previewsWithheld"] == true

      assert [%{"name" => "native", "transport" => "stdio"} = read_native, %{"name" => "remote"}] =
               read_entry["servers"]

      refute Map.has_key?(read_native, "preview")

      assert [%{"server" => "oauth", "keys" => ["oauth.client_secret_secret"]}] =
               entry["rejected"]

      # Viewing never spawns, connects or grants trust.
      Process.sleep(200)
      refute File.exists?(marker)
      assert LemonSkills.McpConfig.project_trust(project) == nil
    end

    test "unavailable source is an explicit error, not an empty list" do
      Application.put_env(:lemon_control_plane, :mcp_source, :knowledge_missing_source)
      assert {:error, {:unavailable, "MCP source is unavailable"}} = call("mcp.servers.list", %{})
    end
  end

  describe "nodes" do
    setup do
      node_id = "knowledge-node-#{System.unique_integer([:positive])}"
      pairing_id = "knowledge-pair-#{System.unique_integer([:positive])}"
      expired_id = pairing_id <> "-expired"
      now = System.system_time(:millisecond)

      :ok =
        NodeStore.put_node(node_id, %{
          id: node_id,
          name: "Build Box",
          type: "coding_agent",
          capabilities: %{"coding_agent.run" => %{"version" => 1}, "node.invoke.cancel" => true},
          token_hash: "stored-token-hash-value",
          paired_at_ms: now - 10_000,
          last_seen_ms: now - 5_000,
          status: :offline
        })

      :ok =
        NodeStore.put_pairing(pairing_id, %{
          id: pairing_id,
          code: "123456",
          node_type: "browser",
          node_name: "Laptop",
          capabilities: %{},
          status: :pending,
          challenge_token: "pending-challenge-secret",
          created_at_ms: now,
          expires_at_ms: now + 60_000
        })

      :ok =
        NodeStore.put_pairing(expired_id, %{
          id: expired_id,
          code: "654321",
          node_name: "Old",
          status: :pending,
          created_at_ms: now - 600_000,
          expires_at_ms: now - 1
        })

      on_exit(fn ->
        LemonCore.Store.delete(:nodes_registry, node_id)
        LemonCore.Store.delete(:nodes_pairing, pairing_id)
        LemonCore.Store.delete(:nodes_pairing, expired_id)
      end)

      %{node_id: node_id, pairing_id: pairing_id}
    end

    test "nodes.list projects nodes and pending pairings without credentials", ctx do
      assert {:ok, %{"nodes" => nodes, "pairings" => pairings}} = call("nodes.list", %{})
      node = Enum.find(nodes, &(&1["id"] == ctx.node_id))

      assert node["name"] == "Build Box"
      assert node["status"] == "offline"
      assert node["capabilities"] == ["coding_agent.run", "node.invoke.cancel"]
      assert node["session"] == "none"

      pairing = Enum.find(pairings, &(&1["pairingId"] == ctx.pairing_id))
      assert pairing["code"] == "123456"
      assert pairing["nodeName"] == "Laptop"
      refute Enum.any?(pairings, &(&1["nodeName"] == "Old"))

      encoded = Jason.encode!(%{nodes: nodes, pairings: pairings})
      refute encoded =~ "stored-token-hash-value"
      refute encoded =~ "pending-challenge-secret"

      # The verification code is pairing authority, not read metadata.
      assert {:ok, %{"pairings" => read_pairings}} = call("nodes.list", %{}, @reader)
      read_pairing = Enum.find(read_pairings, &(&1["pairingId"] == ctx.pairing_id))
      assert read_pairing["nodeName"] == "Laptop"
      refute Map.has_key?(read_pairing, "code")
      refute Jason.encode!(read_pairings) =~ "123456"
    end

    test "nodes.revoke requires the exact durable name and invalidates sessions", ctx do
      token = "knowledge-session-#{System.unique_integer([:positive])}"

      {:ok, _} =
        TokenStore.replace_node_session(token, %{"type" => "node", "nodeId" => ctx.node_id})

      assert {:ok, _} = TokenStore.validate(token)
      assert TokenStore.node_session_state(ctx.node_id) == :active

      assert {:error, {:conflict, _}} =
               call("nodes.revoke", %{"nodeId" => ctx.node_id, "confirmName" => "build box"})

      assert {:ok, _} = TokenStore.validate(token)

      assert {:ok, %{"revoked" => true, "revokedSessions" => 1}} =
               call("nodes.revoke", %{"nodeId" => ctx.node_id, "confirmName" => "Build Box"})

      assert {:error, :invalid_token} = TokenStore.validate(token)

      {:ok, %{"nodes" => nodes}} = call("nodes.list", %{})
      assert Enum.find(nodes, &(&1["id"] == ctx.node_id))["session"] == "revoked"

      assert {:error, {:not_found, _}} =
               call("nodes.revoke", %{"nodeId" => "missing-node", "confirmName" => "x"})
    end
  end

  defp write_skill(agent_dir, key, content) do
    dir = Path.join([agent_dir, "skill", key])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), content)
    # Readiness requires an operator-side grant for these exact bytes.
    {:ok, hash} = LemonSkills.Bundle.compute_hash(dir)
    :ok = LemonSkills.Audit.State.authorize(:global, key, hash, :pass)
  end

  defp fixture_script do
    ~S'''
    defmodule KnowledgeFixture do
      def run do
        IO.stream(:stdio, :line)
        |> Enum.each(fn line -> handle(:json.decode(String.trim(line))) end)
      end

      defp handle(%{"method" => "initialize", "id" => id}) do
        respond(id, %{"protocolVersion" => "2024-11-05", "capabilities" => %{"tools" => %{}},
          "serverInfo" => %{"name" => "knowledge-fixture", "version" => "1.0"}})
      end

      defp handle(%{"method" => "tools/list", "id" => id}) do
        respond(id, %{"tools" => [%{"name" => "echo", "description" => "Fixture echo",
          "inputSchema" => %{"type" => "object"}}]})
      end

      defp handle(%{"id" => id}), do: respond(id, %{})
      defp handle(_), do: :ok
      defp respond(id, result), do: IO.write([:json.encode(%{"jsonrpc" => "2.0", "id" => id, "result" => result}), "\n"])
    end
    KnowledgeFixture.run()
    '''
  end
end
