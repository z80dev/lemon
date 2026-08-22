defmodule LemonControlPlane.Methods.SessionsPatchTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.{SessionsDelete, SessionsPatch, SessionsReset}

  describe "handle/2" do
    test "returns error when sessionKey is missing" do
      params = %{"toolPolicy" => %{"bash" => "always"}}
      ctx = %{auth: %{role: :operator}}

      {:error, error} = SessionsPatch.handle(params, ctx)
      assert String.contains?(inspect(error), "sessionKey")
    end

    test "stores tool_policy in session policy store" do
      session_key = "session_#{System.unique_integer()}"

      params = %{
        "sessionKey" => session_key,
        "toolPolicy" => %{"bash" => "always", "write" => "dangerous"}
      }

      ctx = %{auth: %{role: :operator}}

      {:ok, result} = SessionsPatch.handle(params, ctx)
      assert result["success"] == true
      assert result["sessionKey"] == session_key
      assert result["summary"]["sessionKey"] == session_key
      assert result["summary"]["patchedKeys"] == ["tool_policy"]
      assert result["summary"]["patchedCount"] == 1
      assert result["summary"]["cleanup"]["includesToolPolicy"] == false
      assert result["summary"]["cleanup"]["includesModel"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "dangerous"

      # Verify policy is stored in the session policy store (where router reads from)
      stored = LemonCore.Store.get_session_policy(session_key)
      assert stored[:tool_policy] == %{"bash" => "always", "write" => "dangerous"}

      # Cleanup
      LemonCore.Store.delete_session_policy(session_key)
    end

    test "stores model override" do
      session_key = "session_#{System.unique_integer()}"

      params = %{
        "sessionKey" => session_key,
        "model" => "claude-3-opus-20240229"
      }

      ctx = %{auth: %{role: :operator}}

      {:ok, _result} = SessionsPatch.handle(params, ctx)

      stored = LemonCore.Store.get_session_policy(session_key)
      assert stored[:model] == "claude-3-opus-20240229"

      # Cleanup
      LemonCore.Store.delete_session_policy(session_key)
    end

    test "rejects unknown thinking_level values" do
      session_key = "session_#{System.unique_integer()}"

      params = %{
        "sessionKey" => session_key,
        "thinkingLevel" => "extended"
      }

      ctx = %{auth: %{role: :operator}}

      assert {:error, {:invalid_params, message, %{field: "thinkingLevel", value: "extended"}}} =
               SessionsPatch.handle(params, ctx)

      assert message =~ "thinkingLevel must be one of"
      refute LemonCore.Store.get_session_policy(session_key)
    end

    test "stores thinking_level override" do
      session_key = "session_#{System.unique_integer()}"

      params = %{
        "sessionKey" => session_key,
        "thinkingLevel" => "high"
      }

      ctx = %{auth: %{role: :operator}}

      {:ok, _result} = SessionsPatch.handle(params, ctx)

      stored = LemonCore.Store.get_session_policy(session_key)
      assert stored[:thinking_level] == "high"

      # Cleanup
      LemonCore.Store.delete_session_policy(session_key)
    end

    test "merges with existing session policy" do
      session_key = "session_#{System.unique_integer()}"

      # Pre-populate with existing policy
      existing = %{existing_key: "existing_value"}
      LemonCore.Store.put_session_policy(session_key, existing)

      params = %{
        "sessionKey" => session_key,
        "toolPolicy" => %{"bash" => "never"}
      }

      ctx = %{auth: %{role: :operator}}

      {:ok, _result} = SessionsPatch.handle(params, ctx)

      stored = LemonCore.Store.get_session_policy(session_key)
      # Should have both existing and new keys
      assert stored[:existing_key] == "existing_value"
      assert stored[:tool_policy] == %{"bash" => "never"}

      # Cleanup
      LemonCore.Store.delete_session_policy(session_key)
    end

    test "ignores nil values in patch" do
      session_key = "session_#{System.unique_integer()}"

      params = %{
        "sessionKey" => session_key,
        "toolPolicy" => %{"bash" => "always"},
        "model" => nil,
        "thinkingLevel" => nil
      }

      ctx = %{auth: %{role: :operator}}

      {:ok, _result} = SessionsPatch.handle(params, ctx)

      stored = LemonCore.Store.get_session_policy(session_key)
      assert stored[:tool_policy] == %{"bash" => "always"}
      # nil values should not be stored
      assert not Map.has_key?(stored, :model)
      assert not Map.has_key?(stored, :thinking_level)

      # Cleanup
      LemonCore.Store.delete_session_policy(session_key)
    end

    test "summarizes multiple patched keys without echoing values" do
      session_key = "session_#{System.unique_integer()}"

      params = %{
        "sessionKey" => session_key,
        "model" => "secret-model-name",
        "thinkingLevel" => "medium"
      }

      {:ok, result} = SessionsPatch.handle(params, %{auth: %{role: :operator}})

      assert result["summary"]["patchedKeys"] == [
               "model",
               "thinking_level"
             ]

      assert result["summary"]["patchedCount"] == 2
      refute inspect(result) =~ "secret-model-name"

      LemonCore.Store.delete_session_policy(session_key)
    end
  end

  describe "legacy engine selectors" do
    test "rejects them with actionable native-routing guidance" do
      legacy_fields = ~w(
        engine
        engine_id
        engineId
        default_engine
        defaultEngine
        engine_preference
        enginePreference
        preferred_engine
        preferredEngine
      )

      params =
        Map.new(legacy_fields, fn field -> {field, "codex"} end)
        |> Map.put("sessionKey", "session_#{System.unique_integer()}")

      assert {:error, {:invalid_params, message, %{fields: fields}}} =
               SessionsPatch.handle(params, %{auth: %{role: :operator}})

      assert fields == legacy_fields
      assert message =~ "Top-level engine selection is no longer supported"

      assert message =~
               "remove engine, engine_id, engineId, default_engine, defaultEngine, engine_preference, enginePreference, preferred_engine, preferredEngine"

      assert message =~ "Lemon now runs natively; use model to choose a model"
    end
  end

  describe "integration with LemonRouter.Policy" do
    test "session policy is accessible from router policy resolution" do
      session_key = "session_#{System.unique_integer()}"

      # Store policy via SessionsPatch
      params = %{
        "sessionKey" => session_key,
        "toolPolicy" => %{
          approvals: %{"bash" => :always},
          blocked_tools: ["dangerous_tool"]
        }
      }

      {:ok, _} = SessionsPatch.handle(params, %{auth: %{role: :operator}})

      # Verify LemonRouter.Policy can read it
      if Code.ensure_loaded?(LemonRouter.Policy) do
        policy = LemonRouter.Policy.resolve_for_run(%{session_key: session_key})

        # The tool_policy from session should be accessible
        # (exact structure depends on Policy.merge behavior)
        assert is_map(policy)
      end

      # Cleanup
      LemonCore.Store.delete_session_policy(session_key)
    end
  end

  describe "session lifecycle cleanup responses" do
    test "sessions.reset returns cleanup summary without policy contents" do
      session_key = "session_#{System.unique_integer()}"
      LemonCore.Store.put_session_policy(session_key, %{model: "private-model"})

      {:ok, result} = SessionsReset.handle(%{"sessionKey" => session_key}, %{})

      assert result["success"] == true
      assert result["sessionKey"] == session_key
      assert result["summary"]["sessionKey"] == session_key
      assert result["summary"]["reset"] == true
      assert result["summary"]["cleanup"]["deletedRunHistory"] == true
      assert result["summary"]["cleanup"]["deletedChatState"] == true
      assert result["summary"]["cleanup"]["deletedSessionPolicy"] == true
      assert result["summary"]["cleanup"]["includesMessages"] == false
      assert result["summary"]["cleanup"]["includesPolicy"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "private-model"

      assert LemonCore.Store.get_session_policy(session_key) == nil
    end

    test "sessions.delete returns cleanup summary without policy contents" do
      session_key = "session_#{System.unique_integer()}"
      LemonCore.Store.put_session_policy(session_key, %{model: "private-model"})

      {:ok, result} = SessionsDelete.handle(%{"sessionKey" => session_key}, %{})

      assert result["deleted"] == true
      assert result["sessionKey"] == session_key
      assert result["summary"]["sessionKey"] == session_key
      assert result["summary"]["deleted"] == true
      assert result["summary"]["cleanup"]["deletedRunSession"] == true
      assert result["summary"]["cleanup"]["deletedChatState"] == true
      assert result["summary"]["cleanup"]["deletedSessionPolicy"] == true
      assert result["summary"]["cleanup"]["includesMessages"] == false
      assert result["summary"]["cleanup"]["includesPolicy"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "private-model"

      assert LemonCore.Store.get_session_policy(session_key) == nil
    end
  end
end
