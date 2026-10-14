defmodule LemonControlPlane.Auth.AuthorizeTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.{Authorize, TokenStore}

  setup do
    clear_session_tokens()
    previous_operator_token = Application.get_env(:lemon_control_plane, :operator_token)
    Application.delete_env(:lemon_control_plane, :operator_token)

    on_exit(fn ->
      clear_session_tokens()

      if is_nil(previous_operator_token) do
        Application.delete_env(:lemon_control_plane, :operator_token)
      else
        Application.put_env(:lemon_control_plane, :operator_token, previous_operator_token)
      end
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

    test "does not accept params-only node or unsupported roles" do
      assert {:error, {:unauthorized, "A valid node session token is required"}} =
               Authorize.from_params(%{"role" => "node", "client" => %{"id" => "node-123"}})

      for role <- ["device", "service"] do
        assert {:error, {:unauthorized, "Unsupported role"}} =
                 Authorize.from_params(%{"role" => role})
      end
    end
  end

  describe "from_params/1 token path" do
    test "unknown stored identity cannot escalate to operator" do
      token = "unknown-identity-token-#{System.unique_integer([:positive])}"
      identity = %{"type" => "service", "serviceId" => "svc-1"}

      {:ok, _} = TokenStore.store(token, identity)

      assert {:error, {:unauthorized, "Unsupported token identity"}} =
               Authorize.from_params(%{"auth" => %{"token" => token}})
    end

    test "retired device tokens cannot establish a connection" do
      token = "retired-device-token-#{System.unique_integer([:positive])}"
      {:ok, _} = TokenStore.store(token, %{"type" => "device", "deviceId" => "legacy"})

      assert {:error, {:unauthorized, "Unsupported token identity"}} =
               Authorize.from_params(%{"auth" => %{"token" => token}})
    end

    test "configured operator token rejects missing and wrong credentials and accepts the right one" do
      operator_token = "operator-secret-#{System.unique_integer([:positive])}"
      Application.put_env(:lemon_control_plane, :operator_token, operator_token)

      assert {:error, {:unauthorized, "Operator token is required"}} =
               Authorize.from_params(%{"role" => "operator"})

      assert {:error, {:unauthorized, "Operator token is invalid"}} =
               Authorize.from_params(%{
                 "role" => "operator",
                 "auth" => %{"token" => "wrong-operator-secret"}
               })

      assert {:ok, ctx} =
               Authorize.from_params(%{
                 "role" => "operator",
                 "auth" => %{"token" => operator_token},
                 "client" => %{"id" => "authenticated-operator"}
               })

      assert ctx.role == :operator
      assert ctx.scopes == [:admin, :read, :write, :approvals, :pairing]
      assert ctx.client_id == "authenticated-operator"
      assert ctx.token == nil
      refute inspect(ctx) =~ operator_token
    end

    test "tokenless operator compatibility is loopback-only when no token is configured" do
      assert {:ok, %{role: :operator}} =
               Authorize.from_params(%{"role" => "operator"}, local?: true)

      assert {:error, {:unauthorized, message}} =
               Authorize.from_params(%{"role" => "operator"}, local?: false)

      assert message =~ "Operator authentication is required"
      assert message =~ "LEMON_CONTROL_PLANE_OPERATOR_TOKEN"
    end
  end

  describe "operator credential helpers" do
    test "configured_operator_token/0 trims and treats blank as unset" do
      Application.put_env(:lemon_control_plane, :operator_token, "  tok  ")
      assert Authorize.configured_operator_token() == "tok"

      Application.put_env(:lemon_control_plane, :operator_token, "   ")
      previous_env = System.get_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN")
      System.delete_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN")

      on_exit(fn ->
        if previous_env, do: System.put_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN", previous_env)
      end)

      assert Authorize.configured_operator_token() == nil
    end

    test "loopback_address?/1 accepts only direct loopback forms" do
      assert Authorize.loopback_address?({127, 0, 0, 1})
      assert Authorize.loopback_address?({127, 1, 2, 3})
      assert Authorize.loopback_address?({0, 0, 0, 0, 0, 0, 0, 1})
      assert Authorize.loopback_address?({0, 0, 0, 0, 0, 65_535, 0x7F00, 1})
      refute Authorize.loopback_address?({10, 0, 0, 1})
      refute Authorize.loopback_address?({0, 0, 0, 0, 0, 65_535, 0x0A00, 1})
      refute Authorize.loopback_address?(nil)
      refute Authorize.loopback_address?("127.0.0.1")
    end

    test "tokenless_loopback_allowed?/1 requires the explicit flag and a loopback peer" do
      previous =
        Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

      on_exit(fn ->
        Application.put_env(
          :lemon_control_plane,
          :allow_unauthenticated_loopback_operator,
          previous
        )
      end)

      Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)
      refute Authorize.tokenless_loopback_allowed?({127, 0, 0, 1})

      Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, true)
      assert Authorize.tokenless_loopback_allowed?({127, 0, 0, 1})
      refute Authorize.tokenless_loopback_allowed?({192, 168, 1, 2})
      refute Authorize.tokenless_loopback_allowed?(nil)
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

    test "native continuation and floor receipts require the actual node role and invoke scope" do
      for method <- ["node.native.followup", "node.native.lineage.floor"] do
        assert :ok =
                 Authorize.authorize(%{role: :node, scopes: [:invoke]}, method, [:invoke])

        assert {:error, {:forbidden, _}} =
                 Authorize.authorize(
                   %{role: :operator, scopes: [:admin, :invoke]},
                   method,
                   [:invoke]
                 )

        assert {:error, {:forbidden, _}} =
                 Authorize.authorize(%{role: :node, scopes: [:read]}, method, [:invoke])
      end
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
      assert Authorize.required_scopes("node.invoke.result") == [:invoke, :event]
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
