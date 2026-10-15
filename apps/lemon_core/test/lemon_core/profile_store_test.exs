defmodule LemonCore.ProfileStoreTest do
  use ExUnit.Case, async: true

  alias LemonCore.ProfileStore

  @tag :tmp_dir
  test "all managed profile strings safely persist accepted newlines and controls", %{
    tmp_dir: root
  } do
    opts = opts(root)
    config = Keyword.fetch!(opts, :config_path)
    original = "# keep this comment\n[custom]\nunchanged = true\n"
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, original)

    attrs = %{
      "name" => "Name\n\"\\😀",
      "description" => "Description\r\n\t\b\f" <> <<1>> <> "界",
      "avatar" => "Avatar\n\"\\image",
      "model" => "Provider\n\"\\model",
      "systemPrompt" => " \r\nExact persona\n "
    }

    assert {:ok, created} = ProfileStore.create(Map.put(attrs, "id", "escaped-fields"), opts)
    assert Map.take(created, Map.keys(attrs)) == attrs
    assert {:ok, fetched} = ProfileStore.get("escaped-fields", opts)
    assert Map.take(fetched, Map.keys(attrs)) == attrs
    replacement = Map.new(attrs, fn {key, text} -> {key, "Updated\n" <> text <> "\nend"} end)
    assert {:ok, updated} = ProfileStore.update("escaped-fields", replacement, opts)
    assert Map.take(updated, Map.keys(attrs)) == replacement
    assert {:ok, reloaded} = ProfileStore.get("escaped-fields", opts)
    assert Map.take(reloaded, Map.keys(attrs)) == replacement
    renamed = "Renamed\n\"\\😀"
    assert {:ok, result} = ProfileStore.rename("escaped-fields", renamed, opts)
    assert result["name"] == renamed
    expected = Map.put(replacement, "name", renamed)

    assert {:ok, cloned} =
             ProfileStore.clone("escaped-fields", %{id: "escaped-fields-clone"}, opts)

    assert Map.take(cloned, Map.keys(attrs)) == expected
    assert File.read!(config) =~ original
  end

  @tag :tmp_dir
  test "execution reads distinguish absent profiles from corrupt and unreadable managed stores",
       %{tmp_dir: root} do
    opts = opts(root)
    config = Keyword.fetch!(opts, :config_path)
    assert {:error, :not_found} = ProfileStore.get_for_execution("guarded", opts)

    assert {:ok, _} =
             ProfileStore.create(
               %{id: "guarded", toolPolicy: %{"allow" => ["read"], "deny" => ["bash"]}},
               opts
             )

    assert {:ok, %{"toolPolicy" => %{"allow" => ["read"], "deny" => ["bash"]}}} =
             ProfileStore.get_for_execution("guarded", opts)

    for content <- ["[profiles.guarded\n", "profiles = true\n"] do
      File.write!(config, content)
      assert {:error, :invalid_profile_config} = ProfileStore.get("guarded", opts)
      assert {:error, :invalid_profile_config} = ProfileStore.get_for_execution("guarded", opts)
      assert {:error, :invalid_profile_config} = ProfileStore.get_for_execution("absent", opts)
    end

    File.write!(config, "[profiles]\nguarded = true\n")
    assert {:error, :invalid_profile} = ProfileStore.get("guarded", opts)
    assert {:error, :invalid_profile} = ProfileStore.get_for_execution("guarded", opts)
    assert {:error, :not_found} = ProfileStore.get_for_execution("absent", opts)
    assert ProfileStore.list(opts) == []
    File.rm!(config)
    File.mkdir!(config)
    assert {:error, :profile_store_unavailable} = ProfileStore.get("guarded", opts)
    assert {:error, :profile_store_unavailable} = ProfileStore.get_for_execution("guarded", opts)
    assert {:error, :profile_store_unavailable} = ProfileStore.get_for_execution("absent", opts)
  end

  @tag :tmp_dir
  test "prompt persistence escapes TOML controls without altering exact stored bytes", %{
    tmp_dir: root
  } do
    opts = opts(root)
    prompt = " \r\n\t\b\f\\\"😀界e\u0301" <> <<1>> <> "\r\n "

    assert {:ok, created} =
             ProfileStore.create(%{id: "escaped-prompt", systemPrompt: prompt}, opts)

    assert created["systemPrompt"] == prompt
    assert {:ok, fetched} = ProfileStore.get("escaped-prompt", opts)
    assert fetched["systemPrompt"] == prompt
    assert {:ok, updated} = ProfileStore.update("escaped-prompt", %{name: "Renamed"}, opts)
    assert updated["systemPrompt"] == prompt
    assert {:ok, cloned} = ProfileStore.clone("escaped-prompt", %{id: "escaped-clone"}, opts)
    assert cloned["systemPrompt"] == prompt
  end

  @tag :tmp_dir
  test "unsafe names cannot enter automatic ID normalization", %{tmp_dir: root} do
    for name <- [<<0xFF>>, <<0xED, 0xA0, 0x80>>, "bad\0name"] do
      assert {:error, :invalid_id} = ProfileStore.create(%{name: name}, opts(root))
    end

    assert ProfileStore.list(opts(root)) == []
  end

  @tag :tmp_dir
  test "all name mutations preserve 120 Unicode scalars without counting graphemes", %{
    tmp_dir: root
  } do
    opts = opts(root)

    names = [
      String.duplicate("a", 120),
      String.duplicate("界", 120),
      String.duplicate("😀", 120),
      String.duplicate("é", 120),
      String.duplicate("e\u0301", 60)
    ]

    for {name, index} <- Enum.with_index(names) do
      id = "unicode-#{index}"
      assert {:ok, created} = ProfileStore.create(%{id: id, name: name}, opts)
      assert created["name"] == name
      assert {:ok, fetched} = ProfileStore.get(id, opts)
      assert fetched["name"] == name
      assert {:ok, updated} = ProfileStore.update(id, %{name: name}, opts)
      assert updated["name"] == name
      assert {:ok, renamed} = ProfileStore.rename(id, name, opts)
      assert renamed["name"] == name
      assert {:ok, cloned} = ProfileStore.clone(id, %{id: "#{id}-clone", name: name}, opts)
      assert cloned["name"] == name
    end
  end

  @tag :tmp_dir
  test "all name mutations enforce scalar and defensive byte bounds and reject unsafe text", %{
    tmp_dir: root
  } do
    opts = opts(root)
    assert {:ok, _} = ProfileStore.create(%{id: "source", name: "Source"}, opts)

    scalar_overflows = [
      String.duplicate("a", 121),
      String.duplicate("界", 121),
      String.duplicate("😀", 121),
      String.duplicate("e\u0301", 60) <> "e"
    ]

    # 120 valid Unicode scalars need at most 480 bytes. A 512-byte name can
    # therefore only reach the defensive byte ceiling by exceeding the scalar cap.
    at_byte_ceiling = String.duplicate("😀", 128)
    assert byte_size(at_byte_ceiling) == 512

    cases =
      Enum.map(
        scalar_overflows ++ [at_byte_ceiling],
        &{&1, {:field_too_large, :name, 120}}
      ) ++
        [
          {at_byte_ceiling <> "a", {:field_too_large, :name, 512}},
          {<<0xFF>>, {:invalid_field, :name}},
          {"bad\0name", {:invalid_field, :name}}
        ]

    for {name, error} <- cases do
      assert {:error, ^error} = ProfileStore.create(%{id: "invalid", name: name}, opts)
      assert {:error, ^error} = ProfileStore.update("source", %{name: name}, opts)
      assert {:error, ^error} = ProfileStore.rename("source", name, opts)

      assert {:error, ^error} =
               ProfileStore.clone("source", %{id: "invalid-clone", name: name}, opts)
    end

    assert {:ok, %{"name" => "Source"}} = ProfileStore.get("source", opts)
    assert {:error, :not_found} = ProfileStore.get("invalid", opts)
    assert {:error, :not_found} = ProfileStore.get("invalid-clone", opts)
  end

  @tag :tmp_dir
  test "128 KiB system prompts roundtrip exactly through every lifecycle and snapshot hash", %{
    tmp_dir: root
  } do
    opts = opts(root)
    prompt = "\n " <> String.duplicate("😀", 32_767) <> " \n"
    replacement = "\t " <> String.duplicate("界", 43_689) <> " \t\n"
    assert byte_size(prompt) == 131_072
    assert byte_size(replacement) == 131_072
    assert {:ok, created} = ProfileStore.create(%{id: "prompt", systemPrompt: prompt}, opts)
    assert created["systemPrompt"] == prompt
    assert {:ok, fetched} = ProfileStore.get("prompt", opts)
    assert fetched["systemPrompt"] == prompt
    assert {:ok, first_snapshot} = ProfileStore.persona_snapshot("prompt", opts)
    assert {:ok, first_payload} = LemonCore.ProfileSnapshot.build(first_snapshot)
    assert first_payload["systemPrompt"] == prompt
    assert first_payload["revisionDigest"] == persona_digest("prompt", prompt)

    assert {:ok, updated} = ProfileStore.update("prompt", %{systemPrompt: replacement}, opts)
    assert updated["systemPrompt"] == replacement
    assert {:ok, reloaded} = ProfileStore.get("prompt", opts)
    assert reloaded["systemPrompt"] == replacement
    assert {:ok, cloned} = ProfileStore.clone("prompt", %{id: "prompt-clone"}, opts)
    assert cloned["systemPrompt"] == replacement

    for id <- ["prompt", "prompt-clone"] do
      assert {:ok, snapshot} = ProfileStore.persona_snapshot(id, opts)
      assert snapshot["systemPrompt"] == replacement
      assert {:ok, payload} = LemonCore.ProfileSnapshot.build(snapshot)
      assert payload["revisionDigest"] == persona_digest(id, replacement)
      assert :ok = LemonCore.ProfileSnapshot.validate(payload)
    end

    refute first_payload["revisionDigest"] == persona_digest("prompt", replacement)
  end

  @tag :tmp_dir
  test "system prompt overflow invalid UTF-8 and NUL fail closed without changing stored text", %{
    tmp_dir: root
  } do
    opts = opts(root)
    assert {:ok, _} = ProfileStore.create(%{id: "source", systemPrompt: " \nexact\n "}, opts)

    for {prompt, error} <- [
          {String.duplicate("x", 131_072) <> " ", {:field_too_large, :system_prompt, 131_072}},
          {<<0xFF>>, {:invalid_field, :system_prompt}},
          {<<0xED, 0xA0, 0x80>>, {:invalid_field, :system_prompt}},
          {"bad\0prompt", {:invalid_field, :system_prompt}}
        ] do
      assert {:error, ^error} = ProfileStore.create(%{id: "invalid", systemPrompt: prompt}, opts)
      assert {:error, ^error} = ProfileStore.update("source", %{systemPrompt: prompt}, opts)

      assert {:error, ^error} =
               ProfileStore.clone("source", %{id: "invalid-clone", systemPrompt: prompt}, opts)
    end

    assert {:ok, %{"systemPrompt" => " \nexact\n "}} = ProfileStore.get("source", opts)
    assert {:error, :not_found} = ProfileStore.get("invalid", opts)
    assert {:error, :not_found} = ProfileStore.get("invalid-clone", opts)
  end

  @tag :tmp_dir
  test "larger system prompt capacity does not enlarge chat or persona file limits", %{
    tmp_dir: root
  } do
    assert {:ok, profile} = ProfileStore.create(%{id: "independent-limits"}, opts(root))
    text = String.duplicate("界", 21_845) <> "x"
    assert byte_size(text) == 65_536
    assert {:ok, _} = ProfileStore.chat_request(profile, text)

    assert {:error, {:field_too_large, :prompt, 65_536}} =
             ProfileStore.chat_request(profile, text <> "x")

    path = Path.join(profile["paths"]["workspace"], "SOUL.md")
    File.write!(path, text)

    assert {:ok, %{"instructions" => %{"SOUL.md" => ^text}}} =
             ProfileStore.persona_snapshot(profile["id"], opts(root))

    for invalid <- [text <> "x", <<0xFF>>, "bad\0persona"] do
      File.write!(path, invalid)

      assert {:error, :invalid_profile_instructions} =
               ProfileStore.persona_snapshot(profile["id"], opts(root))
    end
  end

  @tag :tmp_dir
  test "full connector policy capacity persists without truncating tools or approvals", %{
    tmp_dir: root
  } do
    names = Enum.map(1..16_384, &"mcp_connector_tool_#{&1}")
    approvals = Map.new(names, &{&1, "always"})

    policy = %{
      "allow" => names,
      "deny" => names,
      "blocked_tools" => names,
      "require_approval" => names,
      "approvals" => approvals
    }

    assert {:ok, ^policy} = LemonCore.ToolPolicy.normalize(policy)

    assert {:ok, created} =
             ProfileStore.create(%{id: "large-policy", toolPolicy: policy}, opts(root))

    assert created["toolPolicy"] == policy
    assert {:ok, reloaded} = ProfileStore.get("large-policy", opts(root))
    assert reloaded["toolPolicy"] == policy

    assert {:ok, updated} =
             ProfileStore.update("large-policy", %{name: "Large Policy"}, opts(root))

    assert updated["toolPolicy"] == policy

    assert {:ok, cloned} =
             ProfileStore.clone("large-policy", %{id: "large-policy-clone"}, opts(root))

    assert cloned["toolPolicy"] == policy
    too_many = names ++ ["overflow"]

    for key <- ["allow", "deny", "blocked_tools", "require_approval"] do
      assert {:error, {:invalid_field, :tool_policy}} =
               LemonCore.ToolPolicy.normalize(%{key => too_many})
    end

    assert {:error, {:invalid_field, :tool_policy}} =
             LemonCore.ToolPolicy.normalize(%{
               "approvals" => Map.put(approvals, "overflow", "always")
             })
  end

  @tag :tmp_dir
  test "native tool policy persists, reloads, clones, and restricts every invocation", %{
    tmp_dir: root
  } do
    opts = opts(root)

    policy = %{
      "allow" => ["read", "write", "bash", "cron"],
      "deny" => ["bash"],
      "require_approval" => ["write"],
      "approvals" => %{"write" => "always"}
    }

    assert {:ok, profile} = ProfileStore.create(%{id: "policy", toolPolicy: policy}, opts)
    assert profile["toolPolicy"] == policy
    assert {:ok, fetched} = ProfileStore.get("policy", opts)
    assert fetched["toolPolicy"] == policy
    assert {:ok, clone} = ProfileStore.clone("policy", %{id: "policy-clone"}, opts)
    assert clone["toolPolicy"] == policy
    assert {:ok, updated} = ProfileStore.update("policy", %{name: "Renamed"}, opts)
    assert updated["toolPolicy"] == policy

    for session <- [
          nil,
          "agent:policy:task-arbitrary",
          "agent:policy:telegram:bot:dm:42",
          "agent:policy:telegram:bot:group:42"
        ] do
      assert {:ok, request} =
               ProfileStore.chat_request(fetched, "hello",
                 session_key: session,
                 tool_policy: %{
                   "allow" => "all",
                   "deny" => [],
                   "require_approval" => [],
                   "approvals" => %{"write" => "never"}
                 },
                 meta: %{tool_policy: %{allow: :all}}
               )

      assert request.tool_policy.allow == policy["allow"]
      assert request.tool_policy.deny == ["bash"]
      assert request.tool_policy.require_approval == ["write"]
      assert request.tool_policy.approvals["write"] == :always
      refute Map.has_key?(request.meta, :tool_policy)
    end

    assert {:ok, cleared} = ProfileStore.update("policy", %{toolPolicy: %{}}, opts)
    assert cleared["toolPolicy"] == %{}

    for invalid <- [
          %{"profile" => "unknown"},
          %{"allow" => true},
          %{"approvals" => %{"bash" => "dangerous"}},
          %{"network" => false},
          %{"deny" => ["bad name"]}
        ] do
      assert {:error, {:invalid_field, :tool_policy}} =
               ProfileStore.update("policy", %{toolPolicy: invalid}, opts)
    end
  end

  @tag :tmp_dir
  test "MCP fingerprint binds private configuration and projection is idempotent", %{
    tmp_dir: root
  } do
    opts = opts(root)

    server = %{
      "name" => "bot",
      "url" => "https://example.com/mcp",
      "headers" => %{"X-B" => "b", "Authorization" => "secret"}
    }

    assert {:ok, profile} = ProfileStore.create(%{id: "fingerprint", mcpServers: [server]}, opts)

    expected =
      :crypto.hash(
        :sha256,
        Jason.encode!([
          [
            "bot",
            "https://example.com/mcp",
            [["Authorization", "secret"], ["X-B", "b"]],
            nil,
            nil,
            nil
          ]
        ])
      )
      |> Base.encode16(case: :lower)

    assert profile["mcpConfigFingerprint"] == expected
    assert ProfileStore.projection(profile) == profile
    refute inspect(profile) =~ "secret"
    assert {:ok, private} = ProfileStore.get_for_execution("fingerprint", opts)
    assert ProfileStore.projection(private)["mcpConfigFingerprint"] == expected

    assert {:ok, updated} =
             ProfileStore.update(
               "fingerprint",
               %{mcpServers: [Map.put(server, "enabledTools", [])]},
               opts
             )

    refute updated["mcpConfigFingerprint"] == expected
  end

  @tag :tmp_dir
  test "metadata updates and cloning preserve literal escapes in private MCP definitions", %{
    tmp_dir: root
  } do
    opts = opts(root)

    servers = [
      %{
        "name" => "connector",
        "url" => "https://example.com/mcp",
        "headers" => %{
          "Authorization" => ~S(Bearer "quoted"\token),
          "X-Path" => ~S(C:\owner\1\g{1}\0\\tail)
        },
        "enabledTools" => ["read"]
      }
    ]

    public_servers = Enum.map(servers, &Map.delete(&1, "headers"))

    assert {:ok, created} = ProfileStore.create(%{id: "escaped-mcp", mcpServers: servers}, opts)
    assert created["mcpServers"] == public_servers
    assert {:ok, private} = ProfileStore.get_for_execution("escaped-mcp", opts)
    assert private["mcpServers"] == servers

    assert {:ok, updated} = ProfileStore.update("escaped-mcp", %{name: "Renamed"}, opts)
    assert updated["mcpServers"] == public_servers
    assert updated["mcpConfigFingerprint"] == created["mcpConfigFingerprint"]
    assert {:ok, private} = ProfileStore.get_for_execution("escaped-mcp", opts)
    assert private["mcpServers"] == servers

    assert {:ok, cloned} = ProfileStore.clone("escaped-mcp", %{id: "escaped-mcp-clone"}, opts)
    assert cloned["mcpServers"] == public_servers
    assert cloned["mcpConfigFingerprint"] == created["mcpConfigFingerprint"]
    assert {:ok, private_clone} = ProfileStore.get_for_execution("escaped-mcp-clone", opts)
    assert private_clone["mcpServers"] == servers
  end

  @tag :tmp_dir
  test "persona text rejects NUL and origin policy canonicalizes DNS and IPv6", %{tmp_dir: root} do
    opts = opts(root)

    assert {:error, {:invalid_field, :system_prompt}} =
             ProfileStore.create(%{id: "nul", systemPrompt: "bad\0prompt"}, opts)

    assert {:ok, profile} = ProfileStore.create(%{id: "persona-nul"}, opts)
    File.write!(Path.join(profile["paths"]["workspace"], "SOUL.md"), "bad\0persona")
    assert {:error, :invalid_profile_instructions} = ProfileStore.chat_request(profile, "hello")

    assert {:ok, [server]} =
             ProfileStore.normalize_mcp_servers([
               %{
                 "name" => "bot",
                 "url" => "https://example.com/mcp",
                 "allowedOrigins" => [
                   "https://EXAMPLE.COM./",
                   "http://[2001:0db8:0000:0000:0000:0000:0000:0001]:8080"
                 ]
               }
             ])

    assert server["allowedOrigins"] == ["https://example.com", "http://[2001:db8::1]:8080"]
    refute Map.has_key?(server, "approvedPrivateOrigins")
  end

  @tag :tmp_dir
  test "creates, lists, renames, exports, and recoverably deletes a profile", %{tmp_dir: root} do
    opts = opts(root)
    config = Keyword.fetch!(opts, :config_path)

    original = """
    # user comment must survive lifecycle edits
    [custom]
    unknown = "keep-me"
    """

    File.mkdir_p!(Path.dirname(config))
    File.write!(config, original)

    assert {:ok, profile} =
             ProfileStore.create(
               %{
                 id: "research-bot",
                 name: "Research Bot",
                 description: "isolated researcher",
                 model: "openai:gpt-5",
                 system_prompt: "Be rigorous"
               },
               opts
             )

    assert profile["canonicalSessionKey"] == "agent:research-bot:main"

    assert profile["paths"]["workspace"] ==
             Path.join([root, "state", "profiles", "research-bot", "workspace"])

    assert File.dir?(profile["paths"]["memory"])
    assert File.dir?(profile["paths"]["skills"])
    assert File.regular?(profile["paths"]["manifest"])
    assert [%{"id" => "research-bot"}] = Enum.map(ProfileStore.list(opts), &Map.take(&1, ["id"]))

    assert {:ok, renamed} = ProfileStore.rename("research-bot", "Research Prime", opts)
    assert renamed["name"] == "Research Prime"
    assert renamed["canonicalSessionKey"] == profile["canonicalSessionKey"]

    export_path = Path.join(root, "research-profile.json")
    assert {:ok, %{"fileCount" => count}} = ProfileStore.export("research-bot", export_path, opts)
    assert count >= 1
    assert {:error, :destination_exists} = ProfileStore.export("research-bot", export_path, opts)

    assert %{"format" => "lemon-profile", "profile" => %{"id" => "research-bot"}} =
             export_path |> File.read!() |> Jason.decode!()

    assert {:error, :confirmation_required} = ProfileStore.delete("research-bot", opts)

    assert {:ok, %{"homeMoved" => true, "trashPath" => trash}} =
             ProfileStore.delete("research-bot", Keyword.put(opts, :confirm, "research-bot"))

    assert File.dir?(trash)
    refute File.exists?(profile["paths"]["home"])
    assert {:error, :not_found} = ProfileStore.get("research-bot", opts)

    final_config = File.read!(config)
    assert final_config =~ "# user comment must survive lifecycle edits"
    assert final_config =~ ~s([custom]\nunknown = "keep-me")
    refute final_config =~ "[profiles.research-bot]"
  end

  @tag :tmp_dir
  test "export is selected-file and credential-safe by default", %{tmp_dir: root} do
    opts = opts(root)

    assert {:ok, profile} =
             ProfileStore.create(
               %{id: "portable", system_prompt: "authorization = Bearer raw-profile-token"},
               opts
             )

    File.write!(
      profile["paths"]["config"],
      "api_key = \"sk-profile-config-secret-123456\"\nmode = \"safe\"\n"
    )

    File.write!(Path.join(profile["paths"]["workspace"], "SOUL.md"), "Bearer soul-token-123")
    File.write!(Path.join(profile["paths"]["memory"], "MEMORY.md"), "memory-token-leak")
    File.write!(Path.join(profile["paths"]["sessions"], "run.json"), "session-token-leak")
    File.write!(Path.join(profile["paths"]["skills"], "private_token.txt"), "skill-token-leak")

    destination = Path.join(root, "portable.json")

    assert {:ok, %{"omittedCount" => omitted, "redactionCount" => redactions}} =
             ProfileStore.export("portable", destination, opts)

    assert omitted >= 3
    assert redactions >= 3

    exported = File.read!(destination)
    refute exported =~ "sk-profile-config-secret-123456"
    refute exported =~ "raw-profile-token"
    refute exported =~ "soul-token-123"
    refute exported =~ "memory-token-leak"
    refute exported =~ "session-token-leak"
    refute exported =~ "skill-token-leak"

    decoded = Jason.decode!(exported)
    assert decoded["exportPolicy"]["includesSessions"] == false
    assert decoded["exportPolicy"]["includesMemory"] == false
    assert decoded["exportPolicy"]["includesSecrets"] == false
    assert decoded["exportPolicy"]["omissionCounts"]["private_boundary"] >= 2
    assert decoded["files"]["config.toml"]["redacted"]
    assert decoded["files"]["workspace/SOUL.md"]["redacted"]
  end

  @tag :tmp_dir
  test "clone copies regular memory and skills but rejects symlinks", %{tmp_dir: root} do
    opts = opts(root)
    assert {:ok, source} = ProfileStore.create(%{id: "source", name: "Source"}, opts)
    File.write!(Path.join(source["paths"]["memory"], "MEMORY.md"), "remember")
    File.write!(Path.join(source["paths"]["skills"], "SKILL.md"), "skill")

    assert {:ok, clone} =
             ProfileStore.clone("source", %{id: "copy", name: "Copy"}, opts)

    assert File.read!(Path.join(clone["paths"]["memory"], "MEMORY.md")) == "remember"
    assert File.read!(Path.join(clone["paths"]["skills"], "SKILL.md")) == "skill"
    assert clone["canonicalSessionKey"] == "agent:copy:main"

    outside = Path.join(root, "outside")
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(source["paths"]["workspace"], "unsafe-link"))

    assert {:error, {:unsafe_profile_entry, _}} =
             ProfileStore.clone("source", %{id: "unsafe-copy"}, opts)

    assert {:error, :not_found} = ProfileStore.get("unsafe-copy", opts)
  end

  @tag :tmp_dir
  test "rejects invalid ids, reserved ids, collisions, and symlinked homes", %{tmp_dir: root} do
    opts = opts(root)

    assert {:error, :invalid_id} = ProfileStore.create(%{id: "../escape"}, opts)
    assert {:error, :reserved_profile} = ProfileStore.create(%{id: "default"}, opts)
    assert {:ok, _} = ProfileStore.create(%{id: "one", name: "One"}, opts)
    assert {:error, :already_exists} = ProfileStore.create(%{id: "one", name: "Other"}, opts)

    {:ok, paths} = ProfileStore.paths("linked", opts)
    File.mkdir_p!(Path.dirname(paths["home"]))
    outside = Path.join(root, "outside-home")
    File.mkdir_p!(outside)
    File.ln_s!(outside, paths["home"])

    assert {:error, :unsafe_profile_home} =
             ProfileStore.create(%{id: "linked", name: "Linked"}, opts)
  end

  @tag :tmp_dir
  test "create rolls config back when the prepared home cannot commit", %{tmp_dir: root} do
    opts = opts(root)
    config = Keyword.fetch!(opts, :config_path)
    File.mkdir_p!(Path.dirname(config))
    File.write!(config, "# original\n")
    {:ok, paths} = ProfileStore.paths("raced", opts)

    writer = fn path, content ->
      :ok = File.write(path, content)
      :ok = File.write(paths["home"], "collision")
      :ok
    end

    assert {:error, {:home_commit_failed, _}} =
             ProfileStore.create(
               %{id: "raced", name: "Raced"},
               Keyword.put(opts, :atomic_write_fun, writer)
             )

    assert File.read!(config) == "# original\n"
    assert {:error, :not_found} = ProfileStore.get("raced", opts)
  end

  @tag :tmp_dir
  test "rename and delete restore config and home on commit failures", %{tmp_dir: root} do
    opts = opts(root)
    assert {:ok, profile} = ProfileStore.create(%{id: "safe", name: "Safe"}, opts)

    File.rm!(profile["paths"]["manifest"])
    File.mkdir_p!(profile["paths"]["manifest"])
    assert {:error, _} = ProfileStore.rename("safe", "Changed", opts)
    assert {:ok, %{"name" => "Safe"}} = ProfileStore.get("safe", opts)

    failing_writer = fn _path, _content -> {:error, :forced_write_failure} end

    assert {:error, :forced_write_failure} =
             ProfileStore.delete(
               "safe",
               opts
               |> Keyword.put(:confirm, "safe")
               |> Keyword.put(:atomic_write_fun, failing_writer)
             )

    assert File.dir?(profile["paths"]["home"])
    assert {:ok, %{"id" => "safe"}} = ProfileStore.get("safe", opts)
  end

  @tag :tmp_dir
  test "delete refuses a symlinked managed home", %{tmp_dir: root} do
    opts = opts(root)
    assert {:ok, profile} = ProfileStore.create(%{id: "linked-delete"}, opts)
    File.rm_rf!(profile["paths"]["home"])
    outside = Path.join(root, "outside-delete")
    File.mkdir_p!(outside)
    File.ln_s!(outside, profile["paths"]["home"])

    assert {:error, :unsafe_profile_home} =
             ProfileStore.delete("linked-delete", Keyword.put(opts, :confirm, "linked-delete"))

    assert File.dir?(outside)
  end

  test "default profile deletion is always guarded" do
    assert {:error, :reserved_profile} = ProfileStore.delete("default", confirm: "default")
  end

  test "canonical chat binds validated profile identity and node over caller metadata" do
    profile = %{
      "id" => "remote",
      "node" => "newphy",
      "model" => "openai:gpt-5",
      "canonicalSessionKey" => "agent:remote:main",
      "paths" => %{"workspace" => "/controller/profile/workspace"}
    }

    assert {:ok, request} =
             ProfileStore.chat_request(profile, "route me",
               meta: %{
                 "profile_id" => "also-forged",
                 "node" => "local",
                 profile_id: "forged",
                 node: "ophy"
               }
             )

    assert request.meta.profile_id == "remote"
    assert request.meta.node == "newphy"
    refute Map.has_key?(request.meta, "profile_id")
    refute Map.has_key?(request.meta, "node")
    assert request.cwd == nil

    assert {:error, {:invalid_field, :node}} =
             ProfileStore.chat_request(%{profile | "node" => "../bad-node"}, "route me")
  end

  @tag :tmp_dir
  test "updates persist all placement fields and preserve MCP secrets only for execution", %{
    tmp_dir: root
  } do
    opts = opts(root)

    servers = [
      %{
        "name" => "lemon-bot",
        "url" => "https://bot.example/mcp",
        "headers" => %{"Authorization" => "Bearer private-bot-token"}
      }
    ]

    assert {:ok, original} =
             ProfileStore.create(%{id: "placed", description: "keep", mcpServers: servers}, opts)

    refute inspect(original) =~ "private-bot-token"
    config = Keyword.fetch!(opts, :config_path)
    File.write!(config, File.read!(config) <> "\n[custom]\nkeep = true\n")
    File.chmod!(config, 0o644)

    File.write!(
      Path.join(original["paths"]["workspace"], "SOUL.md"),
      "Be an evidence-first teammate."
    )

    assert {:ok, updated} =
             ProfileStore.update(
               "placed",
               %{
                 name: "Placed Bot",
                 avatar: "lemon",
                 model: "openai:gpt-5",
                 systemPrompt: "Research carefully",
                 node: "worker-1"
               },
               opts
             )

    assert updated["description"] == "keep"
    assert updated["createdAt"] == original["createdAt"]
    assert updated["mcpServers"] == [%{"name" => "lemon-bot", "url" => "https://bot.example/mcp"}]
    assert {:ok, ^updated} = ProfileStore.get("placed", opts)
    assert [%{"mcpServers" => projected}] = ProfileStore.list(opts)
    assert projected == updated["mcpServers"]
    refute File.read!(updated["paths"]["manifest"]) =~ "private-bot-token"
    assert File.read!(config) =~ "[custom]\nkeep = true"
    assert Bitwise.band(File.stat!(config).mode, 0o777) == 0o600

    assert {:ok, execution_profile} = ProfileStore.get_for_execution("placed", opts)
    assert execution_profile["mcpServers"] == servers

    assert {:ok, request} =
             ProfileStore.chat_request(execution_profile, "Investigate",
               session_key: "agent:placed:task-123",
               run_id: "run-placement"
             )

    assert request.cwd == nil
    assert request.session_key == "agent:placed:task-123"
    assert request.run_id == "run-placement"
    assert request.model == "openai:gpt-5"
    assert request.meta.node == "worker-1"
    assert request.meta.system_prompt == "Research carefully"
    assert request.meta.profile_instructions == %{"SOUL.md" => "Be an evidence-first teammate."}
    assert request.meta.mcp_servers == servers
    assert request.meta.remote_cwd_explicit == false
    assert request.meta.remote_cwd == nil

    destination = Path.join(root, "placed-export.json")
    assert {:ok, _} = ProfileStore.export("placed", destination, opts)
    refute File.read!(destination) =~ "private-bot-token"

    assert {:ok, cleared} =
             ProfileStore.update(
               "placed",
               %{systemPrompt: "", mcpServers: [], node: "local"},
               opts
             )

    assert cleared["systemPrompt"] == nil
    assert cleared["mcpServers"] == []
  end

  @tag :tmp_dir
  test "controller persists and forwards destination secret references without resolving them", %{
    tmp_dir: root
  } do
    opts = opts(root)
    headers = %{"Authorization" => "${LEMON_SECRET:destination-only-token}"}
    servers = [%{"name" => "bot", "url" => "https://bot.example/mcp", "headers" => headers}]

    assert {:ok, public} =
             ProfileStore.create(%{id: "secret-bound", node: "worker", mcpServers: servers}, opts)

    refute inspect(public) =~ "destination-only-token"
    assert {:ok, profile} = ProfileStore.get_for_execution("secret-bound", opts)
    assert {:ok, request} = ProfileStore.chat_request(profile, "Use the connector")
    assert request.meta.mcp_servers == servers
    assert request.meta.node == "worker"
    assert request.cwd == nil
  end

  @tag :tmp_dir
  test "profile update rolls back and MCP definitions are validated without exposing values", %{
    tmp_dir: root
  } do
    opts = opts(root)
    assert {:ok, profile} = ProfileStore.create(%{id: "updated", name: "Original"}, opts)
    File.rm!(profile["paths"]["manifest"])
    File.mkdir_p!(profile["paths"]["manifest"])
    assert {:error, _} = ProfileStore.update("updated", %{name: "Changed"}, opts)
    assert {:ok, %{"name" => "Original"}} = ProfileStore.get("updated", opts)

    for servers <- [
          [%{"name" => "x", "url" => "file:///private"}],
          [%{"name" => "x", "url" => "https://user:secret@example.com/mcp"}],
          [
            %{
              "name" => "x",
              "url" => "https://example.com",
              "headers" => %{"Authorization" => "secret\r\nInjected: x"}
            }
          ],
          [
            %{"name" => "x", "url" => "https://example.com"},
            %{"name" => "x", "url" => "https://other.example"}
          ]
        ] do
      assert {:error, {:invalid_field, :mcp_servers}} =
               ProfileStore.update("updated", %{mcpServers: servers}, opts)
    end
  end

  @tag :tmp_dir
  test "invocation connectors replace defaults without inheriting owner headers", %{tmp_dir: root} do
    opts = opts(root)

    owner = %{
      "name" => "app",
      "url" => "https://owner.example/mcp",
      "headers" => %{"Authorization" => "${LEMON_SECRET:owner-token}"},
      "enabledTools" => ["read"],
      "allowedOrigins" => ["https://owner.example"],
      "approvedPrivateOrigins" => []
    }

    assert {:ok, _} = ProfileStore.create(%{id: "team-bot", mcpServers: [owner]}, opts)
    assert {:ok, profile} = ProfileStore.get_for_execution("team-bot", opts)
    assert profile["mcpServers"] == [owner]
    assert {:ok, default} = ProfileStore.chat_request(profile, "Default")
    assert default.meta.mcp_servers == [owner]

    assert {:ok, empty} =
             ProfileStore.chat_request(profile, "No connectors", invocation_mcp_servers: [])

    assert empty.meta.mcp_servers == []

    caller = %{
      "name" => "app",
      "url" => "https://caller.example/mcp",
      "headers" => %{},
      "enabledTools" => [],
      "allowedOrigins" => ["https://caller.example"],
      "approvedPrivateOrigins" => []
    }

    assert {:ok, overridden} =
             ProfileStore.chat_request(profile, "Caller only", invocation_mcp_servers: [caller])

    assert overridden.meta.mcp_servers == [caller]
    refute inspect(overridden.meta.mcp_servers) =~ "owner-token"
    assert {:ok, unchanged} = ProfileStore.get_for_execution("team-bot", opts)
    assert unchanged["mcpServers"] == [owner]

    assert {:error, {:invalid_field, :mcp_servers}} =
             ProfileStore.chat_request(profile, "Invalid", invocation_mcp_servers: nil)
  end

  test "MCP tool allowlists and destination origin consent are bounded and validated" do
    base = %{"name" => "app", "url" => "https://app.example/mcp", "headers" => %{}}

    assert {:ok, [normalized]} =
             ProfileStore.normalize_mcp_servers([
               Map.merge(base, %{
                 "enabledTools" => ["tool_*"],
                 "allowedOrigins" => ["https://APP.example:443/"],
                 "approvedPrivateOrigins" => []
               })
             ])

    assert normalized["enabledTools"] == ["tool_*"]
    assert normalized["allowedOrigins"] == ["https://app.example"]

    assert {:ok, [empty]} =
             ProfileStore.normalize_mcp_servers([Map.put(base, "enabledTools", [])])

    assert empty["enabledTools"] == []
    assert {:ok, [unrestricted]} = ProfileStore.normalize_mcp_servers([base])
    refute Map.has_key?(unrestricted, "enabledTools")
    refute Map.has_key?(unrestricted, "allowedOrigins")

    for patch <- [
          %{"headers" => false},
          %{"headers" => nil},
          %{"enabledTools" => nil},
          %{"enabledTools" => [""]},
          %{"enabledTools" => ["x", "x"]},
          %{"enabledTools" => ["not a name"]},
          %{"enabledTools" => List.duplicate("x", 257)},
          %{"allowedOrigins" => ["https://app.example/path"]},
          %{"allowedOrigins" => ["https://secret@app.example"]},
          %{"allowedOrigins" => ["https://app.example?q=secret"]},
          %{"approvedPrivateOrigins" => ["https://app.example"]},
          %{
            "allowedOrigins" => ["https://app.example"],
            "approvedPrivateOrigins" => ["http://127.0.0.1"]
          },
          %{"allowedOrigins" => ["https://app.example", "https://APP.example:443/"]}
        ] do
      assert {:error, {:invalid_field, :mcp_servers}} =
               ProfileStore.normalize_mcp_servers([Map.merge(base, patch)])
    end
  end

  @tag :tmp_dir
  test "persona snapshots never copy mutable user preferences or destination credentials", %{
    tmp_dir: root
  } do
    opts = opts(root)

    assert {:ok, profile} =
             ProfileStore.create(%{id: "persona", systemPrompt: "Trusted persona"}, opts)

    workspace = profile["paths"]["workspace"]
    File.write!(Path.join(workspace, "SOUL.md"), "Controller-owned persona")
    File.write!(Path.join(workspace, "USER.md"), "Controller-only mutable preference")
    File.write!(Path.join(workspace, "TOOLS.md"), "Controller-only credentials")
    assert {:ok, snapshot} = ProfileStore.persona_snapshot("persona", opts)

    assert snapshot == %{
             "id" => "persona",
             "model" => nil,
             "systemPrompt" => "Trusted persona",
             "instructions" => %{"SOUL.md" => "Controller-owned persona"}
           }

    assert {:ok, request} = ProfileStore.chat_request(profile, "Next turn")
    assert request.meta.profile_instructions == snapshot["instructions"]
    refute inspect(snapshot) =~ "Controller-only"
  end

  defp persona_digest(id, prompt) do
    canonical = [id, nil, prompt, Enum.map(LemonCore.ProfileSnapshot.filenames(), &[&1, nil])]
    :crypto.hash(:sha256, Jason.encode!(canonical)) |> Base.encode16(case: :lower)
  end

  defp opts(root) do
    state = Path.join(root, "state")
    [home_state_dir: state, config_path: Path.join(state, "config.toml")]
  end
end
