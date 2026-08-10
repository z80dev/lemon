defmodule LemonCore.Doctor.RegistrationTest do
  @moduledoc """
  The doctor framework stays in lemon_core; the apps it reports on register
  their own checks and diagnostic modules through config.
  """

  use ExUnit.Case, async: false

  alias LemonCore.Doctor
  alias LemonCore.Doctor.RuntimeModules

  defmodule ExtraCheck do
    alias LemonCore.Doctor.Check

    def run(opts) do
      [Check.pass("extra.registered", "ran with #{inspect(Keyword.keys(opts))}")]
    end
  end

  defmodule NotACheck do
    def something_else, do: :ok
  end

  defp put_env(key, value) do
    original = Application.get_env(:lemon_core, key)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:lemon_core, key)
      else
        Application.put_env(:lemon_core, key, original)
      end
    end)

    Application.put_env(:lemon_core, key, value)
  end

  describe "check registration" do
    test "built-ins run without any registration" do
      assert Doctor.registered_checks() == []
      assert Doctor.builtin_checks() |> length() == 17
      assert LemonCore.Doctor.Checks.Secrets in Doctor.builtin_checks()
    end

    test "registered check modules contribute checks" do
      put_env(:doctor_checks, [ExtraCheck])

      assert Doctor.registered_checks() == [ExtraCheck]

      names = Doctor.checks(project_dir: File.cwd!()) |> Enum.map(& &1.name)
      assert "extra.registered" in names
    end

    test "registered checks run after the built-ins" do
      put_env(:doctor_checks, [ExtraCheck])

      names = Doctor.checks(project_dir: File.cwd!()) |> Enum.map(& &1.name)

      assert List.last(names) == "extra.registered"
      assert "secrets.master_key" in names
    end

    test "unusable registrations are skipped rather than crashing the report" do
      put_env(:doctor_checks, [NotACheck, Definitely.Not.Loaded, ExtraCheck])

      assert Doctor.registered_checks() == [ExtraCheck]
      assert %LemonCore.Doctor.Report{} = Doctor.report(project_dir: File.cwd!())
    end
  end

  describe "runtime module registration" do
    test "the umbrella registers the apps that own each diagnostic" do
      registered = RuntimeModules.all()

      assert Keyword.get(registered, :media_jobs) == LemonMedia.MediaJobs
      assert Keyword.get(registered, :browser_artifacts) == LemonBrowser.Artifacts
      assert Keyword.get(registered, :lsp_server_manager) == LemonLsp.ServerManager
    end

    test "an unregistered key resolves to nil so diagnostics fall back" do
      assert RuntimeModules.fetch(:no_such_runtime) == nil
    end

    test "lemon_core names no foreign app module in its doctor code" do
      foreign =
        ~w(LemonLsp LemonMedia LemonBrowser LemonChannels LemonGateway LemonRouter
           CodingAgent AgentCore LemonSkills LemonMemory)

      offenders =
        "lib/lemon_core/doctor/**/*.ex"
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          source = File.read!(path)

          for app <- foreign, String.contains?(source, app <> ".") do
            "#{path}: #{app}"
          end
        end)

      assert offenders == []
    end
  end
end
