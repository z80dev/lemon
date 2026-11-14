defmodule Mix.Tasks.Lemon.Help do
  use Mix.Task

  @shortdoc "List all mix lemon.* tasks, grouped by purpose"

  @moduledoc """
  Print every `mix lemon.*` task grouped by purpose.

  `mix help | grep lemon` lists the ~70 Lemon tasks alphabetically with no
  grouping. This task prints the same set organized into logical groups, reading
  each task's `@shortdoc` at runtime so the descriptions never drift from the
  code.

  ## Usage

      mix lemon.help

  See `docs/mix-tasks.md` for the same grouping with flags, examples, and
  follow-up notes.
  """

  # Ordered groups of task names. Descriptions are pulled from each task's
  # @shortdoc at runtime; @fallback covers tasks that ship without one (or that
  # live outside the umbrella, like lemon.new in the installer archive).
  @groups [
    {"Onboarding & setup",
     ~w(lemon.new lemon.setup lemon.onboard lemon.onboard.anthropic lemon.onboard.codex
        lemon.onboard.copilot lemon.onboard.gemini lemon.onboard.antigravity lemon.providers
        lemon.workspace lemon.update)},
    {"Secrets", ~w(lemon.secrets.init lemon.secrets.set lemon.secrets.list lemon.secrets.status
        lemon.secrets.check lemon.secrets.delete lemon.secrets.import_env lemon.voice.secrets)},
    {"Diagnostics",
     ~w(lemon.doctor lemon.config lemon.channels lemon.usage lemon.media lemon.models
        lemon.introspection lemon.feedback)},
    {"Quality & CI", ~w(lemon.quality lemon.architecture.docs lemon.check_duplicate_tests
        lemon.extension.validate lemon.eval lemon.help)},
    {"Data, stores & messaging",
     ~w(lemon.store.migrate_jsonl_to_sqlite lemon.memory lemon.policy lemon.send)},
    {"Skills", ~w(lemon.skill lemon.skill.lint)},
    {"Benchmarks (platform)", ~w(lemon.bench)}
  ]

  @fallback %{
    "lemon.new" => "Scaffold a new Lemon agent project (installer archive)",
    "lemon.policy" => "Manage per-route model policies (channel/account/peer/thread)",
    "lemon.channels" => "Show redacted Telegram/Discord configuration status",
    "lemon.config" => "Validate and inspect Lemon configuration",
    "lemon.usage" => "Show redacted usage, cost, token, and quota diagnostics",
    "lemon.media" => "Show redacted generated-media job diagnostics",
    "lemon.skill" => "Manage Lemon skills (discover/install/update/remove)"
  }

  @impl true
  def run(_args) do
    Mix.Task.load_all()

    count = @groups |> Enum.flat_map(fn {_t, tasks} -> tasks end) |> length()

    Mix.shell().info("Lemon mix tasks (#{count}). See docs/mix-tasks.md for flags and examples.")

    Enum.each(@groups, fn {title, tasks} ->
      Mix.shell().info("\n" <> IO.iodata_to_binary(IO.ANSI.format([:bright, title])))

      Enum.each(tasks, fn name ->
        desc = describe(name)
        Mix.shell().info("  mix " <> String.pad_trailing(name, 34) <> "  " <> desc)
      end)
    end)

    :ok
  end

  defp describe(name) do
    shortdoc(name) || Map.get(@fallback, name, "")
  end

  defp shortdoc(name) do
    case Mix.Task.get(name) do
      nil -> nil
      module -> Mix.Task.shortdoc(module)
    end
  rescue
    _ -> nil
  end
end
