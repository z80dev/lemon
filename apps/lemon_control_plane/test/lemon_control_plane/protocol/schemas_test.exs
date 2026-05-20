defmodule LemonControlPlane.Protocol.SchemasTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Protocol.Schemas

  describe "get/1" do
    test "returns schema for known methods" do
      assert Schemas.get("connect") != nil
      assert Schemas.get("sessions.list") != nil
      assert Schemas.get("sessions.active.list") != nil
      assert Schemas.get("transports.status") != nil
      assert Schemas.get("introspection.snapshot") != nil
      assert Schemas.get("providers.status") != nil
      assert Schemas.get("memory.status") != nil
      assert Schemas.get("extensions.status") != nil
      assert Schemas.get("media.status") != nil
      assert Schemas.get("proofs.status") != nil
      assert Schemas.get("lsp.diagnostics.status") != nil
      assert Schemas.get("lsp.server.start") != nil
      assert Schemas.get("lsp.server.initialize") != nil
      assert Schemas.get("lsp.server.request") != nil
      assert Schemas.get("lsp.server.stop") != nil
      assert Schemas.get("lsp.document.open") != nil
      assert Schemas.get("lsp.document.change") != nil
      assert Schemas.get("lsp.document.close") != nil
      assert Schemas.get("cron.add") != nil
      assert Schemas.get("cron.pause") != nil
      assert Schemas.get("cron.resume") != nil
      assert Schemas.get("cron.abort") != nil
      assert Schemas.get("cron.audit") != nil
      assert Schemas.get("chat.send") != nil
      assert Schemas.get("agent") != nil
    end

    test "returns schema for contract-backed events" do
      assert Schemas.get_event("exec.approval.requested") != nil
      assert Schemas.get_event("exec.approval.resolved") != nil
    end

    test "returns nil for unknown methods" do
      assert Schemas.get("unknown.method") == nil
      assert Schemas.get("") == nil
    end

    test "returns nil for unknown events" do
      assert Schemas.get_event("unknown.event") == nil
      assert Schemas.get_event("") == nil
    end
  end

  describe "validate/2" do
    test "allows any params for methods without schemas" do
      assert :ok = Schemas.validate("unknown.method", %{"foo" => "bar"})
      assert :ok = Schemas.validate("unknown.method", nil)
      assert :ok = Schemas.validate("unknown.method", %{})
    end

    test "validates required fields" do
      # sessions.preview requires sessionKey
      assert {:error, msg} = Schemas.validate("sessions.preview", %{})
      assert msg =~ "Missing required fields"
      assert msg =~ "sessionKey"

      # With required field present
      assert :ok = Schemas.validate("sessions.preview", %{"sessionKey" => "test-key"})
    end

    test "validates multiple required fields" do
      # cron.add requires name and schedule; execution target is validated by the method.
      result = Schemas.validate("cron.add", %{})
      assert {:error, msg} = result
      assert msg =~ "name"
      assert msg =~ "schedule"
      refute msg =~ "agentId"
      refute msg =~ "sessionKey"
      refute msg =~ "prompt"
    end

    test "validates field types - string" do
      assert :ok = Schemas.validate("sessions.preview", %{"sessionKey" => "valid-string"})

      assert {:error, msg} = Schemas.validate("sessions.preview", %{"sessionKey" => 123})
      assert msg =~ "Type errors"
      assert msg =~ "sessionKey"
      assert msg =~ "expected string"
    end

    test "validates field types - integer" do
      # sessions.list has optional integer fields
      assert :ok = Schemas.validate("sessions.list", %{"limit" => 10})

      assert {:error, msg} = Schemas.validate("sessions.list", %{"limit" => "not-an-int"})
      assert msg =~ "Type errors"
      assert msg =~ "limit"
      assert msg =~ "expected integer"
    end

    test "validates channels.status method schema" do
      assert :ok = Schemas.validate("channels.status", %{})
      assert :ok = Schemas.validate("channels.status", %{"projectDir" => "/tmp/lemon"})
      assert :ok = Schemas.validate("channels.status", %{"project_dir" => "/tmp/lemon"})

      assert {:error, _} = Schemas.validate("channels.status", %{"projectDir" => 123})
    end

    test "validates field types - boolean" do
      # cron.add has optional boolean enabled
      valid_params = %{
        "name" => "test",
        "schedule" => "* * * * *",
        "agentId" => "agent-1",
        "sessionKey" => "session-1",
        "prompt" => "hello",
        "enabled" => true,
        "maxRetries" => 1,
        "retryBackoffMs" => 1_000
      }

      assert :ok = Schemas.validate("cron.add", valid_params)

      command_params = %{
        "name" => "command",
        "schedule" => "hourly",
        "command" => "printf ok",
        "cwd" => "/tmp",
        "env" => %{"LANG" => "C"}
      }

      assert :ok = Schemas.validate("cron.add", command_params)

      invalid_params = Map.put(valid_params, "enabled", "yes")
      assert {:error, msg} = Schemas.validate("cron.add", invalid_params)
      assert msg =~ "enabled"
      assert msg =~ "expected boolean"
    end

    test "validates cron lifecycle schemas" do
      assert :ok = Schemas.validate("cron.pause", %{"id" => "cron_1"})
      assert :ok = Schemas.validate("cron.resume", %{"id" => "cron_1"})
      assert :ok = Schemas.validate("cron.abort", %{"runId" => "run_1"})
      assert :ok = Schemas.validate("cron.audit", %{"jobId" => "cron_1", "limit" => 10})

      assert :ok =
               Schemas.validate("cron.update", %{
                 "id" => "cron_1",
                 "command" => "printf ok",
                 "cwd" => "/tmp",
                 "env" => %{"LANG" => "C"}
               })

      assert {:error, msg} = Schemas.validate("cron.pause", %{})
      assert msg =~ "id"

      assert {:error, msg} = Schemas.validate("cron.abort", %{})
      assert msg =~ "runId"

      assert {:error, msg} = Schemas.validate("cron.audit", %{"limit" => "ten"})
      assert msg =~ "limit"
    end

    test "validates field types - map" do
      # connect has optional map fields like client, auth
      assert :ok = Schemas.validate("connect", %{"client" => %{"name" => "test"}})

      assert {:error, msg} = Schemas.validate("connect", %{"client" => "not-a-map"})
      assert msg =~ "client"
      assert msg =~ "expected map"
    end

    test "validates field types - list" do
      # connect has optional list field scopes
      assert :ok = Schemas.validate("connect", %{"scopes" => ["read", "write"]})

      assert {:error, msg} = Schemas.validate("connect", %{"scopes" => "not-a-list"})
      assert msg =~ "scopes"
      assert msg =~ "expected list"
    end

    test "allows nil for optional fields" do
      assert :ok = Schemas.validate("sessions.list", %{"limit" => nil})
    end

    test "ignores unknown fields" do
      # Extra fields are not validated
      assert :ok =
               Schemas.validate("sessions.preview", %{
                 "sessionKey" => "test",
                 "unknownField" => "ignored"
               })
    end

    test "handles nil params" do
      assert {:error, _} = Schemas.validate("sessions.preview", nil)
      assert :ok = Schemas.validate("connect", nil)
    end

    test "validates chat.send schema" do
      assert {:error, _} = Schemas.validate("chat.send", %{})

      assert :ok =
               Schemas.validate("chat.send", %{
                 "sessionKey" => "test",
                 "prompt" => "hello"
               })

      # With optional fields
      assert :ok =
               Schemas.validate("chat.send", %{
                 "sessionKey" => "test",
                 "prompt" => "hello",
                 "agentId" => "agent-1",
                 "queueMode" => "append"
               })
    end

    test "validates exec.approval.resolve schema" do
      assert {:error, _} = Schemas.validate("exec.approval.resolve", %{})

      assert :ok =
               Schemas.validate("exec.approval.resolve", %{
                 "approvalId" => "approval-123",
                 "decision" => "approve_once"
               })
    end

    test "validates approval event schemas" do
      assert :ok =
               Schemas.validate_event("exec.approval.requested", %{
                 "approvalId" => "approval-oauth-1",
                 "runId" => "run-1",
                 "sessionKey" => "session-1",
                 "agentId" => "agent-1",
                 "tool" => "mcp_mcp_oauth",
                 "action" => %{"type" => "mcp_oauth"},
                 "rationale" => "Authorize MCP resource",
                 "requestedAtMs" => 1_772_000_000_000,
                 "expiresAtMs" => 1_772_000_060_000
               })

      assert :ok =
               Schemas.validate_event("exec.approval.resolved", %{
                 "approvalId" => "approval-oauth-1",
                 "decision" => "approve_once",
                 "runId" => "run-1",
                 "sessionKey" => "session-1",
                 "agentId" => "agent-1",
                 "tool" => "mcp_mcp_oauth"
               })

      assert {:error, msg} =
               Schemas.validate_event("exec.approval.resolved", %{
                 "decision" => "approve_once"
               })

      assert msg =~ "approvalId"

      assert {:error, msg} =
               Schemas.validate_event("exec.approval.requested", %{
                 "approvalId" => "approval-oauth-1",
                 "tool" => "mcp_mcp_oauth",
                 "action" => []
               })

      assert msg =~ "action"
      assert msg =~ "expected map"
      assert :ok = Schemas.validate_event("custom.event", %{"anything" => true})
    end

    test "validates agent schema" do
      assert {:error, _} = Schemas.validate("agent", %{})

      assert :ok = Schemas.validate("agent", %{"prompt" => "hello"})

      assert :ok =
               Schemas.validate("agent", %{
                 "prompt" => "hello",
                 "sessionKey" => "session-1",
                 "agentId" => "agent-1",
                 "engineId" => "claude"
               })
    end

    test "validates providers.status schema" do
      assert :ok = Schemas.validate("providers.status", %{})
      assert :ok = Schemas.validate("providers.status", %{"provider" => "openai"})
      assert :ok = Schemas.validate("providers.status", %{"providers" => ["openai", "zai"]})
      assert :ok = Schemas.validate("providers.status", %{"includeCatalog" => true})
      assert :ok = Schemas.validate("providers.status", %{"fallbackProviders" => ["zai"]})
      assert :ok = Schemas.validate("providers.status", %{"requestedModel" => "gpt-5-mini"})

      assert {:error, msg} = Schemas.validate("providers.status", %{"providers" => "openai"})
      assert msg =~ "providers"
      assert msg =~ "expected list"
    end

    test "validates extensions.status schema" do
      assert :ok = Schemas.validate("extensions.status", %{})
      assert :ok = Schemas.validate("extensions.status", %{"cwd" => "/tmp/lemon"})
      assert :ok = Schemas.validate("extensions.status", %{"projectDir" => "/tmp/lemon"})

      assert :ok =
               Schemas.validate("extensions.status", %{
                 "extensionPaths" => ["/tmp/extensions"]
               })

      assert {:error, msg} =
               Schemas.validate("extensions.status", %{"extensionPaths" => "/tmp/extensions"})

      assert msg =~ "extensionPaths"
      assert msg =~ "expected list"
    end

    test "validates memory.status schema" do
      assert :ok = Schemas.validate("memory.status", %{})
      assert :ok = Schemas.validate("memory.status", nil)
    end

    # New tests for parity methods
    test "validates system-presence method (no params required)" do
      assert :ok = Schemas.validate("system-presence", %{})
      assert :ok = Schemas.validate("system-presence", nil)
    end

    test "validates system-event method requires eventType" do
      assert {:error, _} = Schemas.validate("system-event", %{})
      assert :ok = Schemas.validate("system-event", %{"eventType" => "test"})
      assert :ok = Schemas.validate("system-event", %{"event_type" => "test"})
    end

    test "validates system-event method with optional params" do
      params = %{
        "eventType" => "test",
        "payload" => %{"key" => "value"},
        "target" => "system"
      }

      assert :ok = Schemas.validate("system-event", params)

      assert {:error, msg} =
               Schemas.validate("system-event", %{"eventType" => "test", "payload" => []})

      assert msg =~ "payload"
    end

    test "validates events.ingest schema" do
      assert :ok =
               Schemas.validate("events.ingest", %{
                 "eventType" => "custom",
                 "payload" => %{"safe" => true},
                 "target" => "system"
               })

      assert :ok = Schemas.validate("events.ingest", %{"event_type" => "custom"})

      assert {:error, msg} = Schemas.validate("events.ingest", %{})
      assert msg =~ "eventType"

      assert {:error, msg} =
               Schemas.validate("events.ingest", %{"eventType" => "custom", "payload" => []})

      assert msg =~ "payload"
    end

    test "validates event subscription topic string compatibility" do
      assert :ok = Schemas.validate("events.subscribe", %{"topics" => "system"})
      assert :ok = Schemas.validate("events.subscribe", %{"topics" => ["system"]})
      assert :ok = Schemas.validate("events.unsubscribe", %{"topics" => "system"})

      assert {:error, msg} = Schemas.validate("events.subscribe", %{"topics" => 123})
      assert msg =~ "topics"
    end

    test "validates system.reload schema structure" do
      schema = Schemas.get("system.reload")

      assert is_map(schema)
      assert schema["type"] == "object"
      assert "scope" in schema["required"]
      assert schema["additionalProperties"] == true

      properties = schema["properties"]
      assert is_map(properties)

      assert properties["scope"]["type"] == "string"

      assert properties["scope"]["enum"] == [
               "module",
               "app",
               "extension",
               "all"
             ]

      assert properties["module"]["type"] == "string"
      assert properties["compile"]["type"] == "boolean"
      assert properties["app"]["type"] == "string"
      assert properties["path"]["type"] == "string"
      assert properties["force"]["type"] == "boolean"
      assert properties["apps"]["type"] == "array"
      assert properties["extensions"]["type"] == "array"
    end

    test "validates send method requires channelId and content" do
      assert {:error, _} = Schemas.validate("send", %{})
      assert {:error, _} = Schemas.validate("send", %{"channelId" => "test"})
      assert {:error, _} = Schemas.validate("send", %{"content" => "test"})
      assert :ok = Schemas.validate("send", %{"channelId" => "test", "content" => "hello"})
    end

    test "validates send method with optional params" do
      params = %{
        "channelId" => "telegram",
        "content" => "hello",
        "accountId" => "acc123",
        "peerId" => "peer456",
        "idempotencyKey" => "key789"
      }

      assert :ok = Schemas.validate("send", params)
    end

    test "validates voicewake.get method (no params required)" do
      assert :ok = Schemas.validate("voicewake.get", %{})
    end

    test "validates voicewake.set method requires enabled" do
      assert {:error, _} = Schemas.validate("voicewake.set", %{})
      assert :ok = Schemas.validate("voicewake.set", %{"enabled" => true})
      assert :ok = Schemas.validate("voicewake.set", %{"enabled" => false, "keyword" => "hey"})
    end

    test "validates tts.convert method requires text" do
      assert {:error, _} = Schemas.validate("tts.convert", %{})
      assert :ok = Schemas.validate("tts.convert", %{"text" => "hello"})
      assert :ok = Schemas.validate("tts.convert", %{"text" => "hello", "provider" => "openai"})
    end

    test "validates tts.set-provider method requires provider" do
      assert {:error, _} = Schemas.validate("tts.set-provider", %{})
      assert :ok = Schemas.validate("tts.set-provider", %{"provider" => "openai"})
    end

    test "validates config.set method requires key and value" do
      assert {:error, _} = Schemas.validate("config.set", %{})
      assert {:error, _} = Schemas.validate("config.set", %{"key" => "test"})
      assert :ok = Schemas.validate("config.set", %{"key" => "test", "value" => "val"})
    end

    test "validates config.patch method requires patch" do
      assert {:error, _} = Schemas.validate("config.patch", %{})
      assert :ok = Schemas.validate("config.patch", %{"patch" => %{"key" => "value"}})
    end

    test "validates secrets methods" do
      assert :ok = Schemas.validate("secrets.status", %{})
      assert :ok = Schemas.validate("secrets.list", %{"owner" => "default"})

      assert {:error, _} = Schemas.validate("secrets.set", %{})

      assert :ok =
               Schemas.validate("secrets.set", %{
                 "name" => "demo",
                 "value" => "abc",
                 "provider" => "manual",
                 "expiresAt" => 1_700_000_000_000
               })

      assert {:error, _} = Schemas.validate("secrets.delete", %{})
      assert :ok = Schemas.validate("secrets.delete", %{"name" => "demo"})

      assert {:error, _} = Schemas.validate("secrets.exists", %{})

      assert :ok =
               Schemas.validate("secrets.exists", %{
                 "name" => "demo",
                 "preferEnv" => true,
                 "envFallback" => true
               })
    end

    test "validates device.pair.request method" do
      assert {:error, _} = Schemas.validate("device.pair.request", %{})
      assert {:error, _} = Schemas.validate("device.pair.request", %{"deviceType" => "mobile"})
      params = %{"deviceType" => "mobile", "deviceName" => "My Phone"}
      assert :ok = Schemas.validate("device.pair.request", params)
    end

    test "validates wizard.step method" do
      assert {:error, _} = Schemas.validate("wizard.step", %{})
      assert {:error, _} = Schemas.validate("wizard.step", %{"wizardId" => "wiz123"})
      params = %{"wizardId" => "wiz123", "stepId" => "step1"}
      assert :ok = Schemas.validate("wizard.step", params)
    end

    test "validates connect.challenge method requires challenge" do
      assert {:error, _} = Schemas.validate("connect.challenge", %{})
      assert :ok = Schemas.validate("connect.challenge", %{"challenge" => "abc123"})
    end

    test "validates sessions.active.list method schema" do
      assert :ok = Schemas.validate("sessions.active.list", %{})

      assert :ok =
               Schemas.validate("sessions.active.list", %{
                 "agentId" => "default",
                 "limit" => 25,
                 "route" => %{"channelId" => "telegram"}
               })

      assert {:error, _} = Schemas.validate("sessions.active.list", %{"limit" => "many"})
    end

    test "validates transports.status method schema" do
      assert :ok = Schemas.validate("transports.status", %{})
      assert :ok = Schemas.validate("transports.status", nil)
    end

    test "validates introspection.snapshot method schema" do
      assert :ok = Schemas.validate("introspection.snapshot", %{})

      assert :ok =
               Schemas.validate("introspection.snapshot", %{
                 "agentId" => "default",
                 "route" => %{"channelId" => "telegram"},
                 "limit" => 100,
                 "sessionLimit" => 50,
                 "activeLimit" => 10,
                 "includeAgents" => true,
                 "includeSessions" => true,
                 "includeActiveSessions" => true,
                 "includeChannels" => true,
                 "includeTransports" => true
               })

      assert {:error, _} = Schemas.validate("introspection.snapshot", %{"includeAgents" => "yes"})
    end

    test "validates lsp.diagnostics.status method schema" do
      assert :ok = Schemas.validate("lsp.diagnostics.status", %{})
      assert :ok = Schemas.validate("lsp.diagnostics.status", %{"diagnosticsTimeoutMs" => 1000})
      assert :ok = Schemas.validate("lsp.diagnostics.status", %{"diagnostics_timeout_ms" => 1000})

      assert {:error, _} =
               Schemas.validate("lsp.diagnostics.status", %{"diagnosticsTimeoutMs" => "slow"})
    end

    test "validates media.status method schema" do
      assert :ok = Schemas.validate("media.status", %{})
      assert :ok = Schemas.validate("media.status", %{"projectDir" => "/tmp/lemon"})
      assert :ok = Schemas.validate("media.status", %{"project_dir" => "/tmp/lemon"})
      assert :ok = Schemas.validate("media.status", %{"jobsDir" => "/tmp/lemon/jobs"})
      assert :ok = Schemas.validate("media.status", %{"artifactsDir" => "/tmp/lemon/artifacts"})
      assert :ok = Schemas.validate("media.status", %{"limit" => 5})

      assert {:error, _} = Schemas.validate("media.status", %{"limit" => "many"})
    end

    test "validates proofs.status method schema" do
      assert :ok = Schemas.validate("proofs.status", %{})
      assert :ok = Schemas.validate("proofs.status", %{"projectDir" => "/tmp/lemon"})
      assert :ok = Schemas.validate("proofs.status", %{"project_dir" => "/tmp/lemon"})
      assert :ok = Schemas.validate("proofs.status", %{"limit" => 5})

      assert {:error, _} = Schemas.validate("proofs.status", %{"limit" => "many"})
    end

    test "validates checkpoint.status method schema" do
      assert :ok = Schemas.validate("checkpoint.status", %{})

      assert :ok =
               Schemas.validate("checkpoint.status", %{
                 "checkpointDir" => "/tmp/lemon-checkpoints",
                 "limit" => 5,
                 "eventLimit" => 3,
                 "runId" => "run_1",
                 "sessionKey" => "agent:default",
                 "agentId" => "default"
               })

      assert :ok =
               Schemas.validate("checkpoint.status", %{
                 "checkpoint_dir" => "/tmp/lemon-checkpoints",
                 "event_limit" => 3,
                 "run_id" => "run_1",
                 "session_key" => "agent:default",
                 "agent_id" => "default"
               })

      assert {:error, _} = Schemas.validate("checkpoint.status", %{"eventLimit" => "many"})
    end

    test "validates lsp server session method schemas" do
      assert :ok =
               Schemas.validate("lsp.server.start", %{
                 "serverId" => "elixir-ls",
                 "sessionId" => "test-session",
                 "cwd" => "/tmp"
               })

      assert {:error, _} = Schemas.validate("lsp.server.start", %{})
      assert {:error, _} = Schemas.validate("lsp.server.start", %{"serverId" => 123})

      assert :ok =
               Schemas.validate("lsp.server.request", %{
                 "sessionId" => "test-session",
                 "method" => "initialize",
                 "params" => %{},
                 "timeoutMs" => 1000
               })

      assert {:error, _} = Schemas.validate("lsp.server.request", %{})
      assert {:error, _} = Schemas.validate("lsp.server.request", %{"sessionId" => "test"})
      assert {:error, _} = Schemas.validate("lsp.server.request", %{"method" => "initialize"})
      assert {:error, _} = Schemas.validate("lsp.server.request", %{"sessionId" => 123})

      assert :ok =
               Schemas.validate("lsp.server.initialize", %{
                 "sessionId" => "test-session",
                 "params" => %{},
                 "timeoutMs" => 1000
               })

      assert {:error, _} = Schemas.validate("lsp.server.initialize", %{})
      assert {:error, _} = Schemas.validate("lsp.server.initialize", %{"sessionId" => 123})

      assert :ok =
               Schemas.validate("lsp.document.open", %{
                 "sessionId" => "test-session",
                 "uri" => "file:///tmp/test.ex",
                 "languageId" => "elixir",
                 "text" => "defmodule Test do end",
                 "version" => 1
               })

      assert :ok =
               Schemas.validate("lsp.document.change", %{
                 "sessionId" => "test-session",
                 "uri" => "file:///tmp/test.ex",
                 "text" => "defmodule Test do\nend",
                 "version" => 2
               })

      assert :ok =
               Schemas.validate("lsp.document.close", %{
                 "sessionId" => "test-session",
                 "uri" => "file:///tmp/test.ex"
               })

      assert {:error, _} = Schemas.validate("lsp.document.open", %{"sessionId" => "test"})
      assert {:error, _} = Schemas.validate("lsp.document.change", %{"sessionId" => "test"})
      assert {:error, _} = Schemas.validate("lsp.document.close", %{"sessionId" => "test"})
      assert :ok = Schemas.validate("lsp.server.stop", %{"sessionId" => "test-session"})
      assert {:error, _} = Schemas.validate("lsp.server.stop", %{})
      assert {:error, _} = Schemas.validate("lsp.server.stop", %{"sessionId" => 123})
    end

    test "validates agent routing method schemas" do
      assert {:error, _} = Schemas.validate("agent.inbox.send", %{})

      assert :ok =
               Schemas.validate("agent.inbox.send", %{
                 "prompt" => "hi",
                 "agentId" => "default",
                 "sessionTag" => "latest",
                 "to" => "tg:123",
                 "deliverTo" => ["tg:456"],
                 "meta" => %{}
               })

      assert :ok =
               Schemas.validate("agent.directory.list", %{
                 "agentId" => "default",
                 "includeSessions" => true,
                 "limit" => 10,
                 "route" => %{"channelId" => "telegram"}
               })

      assert :ok =
               Schemas.validate("agent.targets.list", %{
                 "channelId" => "telegram",
                 "accountId" => "default",
                 "query" => "ops",
                 "limit" => 20
               })

      assert :ok = Schemas.validate("agent.endpoints.list", %{"agentId" => "default"})
      assert {:error, _} = Schemas.validate("agent.endpoints.set", %{})

      assert :ok =
               Schemas.validate("agent.endpoints.set", %{
                 "name" => "ops",
                 "target" => "tg:-100123/7"
               })

      assert {:error, _} = Schemas.validate("agent.endpoints.delete", %{})
      assert :ok = Schemas.validate("agent.endpoints.delete", %{"name" => "ops"})
    end
  end
end
