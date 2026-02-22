defmodule LemonCore.DotenvTest do
  @moduledoc """
  Comprehensive tests for the Dotenv module.

  Tests cover:
  - Simple KEY=value pairs
  - Export prefix (export KEY=value)
  - Quoted values (single and double quotes)
  - Comments (lines starting with #)
  - Empty lines
  - Values with = signs in them
  - Escape sequences in double quotes (\\n, \\t, etc.)
  - Override option
  - Existing vars preservation by default
  - path_for with nil, empty string, and directory
  """
  use ExUnit.Case, async: false

  alias LemonCore.Dotenv

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "lemon_dotenv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    tracked_keys = [
      "DOTENV_SIMPLE",
      "DOTENV_SPACED",
      "DOTENV_QUOTED",
      "DOTENV_SINGLE",
      "DOTENV_COMMENTED",
      "DOTENV_EXISTING",
      "DOTENV_EMPTY",
      "DOTENV_ESCAPE_N",
      "DOTENV_ESCAPE_T",
      "DOTENV_ESCAPE_R",
      "DOTENV_ESCAPE_QUOTE",
      "DOTENV_EQUALS",
      "DOTENV_MULTILINE",
      "DOTENV_LEADING_SPACE",
      "DOTENV_TRAILING_SPACE",
      "DOTENV_EXPORT_SPACED",
      "DOTENV_INLINE_COMMENT_SINGLE",
      "DOTENV_INLINE_COMMENT_DOUBLE",
      "DOTENV_SPECIAL_CHARS",
      "DOTENV_UNCLOSED",
      "DOTENV_LONG",
      "DOTENV_UNICODE",
      "DOTENV_EMOJI"
    ]

    previous =
      Enum.into(tracked_keys, %{}, fn key ->
        {key, System.get_env(key)}
      end)

    Enum.each(tracked_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "load/2" do
    test "loads variables from .env", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      DOTENV_SIMPLE=hello
      DOTENV_SPACED = world
      DOTENV_QUOTED="hello there"
      DOTENV_SINGLE='single value'
      DOTENV_COMMENTED=abc # trailing comment
      """)

      assert :ok = Dotenv.load(tmp_dir)

      assert System.get_env("DOTENV_SIMPLE") == "hello"
      assert System.get_env("DOTENV_SPACED") == "world"
      assert System.get_env("DOTENV_QUOTED") == "hello there"
      assert System.get_env("DOTENV_SINGLE") == "single value"
      assert System.get_env("DOTENV_COMMENTED") == "abc"
    end

    test "supports export prefix and does not override existing values by default", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, ".env"), """
      export DOTENV_SIMPLE=from_export
      DOTENV_EXISTING=from_env_file
      """)

      System.put_env("DOTENV_EXISTING", "already-set")

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_SIMPLE") == "from_export"
      assert System.get_env("DOTENV_EXISTING") == "already-set"
    end

    test "returns :ok when .env file is missing", %{tmp_dir: tmp_dir} do
      assert :ok = Dotenv.load(tmp_dir)
    end

    test "can override existing values when override: true", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), "DOTENV_EXISTING=from_file\n")
      System.put_env("DOTENV_EXISTING", "already-set")

      assert :ok = Dotenv.load(tmp_dir, override: true)
      assert System.get_env("DOTENV_EXISTING") == "from_file"
    end

    test "handles empty values", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), "DOTENV_EMPTY=\n")

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_EMPTY") == ""
    end

    test "skips blank lines and comments", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """

      # This is a comment
      DOTENV_SIMPLE=value

      # Another comment
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_SIMPLE") == "value"
    end

    test "handles escape sequences in double-quoted values", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), ~S"""
      DOTENV_ESCAPE_N="line1\nline2"
      DOTENV_ESCAPE_T="col1\tcol2"
      DOTENV_ESCAPE_QUOTE="say \"hello\""
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_ESCAPE_N") == "line1\nline2"
      assert System.get_env("DOTENV_ESCAPE_T") == "col1\tcol2"
      assert System.get_env("DOTENV_ESCAPE_QUOTE") == "say \"hello\""
    end

    test "skips lines with invalid key names", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      123INVALID=nope
      DOTENV_SIMPLE=valid
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_SIMPLE") == "valid"
      assert System.get_env("123INVALID") == nil
    end

    test "handles values containing = signs", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      DOTENV_EQUALS=key=value=with=equals
      DOTENV_SIMPLE=simple
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_EQUALS") == "key=value=with=equals"
      assert System.get_env("DOTENV_SIMPLE") == "simple"
    end

    test "handles export with multiple spaces", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      export   DOTENV_EXPORT_SPACED=spaced_value
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_EXPORT_SPACED") == "spaced_value"
    end

    test "handles inline comments in single-quoted values", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      DOTENV_INLINE_COMMENT_SINGLE='value with # not a comment'
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_INLINE_COMMENT_SINGLE") == "value with # not a comment"
    end

    test "handles inline comments in double-quoted values", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      DOTENV_INLINE_COMMENT_DOUBLE="value with # not a comment"
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_INLINE_COMMENT_DOUBLE") == "value with # not a comment"
    end

    test "handles values with leading/trailing spaces in unquoted values", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      DOTENV_LEADING_SPACE=  leading spaces
      DOTENV_TRAILING_SPACE=trailing spaces  
      """)

      assert :ok = Dotenv.load(tmp_dir)
      # Unquoted values preserve leading/trailing spaces (before strip_inline_comment)
      assert System.get_env("DOTENV_LEADING_SPACE") == "leading spaces"
      assert System.get_env("DOTENV_TRAILING_SPACE") == "trailing spaces"
    end

    test "handles special characters in values", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), ~S"""
      DOTENV_SPECIAL_CHARS="special: !@#$%^&*()_+-=[]{}|;':\",./<>?"
      """)

      assert :ok = Dotenv.load(tmp_dir)
      # Double quotes are stripped, special chars inside are preserved
      assert System.get_env("DOTENV_SPECIAL_CHARS") == "special: !@#$%^&*()_+-=[]{}|;':\",./<>?"
    end

    test "handles carriage return line endings", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), "DOTENV_SIMPLE=hello\r\nDOTENV_SPACED=world\r\n")

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_SIMPLE") == "hello"
      assert System.get_env("DOTENV_SPACED") == "world"
    end

    test "handles keys starting with underscore", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), "_DOTENV_PRIVATE=hidden\n")

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("_DOTENV_PRIVATE") == "hidden"
    end

    test "handles keys with numbers (but not starting with number)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      DOTENV_123=with_numbers
      DOTENV_V2=version2
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_123") == "with_numbers"
      assert System.get_env("DOTENV_V2") == "version2"
    end

    test "handles empty .env file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), "")

      assert :ok = Dotenv.load(tmp_dir)
    end

    test "handles .env file with only comments and whitespace", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      # Only comments

      # More comments
         
      """)

      assert :ok = Dotenv.load(tmp_dir)
    end

    test "handles malformed lines gracefully", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      NO_EQUALS_SIGN
      DOTENV_SIMPLE=valid
      =no_key
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_SIMPLE") == "valid"
      assert System.get_env("NO_EQUALS_SIGN") == nil
      assert System.get_env("") == nil
    end

    test "handles single quotes inside double quotes", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      DOTENV_QUOTED="it's working"
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_QUOTED") == "it's working"
    end

    test "handles double quotes inside single quotes", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      DOTENV_SINGLE='say "hello"'
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_SINGLE") == "say \"hello\""
    end

    test "handles escaped carriage return", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), ~S"""
      DOTENV_ESCAPE_R="line1\rline2"
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_ESCAPE_R") == "line1\rline2"
    end

    test "handles unclosed double quotes gracefully", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), ~S"""
      DOTENV_UNCLOSED="unclosed value
      DOTENV_SIMPLE=simple
      """)

      assert :ok = Dotenv.load(tmp_dir)
      # Falls back to raw value processing - the leading quote is kept since regex doesn't match
      assert System.get_env("DOTENV_UNCLOSED") == "\"unclosed value"
      assert System.get_env("DOTENV_SIMPLE") == "simple"
    end

    test "handles unclosed single quotes gracefully", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      DOTENV_UNCLOSED='unclosed value
      DOTENV_SIMPLE=simple
      """)

      assert :ok = Dotenv.load(tmp_dir)
      # Falls back to raw value with strip_inline_comment
      assert System.get_env("DOTENV_UNCLOSED") == "'unclosed value"
      assert System.get_env("DOTENV_SIMPLE") == "simple"
    end
  end

  describe "path_for/1" do
    test "returns .env in current directory for nil" do
      assert Dotenv.path_for(nil) == Path.join(File.cwd!(), ".env")
    end

    test "returns .env in current directory for empty string" do
      assert Dotenv.path_for("") == Path.join(File.cwd!(), ".env")
    end

    test "returns .env in specified directory" do
      assert Dotenv.path_for("/custom/path") == "/custom/path/.env"
    end

    test "expands relative paths" do
      result = Dotenv.path_for("~/some/dir")
      refute String.starts_with?(result, "~")
      assert String.ends_with?(result, ".env")
    end

    test "handles nested directories" do
      assert Dotenv.path_for("/a/b/c/d") == "/a/b/c/d/.env"
    end

    test "handles paths with trailing slash" do
      assert Dotenv.path_for("/custom/path/") == "/custom/path/.env"
    end
  end

  describe "load_and_log/2" do
    test "returns :ok when file is missing", %{tmp_dir: tmp_dir} do
      assert :ok = Dotenv.load_and_log(tmp_dir)
    end

    test "returns :ok and loads variables from .env", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), "DOTENV_SIMPLE=logged\n")

      assert :ok = Dotenv.load_and_log(tmp_dir)
      assert System.get_env("DOTENV_SIMPLE") == "logged"
    end

    test "logs warning on read error (permission denied simulation)", %{tmp_dir: tmp_dir} do
      # Create a file that can't be read (directory instead of file)
      dotenv_path = Path.join(tmp_dir, ".env")
      File.mkdir_p!(dotenv_path)

      # Should log warning and return :ok
      assert :ok = Dotenv.load_and_log(tmp_dir)
    end
  end

  describe "edge cases and stress tests" do
    test "handles very long values", %{tmp_dir: tmp_dir} do
      long_value = String.duplicate("a", 10_000)
      File.write!(Path.join(tmp_dir, ".env"), "DOTENV_LONG=#{long_value}\n")

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_LONG") == long_value
    end

    test "handles unicode values", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      DOTENV_UNICODE=Hello 世界 🌍
      DOTENV_EMOJI=🚀🎉💯
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_UNICODE") == "Hello 世界 🌍"
      assert System.get_env("DOTENV_EMOJI") == "🚀🎉💯"
    end

    test "handles many variables", %{tmp_dir: tmp_dir} do
      content =
        for i <- 1..100 do
          "DOTENV_VAR#{i}=value#{i}\n"
        end
        |> Enum.join()

      File.write!(Path.join(tmp_dir, ".env"), content)

      assert :ok = Dotenv.load(tmp_dir)

      for i <- 1..100 do
        assert System.get_env("DOTENV_VAR#{i}") == "value#{i}"
      end
    end

    test "preserves existing env vars when override is false", %{tmp_dir: tmp_dir} do
      # Set some env vars before loading
      System.put_env("DOTENV_EXISTING", "original")
      System.put_env("DOTENV_NEW", "should_be_overwritten")

      File.write!(Path.join(tmp_dir, ".env"), """
      DOTENV_EXISTING=from_file
      DOTENV_NEW=from_file
      DOTENV_ONLY_IN_FILE=new_value
      """)

      assert :ok = Dotenv.load(tmp_dir, override: false)

      assert System.get_env("DOTENV_EXISTING") == "original"
      assert System.get_env("DOTENV_NEW") == "should_be_overwritten"
      assert System.get_env("DOTENV_ONLY_IN_FILE") == "new_value"
    end
  end
end
