defmodule LemonCore.Runtime.EnvTest do
  # async: false — tests call System.put_env/delete_env which mutates shared process state
  use ExUnit.Case, async: false

  alias LemonCore.Runtime.Env

  describe "resolve/0" do
    test "returns default ports when env vars are unset" do
      clear_env(["LEMON_CONTROL_PLANE_PORT", "LEMON_WEB_PORT", "LEMON_SIM_UI_PORT"])

      env = Env.resolve()

      assert env.control_port == 4040
      assert env.web_port == 4080
      assert env.sim_port == 4090
    end

    test "reads ports from environment variables" do
      System.put_env("LEMON_CONTROL_PLANE_PORT", "5050")
      System.put_env("LEMON_WEB_PORT", "5080")
      System.put_env("LEMON_SIM_UI_PORT", "5090")

      env = Env.resolve()

      assert env.control_port == 5050
      assert env.web_port == 5080
      assert env.sim_port == 5090
    after
      clear_env(["LEMON_CONTROL_PLANE_PORT", "LEMON_WEB_PORT", "LEMON_SIM_UI_PORT"])
    end

    test "falls back to defaults for malformed port values" do
      System.put_env("LEMON_CONTROL_PLANE_PORT", "not_a_port")

      env = Env.resolve()

      assert env.control_port == 4040
    after
      System.delete_env("LEMON_CONTROL_PLANE_PORT")
    end
  end

  describe "debug?/0" do
    test "returns false when debug vars are absent" do
      clear_env(["LEMON_DEBUG", "LEMON_LOG_LEVEL"])
      refute Env.debug?()
    end

    test "returns true when LEMON_DEBUG=1" do
      System.put_env("LEMON_DEBUG", "1")
      assert Env.debug?()
    after
      System.delete_env("LEMON_DEBUG")
    end

    test "returns true when LEMON_LOG_LEVEL=debug" do
      System.put_env("LEMON_LOG_LEVEL", "debug")
      assert Env.debug?()
    after
      System.delete_env("LEMON_LOG_LEVEL")
    end
  end

  describe "node_name/0" do
    test "returns default when env var is unset" do
      System.delete_env("LEMON_GATEWAY_NODE_NAME")
      assert Env.node_name() == "lemon"
    end

    test "reads from LEMON_GATEWAY_NODE_NAME" do
      System.put_env("LEMON_GATEWAY_NODE_NAME", "mynode")
      assert Env.node_name() == "mynode"
    after
      System.delete_env("LEMON_GATEWAY_NODE_NAME")
    end
  end

  describe "node_cookie/0" do
    test "returns default when env vars are unset" do
      clear_env(["LEMON_GATEWAY_NODE_COOKIE", "LEMON_GATEWAY_COOKIE"])
      assert Env.node_cookie() == "lemon_gateway_dev_cookie"
    end

    test "reads from LEMON_GATEWAY_NODE_COOKIE" do
      System.put_env("LEMON_GATEWAY_NODE_COOKIE", "mysecret")
      assert Env.node_cookie() == "mysecret"
    after
      System.delete_env("LEMON_GATEWAY_NODE_COOKIE")
    end
  end

  describe "require_prod_cookie!/0" do
    test "raises when no cookie env var is set (dev default would be used)" do
      clear_env(["LEMON_GATEWAY_NODE_COOKIE", "LEMON_GATEWAY_COOKIE"])

      assert_raise RuntimeError, ~r/production.*cookie/i, fn ->
        Env.require_prod_cookie!()
      end
    end

    test "succeeds when a non-default cookie is configured" do
      System.put_env("LEMON_GATEWAY_NODE_COOKIE", "my-strong-secret-cookie")

      assert :ok = Env.require_prod_cookie!()
    after
      System.delete_env("LEMON_GATEWAY_NODE_COOKIE")
    end
  end

  describe "apply_ports/1" do
    test "apply_web_port preserves existing :http options beyond ip and port" do
      # Set up a pre-existing :http config with extra transport options
      Application.put_env(:lemon_web, LemonWeb.Endpoint,
        http: [transport_options: [num_acceptors: 10], keyfile: "priv/cert/key.pem"]
      )

      env = %Env{
        control_port: 4040,
        web_port: 9090,
        sim_port: 4090
      }

      Env.apply_ports(env)

      result = Application.get_env(:lemon_web, LemonWeb.Endpoint, [])
      http = Keyword.get(result, :http, [])

      assert http[:port] == 9090
      assert http[:ip] == {127, 0, 0, 1}
      # Extra options must survive the port apply
      assert http[:transport_options] == [num_acceptors: 10]
      assert http[:keyfile] == "priv/cert/key.pem"
    after
      Application.delete_env(:lemon_web, LemonWeb.Endpoint)
    end
  end

  defp clear_env(keys) do
    Enum.each(keys, &System.delete_env/1)
  end
end
