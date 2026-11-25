defmodule LemonCore.PackageNeutralityTest do
  @moduledoc """
  The published foundation stays product- and vendor-neutral: chat platforms
  and the browser driver register through core seams (`:gateway_channels`,
  `:tool_sections`, `:doctor_checks`, `:env_registries`) instead of being named
  in core source (#727).
  """
  # Mutates the global `:tool_sections` registration.
  use ExUnit.Case, async: false

  alias LemonCore.Config.{Tools, Validator}

  @lib Path.expand("../../lib", __DIR__)
  @vendor_terms ~w(telegram discord tern omp bitwarden onepassword launchd)

  test "foundation source contains no product vendor references" do
    terms = Enum.join(@vendor_terms, "|")
    pattern = ~r/(?<![[:alnum:]])(?:#{terms})(?![[:alnum:]])/i
    assert offenders(pattern) == []
  end

  # The browser driver is registered (tool section, doctor check, env registry),
  # so core source never names it, not even in documentation.
  test "core sources do not name the browser driver" do
    assert offenders(~r/\bLemonBrowser\b/) == []
  end

  test "relocated product modules are not available under their former names" do
    for module <- [
          LemonCore.A2A.Client,
          LemonCore.Backup,
          LemonCore.BrowserProvider,
          LemonCore.Checkpoint,
          LemonCore.Doctor.Checks.Browser,
          LemonCore.NodeRegistry,
          LemonCore.Secrets.Source.Bitwarden,
          LemonCore.Secrets.Source.OnePassword,
          LemonCore.Service,
          LemonCore.SessionLifecycle,
          LemonCore.TerminalBackends,
          LemonCore.Tern,
          LemonCore.Uninstall,
          LemonCore.Update.Remote,
          LemonCore.UsageLedger
        ] do
      refute Code.ensure_loaded?(module), "#{inspect(module)} still ships in lemon_core"
    end
  end

  test "an unregistered tool table is neither resolved nor validated by core" do
    previous = Application.fetch_env(:lemon_core, :tool_sections)
    Application.put_env(:lemon_core, :tool_sections, [])

    try do
      tools = Tools.resolve(%{"tools" => %{"browser" => %{"provider" => "anything"}}})
      assert Tools.section(tools, :browser) == nil
      assert Validator.validate_tools(tools, []) == []
    after
      case previous do
        {:ok, value} -> Application.put_env(:lemon_core, :tool_sections, value)
        :error -> Application.delete_env(:lemon_core, :tool_sections)
      end
    end
  end

  test "an enabled external credential source with no registered adapter fails closed" do
    saved = Application.fetch_env(:lemon_core, :secret_source_types)
    Application.delete_env(:lemon_core, :secret_source_types)

    try do
      config =
        LemonCore.Config.Secrets.resolve(%{
          "secrets" => %{
            "sources" => %{"vendor" => %{"type" => "bitwarden", "enabled" => true}}
          }
        })

      assert config.errors == ["secrets.sources.vendor.type: unsupported source type"]
      assert LemonCore.Secrets.external_status(config: config).status == :invalid_config
    after
      case saved do
        {:ok, value} -> Application.put_env(:lemon_core, :secret_source_types, value)
        :error -> Application.delete_env(:lemon_core, :secret_source_types)
      end
    end
  end

  test "pairing codes are redacted for any channel id" do
    for channel <- ~w(xmtp matrix some-channel) do
      redacted = LemonCore.Redact.text("lemon pairing approve #{channel} ABCDEFGH")
      refute redacted =~ "ABCDEFGH"
    end
  end

  defp offenders(pattern) do
    for path <- Path.wildcard(Path.join(@lib, "**/*.ex")),
        # Umbrella-only tooling excluded from the Hex package.
        not String.contains?(path, "/lemon_core/quality/"),
        {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        Regex.match?(pattern, line),
        do: "#{Path.relative_to(path, @lib)}:#{number}"
  end
end
