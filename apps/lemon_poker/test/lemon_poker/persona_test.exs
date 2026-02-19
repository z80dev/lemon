defmodule LemonPoker.PersonaTest do
  use ExUnit.Case, async: true

  alias LemonPoker.Persona

  describe "load/1" do
    test "returns persona for valid names" do
      for name <- Persona.list() do
        assert %{name: ^name, content: content} = Persona.load(name)
        assert is_binary(content)
        assert content != ""
      end
    end

    test "returns nil for invalid persona" do
      assert Persona.load("nonexistent") == nil
    end

    test "returns nil for non-binary input" do
      assert Persona.load(nil) == nil
      assert Persona.load(123) == nil
    end
  end

  describe "list/0" do
    test "returns list of available personas" do
      personas = Persona.list()
      assert is_list(personas)
      assert "grinder" in personas
      assert "aggro" in personas
      assert "friendly" in personas
      assert "silent" in personas
      assert "tourist" in personas
      assert "showman" in personas
      assert "professor" in personas
      assert "road_dog" in personas
      assert "dealer_friend" in personas
      assert "homegame_legend" in personas
    end
  end

  describe "load_banter/0" do
    test "returns banter examples by category" do
      banter = Persona.load_banter()
      assert is_map(banter)

      assert is_list(banter["greetings"])
      assert is_list(banter["reactions"])
      assert is_list(banter["idle_chat"])
      assert is_list(banter["bad_beats"])
      assert is_list(banter["big_pots"])
      assert is_list(banter["leaving"])

      # Each category should have content
      for {_category, examples} <- banter do
        assert length(examples) > 0
        assert Enum.all?(examples, &is_binary/1)
      end
    end
  end

  describe "sample_banter/3" do
    test "samples random examples from a category" do
      banter = Persona.load_banter()
      samples = Persona.sample_banter(banter, "greetings", 3)

      assert length(samples) <= 3
      assert Enum.all?(samples, &is_binary/1)
    end

    test "returns empty list for unknown category" do
      banter = Persona.load_banter()
      assert Persona.sample_banter(banter, "unknown", 3) == []
    end

    test "respects count limit" do
      banter = Persona.load_banter()
      samples = Persona.sample_banter(banter, "greetings", 1)
      assert length(samples) == 1
    end
  end

  describe "build_system_prompt/2" do
    test "returns base prompt when persona is nil" do
      base = "Base poker prompt"
      assert Persona.build_system_prompt(base, nil) == base
    end

    test "combines base prompt with persona content" do
      base = "Base poker prompt"
      persona = %{name: "test", content: "Test persona content"}
      result = Persona.build_system_prompt(base, persona)

      assert result =~ base
      assert result =~ "Test persona content"
      assert result =~ "Your Persona:"
    end
  end

  describe "build_banter_prompt/2" do
    test "returns empty string for nil context" do
      banter = Persona.load_banter()
      assert Persona.build_banter_prompt(banter, nil) == ""
    end

    test "returns examples for valid context" do
      banter = Persona.load_banter()
      result = Persona.build_banter_prompt(banter, "greeting")

      assert result =~ "Examples of table talk"
      assert result =~ "\""
    end

    test "returns empty string for unknown context" do
      banter = Persona.load_banter()
      assert Persona.build_banter_prompt(banter, "unknown") == ""
    end
  end
end
