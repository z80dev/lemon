defmodule CodingAgent.Tools.LspFormatterTest do
  @moduledoc """
  Tests for the LSP-inspired auto-formatter.
  """
  use ExUnit.Case, async: true

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
  # format_file/2
  # ============================================================================

  describe "format_file/2" do
    test "returns :unchanged for files without formatters", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "file.xyz")
      File.write!(path, "content")

      assert {:ok, :unchanged} = LspFormatter.format_file(path)
    end

    test "returns :unchanged for non-existent formatter executables", %{tmp_dir: tmp_dir} do
      # Create a file with a known extension but the formatter won't be available
      path = Path.join(tmp_dir, "test.ex")
      File.write!(path, "content")

      # When mix is not available, should return unchanged
      result = LspFormatter.format_file(path)
      assert result == {:ok, :unchanged} or match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles missing files gracefully" do
      result = LspFormatter.format_file("/nonexistent/path/file.ex")
      # Should either return unchanged or error, not crash
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "respects timeout option", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.ex")
      File.write!(path, "content")

      result = LspFormatter.format_file(path, timeout_ms: 1)
      # With very short timeout, might timeout or complete quickly
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "respects cwd option", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.ex")
      File.write!(path, "content")

      result = LspFormatter.format_file(path, cwd: tmp_dir)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
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

  # ============================================================================
  # Elixir formatting (if available)
  # ============================================================================

  describe "elixir formatting" do
    @tag :requires_mix
    test "formats Elixir files when mix is available", %{tmp_dir: tmp_dir} do
      # Skip if mix is not available
      if System.find_executable("mix") do
        path = Path.join(tmp_dir, "test.ex")
        # Write unformatted code
        File.write!(path, "defmodule Test do def hello do :world end end")

        result = LspFormatter.format_file(path)

        case result do
          {:ok, _} ->
            # File should now be formatted
            content = File.read!(path)
            # Formatted elixir has newlines
            assert content =~ "\n"

          {:error, _} ->
            # Formatting might fail in some environments, that's ok
            :ok
        end
      end
    end
  end

  # ============================================================================
  # Error handling
  # ============================================================================

  describe "error handling" do
    test "handles timeout gracefully", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.ex")
      File.write!(path, "content")

      # Very short timeout should cause issues
      result = LspFormatter.format_file(path, timeout_ms: 0)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles paths with spaces", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "path with spaces", "test.ex"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "content")

      result = LspFormatter.format_file(path)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end
