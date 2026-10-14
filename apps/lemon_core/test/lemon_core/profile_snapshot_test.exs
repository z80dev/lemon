defmodule LemonCore.ProfileSnapshotTest do
  use ExUnit.Case, async: true

  alias LemonCore.ProfileSnapshot

  test "128 KiB system prompts preserve exact UTF-8 whitespace and canonical digest bytes" do
    prompt = "\n " <> String.duplicate("😀", 32_767) <> " \n"
    file = String.duplicate("界", 21_845) <> "x"
    assert byte_size(prompt) == 131_072
    assert byte_size(file) == 65_536
    instructions = Map.new(ProfileSnapshot.filenames(), &{&1, file})

    assert {:ok, payload} =
             ProfileSnapshot.build(
               %{snapshot(instructions) | "systemPrompt" => prompt},
               "boundary"
             )

    assert payload["systemPrompt"] == prompt
    assert payload["personaInstructions"] == instructions

    canonical = [
      "persona",
      "provider:model",
      prompt,
      Enum.map(ProfileSnapshot.filenames(), &[&1, file])
    ]

    expected = :crypto.hash(:sha256, Jason.encode!(canonical)) |> Base.encode16(case: :lower)
    assert payload["revisionDigest"] == expected
    assert :ok = ProfileSnapshot.validate(payload)
    assert {:ok, decoded} = payload |> Jason.encode!() |> Jason.decode()
    assert decoded == payload
    assert :ok = ProfileSnapshot.validate(decoded)
  end

  test "build and validate independently reject prompt overflow unsafe UTF-8 and NUL" do
    assert {:ok, payload} = ProfileSnapshot.build(snapshot(%{}))

    for text <- [
          String.duplicate("x", 131_072) <> " ",
          <<0xFF>>,
          <<0xED, 0xA0, 0x80>>,
          "bad\0prompt"
        ] do
      assert {:error, :invalid_profile_snapshot} =
               ProfileSnapshot.build(%{snapshot(%{}) | "systemPrompt" => text})

      assert {:error, :invalid_profile_snapshot} =
               ProfileSnapshot.validate(%{payload | "systemPrompt" => text})
    end

    for text <- [String.duplicate("x", 65_537), <<0xFF>>, "bad\0persona"] do
      assert {:error, :invalid_profile_snapshot} =
               ProfileSnapshot.build(snapshot(%{"SOUL.md" => text}))

      assert {:error, :invalid_profile_snapshot} =
               ProfileSnapshot.validate(%{
                 payload
                 | "personaInstructions" => %{"SOUL.md" => text}
               })
    end
  end

  test "canonical revisions ignore insertion order and mutation but bind every persona field" do
    first = %{"AGENTS.md" => "agents", "SOUL.md" => "soul"}
    second = Map.new([{"SOUL.md", "soul"}, {"AGENTS.md", "agents"}])
    {:ok, left} = ProfileSnapshot.build(snapshot(first), "one")
    {:ok, right} = ProfileSnapshot.build(snapshot(second), "two")
    assert left["revisionDigest"] == right["revisionDigest"]
    assert :ok = ProfileSnapshot.validate(left)

    for {field, value} <- [
          {"id", "another"},
          {"model", "other:model"},
          {"systemPrompt", "different"},
          {"instructions", Map.put(first, "README.md", "")}
        ] do
      {:ok, changed} = ProfileSnapshot.build(Map.put(snapshot(first), field, value))
      refute changed["revisionDigest"] == left["revisionDigest"]
    end
  end

  test "allowlist excludes user memory tools MCP paths and credentials from controller snapshot" do
    private =
      snapshot(%{
        "AGENTS.md" => "trusted",
        "USER.md" => "user-secret",
        "MEMORY.md" => "memory-secret",
        "TOOLS.md" => "tool-secret"
      })
      |> Map.merge(%{
        "mcpServers" => [%{"headers" => %{"Authorization" => "credential-secret"}}],
        "paths" => %{"home" => "/private/source"}
      })

    assert {:ok, payload} = ProfileSnapshot.build(private)
    assert payload["personaInstructions"] == %{"AGENTS.md" => "trusted"}
    assert payload["mutationId"] == nil
    refute inspect(payload) =~ "secret"
    refute inspect(payload) =~ "/private/source"
    assert {:error, _} = ProfileSnapshot.validate(Map.put(payload, "mcpServers", []))
  end

  test "wire validation rejects unsafe IDs, unexpected persona filenames and oversized text" do
    assert {:error, :invalid_profile_snapshot} =
             ProfileSnapshot.build(%{snapshot(%{}) | "id" => "../outside"})

    assert {:error, :invalid_profile_snapshot} =
             ProfileSnapshot.build(snapshot(%{"SOUL.md" => String.duplicate("x", 65_537)}))

    {:ok, payload} = ProfileSnapshot.build(snapshot(%{}))

    assert {:error, :invalid_profile_snapshot} =
             ProfileSnapshot.validate(%{
               payload
               | "personaInstructions" => %{"USER.md" => "source user"}
             })

    assert {:error, :invalid_profile_snapshot} = ProfileSnapshot.build(snapshot(%{}), "")

    assert {:error, :invalid_profile_snapshot} =
             ProfileSnapshot.build(snapshot(%{"SOUL.md" => "persona" <> <<0>>}))

    assert {:error, :invalid_profile_snapshot} =
             ProfileSnapshot.build(%{snapshot(%{}) | "systemPrompt" => "prompt" <> <<0>>})

    assert {:error, :invalid_profile_snapshot} =
             ProfileSnapshot.validate(%{
               payload
               | "personaInstructions" => %{"USER.md" => "user" <> <<0>>}
             })

    assert {:ok, _} =
             ProfileSnapshot.build(%{snapshot(%{}) | "model" => String.duplicate("m", 512)})

    assert {:error, :invalid_profile_snapshot} =
             ProfileSnapshot.build(%{snapshot(%{}) | "model" => String.duplicate("m", 513)})
  end

  test "status request accepts correlation only and requires a non-null mutation and canonical digest" do
    {:ok, payload} = ProfileSnapshot.build(snapshot(%{"SOUL.md" => "trusted"}), "fixed")
    request = Map.take(payload, ~w(profileId mutationId revisionDigest))
    assert :ok = ProfileSnapshot.validate_status(request)

    assert {:error, :invalid_profile_snapshot} =
             ProfileSnapshot.validate_status(Map.put(request, "personaInstructions", %{}))

    assert {:error, :invalid_profile_snapshot} =
             ProfileSnapshot.validate_status(%{request | "mutationId" => nil})

    assert {:error, :invalid_profile_snapshot} =
             ProfileSnapshot.validate_status(%{request | "revisionDigest" => "wrong"})
  end

  defp snapshot(instructions),
    do: %{
      "id" => "persona",
      "model" => "provider:model",
      "systemPrompt" => "persona prompt",
      "instructions" => instructions
    }
end
