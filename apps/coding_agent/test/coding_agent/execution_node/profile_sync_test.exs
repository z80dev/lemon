defmodule CodingAgent.ExecutionNode.ProfileSyncTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.ProfileSync
  alias LemonCore.{ProfileSnapshot, ProfileStore}

  setup do
    root = Path.join(canonical_tmp(), "lemon-persona-sync-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, home_state_dir: root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)
      File.rm_rf!(root)
    end)

    {:ok, paths} = ProfileStore.paths("persona")
    {:ok, root: root, paths: paths}
  end

  test "acknowledges reread persona and leaves local credentials/user/memory/config untouched", %{paths: paths} do
    File.mkdir_p!(paths["memory"])
    File.mkdir_p!(paths["skills"])
    preserved = %{
      paths["config"] => "[providers.openai]\napi_key = \"destination-secret\"\n",
      Path.join(paths["workspace"], "USER.md") => "destination preferences",
      Path.join(paths["workspace"], "MEMORY.md") => "destination memory",
      Path.join(paths["workspace"], "TOOLS.md") => "destination tools",
      Path.join(paths["memory"], "notes.md") => "private notes",
      Path.join(paths["skills"], "local.md") => "local skill",
      Path.join(paths["home"], "credentials.json") => "destination credentials"
    }
    Enum.each(preserved, fn {path, bytes} -> File.write!(path, bytes) end)
    payload = payload("mutation-one")

    assert {:ok, ack} = ProfileSync.apply(payload, "/not-a-source-path")
    assert ack == (Map.take(payload, ~w(profileId mutationId revisionDigest)) |> Map.put("acknowledged", true))
    assert {:ok, ^ack} = ProfileSync.apply(payload)
    Enum.each(payload["personaInstructions"], fn {name, text} ->
      assert File.read!(Path.join(paths["workspace"], name)) == text
    end)
    Enum.each(preserved, fn {path, bytes} -> assert File.read!(path) == bytes end)
    Enum.each(~w(home workspace memory skills sessions), fn name -> assert File.dir?(paths[name]) end)
    record = paths["home"] |> Path.join("persona-revision.json") |> File.read!() |> Jason.decode!()
    assert record["revisionDigest"] == ProfileSnapshot.revision_digest(record)
    receipt = paths["home"] |> Path.join("persona-sync-receipt.json") |> File.read!() |> Jason.decode!()
    assert receipt["mutationId"] == "mutation-one"
    refute inspect(record) =~ "destination-secret"
  end

  test "maximum six-byte escaped texts remain readable as a durable revision", %{paths: paths} do
    file = String.duplicate(<<1>>, 65_536)
    prompt = String.duplicate(<<1>>, 131_072)
    {:ok, args} = ProfileSnapshot.build(%{
      "id" => "persona", "systemPrompt" => prompt,
      "model" => String.duplicate("m", 512),
      "instructions" => Map.new(ProfileSnapshot.filenames(), &{&1, file})
    }, String.duplicate("m", 128))
    assert {:ok, ack} = ProfileSync.apply(args)
    marker = Path.join(paths["home"], "persona-revision.json")
    bytes = File.read!(marker)
    assert byte_size(bytes) > 2_100_000
    assert byte_size(bytes) <= 2_400_000
    assert Jason.decode!(bytes) == args
    assert {:ok, ^ack} = ProfileSync.apply(args)
    request = Map.take(args, ~w(profileId mutationId revisionDigest))
    assert {:ok, %{"status" => "acknowledged", "revisionDigest" => digest}} =
             ProfileSync.status(request)
    assert digest == args["revisionDigest"]
    for name <- ProfileSnapshot.filenames() do
      assert File.read!(Path.join(paths["workspace"], name)) == file
    end
  end

  test "128 KiB Unicode prompt persists and replaces exact bytes with the matching revision", %{paths: paths} do
    prompt = "\n " <> String.duplicate("😀", 32_767) <> " \n"
    replacement = "\t " <> String.duplicate("界", 43_689) <> " \t\n"
    assert byte_size(prompt) == 131_072
    assert byte_size(replacement) == 131_072
    {:ok, first} = ProfileSnapshot.build(%{"id" => "persona", "systemPrompt" => prompt}, "first")
    {:ok, second} = ProfileSnapshot.build(%{"id" => "persona", "systemPrompt" => replacement}, "second")
    marker = Path.join(paths["home"], "persona-revision.json")
    for args <- [first, second] do
      assert {:ok, ack} = ProfileSync.apply(args)
      record = marker |> File.read!() |> Jason.decode!()
      assert record == args
      assert record["revisionDigest"] == ProfileSnapshot.revision_digest(record)
      assert {:ok, ^ack} = ProfileSync.apply(args)
      request = Map.take(args, ~w(profileId mutationId revisionDigest))
      assert {:ok, %{"status" => "acknowledged", "revisionDigest" => digest}} =
               ProfileSync.status(request)
      assert digest == args["revisionDigest"]
    end
    refute first["revisionDigest"] == second["revisionDigest"]
  end

  test "invalid prompt and persona text is rejected before provisioning", %{root: root} do
    args = payload("invalid-text")
    for text <- [String.duplicate("x", 131_073), <<0xFF>>,
                 <<0xED, 0xA0, 0x80>>, "bad\0prompt"] do
      assert {:error, :invalid_profile_snapshot} =
               ProfileSync.apply(%{args | "systemPrompt" => text})
    end
    for text <- [String.duplicate("x", 65_537), <<0xFF>>, "bad\0persona"] do
      assert {:error, :invalid_profile_snapshot} =
               ProfileSync.apply(%{args | "personaInstructions" => %{"SOUL.md" => text}})
    end
    refute File.exists?(root)
  end

  test "durable revisions over the record ceiling fail closed", %{paths: paths} do
    args = payload("oversized-record")
    assert {:ok, _} = ProfileSync.apply(args)
    marker = Path.join(paths["home"], "persona-revision.json")
    File.write!(marker, String.duplicate(" ", 2_400_001))
    assert {:error, :profile_sync_corrupt} = ProfileSync.apply(args)
    request = Map.take(args, ~w(profileId mutationId revisionDigest))
    assert {:error, :profile_sync_corrupt} = ProfileSync.status(request)
  end

  test "latest mutation binding survives reload and null revision replays", %{paths: paths} do
    original = payload("fixed")
    assert {:ok, _} = ProfileSync.apply(original)
    assert {:ok, _} = ProfileSync.apply(payload(nil))
    changed = payload("fixed", %{"SOUL.md" => "changed"})
    assert {:error, :mutation_conflict} = ProfileSync.apply(changed)
    assert File.read!(Path.join(paths["workspace"], "SOUL.md")) == "soul"
    assert {:ok, _} = ProfileSync.apply(payload("next", %{"SOUL.md" => "changed"}))
    receipt = paths["home"] |> Path.join("persona-sync-receipt.json") |> File.read!() |> Jason.decode!()
    assert receipt["mutationId"] == "next"
    assert Enum.sort(Map.keys(receipt)) ==
             Enum.sort(~w(profileId mutationId revisionDigest status))
  end

  test "committed persona or revision corruption cannot receive a replay acknowledgement", %{paths: paths} do
    args = payload("corrupt")
    assert {:ok, _} = ProfileSync.apply(args)
    soul = Path.join(paths["workspace"], "SOUL.md")
    File.write!(soul, "corruption")
    assert {:error, :profile_sync_corrupt} = ProfileSync.apply(args)
    File.write!(soul, "soul")
    File.write!(Path.join(paths["home"], "persona-revision.json"), "{broken")
    assert {:error, :profile_sync_corrupt} = ProfileSync.apply(args)
  end

  test "a new revision removes omitted persona files but not destination-owned files", %{paths: paths} do
    assert {:ok, _} = ProfileSync.apply(payload("first"))
    user = Path.join(paths["workspace"], "USER.md")
    File.write!(user, "local")
    {:ok, args} = ProfileSnapshot.build(%{"id" => "persona", "instructions" => %{"AGENTS.md" => "new"}}, "second")
    assert {:ok, _} = ProfileSync.apply(args)
    refute File.exists?(Path.join(paths["workspace"], "SOUL.md"))
    assert File.read!(user) == "local"
  end

  test "rejects traversal IDs, untrusted fields and mismatched revisions before writing", %{root: root} do
    assert {:error, :invalid_profile_snapshot} = ProfileSync.apply(%{payload(nil) | "profileId" => "../escape"})
    assert {:error, _} = ProfileSync.apply(Map.put(payload(nil), "credentials", "source-secret"))
    assert {:error, :revision_mismatch} = ProfileSync.apply(%{payload(nil) | "revisionDigest" => String.duplicate("0", 64)})
    refute File.exists?(root)
  end

  test "rejects symlink home and ancestor boundaries without touching outside data", %{root: root, paths: paths} do
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "SOUL.md"), "outside")
    File.mkdir_p!(Path.dirname(paths["home"]))
    File.ln_s!(outside, paths["home"])
    assert {:error, :unsafe_profile_boundary} = ProfileSync.apply(payload(nil))
    assert File.read!(Path.join(outside, "SOUL.md")) == "outside"
    File.rm!(paths["home"])
    File.rmdir!(Path.dirname(paths["home"]))
    File.ln_s!(outside, Path.dirname(paths["home"]))
    assert {:error, :unsafe_profile_boundary} = ProfileSync.apply(payload(nil))
    refute File.exists?(Path.join(outside, "persona"))
  end

  test "rejects unsafe persona/config file boundaries before any file is replaced", %{root: root, paths: paths} do
    File.mkdir_p!(paths["workspace"])
    agents = Path.join(paths["workspace"], "AGENTS.md")
    File.write!(agents, "local original")
    outside = Path.join(root, "outside.txt")
    File.write!(outside, "outside")
    soul = Path.join(paths["workspace"], "SOUL.md")
    File.ln_s!(outside, soul)
    assert {:error, :unsafe_profile_boundary} = ProfileSync.apply(payload(nil))
    assert File.read!(agents) == "local original"
    assert File.read!(outside) == "outside"
    File.rm!(soul)
    File.mkdir!(paths["config"])
    assert {:error, :unsafe_profile_boundary} = ProfileSync.apply(payload(nil))
    assert File.read!(agents) == "local original"
  end

  test "lost acknowledgement is reconciled read-only against exact committed files", %{paths: paths} do
    args = payload("lost-reply")
    assert {:ok, _lost_ack} = ProfileSync.apply(args)
    request = Map.take(args, ~w(profileId mutationId revisionDigest))
    marker = Path.join(paths["home"], "persona-revision.json")
    receipt_path = Path.join(paths["home"], "persona-sync-receipt.json")
    before_record = File.read!(marker)
    before_receipt = File.read!(receipt_path)
    assert {:ok, %{"status" => "acknowledged", "acknowledged" => true, "revisionDigest" => digest}} = ProfileSync.status(request)
    assert digest == args["revisionDigest"]
    assert File.read!(marker) == before_record
    assert File.read!(receipt_path) == before_receipt
    File.write!(Path.join(paths["workspace"], "SOUL.md"), "corrupt")
    assert {:error, :profile_sync_corrupt} = ProfileSync.status(request)
    assert File.read!(receipt_path) == before_receipt
  end

  test "unknown missing binding is distinct from corrupt or unsafe receipt storage", %{root: root, paths: paths} do
    request = Map.take(payload("missing"), ~w(profileId mutationId revisionDigest))
    assert {:ok, %{"status" => "unknown", "acknowledged" => false, "revisionDigest" => nil}} = ProfileSync.status(request)
    refute File.exists?(root)
    File.mkdir_p!(paths["home"])
    receipt_path = Path.join(paths["home"], "persona-sync-receipt.json")
    File.write!(receipt_path, "{broken")
    assert {:error, :profile_sync_corrupt} = ProfileSync.status(request)
    File.rm!(receipt_path)
    File.mkdir!(receipt_path)
    assert {:error, :unsafe_profile_boundary} = ProfileSync.status(request)
  end

  test "an interrupted reservation is pending without creating files and binds digest on replay", %{paths: paths} do
    args = payload("reserved")
    request = Map.take(args, ~w(profileId mutationId revisionDigest))
    File.mkdir_p!(paths["home"])
    receipt_path = Path.join(paths["home"], "persona-sync-receipt.json")
    reserved = Map.put(request, "status", "pending")
    File.write!(receipt_path, Jason.encode!(reserved))
    bytes = File.read!(receipt_path)
    assert {:ok, %{"status" => "pending", "acknowledged" => false}} = ProfileSync.status(request)
    refute File.exists?(paths["workspace"])
    assert File.read!(receipt_path) == bytes
    assert {:error, :mutation_conflict} = ProfileSync.apply(payload("reserved", %{"SOUL.md" => "changed"}))
    assert {:ok, _} = ProfileSync.apply(args)
    assert {:ok, %{"status" => "acknowledged"}} = ProfileSync.status(request)
  end

  test "sync reserves mutation durably before a persona verification failure", %{paths: paths} do
    assert {:ok, _} = ProfileSync.apply(payload(nil))
    File.write!(Path.join(paths["workspace"], "SOUL.md"), "corrupt")
    args = payload("failed-fixed")
    assert {:error, :profile_sync_corrupt} = ProfileSync.apply(args)
    receipt = paths["home"] |> Path.join("persona-sync-receipt.json") |> File.read!() |> Jason.decode!()
    assert receipt["mutationId"] == "failed-fixed"
    assert receipt["status"] == "pending"
    assert receipt["revisionDigest"] == args["revisionDigest"]
    assert {:error, :mutation_conflict} = ProfileSync.apply(payload("failed-fixed", %{"SOUL.md" => "different"}))
    assert {:error, :profile_sync_corrupt} = ProfileSync.status(Map.take(args, ~w(profileId mutationId revisionDigest)))
  end

  test "source mismatch, overwritten revision and superseded mutations never acknowledge", %{paths: paths} do
    first = payload("first")
    request = Map.take(first, ~w(profileId mutationId revisionDigest))
    assert {:ok, _} = ProfileSync.apply(first)
    mismatch = Map.take(payload("first", %{"SOUL.md" => "changed"}), ~w(profileId mutationId revisionDigest))
    assert {:ok, %{"status" => "unknown", "revisionDigest" => nil}} = ProfileSync.status(mismatch)
    assert {:ok, _} = ProfileSync.apply(payload(nil, %{"SOUL.md" => "local revision"}))
    assert {:ok, %{"status" => "unknown"}} = ProfileSync.status(request)
    assert {:error, :mutation_conflict} = ProfileSync.apply(payload("first", %{"SOUL.md" => "different"}))
    assert {:ok, _} = ProfileSync.apply(payload("second"))
    assert {:ok, %{"status" => "unknown"}} = ProfileSync.status(request)
    File.write!(Path.join(paths["workspace"], "SOUL.md"), "corrupt current revision")
    assert {:error, :profile_sync_corrupt} = ProfileSync.status(request)
    File.write!(Path.join(paths["home"], "persona-revision.json"), "{corrupt")
    assert {:error, :profile_sync_corrupt} = ProfileSync.status(request)
  end

  defp payload(mutation, changes \\ %{}) do
    {:ok, payload} = ProfileSnapshot.build(%{
      "id" => "persona", "model" => "openai:gpt-5", "systemPrompt" => "trusted persona",
      "instructions" => Map.merge(%{"AGENTS.md" => "agents", "IDENTITY.md" => "identity", "README.md" => "readme", "SOUL.md" => "soul"}, changes)
    }, mutation)
    payload
  end

  defp canonical_tmp do
    System.tmp_dir!()
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn part, parent ->
      path = Path.join(parent, part)
      case File.read_link(path) do
        {:ok, target} -> Path.expand(target, parent)
        _ -> path
      end
    end)
  end
end
