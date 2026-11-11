defmodule LemonCli.Setup.PortsTest do
  use ExUnit.Case, async: true

  alias LemonCli.Setup.Ports

  test "a listening port is not free; the same port is free once released" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)

    refute Ports.free?(port)

    :gen_tcp.close(socket)
    assert Ports.free?(port)
  end

  test "suggestions skip busy and reserved ports and stay near the original" do
    assert Ports.suggest(4040, [4041], &(&1 != 4042)) == 4043
    assert Ports.suggest(4040, [], fn _ -> false end) == nil
    assert Ports.suggest(65_535, [], fn _ -> true end) == nil
  end

  test "suggestions automatically reserve default node gateway port 4044" do
    # 4040 base, 4041-4043 reserved; 4044 is the default node gateway port so it must be skipped
    assert Ports.suggest(4040, [4041, 4042, 4043], fn _ -> true end) == 4045
  end

  test "suggestions for 4044 itself do not self-reserve" do
    assert Ports.suggest(4044, [], fn _ -> true end) == 4045
  end

  test "defaults, requirements, and labels" do
    assert Ports.default_node_port() == 4044
    assert Ports.required(:runtime_full) == [:control, :node, :web]
    assert Ports.required(:runtime_min) == [:control, :node]
    assert Ports.label(:control) == "control plane"
    assert Ports.label(:node) == "node gateway"
    assert Ports.label(:web) == "web UI"
    assert Ports.label(:sim) == "sim UI"
  end

  test "save persists default ports without LEMON_CONTROL_PLANE_NODE_PORT", %{test: test} do
    tmp = Path.join(System.tmp_dir!(), "ports_test_#{test}_default.env")
    on_exit(fn -> File.rm(tmp) end)

    assert {:ok, ^tmp} = Ports.save(%{control: 4040, web: 4080, sim: 4090}, ports_path: tmp)
    content = File.read!(tmp)

    assert content =~ "LEMON_CONTROL_PLANE_PORT=4040\n"
    assert content =~ "LEMON_WEB_PORT=4080\n"
    assert content =~ "LEMON_SIM_UI_PORT=4090\n"
    refute content =~ "LEMON_CONTROL_PLANE_NODE_PORT"
  end

  test "save does not persist LEMON_CONTROL_PLANE_NODE_PORT when port is default 4044", %{
    test: test
  } do
    tmp = Path.join(System.tmp_dir!(), "ports_test_#{test}_4044.env")
    on_exit(fn -> File.rm(tmp) end)

    assert {:ok, ^tmp} =
             Ports.save(%{control: 4040, node: 4044, web: 4080, sim: 4090}, ports_path: tmp)

    content = File.read!(tmp)
    refute content =~ "LEMON_CONTROL_PLANE_NODE_PORT"
  end

  test "save persists LEMON_CONTROL_PLANE_NODE_PORT when a different port is chosen", %{
    test: test
  } do
    tmp = Path.join(System.tmp_dir!(), "ports_test_#{test}_override.env")

    on_exit(fn ->
      File.rm(tmp)
      System.delete_env("LEMON_CONTROL_PLANE_NODE_PORT")
    end)

    assert {:ok, ^tmp} =
             Ports.save(%{control: 4040, node: 4045, web: 4080, sim: 4090}, ports_path: tmp)

    content = File.read!(tmp)
    assert content =~ "LEMON_CONTROL_PLANE_NODE_PORT=4045\n"
    assert System.get_env("LEMON_CONTROL_PLANE_NODE_PORT") == "4045"
  end

  test "save persists an explicitly disabled node gateway as 0", %{test: test} do
    tmp = Path.join(System.tmp_dir!(), "ports_test_#{test}_disabled.env")

    on_exit(fn ->
      File.rm(tmp)
      System.delete_env("LEMON_CONTROL_PLANE_NODE_PORT")
    end)

    assert {:ok, ^tmp} =
             Ports.save(%{control: 4040, node: 0, web: 4080, sim: 4090}, ports_path: tmp)

    assert File.read!(tmp) =~ "LEMON_CONTROL_PLANE_NODE_PORT=0\n"
    assert System.get_env("LEMON_CONTROL_PLANE_NODE_PORT") == "0"
  end
end
