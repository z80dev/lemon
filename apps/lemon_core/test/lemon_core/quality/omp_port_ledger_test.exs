defmodule LemonCore.Quality.OmpPortLedgerTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)
  @origin ~r/omp's|oh-my-pi|pi-mono|ports the TypeScript|\.omp\//i
  @dispositions ["native port", "depend on package", "delegate via lemon_omp"]

  test "every origin-citing source has an exact ledger row with a disposition and acceptance" do
    ledger = File.read!(Path.join(@repo_root, "docs/omp-port-ledger.md"))
    sources = origin_sources(@repo_root)
    assert sources != []
    assert uncovered(sources, ledger) == []
  end

  test "coverage rejects missing rows, prose mentions and incomplete dispositions" do
    source = "apps/example/lib/ported.ex"

    assert uncovered([source], "See `#{source}` for the original port.") == [source]
    assert uncovered([source], "| `#{source}` | omp unknown | undecided | `test` |") == [source]
    assert uncovered([source], "| `#{source}` | omp unknown | native port | |") == [source]

    assert uncovered([source], "| `#{source}` | omp unknown | native port | `test` |") == []
  end

  test "source discovery covers all origin spellings and excludes tests and dependencies" do
    root =
      Path.join(
        System.tmp_dir!(),
        "omp_port_ledger_#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    sources = [
      {"apps/example/lib/a.ex", "OMP's plan"},
      {"apps/example/lib/b.ex", "oh-my-pi"},
      {"apps/example/lib/c.ex", "pi-mono"},
      {"clients/example/src/a.ts", "ports the TypeScript Agent"},
      {"clients/example/src/b.tsx", ".omp/agents"},
      {"clients/example/src/c.js", "oh-my-pi"}
    ]

    ignored = [
      {"apps/example/test/a.exs", "omp's test fixture"},
      {"apps/example/lib/unrelated.ex", "An ordinary module"},
      {"clients/example/src/node_modules/vendor/a.ts", "oh-my-pi"}
    ]

    for {path, content} <- sources ++ ignored do
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end

    expected = sources |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert origin_sources(root) == expected
  end

  defp origin_sources(root) do
    ["apps/*/lib/**/*.ex", "clients/*/src/**/*.{ts,tsx,js}"]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.reject(&("node_modules" in Path.split(&1)))
    |> Enum.filter(&Regex.match?(@origin, File.read!(&1)))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  defp uncovered(sources, ledger) do
    rows =
      ledger
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "|"))
      |> Enum.map(fn row ->
        row |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)
      end)

    Enum.reject(sources, fn source ->
      Enum.any?(rows, fn
        [path, origin, disposition, acceptance] ->
          path == "`#{source}`" and origin != "" and acceptance != "" and
            Enum.any?(@dispositions, &String.starts_with?(disposition, &1))

        _ ->
          false
      end)
    end)
  end
end
