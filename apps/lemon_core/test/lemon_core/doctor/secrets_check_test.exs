defmodule LemonCore.Doctor.SecretsCheckTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.Checks.Secrets, as: SecretsCheck
  alias LemonCore.Secrets

  setup do
    previous_config = Application.fetch_env(:lemon_core, Secrets)
    previous_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    Application.put_env(:lemon_core, Secrets, key_providers: [:env])
    System.delete_env("LEMON_SECRETS_MASTER_KEY")

    on_exit(fn ->
      case previous_config do
        {:ok, config} -> Application.put_env(:lemon_core, Secrets, config)
        :error -> Application.delete_env(:lemon_core, Secrets)
      end

      if previous_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", previous_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")
    end)
  end

  test "missing master key remediation works in packaged installs" do
    assert [check] = SecretsCheck.run()
    assert check.status == :fail
    assert check.remediation =~ "lemon secrets init"
    refute check.remediation =~ "mix "
    refute check.remediation =~ System.user_home!()
  end

  test "weak master key explains safe recovery without Elixir terms" do
    System.put_env("LEMON_SECRETS_MASTER_KEY", String.duplicate("synthetic-weak-key", 3))
    assert [check] = SecretsCheck.run()
    assert check.status == :fail
    assert check.remediation =~ "lemon secrets status"
    assert check.remediation =~ "openssl rand -base64 32"
    refute check.remediation =~ "mix "
    refute check.remediation =~ "config :"
    refute check.message <> check.remediation =~ "synthetic-weak-key"
  end

  test "invalid key file errors stay redacted and point to secrets status" do
    directory =
      Path.join(System.tmp_dir!(), "secrets-doctor-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    path = Path.join(directory, "master_key")
    File.write!(path, "short")
    on_exit(fn -> File.rm_rf!(directory) end)
    Application.put_env(:lemon_core, Secrets, key_providers: [:file], key_file: path)

    assert [check] = SecretsCheck.run()
    assert check.status == :warn
    assert check.message == "The encrypted secrets master key could not be verified."
    assert check.remediation =~ "lemon secrets status"
    refute check.message <> check.remediation =~ directory
    refute check.message =~ "{:"
  end
end
