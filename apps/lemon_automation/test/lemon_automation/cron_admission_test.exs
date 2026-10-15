defmodule LemonAutomation.CronAdmissionTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronAdmission, CronJob, CronRun}
  alias LemonCore.Secrets

  @origin "https://admission.example.test"
  @profile_id "profile-admission"
  @token "private-admission-token"
  @run_id "router-run-admission"
  @fixture_options [plug: {Req.Test, __MODULE__}]

  setup do
    previous_origins = Application.fetch_env(:lemon_automation, :cron_admission_allowed_origins)
    previous_origin_env = System.get_env("LEMON_CRON_ADMISSION_ALLOWED_ORIGINS")
    System.delete_env("LEMON_CRON_ADMISSION_ALLOWED_ORIGINS")
    previous_secrets = Application.fetch_env(:lemon_core, Secrets)
    suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))
    key_env = "LEMON_CRON_ADMISSION_TEST_KEY_" <> suffix
    routine_id = "routine-admission-" <> suffix

    System.put_env(key_env, Base.encode64(:crypto.strong_rand_bytes(32)))
    Application.put_env(:lemon_core, Secrets, key_providers: [:env], env_var: key_env)
    Application.put_env(:lemon_automation, :cron_admission_allowed_origins, [@origin])
    assert {:ok, secret_name} = CronAdmission.set_token(routine_id, @token)

    admission = %{
      url: @origin <> "/cron/check",
      token_secret: secret_name,
      routine_id: routine_id,
      creator_id: "creator-admission",
      workspace_id: "workspace-admission"
    }

    job =
      CronJob.new(%{
        id: "job-admission",
        name: "admission consumer",
        schedule: "* * * * *",
        profile_id: @profile_id,
        agent_id: "agent-admission",
        session_key: "agent:admission:main",
        prompt: "Perform admitted work"
      })
      |> Map.put(:admission, admission)

    run = %CronRun{
      id: "cron-run-admission",
      job_id: job.id,
      run_id: @run_id <> "-" <> suffix,
      status: :pending,
      triggered_by: :schedule,
      meta: %{scheduled_for_ms: 1_800_000_000_000}
    }

    on_exit(fn ->
      Secrets.delete(secret_name)
      restore_env(:lemon_automation, :cron_admission_allowed_origins, previous_origins)

      if is_nil(previous_origin_env),
        do: System.delete_env("LEMON_CRON_ADMISSION_ALLOWED_ORIGINS"),
        else: System.put_env("LEMON_CRON_ADMISSION_ALLOWED_ORIGINS", previous_origin_env)

      restore_env(:lemon_core, Secrets, previous_secrets)
      System.delete_env(key_env)
    end)

    %{admission: admission, job: job, run: run, key_env: key_env, secret_name: secret_name}
  end

  describe "validate/2" do
    test "nil remains no admission without requiring a profile" do
      assert {:ok, nil} = CronAdmission.validate(nil, nil)
    end

    test "atom, string, and mixed keys canonicalize to the same private map", %{
      admission: admission
    } do
      string_keys = Map.new(admission, fn {key, value} -> {Atom.to_string(key), value} end)

      mixed_keys =
        admission |> Map.delete(:routine_id) |> Map.put("routine_id", admission.routine_id)

      for input <- [admission, string_keys, mixed_keys] do
        assert {:ok, ^admission} = CronAdmission.validate(input, @profile_id)
      end
    end

    test "requires a bounded nonempty profile and all five private fields", %{
      admission: admission
    } do
      for profile <- [nil, "", "  ", 12, String.duplicate("x", 257)] do
        assert_invalid(CronAdmission.validate(admission, profile))
      end

      for key <- [:url, :token_secret, :routine_id, :creator_id, :workspace_id] do
        assert_invalid(CronAdmission.validate(Map.delete(admission, key), @profile_id))

        for value <- [nil, "", "  ", 12, <<255>>] do
          assert_invalid(CronAdmission.validate(Map.put(admission, key, value), @profile_id))
        end
      end

      for key <- [:token_secret, :routine_id, :creator_id, :workspace_id] do
        assert_invalid(
          CronAdmission.validate(Map.put(admission, key, String.duplicate("x", 257)), @profile_id)
        )

        assert {:ok, _} =
                 CronAdmission.validate(
                   Map.put(admission, key, String.duplicate("x", 256)),
                   @profile_id
                 )
      end
    end

    test "rejects plaintext tokens, unknown fields, and ambiguous keys", %{admission: admission} do
      for extra <- [
            %{token: @token},
            %{"token" => @token},
            %{enabled: false},
            %{other: "value"},
            %{"url" => admission.url}
          ] do
        assert_invalid(CronAdmission.validate(Map.merge(admission, extra), @profile_id))
      end

      for input <- [false, [], "callback", 12] do
        assert_invalid(CronAdmission.validate(input, @profile_id))
      end
    end

    test "rejects userinfo, fragments, malformed URLs and non-HTTPS remote callbacks", %{
      admission: admission
    } do
      for url <- [
            "http://admission.example.test/check",
            "https://user:password@admission.example.test/check",
            "https://@admission.example.test/check",
            @origin <> "/check#receipt",
            @origin <> "/check#",
            @origin <> "/check?token=private",
            @origin <> "/check?",
            @origin <> "/check with spaces",
            @origin <> "/check\r\n",
            @origin <> "/%xx",
            @origin <> ":/check",
            "HTTPS://admission.example.test:/check",
            "https://admission.example.test:",
            @origin <> ":99999/check",
            "https://admission.example.test\\@evil.example/check",
            "https:///check",
            "/relative/check",
            @origin <> "/" <> String.duplicate("x", 2048)
          ] do
        assert_invalid(CronAdmission.validate(%{admission | url: url}, @profile_id))
      end
    end

    test "accepts a permitted HTTPS callback with omitted or explicit default port", %{
      admission: admission
    } do
      for url <- [@origin <> "/cron/check", @origin <> ":443/cron/check"] do
        configured = %{admission | url: url}
        assert {:ok, ^configured} = CronAdmission.validate(configured, @profile_id)
      end
    end

    test "allows only exact origins, not subdomains, suffixes or other ports", %{
      admission: admission
    } do
      for url <- [
            "https://sub.admission.example.test/check",
            "https://admission.example.test.evil.test/check",
            "https://admission.example.test:8443/check"
          ] do
        assert_invalid(CronAdmission.validate(%{admission | url: url}, @profile_id))
      end

      assert {:ok, _} =
               CronAdmission.validate(%{admission | url: @origin <> ":443/check"}, @profile_id)

      Application.put_env(:lemon_automation, :cron_admission_allowed_origins, [@origin <> ":8443"])

      assert {:ok, _} =
               CronAdmission.validate(%{admission | url: @origin <> ":8443/check"}, @profile_id)

      assert_invalid(CronAdmission.validate(admission, @profile_id))
    end

    test "empty, malformed and non-origin allowlists fail closed", %{admission: admission} do
      for origins <- [
            [],
            nil,
            @origin,
            [@origin <> "/"],
            [@origin <> "/path"],
            [@origin <> "?query"],
            [@origin <> "#fragment"],
            ["https://*.example.test"]
          ] do
        Application.put_env(:lemon_automation, :cron_admission_allowed_origins, origins)
        assert_invalid(CronAdmission.validate(admission, @profile_id))
      end
    end

    test "operator environment takes precedence and explicit emptiness disables trust", %{
      admission: admission
    } do
      Application.put_env(:lemon_automation, :cron_admission_allowed_origins, [
        "https://different.example.test"
      ])

      System.put_env(
        "LEMON_CRON_ADMISSION_ALLOWED_ORIGINS",
        " https://other.example.test, " <> @origin <> " "
      )

      assert {:ok, _} = CronAdmission.validate(admission, @profile_id)

      Application.put_env(:lemon_automation, :cron_admission_allowed_origins, [@origin])

      for value <- ["", "   ", ",,,", "https://different.example.test", @origin <> "/path"] do
        System.put_env("LEMON_CRON_ADMISSION_ALLOWED_ORIGINS", value)
        assert_invalid(CronAdmission.validate(admission, @profile_id))
      end
    end

    test "HTTP is allowed only for explicitly allowlisted literal loopback IP origins", %{
      admission: admission
    } do
      for origin <- ["http://127.0.0.1:8123", "http://[::1]:8123"] do
        Application.put_env(:lemon_automation, :cron_admission_allowed_origins, [origin])

        assert {:ok, _} =
                 CronAdmission.validate(%{admission | url: origin <> "/check"}, @profile_id)

        assert_invalid(
          CronAdmission.validate(
            %{admission | url: String.replace(origin, ":8123", ":8124") <> "/check"},
            @profile_id
          )
        )
      end

      for origin <- [
            "http://localhost:8123",
            "http://127.0.0.2:8123",
            "http://127.1:8123",
            "http://2130706433:8123",
            "http://[0:0:0:0:0:0:0:1]:8123",
            "http://[::ffff:127.0.0.1]:8123",
            "http://10.0.0.1:8123",
            "http://admission.example.test"
          ] do
        Application.put_env(:lemon_automation, :cron_admission_allowed_origins, [origin])

        assert_invalid(
          CronAdmission.validate(%{admission | url: origin <> "/check"}, @profile_id)
        )
      end

      Application.put_env(:lemon_automation, :cron_admission_allowed_origins, [])

      assert_invalid(
        CronAdmission.validate(%{admission | url: "http://127.0.0.1:8123/check"}, @profile_id)
      )
    end
  end

  describe "validate_invocation/2" do
    test "normalizes the complete private wire object without resolving secrets" do
      assert {:ok, projection} = CronAdmission.validate_invocation(invocation(), @run_id)
      assert projection == canonical_invocation()
    end

    test "requires all six exact string keys and their supported types" do
      input = invocation()

      for invalid <- [
            nil,
            [],
            false,
            Map.put(input, "unexpected", true),
            Map.put(input, :invocationContextKey, "ambiguous"),
            Map.take(input, ~w(invocationContextKey invocationMcpServers invocationToolPolicy)),
            %{context_key: "context", mcp_servers: [], tool_policy: %{}}
          ] do
        assert {:error, :admission_unavailable} =
                 CronAdmission.validate_invocation(invalid, @run_id)
      end

      for key <- Map.keys(input), value <- [nil, 123, "wrong-type", false, true] do
        if not (key in ["invocationContextKey", "memoryContextKey"] and value == "wrong-type") and
             not (key == "sharedMemoryGrant" and value == false) do
          assert {:error, :admission_unavailable} =
                   CronAdmission.validate_invocation(Map.put(input, key, value), @run_id)
        end
      end

      for key <- Map.keys(input) do
        assert {:error, :admission_unavailable} =
                 CronAdmission.validate_invocation(Map.delete(input, key), @run_id)
      end
    end

    test "uses bounded ASCII invocation and memory identities" do
      for field <- ["invocationContextKey", "memoryContextKey"] do
        for key <- ["a", "A0_.:-context", String.duplicate("x", 128)] do
          assert {:ok, projection} =
                   CronAdmission.validate_invocation(Map.put(invocation(), field, key), @run_id)

          canonical_field = if field == "memoryContextKey", do: :memory_key, else: :context_key
          assert projection[canonical_field] == key
        end

        for key <- [
              nil,
              "",
              " space",
              "_start",
              "a/b",
              "a\n",
              "é",
              <<255>>,
              123,
              String.duplicate("x", 129)
            ] do
          assert {:error, :admission_unavailable} =
                   CronAdmission.validate_invocation(Map.put(invocation(), field, key), @run_id)
        end
      end
    end

    test "an empty replacement cannot bind a proof while sparse empty policy stays explicit" do
      input = Map.put(invocation(), "invocationToolPolicy", %{})
      assert {:ok, %{tool_policy: %{}}} = CronAdmission.validate_invocation(input, @run_id)

      assert {:error, :admission_unavailable} =
               CronAdmission.validate_invocation(
                 Map.put(input, "invocationMcpServers", []),
                 @run_id
               )
    end

    test "fresh proof validation rejects stale or foreign authority before any transport" do
      stub_no_dispatch()
      input = invocation()

      for invalid <- invalid_bound_invocations(input) do
        assert {:error, :admission_unavailable} =
                 CronAdmission.validate_invocation(invalid, @run_id)
      end

      for fixed_run_id <- [nil, "", "invalid run", "foreign-run", String.duplicate("x", 129)] do
        assert {:error, :admission_unavailable} =
                 CronAdmission.validate_invocation(input, fixed_run_id)
      end

      refute_received :unexpected_dispatch
    end

    test "rejects unknown server fields, duplicate names, and malformed native configuration" do
      server = hd(invocation()["invocationMcpServers"])

      for servers <- [
            [Map.put(server, "command", "stdio")],
            [Map.put(server, :name, "ambiguous")],
            [Map.delete(server, "name")],
            [Map.delete(server, "url")],
            [Map.put(server, "headers", nil)],
            [Map.put(server, "enabledTools", ["query", "query"])],
            [Map.put(server, "approvedPrivateOrigins", ["https://unapproved.example.test"])],
            [server, server],
            List.duplicate(server, 33),
            [nil],
            %{}
          ] do
        assert {:error, :admission_unavailable} =
                 CronAdmission.validate_invocation(
                   Map.put(invocation(), "invocationMcpServers", servers),
                   @run_id
                 )
      end
    end

    test "rejects credential-bearing and malformed MCP URLs" do
      server = hd(invocation()["invocationMcpServers"])

      for url <- [
            "http://mcp.example.test/mcp",
            "https://user:credential@mcp.example.test/mcp",
            "https://@mcp.example.test/mcp",
            "https://mcp.example.test/mcp?token=literal",
            "https://mcp.example.test/mcp?",
            "https://mcp.example.test/mcp#literal",
            "https://mcp.example.test:/mcp",
            "https://mcp.example.test:99999/mcp",
            "https://mcp.example.test/mcp\\evil",
            "https://mcp.example.test/%xx",
            "https://mcp.example.test/${LEMON_SECRET:credential}",
            "/relative/mcp"
          ] do
        assert {:error, :admission_unavailable} =
                 CronAdmission.validate_invocation(
                   Map.put(invocation(), "invocationMcpServers", [Map.put(server, "url", url)]),
                   @run_id
                 )
      end
    end

    test "literal, environment, malformed, and mixed credential headers fail closed" do
      server = hd(invocation()["invocationMcpServers"])

      for value <- [
            "literal-credential",
            "Bearer literal-credential",
            "${ENV_TOKEN}",
            "${LEMON_SECRET:}",
            "${LEMON_SECRET: missing}",
            "${LEMON_SECRET:missing }",
            "${LEMON_SECRET:missing",
            "${LEMON_SECRET:missing}\r\n",
            "${LEMON_SECRET:missing}suffix",
            "prefix${LEMON_SECRET:missing}",
            "Bearer ${LEMON_SECRET:missing} literal",
            "${LEMON_SECRET:" <> String.duplicate("x", 513) <> "}",
            nil
          ] do
        headers = Map.put(server["headers"], "Authorization", value)

        assert {:error, :admission_unavailable} =
                 CronAdmission.validate_invocation(
                   Map.put(invocation(), "invocationMcpServers", [
                     Map.put(server, "headers", headers)
                   ]),
                   @run_id
                 )
      end
    end

    test "unsupported policy fields and values are not silently ignored" do
      for policy <- [
            nil,
            [],
            %{"unknown" => true},
            %{"profile" => "unsupported"},
            %{"allow" => "none"},
            %{"deny" => nil},
            %{"blocked_tools" => [123]},
            %{"require_approval" => true},
            %{"approvals" => %{"query" => "ask"}},
            %{"no_reply" => "false"}
          ] do
        assert {:error, :admission_unavailable} =
                 CronAdmission.validate_invocation(
                   Map.put(invocation(), "invocationToolPolicy", policy),
                   @run_id
                 )
      end
    end

    test "transport headers and case-folded duplicates cannot override destination authority" do
      server = hd(invocation()["invocationMcpServers"])

      for headers <- [
            %{"Host" => "${LEMON_SECRET:missing}"},
            %{"Content-Length" => "${LEMON_SECRET:missing}"},
            %{"Connection" => "${LEMON_SECRET:missing}"},
            %{"Transfer-Encoding" => "${LEMON_SECRET:missing}"},
            %{"Upgrade" => "${LEMON_SECRET:missing}"},
            %{"Proxy-Authorization" => "${LEMON_SECRET:missing}"},
            %{"Mcp-Session-Id" => "${LEMON_SECRET:missing}"},
            %{
              "Authorization" => "${LEMON_SECRET:missing}",
              "authorization" => "${LEMON_SECRET:other}"
            },
            %{"X-Key" => "Bearer ${LEMON_SECRET:missing}"},
            %{"invalid name" => "${LEMON_SECRET:missing}"}
          ] do
        assert {:error, :admission_unavailable} =
                 CronAdmission.validate_invocation(
                   Map.put(invocation(), "invocationMcpServers", [
                     Map.put(server, "headers", Map.merge(server["headers"], headers))
                   ]),
                   @run_id
                 )
      end

      headers =
        Map.merge(server["headers"], %{
          "Cookie" => "${LEMON_SECRET:missing}",
          "authorization" => "${LEMON_SECRET:missing}"
        })

      assert {:ok, _} =
               CronAdmission.validate_invocation(
                 Map.put(invocation(), "invocationMcpServers", [
                   Map.put(server, "headers", headers)
                 ]),
                 @run_id
               )
    end

    test "literal-loopback HTTP creator bridges require both exact origin approvals", %{
      job: job,
      run: run
    } do
      [core, server] = invocation(run.run_id)["invocationMcpServers"]

      for origin <- ["http://127.0.0.1:8123", "http://[::1]:8123"] do
        bridge =
          server
          |> Map.put("url", origin <> "/mcp")
          |> Map.put("allowedOrigins", [origin <> "/"])
          |> Map.put("approvedPrivateOrigins", [origin])

        input = Map.put(invocation(run.run_id), "invocationMcpServers", [core, bridge])

        expected = %{
          canonical_invocation(run.run_id)
          | mcp_servers: [core, Map.put(bridge, "allowedOrigins", [origin])]
        }

        assert {:ok, ^expected} = CronAdmission.validate_invocation(input, run.run_id)

        Req.Test.stub(__MODULE__, fn conn ->
          {context, conn} = read_context(conn)
          Req.Test.json(conn, %{"allow" => true, "context" => context, "invocation" => input})
        end)

        assert {:ok, ^expected} = CronAdmission.check(job, run, @fixture_options)

        for invalid <- [
              Map.delete(bridge, "allowedOrigins"),
              Map.delete(bridge, "approvedPrivateOrigins"),
              Map.put(bridge, "approvedPrivateOrigins", []),
              Map.put(bridge, "allowedOrigins", [origin <> "0"]),
              Map.put(bridge, "url", String.replace(bridge["url"], ":8123", ":8124"))
            ] do
          assert {:error, :admission_unavailable} =
                   CronAdmission.validate_invocation(
                     Map.put(input, "invocationMcpServers", [core, invalid]),
                     run.run_id
                   )
        end
      end

      for origin <- [
            "http://localhost:8123",
            "http://127.0.0.2:8123",
            "http://127.1:8123",
            "http://[0:0:0:0:0:0:0:1]:8123",
            "http://[::ffff:127.0.0.1]:8123",
            "http://mcp.example.test:8123"
          ] do
        bridge =
          server
          |> Map.put("url", origin <> "/mcp")
          |> Map.put("allowedOrigins", [origin])
          |> Map.put("approvedPrivateOrigins", [origin])

        assert {:error, :admission_unavailable} =
                 CronAdmission.validate_invocation(
                   Map.put(invocation(run.run_id), "invocationMcpServers", [core, bridge]),
                   run.run_id
                 )
      end
    end

    test "native policy preset and all-allow retain sparse canonical values" do
      policy = %{"profile" => "full_access", "allow" => "all"}

      assert {:ok, %{tool_policy: ^policy}} =
               CronAdmission.validate_invocation(
                 Map.put(invocation(), "invocationToolPolicy", policy),
                 @run_id
               )
    end
  end

  describe "check/2 and check/3" do
    test "no admission performs no callback even with missing profile or a command", %{
      job: job,
      run: run
    } do
      stub_no_dispatch()
      job = %{job | admission: nil, profile_id: nil, command: "echo local"}
      assert :ok = CronAdmission.check(job, run)
      assert :ok = CronAdmission.check(job, run, @fixture_options)
      refute_received :unexpected_dispatch
    end

    test "posts private bearer auth and exact bound context before allowing", %{
      job: job,
      run: run
    } do
      expected = expected_context(job, run)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.scheme == :https
        assert conn.host == "admission.example.test"
        assert conn.request_path == "/cron/check"
        assert conn.query_string == ""
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
        {context, conn} = read_context(conn)
        assert context === expected
        Req.Test.json(conn, %{"allow" => true, "context" => context})
      end)

      assert :ok = CronAdmission.check(job, run, @fixture_options)
    end

    test "blank command fields keep agent-job admission semantics", %{job: job, run: run} do
      stub_receipt(true)

      for command <- ["", "  "] do
        assert :ok = CronAdmission.check(%{job | command: command}, run, @fixture_options)
      end
    end

    test "matching false receipt is denied, never admitted", %{job: job, run: run} do
      stub_receipt(false)
      assert {:error, :denied} = CronAdmission.check(job, run, @fixture_options)
    end

    test "approved fresh slot returns canonical core proof, creator refs and native memory key",
         %{job: job, run: run} do
      expected = canonical_invocation(run.run_id)

      Req.Test.stub(__MODULE__, fn conn ->
        {context, conn} = read_context(conn)
        assert context === expected_context(job, run)

        Req.Test.json(conn, %{
          "allow" => true,
          "context" => context,
          "invocation" => invocation(context["routerRunId"])
        })
      end)

      assert {:ok, ^expected} = CronAdmission.check(job, run, @fixture_options)
      assert expected.memory_key == "creator-memory:epoch.1"
      assert expected.shared_memory_grant == false
      assert expected.proof["runId"] == run.run_id
      [core, creator] = expected.mcp_servers

      assert core["headers"]["X-Lemon-Bot-Invocation"] ==
               "${LEMON_SECRET:lemon_bot/invocations/#{run.run_id}}"

      assert creator["headers"]["Authorization"] ==
               "Bearer ${LEMON_SECRET:cron-projection-missing-token}"
    end

    test "approved empty MCP replacement is unavailable without a bindable proof", %{
      job: job,
      run: run
    } do
      input = Map.put(invocation(run.run_id), "invocationMcpServers", [])

      Req.Test.stub(__MODULE__, fn conn ->
        {context, conn} = read_context(conn)
        Req.Test.json(conn, %{"allow" => true, "context" => context, "invocation" => input})
      end)

      assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
    end

    test "a previous slot's otherwise valid proof cannot approve the fresh slot", %{
      job: job,
      run: run
    } do
      stale = invocation(run.run_id <> "-previous-slot")

      Req.Test.stub(__MODULE__, fn conn ->
        {context, conn} = read_context(conn)
        assert context["routerRunId"] == run.run_id
        Req.Test.json(conn, %{"allow" => true, "context" => context, "invocation" => stale})
      end)

      assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
    end

    test "invalid run-bound proof, memory, grants and callback attestation flags fail closed", %{
      job: job,
      run: run
    } do
      for invalid <- invalid_bound_invocations(invocation(run.run_id)) do
        Req.Test.stub(__MODULE__, fn conn ->
          {context, conn} = read_context(conn)
          Req.Test.json(conn, %{"allow" => true, "context" => context, "invocation" => invalid})
        end)

        assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
      end
    end

    test "receipt-level metadata cannot attest otherwise valid execution context", %{
      job: job,
      run: run
    } do
      for field <- [
            "meta",
            "memory_context_verified",
            "invocation_proof_verified",
            "shared_memory_grant"
          ] do
        Req.Test.stub(__MODULE__, fn conn ->
          {context, conn} = read_context(conn)

          receipt = %{
            "allow" => true,
            "context" => context,
            "invocation" => invocation(context["routerRunId"]),
            field => true
          }

          Req.Test.json(conn, receipt)
        end)

        assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
      end
    end

    test "projection never weakens exact binding or denied receipt shape", %{job: job, run: run} do
      for allow <- [true, false], mismatch <- [true, false], extra <- [true, false] do
        if not allow or mismatch or extra do
          Req.Test.stub(__MODULE__, fn conn ->
            {context, conn} = read_context(conn)

            context =
              if mismatch, do: Map.put(context, "creatorId", "other-creator"), else: context

            receipt = %{
              "allow" => allow,
              "context" => context,
              "invocation" => invocation(run.run_id)
            }

            receipt = if extra, do: Map.put(receipt, "unexpected", true), else: receipt
            Req.Test.json(conn, receipt)
          end)

          assert {:error, :admission_unavailable} =
                   CronAdmission.check(job, run, @fixture_options)
        end
      end
    end

    test "invalid approved projections and any denied projection are unavailable", %{
      job: job,
      run: run
    } do
      input = invocation(run.run_id)
      server = hd(input["invocationMcpServers"])

      literal_server =
        Map.put(server, "headers", %{"Authorization" => "Bearer literal-credential"})

      for input <- [
            nil,
            %{},
            Map.delete(input, "invocationToolPolicy"),
            Map.put(input, "unexpected", true),
            Map.put(input, "invocationContextKey", "invalid key"),
            Map.put(input, "invocationToolPolicy", %{"unsupported" => true}),
            Map.put(input, "invocationMcpServers", [literal_server])
          ],
          allow <- [true, false] do
        Req.Test.stub(__MODULE__, fn conn ->
          {context, conn} = read_context(conn)
          Req.Test.json(conn, %{"allow" => allow, "context" => context, "invocation" => input})
        end)

        assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
      end
    end

    test "job and run metadata cannot supply a trusted projection", %{job: job, run: run} do
      stub_receipt(true)

      job = %{
        job
        | meta: %{
            "invocation" => invocation(run.run_id),
            "memory_context_verified" => true,
            "invocation_proof_verified" => true
          }
      }

      run = %{
        run
        | meta: %{
            invocation: invocation(run.run_id),
            memory_context_verified: true,
            invocation_proof_verified: true
          }
      }

      assert :ok = CronAdmission.check(job, run, @fixture_options)
    end

    test "all trigger kinds, including disabled manual jobs, bind exact invocation context", %{
      job: job,
      run: run
    } do
      for trigger <- [:schedule, :manual, :wake, :retry] do
        current_run = %{run | triggered_by: trigger}
        expected = expected_context(job, current_run)

        Req.Test.stub(__MODULE__, fn conn ->
          {context, conn} = read_context(conn)
          assert context === expected
          Req.Test.json(conn, %{"allow" => true, "context" => context})
        end)

        assert :ok = CronAdmission.check(%{job | enabled: false}, current_run, @fixture_options)
      end
    end

    test "scheduled time binds atom/string metadata and explicit nil", %{job: job, run: run} do
      for meta <- [%{scheduled_for_ms: 123}, %{"scheduled_for_ms" => 123}, %{}, nil] do
        current_run = %{run | meta: meta}
        expected = expected_context(job, current_run)

        Req.Test.stub(__MODULE__, fn conn ->
          {context, conn} = read_context(conn)
          assert context === expected
          Req.Test.json(conn, %{"allow" => true, "context" => context})
        end)

        assert :ok = CronAdmission.check(job, current_run, @fixture_options)
      end
    end

    test "any mismatched context field makes true and false receipts unavailable", %{
      job: job,
      run: run
    } do
      for key <- Map.keys(expected_context(job, run)), allow <- [true, false] do
        Req.Test.stub(__MODULE__, fn conn ->
          {context, conn} = read_context(conn)

          Req.Test.json(conn, %{
            "allow" => allow,
            "context" => Map.put(context, key, "mismatched")
          })
        end)

        assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
      end
    end

    test "missing, extra and numerically altered echo keys are unavailable", %{job: job, run: run} do
      for transform <- [
            &Map.delete(&1, "routerRunId"),
            &Map.put(&1, "unexpected", true),
            &Map.put(&1, "scheduledForMs", &1["scheduledForMs"] / 1),
            fn _ -> nil end
          ] do
        Req.Test.stub(__MODULE__, fn conn ->
          {context, conn} = read_context(conn)
          Req.Test.json(conn, %{"allow" => true, "context" => transform.(context)})
        end)

        assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
      end
    end

    test "malformed receipt shapes and invalid JSON are unavailable", %{job: job, run: run} do
      context = expected_context(job, run)

      for receipt <- [
            %{"context" => context},
            %{"allow" => true},
            %{"allow" => "true", "context" => context},
            %{"allow" => 1, "context" => context},
            %{"allow" => nil, "context" => context},
            %{"allow" => true, "context" => context, "extra" => true},
            [true, context],
            nil
          ] do
        Req.Test.stub(__MODULE__, &Req.Test.json(&1, receipt))
        assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
      end

      for body <- ["", "not JSON", "{\"allow\":true", "<html>error</html>"] do
        Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))
        assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
      end
    end

    test "non-200 responses remain unavailable even with an otherwise admitting receipt", %{
      job: job,
      run: run
    } do
      for status <- [201, 204, 400, 401, 403, 429, 500, 503] do
        Req.Test.stub(__MODULE__, fn conn ->
          {context, conn} = read_context(conn)

          conn
          |> Plug.Conn.put_status(status)
          |> Req.Test.json(%{"allow" => true, "context" => context})
        end)

        assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
      end
    end

    test "redirect responses never follow a second request with the bearer token", %{
      job: job,
      run: run
    } do
      for status <- [301, 302, 303, 307, 308] do
        Req.Test.stub(__MODULE__, fn conn ->
          send(self(), :redirect_request)
          {context, conn} = read_context(conn)
          assert conn.host == "admission.example.test"

          conn
          |> Plug.Conn.put_resp_header("location", "https://redirect.example.test/stolen")
          |> Plug.Conn.put_status(status)
          |> Req.Test.json(%{"allow" => true, "context" => context})
        end)

        assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
        assert_received :redirect_request
        refute_received :redirect_request
      end
    end

    test "timeout and disconnect return unavailable without retry", %{job: job, run: run} do
      for reason <- [:timeout, :closed, :econnrefused] do
        Req.Test.stub(__MODULE__, fn conn ->
          send(self(), :transport_request)
          Req.Test.transport_error(conn, reason)
        end)

        assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
        assert_received :transport_request
        refute_received :transport_request
      end
    end

    test "oversized otherwise-valid receipts are unavailable", %{job: job, run: run} do
      body = Jason.encode!(%{"allow" => true, "context" => expected_context(job, run)})

      Req.Test.stub(
        __MODULE__,
        &Plug.Conn.send_resp(&1, 200, body <> String.duplicate(" ", 16_384))
      )

      assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
    end

    test "a receipt at the response byte bound is admitted", %{job: job, run: run} do
      body = Jason.encode!(%{"allow" => true, "context" => expected_context(job, run)})
      bounded_body = body <> String.duplicate(" ", 16_384 - byte_size(body))
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, bounded_body))
      assert :ok = CronAdmission.check(job, run, @fixture_options)
    end

    test "operator environment is rechecked on dispatch and can revoke app-configured trust", %{
      job: job,
      run: run
    } do
      stub_receipt(true)
      System.put_env("LEMON_CRON_ADMISSION_ALLOWED_ORIGINS", @origin)
      assert :ok = CronAdmission.check(job, run, @fixture_options)

      stub_no_dispatch()
      System.put_env("LEMON_CRON_ADMISSION_ALLOWED_ORIGINS", "")
      assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
      refute_received :unexpected_dispatch
    end

    test "allowlist removal and changed origins prevent HTTP dispatch", %{job: job, run: run} do
      stub_no_dispatch()

      for origins <- [[], ["https://another.example.test"], ["http://admission.example.test"]] do
        Application.put_env(:lemon_automation, :cron_admission_allowed_origins, origins)
        assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
      end

      refute_received :unexpected_dispatch
    end

    test "plaintext HTTP off loopback cannot receive a token even when configured", %{
      job: job,
      run: run
    } do
      stub_no_dispatch()

      for origin <- [
            "http://admission.example.test",
            "http://localhost:8123",
            "http://127.0.0.2:8123",
            "http://10.0.0.1:8123"
          ] do
        Application.put_env(:lemon_automation, :cron_admission_allowed_origins, [origin])
        current_job = %{job | admission: %{job.admission | url: origin <> "/check"}}

        assert {:error, :admission_unavailable} =
                 CronAdmission.check(current_job, run, @fixture_options)
      end

      refute_received :unexpected_dispatch
    end

    test "allowlisted literal loopback HTTP transports exact receipts", %{job: job, run: run} do
      for {origin, host} <- [{"http://127.0.0.1:8123", "127.0.0.1"}, {"http://[::1]:8123", "::1"}] do
        Application.put_env(:lemon_automation, :cron_admission_allowed_origins, [origin])
        current_job = %{job | admission: %{job.admission | url: origin <> "/check"}}

        Req.Test.stub(__MODULE__, fn conn ->
          assert conn.scheme == :http
          assert conn.host == host
          assert conn.port == 8123
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> @token]
          {context, conn} = read_context(conn)
          Req.Test.json(conn, %{"allow" => true, "context" => context})
        end)

        assert :ok = CronAdmission.check(current_job, run, @fixture_options)
      end
    end

    test "command jobs, absent profiles, and malformed admission do not dispatch", %{
      job: job,
      run: run
    } do
      stub_no_dispatch()

      for current_job <- [
            %{job | command: "echo forbidden"},
            %{job | profile_id: nil},
            %{job | admission: %{token: @token}}
          ] do
        assert {:error, :admission_unavailable} =
                 CronAdmission.check(current_job, run, @fixture_options)
      end

      refute_received :unexpected_dispatch
    end

    test "missing encrypted token never falls back to an environment token", %{job: job, run: run} do
      missing_name =
        "CRON_ADMISSION_ENV_ONLY_" <> Integer.to_string(System.unique_integer([:positive]))

      System.put_env(missing_name, @token)
      on_exit(fn -> System.delete_env(missing_name) end)
      stub_no_dispatch()
      job = %{job | admission: %{job.admission | token_secret: missing_name}}
      assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
      refute_received :unexpected_dispatch
    end

    test "undecryptable token is unavailable", %{job: job, run: run, key_env: key_env} do
      System.put_env(key_env, Base.encode64(:crypto.strong_rand_bytes(32)))
      stub_no_dispatch()
      assert {:error, :admission_unavailable} = CronAdmission.check(job, run, @fixture_options)
      refute_received :unexpected_dispatch
    end

    test "fixture options cannot weaken request policy", %{job: job, run: run} do
      stub_no_dispatch()

      for option <- [
            redirect: true,
            retry: true,
            receive_timeout: :infinity,
            connect_options: [transport_opts: [verify: :verify_none]]
          ] do
        assert {:error, :admission_unavailable} =
                 CronAdmission.check(job, run, @fixture_options ++ [option])
      end

      refute_received :unexpected_dispatch
    end
  end

  describe "set_token/2" do
    test "returns a stable hashed name and replaces only that routine's encrypted token", %{
      admission: admission,
      secret_name: secret_name
    } do
      expected =
        "cron_admission_" <>
          Base.encode16(:crypto.hash(:sha256, admission.routine_id), case: :lower)

      assert secret_name == expected
      assert {:ok, @token} = Secrets.get(secret_name)

      assert {:ok, ^secret_name} =
               CronAdmission.set_token(admission.routine_id, "replacement-private-token")

      assert {:ok, "replacement-private-token"} = Secrets.get(secret_name)

      other_routine = admission.routine_id <> "-other"
      assert {:ok, other_name} = CronAdmission.set_token(other_routine, "other-private-token")
      on_exit(fn -> Secrets.delete(other_name) end)
      refute other_name == secret_name
      assert {:ok, "other-private-token"} = Secrets.get(other_name)
      assert {:ok, "replacement-private-token"} = Secrets.get(secret_name)
    end

    test "rejects invalid routine IDs and tokens without replacing the current secret", %{
      admission: admission,
      secret_name: secret_name
    } do
      for routine <- [nil, "", "  ", 12, String.duplicate("x", 257), <<255>>] do
        assert {:error, :invalid_request} = CronAdmission.set_token(routine, @token)
      end

      for token <- [
            nil,
            "",
            "  ",
            12,
            String.duplicate("x", 4097),
            "bad\rtoken",
            "bad\ntoken",
            <<255>>
          ] do
        assert {:error, :invalid_request} = CronAdmission.set_token(admission.routine_id, token)
      end

      assert {:ok, @token} = Secrets.get(secret_name)
    end

    test "accepts maximum bounded token length", %{admission: admission, secret_name: secret_name} do
      token = String.duplicate("x", 4096)
      assert {:ok, ^secret_name} = CronAdmission.set_token(admission.routine_id, token)
      assert {:ok, ^token} = Secrets.get(secret_name)
    end

    test "accepts a maximum bounded routine ID" do
      routine_id = String.duplicate("r", 256)
      assert {:ok, secret_name} = CronAdmission.set_token(routine_id, @token)
      on_exit(fn -> Secrets.delete(secret_name) end)
      assert {:ok, @token} = Secrets.get(secret_name)
    end

    test "secret-store failure is a bounded private classification", %{admission: admission} do
      Application.put_env(:lemon_core, Secrets, key_providers: [])
      assert {:error, :secret_unavailable} = CronAdmission.set_token(admission.routine_id, @token)
    end
  end

  defp invocation(run_id \\ @run_id) do
    %{
      "invocationContextKey" => "creator-context:epoch.1",
      "memoryContextKey" => "creator-memory:epoch.1",
      "sharedMemoryGrant" => false,
      "invocationProof" => %{
        "runId" => run_id,
        "serverName" => "core-mcp",
        "serverUrl" => "https://core.example.test/mcp",
        "headerName" => "X-Lemon-Bot-Invocation",
        "secretName" => "lemon_bot/invocations/" <> run_id
      },
      "invocationMcpServers" => [
        %{
          "name" => "core-mcp",
          "url" => "https://core.example.test/mcp",
          "headers" => %{
            "X-Lemon-Bot-Invocation" => "${LEMON_SECRET:lemon_bot/invocations/#{run_id}}"
          }
        },
        %{
          "name" => "creator-mcp",
          "url" => "https://mcp.example.test/mcp",
          "headers" => %{
            "Authorization" => "Bearer ${LEMON_SECRET:cron-projection-missing-token}",
            "X-Workspace-Key" => "${LEMON_SECRET:cron-projection-missing-workspace}"
          },
          "enabledTools" => ["query"],
          "allowedOrigins" => ["https://MCP.EXAMPLE.TEST:443/"],
          "approvedPrivateOrigins" => []
        }
      ],
      "invocationToolPolicy" => %{
        "allow" => ["query", "query"],
        "deny" => ["write"],
        "blocked_tools" => ["shell"],
        "require_approval" => ["query"],
        "approvals" => %{"query" => "always", "read" => "never"},
        "no_reply" => false
      }
    }
  end

  defp canonical_invocation(run_id \\ @run_id) do
    input = invocation(run_id)
    [core, creator] = input["invocationMcpServers"]

    %{
      context_key: input["invocationContextKey"],
      memory_key: input["memoryContextKey"],
      mcp_servers: [core, Map.put(creator, "allowedOrigins", ["https://mcp.example.test"])],
      tool_policy: Map.put(input["invocationToolPolicy"], "allow", ["query"]),
      proof: input["invocationProof"],
      shared_memory_grant: false
    }
  end

  defp invalid_bound_invocations(input) do
    proof = input["invocationProof"]
    [core, creator] = input["invocationMcpServers"]
    header = proof["headerName"]
    reference = core["headers"][header]
    foreign_secret = "lemon_bot/invocations/foreign-run"
    wrong_namespace = "other/invocations/" <> proof["runId"]

    invalid_proofs = [
      nil,
      %{},
      proof |> Map.delete("runId") |> Map.put(:run_id, proof["runId"]),
      Map.put(proof, "unexpected", true),
      Map.put(proof, "runId", "foreign-run"),
      Map.put(proof, "serverName", creator["name"]),
      Map.put(proof, "serverName", "unselected-core"),
      Map.put(proof, "serverUrl", creator["url"]),
      Map.put(proof, "serverUrl", "https://foreign.example.test/mcp"),
      Map.put(proof, "headerName", String.downcase(header)),
      Map.put(proof, "secretName", foreign_secret),
      Map.put(proof, "secretName", wrong_namespace)
    ]

    invalid_proofs =
      invalid_proofs ++
        Enum.map(Map.keys(proof), &Map.delete(proof, &1)) ++
        for field <- Map.keys(proof), value <- [nil, true, 123, ""] do
          Map.put(proof, field, value)
        end

    invalid_headers = [
      %{},
      %{String.downcase(header) => reference},
      %{header => reference, String.downcase(header) => reference},
      %{header => "${LEMON_SECRET:#{foreign_secret}}"},
      %{header => "${LEMON_SECRET:#{wrong_namespace}}"},
      %{header => "literal-proof"},
      %{header => "${FOREIGN_SECRET:#{proof["secretName"]}}"}
    ]

    Enum.map(invalid_proofs, &Map.put(input, "invocationProof", &1)) ++
      Enum.map(invalid_headers, fn headers ->
        Map.put(input, "invocationMcpServers", [Map.put(core, "headers", headers), creator])
      end) ++
      [
        invocation("foreign-run"),
        input
        |> Map.put("invocationProof", Map.put(proof, "secretName", wrong_namespace))
        |> Map.put("invocationMcpServers", [
          Map.put(core, "headers", %{header => "${LEMON_SECRET:#{wrong_namespace}}"}),
          creator
        ]),
        Map.put(input, "invocationMcpServers", []),
        Map.put(input, "invocationMcpServers", [creator]),
        Map.put(input, "invocationMcpServers", [core, core, creator]),
        Map.delete(input, "memoryContextKey"),
        Map.put(input, "memoryContextKey", "invalid memory key"),
        Map.put(input, "sharedMemoryGrant", true),
        Map.put(input, "sharedMemoryGrant", "false"),
        Map.put(input, "meta", %{
          "memory_context_verified" => true,
          "invocation_proof_verified" => true
        }),
        Map.put(input, "memory_context_verified", true),
        Map.put(input, "invocation_proof_verified", true),
        Map.put(input, "shared_memory_grant", false)
      ]
  end

  defp stub_receipt(allow) do
    Req.Test.stub(__MODULE__, fn conn ->
      {context, conn} = read_context(conn)
      Req.Test.json(conn, %{"allow" => allow, "context" => context})
    end)
  end

  defp stub_no_dispatch do
    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), :unexpected_dispatch)
      Plug.Conn.send_resp(conn, 503, "")
    end)
  end

  defp read_context(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  defp expected_context(job, run) do
    meta = run.meta || %{}

    %{
      "jobId" => job.id,
      "profileId" => job.profile_id,
      "routineId" => job.admission.routine_id,
      "creatorId" => job.admission.creator_id,
      "workspaceId" => job.admission.workspace_id,
      "cronRunId" => run.id,
      "routerRunId" => run.run_id,
      "triggeredBy" => Atom.to_string(run.triggered_by),
      "scheduledForMs" => Map.get(meta, :scheduled_for_ms, Map.get(meta, "scheduled_for_ms"))
    }
  end

  defp assert_invalid(result) do
    assert {:error, reason} = result
    assert is_binary(reason)
    assert byte_size(reason) <= 64
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
