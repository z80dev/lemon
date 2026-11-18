defmodule CodingAgent.Tools.LspFormatterTest do
  @moduledoc """
  Tests for the LSP-inspired auto-formatter.
  """
  # Fake formatters are installed on PATH.
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.LspFormatter

  @moduletag :tmp_dir

  # ============================================================================
  # formatable?/1
  # ============================================================================

  describe "formatable?/1" do
    test "returns true for known formatters" do
      assert LspFormatter.formatable?("file.ex")
      assert LspFormatter.formatable?("file.exs")
      assert LspFormatter.formatable?("file.js")
      assert LspFormatter.formatable?("file.ts")
      assert LspFormatter.formatable?("file.py")
      assert LspFormatter.formatable?("file.rs")
      assert LspFormatter.formatable?("file.go")
    end

    test "returns false for unknown extensions" do
      refute LspFormatter.formatable?("file.xyz")
      refute LspFormatter.formatable?("file.unknown")
      refute LspFormatter.formatable?("file")
    end

    test "is case-insensitive for extensions" do
      assert LspFormatter.formatable?("file.EX")
      assert LspFormatter.formatable?("file.JS")
    end
  end

  # ============================================================================
  # format_content/3
  # ============================================================================

  describe "format_content/3" do
    test "returns the content for files without formatters", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "file.xyz")
      assert {:ok, "content"} = LspFormatter.format_content(path, "content")
    end

    test "returns the content when the formatter executable is missing", %{tmp_dir: tmp_dir} do
      with_path(Path.join(tmp_dir, "empty-bin"), fn ->
        path = Path.join(tmp_dir, "main.go")
        assert {:ok, "package main\n"} = LspFormatter.format_content(path, "package main\n")
      end)
    end

    test "rejects a non-positive timeout", %{tmp_dir: tmp_dir} do
      fake_formatter(tmp_dir, "gofmt", "cat")

      with_path(bin(tmp_dir), fn ->
        assert {:error, "timeout must be a positive integer"} =
                 LspFormatter.format_content(project_file(tmp_dir), "x", timeout_ms: 0)
      end)
    end

    test "the formatter filters a private staged copy and never sees the workspace file",
         %{tmp_dir: tmp_dir} do
      project = Path.join(tmp_dir, "project")
      File.mkdir_p!(project)
      path = Path.join(project, "main.go")
      File.write!(path, "on disk\n")
      record = Path.join(tmp_dir, "record")

      fake_formatter(tmp_dir, "gofmt", """
      printf 'args=%s\\n' "$*" > '#{record}'
      printf '// fmt\\n'; cat
      """)

      with_path(bin(tmp_dir), fn ->
        assert {:ok, "// fmt\nstaged\n"} =
                 LspFormatter.format_content(path, "staged\n", cwd: project)
      end)

      assert File.read!(path) == "on disk\n"
      assert File.read!(record) == "args=\n"
    end

    test "configuration hints and working directories follow the formatter", %{tmp_dir: tmp_dir} do
      project = Path.join(tmp_dir, "project")
      File.mkdir_p!(Path.join(project, "lib"))
      record = Path.join(tmp_dir, "record")
      echo = "printf '%s|%s\\n' \"$*\" \"$PWD\" > '#{record}'; cat"

      for name <- ["mix", "prettier", "black", "rustfmt"], do: fake_formatter(tmp_dir, name, echo)

      with_path(bin(tmp_dir), fn ->
        cases = [
          {"lib/a.ex", "format --stdin-filename lib/a.ex -|#{project}"},
          {"lib/a.ts", "--stdin-filepath #{project}/lib/a.ts|#{project}"},
          {"lib/a.py", "--quiet --stdin-filename #{project}/lib/a.py -|#{project}"},
          {"lib/a.rs", "--emit stdout|#{project}/lib"}
        ]

        for {rel, expected} <- cases do
          path = Path.join(project, rel)
          assert {:ok, "x\n"} = LspFormatter.format_content(path, "x\n", cwd: project)
          [args, cwd] = record |> File.read!() |> String.trim() |> String.split("|")
          [expected_args, expected_cwd] = String.split(expected, "|")
          assert args == expected_args
          assert Path.expand(cwd) |> real() == real(expected_cwd)
        end
      end)
    end

    test "formatter output is bounded", %{tmp_dir: tmp_dir} do
      fake_formatter(tmp_dir, "gofmt", "cat >/dev/null; head -c 9000000 /dev/zero")

      with_path(bin(tmp_dir), fn ->
        assert {:error, "formatter output exceeds 8388608 bytes"} =
                 LspFormatter.format_content(project_file(tmp_dir), "package main\n")
      end)
    end

    test "formatter input is bounded", %{tmp_dir: tmp_dir} do
      fake_formatter(tmp_dir, "gofmt", "cat")
      big = :binary.copy("a", 8 * 1024 * 1024 + 1)

      with_path(bin(tmp_dir), fn ->
        assert {:error, "formatter input exceeds 8388608 bytes"} =
                 LspFormatter.format_content(project_file(tmp_dir), big)
      end)
    end

    test "empty output for non-empty input is refused", %{tmp_dir: tmp_dir} do
      fake_formatter(tmp_dir, "gofmt", "cat >/dev/null")

      with_path(bin(tmp_dir), fn ->
        assert {:error, "formatter produced no output"} =
                 LspFormatter.format_content(project_file(tmp_dir), "package main\n")
      end)
    end

    test "a failing formatter reports its status", %{tmp_dir: tmp_dir} do
      fake_formatter(tmp_dir, "gofmt", "echo broken >&2; exit 2")

      with_path(bin(tmp_dir), fn ->
        assert {:error, "formatter exited with status 2: broken"} =
                 LspFormatter.format_content(project_file(tmp_dir), "package main\n")
      end)
    end

    @tag :requires_mix
    test "formats Elixir with the real mix formatter", %{tmp_dir: tmp_dir} do
      if System.find_executable("mix") do
        path = Path.join(tmp_dir, "test.ex")

        assert {:ok, formatted} =
                 LspFormatter.format_content(
                   path,
                   "defmodule Test do def hello do :world end end",
                   cwd: tmp_dir,
                   timeout_ms: 60_000
                 )

        assert formatted == "defmodule Test do\n  def hello do\n    :world\n  end\nend\n"
      end
    end
  end

  # ============================================================================
  # after_write/5
  # ============================================================================

  describe "after_write/5" do
    test "commits the formatted bytes into the file Lemon wrote", %{tmp_dir: cwd} do
      path = Path.join(cwd, "a.go")
      File.write!(path, "written\n")
      inode = File.stat!(path).inode
      formatter = fn ^path, "written\n", _ -> {:ok, "formatted\n"} end

      assert {"formatted\n", true, nil} =
               LspFormatter.after_write(path, "written\n", true, cwd,
                 format_content_fun: formatter
               )

      assert File.read!(path) == "formatted\n"
      assert File.stat!(path).inode == inode
    end

    test "unchanged output leaves the file alone", %{tmp_dir: cwd} do
      path = Path.join(cwd, "a.go")
      File.write!(path, "written\n")

      assert {"written\n", false, nil} =
               LspFormatter.after_write(path, "written\n", true, cwd,
                 format_content_fun: fn _, content, _ -> {:ok, content} end
               )
    end

    test "a file changed before formatting is not formatted", %{tmp_dir: cwd} do
      path = Path.join(cwd, "a.go")
      File.write!(path, "someone else\n")
      parent = self()

      formatter = fn _, _, _ ->
        send(parent, :ran)
        {:ok, "formatted\n"}
      end

      assert {"written\n", false, error} =
               LspFormatter.after_write(path, "written\n", true, cwd,
                 format_content_fun: formatter
               )

      assert error =~ "changed after it was written"
      refute_received :ran
      assert File.read!(path) == "someone else\n"
    end

    test "a file changed while the formatter ran keeps the concurrent bytes", %{tmp_dir: cwd} do
      path = Path.join(cwd, "a.go")
      File.write!(path, "written\n")

      formatter = fn ^path, _, _ ->
        File.write!(path, "concurrent\n")
        {:ok, "formatted\n"}
      end

      assert {"written\n", false, error} =
               LspFormatter.after_write(path, "written\n", true, cwd,
                 format_content_fun: formatter
               )

      assert error =~ "changed after it was written"
      assert File.read!(path) == "concurrent\n"
    end

    test "a file replaced while the formatter ran is refused", %{tmp_dir: cwd} do
      path = Path.join(cwd, "a.go")
      File.write!(path, "written\n")

      formatter = fn ^path, _, _ ->
        File.rm!(path)
        File.write!(path, "written\n")
        {:ok, "formatted\n"}
      end

      assert {"written\n", false, error} =
               LspFormatter.after_write(path, "written\n", true, cwd,
                 format_content_fun: formatter
               )

      assert error =~ "File identity changed"
      assert File.read!(path) == "written\n"
    end
  end

  # ============================================================================
  # list_formatters/0
  # ============================================================================

  describe "list_formatters/0" do
    test "returns a map of formatters" do
      formatters = LspFormatter.list_formatters()
      assert is_map(formatters)
      assert formatters[:elixir]
      assert formatters[:javascript]
      assert formatters[:python]
      assert formatters[:rust]
      assert formatters[:go]
    end

    test "each formatter has required fields" do
      formatters = LspFormatter.list_formatters()

      for {_name, config} <- formatters do
        assert is_binary(config.command)
        assert is_list(config.args)
        assert is_list(config.extensions)
      end
    end

    test "elixir formatter has correct extensions" do
      formatters = LspFormatter.list_formatters()
      elixir = formatters[:elixir]
      assert ".ex" in elixir.extensions
      assert ".exs" in elixir.extensions
      assert ".heex" in elixir.extensions
    end

    test "javascript formatter has correct extensions" do
      formatters = LspFormatter.list_formatters()
      js = formatters[:javascript]
      assert ".js" in js.extensions
      assert ".ts" in js.extensions
    end
  end

  defp bin(tmp_dir), do: Path.join(tmp_dir, "bin")

  # A workspace file beside (not above) the operator bin; only its directory
  # exists (unresolvable roots refuse every executable).
  defp project_file(tmp_dir) do
    project = Path.join(tmp_dir, "project")
    File.mkdir_p!(project)
    Path.join(project, "main.go")
  end

  # Operator formatters live outside the project tree.
  defp fake_formatter(tmp_dir, name, body) do
    File.mkdir_p!(bin(tmp_dir))
    path = Path.join(bin(tmp_dir), name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
  end

  defp with_path(dir, fun) do
    File.mkdir_p!(dir)
    previous = System.get_env("PATH")
    System.put_env("PATH", dir <> ":/usr/bin:/bin")

    try do
      fun.()
    after
      System.put_env("PATH", previous)
    end
  end

  defp real(path) do
    case LemonCore.TrustedRoot.realpath(path) do
      {:ok, real} -> real
      _ -> path
    end
  end
end
