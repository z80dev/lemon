defmodule LemonLsp.WorkspaceRootTest do
  use ExUnit.Case, async: true

  alias LemonLsp.WorkspaceRoot

  setup do
    tmp = Path.join(System.tmp_dir!(), "lsp_workspace_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp write(root, relative, content \\ "") do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  test "files in different umbrella apps share the umbrella root", %{tmp: tmp} do
    write(tmp, "mix.exs", "def project, do: [apps_path: \"apps\", version: \"0.1.0\"]")
    write(tmp, "apps/a/mix.exs", "def project, do: [app: :a]")
    write(tmp, "apps/b/mix.exs", "def project, do: [app: :b]")
    a = write(tmp, "apps/a/lib/a.ex")
    b = write(tmp, "apps/b/test/b_test.exs")

    assert WorkspaceRoot.detect(a, tmp, ["mix.exs"]) == tmp
    assert WorkspaceRoot.detect(b, tmp, ["mix.exs"]) == tmp
  end

  test "a cwd of / contains every file", %{tmp: tmp} do
    write(tmp, "mix.exs", "def project, do: [apps_path: \"apps\"]")
    write(tmp, "apps/a/mix.exs", "def project, do: [app: :a]")
    a = write(tmp, "apps/a/lib/a.ex")

    assert WorkspaceRoot.detect(a, "/", ["mix.exs"]) == tmp
    assert WorkspaceRoot.detect("/x.ex", "/", ["absent.marker"]) == "/"
  end

  test "the outermost workspace wins over nested workspaces", %{tmp: tmp} do
    write(tmp, "Cargo.toml", "[workspace]\nmembers = [\"crates/*\"]\n")
    write(tmp, "crates/inner/Cargo.toml", "[workspace]\n[package]\nname = \"inner\"\n")
    file = write(tmp, "crates/inner/src/lib.rs")

    assert WorkspaceRoot.detect(file, tmp, ["Cargo.toml"]) == tmp
  end

  test "package-manager, Go and uv workspaces are recognised", %{tmp: tmp} do
    npm = Path.join(tmp, "npm")
    write(npm, "package.json", ~s({"private": true, "workspaces": ["packages/*"]}))
    write(npm, "packages/ui/package.json", ~s({"name": "ui"}))
    ui = write(npm, "packages/ui/src/index.ts")
    assert WorkspaceRoot.detect(ui, tmp, ["tsconfig.json", "package.json"]) == npm

    pnpm = Path.join(tmp, "pnpm")
    write(pnpm, "pnpm-workspace.yaml", "packages:\n  - apps/*\n")
    write(pnpm, "apps/web/package.json", ~s({"name": "web"}))
    web = write(pnpm, "apps/web/main.js")
    assert WorkspaceRoot.detect(web, tmp, ["package.json"]) == pnpm

    go = Path.join(tmp, "go")
    write(go, "go.work", "go 1.22\nuse ./svc\n")
    write(go, "svc/go.mod", "module svc\n")
    svc = write(go, "svc/main.go")
    assert WorkspaceRoot.detect(svc, tmp, ["go.mod"]) == go

    uv = Path.join(tmp, "uv")
    write(uv, "pyproject.toml", "[tool.uv.workspace]\nmembers = [\"pkgs/*\"]\n")
    write(uv, "pkgs/core/pyproject.toml", "[project]\nname = \"core\"\n")
    core = write(uv, "pkgs/core/core.py")
    assert WorkspaceRoot.detect(core, tmp, ["pyproject.toml"]) == uv
  end

  test "without a workspace the nearest marker wins, else the cwd", %{tmp: tmp} do
    write(tmp, "package.json", ~s({"name": "root"}))
    write(tmp, "tools/cli/package.json", ~s({"name": "cli"}))
    cli = write(tmp, "tools/cli/src/main.ts")
    assert WorkspaceRoot.detect(cli, tmp, ["package.json"]) == Path.join(tmp, "tools/cli")

    loose = write(tmp, "notes/x.c")
    assert WorkspaceRoot.detect(loose, tmp, ["compile_flags.txt"]) == tmp
  end

  test "a workspace for another server's markers is ignored", %{tmp: tmp} do
    write(tmp, "mix.exs", "def project, do: [apps_path: \"apps\"]")
    write(tmp, "apps/web/assets/package.json", ~s({"name": "assets"}))
    js = write(tmp, "apps/web/assets/js/app.js")

    assert WorkspaceRoot.detect(js, tmp, ["package.json"]) == Path.join(tmp, "apps/web/assets")
  end

  test "a file outside the cwd never adopts an enclosing workspace", %{tmp: tmp} do
    write(tmp, "mix.exs", "def project, do: [apps_path: \"apps\"]")
    write(tmp, "apps/a/mix.exs", "def project, do: [app: :a]")
    cwd = Path.join(tmp, "elsewhere")
    File.mkdir_p!(cwd)
    file = write(tmp, "apps/a/lib/a.ex")

    assert WorkspaceRoot.detect(file, cwd, ["mix.exs"]) == Path.join(tmp, "apps/a")

    stray = write(tmp, "stray/x.ex")
    assert WorkspaceRoot.detect(stray, cwd, ["absent.marker"]) == Path.join(tmp, "stray")
  end
end
