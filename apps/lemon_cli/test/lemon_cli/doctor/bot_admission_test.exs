defmodule LemonCli.Doctor.BotAdmissionTest do
  use ExUnit.Case, async: false

  alias LemonCli.Doctor.BotAdmission
  alias LemonCore.Doctor

  @public_url "LEMON_BOT_PUBLIC_URL"
  @native "LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS"
  @cron "LEMON_CRON_ADMISSION_ALLOWED_ORIGINS"
  @app_keys [
    {:lemon_router, :native_followup_allowed_origins},
    {:lemon_automation, :cron_admission_allowed_origins}
  ]

  setup do
    environment = Map.new([@public_url, @native, @cron], &{&1, System.fetch_env(&1)})
    configuration = Map.new(@app_keys, &{&1, Application.fetch_env(elem(&1, 0), elem(&1, 1))})

    on_exit(fn ->
      for {key, original} <- environment do
        case original do
          {:ok, value} -> System.put_env(key, value)
          :error -> System.delete_env(key)
        end
      end

      for {{app, key}, original} <- configuration do
        case original do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    for key <- [@public_url, @native, @cron], do: System.delete_env(key)
    for {app, key} <- @app_keys, do: Application.put_env(app, key, [])
    :ok
  end

  test "the CLI check is registered with the shared doctor framework" do
    assert BotAdmission in Doctor.registered_checks()
  end

  test "an unset Bot public URL skips the offline check" do
    System.put_env(@native, "invalid")
    System.put_env(@cron, "invalid")

    assert [check] = BotAdmission.run(runtime: :external)
    assert check.name == "bot.admission_origins"
    assert check.status == :skip
    assert check.message =~ @public_url
  end

  test "both missing allowlists are named without disclosing URLs" do
    System.put_env(@public_url, "https://private-bot.example/private-callback")
    System.put_env(@native, "https://private-native.example")
    System.put_env(@cron, "https://private-cron.example")

    assert [check] = BotAdmission.run()
    assert check.status == :fail
    assert check.message =~ @native
    assert check.message =~ @cron
    assert check.remediation =~ @native
    assert check.remediation =~ @cron
    refute inspect(check) =~ "private-"
    refute inspect(check) =~ "https://"
  end

  for {missing, valid} <- [{@native, @cron}, {@cron, @native}] do
    test "names only #{missing} when the other allowlist contains the origin" do
      System.put_env(@public_url, "https://bot.example")
      System.put_env(unquote(valid), "https://bot.example")

      assert [check] = BotAdmission.run()
      assert check.status == :fail
      assert check.message =~ unquote(missing)
      assert check.remediation =~ unquote(missing)
      refute check.message =~ unquote(valid)
      refute check.remediation =~ unquote(valid)
    end
  end

  for {public_url, native, cron} <- [
        {"https://BOT.EXAMPLE:443/private-callback", "https://bot.example",
         "HTTPS://BOT.EXAMPLE:443"},
        {"HTTPS://BOT.EXAMPLE", "https://bot.example:443", "https://BOT.EXAMPLE"},
        {"http://127.0.0.1", "http://127.0.0.1:80", "http://127.0.0.1"},
        {"http://[::1]:80", "http://[::1]", "http://[::1]:80"},
        {"http://127.0.0.1:4100", "http://127.0.0.1:4100", "http://127.0.0.1:4100"}
      ] do
    test "both allowlists accept canonical origin matching for #{public_url}" do
      System.put_env(@public_url, unquote(public_url))
      System.put_env(@native, "https://other.example, " <> unquote(native) <> " ,")
      System.put_env(@cron, unquote(cron))

      assert [check] = BotAdmission.run()
      assert check.status == :pass
      refute inspect(check) =~ "bot.example"
      refute inspect(check) =~ "private-callback"
    end
  end

  test "absent environment allowlists use the configured same-machine origin" do
    System.put_env(@public_url, "http://127.0.0.1:4100/")

    for {app, key} <- @app_keys do
      Application.put_env(app, key, ["http://127.0.0.1:4100"])
    end

    assert [check] = BotAdmission.run()
    assert check.status == :pass
  end

  for {override, valid} <- [{@native, @cron}, {@cron, @native}],
      value <- ["", "   ", "https://other.example"] do
    test "#{override}=#{inspect(value)} replaces matching app configuration" do
      System.put_env(@public_url, "https://bot.example")
      System.put_env(unquote(override), unquote(value))
      System.put_env(unquote(valid), "https://bot.example")

      for {app, key} <- @app_keys do
        Application.put_env(app, key, ["https://bot.example"])
      end

      assert [check] = BotAdmission.run()
      assert check.status == :fail
      assert check.message =~ unquote(override)
      refute check.message =~ unquote(valid)
    end
  end

  test "an allowlisted path or different port does not authorize the public origin" do
    System.put_env(@public_url, "https://bot.example")
    System.put_env(@native, "https://bot.example/callback")
    System.put_env(@cron, "https://bot.example:444")

    assert [check] = BotAdmission.run()
    assert check.status == :fail
    assert check.message =~ @native
    assert check.message =~ @cron
  end

  for url <- [
        "",
        "not-a-url-private-value",
        "https://private-user:private-password@bot.example/private-path?private-query#private-fragment",
        "http://bot.example",
        "https://bot.example:"
      ] do
    test "invalid public URL #{inspect(url)} fails without leaking its value" do
      System.put_env(@public_url, unquote(url))

      assert [check] = BotAdmission.run()
      assert check.status == :fail
      assert check.message =~ @public_url
      refute inspect(check) =~ "private-"
      refute inspect(check) =~ "bot.example"
      refute inspect(check) =~ "https://"
    end
  end
end
