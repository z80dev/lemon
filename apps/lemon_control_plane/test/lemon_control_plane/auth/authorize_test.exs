defmodule LemonControlPlane.Auth.AuthorizeTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.{Authorize, TokenStore}

  setup do
    clear_session_tokens()

    on_exit(fn ->
      clear_session_tokens()
    end)

    :ok
  end

  describe "from_params/1 params-based parsing" do
    test "parses operator role and scopes from params" do
      {:ok, ctx} =
        Authorize.from_params(%{
          "role" => "operator",
          "scopes" => ["operator.admin", "operator.read", "write", "unknown.scope"],
          "client" => %{"id" => "operator-client-1"}
        })

      assert ctx.role == :operator
      assert ctx.scopes == [:admin, :read, :write]
      assert ctx.token == nil
      assert ctx.client_id == "operator-client-1"
      assert ctx.identity == nil
    end

    test "parses node role with default scopes" do
      {:ok, ctx} =
        Authorize.from_params(%{
          "role" => "node",
          "client" => %{"id" => "node-123"}
        })

      assert ctx.role == :node
      assert ctx.scopes == [:invoke, :event]
      assert ctx.token == nil
      assert ctx.client_id == "node-123"
      assert ctx.identity == nil
    end

    test "parses device role with default scopes" do
      {:ok, ctx} =
        Authorize.from_params(%{
          "role" => "device",
          "client" => %{"id" => "device-456"}
        })

      assert ctx.role == :device
      assert ctx.scopes == [:control]
      assert ctx.token == nil
      assert ctx.client_id == "device-456"
      assert ctx.identity == nil
    end
  end

  describe "from_params/1 token path" do
    test "falls back to operator read scope for unknown identity type" do
      token = "unknown-identity-token-#{System.unique_integer([:positive])}"
      identity = %{"type" => "service", "serviceId" => "svc-1"}

      {:ok, _} = TokenStore.store(token, identity)

      {:ok, ctx} =
        Authorize.from_params(%{
          "auth" => %{"token" => token}
        })

      assert ctx.role == :operator
      assert ctx.scopes == [:read]
      assert ctx.token == token
      assert ctx.client_id == nil
      assert ctx.identity == identity
    end
  end

  describe "default contexts" do
    test "default_operator/0 returns full operator context" do
      assert Authorize.default_operator() == %{
               role: :operator,
               scopes: [:admin, :read, :write, :approvals, :pairing],
               token: nil,
               client_id: nil
             }
    end

    test "node_context/1 returns node context for id" do
      assert Authorize.node_context("node-xyz") == %{
               role: :node,
               scopes: [:invoke, :event],
               token: nil,
               client_id: "node-xyz"
             }
    end
  end

  describe "authorize/3" do
    test "allows public methods when required scopes are empty" do
      ctx = %{role: :operator, scopes: [:read]}

      assert :ok = Authorize.authorize(ctx, "health", [])
    end

    test "allows when context has at least one required scope" do
      ctx = %{role: :operator, scopes: [:read, :write]}

      assert :ok = Authorize.authorize(ctx, "chat.send", [:write])
    end

    test "returns node role forbidden error for node-only methods with non-node context" do
      ctx = %{role: :operator, scopes: [:read]}

      assert {:error, {:forbidden, "Method node.invoke.result requires node role"}} =
               Authorize.authorize(ctx, "node.invoke.result", [:invoke, :event])
    end

    test "returns generic insufficient-permissions forbidden error" do
      ctx = %{role: :operator, scopes: [:read]}

      assert {:error, {:forbidden, "Insufficient permissions for config.get"}} =
               Authorize.authorize(ctx, "config.get", [:admin])
    end
  end

  describe "required_scopes/1" do
    test "classifies representative methods by category" do
      assert Authorize.required_scopes("health") == []
      assert Authorize.required_scopes("config.get") == [:admin]
      assert Authorize.required_scopes("exec.approvals.list") == [:approvals]
      assert Authorize.required_scopes("node.pair.start") == [:pairing]
      assert Authorize.required_scopes("node.event") == [:invoke, :event]
      assert Authorize.required_scopes("chat.send") == [:write]
      assert Authorize.required_scopes("sessions.list") == [:read]
    end
  end

  defp clear_session_tokens do
    try do
      LemonCore.Store.list(:session_tokens)
      |> Enum.each(fn {token, _} ->
        LemonCore.Store.delete(:session_tokens, token)
      end)
    rescue
      _ -> :ok
    end
  end
end
