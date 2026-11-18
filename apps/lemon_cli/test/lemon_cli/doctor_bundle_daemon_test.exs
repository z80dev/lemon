defmodule LemonCli.DoctorBundleDaemonTest do
  @moduledoc """
  `lemon doctor --bundle` runs in a one-shot VM. When a daemon answers its
  health probe, the runtime sections must come from that daemon (through the
  `doctor.bundle` control-plane method), not from local probes that report the
  one-shot VM's own `running: false`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI

  defmodule DaemonClient do
    def request(method, params, opts \\ []) do
      send(Process.get(:doctor_bundle_test_owner) || self(), {:rpc, method, params, opts})

      {:ok,
       %{
         "entries" => %{
           "media_diagnostics.json" => %{
             "worker_status" => %{"supervised" => true, "running" => true, "workers" => 2},
             "jobs_dir" => "/Users/alice/.lemon/media"
           },
           "memory_diagnostics.json" => %{"provider_count" => 1, "running" => true},
           "channel_diagnostics.json" => %{
             "transports" => [%{"transport" => "telegram", "allowed_chat_ids" => [987_654_321]}]
           },
           "../escape.json" => %{"evil" => true}
         }
       }}
    end
  end

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_cli_bundle_daemon_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, "home"))
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)
    server = spawn_link(fn -> serve_health(listener) end)

    env = Map.new(~w(LEMON_CONTROL_PLANE_PORT HOME), &{&1, System.get_env(&1)})
    System.put_env("LEMON_CONTROL_PLANE_PORT", Integer.to_string(port))
    System.put_env("HOME", Path.join(tmp_dir, "home"))

    previous_client = Application.fetch_env(:lemon_cli, :control_plane_client)
    Application.put_env(:lemon_cli, :control_plane_client, DaemonClient)
    Process.put(:doctor_bundle_test_owner, self())

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)

      Enum.each(env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      case previous_client do
        {:ok, value} -> Application.put_env(:lemon_cli, :control_plane_client, value)
        :error -> Application.delete_env(:lemon_cli, :control_plane_client)
      end
    end)

    %{tmp_dir: tmp_dir}
  end

  test "with a running daemon the bundle carries the daemon's runtime sections",
       %{tmp_dir: tmp_dir} do
    bundle_path = Path.join(tmp_dir, "bundle.zip")

    capture_io(fn ->
      capture_io(:stderr, fn ->
        CLI.run(["doctor", "--bundle", bundle_path, "--project-dir", tmp_dir])
      end)
    end)

    assert_received {:rpc, "doctor.bundle", _params, _opts}
    assert {:ok, entries} = :zip.extract(String.to_charlist(bundle_path), [:memory])
    names = Enum.map(entries, fn {name, _} -> List.to_string(name) end)
    refute Enum.any?(names, &String.contains?(&1, ".."))

    media = json(entries, "media_diagnostics.json")
    assert media["worker_status"]["running"] == true
    assert media["worker_status"]["workers"] == 2

    manifest = json(entries, "manifest.json")
    assert manifest["runtime_source"] == "daemon"

    for {name, content} <- entries do
      text = IO.iodata_to_binary(content)
      refute text =~ "/Users/alice", "#{name} leaks a daemon path"
      refute text =~ tmp_dir, "#{name} leaks a client path"
      refute text =~ "allowed_chat_ids", "#{name} leaks chat ids"
      refute text =~ "987654321", "#{name} leaks chat ids"
    end
  end

  test "lemon doctor text output applies the sharing policy", %{tmp_dir: tmp_dir} do
    previous = System.get_env("LEMON_PATH")
    System.put_env("LEMON_PATH", "/workspace")

    on_exit(fn ->
      if previous,
        do: System.put_env("LEMON_PATH", previous),
        else: System.delete_env("LEMON_PATH")
    end)

    output =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          CLI.run(["doctor", "--verbose", "--project-dir", tmp_dir])
        end)
      end)

    assert output =~ "runtime.lemon_root"
    refute output =~ "/workspace"
    refute output =~ tmp_dir
  end

  defp json(entries, name) do
    {_, content} = Enum.find(entries, fn {entry, _} -> entry == String.to_charlist(name) end)
    content |> IO.iodata_to_binary() |> Jason.decode!()
  end

  defp serve_health(listener) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        _ = :gen_tcp.recv(socket, 0, 1_000)
        body = ~s({"ok":true})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
        )

        :gen_tcp.close(socket)
        serve_health(listener)

      {:error, _} ->
        :ok
    end
  end
end
