defmodule LemonCore.Doctor.ChecksTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.Check

  alias LemonCore.Doctor.Checks.{
    Config,
    NodeTools,
    Providers
  }

  describe "Config.run/1" do
    test "returns a list of Check structs" do
      checks = Config.run()
      assert is_list(checks)
      assert Enum.all?(checks, &match?(%Check{}, &1))
    end

    test "check names are unique" do
      names = Config.run() |> Enum.map(& &1.name)
      assert length(names) == length(Enum.uniq(names))
    end
  end

  describe "Providers.run/1" do
    setup do
      previous_paths = Application.get_env(:lemon_core, :paths)

      global_config =
        Path.join(System.tmp_dir!(), "doctor_global_#{System.unique_integer([:positive])}.toml")

      Application.put_env(:lemon_core, :paths, global_config: global_config)
      LemonCore.ConfigCache.clear()

      on_exit(fn ->
        if previous_paths,
          do: Application.put_env(:lemon_core, :paths, previous_paths),
          else: Application.delete_env(:lemon_core, :paths)

        LemonCore.ConfigCache.clear()
        File.rm(global_config)
      end)

      %{global_config: global_config}
    end

    for {provider, auth, expected} <- [
          {"ollama", "", :pass},
          {"custom", "auth = \"none\"", :pass},
          {"ollama_cloud", "", :fail}
        ] do
      test "#{provider} credentials report #{expected} without an API key", %{
        global_config: global_config
      } do
        tmp_dir =
          Path.join(System.tmp_dir!(), "doctor_keyless_#{System.unique_integer([:positive])}")

        File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

        File.write!(global_config, """
        [defaults]
        provider = "#{unquote(provider)}"
        model = "test-model"
        [providers.#{unquote(provider)}]
        #{unquote(auth)}
        """)

        on_exit(fn -> File.rm_rf!(tmp_dir) end)

        check =
          Providers.run(project_dir: tmp_dir) |> Enum.find(&(&1.name == "providers.credentials"))

        assert check.status == unquote(expected)
      end
    end

    test "a named missing secret is not a usable default credential", %{
      global_config: global_config
    } do
      tmp_dir =
        Path.join(System.tmp_dir!(), "doctor_missing_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

      File.write!(global_config, """
      [defaults]
      provider = "doctor_test_provider"
      model = "doctor_test_provider:model"
      [providers.doctor_test_provider]
      api_key_secret = "doctor_missing_secret_#{System.unique_integer([:positive])}"
      """)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      check =
        Providers.run(project_dir: tmp_dir) |> Enum.find(&(&1.name == "providers.credentials"))

      assert check.status == :fail
      refute check.message =~ "doctor_missing_secret_"
    end

    test "provider routing check reports a ready fallback without leaking credentials", %{
      global_config: global_config
    } do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "provider_routing_check_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

      File.write!(
        global_config,
        """
        [providers.zai]
        api_key = "private-zai-key"

        [defaults]
        provider = "openai"
        model = "glm-5-turbo"

        [runtime.provider_routing]
        fallback_providers = ["zai"]
        """
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      checks = Providers.run(project_dir: tmp_dir)
      routing_check = Enum.find(checks, &(&1.name == "providers.routing"))

      assert routing_check.status == :pass
      assert routing_check.message =~ "Default provider is not credential-ready"
      assert routing_check.message =~ "zai"
      refute inspect(routing_check) =~ "private-zai-key"
    end
  end

  describe "NodeTools.run/1" do
    test "git check reflects executable availability" do
      checks = NodeTools.run()
      git_check = Enum.find(checks, &(&1.name == "node_tools.git"))
      expected = if System.find_executable("git"), do: :pass, else: :fail
      assert git_check.status == expected
    end
  end
end
