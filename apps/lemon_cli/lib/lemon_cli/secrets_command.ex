defmodule LemonCli.SecretsCommand do
  @moduledoc """
  `lemon secrets`: the only command-line implementation of the encrypted
  secrets commands. `LemonCore.Secrets` (with `MasterKey` and `KeyRotation`)
  is the store API; this module owns their prompts, output and exit codes.

  Reads boot a read-only client. `set`, `delete` and `import-env` write
  through `LemonCli.SecretWriter`, which sends the write to a running runtime
  that owns the store instead of opening a second writer beside it.
  """

  alias LemonCli.CLI
  alias LemonCli.CommandRegistry
  alias LemonCli.SecretWriter
  alias LemonCore.Secrets
  alias LemonCore.Secrets.EnvCatalog
  alias LemonCli.Secrets.KeyRotation
  alias LemonCore.Secrets.MasterKey

  @exit_ok 0
  @exit_error 1
  @exit_usage 2

  @spec run([String.t()]) :: 0 | 1 | 2
  def run(["status" | _rest]), do: status()
  def run(["init" | rest]), do: init(rest)
  def run(["set" | rest]), do: set(rest)
  def run(["list" | _rest]), do: list()
  def run(["delete" | rest]), do: delete(rest)
  def run(["check" | _rest]), do: check()
  def run(["import-env" | rest]), do: import_env(rest)
  def run(["rotate-key" | rest]), do: rotate_key(rest)

  def run(["sources" | rest]) do
    CLI.ensure_apps_started!([:lemon_core])
    LemonCli.SecretSourcesCommand.run(rest)
  end

  def run(_other) do
    IO.write(CommandRegistry.help("secrets"))
    @exit_usage
  end

  # ── status / list / check ────────────────────────────────────────────────

  defp status do
    CLI.ensure_apps_started!([:lemon_core], store: :read_only)

    status = Secrets.status()

    IO.puts("configured: #{status.configured}")
    IO.puts("source: #{status.source || "none"}")
    IO.puts("keychain_available: #{status.keychain_available}")
    IO.puts("env_fallback: #{status.env_fallback}")

    if status.keychain_error do
      IO.puts(
        "Keychain access failed: #{CLI.format_reason(status.keychain_error)}. Run `lemon secrets status` for recovery guidance."
      )
    end

    IO.puts("owner: #{status.owner}")
    IO.puts("count: #{status.count}")

    @exit_ok
  end

  defp list do
    CLI.ensure_apps_started!([:lemon_core], store: :read_only)

    case Secrets.list() do
      {:ok, []} ->
        IO.puts("No secrets configured")
        @exit_ok

      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          IO.puts(
            "#{entry.name} provider=#{entry.provider} usage=#{entry.usage_count} expires_at=#{format_optional(entry.expires_at)}"
          )
        end)

        @exit_ok

      {:error, reason} ->
        IO.puts(
          :stderr,
          "Could not list secrets: #{CLI.format_reason(reason)}. Run `lemon secrets status` to check store readiness."
        )

        @exit_error
    end
  end

  defp check do
    CLI.ensure_apps_started!([:lemon_core], store: :read_only)

    max_name_len = EnvCatalog.names() |> Enum.map(&String.length/1) |> Enum.max()

    IO.puts(String.pad_trailing("NAME", max_name_len) <> "  SOURCE   VALUE")
    IO.puts(String.duplicate("-", max_name_len + 30))

    results = Enum.map(EnvCatalog.names(), &check_secret(&1, max_name_len))

    from_store = Enum.count(results, &(&1 == :store))
    from_env = Enum.count(results, &(&1 == :env))
    from_external = Enum.count(results, &external_source?/1)
    missing = Enum.count(results, &(&1 == :missing))

    IO.puts("")

    IO.puts(
      "#{from_store} from store, #{from_external} from external sources, " <>
        "#{from_env} from env, #{missing} missing"
    )

    @exit_ok
  end

  defp check_secret(name, max_name_len) do
    padded_name = String.pad_trailing(name, max_name_len)

    case Secrets.resolve(name) do
      {:ok, _value, source} ->
        IO.puts("#{padded_name}  #{String.pad_trailing(to_string(source), 7)}  present")
        source

      {:error, _reason} ->
        IO.puts("#{padded_name}  #{String.pad_trailing("missing", 7)}  ---")
        :missing
    end
  end

  defp external_source?(source) when is_binary(source),
    do: String.starts_with?(source, "external:")

  defp external_source?(_source), do: false

  # ── init ─────────────────────────────────────────────────────────────────

  # The master key lives in the Keychain or a key file, never in the store.
  defp init(args) do
    CLI.ensure_apps_started!([:lemon_core], store: :read_only)

    {parsed, _rest, _invalid} =
      OptionParser.parse(args, strict: [target: :string, force: :boolean])

    case MasterKey.init(init_opts(parsed)) do
      {:ok, %{source: :file, key_file: path}} ->
        IO.puts("Secrets master key written to #{path} (0600)")
        @exit_ok

      {:ok, %{source: source}} ->
        IO.puts("Secrets master key initialized in #{source}")
        @exit_ok

      {:error, :keychain_unavailable} ->
        fail(
          "Keychain is unavailable on this system and no key file location could be " <>
            "determined. Set #{MasterKey.env_var()}, or configure " <>
            "`config :lemon_core, :secrets, key_file: ...`."
        )

      {:error, :master_key_exists} ->
        fail(
          "A secrets master key already exists (see `lemon secrets status`). Re-run with --force " <>
            "to replace it — every secret encrypted under the old key becomes unreadable. " <>
            "To change the key and keep secrets, run `lemon secrets rotate-key`."
        )

      {:error, {:master_key_check_failed, reason}} ->
        fail(
          "Could not check for an existing secrets master key: #{CLI.format_reason(reason)}. " <>
            "Nothing was written. Run `lemon secrets status` for diagnostics and restore " <>
            "access to the keychain or key file."
        )

      {:error, reason} ->
        fail(
          "Could not initialize the secrets master key: #{CLI.format_reason(reason)}. Run `lemon secrets status` for diagnostics."
        )
    end
  end

  defp init_opts(parsed) do
    opts = if parsed[:force], do: [force: true], else: []

    case parsed[:target] do
      nil -> opts
      target -> [{:target, String.to_atom(target)} | opts]
    end
  end

  # ── set / delete / import-env ────────────────────────────────────────────

  defp set(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [name: :string, value: :string, provider: :string, expires_at: :integer],
        aliases: [n: :name, v: :value]
      )

    case parse_name_and_value(opts, positional) do
      {:ok, name, value} ->
        CLI.ensure_apps_started!([:lemon_core])

        secrets_opts =
          []
          |> maybe_put(:provider, opts[:provider])
          |> maybe_put(:expires_at, opts[:expires_at])

        case SecretWriter.set(name, value, secrets_opts) do
          {:ok, metadata} ->
            IO.puts("Stored secret #{metadata.name} (owner=#{metadata.owner})")
            @exit_ok

          {:error, reason} ->
            fail(set_error(reason))
        end

      {:error, :usage} ->
        IO.puts(:stderr, "Usage: lemon secrets set <name> <value>")
        @exit_usage
    end
  end

  defp set_error(:missing_master_key),
    do: "Missing secrets master key. Run `lemon secrets init` or set #{MasterKey.env_var()}."

  defp set_error(:weak_master_key),
    do:
      "Secrets master key is not base64-encoded 32-byte key material. " <>
        "Run `lemon secrets status` for diagnostics; to keep secrets encrypted under it, " <>
        "allow legacy raw keys and run `lemon secrets rotate-key`."

  defp set_error({:keychain_failed, reason}),
    do:
      "Could not read the secrets master key from keychain: #{CLI.format_reason(reason)}. " <>
        "Nothing was written. Run `lemon secrets status` for diagnostics and restore " <>
        "keychain access; do not re-initialize the key."

  defp set_error(:master_key_mismatch),
    do:
      "The resolved secrets master key does not open the stored secrets, so nothing was written. " <>
        "Run `lemon secrets status` to see which key source is in use (a stale " <>
        "#{MasterKey.env_var()} or a replaced keychain entry) and restore the original key."

  defp set_error(reason),
    do:
      writer_error(reason) ||
        "Could not store the secret: #{CLI.format_reason(reason)}. Run `lemon secrets status` for diagnostics."

  defp parse_name_and_value(opts, positional) do
    case {opts[:name], opts[:value], positional} do
      {name, value, _} when is_binary(name) and is_binary(value) and name != "" and value != "" ->
        {:ok, name, value}

      {nil, nil, [name, value | _]} ->
        {:ok, name, value}

      _ ->
        {:error, :usage}
    end
  end

  defp delete(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: [name: :string], aliases: [n: :name])

    name = opts[:name] || List.first(positional)

    if not is_binary(name) or String.trim(name) == "" do
      IO.puts(:stderr, "Usage: lemon secrets delete <name>")
      @exit_usage
    else
      CLI.ensure_apps_started!([:lemon_core])

      case SecretWriter.delete(name) do
        :ok ->
          IO.puts("Deleted secret #{String.trim(name)}")
          @exit_ok

        {:error, reason} ->
          fail(
            writer_error(reason) ||
              "Could not delete the secret: #{CLI.format_reason(reason)}. Run `lemon secrets status` to check store readiness."
          )
      end
    end
  end

  defp import_env(args) do
    CLI.ensure_apps_started!([:lemon_core])

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        switches: [dry_run: :boolean, force: :boolean],
        aliases: [d: :dry_run, f: :force]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    force = Keyword.get(opts, :force, false)

    if dry_run, do: IO.puts("Dry run mode — no changes will be made")

    results = Enum.map(EnvCatalog.names(), &import_secret(&1, dry_run, force))

    imported = Enum.count(results, &(&1 == :imported))
    already = Enum.count(results, &(&1 == :already_in_store))
    not_set = Enum.count(results, &(&1 == :not_in_env))
    errors = Enum.count(results, &match?({:error, _}, &1))

    IO.puts("")

    summary = "#{imported} imported, #{already} already in store, #{not_set} not in env"
    IO.puts(if errors > 0, do: summary <> ", #{errors} errors", else: summary)

    if errors > 0, do: @exit_error, else: @exit_ok
  end

  defp import_secret(name, dry_run, force) do
    env_value = System.get_env(name)

    cond do
      is_nil(env_value) or env_value == "" ->
        IO.puts("#{name}: not set in env")
        :not_in_env

      not force and match?({:ok, _}, Secrets.get(name)) ->
        IO.puts("#{name}: already in store")
        :already_in_store

      dry_run ->
        IO.puts("#{name}: would import")
        :imported

      true ->
        case SecretWriter.set(name, env_value, provider: "import_env") do
          {:ok, _metadata} ->
            IO.puts("#{name}: imported")
            :imported

          {:error, reason} ->
            IO.puts(
              writer_error(reason) ||
                "#{name}: check failed: #{CLI.format_reason(reason)}. Run `lemon secrets status` for recovery guidance."
            )

            {:error, reason}
        end
    end
  end

  # Failures of the write through a running runtime (`LemonCli.SecretWriter`).
  defp writer_error(:runtime_unreachable),
    do:
      "A running Lemon runtime owns the secrets store, but its control plane did not answer, " <>
        "so nothing was written. Check it with `lemon doctor`, or stop it (`lemon stop`) and retry."

  defp writer_error(:outcome_unknown),
    do:
      "The running Lemon runtime did not confirm the write; it may or may not have been applied. " <>
        "Check `lemon secrets list` before retrying."

  defp writer_error({:runtime_refused, "METHOD_NOT_FOUND"}),
    do:
      "The running Lemon runtime does not accept secret writes from the CLI, so nothing was " <>
        "written. Restart it on this version (`lemon stop`), then retry."

  defp writer_error({:runtime_refused, _code}),
    do:
      "The running Lemon runtime refused the write, so nothing was written. Set " <>
        "LEMON_CONTROL_PLANE_OPERATOR_TOKEN to an operator token with admin scope and retry."

  defp writer_error(_reason), do: nil

  # ── rotate-key ───────────────────────────────────────────────────────────

  defp rotate_key(args) do
    switches = [confirm: :string, resume: :boolean, abandon: :boolean, confirm_abandon: :boolean]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        CLI.ensure_apps_started!([:lemon_core])
        confirmed? = parsed[:confirm_abandon] == true

        case {parsed[:confirm], parsed[:resume] == true, parsed[:abandon] == true, confirmed?} do
          {nil, false, false, false} -> rotate_key_preview()
          {token, false, false, false} -> rotate_key_apply(token)
          {nil, true, false, false} -> rotate_key_recover(:resume, [])
          {nil, false, true, _} -> rotate_key_abandon(confirmed?)
          _conflicting -> rotate_key_usage()
        end

      _other ->
        rotate_key_usage()
    end
  end

  defp rotate_key_usage do
    IO.puts(
      :stderr,
      "Usage: lemon secrets rotate-key [--confirm <token> | --resume | --abandon --confirm-abandon]"
    )

    @exit_usage
  end

  # Abandoning is an operator assertion that cannot be checked: always show
  # the warning, and act only with the explicit confirmation flag.
  defp rotate_key_abandon(confirmed?) do
    IO.puts(:stderr, KeyRotation.abandon_warning())
    rotate_key_recover(:abandon, confirm_abandon: confirmed?)
  end

  # Settles a rotation whose key switch is pending; KeyRotation.recover/2
  # reads the provider itself before changing anything.
  defp rotate_key_recover(action, opts) do
    case KeyRotation.recover(action, opts) do
      {:ok, %{action: :resumed} = result} ->
        IO.puts(
          "Resumed: #{format_key_source(result)} holds the new master key. " <>
            "Run `lemon secrets rotate-key` to finish re-encrypting."
        )

        @exit_ok

      {:ok, %{action: :abandoned} = result} ->
        IO.puts(
          "Abandoned the pending key switch; #{format_key_source(result)} keeps the current key."
        )

        @exit_ok

      {:error, reason} ->
        rotate_key_error(reason)
    end
  end

  defp rotate_key_preview do
    case KeyRotation.preview() do
      {:ok, preview} ->
        IO.puts("Secrets master key rotation preview (nothing changed)")
        IO.puts("key source: #{format_key_source(preview)}")
        IO.puts("secrets to re-encrypt: #{preview.count}")
        IO.puts("expired secrets to delete: #{preview.expired}")
        IO.puts("resumed from an interrupted rotation: #{preview.resumed}")
        IO.puts("confirmation token: #{preview.confirmation_token}")
        IO.puts("")

        if preview.runtime_running do
          IO.puts("A Lemon runtime is running; stop it (`lemon stop`) before rotating.")
        end

        IO.puts(
          "Stored secrets in existing backups stay encrypted under the current key; " <>
            "keep it if you may restore them."
        )

        IO.puts("Rotate with: lemon secrets rotate-key --confirm #{preview.confirmation_token}")
        @exit_ok

      {:error, reason} ->
        rotate_key_error(reason)
    end
  end

  # The runtime guard and the secrets lock live in KeyRotation.rotate/2.
  defp rotate_key_apply(token) do
    case KeyRotation.rotate(token) do
      {:ok, result} ->
        IO.puts(
          "Rotated secrets master key in #{format_key_source(result)}: " <>
            "#{result.rotated} secrets re-encrypted, #{result.pruned} expired deleted"
        )

        @exit_ok

      {:error, reason} ->
        rotate_key_error(reason)
    end
  end

  defp rotate_key_error(reason) do
    IO.puts(:stderr, "Secrets key rotation failed: " <> KeyRotation.describe_error(reason))
    @exit_error
  end

  defp format_key_source(%{source: :file, key_file: path}) when is_binary(path),
    do: "file (#{path})"

  defp format_key_source(%{source: source}), do: to_string(source)

  # ── helpers ──────────────────────────────────────────────────────────────

  defp fail(message) do
    IO.puts(:stderr, message)
    @exit_error
  end

  defp format_optional(nil), do: "never"
  defp format_optional(value), do: to_string(value)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
