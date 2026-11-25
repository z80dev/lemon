defmodule LemonCore.Secrets.FailClosedResolutionTest do
  @moduledoc """
  Only a definite store miss may defer to an external source or the ambient
  environment. Every other store, key or source-config failure fails closed.
  """
  use LemonPlatformTest.Testing.Case, async: false, with_store: true

  alias LemonCore.Clock
  alias LemonCore.Config.Secrets.Source
  alias LemonCore.Secrets
  alias LemonCore.Secrets.{External, SourceCache}
  alias LemonCore.Store

  @name "FAIL_CLOSED_TARGET"
  @bootstrap "FAIL_CLOSED_BOOTSTRAP"
  @ambient "ambient-tripwire-never-used"
  @external "external-value"
  @master_env "LEMON_SECRETS_MASTER_KEY"

  setup %{tmp_dir: tmp_dir} do
    original_master_key = System.get_env(@master_env)
    original_paths = Application.get_env(:lemon_core, :paths)
    System.put_env(@master_env, Base.encode64(:crypto.strong_rand_bytes(32)))
    System.put_env(@name, @ambient)
    System.put_env(@bootstrap, @ambient)

    for {ref, _} <- Store.list(Secrets.table()), do: Store.delete(Secrets.table(), ref)
    SourceCache.clear()

    stub = Path.join(tmp_dir, "source-stub")
    File.write!(stub, stub_source())
    File.chmod!(stub, 0o700)

    on_exit(fn ->
      restore_env(@master_env, original_master_key)
      System.delete_env(@name)
      System.delete_env(@bootstrap)

      if original_paths,
        do: Application.put_env(:lemon_core, :paths, original_paths),
        else: Application.delete_env(:lemon_core, :paths)

      for {ref, _} <- Store.list(Secrets.table()), do: Store.delete(Secrets.table(), ref)
      SourceCache.clear()
    end)

    {:ok, stub: stub, marker: Path.join(tmp_dir, "source-called")}
  end

  # Each case leaves `@name` unreadable from the store for one reason, with
  # the ambient environment and an external source both able to answer.
  @store_failures [
    decrypt_failed: :flipped_ciphertext,
    invalid_payload: :unencoded_ciphertext,
    invalid_secret_record: :map_without_ciphertext,
    invalid_secret_record: :non_map_record,
    store_unavailable: :missing_store,
    missing_master_key: :no_master_key,
    expired: :expired_record
  ]

  for {reason, setup} <- @store_failures do
    test "store #{reason} (#{setup}) reaches neither an external source nor env", ctx do
      opts = arrange(unquote(setup), @name)
      reason = unquote(reason)

      assert {:error, ^reason} = Secrets.get(@name, opts)

      source = command_source(ctx.stub, ["value", ctx.marker])
      assert {:error, ^reason} = Secrets.resolve(@name, [sources: [source]] ++ opts)
      assert {:error, ^reason} = Secrets.resolve(@name, [external_fallback: false] ++ opts)
      assert {:error, ^reason} = Secrets.resolve_local(@name, opts)
      refute Secrets.exists_local?(@name, opts)
      refute Secrets.exists?(@name, [sources: [source]] ++ opts)
      assert Secrets.fetch_value(@name, [sources: [source]] ++ opts) == nil
      refute File.exists?(ctx.marker)
    end

    test "bootstrap credential with store #{reason} (#{setup}) is never read from env", ctx do
      opts = arrange(unquote(setup), @bootstrap)

      source =
        command_source(ctx.stub, ["bootstrap", ctx.marker], secret_env: %{"BOOT" => @bootstrap})

      # A store-wide failure stops at the target itself; otherwise the source
      # refuses to start without its bootstrap credential.
      assert {:error, reason} = Secrets.resolve(@name, [sources: [source]] ++ opts)
      assert reason in [:store_unavailable, {:external_source, :bootstrap_secret_missing}]

      refute File.exists?(ctx.marker)
    end
  end

  test "a definite store miss consults the external source, then env", ctx do
    source = command_source(ctx.stub, ["value", ctx.marker])

    assert {:ok, @external, "external:command:stub"} =
             Secrets.resolve(@name, sources: [source])

    assert {:ok, @ambient, :env} = Secrets.resolve(@name, sources: [])
    assert {:ok, @ambient, :env} = Secrets.resolve_local(@name)
  end

  test "an expired record defers only with the explicit expired_fallback opt-in", ctx do
    opts = arrange(:expired_record, @name)
    source = command_source(ctx.stub, ["value", ctx.marker])

    assert {:ok, @external, "external:command:stub"} =
             Secrets.resolve(@name, [sources: [source], expired_fallback: true] ++ opts)

    assert {:ok, @ambient, :env} =
             Secrets.resolve(@name, [sources: [], expired_fallback: true] ++ opts)

    assert {:ok, @ambient, :env} = Secrets.resolve_local(@name, [expired_fallback: true] ++ opts)
  end

  test "env_fallback: false still consults external sources", ctx do
    source = command_source(ctx.stub, ["value", ctx.marker])

    assert {:ok, @external, "external:command:stub"} =
             Secrets.resolve(@name, sources: [source], env_fallback: false)

    assert {:error, :not_found} =
             Secrets.resolve(@name,
               sources: [source],
               env_fallback: false,
               external_fallback: false
             )
  end

  test "an invalid [secrets] table in a real config file yields an error, never env", ctx do
    global = Path.join(ctx.tmp_dir, "global.toml")
    File.write!(global, ~s(secrets = "not-a-table"\n))
    Application.put_env(:lemon_core, :paths, global_config: global)
    project = Path.join(ctx.tmp_dir, "project")
    File.mkdir_p!(project)

    assert External.source_config(project_dir: project).errors != []

    assert {:error, {:external_source, :invalid_config}} =
             Secrets.resolve(@name, project_dir: project)

    assert Secrets.fetch_value(@name, project_dir: project) == nil
  end

  test "an invalid config elsewhere still honours a valid [secrets] table", ctx do
    global = Path.join(ctx.tmp_dir, "global.toml")
    project = Path.join(ctx.tmp_dir, "project")
    File.mkdir_p!(project)
    Application.put_env(:lemon_core, :paths, global_config: global)

    # A provider table that fails runtime validation is unrelated to secrets:
    # a definite store miss still reaches env when no source is enabled ...
    File.write!(global, ~s([providers.openai-codex]\napi_key = "inline"\n))
    assert_raise LemonCore.Config.ValidationError, fn -> LemonCore.Config.cached(project) end
    assert {:ok, @ambient, :env} = Secrets.resolve(@name, project_dir: project)

    # ... and an enabled source in the same file is still consulted first.
    File.write!(global, """
    [providers.openai-codex]
    api_key = "inline"

    [secrets.sources.stub]
    type = "command"
    enabled = true
    argv = ["#{ctx.stub}", "value", "#{ctx.marker}"]
    """)

    LemonCore.ConfigCache.invalidate(project)

    assert {:ok, @external, "external:command:stub"} =
             Secrets.resolve(@name, project_dir: project)

    # Unreadable TOML leaves the source configuration unknown: fail closed.
    File.write!(global, "[secrets\n")
    LemonCore.ConfigCache.invalidate(project)

    assert {:error, {:external_source, :invalid_config}} =
             Secrets.resolve(@name, project_dir: project)
  end

  test "a two-ref 1Password source asked for one name runs one op read", ctx do
    source = op_source(ctx.stub, ctx.marker, timeout_ms: 5_000)

    assert {:ok, "value-a", "external:onepassword:op"} =
             Secrets.resolve("OP_A", sources: [source], env_fallback: false)

    assert File.read!(ctx.marker) == "op://vault/a/credential\n"
  end

  test "a 1Password source without a ref for the name is skipped without an op read", ctx do
    source = op_source(ctx.stub, ctx.marker, timeout_ms: 5_000)

    assert {:ok, @ambient, :env} = Secrets.resolve(@name, sources: [source])
    refute File.exists?(ctx.marker)
  end

  test "the outer budget covers every op read in a full source run", ctx do
    # Each read takes ~400ms against a 700ms per-read timeout: two reads fit
    # their own limits but not one shared 700ms budget.
    source = op_source(ctx.stub, ctx.marker, timeout_ms: 700, delay: "0.4")

    result = External.test(sources: [source])
    assert result.status == :ready
    assert hd(result.results).secret_count == 2
  end

  defp arrange(:flipped_ciphertext, name) do
    replace_ciphertext(name, fn encoded ->
      bytes = Base.decode64!(encoded)
      Base.encode64(:crypto.exor(bytes, :binary.copy(<<1>>, byte_size(bytes))))
    end)
  end

  defp arrange(:unencoded_ciphertext, name) do
    replace_ciphertext(name, fn _encoded -> "!not base64!" end)
  end

  defp arrange(:map_without_ciphertext, name) do
    :ok = Store.put(Secrets.table(), {"default", name}, %{provider: "manual"})
    []
  end

  defp arrange(:non_map_record, name) do
    :ok = Store.put(Secrets.table(), {"default", name}, "not-a-record")
    []
  end

  defp arrange(:missing_store, _name), do: [store: :fail_closed_missing_store]

  defp arrange(:no_master_key, name) do
    {:ok, _} = Secrets.set(name, "stored")

    [
      key_providers: [:env],
      env_getter: fn
        @master_env -> nil
        other -> System.get_env(other)
      end
    ]
  end

  defp arrange(:expired_record, name) do
    {:ok, _} = Secrets.set(name, "stored", expires_at: Clock.now_ms() - 1_000)
    []
  end

  defp replace_ciphertext(name, fun) do
    {:ok, _} = Secrets.set(name, "stored")
    key = {"default", name}
    {:ok, entry} = Store.fetch(Store, Secrets.table(), key)
    field = if Map.has_key?(entry, :ciphertext), do: :ciphertext, else: "ciphertext"
    :ok = Store.put(Secrets.table(), key, Map.update!(entry, field, fun))
    []
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
          timeout_ms: 5_000,
          max_output_bytes: 4_096
        ],
        opts
      )
    )
  end

  defp op_source(stub, marker, opts) do
    delay = Keyword.get(opts, :delay, "0")

    %Source{
      id: "op",
      type: :onepassword,
      enabled: true,
      executable: Path.join(Path.dirname(stub), "op-stub-#{delay}"),
      refs: %{"OP_A" => "op://vault/a/credential", "OP_B" => "op://vault/b/credential"},
      timeout_ms: Keyword.fetch!(opts, :timeout_ms),
      max_output_bytes: 1_024
    }
    |> tap(fn source -> write_op_stub(source.executable, marker, delay) end)
  end

  defp write_op_stub(path, marker, delay) do
    File.write!(path, """
    #!/bin/sh
    set -eu
    [ "$1" = read ] && [ "$2" = --no-newline ] && [ "$3" = -- ]
    printf '%s\\n' "$4" >> '#{marker}'
    sleep #{delay}
    case "$4" in
      op://vault/a/credential) printf value-a ;;
      op://vault/b/credential) printf value-b ;;
      *) exit 3 ;;
    esac
    """)

    File.chmod!(path, 0o700)
  end

  defp stub_source do
    """
    #!/bin/sh
    set -eu
    : > "$2"
    case "$1" in
      value) printf '#{@name}=#{@external}\\n' ;;
      bootstrap) printf '%s' "${BOOT:-}" > "$2"; printf '#{@name}=#{@external}\\n' ;;
      *) exit 64 ;;
    esac
    """
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
