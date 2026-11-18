defmodule LemonCore.Doctor.SupportBundleRedactionTest do
  @moduledoc """
  Support bundles and `lemon doctor --json` are attached to public issues, so
  every emitted entry must be free of absolute paths, chat/guild ids and
  exception text, whatever the sections' producers return.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Doctor
  alias LemonCore.Doctor.{Check, Report, SupportBundle}

  @alice_home "/Users/alice"
  @alice_store "/Users/alice/.lemon/store"
  @chat_id "987654321"
  @guild_id "112233445566778899"

  # Values that must never appear in any shared output.
  @secrets [
    "skb-private-0123456789abcdef",
    "hunter2",
    "opaque-header-value",
    "X-Private-Header",
    "+15551234567",
    "15557654321",
    "bob@example.com",
    "carol@example.com",
    "alice-omp-account",
    "private.internal.example",
    "alice-kanban-owner",
    "Secret Column",
    "private-shot-name.png",
    "private-mcp-server",
    "customer.private.example",
    "alice-private-pool"
  ]

  # Producers owned by other apps return absolute directories; the bundle must
  # not pass them through.
  defmodule PathyBrowserArtifacts do
    def default_dir(project_dir), do: Path.join([project_dir, ".lemon", "browser"])
    def summary(opts), do: %{dir: Path.join(opts[:project_dir], ".lemon/browser"), count: 0}

    def recent(_opts),
      do: [%{path: "/Users/alice/shots/one.png", name: "private-shot-name.png", bytes: 3}]
  end

  defmodule PathyMediaJobs do
    def default_dir(project_dir), do: Path.join([project_dir, ".lemon", "media"])
    def default_artifacts_dir(project_dir), do: Path.join([project_dir, ".lemon", "media", "a"])
    def summary(_opts), do: %{count: 0, error: "could not read /Users/alice/media/jobs.json"}
    def recent(_opts), do: []
  end

  defmodule LeakyChannelDiagnostics do
    def status(_opts) do
      %{
        transports: [
          %{
            transport: "telegram",
            enabled: true,
            allowed_chat_ids: [987_654_321],
            chat_id: 987_654_321
          },
          %{transport: "discord", enabled: true, allowed_guild_ids: ["112233445566778899"]}
        ],
        cleanup: %{includes_chat_ids: false, includes_guild_ids: false},
        error:
          "chat 987654321 / guild 112233445566778899 for bob@example.com at +15551234567 and 15557654321"
      }
    end
  end

  defmodule LeakyKanban do
    def diagnostics(_opts) do
      %{
        recent_boards: [
          %{owner: "alice-kanban-owner", columns: ["Secret Column", "done"], task_count: 1}
        ]
      }
    end
  end

  defmodule RaisingCheck do
    def run(_opts), do: raise("boom while reading /Users/alice/.lemon/secret.toml")
  end

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon bundle redaction #{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    previous_runtime = Application.get_env(:lemon_core, :doctor_runtime, [])

    Application.put_env(
      :lemon_core,
      :doctor_runtime,
      Keyword.merge(previous_runtime,
        browser_artifacts: PathyBrowserArtifacts,
        media_jobs: PathyMediaJobs,
        channel_diagnostics: LeakyChannelDiagnostics
      )
    )

    previous_workspace = Application.get_env(:lemon_core, :workspace_diagnostics)
    Application.put_env(:lemon_core, :workspace_diagnostics, kanban: LeakyKanban)

    previous_paths = Application.get_env(:lemon_core, :paths)
    global_config = Path.join(tmp_dir, "global.toml")
    Application.put_env(:lemon_core, :paths, global_config: global_config)
    LemonCore.ConfigCache.clear()

    File.write!(global_config, """
    [gateway.telegram]
    enabled = true
    allowed_chat_ids = [#{@chat_id}]

    [gateway.discord]
    enabled = true
    allowed_guild_ids = [#{@guild_id}]

    [runtime]
    extension_paths = ["#{@alice_home}/private-ext"]

    [web]
    secret_key_base = "skb-private-0123456789abcdef"

    [providers.custom]
    base_url = "https://alice:hunter2@llm.example/v1"
    headers = { "X-Private-Header" = "opaque-header-value" }
    auth_source = "omp_broker"
    omp_account = "alice-omp-account"

    [gateway.sms]
    inbox_number = "+15551234567"

    [gateway.email]
    allowed_senders = ["bob@example.com", "carol@example.com"]

    [providers."customer.private.example"]
    api_key_secret = "customer_secret_name"

    [runtime.provider_routing]
    default_pool = "alice-private-pool"

    [runtime.provider_routing.credential_pools.alice-private-pool]
    providers = ["customer.private.example"]
    strategy = "priority"

    [mcp_servers.private-mcp-server]
    command = "#{@alice_home}/bin/mcp"
    """)

    File.write!(Path.join([tmp_dir, ".lemon", "config.toml"]), """
    [gateway.telegram]
    allowed_chat_ids = [
      #{@chat_id},
    ]
    """)

    env = Map.new(~w(LEMON_PATH LEMON_STORE_PATH PHX_HOST), &{&1, System.get_env(&1)})
    System.put_env("LEMON_PATH", "#{@alice_home}/lemon")
    System.put_env("LEMON_STORE_PATH", @alice_store)
    System.put_env("PHX_HOST", "private.internal.example")

    on_exit(fn ->
      Application.put_env(:lemon_core, :doctor_runtime, previous_runtime)

      if previous_workspace,
        do: Application.put_env(:lemon_core, :workspace_diagnostics, previous_workspace),
        else: Application.delete_env(:lemon_core, :workspace_diagnostics)

      if previous_paths,
        do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)

      LemonCore.ConfigCache.clear()

      Enum.each(env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "no bundle entry carries an absolute path, chat id or guild id", %{tmp_dir: tmp_dir} do
    report =
      Report.from_checks([
        Check.warn(
          "config.global",
          "Global config at #{tmp_dir}/global.toml",
          "Edit #{@alice_home}/.lemon/config.toml"
        )
      ])

    bundle_path = Path.join(tmp_dir, "support.zip")

    assert {:ok, ^bundle_path} =
             SupportBundle.write(report,
               bundle_path: bundle_path,
               project_dir: tmp_dir,
               checkpoint_dir: Path.join(@alice_store, "checkpoints")
             )

    assert {:ok, entries} = :zip.extract(String.to_charlist(bundle_path), [:memory])
    assert length(entries) > 10

    for {name, content} <- entries do
      assert_public_safe(List.to_string(name), IO.iodata_to_binary(content), tmp_dir)
    end

    checkpoint = entry_json(entries, "checkpoint_diagnostics.json")
    assert checkpoint["cleanup"]["includes_raw_paths"] == false
    refute Map.has_key?(checkpoint, "store_dir")
    assert checkpoint["store"]["exists"] == false
    assert is_binary(checkpoint["store"]["path_hash"])

    manifest = entry_json(entries, "manifest.json")
    refute Map.has_key?(manifest, "project_dir")
    refute Map.has_key?(manifest, "cwd")
    assert manifest["runtime_source"] == "local"

    environment = entry_json(entries, "environment.json")
    assert environment["LEMON_STORE_PATH"]["present"] == true

    readme = entries |> entry("README.txt")

    for {name, _} <- entries, name = List.to_string(name), name != "README.txt" do
      assert readme =~ name, "README does not document #{name}"
    end
  end

  test "doctor --json and the text renderer pass the same redaction scan", %{tmp_dir: tmp_dir} do
    report =
      Report.from_checks([
        Check.fail(
          "runtime.store",
          "Store #{@alice_store} not writable (#{tmp_dir}); config \"#{@alice_home}/My Docs/x.toml\"",
          "chmod #{@alice_home}/.lemon; mail bob@example.com or +15551234567 about chat #{@chat_id}"
        )
      ])

    assert_public_safe("doctor --json", Report.to_json(report), tmp_dir)
    assert_public_safe("doctor text", printed(report), tmp_dir)
  end

  test "real checks never interpolate LEMON_PATH or config paths, with or without spaces",
       %{tmp_dir: tmp_dir} do
    for root <- ["/workspace", "/Users/Alice Smith/work"] do
      System.put_env("LEMON_PATH", root)
      report = Doctor.report(runtime: :absent, project_dir: tmp_dir)

      assert %Check{message: message} =
               Enum.find(report.checks, &(&1.name == "runtime.lemon_root"))

      assert message =~ "[path:"

      for {name, text} <- [
            {"raw", inspect(report)},
            {"json", Report.to_json(report)},
            {"text", printed(report, verbose: true)}
          ] do
        refute text =~ root, "#{name} leaks LEMON_PATH:\n#{text}"
        refute text =~ "Smith", "#{name} leaks a path component:\n#{text}"
        # The temp project (whose name has a space) reaches the config checks.
        refute text =~ tmp_dir, "#{name} leaks the config path:\n#{text}"
        # Rendered output also gets the full scan; raw check text may name
        # config keys such as `allowed_chat_ids` (never their values).
        if name != "raw",
          do: assert_public_safe(name, text, tmp_dir, ~w(allowed_chat_ids allowed_guild_ids))
      end
    end
  end

  test "slash commands survive and free-text identifiers do not" do
    alias LemonCore.Doctor.Redaction

    assert Redaction.text("Run /checkpoint diff abc or /login") ==
             "Run /checkpoint diff abc or /login"

    assert Redaction.text("open /workspace and '/a b/c d'") == "open [path] and '[path]'"

    leaked =
      Redaction.text("GET https://api.telegram.org/bot123456:AAE-tok/getMe for chat:987654321")

    refute leaked =~ "AAE-tok"
    refute leaked =~ "api.telegram.org"
    refute leaked =~ "987654321"
    assert leaked =~ "https://[host:"
    assert leaked =~ "chat:[id]"
  end

  defp printed(report, opts \\ []) do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      Report.print(report, opts)
      collect_shell([])
    after
      Mix.shell(previous)
    end
  end

  defp collect_shell(acc) do
    receive do
      {:mix_shell, _kind, [line]} -> collect_shell([IO.iodata_to_binary(line) | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  test "a raising check yields a fixed message and its class, never the exception text" do
    previous = Application.get_env(:lemon_core, :doctor_checks)
    Application.put_env(:lemon_core, :doctor_checks, [RaisingCheck])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :doctor_checks, previous),
        else: Application.delete_env(:lemon_core, :doctor_checks)
    end)

    failed = Doctor.checks(runtime: :absent) |> Enum.filter(&(&1.name == "doctor.check_failed"))
    assert [check] = failed
    text = "#{check.message} #{check.remediation}"
    assert text =~ "RuntimeError"
    refute text =~ "boom"
    refute text =~ @alice_home
  end

  # `allowed` names config keys a check may mention as guidance (never values).
  defp assert_public_safe(name, text, tmp_dir, allowed \\ []) do
    for forbidden <-
          [
            tmp_dir,
            System.tmp_dir!() |> Path.expand(),
            @alice_home,
            System.user_home!(),
            File.cwd!(),
            "allowed_chat_ids",
            "allowed_guild_ids",
            @chat_id,
            @guild_id,
            "boom"
            | @secrets
          ] -- allowed do
      refute String.contains?(text, forbidden),
             "#{name} leaks #{inspect(forbidden)}:\n#{text}"
    end

    refute text =~ ~r{(?<![\w.:/-])/(?:Users|home|private|var|tmp|root)/},
           "#{name} leaks an absolute path:\n#{text}"
  end

  defp entry(entries, name) do
    {_, content} = Enum.find(entries, fn {entry, _} -> entry == String.to_charlist(name) end)
    IO.iodata_to_binary(content)
  end

  defp entry_json(entries, name), do: entries |> entry(name) |> Jason.decode!()
end
