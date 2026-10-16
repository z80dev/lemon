defmodule LemonControlPlane.Protocol.SchemasTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Protocol.Schemas

  describe "get/1" do
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

  test "usage.records requires a millisecond range and typed pagination filters" do
    assert :ok =
             Schemas.validate("usage.records", %{
               "fromMs" => 0,
               "toMs" => 1000,
               "runId" => "r",
               "sessionKey" => "s",
               "cursor" => "opaque",
               "limit" => 100
             })

    assert {:error, _} = Schemas.validate("usage.records", %{"fromMs" => 0})
    assert {:error, _} = Schemas.validate("usage.records", %{"fromMs" => "0", "toMs" => 1000})
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
      assert :ok = Schemas.validate("cron.pause", %{"all" => true})
      assert :ok = Schemas.validate("cron.resume", %{"all" => true})
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

      assert {:error, msg} = Schemas.validate("cron.resume", %{"all" => "yes"})
      assert msg =~ "expected boolean"

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

    # New tests for parity methods
    test "validates config.set method requires key and value" do
      assert {:error, _} = Schemas.validate("config.set", %{})
      assert {:error, _} = Schemas.validate("config.set", %{"key" => "test"})
      assert :ok = Schemas.validate("config.set", %{"key" => "test", "value" => "val"})
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

    test "validates agent directory schema" do
      assert :ok =
               Schemas.validate("agent.directory.list", %{
                 "agentId" => "default",
                 "includeSessions" => true,
                 "limit" => 10,
                 "route" => %{"channelId" => "telegram"}
               })
    end
  end
end
