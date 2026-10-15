defmodule LemonCore.Config.WriteApprovalTest do
  use ExUnit.Case, async: true

  alias LemonCore.Config.Modular

  test "durable write approval is off by default" do
    assert {:ok, config} = Modular.validate_settings(%{})
    assert config.memory.write_approval == false
    assert config.skills.write_approval == false
  end

  test "memory and skill write approval are independent boolean settings" do
    assert {:ok, config} = Modular.validate_settings(%{"memory" => %{"write_approval" => true}})
    assert config.memory.write_approval
    refute config.skills.write_approval

    assert {:ok, config} = Modular.validate_settings(%{"skills" => %{"write_approval" => true}})
    refute config.memory.write_approval
    assert config.skills.write_approval
  end

  test "invalid write approval values are rejected rather than coerced" do
    for section <- ["memory", "skills"], value <- ["true", 0, nil] do
      assert {:error, errors} =
               Modular.validate_settings(%{section => %{"write_approval" => value}})

      assert Enum.any?(errors, &String.contains?(&1, section <> ".write_approval"))
    end
  end
end
