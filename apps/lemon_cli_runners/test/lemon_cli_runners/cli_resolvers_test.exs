defmodule LemonCliRunners.CliResolversTest do
  @moduledoc """
  The vendor half of the CLI config contract.

  These are the vendor-default assertions `LemonCore.Config.Agent` used to
  carry as five hardcoded `resolve_*_cli` functions. They now run against
  whatever `LemonCliRunners.Application` registered at boot, which is the
  point: the platform resolves `[runtime.cli.<engine>]` sections without
  knowing any of these vendors.
  """

  # async: false — the TOML round-trip below swaps $HOME.
  use ExUnit.Case, async: false

  alias LemonCore.Config.Agent
  alias LemonCore.Config.CliResolvers

  test "every vendor CLI registers its config resolver at boot" do
    ids = CliResolvers.list_ids()

    for module <- LemonCliRunners.Application.subagents() do
      assert module.id() in ids
    end
  end

  describe "vendor defaults" do
    test "materialize for unconfigured sections" do
      config = Agent.resolve(%{})

      assert config.cli.codex.extra_args == []
      assert config.cli.codex.auto_approve == false
      assert config.cli.kimi.extra_args == []
      assert config.cli.opencode.model == nil
      assert config.cli.pi.extra_args == []
      assert config.cli.pi.model == nil
      assert config.cli.pi.provider == nil
      assert config.cli.claude.dangerously_skip_permissions == true
      assert config.cli.claude.allowed_tools == []
      assert config.cli.claude.scrub_env == :auto
      assert config.cli.claude.env_allowlist == []
      assert config.cli.claude.env_allow_prefixes == []
      assert config.cli.claude.env_overrides == %{}
    end

    test "settings from the runtime section override them" do
      settings = %{
        "runtime" => %{
          "cli" => %{
            "codex" => %{"extra_args" => ["--flag"], "auto_approve" => true},
            "kimi" => %{"extra_args" => ["--kimi-flag"]},
            "opencode" => %{"model" => "gpt-4o"},
            "pi" => %{"model" => "test", "provider" => "openai"},
            "claude" => %{
              "dangerously_skip_permissions" => false,
              "allowed_tools" => ["bash"],
              "scrub_env" => "true",
              "env_allowlist" => ["PATH"],
              "env_allow_prefixes" => ["LEMON_"],
              "env_overrides" => %{"FOO" => "bar"}
            }
          }
        }
      }

      config = Agent.resolve(settings)

      assert config.cli.codex.extra_args == ["--flag"]
      assert config.cli.codex.auto_approve == true
      assert config.cli.kimi.extra_args == ["--kimi-flag"]
      assert config.cli.opencode.model == "gpt-4o"
      assert config.cli.pi.model == "test"
      assert config.cli.pi.provider == "openai"
      assert config.cli.claude.dangerously_skip_permissions == false
      assert config.cli.claude.allowed_tools == ["bash"]
      assert config.cli.claude.scrub_env == true
      assert config.cli.claude.env_allowlist == ["PATH"]
      assert config.cli.claude.env_allow_prefixes == ["LEMON_"]
      assert config.cli.claude.env_overrides == %{"FOO" => "bar"}
    end

    test "empty model/provider strings settle to nil" do
      settings = %{
        "runtime" => %{
          "cli" => %{
            "opencode" => %{"model" => ""},
            "pi" => %{"model" => "", "provider" => ""}
          }
        }
      }

      config = Agent.resolve(settings)

      assert config.cli.opencode.model == nil
      assert config.cli.pi.model == nil
      assert config.cli.pi.provider == nil
    end
  end

  describe "TOML round-trip" do
    setup do
      original_home = System.get_env("HOME")

      tmp_dir =
        Path.join(System.tmp_dir!(), "lemon_cli_resolvers_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      System.put_env("HOME", tmp_dir)

      on_exit(fn ->
        if original_home,
          do: System.put_env("HOME", original_home),
          else: System.delete_env("HOME")

        File.rm_rf!(tmp_dir)
      end)

      %{home: tmp_dir}
    end

    test "parses CLI settings from the runtime section", %{home: home} do
      global_dir = Path.join(home, ".lemon")
      File.mkdir_p!(global_dir)

      File.write!(Path.join(global_dir, "config.toml"), """
      [runtime.cli.codex]
      extra_args = ["-c", "notify=[]"]
      auto_approve = false

      [runtime.cli.claude]
      dangerously_skip_permissions = true

      [runtime.cli.mystery]
      anything = "goes"
      """)

      config = LemonCore.Config.load()

      assert config.agent.cli.codex.extra_args == ["-c", "notify=[]"]
      assert config.agent.cli.codex.auto_approve == false
      assert config.agent.cli.claude.dangerously_skip_permissions == true

      # Unconfigured vendors still materialize their defaults...
      assert config.agent.cli.kimi.extra_args == []

      # ...and sections no vendor claims are carried raw, not dropped.
      assert config.agent.cli["mystery"] == %{"anything" => "goes"}
    end
  end
end
