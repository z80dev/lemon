defmodule CodingAgent.Tools.PostWriteSwapRaceTest do
  @moduledoc """
  Deterministic races against the work mutation tools do after their own
  write: formatting, diagnostics and read-tracker bookkeeping.

  `FileServerTap` swaps `root/sub` for a symlink to a directory outside the
  workspace at the first file-server request served after Lemon's write has
  landed (the hook watches the target with `:prim_file`), the way a
  concurrent local writer could. Everything after the write must stay bound
  to the file Lemon wrote, or refuse.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.FileReadTracker
  alias CodingAgent.Tools.{Edit, Patch, Write}
  alias LemonAgent.Types.AgentToolResult
  alias LemonCore.Testing.FileServerTap

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "root")
    sub = Path.join(root, "sub")
    outside = Path.join(tmp, "outside")
    bin = Path.join(tmp, "bin")
    Enum.each([sub, outside, bin], &File.mkdir_p!/1)

    File.write!(Path.join(sub, "main.go"), "package main\n")
    File.write!(Path.join(outside, "main.go"), "outside\n")
    File.write!(Path.join(outside, "sentinel.txt"), "sentinel\n")

    # Operator formatter outside the workspace. File mode (`gofmt -w FILE`)
    # rewrites FILE; filter mode formats stdin to stdout.
    gofmt = Path.join(bin, "gofmt")

    File.write!(gofmt, """
    #!/bin/sh
    if [ "$1" = "-w" ]; then
      c=$(cat "$2"); printf '// fmt\\n%s\\n' "$c" > "$2"
    else
      printf '// fmt\\n'; cat
    fi
    """)

    File.chmod!(gofmt, 0o755)
    previous_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)
    session = "post-write-swap-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      FileReadTracker.forget_session(session)
    end)

    %{
      tmp: tmp,
      root: root,
      sub: sub,
      outside: outside,
      opts: [filesystem_checkpoints: false, session_id: session, format_timeout_ms: 10_000]
    }
  end

  describe "format: true" do
    test "write of an existing file never formats through a swapped ancestor", ctx do
      {result, before} =
        race(ctx, "sub/main.go", fn ->
          Write.execute(
            "write",
            %{
              "path" => "sub/main.go",
              "content" => "package main\n\nfunc main() {}\n",
              "format" => true
            },
            nil,
            nil,
            ctx.root,
            ctx.opts
          )
        end)

      assert_outside_untouched(ctx, before)
      assert %AgentToolResult{details: details} = result
      refute details.formatted
      assert details.format_error =~ "symlink"
      assert File.read!(Path.join(ctx.sub <> ".moved", "main.go")) =~ "func main"
    end

    test "write of a new file never formats through a swapped ancestor", ctx do
      {result, before} =
        race(ctx, "sub/new.go", fn ->
          Write.execute(
            "write",
            %{"path" => "sub/new.go", "content" => "package main\n", "format" => true},
            nil,
            nil,
            ctx.root,
            ctx.opts
          )
        end)

      assert_outside_untouched(ctx, before)
      assert %AgentToolResult{details: %{formatted: false}} = result
    end

    test "edit never formats through a swapped ancestor", ctx do
      {result, before} =
        race(ctx, "sub/main.go", fn ->
          Edit.execute(
            "edit",
            %{
              "path" => "sub/main.go",
              "old_text" => "package main",
              "new_text" => "package edited",
              "format" => true
            },
            nil,
            nil,
            ctx.root,
            ctx.opts
          )
        end)

      assert_outside_untouched(ctx, before)
      assert %AgentToolResult{details: details} = result
      refute details.formatted
      assert details.format_error =~ "symlink"
      assert File.read!(Path.join(ctx.sub <> ".moved", "main.go")) == "package edited\n"
    end

    test "patch never formats through a swapped ancestor", ctx do
      {result, before} =
        race(ctx, "sub/main.go", fn ->
          Patch.execute(
            "patch",
            %{
              "patch_text" =>
                "*** Begin Patch\n*** Update File: sub/main.go\n@@\n-package main\n+package patched\n*** End Patch",
              "format" => true
            },
            nil,
            nil,
            ctx.root,
            ctx.opts
          )
        end)

      assert_outside_untouched(ctx, before)
      assert %AgentToolResult{details: details} = result
      refute details.formatted
      assert File.read!(Path.join(ctx.sub <> ".moved", "main.go")) == "package patched\n"
    end
  end

  describe "diagnostics: true" do
    test "post-edit diagnostics never read a swapped ancestor's file", ctx do
      File.write!(Path.join(ctx.sub, "a.ex"), "value = 1\n")
      # Valid inside, a syntax error in the planted file.
      File.write!(Path.join(ctx.outside, "a.ex"), "value = (\n")
      opts = Keyword.put(ctx.opts, :semantic, false)

      {result, before} =
        race(ctx, "sub/a.ex", fn ->
          Edit.execute(
            "edit",
            %{
              "path" => "sub/a.ex",
              "old_text" => "1",
              "new_text" => "2",
              "diagnostics" => true
            },
            nil,
            nil,
            ctx.root,
            opts
          )
        end)

      assert_outside_untouched(ctx, before)
      assert %AgentToolResult{details: details} = result
      assert details.diagnostics.introduced_diagnostics == []
      refute hd(result.content).text =~ "Diagnostics introduced"
    end
  end

  describe "read tracker" do
    test "an archive write records the committed bytes, never a swapped ancestor's file", ctx do
      archive = Path.join(ctx.sub, "bundle.zip")
      {:ok, _} = :zip.create(String.to_charlist(archive), [{~c"member.txt", "inside"}])

      {:ok, _} =
        :zip.create(String.to_charlist(Path.join(ctx.outside, "bundle.zip")), [
          {~c"member.txt", "SECRET"}
        ])

      outside_bytes = File.read!(Path.join(ctx.outside, "bundle.zip"))

      {result, before} =
        race(ctx, "sub/bundle.zip", fn ->
          Write.execute(
            "write",
            %{"path" => "sub/bundle.zip:member.txt", "content" => "updated"},
            nil,
            nil,
            ctx.root,
            ctx.opts
          )
        end)

      assert %AgentToolResult{} = result
      assert_tree_unchanged(ctx, before)
      # Nothing may reopen the archive by name after the commit.
      refute_received {:path_request, _}
      committed = File.read!(swapped_or_original(archive))
      assert FileReadTracker.check(ctx.opts, archive, committed) == :ok
      assert FileReadTracker.check(ctx.opts, archive, outside_bytes) == {:error, :stale}
    end
  end

  # Swaps `root/sub` for a symlink to `outside` just before the first
  # file-server request for a path in this test's directory (workspace or
  # operator bin; other processes' requests are ignored) served after `rel`'s
  # content first differs from its content when the race started, i.e. right
  # after Lemon's write lands. Requests naming the target after that are
  # reported to the test.
  defp race(ctx, rel, fun) do
    test = self()
    target = Path.join(ctx.root, rel)
    original = read_prim(target)
    before = tree(ctx.outside)

    hook = fn request ->
      path = FileServerTap.path(request)

      cond do
        is_nil(path) or not String.starts_with?(path, ctx.tmp <> "/") ->
          :ok

        Process.get(:swapped) ->
          if path == target, do: send(test, {:path_request, request})

        (current = read_prim(target)) != nil and current != original ->
          FileServerTap.swap_for_symlink(ctx.sub, ctx.outside)
          Process.put(:swapped, true)
          send(test, {:swapped, request})

        true ->
          :ok
      end
    end

    {FileServerTap.with_tap(hook, fun), before}
  end

  defp read_prim(path) do
    case :prim_file.read_file(path) do
      {:ok, bytes} -> bytes
      _ -> nil
    end
  end

  defp swapped_or_original(path) do
    moved = Path.join(Path.dirname(path) <> ".moved", Path.basename(path))
    if File.exists?(moved), do: moved, else: path
  end

  defp assert_outside_untouched(ctx, before) do
    assert_received {:swapped, _}
    assert_tree_unchanged(ctx, before)
  end

  defp assert_tree_unchanged(ctx, before), do: assert(tree(ctx.outside) == before)

  defp tree(dir) do
    dir
    |> File.ls!()
    |> Map.new(&{&1, File.read!(Path.join(dir, &1))})
  end
end
