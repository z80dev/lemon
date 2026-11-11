defmodule LemonMCP.HTTP.OriginPolicyLoopbackTest do
  use ExUnit.Case, async: false

  alias LemonMCP.HTTP.OriginPolicy

  setup do
    original = Application.fetch_env(:lemon_core, :require_owned_loopback)
    Application.put_env(:lemon_core, :require_owned_loopback, true)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:lemon_core, :require_owned_loopback, value)
        :error -> Application.delete_env(:lemon_core, :require_owned_loopback)
      end
    end)
  end

  test "approved loopback origins fail closed for every non-owned result" do
    for origin <- ["http://127.0.0.1:4100", "http://[::1]:4100", "http://[::ffff:127.0.0.1]:4100"],
        ownership <- [:foreign, :absent, :unverifiable] do
      assert {:error, :private_origin_not_owned} =
               OriginPolicy.pin(origin <> "/mcp?invocation=secret", approved(origin),
                 listener_owner: fn {_address, 4100} -> ownership end
               )
    end
  end

  test "owned loopback origins retain the original URL and destination pin" do
    origin = "http://127.0.0.1:4100"
    url = origin <> "/mcp"

    assert {:ok, %{url: ^url, origin: ^origin, port: 4100, address: {127, 0, 0, 1}}} =
             OriginPolicy.pin(url, approved(origin),
               listener_owner: fn {{127, 0, 0, 1}, 4100} -> :owned end
             )
  end

  test "ownership is checked per pin, including default ports" do
    parent = self()

    check = fn {address, port} ->
      send(parent, {:checked, address, port})
      :owned
    end

    for _ <- 1..2 do
      assert {:ok, %{port: 80}} =
               OriginPolicy.pin("http://127.0.0.1/mcp", approved("http://127.0.0.1"),
                 listener_owner: check
               )

      assert_receive {:checked, {127, 0, 0, 1}, 80}
    end

    assert {:ok, %{port: 443}} =
             OriginPolicy.pin("https://[::1]/mcp", approved("https://[::1]"),
               listener_owner: check
             )

    assert_receive {:checked, {0, 0, 0, 0, 0, 0, 0, 1}, 443}
  end

  test "ownership never bypasses origin allowlists or private approval" do
    origin = "http://127.0.0.1:4100"
    opts = [listener_owner: fn _ -> flunk("authorization must reject before ownership") end]

    assert {:error, :origin_not_allowed} =
             OriginPolicy.pin(origin <> "/mcp", %{allowed_origins: []}, opts)

    assert {:error, :destination_not_public} =
             OriginPolicy.pin(origin <> "/mcp", %{allowed_origins: [origin]}, opts)

    assert {:error, :invalid_url} =
             OriginPolicy.pin("http://user:secret@127.0.0.1:4100/mcp", approved(origin), opts)
  end

  test "DNS, non-loopback private origins, public literals and legacy policy are unchanged" do
    opts = [
      listener_owner: fn _ -> flunk("not an approved literal-loopback origin") end,
      resolver: fn "localhost" -> {:ok, [{127, 0, 0, 1}]} end
    ]

    for origin <- ["http://localhost:4100", "http://192.168.1.2:4100", "https://93.184.216.34"] do
      assert {:ok, _} = OriginPolicy.pin(origin <> "/mcp", approved(origin), opts)
    end

    assert {:ok, nil} = OriginPolicy.pin("http://127.0.0.1:4100/mcp", nil, opts)
  end

  test "the explicit worker opt-out disables listener inspection" do
    Application.put_env(:lemon_core, :require_owned_loopback, false)
    origin = "http://127.0.0.1:4100"

    assert {:ok, _} =
             OriginPolicy.pin(origin <> "/mcp", approved(origin),
               listener_owner: fn _ -> flunk("guard is disabled") end
             )
  end

  test "pins a real loopback listener owned by the executing user" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    origin = "http://127.0.0.1:#{port}"

    case :os.type() do
      {:unix, os} when os in [:linux, :darwin, :freebsd, :openbsd, :netbsd, :dragonfly] ->
        assert {:ok, %{port: ^port}} = OriginPolicy.pin(origin <> "/mcp", approved(origin))

      _ ->
        assert {:error, :private_origin_not_owned} =
                 OriginPolicy.pin(origin <> "/mcp", approved(origin))
    end
  end

  defp approved(origin), do: %{allowed_origins: [origin], approved_private_origins: [origin]}
end
