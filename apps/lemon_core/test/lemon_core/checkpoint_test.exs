defmodule LemonCore.CheckpointTest do
  use ExUnit.Case, async: false

  alias LemonCore.Checkpoint
  alias LemonCore.Introspection

  # The test Store backend, except that its durability barrier always fails.
  defmodule SyncRefusingEts do
    @behaviour LemonCore.Store.Backend
    alias LemonCore.Store.EtsBackend

    defdelegate init(opts), to: EtsBackend
    defdelegate put(state, table, key, value), to: EtsBackend
    defdelegate put_new(state, table, key, value), to: EtsBackend
    defdelegate get(state, table, key), to: EtsBackend
    defdelegate delete(state, table, key), to: EtsBackend
    defdelegate sweep(state, table, predicate), to: EtsBackend
    defdelegate compare_and_delete_many(state, entries), to: EtsBackend
    defdelegate list(state, table), to: EtsBackend
    def sync(_state), do: {:error, :sync_refused}
  end

  setup do
    original = Application.get_env(:lemon_core, :introspection, [])
    Application.put_env(:lemon_core, :introspection, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:lemon_core, :introspection, original) end)
    :ok
  end

  @tag :tmp_dir
  test "no restore happens unless consuming the token is durable", %{tmp_dir: tmp_dir} do
    session_id = unique_session("core-durable-take")
    path = Path.join(tmp_dir, "durable.txt")
    File.write!(path, "before\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    assert {:ok, checkpoint} = Checkpoint.create_filesystem(session_id, [path], cwd: tmp_dir)
    File.write!(path, "after\n")

    assert {:ok, %{confirm_token: token}} =
             Checkpoint.restore_preview(checkpoint.id, session_id, caller: session_id)

    original = :sys.get_state(LemonCore.Store).backend
    assert original == LemonCore.Store.EtsBackend
    :sys.replace_state(LemonCore.Store, &%{&1 | backend: SyncRefusingEts})

    result =
      try do
        Checkpoint.confirmed_restore_filesystem(checkpoint.id, session_id, token,
          caller: session_id
        )
      after
        :sys.replace_state(LemonCore.Store, &%{&1 | backend: original})
      end

    assert {:error, :confirmation_unavailable} = result
    assert File.read!(path) == "after\n"
  end

  test "creates, lists, stats, and deletes generic checkpoints" do
    session_id = unique_session("core-generic")

    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    assert {:ok, checkpoint} =
             Checkpoint.create(session_id,
               context: %{step: 1},
               metadata: %{tool: "core-test"}
             )

    assert checkpoint.session_id == session_id
    assert checkpoint.context.step == 1
    assert [listed] = Checkpoint.list(session_id)
    assert listed.id == checkpoint.id
    assert Checkpoint.exists?(checkpoint.id)
    assert Checkpoint.stats(session_id).count == 1
    assert :ok = Checkpoint.delete(checkpoint.id, session_id)
    refute Checkpoint.exists?(checkpoint.id)
  end

  test "loads and scans freeform JSON keys without requiring or creating atoms" do
    session_id = unique_session("core-freeform")
    other_session_id = unique_session("core-other-freeform")
    key = "checkpoint_external_key_#{System.unique_integer([:positive, :monotonic])}"
    nested = %{key => [%{key => "persisted"}]}

    on_exit(fn ->
      Checkpoint.delete_all(session_id)
      Checkpoint.delete_all(other_session_id)
    end)

    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

    assert {:ok, other} = Checkpoint.create(other_session_id, metadata: nested)

    assert {:ok, checkpoint} =
             Checkpoint.create(session_id,
               state: nested,
               context: nested,
               todos: [nested],
               requirements: nested,
               metadata: nested
             )

    assert {:ok, loaded} = Checkpoint.load(checkpoint.id)
    assert loaded.state == nested
    assert loaded.context == nested
    assert loaded.todos == [nested]
    assert loaded.requirements == nested
    assert loaded.metadata[key] == nested[key]
    assert [listed] = Checkpoint.list(session_id)
    assert listed.id == checkpoint.id
    assert listed.metadata[key] == nested[key]
    assert {:ok, %{id: id}} = Checkpoint.get_latest(session_id)
    assert id == checkpoint.id
    assert {:ok, 1} = Checkpoint.delete_all(session_id)
    assert Checkpoint.exists?(other.id)
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  @tag :tmp_dir
  test "diffs and restores filesystem checkpoints with events", %{tmp_dir: tmp_dir} do
    session_id = unique_session("core-filesystem")
    run_id = "run_#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "target.txt")

    File.write!(path, "before\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

    assert {:ok, checkpoint} =
             Checkpoint.create_filesystem(session_id, [path],
               cwd: tmp_dir,
               tool: "core-test",
               run_id: run_id,
               session_key: session_id
             )

    assert_receive %LemonCore.Event{
                     type: :checkpoint_created,
                     payload: %{checkpoint_id: checkpoint_id, checkpoint_kind: "filesystem"}
                   },
                   1_000

    assert checkpoint_id == checkpoint.id
    File.write!(path, "after\n")

    assert {:ok, diff} = Checkpoint.diff_filesystem(checkpoint.id, session_id)
    assert diff.changed == [path]
    assert diff.output =~ "-before"
    assert diff.output =~ "+after"

    assert {:ok, restored} =
             Checkpoint.restore_filesystem(checkpoint.id, session_id,
               paths: [path],
               run_id: run_id,
               session_key: session_id
             )

    assert restored.restored == [path]
    assert File.read!(path) == "before\n"

    assert_receive %LemonCore.Event{
                     type: :checkpoint_restored,
                     payload: %{checkpoint_id: ^checkpoint_id, restored_count: 1}
                   },
                   1_000

    event =
      Introspection.list(event_type: :checkpoint_restored, run_id: run_id, limit: 20)
      |> Enum.find(&(&1.payload.checkpoint_id == checkpoint.id))

    assert event.payload.restored_count == 1
  end

  @tag :tmp_dir
  test "a checkpoint created in session A cannot be previewed or restored from session B",
       %{tmp_dir: tmp_dir} do
    session_a = unique_session("core-owner-a")
    session_b = unique_session("core-owner-b")
    path = Path.join(tmp_dir, "owned.txt")
    File.write!(path, "a-before\n")
    on_exit(fn -> Checkpoint.delete_all(session_a) end)

    assert {:ok, checkpoint} = Checkpoint.create_filesystem(session_a, [path], cwd: tmp_dir)
    File.write!(path, "a-after\n")

    assert {:error, :not_found} =
             Checkpoint.restore_preview(checkpoint.id, session_b, caller: :caller_b)

    assert {:ok, %{confirm_token: token}} =
             Checkpoint.restore_preview(checkpoint.id, session_a, caller: :caller_a)

    assert {:error, :not_found} =
             Checkpoint.confirmed_restore_filesystem(checkpoint.id, session_b, token,
               caller: :caller_a
             )

    assert {:error, :not_found} = Checkpoint.restore_filesystem(checkpoint.id, session_b)
    assert File.read!(path) == "a-after\n"
  end

  @tag :tmp_dir
  test "confirmed restore requires the current issued preview token", %{tmp_dir: tmp_dir} do
    session_id = unique_session("core-preview")
    path = Path.join(tmp_dir, "previewed.txt")
    File.write!(path, "before\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)
    caller = {:chat, session_id}

    assert {:ok, checkpoint} = Checkpoint.create_filesystem(session_id, [path], cwd: tmp_dir)
    File.write!(path, "after\n")

    assert {:ok, preview} = Checkpoint.restore_preview(checkpoint.id, session_id, caller: caller)
    assert preview.checkpoint_id == checkpoint.id
    assert preview.changed == [path]
    assert byte_size(preview.confirm_token) >= 32

    # Missing and literal-word confirmations change nothing.
    for missing <- [nil, "", "confirm"] do
      assert {:error, reason} =
               Checkpoint.confirmed_restore_filesystem(checkpoint.id, session_id, missing,
                 caller: caller
               )

      assert reason in [:confirmation_required, :invalid_confirmation]
      assert File.read!(path) == "after\n"
    end

    # The tree changed after the preview: the token is stale (and now spent).
    File.write!(path, "changed-again\n")

    assert {:error, :stale_confirmation} =
             Checkpoint.confirmed_restore_filesystem(
               checkpoint.id,
               session_id,
               preview.confirm_token,
               caller: caller
             )

    assert File.read!(path) == "changed-again\n"

    assert {:ok, fresh} = Checkpoint.restore_preview(checkpoint.id, session_id, caller: caller)
    refute fresh.confirm_token == preview.confirm_token

    assert {:ok, %{restored: [^path]}} =
             Checkpoint.confirmed_restore_filesystem(
               checkpoint.id,
               session_id,
               fresh.confirm_token,
               caller: caller
             )

    assert File.read!(path) == "before\n"
  end

  @tag :tmp_dir
  test "a token computed from checkpoint and tree data without a preview is refused",
       %{tmp_dir: tmp_dir} do
    session_id = unique_session("core-unissued")
    path = Path.join(tmp_dir, "unissued.txt")
    File.write!(path, "before\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    assert {:ok, checkpoint} = Checkpoint.create_filesystem(session_id, [path], cwd: tmp_dir)
    File.write!(path, "after\n")

    # Everything the previous checksum token was derived from is readable by
    # anyone who can read the checkpoint store and the workspace.
    assert {:ok, loaded} = Checkpoint.load(checkpoint.id)
    assert {:ok, files} = Checkpoint.confined_filesystem_files(loaded)
    assert {:ok, fingerprint} = Checkpoint.filesystem_fingerprint(path)

    computed =
      {1, loaded.id, loaded.session_id, loaded.timestamp, files, [{path, fingerprint}]}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 8)
      |> Base.encode16(case: :lower)

    random = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    for token <- [computed, random] do
      assert {:error, :invalid_confirmation} =
               Checkpoint.confirmed_restore_filesystem(checkpoint.id, session_id, token,
                 caller: session_id
               )

      assert File.read!(path) == "after\n"
    end
  end

  @tag :tmp_dir
  test "a spent token is not revived when the previewed tree state recurs",
       %{tmp_dir: tmp_dir} do
    session_id = unique_session("core-replay")
    path = Path.join(tmp_dir, "replayed.txt")
    File.write!(path, "before\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    assert {:ok, checkpoint} = Checkpoint.create_filesystem(session_id, [path], cwd: tmp_dir)
    File.write!(path, "after\n")

    assert {:ok, %{confirm_token: token}} =
             Checkpoint.restore_preview(checkpoint.id, session_id, caller: session_id)

    assert {:ok, %{restored: [^path]}} =
             Checkpoint.confirmed_restore_filesystem(checkpoint.id, session_id, token,
               caller: session_id
             )

    assert File.read!(path) == "before\n"

    # Recreate exactly the tree the preview fingerprinted, then replay.
    File.write!(path, "after\n")

    assert {:error, :invalid_confirmation} =
             Checkpoint.confirmed_restore_filesystem(checkpoint.id, session_id, token,
               caller: session_id
             )

    assert File.read!(path) == "after\n"
  end

  @tag :tmp_dir
  test "a token is bound to the caller it was issued to and spent by a foreign attempt",
       %{tmp_dir: tmp_dir} do
    session_id = unique_session("core-caller")
    path = Path.join(tmp_dir, "caller.txt")
    File.write!(path, "before\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    assert {:ok, checkpoint} = Checkpoint.create_filesystem(session_id, [path], cwd: tmp_dir)
    File.write!(path, "after\n")

    assert {:ok, %{confirm_token: token}} =
             Checkpoint.restore_preview(checkpoint.id, session_id, caller: {:user, 1})

    assert {:error, :invalid_confirmation} =
             Checkpoint.confirmed_restore_filesystem(checkpoint.id, session_id, token,
               caller: {:user, 2}
             )

    assert {:error, :invalid_confirmation} =
             Checkpoint.confirmed_restore_filesystem(checkpoint.id, session_id, token,
               caller: {:user, 1}
             )

    assert File.read!(path) == "after\n"
  end

  @tag :tmp_dir
  test "tokens expire and are bound to the selected roots", %{tmp_dir: tmp_dir} do
    session_id = unique_session("core-expiry")
    first = Path.join(tmp_dir, "first.txt")
    second = Path.join(tmp_dir, "second.txt")
    File.write!(first, "one\n")
    File.write!(second, "two\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    assert {:ok, checkpoint} =
             Checkpoint.create_filesystem(session_id, [first, second], cwd: tmp_dir)

    File.write!(first, "one-after\n")
    File.write!(second, "two-after\n")

    assert {:ok, %{confirm_token: narrow}} =
             Checkpoint.restore_preview(checkpoint.id, session_id,
               caller: session_id,
               paths: [first]
             )

    assert {:error, :stale_confirmation} =
             Checkpoint.confirmed_restore_filesystem(checkpoint.id, session_id, narrow,
               caller: session_id
             )

    assert {:ok, %{confirm_token: expiring}} =
             Checkpoint.restore_preview(checkpoint.id, session_id, caller: session_id)

    key = :crypto.hash(:sha256, expiring)
    record = LemonCore.Store.get(:checkpoint_restore_confirmations, key)
    assert is_map(record)

    :ok =
      LemonCore.Store.put(:checkpoint_restore_confirmations, key, %{
        record
        | expires_at_ms: System.system_time(:millisecond) - 1
      })

    assert {:error, :invalid_confirmation} =
             Checkpoint.confirmed_restore_filesystem(checkpoint.id, session_id, expiring,
               caller: session_id
             )

    assert File.read!(first) == "one-after\n"
    assert File.read!(second) == "two-after\n"
  end

  defp unique_session(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
