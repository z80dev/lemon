defmodule LemonCore.Secrets.ExternalTest do
  use LemonCore.Testing.Case, async: false, with_store: true

  import ExUnit.CaptureLog

  alias LemonCore.Config.Secrets.Source
  alias LemonCore.Secrets
  alias LemonCore.Secrets.{External, SourceCache}

  @resolved_secret "stub-secret-value-never-print"
  @bootstrap_secret "stub-bootstrap-never-print"

  setup %{tmp_dir: tmp_dir} do
    original_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    original_ambient = System.get_env("AMBIENT_SECRET_SHOULD_NOT_PASS")
    original_target = System.get_env("STUB_SECRET")
    original_other_target = System.get_env("OTHER_STUB_SECRET")

    System.put_env("LEMON_SECRETS_MASTER_KEY", random_master_key())
    System.put_env("AMBIENT_SECRET_SHOULD_NOT_PASS", "ambient-never-print")
    System.delete_env("STUB_SECRET")
    System.delete_env("OTHER_STUB_SECRET")
    :ok = Secrets.delete("STUB_SECRET")
    :ok = Secrets.delete("stub_bootstrap")
    :ok = Secrets.delete("op_bootstrap")
    :ok = Secrets.delete("bws_bootstrap")
    SourceCache.clear()

    stub = Path.join(tmp_dir, "secret-source-stub")
    File.write!(stub, stub_source())
    File.chmod!(stub, 0o700)

    on_exit(fn ->
      restore_env("LEMON_SECRETS_MASTER_KEY", original_master_key)
      restore_env("AMBIENT_SECRET_SHOULD_NOT_PASS", original_ambient)
      restore_env("STUB_SECRET", original_target)
      restore_env("OTHER_STUB_SECRET", original_other_target)
      :ok = Secrets.delete("STUB_SECRET")
      :ok = Secrets.delete("stub_bootstrap")
      :ok = Secrets.delete("op_bootstrap")
      :ok = Secrets.delete("bws_bootstrap")
      SourceCache.clear()
    end)

    {:ok, stub: stub}
  end

  test "real argv-only command resolves through Lemon with a minimal environment", %{stub: stub} do
    marker = stub <> ".injection-marker"

    source =
      command_source(stub, ["success", ";touch", marker],
        secret_env: %{"STUB_BOOTSTRAP" => "stub_bootstrap"}
      )

    assert {:ok, _metadata} = Secrets.set("stub_bootstrap", @bootstrap_secret)

    log =
      capture_log(fn ->
        assert {:ok, @resolved_secret, "external:command:stub"} =
                 Secrets.resolve("STUB_SECRET", sources: [source])
      end)

    refute File.exists?(marker)
    refute log =~ @resolved_secret
    refute log =~ @bootstrap_secret
    refute log =~ "ambient-never-print"
  end

  test "encrypted store remains authoritative and avoids invoking the helper", %{stub: stub} do
    marker = stub <> ".called"
    source = command_source(stub, ["mark", marker])
    assert {:ok, _metadata} = Secrets.set("STUB_SECRET", "stored-wins")

    assert {:ok, "stored-wins", :store} = Secrets.resolve("STUB_SECRET", sources: [source])
    refute File.exists?(marker)
  end

  test "a successful source miss may continue to ordinary environment fallback", %{stub: stub} do
    System.put_env("OTHER_STUB_SECRET", "environment-after-source-miss")
    source = command_source(stub, ["success"])

    assert {:ok, "environment-after-source-miss", :env} =
             Secrets.resolve("OTHER_STUB_SECRET", sources: [source])
  end

  test "optional TTL cache is process-local and avoids a second helper invocation", %{stub: stub} do
    marker = stub <> ".cache-calls"
    source = command_source(stub, ["count", marker], cache_ttl_ms: 10_000)

    assert {:ok, @resolved_secret, "external:command:stub"} =
             Secrets.resolve("STUB_SECRET", sources: [source])

    assert {:ok, @resolved_secret, "external:command:stub"} =
             Secrets.resolve("STUB_SECRET", sources: [source])

    assert File.read!(marker) == "x"
  end

  test "enabled-source failure is fail-closed before environment fallback", %{stub: stub} do
    System.put_env("STUB_SECRET", "stale-env-must-not-win")
    source = command_source(stub, ["failure"])

    log =
      capture_log(fn ->
        assert {:error, {:external_source, :exit_nonzero}} =
                 Secrets.resolve("STUB_SECRET", sources: [source])
      end)

    refute log =~ @resolved_secret
    refute log =~ "stale-env-must-not-win"
  end

  test "timeout closes the supervised helper and returns a stable redacted error", %{stub: stub} do
    source = command_source(stub, ["timeout"], timeout_ms: 100)
    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:external_source, :timeout}} =
             Secrets.resolve("STUB_SECRET", sources: [source])

    assert System.monotonic_time(:millisecond) - started_at < 1_000
  end

  test "combined stdout and stderr are hard bounded and never returned", %{stub: stub} do
    source = command_source(stub, ["overflow"], max_output_bytes: 256)

    error = Secrets.resolve("STUB_SECRET", sources: [source])
    assert error == {:error, {:external_source, :output_too_large}}
    refute inspect(error) =~ @resolved_secret
  end

  test "malformed helper output maps to a stable value-free error", %{stub: stub} do
    source = command_source(stub, ["invalid"])

    error = Secrets.resolve("STUB_SECRET", sources: [source])
    assert error == {:error, {:external_source, :invalid_output}}
    refute inspect(error) =~ @resolved_secret
  end

  test "1Password adapter uses an op reference as one argv element", %{stub: stub} do
    assert {:ok, _metadata} = Secrets.set("op_bootstrap", @bootstrap_secret)

    source = %Source{
      id: "op",
      type: :onepassword,
      enabled: true,
      executable: stub,
      refs: %{"STUB_SECRET" => "op://Private/Test/credential"},
      auth_secret: "op_bootstrap",
      timeout_ms: 500,
      max_output_bytes: 1_024
    }

    assert {:ok, @resolved_secret, "external:onepassword:op"} =
             Secrets.resolve("STUB_SECRET", sources: [source])
  end

  test "Bitwarden adapter resolves its bootstrap through the existing store", %{stub: stub} do
    assert {:ok, _metadata} = Secrets.set("bws_bootstrap", @bootstrap_secret)

    source = %Source{
      id: "bws",
      type: :bitwarden,
      enabled: true,
      executable: stub,
      project_id: "project_123",
      access_token_secret: "bws_bootstrap",
      access_token_env: "BWS_ACCESS_TOKEN",
      timeout_ms: 500,
      max_output_bytes: 4_096
    }

    assert {:ok, @resolved_secret, "external:bitwarden:bws"} =
             Secrets.resolve("STUB_SECRET", sources: [source])
  end

  test "status and live test contain readiness and provenance but no values", %{stub: stub} do
    source = command_source(stub, ["success"])

    status = External.status(sources: [source])
    result = External.test(sources: [source])

    assert status.status == :ready
    assert result.status == :ready
    assert hd(result.results).secret_count == 1
    assert hd(result.results).provenance == "external:command:stub"
    assert result.includes_secret_values == false
    refute inspect(status) =~ @resolved_secret
    refute inspect(result) =~ @resolved_secret
  end

  test "source cache retains at most 32 process-local entries" do
    Enum.each(1..33, fn index ->
      assert :ok = SourceCache.put({:entry, index}, %{value: index}, index)
    end)

    assert :miss = SourceCache.get({:entry, 1}, 0)
    assert {:ok, %{value: 33}} = SourceCache.get({:entry, 33}, 0)
  end

  defp command_source(stub, args, opts \\ []) do
    struct!(
      Source,
      Keyword.merge(
        [
          id: "stub",
          type: :command,
          enabled: true,
          argv: [stub | args],
          timeout_ms: 500,
          max_output_bytes: 4_096
        ],
        opts
      )
    )
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp stub_source do
    """
    #!/bin/sh
    set -eu
    mode="${1:-}"
    case "$mode" in
      success)
        [ -z "${AMBIENT_SECRET_SHOULD_NOT_PASS:-}" ]
        if [ "${STUB_BOOTSTRAP:-}" != "#{@bootstrap_secret}" ] && [ -n "${STUB_BOOTSTRAP:-}" ]; then
          exit 41
        fi
        printf 'STUB_SECRET=#{@resolved_secret}\\n'
        ;;
      mark)
        : > "$2"
        printf 'STUB_SECRET=#{@resolved_secret}\\n'
        ;;
      count)
        printf x >> "$2"
        printf 'STUB_SECRET=#{@resolved_secret}\\n'
        ;;
      failure)
        printf '#{@resolved_secret}' >&2
        exit 17
        ;;
      timeout)
        exec sleep 5
        ;;
      overflow)
        i=0
        while [ "$i" -lt 200 ]; do
          printf '#{@resolved_secret}'
          i=$((i + 1))
        done
        ;;
      invalid)
        printf 'not-an-assignment #{@resolved_secret}\\n'
        ;;
      read)
        [ "$2" = '--no-newline' ]
        [ "$3" = '--' ]
        [ "$4" = 'op://Private/Test/credential' ]
        [ "${OP_SERVICE_ACCOUNT_TOKEN:-}" = '#{@bootstrap_secret}' ]
        printf '#{@resolved_secret}'
        ;;
      secret)
        [ "$2" = 'list' ]
        [ "$3" = 'project_123' ]
        [ "$4" = '--output' ]
        [ "$5" = 'json' ]
        [ "${BWS_ACCESS_TOKEN:-}" = '#{@bootstrap_secret}' ]
        printf '[{"key":"STUB_SECRET","value":"#{@resolved_secret}"}]'
        ;;
      *)
        exit 64
        ;;
    esac
    """
  end
end
