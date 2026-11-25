defmodule LemonCore.Config.FeaturesTest do
  # async: false — tests manipulate LEMON_FEATURE_* environment variables.
  use ExUnit.Case, async: false

  alias LemonCore.Config.Features

  @env_var "LEMON_FEATURE_SESSION_SEARCH"

  setup do
    originals = Map.new([@env_var, "LEMON_FEATURE_CRASH_RESUME"], &{&1, System.get_env(&1)})
    Enum.each(originals, fn {key, _value} -> System.delete_env(key) end)

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      LemonCore.Config.reload()
    end)

    :ok
  end

  describe "resolve/1 defaults" do
    test "session_search defaults to default-on" do
      features = Features.resolve(%{})
      assert features.session_search == :"default-on"
      assert Features.enabled?(features, :session_search)
    end

    test "learning-loop flags default to default-on" do
      features = Features.resolve(%{})
      assert features.routing_feedback == :"default-on"
      assert features.skill_synthesis_drafts == :"default-on"
      assert Features.enabled?(features, :routing_feedback)
      assert Features.enabled?(features, :skill_synthesis_drafts)
    end

    test "crash resume is default off and explicitly configurable" do
      refute Features.enabled?(Features.resolve(%{}), :crash_resume)

      features = Features.resolve(%{"features" => %{"crash_resume" => "on"}})
      assert Features.enabled?(features, :crash_resume)

      System.put_env("LEMON_FEATURE_CRASH_RESUME", "off")
      overridden = Features.resolve(%{"features" => %{"crash_resume" => "on"}})
      refute Features.enabled?(overridden, :crash_resume)
    end

    test "the cached facade retains canonical feature flags through projections and overrides" do
      System.put_env("LEMON_FEATURE_CRASH_RESUME", "on")
      config = LemonCore.Config.reload()
      assert Features.enabled?(config.features, :crash_resume)
      assert LemonCore.Config.cached().features == config.features
      assert LemonCore.Config.cached(nil, overrides: %{}).features == config.features
      assert LemonCore.Config.to_map(config).features.crash_resume == :"default-on"
    end

    test "struct defaults match resolve defaults" do
      assert %Features{} == Features.resolve(%{})
    end
  end

  describe "resolve/1 parsing" do
    test "TOML value overrides the default" do
      features = Features.resolve(%{"features" => %{"session_search" => "off"}})
      assert features.session_search == :off
      refute Features.enabled?(features, :session_search)
    end

    test "on parses to default-on" do
      features = Features.resolve(%{"features" => %{"session_search" => "on"}})
      assert features.session_search == :"default-on"
    end

    # #617: a typo is a validation error, not a silent kill switch.
    test "unknown values are kept and fail validation" do
      features = Features.resolve(%{"features" => %{"session_search" => "banana"}})
      assert features.session_search == "banana"
      refute Features.enabled?(features, :session_search)
      assert {:error, [error]} = Features.validate(features)
      assert error =~ "features.session_search"

      assert {:error, errors} =
               LemonCore.Config.Modular.validate_settings(%{
                 "features" => %{"crash_resume" => "yes"}
               })

      assert Enum.any?(errors, &String.starts_with?(&1, "features.crash_resume:"))
    end

    test "environment variable kill switch wins over TOML" do
      System.put_env(@env_var, "off")
      features = Features.resolve(%{"features" => %{"session_search" => "default-on"}})
      assert features.session_search == :off
      refute Features.enabled?(features, :session_search)
    end
  end

  describe "enabled?/3" do
    test "opt-in is inactive unless opt_in: true is passed" do
      features = %Features{session_search: :"opt-in"}
      refute Features.enabled?(features, :session_search)
      assert Features.enabled?(features, :session_search, opt_in: true)
    end

    test "off stays off even with opt_in: true" do
      features = %Features{session_search: :off}
      refute Features.enabled?(features, :session_search, opt_in: true)
    end
  end

  describe "validate/1" do
    test "default struct validates" do
      assert Features.validate(%Features{}) == :ok
    end

    test "invalid state is reported" do
      assert {:error, [error]} = Features.validate(%Features{session_search: :banana})
      assert error =~ "session_search"
    end
  end
end
