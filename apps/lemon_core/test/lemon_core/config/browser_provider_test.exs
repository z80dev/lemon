defmodule LemonCore.Config.BrowserProviderTest do
  use ExUnit.Case, async: false

  alias LemonCore.Config.{Modular, Tools, ValidationError, Validator}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    keys = ~w(LEMON_BROWSER_PROVIDER LEMON_BROWSER_BACKEND HOME)
    original_env = Map.new(keys, &{&1, System.get_env(&1)})
    backend = Application.fetch_env(:lemon_browser, :backend)
    System.delete_env("LEMON_BROWSER_PROVIDER")
    System.delete_env("LEMON_BROWSER_BACKEND")
    Application.delete_env(:lemon_browser, :backend)
    System.put_env("HOME", dir)

    on_exit(fn ->
      Enum.each(original_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      case backend do
        {:ok, value} -> Application.put_env(:lemon_browser, :backend, value)
        :error -> Application.delete_env(:lemon_browser, :backend)
      end
    end)

    %{dir: dir}
  end

  test "browser provider defaults auto with a declared environment override" do
    assert Tools.defaults()["browser"] == %{"provider" => "auto"}
    assert Tools.resolve(%{}).browser == %{provider: "auto"}
    assert LemonCore.Env.describe(:lemon_browser_provider).env_var == "LEMON_BROWSER_PROVIDER"
    assert LemonCore.Env.describe(:lemon_browser_provider).default == "auto"
  end

  test "all supported provider strings validate, including legacy controller and hybrid" do
    for provider <- LemonCore.BrowserProvider.providers() do
      config = tools(%{"provider" => provider})
      assert config.browser.provider == provider
      assert Validator.validate_tools(config, []) == []
    end
  end

  test "unknown and incorrectly typed provider values fail with a redacted allowlist" do
    for invalid <- ["unknown", "https://private.example/token", "AUTO", "", false, 12, [], %{}] do
      errors = tools(%{"provider" => invalid}) |> Validator.validate_tools([])

      assert Enum.any?(
               errors,
               &String.starts_with?(&1, "runtime.tools.browser.provider: must be one of ")
             )

      refute Enum.any?(errors, &String.contains?(&1, "private.example"))
    end

    for invalid <- [false, "local", 1, []] do
      errors = tools(invalid) |> Validator.validate_tools([])
      assert "runtime.tools.browser: must be a table" in errors
    end
  end

  test "provider override wins over file and legacy backend choices" do
    System.put_env("LEMON_BROWSER_BACKEND", "controller")
    Application.put_env(:lemon_browser, :backend, :hybrid)
    System.put_env("LEMON_BROWSER_PROVIDER", "lcu")
    assert tools(%{"provider" => "relay"}).browser.provider == "lcu"
    assert Tools.resolve(%{}).browser.provider == "lcu"

    System.put_env("LEMON_BROWSER_PROVIDER", "auto")
    assert Tools.resolve(%{}).browser.provider == "auto"
  end

  test "invalid environment providers are validated instead of falling back" do
    System.put_env("LEMON_BROWSER_PROVIDER", "secret-invalid-provider")
    errors = tools(%{"provider" => "relay"}) |> Validator.validate_tools([])
    assert Enum.any?(errors, &String.contains?(&1, "runtime.tools.browser.provider"))
    refute inspect(errors) =~ "secret-invalid-provider"
  end

  test "explicit backend env remains supported, but explicit new config wins" do
    System.put_env("LEMON_BROWSER_BACKEND", "cdp")
    assert Tools.resolve(%{}).browser.provider == "cdp"
    assert tools(%{"provider" => "auto"}).browser.provider == "auto"
    assert tools(%{"provider" => "local"}).browser.provider == "local"
  end

  test "historical default local application backend does not defeat auto" do
    for backend <- [:local, "local"] do
      Application.put_env(:lemon_browser, :backend, backend)
      assert Tools.resolve(%{}).browser.provider == "auto"
    end

    for backend <- [:controller, "hybrid"] do
      Application.put_env(:lemon_browser, :backend, backend)
      assert Tools.resolve(%{}).browser.provider == to_string(backend)
    end
  end

  test "existing browser backend settings survive provider resolution" do
    config =
      tools(%{
        "provider" => "auto",
        "backend" => "local",
        "executable_path" => "/private/browser",
        "relay" => %{"port" => 9224}
      })

    assert config.browser.provider == "auto"
    assert config.browser["backend"] == "local"
    assert config.browser["executable_path"] == "/private/browser"
    assert config.browser["relay"] == %{"port" => 9224}
  end

  test "canonical TOML carries provider through modular and facade config", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, ".lemon"))
    path = Path.join([dir, ".lemon", "config.toml"])
    File.write!(path, "[runtime.tools.browser]\nprovider = \"relay\"\n")
    assert Modular.load(project_dir: dir).tools.browser.provider == "relay"
    assert LemonCore.Config.load(dir, cache: false).agent.tools.browser.provider == "relay"

    System.put_env("LEMON_BROWSER_PROVIDER", "lcu")
    assert Modular.load(project_dir: dir).tools.browser.provider == "lcu"
    assert LemonCore.Config.load(dir, cache: false).agent.tools.browser.provider == "lcu"
  end

  test "canonical TOML rejects invalid providers before runtime selection", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, ".lemon"))

    File.write!(
      Path.join([dir, ".lemon", "config.toml"]),
      "[runtime.tools.browser]\nprovider = \"invalid\"\n"
    )

    error = assert_raise ValidationError, fn -> Modular.load(project_dir: dir) end
    assert error.message =~ "runtime.tools.browser.provider"
  end

  defp tools(browser), do: Tools.resolve(%{"tools" => %{"browser" => browser}})
end
