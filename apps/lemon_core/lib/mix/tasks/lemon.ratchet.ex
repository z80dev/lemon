defmodule Mix.Tasks.Lemon.Ratchet do
  use Mix.Task

  alias LemonCore.Quality.RatchetCheck

  @shortdoc "Measure the quality ratchets and compare them with .ratchets.exs"
  @moduledoc """
  Measure the repository's quality ratchets.

  Usage:
    mix lemon.ratchet              # print measurements; fail on any regression
    mix lemon.ratchet --update     # lower ratchets to the current measurements
    mix lemon.ratchet --root PATH

  A ratchet is a count that may only go down. `mix lemon.quality` runs the
  same comparison; this task exists to print the table and to record lower
  values after a cleanup. See `LemonCore.Quality.RatchetCheck`.
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, switches: [root: :string, update: :boolean], aliases: [r: :root])

    root = opts[:root] || File.cwd!()

    if opts[:update] do
      {:ok, %{measurements: measurements, baselines: baselines}} =
        RatchetCheck.update_baselines(root)

      print_table(measurements, baselines)
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

    Enum.each(RatchetCheck.metrics(), fn {key, _doc} ->
      current = Map.fetch!(measurements, key)
      ratchet = Map.get(baselines, key)

      Mix.shell().info(
        String.pad_trailing(Atom.to_string(key), 24) <>
          String.pad_leading(Integer.to_string(current), 9) <>
          String.pad_leading(format_ratchet(ratchet), 10)
      )
    end)
  end

  defp format_ratchet(nil), do: "-"
  defp format_ratchet(value), do: Integer.to_string(value)
end
