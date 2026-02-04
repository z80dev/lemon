defmodule LemonControlPlane.Auth.AuthorizeExpirationTest do
  @moduledoc """
  Tests for Authorize.from_params handling of expired tokens.

  Per parity requirements, expired tokens should be treated as auth errors,
  not fall through to unauthenticated path.
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.{Authorize, TokenStore}

  setup do
    # Clean up token store after each test
    on_exit(fn ->
      try do
        LemonCore.Store.list(:session_tokens) |> Enum.each(fn {k, _} ->
          LemonCore.Store.delete(:session_tokens, k)
        end)
      rescue
        _ -> :ok
      end
    end)
    :ok
  end

  describe "from_params/1 with expired token" do
    test "returns unauthorized error for expired token" do
      token = "expired-auth-token-#{System.unique_integer([:positive])}"

      # Store an expired token
      LemonCore.Store.put(:session_tokens, token, %{
        token: token,
        identity: %{"type" => "device", "deviceId" => "dev-123"},
        issued_at_ms: System.system_time(:millisecond) - 60_000,
        expires_at_ms: System.system_time(:millisecond) - 1000  # Expired
      })

      # Should return unauthorized error, not fall through to params-based auth
      result = Authorize.from_params(%{
        "auth" => %{"token" => token}
      })

      assert {:error, {:unauthorized, message}} = result
      assert message =~ "expired"
    end

    test "returns unauthorized error for invalid token" do
      result = Authorize.from_params(%{
        "auth" => %{"token" => "nonexistent-token-123"}
      })

      assert {:error, {:unauthorized, message}} = result
      assert message =~ "Invalid"
    end

    test "valid token returns auth context successfully" do
      token = "valid-auth-token-#{System.unique_integer([:positive])}"

      # Store a valid token
      {:ok, _} = TokenStore.store(token, %{
        "type" => "device",
        "deviceId" => "dev-456"
      })

      {:ok, auth_ctx} = Authorize.from_params(%{
        "auth" => %{"token" => token}
      })

      assert auth_ctx.role == :device
      assert :control in auth_ctx.scopes
    end

    test "empty token falls through to params-based auth" do
      # Empty token should not trigger token validation error
      {:ok, auth_ctx} = Authorize.from_params(%{
        "auth" => %{"token" => ""},
        "role" => "operator"
      })

      # Should use params-based auth
      assert auth_ctx.role == :operator
    end

    test "nil token falls through to params-based auth" do
      {:ok, auth_ctx} = Authorize.from_params(%{
        "auth" => %{"token" => nil},
        "role" => "node"
      })

      assert auth_ctx.role == :node
    end

    test "no token provided uses params-based auth" do
      {:ok, auth_ctx} = Authorize.from_params(%{
        "role" => "operator",
        "scopes" => ["operator.admin", "operator.read"]
      })

      assert auth_ctx.role == :operator
      assert :admin in auth_ctx.scopes
      assert :read in auth_ctx.scopes
    end
  end

  describe "from_params/1 with string keys (JSONL reload)" do
    test "handles expired token with string keys in store" do
      token = "expired-string-auth-#{System.unique_integer([:positive])}"

      # Store with string keys (simulates JSONL reload)
      LemonCore.Store.put(:session_tokens, token, %{
        "token" => token,
        "identity" => %{"type" => "device"},
        "issued_at_ms" => System.system_time(:millisecond) - 60_000,
        "expires_at_ms" => System.system_time(:millisecond) - 1000
      })

      result = Authorize.from_params(%{
        "auth" => %{"token" => token}
      })

      assert {:error, {:unauthorized, message}} = result
      assert message =~ "expired"
    end

    test "handles valid token with string keys in store" do
      token = "valid-string-auth-#{System.unique_integer([:positive])}"

      LemonCore.Store.put(:session_tokens, token, %{
        "token" => token,
        "identity" => %{"type" => "node", "nodeId" => "node-789"},
        "issued_at_ms" => System.system_time(:millisecond),
        "expires_at_ms" => System.system_time(:millisecond) + 60_000
      })

      {:ok, auth_ctx} = Authorize.from_params(%{
        "auth" => %{"token" => token}
      })

      assert auth_ctx.role == :node
      assert :invoke in auth_ctx.scopes
      assert :event in auth_ctx.scopes
    end
  end
end
