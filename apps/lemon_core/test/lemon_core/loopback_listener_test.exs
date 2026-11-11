defmodule LemonCore.LoopbackListenerTest do
  use ExUnit.Case, async: true
  alias LemonCore.LoopbackListener

  @header "sl local_address rem_address st tx_queue rx_queue tr uid timeout inode\n"
  @v4 {127, 0, 0, 1}
  @v6 {0, 0, 0, 0, 0, 0, 0, 1}
  @server {@v4, 4044}
  @client {@v4, 55000}

  @tag :tmp_dir
  test "Linux listener checks match exact address, family and port", %{tmp_dir: root} do
    opts = [os_type: {:unix, :linux}, uid: 1000, proc_root: root]
    write_proc(root, [row(@server, @client, 1001)], [row({@v6, 4044}, {@v6, 0}, 1000)])
    assert :foreign = LoopbackListener.owned_by_self?(@server, opts)
    assert :owned = LoopbackListener.owned_by_self?({@v6, 4044}, opts)
    assert :absent = LoopbackListener.owned_by_self?({@v4, 4045}, opts)
    write_proc(root, [row({{127, 0, 0, 2}, 4044}, @client, 1000)])
    assert :absent = LoopbackListener.owned_by_self?(@server, opts)
    write_proc(root, [row({{0, 0, 0, 0}, 4044}, @client, 1000)])
    assert :owned = LoopbackListener.owned_by_self?(@server, opts)
  end

  @tag :tmp_dir
  test "Linux established ownership ignores a replacement listener and other connections", %{
    tmp_dir: root
  } do
    opts = [os_type: {:unix, :linux}, uid: 1000, proc_root: root]

    write_proc(root, [
      row(@server, @client, 1000),
      row(@server, @client, 1001, "01"),
      row(@server, {@v4, 55001}, 1000, "01"),
      row(@client, @server, 1000, "01")
    ])

    assert :owned = LoopbackListener.owned_by_self?(@server, opts)
    assert :foreign = LoopbackListener.connection_owned_by_self?(@client, @server, opts)
    write_proc(root, [row(@server, @client, 1000, "01")])
    assert :owned = LoopbackListener.connection_owned_by_self?(@client, @server, opts)
    write_proc(root, [row(@server, @client, 1000)])
    assert :absent = LoopbackListener.connection_owned_by_self?(@client, @server, opts)
    write_proc(root, [row(@server, @client, 1000, "01", 0)])
    assert :absent = LoopbackListener.connection_owned_by_self?(@client, @server, opts)
  end

  @tag :tmp_dir
  test "Linux IPv6 established tuple is exact", %{tmp_dir: root} do
    opts = [os_type: {:unix, :linux}, uid: 1000, proc_root: root]
    server = {@v6, 4044}
    client = {@v6, 55000}
    write_proc(root, [], [row(server, client, 1000, "01")])
    assert :owned = LoopbackListener.connection_owned_by_self?(client, server, opts)
    assert :absent = LoopbackListener.connection_owned_by_self?({@v6, 55001}, server, opts)
  end

  @tag :tmp_dir
  test "inaccessible or malformed inspection fails closed", %{tmp_dir: root} do
    opts = [os_type: {:unix, :linux}, uid: 1000, proc_root: root]
    assert :unverifiable = LoopbackListener.owned_by_self?(@server, opts)
    malformed = String.replace_prefix(row(@server, @client, 1000), "0: ", "0: FF")
    write_proc(root, [malformed])
    assert :unverifiable = LoopbackListener.owned_by_self?(@server, opts)
    write_proc(root, ["malformed\n"])
    assert :unverifiable = LoopbackListener.owned_by_self?(@server, opts)

    assert :unverifiable =
             LoopbackListener.owned_by_self?(@server, os_type: {:win32, :nt}, uid: 1000)

    assert :unverifiable = LoopbackListener.owned_by_self?(@server, uid: :unknown)
    assert :unverifiable = LoopbackListener.peer_owned_by_self?(:invalid, :tcp)
  end

  test "lsof listener query and records match address, family and port" do
    command = fn executable, args, opts ->
      assert executable == "/usr/sbin/lsof"
      assert args == ["-nP", "-a", "-u", "1000", "-i4TCP@127.0.0.1:4044", "-sTCP:LISTEN", "-Fftn"]
      assert opts == [stderr_to_stdout: false]
      {"p123\nf8\ntIPv4\nn127.0.0.1:4044\n", 0}
    end

    opts = [os_type: {:unix, :darwin}, uid: 1000, command: command]
    assert :owned = LoopbackListener.owned_by_self?(@server, opts)

    for record <- [
          "tIPv6\nn[::1]:4044",
          "tIPv4\nn192.168.1.2:4044",
          "tIPv4\nn127.0.0.2:4044",
          "tIPv4\nn127.0.0.1:4045",
          "tIPv6\nn*:4044"
        ] do
      opts = Keyword.put(opts, :command, fn _, _, _ -> {"p123\nf8\n#{record}\n", 0} end)
      refute :owned == LoopbackListener.owned_by_self?(@server, opts)
    end
  end

  test "lsof established records require both exact endpoints, not the listener" do
    command = fn _, args, _ ->
      assert "-a" in args
      assert "-sTCP:ESTABLISHED" in args
      assert "-i4TCP@127.0.0.1:4044" in args
      {"p123\nf8\ntIPv4\nn127.0.0.1:4044->127.0.0.1:55000\n", 0}
    end

    opts = [os_type: {:unix, :darwin}, uid: 1000, command: command]
    assert :owned = LoopbackListener.connection_owned_by_self?(@client, @server, opts)

    for name <- [
          "127.0.0.1:4044",
          "127.0.0.1:4044->127.0.0.1:55001",
          "127.0.0.1:55000->127.0.0.1:4044"
        ] do
      opts = Keyword.put(opts, :command, fn _, _, _ -> {"p123\nf8\ntIPv4\nn#{name}\n", 0} end)
      refute :owned == LoopbackListener.connection_owned_by_self?(@client, @server, opts)
    end

    opts = Keyword.put(opts, :command, fn _, _, _ -> {"", 1} end)
    assert :foreign = LoopbackListener.connection_owned_by_self?(@client, @server, opts)
  end

  test "lsof probe uses only the requested endpoint and failures fail closed" do
    for result <- [:foreign, :absent, :unverifiable] do
      assert ^result =
               LoopbackListener.owned_by_self?(@server,
                 os_type: {:unix, :darwin},
                 uid: 1000,
                 command: fn _, _, _ -> {"", 1} end,
                 probe: fn endpoint ->
                   assert endpoint == @server
                   result
                 end
               )
    end

    for response <- [
          {"", 0},
          {"not-a-record", 0},
          {"p123\nf8\ntIPv4\nn127.0.0.1:4044\nunexpected\n", 0},
          {"", 2}
        ] do
      assert :unverifiable =
               LoopbackListener.owned_by_self?(@server,
                 os_type: {:unix, :darwin},
                 uid: 1000,
                 command: fn _, _, _ -> response end,
                 probe: fn _ -> flunk("inspection failure must not probe") end
               )
    end
  end

  test "real established socket remains owned after the listener closes" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: @v4, active: false])
    {:ok, endpoint} = :inet.sockname(listener)
    {:ok, client} = :gen_tcp.connect(@v4, elem(endpoint, 1), [:binary, active: false])
    {:ok, server} = :gen_tcp.accept(listener)
    on_exit(fn -> Enum.each([listener, client, server], &:gen_tcp.close/1) end)
    assert :owned = LoopbackListener.owned_by_self?(endpoint)
    :gen_tcp.close(listener)
    assert :owned = LoopbackListener.peer_owned_by_self?(client, :tcp)
  end

  test "literal loopback detection never resolves DNS" do
    for host <- ["127.0.0.1", "127.9.8.7", "::1", "[::1]", "::ffff:127.0.0.1"],
        do: assert(LoopbackListener.literal_loopback?(host))

    for host <- [nil, "localhost", "127.0.0.1.example", "192.168.1.1", "::", "::2", "127.1"],
        do: refute(LoopbackListener.literal_loopback?(host))
  end

  defp write_proc(root, v4, v6 \\ []) do
    File.mkdir_p!(Path.join(root, "net"))
    File.write!(Path.join(root, "net/tcp"), [@header | v4])
    File.write!(Path.join(root, "net/tcp6"), [@header | v6])
  end

  defp endpoint({address, port}) do
    bytes =
      if tuple_size(address) == 4 do
        address |> Tuple.to_list() |> :binary.list_to_bin()
      else
        for word <- Tuple.to_list(address), into: <<>>, do: <<word::16>>
      end

    encoded =
      for <<word::32 <- bytes>>, into: <<>>, do: <<word::native-unsigned-integer-size(32)>>

    Base.encode16(encoded) <> ":" <> (port |> Integer.to_string(16) |> String.pad_leading(4, "0"))
  end

  defp row(local, remote, uid, state \\ "0A", inode \\ 1),
    do:
      "0: #{endpoint(local)} #{endpoint(remote)} #{state} 00000000:00000000 00:00000000 00000000 #{uid} 0 #{inode}\n"
end
