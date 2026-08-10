defmodule Mix.Tasks.Lemon.New do
  @shortdoc "Creates a new Lemon agent project"

  @moduledoc """
  Creates a new BEAM agent project wired to the Lemon platform packages.

      mix lemon.new my_agent

  The generated project is a plain, standalone Mix project — not an umbrella
  app — that depends on `lemon_core`, `lemon_ai` and `lemon_agent`. It contains
  a supervised agent, one example tool, a console channel, and a test suite that
  passes with no API key because the LLM is faked at the `stream_fn` seam.

  ## What you get

      my_agent/
        lib/my_agent.ex                  facade: MyAgent.ask/1
        lib/my_agent/application.ex      supervision tree
        lib/my_agent/agent.ex            model, prompt and tool wiring
        lib/my_agent/console.ex          the console channel: stdin -> agent -> stdout
        lib/my_agent/tools/word_count.ex the example tool
        test/support/fake_llm.ex         scripted LLM, so tests need no network

  ## Options

    * `--app` — the OTP application name. Defaults to the directory basename.
    * `--module` — the base module name. Defaults to the camel-cased app name.
    * `--channel` — additionally generate a real `LemonChannels.Plugin` adapter
      and a `LemonPlatformTest.PluginCase` compliance suite for it. This adds a
      dependency on `lemon_channels` and, for tests, `lemon_platform_test`.
    * `--memory` — additionally generate durable memory wiring on
      `lemon_memory` (adds a SQLite-backed dependency).
    * `--lemon-path` — path to a checkout of the `lemon` repository. The
      platform packages are not on Hex yet, so the generated `mix.exs` uses path
      dependencies pointing here. Defaults to `$LEMON_PATH`, then to the
      checkout this installer was built from.
    * `--install` / `--no-install` — run `mix deps.get` in the new project.
      Defaults to asking.

  ## Examples

      mix lemon.new my_agent
      mix lemon.new my_agent --channel --memory
      mix lemon.new agents/support_bot --app support_bot --module SupportBot
  """

  use Mix.Task

  alias LemonNew.{Generator, Project}

  # Where this installer was built from. Correct for the archive built out of a
  # lemon checkout, which is the only way to get one until the packages publish.
  @built_from Path.expand("../../../..", __DIR__)

  @switches [
    app: :string,
    module: :string,
    channel: :boolean,
    memory: :boolean,
    lemon_path: :string,
    install: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, argv} = OptionParser.parse!(argv, strict: @switches)

    case argv do
      [] ->
        Mix.raise("""
        Expected a project path.

            mix lemon.new PATH

        For example:

            mix lemon.new my_agent
        """)

      [base_path | _] ->
        generate(base_path, opts)
    end
  end

  defp generate(base_path, opts) do
    lemon_path = resolve_lemon_path(opts)
    project = Project.new(base_path, Keyword.put(opts, :lemon_path, lemon_path))

    Project.validate_app!(project.app)
    Project.validate_module!(project.app_module)
    check_directory!(project)

    created = Generator.copy(project)

    Mix.shell().info([:green, "* creating ", :reset, Path.relative_to_cwd(project.base_path)])

    for file <- created do
      Mix.shell().info([
        :green,
        "* creating ",
        :reset,
        Path.join(project.base_path, file) |> Path.relative_to_cwd()
      ])
    end

    maybe_install(project, opts)
    print_next_steps(project, opts)
  end

  defp check_directory!(%Project{base_path: path}) do
    if File.exists?(Path.join(path, "mix.exs")) do
      Mix.raise("""
      #{Path.relative_to_cwd(path)} already contains a mix.exs.

      Refusing to overwrite an existing project. Remove it or choose another path.
      """)
    end

    File.mkdir_p!(path)
  end

  defp resolve_lemon_path(opts) do
    path = opts[:lemon_path] || System.get_env("LEMON_PATH") || @built_from
    path = Path.expand(path)

    unless File.exists?(Path.join(path, "apps/agent_core/mix.exs")) do
      Mix.shell().error("""
      Warning: #{path} does not look like a lemon checkout (no apps/agent_core/mix.exs).

      The generated mix.exs will point its path dependencies there anyway, so
      `mix deps.get` will fail until you fix it. Pass --lemon-path or set
      $LEMON_PATH to the right directory.
      """)
    end

    path
  end

  defp maybe_install(project, opts) do
    install? =
      case Keyword.fetch(opts, :install) do
        {:ok, value} -> value
        :error -> Mix.shell().yes?("\nFetch and install dependencies?")
      end

    if install? do
      File.cd!(project.base_path, fn ->
        Mix.shell().cmd("mix deps.get")
      end)
    end
  end

  defp print_next_steps(project, opts) do
    relative = Path.relative_to_cwd(project.base_path)
    fetched? = opts[:install] == true

    Mix.shell().info("""

    Your Lemon agent project is ready.

        cd #{relative}#{unless fetched?, do: "\n    mix deps.get"}
        mix test

    The tests pass without an API key: `test/support/fake_llm.ex` scripts the
    model at the same seam the real provider plugs into. To talk to a real
    model, export a key and start the console:

        export ANTHROPIC_API_KEY=...
        mix run --no-halt -e "#{project.app_module}.Console.start()"

    Guides live in the lemon repo under docs/getting-started/.
    """)
  end
end
