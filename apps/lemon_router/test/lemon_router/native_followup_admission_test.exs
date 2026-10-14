defmodule LemonRouter.NativeFollowupAdmissionTest do
  use ExUnit.Case, async: false

  alias LemonCore.{ProfileStore, Secrets, Store}
  alias LemonRouter.NativeFollowupAdmission

  @origin "https://native-admission.example.test"
  @token "private-native-issuer-token"
  @run_id "native-followup-fixed"
  @fixture [plug: {Req.Test, __MODULE__}]

  defmodule HTTPFixture do
    @behaviour Plug
    def init(opts), do: opts
    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(opts.pid, {:native_http_request, conn.method, conn.request_path, conn.req_headers, body})
      conn = Enum.reduce(Map.get(opts, :headers, []), conn, fn {name, value}, conn -> Plug.Conn.put_resp_header(conn, name, value) end)
      Plug.Conn.send_resp(conn, opts.status, opts.body)
    end
  end

  setup do
    suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    root = Path.join(System.tmp_dir!(), "native-admission-" <> suffix)
    state = Path.join(root, "state")
    File.mkdir_p!(state)
    previous_paths = Application.fetch_env(:lemon_core, :paths)
    previous_secrets = Application.fetch_env(:lemon_core, Secrets)
    previous_origins = Application.fetch_env(:lemon_router, :native_followup_allowed_origins)
    previous_origin_env = System.get_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS")
    key_env = "NATIVE_ADMISSION_TEST_KEY_" <> suffix
    profile_id = "native-issuer-" <> suffix

    System.put_env(key_env, Base.encode64(:crypto.strong_rand_bytes(32)))
    System.delete_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS")
    Application.put_env(:lemon_core, :paths, home_state_dir: state, global_config: Path.join(state, "config.toml"))
    Application.put_env(:lemon_core, Secrets, key_providers: [:env], env_var: key_env)
    Application.put_env(:lemon_router, :native_followup_allowed_origins, [@origin])
    assert {:ok, _profile} = ProfileStore.create(%{"id" => profile_id, "name" => "Native issuer", "mcpServers" => templates()})
    assert {:ok, secret_name} = NativeFollowupAdmission.configure(profile_id, @origin <> "/internal/runtime/followup/admission", @token)
    assert {:ok, config} = NativeFollowupAdmission.fetch_config(profile_id)

    on_exit(fn ->
      {:ok, secrets} = Secrets.list()
      for secret <- secrets, String.starts_with?(secret.name, "native_followup/" <> profile_id <> "/"), do: Secrets.delete(secret.name)
      Store.delete(:native_followup_admission_configs, profile_id)
      restore_env(:lemon_core, :paths, previous_paths)
      restore_env(:lemon_core, Secrets, previous_secrets)
      restore_env(:lemon_router, :native_followup_allowed_origins, previous_origins)
      restore_system_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS", previous_origin_env)
      System.delete_env(key_env)
      File.rm_rf!(root)
    end)

    %{profile_id: profile_id, config: config, secret_name: secret_name,
      lineage: %{run_id: @run_id, source_profile_id: profile_id, target_profile_id: profile_id}, state: state}
  end

  test "provisions encrypted credentials without changing actual profile projections", ctx do
    assert {:ok, @token} = Secrets.get(ctx.secret_name)
    assert {:ok, encrypted} = Store.fetch(Secrets.table(), {Secrets.default_owner(), ctx.secret_name})
    assert is_binary(encrypted.ciphertext)
    refute inspect(encrypted) =~ @token
    assert {:ok, profile} = ProfileStore.get(ctx.profile_id)
    assert {:ok, execution} = ProfileStore.get_for_execution(ctx.profile_id)
    assert {:ok, _updated} = ProfileStore.update(ctx.profile_id, %{"description" => "Unrelated field survives"})
    assert {:ok, updated} = ProfileStore.get(ctx.profile_id)
    assert updated["description"] == "Unrelated field survives"
    for projection <- [profile, execution, updated, ProfileStore.list()] do
      refute inspect(projection) =~ @origin
      refute inspect(projection) =~ @token
      refute inspect(projection) =~ ctx.secret_name
    end
    refute File.read!(Path.join(ctx.state, "config.toml")) =~ @origin
    destination = Path.join(ctx.state, "native-profile-export.json")
    assert {:ok, _report} = ProfileStore.export(ctx.profile_id, destination)
    exported = File.read!(destination)
    refute exported =~ @origin
    refute exported =~ @token
    refute exported =~ ctx.secret_name
  end

  test "rejects unknown profiles, strict invalid IDs and unsafe or unbounded tokens", ctx do
    assert {:error, :profile_not_found} = NativeFollowupAdmission.configure("does-not-exist", @origin <> "/check", @token)
    for id <- [nil, "", "../escape", "UPPER", String.duplicate("x", 65)] do
      assert {:error, :invalid_request} = NativeFollowupAdmission.configure(id, @origin <> "/check", @token)
    end
    for token <- [nil, "", "  ", "secret\r\nheader", <<0>>, <<255>>, String.duplicate("x", 4097)] do
      assert {:error, :invalid_request} = NativeFollowupAdmission.configure(ctx.profile_id, @origin <> "/check", token)
    end
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.fetch_config("does-not-exist")
  end

  test "unavailable encryption never provisions fake success or replaces current configuration", ctx do
    missing_env = "NATIVE_ADMISSION_MISSING_KEY_#{System.unique_integer([:positive])}"
    System.delete_env(missing_env)
    Application.put_env(:lemon_core, Secrets, key_providers: [:env], env_var: missing_env)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.configure(ctx.profile_id, @origin <> "/replacement", "replacement-token")
    assert {:ok, config} = NativeFollowupAdmission.fetch_config(ctx.profile_id)
    assert config == ctx.config
    Req.Test.stub(__MODULE__, fn _conn -> flunk("unavailable encrypted credential reached callback") end)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(config, ctx.lineage, @fixture)
  end

  test "exact origin, HTTPS, URL syntax and environment precedence fail closed", ctx do
    for url <- ["http://native-admission.example.test/check", "https://sub.native-admission.example.test/check",
                "https://native-admission.example.test.evil/check", @origin <> ":8443/check",
                "https://user:secret@native-admission.example.test/check", @origin <> "/check?token=secret",
                @origin <> "/check#fragment", @origin <> ":/check", @origin <> "/%xx",
                @origin <> "/check\r\n", @origin <> "/" <> String.duplicate("x", 2048)] do
      assert {:error, :invalid_request} = NativeFollowupAdmission.configure(ctx.profile_id, url, @token)
    end
    assert {:ok, _} = NativeFollowupAdmission.configure(ctx.profile_id, @origin <> ":443/check", @token)
    for origins <- [[], nil, @origin, [@origin <> "/"], [@origin <> "/path"], ["https://*.example.test"]] do
      Application.put_env(:lemon_router, :native_followup_allowed_origins, origins)
      assert {:error, :invalid_request} = NativeFollowupAdmission.configure(ctx.profile_id, @origin <> "/check", @token)
    end
    Application.put_env(:lemon_router, :native_followup_allowed_origins, [@origin])
    System.put_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS", "")
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.fetch_config(ctx.profile_id)
    System.put_env("LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS", " https://other.example.test, " <> @origin <> " ")
    assert {:ok, _} = NativeFollowupAdmission.fetch_config(ctx.profile_id)
  end

  test "HTTP requires exact allowlisted literal loopback origins", ctx do
    for origin <- ["http://127.0.0.1:8123", "http://[::1]:8123"] do
      Application.put_env(:lemon_router, :native_followup_allowed_origins, [origin])
      assert {:ok, _} = NativeFollowupAdmission.configure(ctx.profile_id, origin <> "/check", @token)
      assert {:error, :invalid_request} = NativeFollowupAdmission.configure(ctx.profile_id, String.replace(origin, ":8123", ":8124") <> "/check", @token)
    end
    for origin <- ["http://localhost:8123", "http://127.0.0.2:8123", "http://127.1:8123", "http://2130706433:8123", "http://[0:0:0:0:0:0:0:1]:8123", "http://10.0.0.1:8123"] do
      Application.put_env(:lemon_router, :native_followup_allowed_origins, [origin])
      assert {:error, :invalid_request} = NativeFollowupAdmission.configure(ctx.profile_id, origin <> "/check", @token)
    end
  end

  test "approved callback sends only reserved F and private bearer and returns unattested JSON", ctx do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/internal/runtime/followup/admission"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"runId" => @run_id}
      Req.Test.json(conn, %{"allow" => true, "invocation" => invocation()})
    end)
    assert {:ok, projection} = NativeFollowupAdmission.check(ctx.config, Map.merge(ctx.lineage, %{prompt: "never transmit", actor: "never transmit", parent_run_id: "never transmit"}), @fixture)
    assert Enum.sort(Map.keys(projection)) == Enum.sort(Map.keys(invocation()))
    assert projection["sharedMemoryGrant"] == false
    assert projection["invocationProof"] == invocation()["invocationProof"]
    refute Map.has_key?(projection, "invocationProofVerified")
    refute Map.has_key?(projection, "memoryContextVerified")
  end

  test "complete policies larger than 64 KiB remain intact within the native execution byte cap", ctx do
    tools = Enum.map(1..2048, &("tool_#{&1}_" <> String.duplicate("x", 40)))
    policy = %{"allow" => ["read"], "deny" => tools, "require_approval" => tools,
               "approvals" => Map.new(tools, &{&1, "always"})}
    complete = Map.put(invocation(), "invocationToolPolicy", policy)
    assert byte_size(Jason.encode!(complete)) > 65_536
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"allow" => true, "invocation" => complete}))
    assert {:ok, projection} = NativeFollowupAdmission.check(ctx.config, ctx.lineage, @fixture)
    assert projection["invocationToolPolicy"] == policy
  end

  test "source callback credential rotation during response invalidates admission", ctx do
    Req.Test.stub(__MODULE__, fn conn ->
      assert {:ok, _} = NativeFollowupAdmission.configure(ctx.profile_id, ctx.config.url, "rotated-source-bearer")
      Req.Test.json(conn, %{"allow" => true, "invocation" => invocation()})
    end)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(ctx.config, ctx.lineage, @fixture)
    assert {:ok, current} = NativeFollowupAdmission.fetch_config(ctx.profile_id)
    assert current.token_secret != ctx.config.token_secret
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer rotated-source-bearer"]
      Req.Test.json(conn, %{"allow" => true, "invocation" => invocation()})
    end)
    assert {:ok, _} = NativeFollowupAdmission.check(current, ctx.lineage, @fixture)
  end

  test "missing configuration or credentials, wrong source and option overrides never callback", ctx do
    Req.Test.stub(__MODULE__, fn _conn -> flunk("invalid configuration reached callback") end)
    for opts <- [[url: @origin], [headers: []], [retry: true], [redirect: true], [receive_timeout: 1], [plug: nil, plug: nil], [adapter: fn _ -> nil end]] do
      assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(ctx.config, ctx.lineage, opts)
    end
    for config <- [nil, Map.put(ctx.config, :url, @origin <> "/model-selected"), Map.put(ctx.config, :token, @token)] do
      assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(config, ctx.lineage, @fixture)
    end
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(ctx.config, %{ctx.lineage | source_profile_id: "other"}, @fixture)
    assert :ok = Secrets.delete(ctx.secret_name)
    System.put_env(ctx.secret_name, @token)
    on_exit(fn -> System.delete_env(ctx.secret_name) end)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(ctx.config, ctx.lineage, @fixture)
  end

  test "denial and all unavailable responses have only bounded redacted classifications", ctx do
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"allow" => false}))
    assert {:error, :denied} = NativeFollowupAdmission.check(ctx.config, ctx.lineage, @fixture)
    for {status, body} <- [{401, @token}, {403, @origin}, {500, "private backend failure"},
                           {200, "not json"}, {200, Jason.encode!(%{"allow" => true})},
                           {200, Jason.encode!(%{"allow" => false, "private" => @token})},
                           {200, Jason.encode!(%{"allow" => false, "invocation" => invocation()})},
                           {200, String.duplicate("x", 16_777_217)}] do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, status, body))
      assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(ctx.config, ctx.lineage, @fixture)
    end
  end

  test "duplicate JSON authority fields fail closed at every nested level", ctx do
    json = Jason.encode!(%{"allow" => true, "invocation" => invocation()})
    for body <- [String.replace(json, "\"allow\":true", "\"allow\":false,\"allow\":true"),
                 String.replace(json, "\"memoryContextKey\":\"source-context\"", "\"memoryContextKey\":\"other\",\"memoryContextKey\":\"source-context\""),
                 String.replace(json, "\"runId\":\"" <> @run_id <> "\"", "\"runId\":\"old\",\"runId\":\"" <> @run_id <> "\""),
                 String.replace(json, "\"deny\":[]", "\"deny\":[\"read\"],\"deny\":[]")] do
      refute body == json
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))
      assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(ctx.config, ctx.lineage, @fixture)
    end
  end

  test "strict invocation policy, server, proof, scalar and privacy shapes reject malformed or extra claims" do
    projection = invocation()
    server = hd(projection["invocationMcpServers"])
    proof = projection["invocationProof"]
    for invalid <- [Map.put(projection, "actor", "forged"), Map.put(projection, "memoryContextVerified", true),
                    Map.put(projection, :invocationContextKey, "ambiguous"), Map.put(projection, "sharedMemoryGrant", true),
                    Map.put(projection, "sharedMemoryGrant", nil), Map.put(projection, "memoryContextKey", "bad/key"),
                    Map.put(projection, "invocationToolPolicy", nil), Map.put(projection, "invocationToolPolicy", %{"unknown" => true}),
                    Map.put(projection, "invocationToolPolicy", %{"allow" => 4}),
                    Map.put(projection, "invocationToolPolicy", %{"approvals" => %{"read" => "auto"}}),
                    Map.put(projection, "invocationMcpServers", []),
                    Map.put(projection, "invocationMcpServers", [server, server]),
                    Map.put(projection, "invocationMcpServers", [Map.put(server, "command", "stdio")]),
                    Map.put(projection, "invocationMcpServers", [Map.put(server, "headers", %{"Authorization" => "Bearer literal"})]),
                    Map.put(projection, "invocationMcpServers", [Map.put(server, "headers", %{"Host" => "${LEMON_SECRET:private}"})]),
                    Map.put(projection, "invocationMcpServers", [Map.put(server, "headers", %{"X-Proof" => "${LEMON_SECRET:one}", "x-proof" => "${LEMON_SECRET:two}"})]),
                    Map.put(projection, "invocationMcpServers", [Map.put(server, "url", "https://user:secret@core.example.test/mcp")]),
                    Map.put(projection, "invocationMcpServers", [Map.put(server, "url", "http://core.example.test/mcp")]),
                    Map.put(projection, "invocationProof", Map.put(proof, "runId", "parent-proof")),
                    Map.put(projection, "invocationProof", Map.put(proof, "secretName", "lemon_bot/invocations/parent-proof")),
                    Map.put(projection, "invocationProof", Map.put(proof, "trusted", true))] do
      assert {:error, :admission_unavailable} = NativeFollowupAdmission.validate_invocation(invalid, @run_id)
    end
    for key <- Map.keys(projection) do
      assert {:error, :admission_unavailable} = NativeFollowupAdmission.validate_invocation(Map.delete(projection, key), @run_id)
    end
    assert {:ok, _} = NativeFollowupAdmission.validate_invocation(projection, @run_id)
  end

  test "every MCP URL requires an explicit canonical origin policy even before ceiling validation" do
    projection = invocation()
    server = hd(projection["invocationMcpServers"])
    for invalid_server <- [Map.delete(server, "allowedOrigins"),
                           Map.put(server, "allowedOrigins", []),
                           Map.put(server, "allowedOrigins", ["https://unrelated.example.test"]),
                           Map.put(server, "approvedPrivateOrigins", ["https://unrelated.example.test"])] do
      invalid = Map.put(projection, "invocationMcpServers", [invalid_server])
      assert {:error, :admission_unavailable} = NativeFollowupAdmission.validate_invocation(invalid, @run_id)
    end
    canonical = server |> Map.put("url", "https://CORE.example.test:443/current-mcp")
    candidate = replace_core_server(projection, canonical)
    assert {:ok, _} = NativeFollowupAdmission.validate_invocation(candidate, @run_id)
  end

  test "literal private HTTPS and HTTP reuse canonical private-origin approval without DNS" do
    projection = invocation()
    server = hd(projection["invocationMcpServers"])
    for origin <- ["https://127.0.0.1", "https://[::1]", "http://127.0.0.1:8123", "http://[::1]:8123"] do
      literal = server |> Map.put("url", origin <> "/mcp") |> Map.put("allowedOrigins", [origin])
      assert {:error, :admission_unavailable} =
               NativeFollowupAdmission.validate_invocation(replace_core_server(projection, literal), @run_id)
      approved = Map.put(literal, "approvedPrivateOrigins", [origin])
      assert {:ok, _} = NativeFollowupAdmission.validate_invocation(replace_core_server(projection, approved), @run_id)
    end
  end

  test "current target rotation allows new Core URL and contexts despite old source transport", ctx do
    target_id = ctx.profile_id <> "-rotated"
    assert {:ok, _} = ProfileStore.create(%{"id" => target_id, "mcpServers" => templates()})
    current = hd(invocation()["invocationMcpServers"])
      |> Map.put("url", "https://current-core.example.test/fresh-mcp")
      |> Map.put("allowedOrigins", ["https://current-core.example.test"])
    projection = replace_core_server(invocation(), current)
      |> Map.put("invocationContextKey", "current-target-context-v2")
      |> Map.put("memoryContextKey", "current-target-memory-v2")
    lineage = %{ctx.lineage | target_profile_id: target_id}
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"allow" => true, "invocation" => projection}))
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(ctx.config, lineage, @fixture)
    assert {:ok, _} = ProfileStore.update(target_id, %{"mcpServers" => [Map.put(current, "headers", %{})]})
    assert {:ok, actual} = NativeFollowupAdmission.check(ctx.config, lineage, @fixture)
    assert actual == projection
    assert {:ok, source} = ProfileStore.get_for_execution(ctx.profile_id)
    assert source["mcpServers"] == templates()
  end

  test "real loopback HTTP uses encrypted bearer and exact body", ctx do
    bandit = start_supervised!({Bandit, plug: {HTTPFixture, %{pid: self(), status: 200, body: Jason.encode!(%{"allow" => true, "invocation" => invocation()})}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false})
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    origin = "http://127.0.0.1:#{port}"
    Application.put_env(:lemon_router, :native_followup_allowed_origins, [origin])
    assert {:ok, _} = NativeFollowupAdmission.configure(ctx.profile_id, origin <> "/internal/runtime/followup/admission", @token)
    assert {:ok, config} = NativeFollowupAdmission.fetch_config(ctx.profile_id)
    assert {:ok, _projection} = NativeFollowupAdmission.check(config, ctx.lineage)
    assert_receive {:native_http_request, "POST", "/internal/runtime/followup/admission", headers, body}
    assert {"authorization", "Bearer " <> @token} in headers
    assert Jason.decode!(body) == %{"runId" => @run_id}
    refute_receive {:native_http_request, _, _, _, _}, 50
  end

  test "real HTTP redirects and failures never retry or follow another destination", ctx do
    for status <- [302, 503] do
      id = {:http_fixture, status}
      bandit = start_supervised!(Supervisor.child_spec({Bandit, plug: {HTTPFixture, %{pid: self(), status: status, body: @token, headers: [{"location", "/must-not-follow"}]}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}, id: id))
      assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
      origin = "http://127.0.0.1:#{port}"
      Application.put_env(:lemon_router, :native_followup_allowed_origins, [origin])
      assert {:ok, _} = NativeFollowupAdmission.configure(ctx.profile_id, origin <> "/check", @token)
      assert {:ok, config} = NativeFollowupAdmission.fetch_config(ctx.profile_id)
      assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(config, ctx.lineage)
      assert_receive {:native_http_request, "POST", "/check", _, _}
      refute_receive {:native_http_request, _, _, _, _}, 100
    end
  end

  test "missing and empty current target templates fail closed without inheritance", ctx do
    Req.Test.stub(__MODULE__, fn _ -> flunk("empty or malformed target ceiling called issuer") end)
    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"mcpServers" => []})
    assert {:ok, target, version} = NativeFollowupAdmission.capture_target(ctx.profile_id)
    assert target["mcpServers"] == []
    assert :ok = NativeFollowupAdmission.ensure_current_target(ctx.profile_id, version)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.validate_invocation(invocation(), @run_id, target)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(ctx.config, ctx.lineage, @fixture)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.capture_target("missing-target")
    legacy = Map.drop(hd(templates()), ["allowedOrigins", "approvedPrivateOrigins"])
    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"mcpServers" => [legacy]})
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.capture_target(ctx.profile_id)
  end

  test "response origin claims and new server identities cannot widen current target templates", ctx do
    projection = invocation()
    core = hd(projection["invocationMcpServers"])
    for server <- [Map.put(core, "name", "new-owner-server"),
                   Map.put(core, "url", "https://core.example.test/different-path"),
                   core |> Map.put("url", "https://attacker.example.test/mcp")
                        |> Map.put("allowedOrigins", ["https://attacker.example.test"]),
                   Map.put(core, "allowedOrigins", ["https://core.example.test", "https://attacker.example.test"]),
                   Map.put(core, "approvedPrivateOrigins", ["https://core.example.test"])] do
      candidate = replace_core_server(projection, server)
      Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"allow" => true, "invocation" => candidate}))
      assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(ctx.config, ctx.lineage, @fixture)
    end
    connector = %{"name" => "static-owner", "url" => "https://owner.example.test/mcp",
                  "allowedOrigins" => ["https://owner.example.test"], "approvedPrivateOrigins" => [],
                  "headers" => %{"Authorization" => "Bearer ${LEMON_SECRET:owner-static}"}}
    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"mcpServers" => [hd(templates()), connector]})
    candidate = Map.put(projection, "invocationMcpServers", [core, connector])
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.validate_invocation(candidate, @run_id, ctx.profile_id)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.capture_target(ctx.profile_id)
  end

  test "canonical URLs match while origin, private-origin and tool sets only narrow", ctx do
    template = hd(templates())
      |> Map.put("allowedOrigins", ["https://core.example.test", "https://extra.example.test"])
      |> Map.put("approvedPrivateOrigins", ["https://extra.example.test"])
      |> Map.put("enabledTools", ["read", "search"])
    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{"mcpServers" => [template]})
    assert {:ok, target, _} = NativeFollowupAdmission.capture_target(ctx.profile_id)
    core = hd(invocation()["invocationMcpServers"])
      |> Map.put("url", "https://CORE.example.test:443/mcp")
      |> Map.put("enabledTools", ["read"])
    projection = replace_core_server(invocation(), core)
    assert {:ok, _} = NativeFollowupAdmission.validate_invocation(projection, @run_id, target)
    for tools <- [nil, ["write"]] do
      server = if is_nil(tools), do: Map.delete(core, "enabledTools"), else: Map.put(core, "enabledTools", tools)
      assert {:error, :admission_unavailable} =
               NativeFollowupAdmission.validate_invocation(replace_core_server(projection, server), @run_id, target)
    end
    assert {:ok, _} = NativeFollowupAdmission.validate_invocation(replace_core_server(projection, Map.put(core, "enabledTools", [])), @run_id, target)
  end

  test "callback uses original source bearer and fences actual target profile template rotation", ctx do
    target_id = ctx.profile_id <> "-target"
    assert {:ok, _} = ProfileStore.create(%{"id" => target_id})
    lineage = %{ctx.lineage | target_profile_id: target_id}
    Req.Test.stub(__MODULE__, fn _ -> flunk("missing target ceiling called issuer") end)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(ctx.config, lineage, @fixture)
    assert {:ok, _} = ProfileStore.update(target_id, %{"mcpServers" => templates()})
    assert {:ok, _target, version} = NativeFollowupAdmission.capture_target(target_id)
    assert :ok = NativeFollowupAdmission.ensure_current_target(target_id, version)
    Req.Test.stub(__MODULE__, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
      Req.Test.json(conn, %{"allow" => true, "invocation" => invocation()})
    end)
    # The target has no private callback configuration: only the original source
    # credential authenticates this callback.
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.fetch_config(target_id)
    assert {:ok, _} = NativeFollowupAdmission.check(ctx.config, lineage, @fixture)
    narrowed = hd(templates()) |> Map.put("enabledTools", ["read"])
    Req.Test.stub(__MODULE__, fn conn ->
      assert {:ok, _} = ProfileStore.update(target_id, %{"mcpServers" => [narrowed]})
      Req.Test.json(conn, %{"allow" => true, "invocation" => invocation()})
    end)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.check(ctx.config, lineage, @fixture)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.ensure_current_target(target_id, version)
    assert {:ok, target, next_version} = NativeFollowupAdmission.capture_target(target_id)
    assert next_version != version
    projection = replace_core_server(invocation(), Map.put(hd(invocation()["invocationMcpServers"]), "enabledTools", ["read"]))
    Req.Test.stub(__MODULE__, &Req.Test.json(&1, %{"allow" => true, "invocation" => projection}))
    assert {:ok, _} = NativeFollowupAdmission.check(ctx.config, lineage, @fixture)
    assert {:ok, _} = ProfileStore.update(target_id, %{"mcpServers" => []})
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.ensure_current_target(target_id, next_version)
    assert {:error, :admission_unavailable} = NativeFollowupAdmission.validate_invocation(projection, @run_id, target)
  end

  defp templates, do: Enum.map(invocation()["invocationMcpServers"], &Map.put(&1, "headers", %{}))

  defp invocation do
    %{"invocationContextKey" => "source-context", "memoryContextKey" => "source-context",
      "invocationToolPolicy" => %{"allow" => ["read"], "deny" => []},
      "invocationMcpServers" => [%{"name" => "lemon-bot", "url" => "https://core.example.test/mcp",
        "allowedOrigins" => ["https://core.example.test"], "approvedPrivateOrigins" => [],
        "headers" => %{"X-Lemon-Bot-Invocation" => "${LEMON_SECRET:lemon_bot/invocations/#{@run_id}}"}}],
      "invocationProof" => %{"runId" => @run_id, "serverName" => "lemon-bot", "serverUrl" => "https://core.example.test/mcp",
        "headerName" => "X-Lemon-Bot-Invocation", "secretName" => "lemon_bot/invocations/" <> @run_id},
      "sharedMemoryGrant" => false}
  end

  defp replace_core_server(projection, server) do
    projection
    |> Map.put("invocationMcpServers", [server])
    |> Map.update!("invocationProof", &Map.merge(&1, %{"serverName" => server["name"], "serverUrl" => server["url"]}))
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
