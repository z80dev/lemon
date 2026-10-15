defmodule CodingAgent.InternalLocalProcUrlsTest do
  use ExUnit.Case, async: false
  alias CodingAgent.{InternalUrls, Tools.Read, Tools.Write}
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    cwd =
      if match?({:unix, :darwin}, :os.type()),
        do: String.replace_prefix(directory, "/var/", "/private/var/"),
        else: directory

    %{tmp_dir: cwd}
  end

  test "local files round trip and remain session scoped", %{tmp_dir: cwd} do
    opts = [session_id: "local-a"]

    assert %LemonAgent.Types.AgentToolResult{} =
             Write.execute(
               "w",
               %{"path" => "local://plan.md", "content" => "shared plan"},
               nil,
               nil,
               cwd,
               opts
             )

    assert {:ok, path} = InternalUrls.resolve("local://plan.md", Keyword.put(opts, :cwd, cwd))
    assert File.read!(path) == "shared plan"

    assert %LemonAgent.Types.AgentToolResult{} =
             Read.execute("r", %{"path" => "local://plan.md"}, nil, nil, cwd, opts)

    assert {:ok, other} = InternalUrls.resolve("local://plan.md", cwd: cwd, session_id: "local-b")
    refute File.exists?(other)

    assert {:ok, command} =
             CodingAgent.Tools.Bash.InternalUrlExpansion.expand(
               "cat local://plan.md",
               Keyword.put(opts, :cwd, cwd)
             )

    assert command == "cat '#{path}'"
  end

  test "local URLs reject traversal, symlinks and missing session", %{tmp_dir: cwd} do
    for name <- ["", "..", "../escape", "%2e%2e", "foo/bar", "foo\\bar", "a?b"] do
      assert {:error, _} = InternalUrls.resolve("local://" <> name, cwd: cwd, session_id: "safe")
    end

    assert {:error, _} = InternalUrls.resolve("local://plan", cwd: cwd)
    assert {:ok, path} = InternalUrls.resolve("local://plan", cwd: cwd, session_id: "safe")
    File.ln_s!(cwd, path)
    assert {:error, _} = InternalUrls.resolve("local://plan", cwd: cwd, session_id: "safe")
  end

  test "process URLs list, peek, send stdin and terminate", %{tmp_dir: cwd} do
    import CodingAgent.AsyncHelpers
    alias CodingAgent.{ProcessManager, ProcessStore}
    opts = [session_id: "proc-owner"]
    assert {:ok, id} = ProcessManager.exec(command: "cat", cwd: cwd, owner: "proc-owner")
    on_exit(fn -> ProcessManager.kill(id, :sigkill) end)
    assert_eventually(fn -> match?({:ok, %{status: :running}, _}, ProcessStore.get(id)) end)
    listing = Read.execute("r", %{"path" => "proc://"}, nil, nil, cwd, opts)
    assert hd(listing.content).text =~ id
    foreign = Read.execute("r", %{"path" => "proc://"}, nil, nil, cwd, session_id: "foreign")
    refute hd(foreign.content).text =~ id

    assert {:error, _} =
             Read.execute("r", %{"path" => "proc://#{id}"}, nil, nil, cwd, session_id: "foreign")

    assert %LemonAgent.Types.AgentToolResult{} =
             Write.execute(
               "w",
               %{"path" => "proc://#{id}", "content" => "url-input\n"},
               nil,
               nil,
               cwd,
               opts
             )

    assert_eventually(fn ->
      result = Read.execute("r", %{"path" => "proc://#{id}"}, nil, nil, cwd, opts)
      Enum.any?(result.content, &(&1.text =~ "url-input"))
    end)

    assert {:ok, output} = ProcessManager.read_output(id)
    assert "url-input" in output.lines

    assert %LemonAgent.Types.AgentToolResult{} =
             Write.execute("w", %{"path" => "proc://#{id}/kill"}, nil, nil, cwd, opts)
  end

  test "process URLs require ownership", %{tmp_dir: cwd} do
    assert {:error, _} = Read.execute("r", %{"path" => "proc://"}, nil, nil, cwd, [])

    assert {:error, _} =
             Read.execute("r", %{"path" => "proc://unknown"}, nil, nil, cwd, session_id: "safe")

    assert {:error, _} =
             Write.execute("w", %{"path" => "proc://unknown/kill"}, nil, nil, cwd,
               session_id: "safe"
             )
  end
end
