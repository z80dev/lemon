defmodule CodingAgent.InternalUrls.NotesProtocolTest do
  use ExUnit.Case, async: true

  alias CodingAgent.InternalUrls.NotesProtocol

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup do
    test_id = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "notes_protocol_test_#{test_id}")
    File.mkdir_p!(tmp_dir)

    session_id = "sess_#{test_id}"

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir, session_id: session_id}
  end

  # ============================================================================
  # parse_notes_url/1
  # ============================================================================

  describe "parse_notes_url/1" do
    test "parses simple filename" do
      assert {:ok, %{scheme: "notes", path: "plan.md"}} =
               NotesProtocol.parse_notes_url("notes://plan.md")
    end

    test "parses path with subdirectory" do
      assert {:ok, %{scheme: "notes", path: "subdir/artifact.md"}} =
               NotesProtocol.parse_notes_url("notes://subdir/artifact.md")
    end

    test "parses deeply nested path" do
      assert {:ok, %{scheme: "notes", path: "a/b/c/file.txt"}} =
               NotesProtocol.parse_notes_url("notes://a/b/c/file.txt")
    end

    test "strips leading slashes" do
      assert {:ok, %{scheme: "notes", path: "plan.md"}} =
               NotesProtocol.parse_notes_url("notes:///plan.md")
    end

    test "strips trailing slashes" do
      assert {:ok, %{scheme: "notes", path: "plan.md"}} =
               NotesProtocol.parse_notes_url("notes://plan.md/")
    end

    test "rejects non-notes scheme" do
      assert {:error, :invalid_scheme} =
               NotesProtocol.parse_notes_url("http://example.com")
    end

    test "rejects plan:// scheme" do
      assert {:error, :invalid_scheme} =
               NotesProtocol.parse_notes_url("plan://something")
    end

    test "rejects empty path" do
      assert {:error, :empty_path} =
               NotesProtocol.parse_notes_url("notes://")
    end

    test "rejects path that is only slashes" do
      assert {:error, :empty_path} =
               NotesProtocol.parse_notes_url("notes:///")
    end

    test "rejects non-string input" do
      assert {:error, :invalid_url} = NotesProtocol.parse_notes_url(123)
      assert {:error, :invalid_url} = NotesProtocol.parse_notes_url(nil)
    end

    test "rejects malformed URL without ://" do
      assert {:error, :invalid_url} =
               NotesProtocol.parse_notes_url("notes:plan.md")
    end
  end

  # ============================================================================
  # resolve/2
  # ============================================================================

  describe "resolve/2" do
    test "resolves to path under notes directory", %{tmp_dir: tmp_dir, session_id: session_id} do
      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:ok, path} = NotesProtocol.resolve("notes://plan.md", opts)
      assert String.ends_with?(path, "/plan.md")
      assert String.contains?(path, "notes")
      assert String.contains?(path, session_id)
    end

    test "resolves nested path", %{tmp_dir: tmp_dir, session_id: session_id} do
      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:ok, path} = NotesProtocol.resolve("notes://subdir/file.md", opts)
      assert String.ends_with?(path, "/subdir/file.md")
    end

    test "rejects path traversal with ..", %{tmp_dir: tmp_dir, session_id: session_id} do
      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:error, :path_traversal} =
               NotesProtocol.resolve("notes://../../../etc/passwd", opts)
    end

    test "normalizes leading slashes in URL path", %{tmp_dir: tmp_dir, session_id: session_id} do
      # notes:///etc/passwd has the path stripped of leading slashes,
      # becoming "etc/passwd" which is safely relative to the notes dir
      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:ok, path} = NotesProtocol.resolve("notes:///etc/passwd", opts)
      assert String.ends_with?(path, "/etc/passwd")
      assert String.contains?(path, session_id)
    end

    test "rejects null bytes in path", %{tmp_dir: tmp_dir, session_id: session_id} do
      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:error, :invalid_path} =
               NotesProtocol.resolve("notes://file\0.md", opts)
    end

    test "rejects hidden traversal with encoded ..", %{tmp_dir: tmp_dir, session_id: session_id} do
      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:error, :path_traversal} =
               NotesProtocol.resolve("notes://foo/../../../etc/passwd", opts)
    end

    test "passes through invalid scheme", %{tmp_dir: tmp_dir, session_id: session_id} do
      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:error, :invalid_scheme} =
               NotesProtocol.resolve("http://example.com", opts)
    end

    test "uses session fallback when file missing in primary", %{
      tmp_dir: tmp_dir,
      session_id: session_id
    } do
      fallback_id = "fallback_#{System.unique_integer([:positive])}"

      # Create file in fallback session but not primary
      fallback_dir = NotesProtocol.notes_dir(tmp_dir, fallback_id)
      File.mkdir_p!(fallback_dir)
      File.write!(Path.join(fallback_dir, "shared.md"), "fallback content")

      opts = [
        session_id: session_id,
        cwd: tmp_dir,
        fallback_session_ids: [fallback_id]
      ]

      assert {:ok, path} = NotesProtocol.resolve("notes://shared.md", opts)
      assert String.contains?(path, fallback_id)
      assert File.exists?(path)
    end

    test "prefers primary session over fallback", %{tmp_dir: tmp_dir, session_id: session_id} do
      fallback_id = "fallback_#{System.unique_integer([:positive])}"

      # Create file in both sessions
      primary_dir = NotesProtocol.notes_dir(tmp_dir, session_id)
      fallback_dir = NotesProtocol.notes_dir(tmp_dir, fallback_id)
      File.mkdir_p!(primary_dir)
      File.mkdir_p!(fallback_dir)
      File.write!(Path.join(primary_dir, "plan.md"), "primary")
      File.write!(Path.join(fallback_dir, "plan.md"), "fallback")

      opts = [
        session_id: session_id,
        cwd: tmp_dir,
        fallback_session_ids: [fallback_id]
      ]

      assert {:ok, path} = NotesProtocol.resolve("notes://plan.md", opts)
      assert String.contains?(path, session_id)
      refute String.contains?(path, fallback_id)
    end

    test "returns primary path when no fallback has the file", %{
      tmp_dir: tmp_dir,
      session_id: session_id
    } do
      fallback_id = "fallback_#{System.unique_integer([:positive])}"

      opts = [
        session_id: session_id,
        cwd: tmp_dir,
        fallback_session_ids: [fallback_id]
      ]

      assert {:ok, path} = NotesProtocol.resolve("notes://missing.md", opts)
      assert String.contains?(path, session_id)
    end
  end

  # ============================================================================
  # list_files/1
  # ============================================================================

  describe "list_files/1" do
    test "returns empty list when notes dir doesn't exist", %{
      tmp_dir: tmp_dir,
      session_id: session_id
    } do
      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:ok, []} = NotesProtocol.list_files(opts)
    end

    test "lists files in notes directory", %{tmp_dir: tmp_dir, session_id: session_id} do
      dir = NotesProtocol.notes_dir(tmp_dir, session_id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "plan.md"), "plan content")
      File.write!(Path.join(dir, "notes.md"), "notes content")

      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:ok, files} = NotesProtocol.list_files(opts)
      assert "notes.md" in files
      assert "plan.md" in files
      assert length(files) == 2
    end

    test "lists files in subdirectories", %{tmp_dir: tmp_dir, session_id: session_id} do
      dir = NotesProtocol.notes_dir(tmp_dir, session_id)
      sub_dir = Path.join(dir, "artifacts")
      File.mkdir_p!(sub_dir)
      File.write!(Path.join(dir, "plan.md"), "plan")
      File.write!(Path.join(sub_dir, "diagram.md"), "diagram")

      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:ok, files} = NotesProtocol.list_files(opts)
      assert "plan.md" in files
      assert "artifacts/diagram.md" in files
    end

    test "returns sorted file list", %{tmp_dir: tmp_dir, session_id: session_id} do
      dir = NotesProtocol.notes_dir(tmp_dir, session_id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "zebra.md"), "z")
      File.write!(Path.join(dir, "alpha.md"), "a")
      File.write!(Path.join(dir, "middle.md"), "m")

      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:ok, ["alpha.md", "middle.md", "zebra.md"]} = NotesProtocol.list_files(opts)
    end
  end

  # ============================================================================
  # rename_approved_plan/3
  # ============================================================================

  describe "rename_approved_plan/3" do
    test "renames plan to approved plan", %{tmp_dir: tmp_dir, session_id: session_id} do
      dir = NotesProtocol.notes_dir(tmp_dir, session_id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "plan.md"), "the plan")

      opts = [session_id: session_id, cwd: tmp_dir]

      assert :ok = NotesProtocol.rename_approved_plan("plan.md", "approved-plan.md", opts)
      refute File.exists?(Path.join(dir, "plan.md"))
      assert File.read!(Path.join(dir, "approved-plan.md")) == "the plan"
    end

    test "returns error when source doesn't exist", %{tmp_dir: tmp_dir, session_id: session_id} do
      dir = NotesProtocol.notes_dir(tmp_dir, session_id)
      File.mkdir_p!(dir)

      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:error, :source_not_found} =
               NotesProtocol.rename_approved_plan("nonexistent.md", "approved.md", opts)
    end

    test "rejects path traversal in source name", %{tmp_dir: tmp_dir, session_id: session_id} do
      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:error, :path_traversal} =
               NotesProtocol.rename_approved_plan("../evil.md", "approved.md", opts)
    end

    test "rejects path traversal in target name", %{tmp_dir: tmp_dir, session_id: session_id} do
      opts = [session_id: session_id, cwd: tmp_dir]

      assert {:error, :path_traversal} =
               NotesProtocol.rename_approved_plan("plan.md", "../evil.md", opts)
    end

    test "creates target subdirectory if needed", %{tmp_dir: tmp_dir, session_id: session_id} do
      dir = NotesProtocol.notes_dir(tmp_dir, session_id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "plan.md"), "plan content")

      opts = [session_id: session_id, cwd: tmp_dir]

      assert :ok =
               NotesProtocol.rename_approved_plan("plan.md", "approved/plan.md", opts)

      assert File.exists?(Path.join(dir, "approved/plan.md"))
    end
  end

  # ============================================================================
  # notes_dir/2 and ensure_notes_dir!/2
  # ============================================================================

  describe "notes_dir/2" do
    test "returns path under sessions directory", %{tmp_dir: tmp_dir, session_id: session_id} do
      dir = NotesProtocol.notes_dir(tmp_dir, session_id)

      assert String.contains?(dir, "sessions")
      assert String.contains?(dir, "notes")
      assert String.contains?(dir, session_id)
    end

    test "returns different paths for different sessions", %{tmp_dir: tmp_dir} do
      dir1 = NotesProtocol.notes_dir(tmp_dir, "session_a")
      dir2 = NotesProtocol.notes_dir(tmp_dir, "session_b")

      assert dir1 != dir2
    end

    test "returns different paths for different cwds", %{session_id: session_id} do
      dir1 = NotesProtocol.notes_dir("/project/a", session_id)
      dir2 = NotesProtocol.notes_dir("/project/b", session_id)

      assert dir1 != dir2
    end
  end

  describe "ensure_notes_dir!/2" do
    test "creates the notes directory", %{tmp_dir: tmp_dir, session_id: session_id} do
      dir = NotesProtocol.notes_dir(tmp_dir, session_id)
      refute File.dir?(dir)

      assert :ok = NotesProtocol.ensure_notes_dir!(tmp_dir, session_id)
      assert File.dir?(dir)
    end

    test "is idempotent", %{tmp_dir: tmp_dir, session_id: session_id} do
      assert :ok = NotesProtocol.ensure_notes_dir!(tmp_dir, session_id)
      assert :ok = NotesProtocol.ensure_notes_dir!(tmp_dir, session_id)
      assert File.dir?(NotesProtocol.notes_dir(tmp_dir, session_id))
    end
  end
end
