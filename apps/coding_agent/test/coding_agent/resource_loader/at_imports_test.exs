defmodule CodingAgent.ResourceLoader.AtImportsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ResourceLoader.AtImports

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    project = Path.join(tmp_dir, "project")
    File.mkdir_p!(home)
    File.mkdir_p!(project)
    {:ok, home: home, project: project, source: Path.join(project, "AGENTS.md")}
  end

  defp expand(content, ctx), do: AtImports.expand(content, ctx.source, home: ctx.home)

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  test "imports resolve relative to the importing file, including nested imports", ctx do
    write!(Path.join(ctx.project, "docs/a.md"), "A then @b.md\n")
    write!(Path.join(ctx.project, "docs/b.md"), "B BODY")
    write!(Path.join(ctx.project, "notes.md"), "NOTES BODY")

    assert expand("@docs/a.md\nRead @notes.md now", ctx) ==
             "A then B BODY\nRead NOTES BODY now"
  end

  test "imports ~/ paths from home and absolute paths", ctx do
    write!(Path.join(ctx.home, ".notes/aliases.md"), "HOME ALIASES")
    absolute = write!(Path.join(ctx.project, "abs/target.md"), "ABSOLUTE BODY")

    assert expand("@~/.notes/aliases.md and @#{absolute}", ctx) ==
             "HOME ALIASES and ABSOLUTE BODY"
  end

  test "strips trailing punctuation from the path", ctx do
    write!(Path.join(ctx.project, "setup.md"), "SETUP")
    write!(Path.join(ctx.project, "other.md"), "OTHER")

    assert expand("See @setup.md. Also (@setup.md), @other.md!", ctx) ==
             "See SETUP. Also (@setup.md), OTHER!"
  end

  test "emails, git remotes and mid-word @ are never imports", ctx do
    write!(Path.join(ctx.project, "example.com"), "SHOULD NOT APPEAR")
    write!(Path.join(ctx.project, "github.com:org/repo.git"), "SHOULD NOT APPEAR")

    text = "Mail user@example.com or clone git@github.com:org/repo.git"
    assert expand(text, ctx) == text
  end

  test "fenced code blocks and inline code spans stay literal", ctx do
    write!(Path.join(ctx.project, "types/node"), "SHOULD NOT APPEAR")
    write!(Path.join(ctx.project, "real.md"), "REAL")

    content = """
    ```sh
    npm install @types/node
    ```
    ~~~~
    @real.md
    ```
    @real.md
    ~~~~
    Run `npm i @types/node` then @real.md
    """

    assert expand(content, ctx) == """
           ```sh
           npm install @types/node
           ```
           ~~~~
           @real.md
           ```
           @real.md
           ~~~~
           Run `npm i @types/node` then REAL
           """
  end

  test "a missing or directory target keeps the original token", ctx do
    File.mkdir_p!(Path.join(ctx.project, "somedir"))
    text = "Missing @nope.md and dir @somedir here"
    assert expand(text, ctx) == text
  end

  test "cycles stop silently and leave the cyclic token", ctx do
    write!(Path.join(ctx.project, "a.md"), "A -> @b.md")
    write!(Path.join(ctx.project, "b.md"), "B -> @a.md")

    assert expand("@a.md", ctx) == "A -> B -> @a.md"
    # The importing file itself is part of the visited set.
    write!(ctx.source, "self @AGENTS.md")
    assert expand("self @AGENTS.md", ctx) == "self @AGENTS.md"
  end

  test "imports follow at most five hops", ctx do
    for n <- 1..6 do
      write!(Path.join(ctx.project, "f#{n}.md"), "F#{n} @f#{n + 1}.md")
    end

    result = expand("@f1.md", ctx)
    assert result == "F1 F2 F3 F4 F5 @f6.md"
    refute result =~ "F6"
  end

  test "bounds each imported file", ctx do
    write!(Path.join(ctx.project, "big.md"), String.duplicate("x", 70_000))

    result = expand("@big.md", ctx)
    assert result =~ "[... imported file truncated at 65536 bytes]"
    assert byte_size(result) < 66_000
  end
end
