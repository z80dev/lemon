defmodule Mix.Tasks.Lemon.Ratchet do
  use Mix.Task

  alias LemonCore.Quality.RatchetCheck

  @shortdoc "Measure architecture-debt ratchets"
  @moduledoc """
  Measures the repository's architecture-debt ratchets.

      mix lemon.ratchet
      mix lemon.ratchet --update
      mix lemon.ratchet --root /path/to/repo

  The default mode prints current values and fails when any value exceeds its
  baseline. `--update` records lower current values and never raises a ratchet.
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [root: :string, update: :boolean],
        aliases: [r: :root]
      )

    root = opts[:root] || File.cwd!()

    if opts[:update] do
      {:ok, report} = RatchetCheck.update_baselines(root)
      print_table(report.measurements, report.baselines)
      Mix.shell().info("Recorded #{RatchetCheck.baseline_file()}.")
    else
      case RatchetCheck.run(root: root) do
        {:ok, report} ->
          print_table(report.measurements, report.baselines)
          Mix.shell().info("All ratchets hold.")

        {:error, report} ->
          print_table(report.measurements, report.baselines)

          Enum.each(report.issues, fn issue ->
            Mix.shell().error("  - [#{issue.code}] #{issue.message}")
          end)

          Mix.raise("Ratchet check failed (#{report.issue_count} issues).")
      end
    end
  end

  defp print_table(measurements, baselines) do
    Mix.shell().info(String.pad_trailing("metric", 24) <> "  current   ratchet")

    Enum.each(RatchetCheck.metrics(), fn {key, _description} ->
      current = Map.fetch!(measurements, key)
      baseline = Map.get(baselines, key)

      Mix.shell().info(
        String.pad_trailing(Atom.to_string(key), 24) <>
          String.pad_leading(Integer.to_string(current), 9) <>
          String.pad_leading(format_baseline(baseline), 10)
      )
    end)
  end

  defp format_baseline(nil), do: "-"
  defp format_baseline(value), do: Integer.to_string(value)
end
