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

  import ExUnit.CaptureLog

  # Project files import only inside their trusted root. Provenance markers are
  # stripped here so structural tests compare the spliced content; a dedicated
  # test asserts the markers.
  defp expand(content, ctx, opts \\ []), do: content |> raw(ctx, opts) |> unmark()

  defp expand_global(content, ctx), do: content |> raw(ctx, root: :unconfined) |> unmark()

  defp raw(content, ctx, opts \\ []) do
    opts = [home: ctx.home] ++ Keyword.put_new(opts, :root, ctx.project)
    {text, _identities} = AtImports.expand(content, ctx.source, opts)
    text
  end

  defp unmark(text), do: Regex.replace(~r/<!-- (?:@import [^>]*|\/@import) -->/, text, "")

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

  test "home-owned global files import ~/ paths from home and absolute paths", ctx do
    write!(Path.join(ctx.home, ".notes/aliases.md"), "HOME ALIASES")
    absolute = write!(Path.join(ctx.project, "abs/target.md"), "ABSOLUTE BODY")

    assert expand_global("@~/.notes/aliases.md and @#{absolute}", ctx) ==
             "HOME ALIASES and ABSOLUTE BODY"
  end

  test "project files never import home, absolute or traversal targets", ctx do
    write!(Path.join(ctx.home, ".ssh/id_ed25519"), "PRIVATE-KEY-BYTES")
    outside = write!(Path.join(Path.dirname(ctx.project), "outside/secret.md"), "OUTSIDE-BYTES")
    passwd = if File.regular?("/etc/passwd"), do: "/etc/passwd", else: outside

    text =
      "See @~/.ssh/id_ed25519 and @#{passwd} and @../../../etc/passwd and " <>
        "@../outside/secret.md and @#{outside}"

    log =
      capture_log(fn ->
        assert raw(text, ctx) == text
      end)

    for token <- ["~/.ssh/id_ed25519", passwd, "../outside/secret.md", outside],
        do: assert(log =~ "Refused @import #{token}", token)
  end

  test "symlinks and hard links leading outside the trusted root are refused", ctx do
    secret = write!(Path.join(ctx.home, ".ssh/id_rsa"), "PRIVATE-KEY-BYTES")
    File.ln_s!(secret, Path.join(ctx.project, "linked.md"))
    File.ln_s!(Path.dirname(secret), Path.join(ctx.project, "linkdir"))
    File.ln!(secret, Path.join(ctx.project, "hard.md"))

    text = "@linked.md @linkdir/id_rsa @hard.md"

    log =
      capture_log(fn ->
        assert raw(text, ctx) == text
      end)

    for token <- ["linked.md", "linkdir/id_rsa", "hard.md"],
        do: assert(log =~ "Refused @import #{token}", token)

    # A symlink that stays inside the root still imports.
    inside = write!(Path.join(ctx.project, "docs/real.md"), "INSIDE")
    File.ln_s!(inside, Path.join(ctx.project, "alias.md"))
    assert expand("@alias.md", ctx) == "INSIDE"
  end

  test "imported spans are labelled with their resolved source path", ctx do
    target = write!(Path.join(ctx.project, "docs/a.md"), "A BODY")
    {:ok, real} = LemonCore.TrustedRoot.realpath(target)

    assert raw("Read @docs/a.md now", ctx) ==
             "Read <!-- @import #{real} -->A BODY<!-- /@import --> now"
  end

  test "files in :skip, including symlink aliases, stay literal", ctx do
    agents = write!(Path.join(ctx.project, "AGENTS.md"), "AGENTS BODY")
    File.ln_s!(agents, Path.join(ctx.project, "alias.md"))
    doc = write!(Path.join(ctx.project, "docs/a.md"), "DOC BODY")
    skip = [AtImports.identity(agents)]

    assert expand("@AGENTS.md @alias.md @docs/a.md", ctx, skip: skip) ==
             "@AGENTS.md @alias.md DOC BODY"

    {_text, identities} =
      AtImports.expand("@docs/a.md", ctx.source, home: ctx.home, root: ctx.project, skip: skip)

    assert MapSet.subset?(MapSet.new([AtImports.identity(doc) | skip]), identities)
    assert expand("@docs/a.md", ctx, skip: identities) == "@docs/a.md"
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

    code = "``outer ` @real.md\nstill @real.md ``"
    assert expand(code, ctx) == code
    assert expand(code <> "\n@real.md", ctx) == code <> "\nREAL"
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
