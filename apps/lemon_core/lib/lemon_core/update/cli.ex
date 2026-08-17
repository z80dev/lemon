defmodule LemonCore.Update.CLI do
  @moduledoc """
  Entry point for `bin/<profile> eval 'LemonCore.Update.CLI.main(System.argv())'`.

  `eval` boots the VM without starting any OTP application — no supervision
  tree, no store. `run/1` starts exactly what `LemonCore.Update.Remote` needs
  (`:crypto`, `:ssl`, `:inets`, `:jason`) and never touches anything else.

  ## Subcommands

    * (none) — check, then apply if an update is available.
    * `--check` — check only, no download.
    * `--rollback` — flip `current` to the previous version.
    * `--channel <c>` — override the update channel.
    * `--version <v>` — pin to a specific published version.
    * `--json` — emit a single JSON object instead of human-readable text.

  If `argv` is empty, falls back to splitting `LEMON_UPDATE_ARGS` — the shim
  exports this so the overlay's `update` subcommand can hand off arguments
  after `--` without relying on the release `eval` invocation to preserve
  argv shape.
  """

  alias LemonCore.Update.Remote

  @apps [:crypto, :ssl, :inets, :jason]

  @doc """
  Halting entry point. Exits `0` on success, `1` on error.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    System.halt(run(argv))
  end

  @doc """
  Runs the requested subcommand and returns an exit code instead of halting.

  Prefer this in tests — `main/1` calls `System.halt/1`.
  """
  @spec run([String.t()]) :: 0 | 1
  def run(argv) do
    ensure_started()

    argv
    |> effective_argv()
    |> parse_args()
    |> execute()
  end

  defp ensure_started, do: Enum.each(@apps, &Application.ensure_all_started/1)

  defp effective_argv([]) do
    String.split(System.get_env("LEMON_UPDATE_ARGS") || "", " ", trim: true)
  end

  defp effective_argv(argv), do: argv

  defp parse_args(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        switches: [
          check: :boolean,
          rollback: :boolean,
          channel: :string,
          version: :string,
          json: :boolean
        ]
      )

    opts
  end

  defp execute(opts) do
    json? = Keyword.get(opts, :json, false)
    remote_opts = remote_opts(opts)

    cond do
      opts[:rollback] -> run_rollback(remote_opts, json?)
      opts[:check] -> run_check(remote_opts, json?)
      true -> run_default(remote_opts, json?)
    end
  end

  defp remote_opts(opts) do
    []
    |> maybe_put(:channel, opts[:channel])
    |> maybe_put(:version, opts[:version])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp run_check(remote_opts, json?) do
    case Remote.check(remote_opts) do
      {:ok, info} ->
        report(:check, info, json?)
        0

      {:error, reason} ->
        report_error(reason, json?)
        1
    end
  end

  defp run_default(remote_opts, json?) do
    case Remote.apply(remote_opts) do
      {:ok, info} ->
        report(:apply, info, json?)
        0

      {:error, reason} ->
        report_error(reason, json?)
        1
    end
  end

  defp run_rollback(remote_opts, json?) do
    case Remote.rollback(remote_opts) do
      {:ok, info} ->
        report(:rollback, info, json?)
        0

      {:error, reason} ->
        report_error(reason, json?)
        1
    end
  end

  defp report(kind, info, true) do
    info
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put("action", to_string(kind))
    |> Jason.encode!()
    |> IO.puts()
  end

  defp report(:check, info, false) do
    IO.puts("Current: #{info.current}")
    IO.puts("Latest:  #{info.latest || "unknown"}")
    report_artifact("Runtime", info[:artifact])
    report_artifact("TUI", info[:tui_artifact])
    IO.puts(if info.update_available?, do: "Update available.", else: "Up to date.")
  end

  defp report(:apply, %{staged: nil} = info, false) do
    IO.puts("Already up to date (#{info.current}).")
  end

  defp report(:apply, info, false) do
    IO.puts("Staged #{info.staged}. Restart to apply.")
  end

  defp report(:rollback, info, false) do
    IO.puts("Rolled back. Active version: #{info.active}")
  end

  defp report_artifact(_label, nil), do: :ok

  defp report_artifact(label, artifact) do
    case artifact["file"] do
      file when is_binary(file) -> IO.puts("#{label}: #{file}")
      _ -> :ok
    end
  end

  defp report_error(reason, true) do
    IO.puts(:stderr, Jason.encode!(%{"error" => inspect(reason)}))
  end

  defp report_error(reason, false) do
    IO.puts(:stderr, "Error: #{inspect(reason)}")
  end
end
