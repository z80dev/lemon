defmodule LemonCore.ResumeFormatsTest do
  # Registration writes application env, which is global.
  use ExUnit.Case, async: false

  alias LemonCore.ResumeFormat
  alias LemonCore.ResumeFormats

  doctest LemonCore.ResumeFormat

  setup do
    on_exit(fn -> Enum.each(~w(one two lemon), &ResumeFormats.unregister/1) end)
    :ok
  end

  defp format(engine, opts \\ []) do
    ResumeFormat.new(
      engine,
      Keyword.merge(
        [
          pattern: ~r/`?#{engine}\s+go\s+([a-z0-9_-]+)`?/i,
          render: &("#{engine} go " <> &1)
        ],
        opts
      )
    )
  end

  test "the lemon format is built in, so a bare core runtime still round-trips" do
    assert {:ok, lemon} = ResumeFormats.fetch("lemon")
    assert ResumeFormat.render(lemon, "abc") == "lemon resume abc"
    assert ResumeFormat.capture(lemon, "`lemon resume abc`") == "abc"
  end

  test "registered formats come before the built-ins, in registration order" do
    :ok = ResumeFormats.register(format("one"))
    :ok = ResumeFormats.register(format("two"))

    engines = ResumeFormats.list_engines()

    assert index(engines, "one") < index(engines, "two")
    assert index(engines, "two") < index(engines, "lemon")
  end

  test "re-registering an engine replaces its format instead of shadowing it" do
    :ok = ResumeFormats.register(format("one"))
    :ok = ResumeFormats.register(format("one", render: &("one resume " <> &1)))

    assert Enum.count(ResumeFormats.list_engines(), &(&1 == "one")) == 1
    assert {:ok, one} = ResumeFormats.fetch("one")
    assert ResumeFormat.render(one, "x") == "one resume x"
  end

  test "an engine may register over a built-in" do
    :ok = ResumeFormats.register(format("lemon"))

    assert Enum.count(ResumeFormats.list_engines(), &(&1 == "lemon")) == 1
    assert {:ok, lemon} = ResumeFormats.fetch("lemon")
    assert ResumeFormat.render(lemon, "abc") == "lemon go abc"

    :ok = ResumeFormats.unregister("lemon")

    assert {:ok, builtin} = ResumeFormats.fetch("lemon")
    assert ResumeFormat.render(builtin, "abc") == "lemon resume abc"
  end

  defp index(engines, engine), do: Enum.find_index(engines, &(&1 == engine))

  test "unregister/1 is idempotent and fetch/1 answers :error for the unknown" do
    :ok = ResumeFormats.register(format("one"))
    :ok = ResumeFormats.unregister("one")
    :ok = ResumeFormats.unregister("one")

    assert ResumeFormats.fetch("one") == :error
    assert ResumeFormats.fetch(:one) == :error
  end

  test "register/2 builds the format from options" do
    :ok = ResumeFormats.register("one", pattern: ~r/one!(\w+)/, render: &("one!" <> &1))

    assert {:ok, one} = ResumeFormats.fetch("one")
    assert ResumeFormat.capture(one, "say one!abc") == "abc"
  end

  describe "ResumeFormat.new/2" do
    test "derives the strict pattern from the loose one" do
      one = format("one")

      assert ResumeFormat.resume_line?(one, " one go abc ")
      refute ResumeFormat.resume_line?(one, "run one go abc now")
    end

    test "keeps an explicitly supplied strict pattern" do
      one = format("one", strict_pattern: ~r/^one!$/)

      assert ResumeFormat.resume_line?(one, "one!")
      refute ResumeFormat.resume_line?(one, "one go abc")
    end

    test "rejects a format the parser could not use" do
      assert_raise ArgumentError, fn -> ResumeFormat.new("", pattern: ~r/x(y)/, render: & &1) end

      assert_raise ArgumentError, fn ->
        ResumeFormat.new("one", pattern: "not a regex", render: & &1)
      end

      assert_raise ArgumentError, fn ->
        ResumeFormat.new("one", pattern: ~r/x(y)/, render: fn -> "no arg" end)
      end

      assert_raise ArgumentError, fn ->
        ResumeFormat.new("one", pattern: ~r/x(y)/, render: & &1, normalize: :upcase)
      end
    end

    test "capture/1 and resume_line?/2 tolerate non-binary input" do
      one = format("one")

      assert ResumeFormat.capture(one, :nope) == nil
      assert ResumeFormat.resume_line?(one, nil) == false
    end
  end
end
