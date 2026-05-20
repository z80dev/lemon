defmodule CodingAgent.Tools.LspDiagnosticsTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.Tools.LspDiagnostics

  @moduletag :tmp_dir

  describe "diagnose_file/3" do
    test "reports clean Elixir syntax", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ok.exs")
      File.write!(path, "value = 1\n")

      assert {:ok, result} = LspDiagnostics.diagnose_file(path, tmp_dir, semantic: false)
      assert result.status == :clean
      assert result.language == :elixir
      assert result.diagnostics == []
    end

    test "reports Elixir syntax diagnostics", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.exs")
      File.write!(path, "defmodule Bad do\n")

      assert {:ok, result} = LspDiagnostics.diagnose_file(path, tmp_dir)
      assert result.status == :diagnostics

      assert [%{line: 1, severity: "error", source: "elixir syntax"} = diagnostic] =
               result.diagnostics

      assert diagnostic.message =~ "missing terminator"
    end

    test "reports clean Python syntax when python is available", %{tmp_dir: tmp_dir} do
      if python_available?() do
        path = Path.join(tmp_dir, "ok.py")
        File.write!(path, "value = 1\n")

        assert {:ok, result} = LspDiagnostics.diagnose_file(path, tmp_dir)
        assert result.status == :clean
        assert result.language == :python
        assert result.diagnostics == []
        assert result.source == "python py_compile"
      end
    end

    test "reports Python syntax diagnostics when python is available", %{tmp_dir: tmp_dir} do
      if python_available?() do
        path = Path.join(tmp_dir, "bad.py")
        File.write!(path, "def broken(:\n")

        assert {:ok, result} = LspDiagnostics.diagnose_file(path, tmp_dir)
        assert result.status == :diagnostics
        assert result.language == :python

        assert [%{line: 1, severity: "error", source: "python py_compile"} = diagnostic] =
                 result.diagnostics

        assert diagnostic.message =~ "SyntaxError"
      end
    end

    test "skips TypeScript files without a workspace tsconfig", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "component.ts")
      File.write!(path, "const value: number = 1\n")

      assert {:ok, result} = LspDiagnostics.diagnose_file(path, tmp_dir)
      assert result.status == :skipped
      assert result.language == :typescript
      assert result.reason == "no tsconfig.json found"
    end

    test "reports JavaScript syntax diagnostics when node is available", %{tmp_dir: tmp_dir} do
      if System.find_executable("node") do
        path = Path.join(tmp_dir, "bad.js")
        File.write!(path, "function broken( {\n")

        assert {:ok, result} = LspDiagnostics.diagnose_file(path, tmp_dir)
        assert result.status == :diagnostics
        assert result.language == :javascript

        assert [%{severity: "error", source: "node --check"} = diagnostic | _] =
                 result.diagnostics

        assert diagnostic.message != ""
      end
    end

    test "reports TypeScript diagnostics with a tsconfig workspace when tsc is available", %{
      tmp_dir: tmp_dir
    } do
      if System.find_executable("tsc") do
        File.write!(
          Path.join(tmp_dir, "tsconfig.json"),
          ~s({"compilerOptions":{"strict":true,"noEmit":true},"include":["*.ts"]}\n)
        )

        path = Path.join(tmp_dir, "bad.ts")
        File.write!(path, ~s(const value: number = "bad";\n))

        assert {:ok, result} = LspDiagnostics.diagnose_file(path, tmp_dir)
        assert result.status == :diagnostics
        assert result.language == :typescript

        assert [%{line: 1, column: 7, severity: "error", source: "tsc --noEmit"} = diagnostic] =
                 result.diagnostics

        assert diagnostic.message =~ "not assignable"
      end
    end

    test "reports Go diagnostics with a go.mod workspace when go is available", %{
      tmp_dir: tmp_dir
    } do
      if System.find_executable("go") do
        File.write!(Path.join(tmp_dir, "go.mod"), "module example.com/lemonfixture\n\ngo 1.21\n")

        path = Path.join(tmp_dir, "main.go")
        File.write!(path, "package main\n\nfunc main() { var n int = \"bad\"; _ = n }\n")

        assert {:ok, result} = LspDiagnostics.diagnose_file(path, tmp_dir)
        assert result.status == :diagnostics
        assert result.language == :go

        assert [%{line: 3, column: 27, severity: "error", source: "go test"} = diagnostic | _] =
                 result.diagnostics

        assert diagnostic.message =~ "cannot use"
      end
    end

    test "reports Rust diagnostics with a Cargo workspace when cargo is available", %{
      tmp_dir: tmp_dir
    } do
      if cargo_available?() do
        File.write!(
          Path.join(tmp_dir, "Cargo.toml"),
          "[package]\nname = \"lemon_fixture\"\nversion = \"0.1.0\"\nedition = \"2021\"\n"
        )

        src_dir = Path.join(tmp_dir, "src")
        File.mkdir_p!(src_dir)

        path = Path.join(src_dir, "main.rs")
        File.write!(path, "fn main() { let value: i32 = \"bad\"; println!(\"{}\", value); }\n")

        assert {:ok, result} = LspDiagnostics.diagnose_file(path, tmp_dir)
        assert result.status == :diagnostics
        assert result.language == :rust

        assert [%{line: 1, column: 30, severity: "error", source: "cargo check"} = diagnostic | _] =
                 result.diagnostics

        assert diagnostic.message =~ "mismatched types"
      end
    end

    test "reports C diagnostics when a C compiler is available", %{tmp_dir: tmp_dir} do
      if c_compiler_available?() do
        path = Path.join(tmp_dir, "bad.c")
        File.write!(path, "int main(void) { return \"bad\" }\n")

        assert {:ok, result} = LspDiagnostics.diagnose_file(path, tmp_dir)
        assert result.status == :diagnostics
        assert result.language == :c_cpp

        assert [%{line: 1, severity: "error"} = diagnostic | _] = result.diagnostics
        assert diagnostic.source =~ "-fsyntax-only"
        assert diagnostic.message != ""
      end
    end

    test "skips unsupported files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "notes.txt")
      File.write!(path, "hello\n")

      assert {:ok, result} = LspDiagnostics.diagnose_file(path, tmp_dir)
      assert result.status == :skipped
      assert result.reason == "unsupported file extension"
    end
  end

  describe "post_edit/5" do
    test "returns only introduced diagnostics", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.exs")
      File.write!(path, "defmodule Bad do\n")
      baseline = LspDiagnostics.baseline(path, tmp_dir, true, semantic: false)

      File.write!(path, "defmodule Bad do\n")

      {report, text} = LspDiagnostics.post_edit(path, tmp_dir, baseline, true, semantic: false)

      assert report.status == :diagnostics
      assert report.introduced_diagnostics == []
      assert text =~ "pre-existing"
    end

    test "reports all diagnostics for a new broken file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "new_bad.exs")
      baseline = nil

      File.write!(path, "defmodule Bad do\n")

      {report, text} = LspDiagnostics.post_edit(path, tmp_dir, baseline, true, semantic: false)

      assert report.status == :diagnostics
      assert length(report.introduced_diagnostics) == 1
      assert text =~ "Diagnostics introduced 1 issue"
    end
  end

  describe "tool/2" do
    test "executes diagnostics as a model-facing tool", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.exs")
      File.write!(path, "defmodule Bad do\n")

      tool = LspDiagnostics.tool(tmp_dir)
      assert tool.name == "lsp_diagnostics"

      assert %AgentToolResult{details: details, content: [content]} =
               tool.execute.("call_1", %{"path" => path}, nil, nil)

      assert details.status == :diagnostics
      assert content.text =~ "Diagnostics found 1 issue"
    end
  end

  describe "status/1" do
    test "returns redacted operator capability metadata" do
      status = LspDiagnostics.status()

      assert status.status == :preview
      assert status.default_timeout_ms == 20_000
      assert status.supported_language_count >= 6
      assert Enum.any?(status.supported_languages, &(&1.language == :elixir))
      assert is_integer(status.executable_summary.available_count)
      assert status.cleanup.includes_raw_paths == false
      assert status.cleanup.includes_file_contents == false
      assert status.cleanup.includes_diagnostics_output == false
      assert status.cleanup.includes_workspace_roots == false
    end
  end

  defp python_available? do
    System.find_executable("python3") != nil or System.find_executable("python") != nil
  end

  defp c_compiler_available? do
    Enum.any?(["clang", "gcc", "cc"], &(System.find_executable(&1) != nil))
  end

  defp cargo_available? do
    case System.find_executable("cargo") do
      nil ->
        false

      cargo ->
        case System.cmd(cargo, ["--version"], stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end
    end
  end
end
