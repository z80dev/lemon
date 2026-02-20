defmodule LemonControlPlane.Protocol.SchemasTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Protocol.Schemas

  describe "get/1" do
    test "returns schema for known methods" do
      assert Schemas.get("connect") != nil
      assert Schemas.get("sessions.list") != nil
      assert Schemas.get("cron.add") != nil
      assert Schemas.get("chat.send") != nil
      assert Schemas.get("agent") != nil
    end

    test "returns nil for unknown methods" do
      assert Schemas.get("unknown.method") == nil
      assert Schemas.get("") == nil
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
      # cron.add requires name, schedule, agentId, sessionKey, prompt
      result = Schemas.validate("cron.add", %{})
      assert {:error, msg} = result
      assert msg =~ "name"
      assert msg =~ "schedule"
      assert msg =~ "agentId"
      assert msg =~ "sessionKey"
      assert msg =~ "prompt"
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
        "enabled" => true
      }

      assert :ok = Schemas.validate("cron.add", valid_params)

      invalid_params = Map.put(valid_params, "enabled", "yes")
      assert {:error, msg} = Schemas.validate("cron.add", invalid_params)
      assert msg =~ "enabled"
      assert msg =~ "expected boolean"
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
    test "validates system-presence method (no params required)" do
      assert :ok = Schemas.validate("system-presence", %{})
      assert :ok = Schemas.validate("system-presence", nil)
    end

    test "validates system-event method requires eventType" do
      assert {:error, _} = Schemas.validate("system-event", %{})
      assert :ok = Schemas.validate("system-event", %{"eventType" => "test"})
    end

    test "validates system-event method with optional params" do
      params = %{
        "eventType" => "test",
        "payload" => %{"key" => "value"},
        "target" => "system"
      }

      assert :ok = Schemas.validate("system-event", params)
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
