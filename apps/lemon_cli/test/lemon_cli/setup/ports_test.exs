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
end
