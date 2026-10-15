# Run from the umbrella root:
#   mix run --no-start scripts/generate_config_registry.exs [--check]
# No applications or credential resolvers are started.

defmodule ConfigRegistryGenerator do
  def render(path) do
    Enum.each(LemonCore.Env.registries(), &Code.ensure_loaded!/1)
    [preamble, _tables] = String.split(File.read!(path), "## Variables by area", parts: 2)

    tables =
      LemonCore.Env.all_declared()
      |> Enum.group_by(& &1.area)
      |> Enum.sort_by(fn {area, _} -> area end)
      |> Enum.map_join("\n", fn {area, declarations} ->
        title = area |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

        rows =
          declarations
          |> Enum.sort_by(& &1.env_var)
          |> Enum.map_join("\n", &row/1)

        "### #{title}\n\n" <>
          "| Env Var | Type | Default | Secret | Apps | Description |\n" <>
          "|---|---|---|---|---|---|\n" <> rows <> "\n"
      end)

    preamble <> "## Variables by area\n\n" <> tables
  end

  defp row(declaration) do
    aliases =
      case declaration.aliases do
        [] -> ""
        names -> "<br>_(alias: #{Enum.map_join(names, ", ", &code/1)})_"
      end

    default =
      case declaration.default do
        nil -> "_(none)_"
        value when is_binary(value) -> code(value)
        value -> code(inspect(value))
      end

    type =
      case declaration.type do
        :list -> "list (comma-separated)"
        :bytes -> "bytes (B/KB/MB/GB)"
        type -> Atom.to_string(type)
      end

    cells = [
      code(declaration.env_var) <> aliases,
      type,
      default,
      if(declaration.secret?, do: "yes", else: ""),
      Enum.map_join(declaration.apps, ", ", &code(Atom.to_string(&1))),
      escape(declaration.doc)
    ]

    "| " <> Enum.join(cells, " | ") <> " |"
  end

  defp code(value), do: "`" <> escape(value) <> "`"
  defp escape(value), do: value |> String.replace("|", "&#124;") |> String.replace("\n", "<br>")
end

path = Path.expand("../docs/config-registry.md", __DIR__)
rendered = ConfigRegistryGenerator.render(path)

case System.argv() do
  [] ->
    File.write!(path, rendered)
    IO.puts("Regenerated docs/config-registry.md from LemonCore.Env.all_declared/0")

  ["--check"] ->
    if File.read!(path) != rendered do
      Mix.raise(
        "Environment registry is stale; run mix run --no-start scripts/generate_config_registry.exs"
      )
    end

    IO.puts("Environment registry matches all declared variables")

  _ ->
    Mix.raise("Usage: mix run --no-start scripts/generate_config_registry.exs [--check]")
end
