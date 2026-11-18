defmodule LemonCli.Setup.OmpSetupTest do
  use ExUnit.Case, async: false

  alias LemonAi.Auth.OmpAuthBroker
  alias LemonCli.Onboarding.Runner
  alias LemonCli.Setup.Omp

  @anthropic_access "sk-ant-oat01-omp-setup-synthetic"
  @codex_access "codex-access-omp-setup-synthetic"

  defmodule FakeSecrets do
    def status, do: %{configured: true}

    def set(name, value) do
      send(self(), {:secret, name, value})
      {:ok, name}
    end
  end

  setup do
    Runner.ensure_required_apps!()

    dir =
      Path.join(System.tmp_dir!(), "lemon_cli_omp_setup_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    env = Map.new(~w(OMP_AUTH_BROKER_URL OMP_AUTH_BROKER_TOKEN), &{&1, System.get_env(&1)})
    System.delete_env("OMP_AUTH_BROKER_URL")
    System.put_env("OMP_AUTH_BROKER_TOKEN", "broker-bearer")

    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    OmpAuthBroker.invalidate_all()

    {:ok, broker} = Agent.start_link(fn -> %{up: true, installs: []} end)

    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        not Agent.get(broker, & &1.up) ->
          Req.Test.transport_error(conn, :econnrefused)

        conn.request_path == "/v1/healthz" ->
          Req.Test.json(conn, %{"ok" => true, "version" => "18.0.0"})

        conn.request_path == "/v1/snapshot" ->
          Req.Test.json(conn, snapshot())
      end
    end)

    on_exit(fn ->
      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Req.default_options(previous)
      Req.Test.set_req_test_to_private(%{})
      OmpAuthBroker.invalidate_all()
      File.rm_rf!(dir)
    end)

    config_path = Path.join(dir, "config.toml")

    File.write!(config_path, """
    # keep this comment
    [providers.openai-codex]
    auth_source = "oauth"
    oauth_secret = "llm_openai_codex_api_key"
    """)

    install = fn roles, opts ->
      Agent.update(broker, &%{&1 | up: true, installs: [{roles, opts} | &1.installs]})
      {:ok, %{units: [%{role: "omp-broker", state: "ready", detail: nil}]}}
    end

    %{dir: dir, config_path: config_path, broker: broker, install: install}
  end

  test "non-interactive setup starts the broker service and connects omp's usable providers",
       ctx do
    Agent.update(ctx.broker, &%{&1 | up: false})
    omp = fake_omp(ctx.dir)
    model = anthropic_model()
    {io, output} = recording_io()

    assert :ok =
             Omp.run(
               [
                 "-n",
                 "--all",
                 "--model",
                 "anthropic:#{model}",
                 "--skip-verify",
                 "--config-path",
                 ctx.config_path
               ],
               io,
               omp_bin: omp,
               service_install: ctx.install,
               port_free?: fn 8765 -> true end
             )

    assert [{["omp-broker"], install_opts}] = Agent.get(ctx.broker, & &1.installs)
    assert install_opts[:omp_bin] == omp
    assert install_opts[:port] == 8765

    config = File.read!(ctx.config_path)
    assert config =~ "# keep this comment"
    decoded = Toml.decode!(config)
    assert decoded["providers"]["anthropic"]["auth_source"] == "omp_broker"
    assert decoded["providers"]["openai-codex"]["auth_source"] == "omp_broker"
    # Lemon's own login stays referenced so disconnect can restore it.
    assert decoded["providers"]["openai-codex"]["oauth_secret"] == "llm_openai_codex_api_key"
    # omp's Copilot sign-in has no Lemon shape: it is reported, never saved.
    refute Map.has_key?(decoded["providers"], "github_copilot")
    assert decoded["defaults"] == %{"provider" => "anthropic", "model" => "anthropic:#{model}"}

    text = output.()
    assert text =~ "Skipping GitHub Copilot"
    assert text =~ "cursor"
    assert text =~ "no matching Lemon provider"
    refute text =~ @anthropic_access
    refute text =~ @codex_access
    refute text =~ "me@example.com"
  end

  test "another program on the default port moves the broker and Lemon remembers where", ctx do
    Agent.update(ctx.broker, &%{&1 | up: false})
    {io, output} = recording_io()

    assert :ok =
             Omp.run(
               [
                 "-n",
                 "--provider",
                 "anthropic",
                 "--skip-verify",
                 "--config-path",
                 ctx.config_path
               ],
               io,
               omp_bin: fake_omp(ctx.dir),
               service_install: ctx.install,
               port_free?: &(&1 != 8765),
               secrets: __MODULE__.FakeSecrets
             )

    assert [{["omp-broker"], install_opts}] = Agent.get(ctx.broker, & &1.installs)
    port = install_opts[:port]
    assert port != 8765
    assert_received {:secret, "OMP_AUTH_BROKER_URL", url}
    assert url == "http://127.0.0.1:#{port}"
    assert output.() =~ "127.0.0.1:8765 is in use by another program"
  end

  test "an explicit --port that is in use fails before installing anything", ctx do
    Agent.update(ctx.broker, &%{&1 | up: false})
    {io, _output} = recording_io()

    assert_raise Mix.Error, ~r/127.0.0.1:9123 is in use/, fn ->
      Omp.run(["-n", "--all", "--port", "9123", "--config-path", ctx.config_path], io,
        omp_bin: fake_omp(ctx.dir),
        service_install: ctx.install,
        port_free?: fn 9123 -> false end
      )
    end

    assert Agent.get(ctx.broker, & &1.installs) == []
  end

  test "an unreachable custom broker URL fails without installing a service", ctx do
    Agent.update(ctx.broker, &%{&1 | up: false})
    System.put_env("OMP_AUTH_BROKER_URL", "http://broker.tailnet:8765")
    {io, _output} = recording_io()

    assert_raise Mix.Error, ~r/OMP_AUTH_BROKER_URL is unreachable/, fn ->
      Omp.run(["-n", "--all", "--config-path", ctx.config_path], io,
        omp_bin: fake_omp(ctx.dir),
        service_install: ctx.install
      )
    end

    assert Agent.get(ctx.broker, & &1.installs) == []
    refute File.read!(ctx.config_path) =~ "omp_broker"
  end

  test "interactive setup picks providers one by one and the default model", ctx do
    model = anthropic_model()
    {io, _output} = recording_io()

    io =
      Map.put(io, :select, fn
        %{title: "Use omp's credentials in Lemon"} -> {:ok, :each}
        %{title: "Use omp's Anthropic credential?"} -> {:ok, true}
        %{title: "Use omp's" <> _} -> {:ok, false}
        %{title: "Default model", options: options} -> {:ok, find_value(options, "anthropic")}
        %{title: "Choose Anthropic Model"} -> {:ok, model}
      end)

    assert :ok = Omp.run(["--skip-verify", "--config-path", ctx.config_path], io, [])

    decoded = Toml.decode!(File.read!(ctx.config_path))
    assert decoded["providers"]["anthropic"]["auth_source"] == "omp_broker"
    assert decoded["providers"]["openai-codex"]["auth_source"] == "oauth"
    assert decoded["defaults"]["model"] == "anthropic:#{model}"
  end

  test "disconnect restores Lemon's own login and status reports the connection", ctx do
    {io, _output} = recording_io()

    assert :ok =
             Omp.run(
               [
                 "-n",
                 "--provider",
                 "openai-codex",
                 "--provider",
                 "anthropic",
                 "--skip-verify",
                 "--config-path",
                 ctx.config_path
               ],
               io,
               []
             )

    {io, output} = recording_io()

    assert :ok =
             Omp.run(["status", "--config-path", ctx.config_path], io,
               service_status: fn ["omp-broker"], _ ->
                 {:ok, %{units: [%{state: "ready"}]}}
               end
             )

    assert output.() =~ "openai-codex: ready"

    assert :ok =
             Omp.run(["disconnect", "--all", "--config-path", ctx.config_path], io, [])

    providers = Toml.decode!(File.read!(ctx.config_path))["providers"]

    assert providers["openai-codex"] == %{
             "auth_source" => "oauth",
             "oauth_secret" => "llm_openai_codex_api_key"
           }

    # A table that only selected the broker is removed rather than left invalid.
    refute Map.has_key?(providers, "anthropic")
  end

  defp snapshot do
    now = System.system_time(:millisecond)

    oauth = fn id, provider, access ->
      %{
        "id" => id,
        "provider" => provider,
        "identityKey" => "email:me@example.com",
        "rotatesInMs" => nil,
        "credential" => %{
          "type" => "oauth",
          "access" => access,
          "refresh" => "__remote__",
          "expires" => now + 3_600_000
        }
      }
    end

    %{
      "generation" => 1,
      "generatedAt" => now,
      "serverNowMs" => now,
      "refresher" => %{
        "enabled" => true,
        "intervalMs" => 60_000,
        "skewMs" => 300_000,
        "nextSweepInMs" => 1_000
      },
      "credentials" => [
        oauth.(1, "anthropic", @anthropic_access),
        oauth.(2, "openai-codex", @codex_access),
        oauth.(3, "github-copilot", "copilot-access"),
        oauth.(4, "cursor", "cursor-access")
      ]
    }
  end

  defp anthropic_model do
    LemonAi.Models.get_models(:anthropic) |> hd() |> Map.fetch!(:id)
  end

  defp find_value(options, needle) do
    Enum.find_value(options, fn %{label: label, value: value} ->
      if String.contains?(String.downcase(label), needle), do: value
    end)
  end

  defp fake_omp(dir) do
    omp = Path.join(dir, "omp")
    File.write!(omp, "#!/bin/sh\nexit 0\n")
    File.chmod!(omp, 0o700)
    omp
  end

  defp recording_io do
    {:ok, log} = Agent.start_link(fn -> [] end)
    record = fn message -> Agent.update(log, &[message | &1]) end

    io = %{
      info: record,
      error: record,
      prompt: fn _ -> flunk("unexpected prompt") end,
      secret: fn _ -> flunk("unexpected secret prompt") end
    }

    {io, fn -> log |> Agent.get(& &1) |> Enum.reverse() |> Enum.join("\n") end}
  end
end
