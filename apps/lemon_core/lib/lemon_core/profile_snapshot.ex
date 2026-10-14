defmodule LemonCore.ProfileSnapshot do
  @moduledoc """
  Credential-free execution-node persona snapshot contract.

  Revisions hash a JSON array of profile ID, model, system prompt and four ordered
  filename/text pairs. Missing files are represented by null, distinct from empty
  files. Mutation correlation is not part of the persona revision.
  The system prompt is preserved exactly up to 131,072 UTF-8 bytes; each persona
  file remains limited to 65,536 bytes. Invalid UTF-8 and NUL are rejected.
  """

  @filenames ~w(AGENTS.md IDENTITY.md README.md SOUL.md)
  @fields ~w(profileId model systemPrompt personaInstructions revisionDigest mutationId)
  @max_system_prompt_bytes 131_072
  @max_persona_file_bytes 65_536

  def filenames, do: @filenames

  def build(snapshot, mutation_id \\ nil) when is_map(snapshot) do
    payload = %{
      "profileId" => snapshot["id"],
      "model" => snapshot["model"],
      "systemPrompt" => snapshot["systemPrompt"],
      "personaInstructions" => Map.take(snapshot["instructions"] || %{}, @filenames),
      "mutationId" => mutation_id
    }

    with :ok <- validate_fields(payload) do
      {:ok, Map.put(payload, "revisionDigest", revision_digest(payload))}
    end
  end

  def validate(payload) when is_map(payload) do
    with true <- Enum.sort(Map.keys(payload)) == Enum.sort(@fields),
         :ok <- validate_fields(payload),
         digest when is_binary(digest) <- payload["revisionDigest"],
         true <- digest == revision_digest(payload) do
      :ok
    else
      false -> {:error, :revision_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :invalid_profile_snapshot}
    end
  end

  def validate(_), do: {:error, :invalid_profile_snapshot}

  @doc "Validate a read-only lookup bound to one non-null mutation and expected revision."
  def validate_status(args) when is_map(args) do
    with true <- Enum.sort(Map.keys(args)) == Enum.sort(~w(profileId mutationId revisionDigest)),
         {:ok, _} <- LemonCore.ProfileStore.paths(args["profileId"]),
         true <- not is_nil(args["mutationId"]) and valid_mutation?(args["mutationId"]),
         digest when is_binary(digest) <- args["revisionDigest"],
         true <- Regex.match?(~r/^[a-f0-9]{64}$/, digest) do
      :ok
    else
      _ -> {:error, :invalid_profile_snapshot}
    end
  end
  def validate_status(_), do: {:error, :invalid_profile_snapshot}

  def revision_digest(payload) do
    canonical = [
      payload["profileId"],
      payload["model"],
      payload["systemPrompt"],
      Enum.map(@filenames, &[&1, Map.get(payload["personaInstructions"], &1)])
    ]

    :crypto.hash(:sha256, Jason.encode!(canonical)) |> Base.encode16(case: :lower)
  end

  def valid_mutation?(nil), do: true
  def valid_mutation?(id), do: text?(id, 128) and byte_size(id) > 0

  defp validate_fields(payload) do
    instructions = payload["personaInstructions"]

    with {:ok, _} <- LemonCore.ProfileStore.paths(payload["profileId"]),
         true <- optional_text?(payload["model"], 512),
         true <- optional_text?(payload["systemPrompt"], @max_system_prompt_bytes),
         true <- valid_mutation?(payload["mutationId"]),
         true <- is_map(instructions),
         true <- Enum.all?(instructions, fn {name, text} ->
           name in @filenames and text?(text, @max_persona_file_bytes)
         end) do
      :ok
    else
      _ -> {:error, :invalid_profile_snapshot}
    end
  end

  defp optional_text?(nil, _max), do: true
  defp optional_text?(value, max), do: text?(value, max)
  defp text?(value, max) when is_binary(value),
    do: byte_size(value) <= max and String.valid?(value) and not String.contains?(value, <<0>>)
  defp text?(_, _), do: false
end
