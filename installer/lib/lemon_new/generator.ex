defmodule LemonNew.Generator do
  @moduledoc """
  Renders the templates under `installer/templates` into a target directory.

  Templates are read at compile time and embedded in this module's beam file,
  because the installer ships as a mix archive with no access to the source
  tree it was built from.
  """

  alias LemonNew.Project

  @templates_root Path.expand("../../templates", __DIR__)

  @template_files @templates_root
                  |> Path.join("**/*.eex")
                  |> Path.wildcard()
                  |> Enum.sort()

  for file <- @template_files do
    @external_resource file
  end

  @templates Map.new(@template_files, fn file ->
               {Path.relative_to(file, @templates_root), File.read!(file)}
             end)

  # {template, destination}. The destination is relative to the project root and
  # may contain `:app`, replaced with the application name. Listing them here
  # rather than deriving destinations from template paths keeps the mapping
  # greppable — it is the first thing you want to see when a generated file
  # lands in the wrong place.
  @base [
    {"base/gitignore.eex", ".gitignore"},
    {"base/formatter.exs.eex", ".formatter.exs"},
    {"base/README.md.eex", "README.md"},
    {"base/mix.exs.eex", "mix.exs"},
    {"base/config/config.exs.eex", "config/config.exs"},
    {"base/config/runtime.exs.eex", "config/runtime.exs"},
    {"base/lib/app.ex.eex", "lib/:app.ex"},
    {"base/lib/app/application.ex.eex", "lib/:app/application.ex"},
    {"base/lib/app/agent.ex.eex", "lib/:app/agent.ex"},
    {"base/lib/app/console.ex.eex", "lib/:app/console.ex"},
    {"base/lib/app/tools/word_count.ex.eex", "lib/:app/tools/word_count.ex"},
    {"base/test/test_helper.exs.eex", "test/test_helper.exs"},
    {"base/test/support/fake_llm.ex.eex", "test/support/fake_llm.ex"},
    {"base/test/app/agent_test.exs.eex", "test/:app/agent_test.exs"},
    {"base/test/app/tools/word_count_test.exs.eex", "test/:app/tools/word_count_test.exs"}
  ]

  @channel [
    {"channel/lib/app/channel.ex.eex", "lib/:app/channel.ex"},
    {"channel/test/app/channel_test.exs.eex", "test/:app/channel_test.exs"}
  ]

  @memory [
    {"memory/lib/app/memory.ex.eex", "lib/:app/memory.ex"},
    {"memory/test/app/memory_test.exs.eex", "test/:app/memory_test.exs"}
  ]

  @doc "Every template path known to the generator, for tests and tooling."
  @spec template_paths() :: [String.t()]
  def template_paths, do: Map.keys(@templates) |> Enum.sort()

  @doc """
  The files this project will produce, as `{template, destination}` pairs with
  `:app` already substituted.
  """
  @spec files(Project.t()) :: [{String.t(), String.t()}]
  def files(%Project{} = project) do
    (@base ++
       if(project.channel?, do: @channel, else: []) ++
       if(project.memory?, do: @memory, else: []))
    |> Enum.map(fn {template, dest} ->
      {template, String.replace(dest, ":app", project.app_path)}
    end)
  end

  @doc """
  Renders every file for `project` into `project.base_path`.

  Returns the list of created paths, relative to the project root.
  """
  @spec copy(Project.t()) :: [String.t()]
  def copy(%Project{} = project) do
    assigns = Project.assigns(project)

    for {template, dest} <- files(project) do
      target = Path.join(project.base_path, dest)
      target |> Path.dirname() |> File.mkdir_p!()
      File.write!(target, template |> render(assigns) |> format(dest))
      dest
    end
  end

  # Running the formatter over generated Elixir keeps the templates readable
  # (they may leave trailing commas and blank lines where a conditional block
  # was skipped) and turns a template that no longer parses into a generator
  # failure rather than a broken project.
  defp format(contents, dest) do
    if Path.extname(dest) in [".ex", ".exs"] do
      contents
      |> Code.format_string!(file: dest)
      |> IO.iodata_to_binary()
      |> Kernel.<>("\n")
    else
      contents
    end
  end

  @doc """
  Renders one template to a string.

  Exposed so tests can assert on generated content without touching disk.
  """
  @spec render(String.t(), keyword()) :: String.t()
  def render(template, assigns) do
    body =
      Map.get(@templates, template) ||
        raise ArgumentError, "unknown template: #{template}"

    EEx.eval_string(body, assigns: assigns, trim: true)
  end
end
