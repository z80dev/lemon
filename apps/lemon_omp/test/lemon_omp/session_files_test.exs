defmodule LemonOmp.SessionFilesTest do
  use ExUnit.Case, async: true

  alias LemonOmp.SessionFiles

  setup do
    root = Path.join(System.tmp_dir!(), "lemon_omp_sf_#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    sessions_dir = Path.join(root, "agent/sessions")
    File.mkdir_p!(workspace)
    File.mkdir_p!(sessions_dir)
    on_exit(fn -> File.rm_rf(root) end)

    canonical = canonical(workspace)
    {:ok, workspace: workspace, canonical: canonical, sessions_dir: sessions_dir}
  end

  # The OS's own symlink-free path (e.g. macOS /var -> /private/var).
  defp canonical(dir) do
    {out, 0} = System.cmd("/bin/pwd", ["-P"], cd: dir)
    String.trim(out)
  end

  defp absolute_name(path),
    do: "--" <> (path |> String.trim_leading("/") |> String.replace("/", "-")) <> "--"

  defp title_slot(title) do
    String.pad_trailing(Jason.encode!(%{"type" => "title", "v" => 1, "title" => title}), 256)
  end

  defp header(id, cwd, extra \\ %{}) do
    Jason.encode!(
      Map.merge(
        %{
          "type" => "session",
          "version" => 3,
          "id" => id,
          "cwd" => cwd,
          "timestamp" => "2026-10-13T10:00:00.000Z"
        },
        extra
      )
    )
  end

  defp user(text),
    do:
      Jason.encode!(%{
        "type" => "message",
        "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
      })

  defp assistant(stop_reason, extra \\ %{}) do
    Jason.encode!(%{
      "type" => "message",
      "message" =>
        Map.merge(
          %{
            "role" => "assistant",
            "stopReason" => stop_reason,
            "content" => [%{"type" => "text", "text" => "ok"}]
          },
          extra
        )
    })
  end

  defp tool_result,
    do:
      Jason.encode!(%{
        "type" => "message",
        "message" => %{"role" => "toolResult", "content" => []}
      })

  defp exit_entry,
    do: Jason.encode!(%{"type" => "custom", "customType" => "session_exit", "data" => %{}})

  defp write_session(dir, id, lines, opts \\ []) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "2026-10-13T10-00-00-000Z_#{id}.jsonl")
    File.write!(path, Enum.map_join(lines, "", &(&1 <> "\n")))

    case Keyword.get(opts, :age_s) do
      nil -> :ok
      age -> File.touch!(path, System.os_time(:second) - age)
    end

    path
  end

  defp by_id(sessions), do: Map.new(sessions, &{&1["ompSessionId"], &1})

  test "finds sessions stored under the absolute-path encoding", ctx do
    dir = Path.join(ctx.sessions_dir, absolute_name(ctx.canonical))

    write_session(dir, "01aaa", [
      title_slot("Refactor the parser"),
      header("01aaa", ctx.canonical),
      user("please refactor"),
      assistant("stop", %{"provider" => "anthropic", "model" => "claude-x"}),
      exit_entry()
    ])

    assert {:ok, [session]} = SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir)

    assert session == %{
             "ompSessionId" => "01aaa",
             "title" => "Refactor the parser",
             "cwd" => ctx.canonical,
             "createdAt" => 1_791_885_600_000,
             "updatedAt" => session["updatedAt"],
             "model" => "anthropic/claude-x",
             "lastStatus" => "completed",
             "interrupted" => false,
             "activeElsewhere" => false,
             "liveId" => nil
           }

    assert is_integer(session["updatedAt"])
    assert {:ok, _} = Jason.encode(session)
  end

  test "finds sessions stored under the temp-relative encoding", ctx do
    tmp_root = canonical(System.tmp_dir!())
    relative = String.replace_prefix(ctx.canonical, tmp_root <> "/", "")
    dir = Path.join(ctx.sessions_dir, "-tmp-" <> String.replace(relative, "/", "-"))

    write_session(dir, "01tmp", [title_slot("tmp session"), header("01tmp", ctx.canonical)],
      age_s: 600
    )

    assert {:ok, [%{"ompSessionId" => "01tmp", "lastStatus" => "unknown"}]} =
             SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir)
  end

  test "candidate names cover home-relative, temp-relative and absolute encodings" do
    home = canonical(System.user_home!())
    project = Path.join(home, "dev/my proj")

    names = SessionFiles.candidate_dir_names(project, project)
    assert "-dev-my proj" in names
    assert ("--" <> String.replace(String.trim_leading(project, "/"), "/", "-") <> "--") in names

    assert "-" in SessionFiles.candidate_dir_names(home, home)
    assert SessionFiles.candidate_dir_names("/opt/x/y", "/opt/x/y") == ["--opt-x-y--"]
  end

  test "ignores files whose header cwd is another workspace", ctx do
    dir = Path.join(ctx.sessions_dir, absolute_name(ctx.canonical))
    elsewhere = Path.join(Path.dirname(ctx.workspace), "elsewhere")

    write_session(dir, "01mismatch", [
      title_slot("other"),
      header("01mismatch", elsewhere),
      user("x")
    ])

    write_session(dir, "01noheader", [title_slot("no header"), user("x")])
    write_session(dir, "01badid", [header(nil, ctx.canonical)])
    File.write!(Path.join(dir, "garbage.jsonl"), "\x00\x01not json\n{]\n")
    File.write!(Path.join(dir, "notes.txt"), header("01txt", ctx.canonical))
    File.mkdir_p!(Path.join(dir, "subdir.jsonl"))

    # A header naming the same directory through a non-canonical path still counts.
    write_session(dir, "01alias", [header("01alias", ctx.workspace <> "/./")])

    assert {:ok, sessions} = SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir)
    assert Enum.map(sessions, & &1["ompSessionId"]) == ["01alias"]
  end

  test "derives the last status from the newest message and exit marker", ctx do
    dir = Path.join(ctx.sessions_dir, absolute_name(ctx.canonical))

    cases = %{
      "01completed" => {[user("a"), assistant("stop")], "completed"},
      "01error" => {[user("a"), assistant("error"), exit_entry()], "error"},
      "01aborted" => {[user("a"), assistant("aborted")], "aborted"},
      "01toolUse" => {[user("a"), assistant("toolUse")], "interrupted"},
      "01toolUseExit" => {[user("a"), assistant("toolUse"), exit_entry()], "exited"},
      "01user" => {[user("a")], "interrupted"},
      "01toolResultExit" =>
        {[user("a"), assistant("toolUse"), tool_result(), exit_entry()], "exited"},
      "01empty" => {[exit_entry()], "empty"},
      "01blank" => {[], "unknown"}
    }

    for {id, {entries, _status}} <- cases do
      write_session(dir, id, [header(id, ctx.canonical) | entries], age_s: 3_600)
    end

    assert {:ok, sessions} = SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir)
    found = by_id(sessions)

    for {id, {_entries, status}} <- cases do
      assert found[id]["lastStatus"] == status, "#{id}: #{inspect(found[id])}"
      assert found[id]["interrupted"] == (status == "interrupted")
    end
  end

  test "titles fall back from the slot to the header to the first prompt, sanitized", ctx do
    dir = Path.join(ctx.sessions_dir, absolute_name(ctx.canonical))

    write_session(dir, "01slot", [
      title_slot("\e[31mSlot\e[0m title\u202E"),
      header("01slot", ctx.canonical)
    ])

    write_session(dir, "01header", [
      title_slot(""),
      header("01header", ctx.canonical, %{"title" => "Header title"})
    ])

    write_session(dir, "01prompt", [
      header("01prompt", ctx.canonical),
      user("First line\nsecond line")
    ])

    write_session(dir, "01none", [header("01none", ctx.canonical)])

    assert {:ok, sessions} = SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir)
    found = by_id(sessions)

    assert found["01slot"]["title"] == "Slot title"
    assert found["01header"]["title"] == "Header title"
    assert found["01prompt"]["title"] == "First line"
    assert found["01none"]["title"] == nil
  end

  test "reads only the head and tail of a large session file", ctx do
    dir = Path.join(ctx.sessions_dir, absolute_name(ctx.canonical))
    filler = for i <- 1..1_500, do: user("filler #{i} " <> String.duplicate("z", 1_000))

    # The middle of the file (beyond the 16 KiB head and 64 KiB tail) holds a
    # newer model change and session exit; a bounded reader never sees them.
    path =
      write_session(
        dir,
        "01large",
        [
          title_slot("Large session"),
          header("01large", ctx.canonical),
          user("the first prompt"),
          assistant("stop", %{"provider" => "head", "model" => "model"})
        ] ++
          filler ++
          [Jason.encode!(%{"type" => "model_change", "model" => "middle/model"}), exit_entry()] ++
          filler ++
          [assistant("aborted")]
      )

    assert File.stat!(path).size > 3_000_000

    assert {:ok, [session]} = SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir)

    assert session["title"] == "Large session"
    assert session["model"] == "head/model"
    assert session["lastStatus"] == "aborted"
    assert session["createdAt"] == 1_791_885_600_000
  end

  test "a file larger than the head but within the tail budget is read to its end", ctx do
    dir = Path.join(ctx.sessions_dir, absolute_name(ctx.canonical))
    filler = for i <- 1..20, do: user("filler #{i} " <> String.duplicate("z", 1_000))

    path =
      write_session(
        dir,
        "01mid",
        [title_slot("Mid session"), header("01mid", ctx.canonical), assistant("toolUse")] ++
          filler ++ [assistant("stop", %{"provider" => "tail", "model" => "model"})]
      )

    size = File.stat!(path).size
    assert size > 16_384 and size < 65_536

    assert {:ok, [session]} = SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir)
    assert session["lastStatus"] == "completed"
    assert session["model"] == "tail/model"
  end

  test "an unterminated last line in the tail is ignored", ctx do
    dir = Path.join(ctx.sessions_dir, absolute_name(ctx.canonical))

    path =
      write_session(dir, "01partial", [
        header("01partial", ctx.canonical),
        user("a"),
        assistant("stop")
      ])

    File.write!(path, ~s({"type":"message","message":{"role":"user","con), [:append])

    assert {:ok, [%{"lastStatus" => "completed"}]} =
             SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir)
  end

  test "flags recently written sessions without an exit marker as active elsewhere", ctx do
    dir = Path.join(ctx.sessions_dir, absolute_name(ctx.canonical))
    write_session(dir, "01fresh", [header("01fresh", ctx.canonical), user("a")])

    write_session(dir, "01freshexit", [
      header("01freshexit", ctx.canonical),
      user("a"),
      exit_entry()
    ])

    write_session(dir, "01stale", [header("01stale", ctx.canonical), user("a")], age_s: 3_600)

    assert {:ok, sessions} = SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir)
    found = by_id(sessions)

    assert found["01fresh"]["activeElsewhere"] == true
    assert found["01freshexit"]["activeElsewhere"] == false
    assert found["01stale"]["activeElsewhere"] == false
  end

  test "returns the newest sessions first, up to the limit", ctx do
    dir = Path.join(ctx.sessions_dir, absolute_name(ctx.canonical))

    for i <- 1..5 do
      write_session(dir, "01s#{i}", [header("01s#{i}", ctx.canonical)], age_s: 1_000 * (6 - i))
    end

    assert {:ok, two} =
             SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir, limit: 2)

    assert Enum.map(two, & &1["ompSessionId"]) == ["01s5", "01s4"]

    for limit <- [nil, 0, -1, "3", 1_000] do
      assert {:ok, all} =
               SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir, limit: limit)

      assert Enum.map(all, & &1["ompSessionId"]) == ["01s5", "01s4", "01s3", "01s2", "01s1"]
    end
  end

  test "an empty or missing sessions directory yields no sessions", ctx do
    assert {:ok, []} = SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir)

    assert {:ok, []} =
             SessionFiles.discover(ctx.workspace,
               sessions_dir: Path.join(ctx.sessions_dir, "nope")
             )
  end

  test "rejects a cwd that is not a directory", ctx do
    assert {:error, :invalid_cwd} =
             SessionFiles.discover(Path.join(ctx.workspace, "missing"),
               sessions_dir: ctx.sessions_dir
             )

    file = Path.join(ctx.workspace, "file.txt")
    File.write!(file, "x")
    assert {:error, :invalid_cwd} = SessionFiles.discover(file, sessions_dir: ctx.sessions_dir)
  end

  test "never writes to the sessions directory", ctx do
    dir = Path.join(ctx.sessions_dir, absolute_name(ctx.canonical))
    path = write_session(dir, "01ro", [header("01ro", ctx.canonical), user("a")], age_s: 100)
    before = File.stat!(path, time: :posix)
    listing = File.ls!(dir)

    assert {:ok, [_]} = SessionFiles.discover(ctx.workspace, sessions_dir: ctx.sessions_dir)

    assert File.stat!(path, time: :posix).mtime == before.mtime
    assert File.stat!(path).size == before.size
    assert File.ls!(dir) == listing
  end
end
