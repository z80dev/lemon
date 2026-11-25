defmodule LemonAgent.ModelRuntime.AmbientCredentialsTest do
  # Swaps Req's global default plug and process environment.
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.AmbientCredentials
  alias LemonAi.Auth.{AnthropicOAuth, KimiCodeOAuth}

  @env ~w(HOME CODEX_HOME ANTHROPIC_TOKEN CLAUDE_CODE_OAUTH_TOKEN)

  setup do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    tmp =
      Path.join(System.tmp_dir!(), "ambient_credentials_#{System.unique_integer([:positive])}")

    home = Path.join(tmp, "home")
    File.mkdir_p!(home)
    previous_env = Map.new(@env, &{&1, System.get_env(&1)})
    System.put_env("HOME", home)
    Enum.each(@env -- ["HOME"], &System.delete_env/1)

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})

      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(tmp)
    end)

    {:ok, home: home, tmp: tmp}
  end

  describe "Claude Code credentials" do
    test "reads the Claude Code credentials file", %{home: home} do
      write_claude_credentials(home, "sk-ant-oat01-file-token", 3_600_000)
      assert AmbientCredentials.anthropic_access_token() == "sk-ant-oat01-file-token"
    end

    test "a refreshable file login wins over a static env token", %{home: home} do
      write_claude_credentials(home, "sk-ant-oat01-refreshable-token", 3_600_000)
      System.put_env("ANTHROPIC_TOKEN", "sk-ant-oat01-static-token")

      assert AmbientCredentials.anthropic_access_token() == "sk-ant-oat01-refreshable-token"
    end

    test "env tokens apply without a file and must be OAuth tokens" do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-api03-not-oauth")
      assert AmbientCredentials.anthropic_access_token() == nil

      System.put_env("ANTHROPIC_TOKEN", "sk-ant-oat01-env-token")
      assert AmbientCredentials.anthropic_access_token() == "sk-ant-oat01-env-token"
    end

    test "refreshes and atomically writes back a private file, keeping other fields",
         %{home: home} do
      path = write_claude_credentials(home, "sk-ant-oat01-stale", -1)
      File.chmod!(path, 0o644)

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "sk-ant-oat01-rotated",
          "refresh_token" => "rotated-refresh",
          "expires_in" => 3600
        })
      end)

      assert AmbientCredentials.anthropic_access_token() == "sk-ant-oat01-rotated"
      stored = path |> File.read!() |> Jason.decode!()
      assert stored["claudeAiOauth"]["refreshToken"] == "rotated-refresh"
      assert stored["claudeAiOauth"]["scopes"] == ["user:inference"]
      assert stored["other"] == "kept"
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      refute Enum.any?(File.ls!(Path.dirname(path)), &String.starts_with?(&1, ".lemon-stage-"))
    end

    # The 0600-from-creation staging itself is LemonCore.ConfinedFS.replace/5's
    # contract, observed mid-write in confined_fs_test.exs ("a private file's
    # replacement is never readable by others while staged").
    test "a write that fails before publication keeps the previous file intact",
         %{home: home} do
      path = write_claude_credentials(home, "sk-ant-oat01-old", 3_600_000)
      original = File.read!(path)
      dir = Path.dirname(path)
      # The staging directory cannot be created: the write stops after reading.
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod(dir, 0o700) end)

      assert {:error, :oauth_secret_persistence_failed} =
               AmbientCredentials.persist_claude_code_login(
                 dir,
                 refreshed_secret(),
                 :crypto.hash(:sha256, original)
               )

      assert File.read!(path) == original
      File.chmod!(dir, 0o700)
      refute Enum.any?(File.ls!(dir), &String.starts_with?(&1, ".lemon-stage-"))
    end

    test "a file Claude Code changed after the refresh started is not overwritten",
         %{home: home} do
      path = write_claude_credentials(home, "sk-ant-oat01-old", 3_600_000)
      stale_revision = :crypto.hash(:sha256, File.read!(path))

      current =
        File.read!(write_claude_credentials(home, "sk-ant-oat01-claude-rotated", 3_600_000))

      assert {:error, :stale_revision} =
               AmbientCredentials.persist_claude_code_login(
                 Path.dirname(path),
                 refreshed_secret(),
                 stale_revision
               )

      assert File.read!(path) == current
    end
  end

  describe "Codex CLI login" do
    test "detects usable CLI logins without returning tokens or making requests", %{home: home} do
      Req.Test.stub(__MODULE__, fn _ -> flunk("detection must not call HTTP") end)
      path = Path.join(home, "detected.json")
      assert AmbientCredentials.codex_cli_login_status(path: path) == :absent
      original = write_cli_login(path, cli_login(-60))
      assert AmbientCredentials.codex_cli_login_status(path: path) == :present
      assert File.read!(path) == original
      write_cli_login(path, %{"OPENAI_API_KEY" => "synthetic-key"})

      assert AmbientCredentials.codex_cli_login_status(path: path) ==
               {:unusable, :not_chatgpt_oauth}

      File.write!(path, "invalid")

      assert AmbientCredentials.codex_cli_login_status(path: path) ==
               {:unusable, :invalid_codex_cli_login}
    end

    test "imports only the selected CLI copy, CODEX_HOME before HOME, without writes",
         %{home: home} do
      Req.Test.stub(__MODULE__, fn _ -> flunk("import must not call HTTP") end)
      path = Path.join([home, ".codex", "auth.json"])
      login = cli_login(3_600)
      original = write_cli_login(path, login)

      assert {:ok, secret} = AmbientCredentials.import_codex_cli_login()
      assert secret["access_token"] == login["tokens"]["access_token"]
      assert secret["account_id"] == "acc_import"
      assert File.read!(path) == original

      codex_home = Path.join(home, "alternate")
      System.put_env("CODEX_HOME", codex_home)
      assert {:error, :enoent} = AmbientCredentials.import_codex_cli_login()
      write_cli_login(Path.join(codex_home, "auth.json"), %{"OPENAI_API_KEY" => "synthetic-key"})
      assert {:error, :not_chatgpt_oauth} = AmbientCredentials.import_codex_cli_login()
      assert {:ok, selected} = AmbientCredentials.import_codex_cli_login(path: path)
      assert selected["access_token"] == secret["access_token"]

      assert {:error, :invalid_codex_auth_path} =
               AmbientCredentials.import_codex_cli_login(path: 42)
    end
  end

  describe "Kimi Code device id" do
    setup %{home: home} do
      {:ok, path: Path.join([home, ".lemon", "kimi-device-id"])}
    end

    test "seeds the pre-persistence identity privately and keeps it across host renames",
         %{home: home, path: path} do
      legacy = KimiCodeOAuth.derived_device_id(hostname: "old-host", home: home)

      assert AmbientCredentials.kimi_device_id(home: home, hostname: "old-host") == legacy
      assert File.read!(path) == legacy <> "\n"
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

      assert AmbientCredentials.kimi_device_id(home: home, hostname: "renamed-host") == legacy
    end

    test "uses an existing id and reseeds an empty file", %{home: home, path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "  existing-device-id\n")
      assert AmbientCredentials.kimi_device_id(home: home, hostname: "h") == "existing-device-id"

      File.write!(path, "\n")
      seeded = AmbientCredentials.kimi_device_id(home: home, hostname: "h")
      assert seeded =~ ~r/^[0-9a-f]{32}$/
      assert File.read!(path) == seeded <> "\n"
    end

    test "falls back to the derived id when the file cannot be read or written",
         %{home: home, path: path} do
      blocked = Path.join(home, "blocked")
      File.mkdir_p!(Path.join([blocked, ".lemon", "kimi-device-id"]))

      assert AmbientCredentials.kimi_device_id(home: blocked, hostname: "h") ==
               KimiCodeOAuth.derived_device_id(hostname: "h", home: blocked)

      File.write!(Path.join(home, ".lemon"), "not a directory")

      assert AmbientCredentials.kimi_device_id(home: home, hostname: "h") ==
               KimiCodeOAuth.derived_device_id(hostname: "h", home: home)

      refute File.exists?(path)
    end

    test "the runtime injects the persisted id into lemon_ai lazily" do
      assert Application.get_env(:lemon_ai, :kimi_device_id) ==
               {AmbientCredentials, :kimi_device_id, []}
    end
  end

  defp write_claude_credentials(home, access_token, expires_in_ms) do
    path = Path.join([home, ".claude", ".credentials.json"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => access_token,
          "refreshToken" => "refresh-token",
          "expiresAt" => System.system_time(:millisecond) + expires_in_ms,
          "scopes" => ["user:inference"]
        },
        "other" => "kept"
      })
    )

    path
  end

  defp refreshed_secret do
    AnthropicOAuth.encode_secret(%{
      "type" => "anthropic_oauth",
      "access_token" => "sk-ant-oat01-new",
      "refresh_token" => "refresh-new",
      "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
    })
  end

  defp cli_login(seconds) do
    %{
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => %{
        "access_token" => make_jwt("acc_import", seconds),
        "refresh_token" => "synthetic-refresh",
        "account_id" => "acc_import",
        "id_token" => make_jwt("acc_import", seconds)
      }
    }
  end

  defp write_cli_login(path, login) do
    contents = Jason.encode!(login)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    contents
  end

  defp make_jwt(account_id, expires_in_seconds) do
    payload =
      Jason.encode!(%{
        "exp" => System.system_time(:second) + expires_in_seconds,
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}
      })

    "header." <> Base.url_encode64(payload, padding: false) <> ".signature"
  end
end
