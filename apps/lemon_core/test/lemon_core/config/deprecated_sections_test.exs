defmodule LemonCore.Config.DeprecatedSectionsTest do
  @moduledoc """
  Tests for deprecated section detection in configuration.
  """
  use ExUnit.Case, async: true

  alias LemonCore.Config.Modular
  alias LemonCore.Config.Validator
  alias LemonCore.Config.ValidationError

  describe "Modular.check_deprecated_sections!/1" do
    test "returns :ok for valid settings with no deprecated sections" do
      settings = %{
        "defaults" => %{"provider" => "anthropic", "model" => "claude-sonnet-4"},
        "runtime" => %{"theme" => "lemon"},
        "providers" => %{}
      }

      assert :ok = Modular.check_deprecated_sections!(settings)
    end

    test "returns :ok for empty settings" do
      assert :ok = Modular.check_deprecated_sections!(%{})
    end

    test "raises when [agent] section is present" do
      settings = %{
        "agent" => %{"default_model" => "claude-sonnet-4"}
      }

      assert_raise ValidationError, ~r/\[agent\] is deprecated/, fn ->
        Modular.check_deprecated_sections!(settings)
      end
    end

    test "raises when [agents] section is present" do
      settings = %{
        "agents" => %{"default" => %{"name" => "My Agent"}}
      }

      assert_raise ValidationError, ~r/\[agents\.<id>\] is deprecated/, fn ->
        Modular.check_deprecated_sections!(settings)
      end
    end

    test "raises when [agent.tools] is present" do
      settings = %{
        "agent" => %{
          "tools" => %{
            "web" => %{"search" => %{"provider" => "brave"}}
          }
        }
      }

      error =
        assert_raise ValidationError, fn ->
          Modular.check_deprecated_sections!(settings)
        end

      assert Enum.any?(error.errors, &String.contains?(&1, "[agent.tools.*] is deprecated"))
      assert Enum.any?(error.errors, &String.contains?(&1, "[agent] is deprecated"))
    end

    test "collects multiple deprecation errors" do
      settings = %{
        "agent" => %{
          "default_model" => "test",
          "tools" => %{"web" => %{}}
        },
        "agents" => %{"default" => %{}}
      }

      error =
        assert_raise ValidationError, fn ->
          Modular.check_deprecated_sections!(settings)
        end

      assert length(error.errors) == 3
    end

    test "raises when top-level [tools] section is present" do
      settings = %{
        "tools" => %{"web" => %{"search" => %{"provider" => "brave"}}}
      }

      assert_raise ValidationError, ~r/\[tools\.\*\] is deprecated/, fn ->
        Modular.check_deprecated_sections!(settings)
      end
    end

    test "does not raise when agent key is not a map" do
      settings = %{
        "agent" => "not-a-map"
      }

      assert :ok = Modular.check_deprecated_sections!(settings)
    end
  end

  describe "Validator.validate_deprecated_sections/1" do
    test "returns :ok for valid settings" do
      assert :ok =
               Validator.validate_deprecated_sections(%{
                 "defaults" => %{"model" => "test"},
                 "runtime" => %{}
               })
    end

    test "returns error tuple for [agent] section" do
      assert {:error, errors} =
               Validator.validate_deprecated_sections(%{
                 "agent" => %{"default_model" => "test"}
               })

      assert Enum.any?(errors, &String.contains?(&1, "[agent] is deprecated"))
    end

    test "returns error tuple for [agents] section" do
      assert {:error, errors} =
               Validator.validate_deprecated_sections(%{
                 "agents" => %{"default" => %{}}
               })

      assert Enum.any?(errors, &String.contains?(&1, "[agents.<id>] is deprecated"))
    end

    test "returns error tuple for [agent.tools] section" do
      assert {:error, errors} =
               Validator.validate_deprecated_sections(%{
                 "agent" => %{"tools" => %{"web" => %{}}}
               })

      assert Enum.any?(errors, &String.contains?(&1, "[agent.tools.*] is deprecated"))
      assert Enum.any?(errors, &String.contains?(&1, "[agent] is deprecated"))
    end

    test "returns error tuple for top-level [tools] section" do
      assert {:error, errors} =
               Validator.validate_deprecated_sections(%{
                 "tools" => %{"web" => %{"search" => %{}}}
               })

      assert Enum.any?(errors, &String.contains?(&1, "[tools.*] is deprecated"))
    end
  end
end
