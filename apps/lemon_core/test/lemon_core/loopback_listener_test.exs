defmodule LemonCore.LoopbackListenerTest do
  use ExUnit.Case, async: true

  alias LemonCore.LoopbackListener

  @header "  sl  local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n"
  @uid 1000
  @port 4044

  @tag :tmp_dir
  test "classifies owned, foreign and absent Linux listeners", %{tmp_dir: root} do
    opts = [os_type: {:unix, :linux}, uid: @uid, proc_root: root]
    write_proc(root, [row(ipv4(127, 0, 0, 1), @port, @uid)])
    assert :owned = LoopbackListener.owned_by_self?(@port, opts)
    assert :absent = LoopbackListener.owned_by_self?(@port + 1, opts)

    write_proc(root, [row(ipv4(127, 0, 0, 1), @port, @uid + 1)])
    assert :foreign = LoopbackListener.owned_by_self?(@port, opts)

    write_proc(root, [row(ipv4(127, 0, 0, 1), @port, @uid, "01")])
    assert :absent = LoopbackListener.owned_by_self?(@port, opts)
  end

  @tag :tmp_dir
  test "includes IPv6 and wildcard listeners and refuses mixed ownership", %{tmp_dir: root} do
    opts = [os_type: {:unix, :linux}, uid: @uid, proc_root: root]

    for address <- [<<0::120, 1>>, <<0::128>>, <<0::80, 0xFFFF::16, 127, 0, 0, 1>>] do
      write_proc(root, [], [row(address, @port, @uid)])
      assert :owned = LoopbackListener.owned_by_self?(@port, opts)
    end

    write_proc(root, [row(ipv4(0, 0, 0, 0), @port, @uid)])
    assert :owned = LoopbackListener.owned_by_self?(@port, opts)

    write_proc(root, [row(ipv4(127, 0, 0, 1), @port, @uid)], [row(<<0::120, 1>>, @port, @uid + 1)])

    assert :foreign = LoopbackListener.owned_by_self?(@port, opts)

    write_proc(root, [row(ipv4(192, 168, 1, 1), @port, @uid)])
    assert :absent = LoopbackListener.owned_by_self?(@port, opts)
  end

  @tag :tmp_dir
  test "fails closed on inaccessible or malformed proc data", %{tmp_dir: root} do
    opts = [os_type: {:unix, :linux}, uid: @uid, proc_root: root]
    assert :unverifiable = LoopbackListener.owned_by_self?(@port, opts)

    write_proc(root, ["malformed\n"])
    assert :unverifiable = LoopbackListener.owned_by_self?(@port, opts)

    write_proc(root, [row(ipv4(127, 0, 0, 1), @port, @uid)])
    File.write!(Path.join(root, "net/tcp6"), "invalid header\n")
    assert :unverifiable = LoopbackListener.owned_by_self?(@port, opts)

    File.rm!(Path.join(root, "net/tcp6"))
    assert :owned = LoopbackListener.owned_by_self?(@port, opts)
  end

  test "lsof is restricted to the current uid and listening port" do
    command = fn executable, args, opts ->
      assert executable == "/usr/sbin/lsof"
      assert args == ["-nP", "-a", "-u", "1000", "-iTCP:4044", "-sTCP:LISTEN", "-t"]
      assert opts == [stderr_to_stdout: false]
      {"123\n456\n", 0}
    end

    assert :owned =
             LoopbackListener.owned_by_self?(@port,
               os_type: {:unix, :darwin},
               uid: @uid,
               command: command
             )
  end

  test "empty lsof results distinguish foreign listeners from absence" do
    for result <- [:foreign, :absent, :unverifiable] do
      assert ^result =
               LoopbackListener.owned_by_self?(@port,
                 os_type: {:unix, :freebsd},
                 uid: @uid,
                 command: fn _, _, _ -> {"", 1} end,
                 probe: fn port ->
                   assert port == @port
                   result
                 end
               )
    end
  end

  test "inspection failures never turn into ownership or absence" do
    for response <- [{"", 0}, {"not-a-pid", 0}, {"", 2}] do
      assert :unverifiable =
               LoopbackListener.owned_by_self?(@port,
                 os_type: {:unix, :darwin},
                 uid: @uid,
                 command: fn _, _, _ -> response end,
                 probe: fn _ -> flunk("failed inspection must not probe") end
               )
    end

    assert :unverifiable =
             LoopbackListener.owned_by_self?(@port, os_type: {:win32, :nt}, uid: @uid)

    assert :unverifiable = LoopbackListener.owned_by_self?(@port, uid: :unknown)

    for port <- [0, -1, 65_536, nil, "4044"],
        do: assert(:unverifiable == LoopbackListener.owned_by_self?(port))
  end

  test "an unattributed live socket is foreign, not owned" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    opts = [os_type: {:unix, :darwin}, uid: @uid, command: fn _, _, _ -> {"", 1} end]

    assert :foreign = LoopbackListener.owned_by_self?(port, opts)
    :gen_tcp.close(listener)
    assert :absent = LoopbackListener.owned_by_self?(port, opts)
  end

  test "recognizes a live listener owned by this user" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)

    case :os.type() do
      {:unix, os} when os in [:linux, :darwin, :freebsd, :openbsd, :netbsd, :dragonfly] ->
        assert :owned = LoopbackListener.owned_by_self?(port)

      _ ->
        assert :unverifiable = LoopbackListener.owned_by_self?(port)
    end
  end

  test "literal loopback detection never resolves DNS" do
    for host <- ["127.0.0.1", "127.9.8.7", "::1", "[::1]", "::ffff:127.0.0.1"] do
      assert LoopbackListener.literal_loopback?(host)
    end

    for host <- [nil, "localhost", "127.0.0.1.example", "192.168.1.1", "::", "::2", "127.1"] do
      refute LoopbackListener.literal_loopback?(host)
    end
  end

  defp write_proc(root, v4, v6 \\ []) do
    File.mkdir_p!(Path.join(root, "net"))
    File.write!(Path.join(root, "net/tcp"), [@header | v4])
    File.write!(Path.join(root, "net/tcp6"), [@header | v6])
  end

  defp ipv4(a, b, c, d), do: <<a, b, c, d>>

  defp row(address, port, uid, state \\ "0A") do
    encoded =
      for <<word::32 <- address>>, into: <<>>, do: <<word::native-unsigned-integer-size(32)>>

    hex_port = port |> Integer.to_string(16) |> String.pad_leading(4, "0")

    "0: #{Base.encode16(encoded)}:#{hex_port} 00000000:0000 #{state} 00000000:00000000 00:00000000 00000000 #{uid} 0 1\n"
  end
end
