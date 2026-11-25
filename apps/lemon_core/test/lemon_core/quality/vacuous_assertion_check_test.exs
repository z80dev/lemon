defmodule LemonCore.Quality.VacuousAssertionCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.VacuousAssertionCheck

  # Joined so this file's own source never contains the patterns it checks.
  @assert_true Enum.join(["assert", "true"], " ")
  @refute_false Enum.join(["refute", "false"], " ")

  @repo_root Path.expand("../../../../..", __DIR__)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "vacuous_assertion_check_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(root, "apps/demo/test/support"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "the repository's tracked app tests contain no vacuous assertion" do
    assert {:ok, report} = VacuousAssertionCheck.run(root: @repo_root)
    assert report.checked_files > 1_000
  end

  test "flags bare and else-branch literal assertions with their lines", %{root: root} do
    write(root, "apps/demo/test/demo_test.exs", """
    defmodule DemoTest do
      use ExUnit.Case

      test "bare" do
        #{@assert_true}
      end

      test "fallback" do
        if System.find_executable("missing-tool") do
          assert Demo.run() == :ok
        else
          #{@assert_true}, "tool missing"
        end
      end

      test "other literals" do
        assert :ok
        #{@refute_false}
        refute nil
      end
    end
    """)

    assert {:error, report} = VacuousAssertionCheck.run(root: root)
    assert report.checked_files == 1
    assert Enum.all?(report.issues, &(&1.code == :vacuous_assertion))
    assert Enum.all?(report.issues, &(&1.path == "apps/demo/test/demo_test.exs"))

    assert Enum.map(report.issues, &(&1.message |> String.split(" cannot fail") |> hd())) == [
             "apps/demo/test/demo_test.exs:5: `#{@assert_true}`",
             "apps/demo/test/demo_test.exs:12: `#{@assert_true}, \"tool missing\"`",
             "apps/demo/test/demo_test.exs:17: `assert :ok`",
             "apps/demo/test/demo_test.exs:18: `#{@refute_false}`",
             "apps/demo/test/demo_test.exs:19: `refute nil`"
           ]
  end

  test "accepts assertions on computed values, strings and comments", %{root: root} do
    write(root, "apps/demo/test/support/helper.ex", """
    defmodule Demo.Helper do
      import ExUnit.Assertions

      # #{@assert_true} in a comment is not code.
      def check(value) do
        #{@assert_true} = Port.command(value, "x")
        assert value == true
        refute value == false
        "#{@assert_true}"
      end
    end
    """)

    assert {:ok, %{checked_files: 1, issues: []}} = VacuousAssertionCheck.run(root: root)
  end

  test "checks only app test sources", %{root: root} do
    write(root, "apps/demo/lib/demo.ex", "def x, do: #{@assert_true}\n")
    write(root, "apps/demo/test/fixtures/readme.md", "#{@assert_true}\n")
    write(root, "test/root_test.exs", "#{@assert_true}\n")

    assert {:ok, %{checked_files: 0}} = VacuousAssertionCheck.run(root: root)
  end

  test "reports unparseable test sources instead of skipping them", %{root: root} do
    write(root, "apps/demo/test/broken_test.exs", "defmodule Broken do\n")

    assert {:error, %{issues: [issue]}} = VacuousAssertionCheck.run(root: root)
    assert issue.code == :unparseable_test
    assert issue.path == "apps/demo/test/broken_test.exs"
  end

  defp write(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end
end
