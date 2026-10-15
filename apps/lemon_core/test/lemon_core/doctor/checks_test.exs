defmodule LemonCore.Doctor.ChecksTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.Check

  alias LemonCore.Doctor.Checks.{
    Config,
    NodeTools,
    Providers,
    Usage
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
    for {provider, auth, expected} <- [
          {"ollama", "", :pass},
          {"custom", "auth = \"none\"", :pass},
          {"ollama_cloud", "", :fail}
        ] do
      test "#{provider} credentials report #{expected} without an API key" do
        tmp_dir =
          Path.join(System.tmp_dir!(), "doctor_keyless_#{System.unique_integer([:positive])}")

        File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

        File.write!(Path.join(tmp_dir, ".lemon/config.toml"), """
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

    test "a named missing secret is not a usable default credential" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "doctor_missing_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

      File.write!(Path.join(tmp_dir, ".lemon/config.toml"), """
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

    test "provider routing check reports a ready fallback without leaking credentials" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "provider_routing_check_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

      File.write!(
        Path.join([tmp_dir, ".lemon", "config.toml"]),
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

  describe "Usage.run/1" do
    test "reports safe aggregate usage without leaking stored prompt or credential fields" do
      checks =
        Usage.run(
          summary: %{
            total_cost: 0.42,
            total_requests: 3,
            total_tokens: %{input: 1_000, output: 500},
            breakdown: %{"openai" => 0.42},
            requests: %{"openai" => 3},
            tokens: %{"openai" => %{input: 1_000, output: 500}},
            prompt: "private usage prompt",
            api_key: "usage-secret-key"
          },
          today: %{date: Date.to_iso8601(Date.utc_today()), total_cost: 0.42},
          quotas: %{runs_limit: 10, tokens_limit: 2_000, cost_limit: 1.0}
        )

      usage = Enum.find(checks, &(&1.name == "usage.status"))

      assert usage.status == :pass
      assert usage.message =~ "3 request(s)"
      assert usage.message =~ "1500 token(s)"
      assert usage.message =~ "1 provider(s)"
      refute inspect(usage) =~ "private usage prompt"
      refute inspect(usage) =~ "usage-secret-key"
    end

    test "warns when configured usage quotas are exceeded" do
      checks =
        Usage.run(
          summary: %{
            total_cost: 1.5,
            total_requests: 3,
            total_tokens: %{input: 1_000, output: 500}
          },
          quotas: %{runs_limit: 2, tokens_limit: 1_000, cost_limit: 1.0}
        )

      usage = Enum.find(checks, &(&1.name == "usage.status"))

      assert usage.status == :warn
      assert usage.message =~ "over a configured quota"
      assert usage.remediation =~ "`usage.status`"
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
