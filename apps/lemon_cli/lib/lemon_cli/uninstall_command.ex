defmodule LemonCli.UninstallCommand do
  @moduledoc """
  CLI command implementation for `lemon uninstall`.

  Provides preview and destructive execution modes for uninstallation.
  Preview is the default; execution requires `--confirm DIGEST` with the
  SHA-256 confirmation digest output during preview.
  """

  alias LemonCore.Uninstall

  @exit_ok 0
  @exit_error 1
  @exit_usage 2

  @spec run([String.t()], keyword()) :: 0 | 1 | 2
  def run(args, dependencies \\ []) do
    case parse_args(args) do
      {:help, _} ->
        print_help()
        @exit_ok

      {:ok, opts} ->
        dispatch(Keyword.merge(dependencies, opts))

      {:error, :usage} ->
        print_usage(:stderr)
        @exit_usage
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args,
           strict: [
             purge: :boolean,
             confirm: :string,
             json: :boolean,
             help: :boolean
           ],
           aliases: [h: :help]
         ) do
      {opts, [], []} ->
        if opts[:help] do
          {:help, opts}
        else
          {:ok, opts}
        end

      _ ->
        {:error, :usage}
    end
  end

  defp dispatch(opts) do
    if opts[:confirm] do
      execute_uninstall(opts)
    else
      preview_uninstall(opts)
    end
  end

  defp preview_uninstall(opts) do
    json? = opts[:json] == true

    case Uninstall.preview(opts) do
      {:ok, preview} ->
        if json? do
          render_json_preview(preview)
        else
          render_human_preview(preview)
        end

        @exit_ok

      {:error, reason} ->
        if json? do
          IO.puts(:stderr, Jason.encode!(%{ok: false, error: to_string(reason)}))
        else
          IO.puts(:stderr, "Error: #{explain(reason)}")
        end

        @exit_error
    end
  end

  defp execute_uninstall(opts) do
    json? = opts[:json] == true

    case Uninstall.execute(opts) do
      {:ok, result} ->
        if json? do
          payload = %{
            ok: true,
            status: "uninstalled",
            units: format_units(result.units),
            programs: result.program_paths,
            rc_lines: format_rc_lines(result.rc_lines),
            purged: result.purged
          }

          IO.puts(Jason.encode!(payload, pretty: true))
        else
          IO.puts("Removed #{length(result.units)} service unit(s).")
          IO.puts("Stopped the unsupervised controller runtime.")

          if result.rc_lines != [] do
            IO.puts(
              "Removed the installer PATH entry from #{length(result.rc_lines)} shell rc file(s)."
            )
          end

          if result.purged, do: IO.puts("Purged ~/.lemon and the stored secrets master key.")

          if result.deleted_paths != [] do
            IO.puts("Handed #{length(result.deleted_paths)} path(s) to the launcher for removal.")
          end

          IO.puts("")
          IO.puts("Lemon has been uninstalled.")
        end

        @exit_ok

      {:error, {:digest_mismatch, expected_digest}} ->
        if json? do
          payload = %{
            ok: false,
            error: "digest_mismatch",
            expected_digest: expected_digest,
            provided_digest: opts[:confirm]
          }

          IO.puts(:stderr, Jason.encode!(payload, pretty: true))
        else
          IO.puts(
            :stderr,
            "Error: confirmation digest mismatch. Preview has changed or digest was incorrect."
          )

          IO.puts(
            :stderr,
            "Run 'lemon uninstall' to inspect current changes and obtain a fresh digest."
          )
        end

        @exit_error

      {:error, reason} ->
        if json? do
          IO.puts(:stderr, Jason.encode!(%{ok: false, error: to_string(reason)}))
        else
          IO.puts(:stderr, "Error: #{explain(reason)}")
        end

        @exit_error
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Rendering
  # ──────────────────────────────────────────────────────────────────────────

  defp render_json_preview(preview) do
    payload = %{
      ok: true,
      source: preview.source,
      units: format_units(preview.units),
      programs: preview.program_paths,
      rc_lines: format_rc_lines(preview.rc_lines),
      purge: preview.purge,
      purge_paths: preview.purge_paths,
      keychain: preview.keychain,
      confirmation_digest: preview.confirmation_digest
    }

    IO.puts(Jason.encode!(payload, pretty: true))
  end

  defp render_human_preview(preview) do
    IO.puts("Lemon uninstall preview:")
    IO.puts("")

    IO.puts("Units to remove:")

    case format_units(preview.units) do
      [] -> IO.puts("  (none)")
      labels -> Enum.each(labels, &IO.puts("  - " <> &1))
    end

    IO.puts("")
    IO.puts("Program files to delete:")

    case preview.program_paths do
      [] ->
        IO.puts("  (none)")

      paths ->
        Enum.each(paths, fn path ->
          IO.puts("  - #{path}")
        end)
    end

    IO.puts("")
    IO.puts("Shell configuration lines to remove:")

    case preview.rc_lines do
      [] ->
        IO.puts("  (none)")

      rc_lines ->
        Enum.each(rc_lines, fn %{file: file, line: line} ->
          IO.puts("  - #{file}:")
          IO.puts("      # added by the lemon installer")
          IO.puts("      #{line}")
        end)
    end

    IO.puts("")

    cond do
      preview.source ->
        IO.puts(
          "Source checkout: service units only; program files, shell configuration and local data are untouched."
        )

      preview.purge ->
        IO.puts("Purge data (~/.lemon): yes (all local data, keys, and state will be deleted)")
        if preview.keychain, do: IO.puts("Keychain secret: #{preview.keychain} (will be removed)")

      true ->
        IO.puts("Purge data (~/.lemon): no (pass --purge to also delete ~/.lemon and secrets)")
    end

    IO.puts("")
    IO.puts("Confirmation digest: #{preview.confirmation_digest}")
    IO.puts("")
    IO.puts("To execute this uninstallation, run:")

    flag_str = if preview.purge, do: " --purge", else: ""
    IO.puts("  lemon uninstall#{flag_str} --confirm #{preview.confirmation_digest}")
  end

  defp format_units(units) do
    Enum.map(units, fn
      %{label: label} when is_binary(label) -> label
      %{"label" => label} when is_binary(label) -> label
      %{name: name} when is_binary(name) -> name
      %{"name" => name} when is_binary(name) -> name
      %{role: role} when is_binary(role) -> role
      %{"role" => role} when is_binary(role) -> role
      label when is_binary(label) -> label
      _ -> "unit"
    end)
  end

  defp format_rc_lines(rc_lines) do
    Enum.map(rc_lines, fn
      %{file: file, line: line} -> %{file: file, line: line}
      %{"file" => file, "line" => line} -> %{file: file, line: line}
      entry -> entry
    end)
  end

  # Stable codes only: no path, command output or exception text is rendered
  # beyond what the preview already showed the operator.
  defp explain(:unit_status_unavailable),
    do: "service unit state could not be read; run `lemon service status` and retry"

  defp explain(:unit_not_removed),
    do: "a service unit was not removed; run `lemon service status` and retry"

  defp explain(:launcher_unavailable),
    do: "no Lemon launcher is available to stop the controller; run uninstall through `lemon`"

  defp explain(:controller_snapshot_unverified),
    do: "the running controller could not be verified; no process was signalled"

  defp explain(:controller_stop_failed),
    do: "the verified controller did not stop; stop it where it runs, then retry"

  defp explain(:rc_file_changed),
    do: "a shell rc file changed since the preview; run `lemon uninstall` again"

  defp explain(:rc_write_failed), do: "a shell rc file could not be rewritten"

  defp explain(:uninstall_manifest_missing),
    do: "program files can only be removed by the launcher; run `lemon uninstall`"

  defp explain(:uninstall_manifest_write_failed),
    do: "the launcher's removal manifest could not be written"

  defp explain(:keychain_removal_failed), do: "the Keychain item could not be removed"
  defp explain(:confirmation_required), do: "run `lemon uninstall` first and pass its digest"
  defp explain(reason) when is_atom(reason), do: to_string(reason)

  defp print_usage(device) do
    IO.puts(device, "Usage: lemon uninstall [--purge] [--confirm DIGEST] [--json]")
  end

  defp print_help do
    IO.puts("""
    Usage: lemon uninstall [--purge] [--confirm DIGEST] [--json]

    Preview and execute Lemon uninstallation.

    Default mode generates a preview of changes and a confirmation digest.
    Pass `--confirm DIGEST` to execute.

    Options:
      --purge           Also remove data directory (~/.lemon) and secrets
      --confirm DIGEST  Execute uninstallation with the specified digest
      --json            Output in JSON format
      -h, --help        Show this help message
    """)
  end
end
