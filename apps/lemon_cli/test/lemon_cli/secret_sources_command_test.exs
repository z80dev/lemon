defmodule LemonCli.SecretSourcesCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI
  alias LemonCore.Secrets.SourceCache

  @secret "cli-source-secret-never-print"

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_secret_sources_cli_#{System.unique_integer([:positive])}"
      )

    project_dir = Path.join(tmp_dir, "project")
    File.mkdir_p!(Path.join(project_dir, ".lemon"))

    stub = Path.join(tmp_dir, "source-stub")
    File.write!(stub, stub_source())
    File.chmod!(stub, 0o700)
    SourceCache.clear()

    on_exit(fn ->
      SourceCache.clear()
      File.rm_rf!(tmp_dir)
    end)

    {:ok, project_dir: project_dir, stub: stub}
  end

  test "packaged/source command status is readiness-only and test is value-free", context do
    write_config(context, "success", timeout_ms: 500, max_output_bytes: 4_096)

    status_output =
      capture_io(fn ->
        assert CLI.run([
                 "secrets",
                 "sources",
                 "status",
                 "--project-dir",
                 context.project_dir
               ]) == 0
      end)

    assert status_output =~ "Status: ready"
    assert status_output =~ "provenance=external:command:stub"
    assert status_output =~ "Secret values included: no"
    refute status_output =~ @secret

    test_output =
      capture_io(fn ->
        assert CLI.run([
                 "secrets",
                 "sources",
                 "test",
                 "stub",
                 "--project-dir",
                 context.project_dir
               ]) == 0
      end)

    assert test_output =~ "Status: ready"
    assert test_output =~ "secrets=1"
    assert test_output =~ "provenance=external:command:stub"
    refute test_output =~ @secret
  end

  test "JSON live test exposes only counts, readiness, and provenance", context do
    write_config(context, "success", timeout_ms: 500, max_output_bytes: 4_096)

    output =
      capture_io(fn ->
        assert CLI.run([
                 "secrets",
                 "sources",
                 "test",
                 "--project-dir",
                 context.project_dir,
                 "--json"
               ]) == 0
      end)

    payload = Jason.decode!(output)
    assert payload["status"] == "ready"
    assert get_in(payload, ["results", Access.at(0), "secret_count"]) == 1
    assert get_in(payload, ["results", Access.at(0), "includes_secret_values"]) == false
    refute output =~ @secret
  end

  test "failure, timeout, and output overflow stay bounded and redacted", context do
    for {mode, timeout_ms, max_output_bytes, expected} <- [
          {"failure", 500, 4_096, "error=exit_nonzero"},
          {"timeout", 100, 4_096, "error=timeout"},
          {"overflow", 500, 64, "error=output_too_large"}
        ] do
      write_config(context, mode,
        timeout_ms: timeout_ms,
        max_output_bytes: max_output_bytes
      )

      LemonCore.ConfigCache.clear()

      output =
        capture_io(fn ->
          assert CLI.run([
                   "secrets",
                   "sources",
                   "test",
                   "stub",
                   "--project-dir",
                   context.project_dir
                 ]) == 1
        end)

      assert output =~ expected
      assert output =~ "Secret values included: no"
      refute output =~ @secret
    end
  end

  test "invalid options return usage without invoking the source", context do
    write_config(context, "success", timeout_ms: 500, max_output_bytes: 4_096)

    output =
      capture_io(:stderr, fn ->
        assert CLI.run(["secrets", "sources", "test", "--unknown"]) == 2
      end)

    assert output =~ "Usage: lemon secrets sources"
    refute output =~ @secret

    output =
      capture_io(:stderr, fn ->
        assert CLI.run(["secrets", "sources", "status", "--source-id", "stub"]) == 2
      end)

    assert output =~ "Usage: lemon secrets sources"

    output =
      capture_io(:stderr, fn ->
        assert CLI.run(["secrets", "sources", "test", "INVALID ID"]) == 2
      end)

    assert output =~ "Usage: lemon secrets sources"
  end

  defp write_config(context, mode, opts) do
    path = Path.join([context.project_dir, ".lemon", "config.toml"])

    File.write!(path, """
    [secrets.sources.stub]
    type = "command"
    enabled = true
    argv = [#{toml_string(context.stub)}, #{toml_string(mode)}]
    timeout_ms = #{Keyword.fetch!(opts, :timeout_ms)}
    max_output_bytes = #{Keyword.fetch!(opts, :max_output_bytes)}
    cache_ttl_ms = 0
    """)
  end

  defp toml_string(value), do: Jason.encode!(value)

  defp stub_source do
    """
    #!/bin/sh
    set -eu
    case "${1:-}" in
      success)
        printf 'CLI_STUB_SECRET=#{@secret}\\n'
        ;;
      failure)
        printf '#{@secret}' >&2
        exit 19
        ;;
      timeout)
        exec sleep 5
        ;;
      overflow)
        i=0
        while [ "$i" -lt 50 ]; do
          printf '#{@secret}'
          i=$((i + 1))
        done
        ;;
      *)
        exit 64
        ;;
    esac
    """
  end
end
