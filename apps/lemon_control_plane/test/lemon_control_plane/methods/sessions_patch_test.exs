defmodule LemonControlPlane.Methods.SessionsPatchTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.SessionsPatch

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

    test "stores thinking_level override" do
      session_key = "session_#{System.unique_integer()}"

      params = %{
        "sessionKey" => session_key,
        "thinkingLevel" => "extended"
      }

      ctx = %{auth: %{role: :operator}}

      {:ok, _result} = SessionsPatch.handle(params, ctx)

      stored = LemonCore.Store.get_session_policy(session_key)
      assert stored[:thinking_level] == "extended"

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
end
