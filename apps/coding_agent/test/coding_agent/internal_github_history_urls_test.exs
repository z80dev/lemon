defmodule CodingAgent.InternalGitHubHistoryUrlsTest do
  use ExUnit.Case, async: false
  alias CodingAgent.{TaskStore, Tools.Read}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  @moduletag :tmp_dir

  defp read(path, cwd, opts), do: Read.execute("r", %{"path" => path}, nil, nil, cwd, opts)
  defp text(result), do: Enum.map_join(result.content, "\n", & &1.text)

  defp issue,
    do: %{
      "number" => 42,
      "title" => "Example",
      "body" => "Description",
      "state" => "open",
      "user" => %{"login" => "author"}
    }

  test "uses authenticated gh and resolves SSH origin without public HTTP", %{tmp_dir: cwd} do
    cmd = fn
      "git", ["remote", "get-url", "origin"], options ->
        assert options[:cd] == cwd
        {"git@github.com:owner/project.git\n", 0}

      "gh-test", ["api", "--hostname", "github.com", "repos/owner/project/issues/42"], _ ->
        {Jason.encode!(issue()), 0}

      "gh-test",
      ["api", "--hostname", "github.com", "repos/owner/project/issues/42/comments?per_page=100"],
      _ ->
        {Jason.encode!([%{"body" => "A comment", "user" => %{"login" => "reader"}}]), 0}
    end

    result =
      read("issue://42", cwd,
        github_gh: "gh-test",
        github_command_fn: cmd,
        github_http_fn: fn _ -> flunk("unexpected HTTP") end
      )

    assert result.trust == :untrusted
    assert text(result) =~ "Example (#42)"
    assert text(result) =~ "A comment"
  end

  test "falls back to public REST without handling CLI credentials", %{tmp_dir: cwd} do
    http = fn url ->
      assert String.starts_with?(url, "https://api.github.com/repos/a/b/issues/42")
      {:ok, if(String.contains?(url, "/comments"), do: [], else: issue())}
    end

    result =
      read("pr://a/b/42", cwd,
        github_gh: "gh-test",
        github_command_fn: fn _, _, _ -> {"not authenticated", 1} end,
        github_http_fn: http
      )

    assert text(result) =~ "Description"
  end

  test "lists zero-based diff files and renders single and all patches", %{tmp_dir: cwd} do
    files = [
      %{
        "filename" => "a.ex",
        "status" => "modified",
        "additions" => 1,
        "deletions" => 0,
        "patch" => "+hello"
      },
      %{"filename" => "b.bin", "status" => "added"}
    ]

    opts = [github_gh: nil, github_http_fn: fn _ -> {:ok, files} end]
    assert text(read("pr://a/b/42/diff", cwd, opts)) =~ "0: a.ex"
    assert text(read("pr://a/b/42/diff/0", cwd, opts)) =~ "+hello"
    assert text(read("pr://a/b/42/diff/all", cwd, opts)) =~ "No patch supplied"
    assert {:error, _} = read("pr://a/b/42/diff/2", cwd, opts)
    assert {:error, _} = read("issue://a/b/42/diff", cwd, opts)
    assert {:error, _} = read("pr://a/../42", cwd, opts)
  end

  test "bounds Unicode output without invalid UTF-8", %{tmp_dir: cwd} do
    opts = [
      github_gh: nil,
      github_http_fn: fn url ->
        {:ok,
         if(String.contains?(url, "/comments"),
           do: [],
           else: Map.put(issue(), "body", String.duplicate("中", 30_000))
         )}
      end
    ]

    body = text(read("issue://a/b/42", cwd, opts))
    assert String.valid?(body)
    assert byte_size(body) < 50_100
    assert body =~ "truncated"
  end

  test "paginates diff files with a finite page cap", %{tmp_dir: cwd} do
    caller = self()

    http = fn url ->
      send(caller, {:page, url})
      {:ok, List.duplicate(%{"filename" => "a", "status" => "added"}, 100)}
    end

    body = text(read("pr://a/b/42/diff", cwd, github_gh: nil, github_http_fn: http))
    assert body =~ "999: a"
    assert body =~ "capped at 1000"

    for page <- 1..10 do
      expected = "https://api.github.com/repos/a/b/pulls/42/files?per_page=100&page=#{page}"
      assert_receive {:page, ^expected}
    end

    refute_receive {:page, _}
  end

  test "history stays bounded and ignores opaque result details", %{tmp_dir: cwd} do
    opts = [session_id: "bounded-history"]

    id =
      TaskStore.new_task(%{
        owner: CodingAgent.Tools.Task.Control.owner(opts),
        description: "Long task"
      })

    TaskStore.append_event(id, %AgentToolResult{
      content: [%TextContent{text: String.duplicate("中", 20_000)}]
    })

    TaskStore.finish(id, %{thinking: "never expose this"})
    body = text(read("history://#{id}", cwd, opts))
    assert byte_size(body) < 49_000
    assert body =~ "History truncated"
    refute body =~ "never expose"
  end

  test "rejects missing and non-GitHub origins", %{tmp_dir: cwd} do
    for remote <- [{"", 1}, {"https://example.org/a/b.git", 0}] do
      assert {:error, _} = read("issue://42", cwd, github_command_fn: fn _, _, _ -> remote end)
    end
  end

  test "history exposes only owned visible updates and result", %{tmp_dir: cwd} do
    opts = [session_id: "history-owner"]

    id =
      TaskStore.new_task(%{
        owner: CodingAgent.Tools.Task.Control.owner(opts),
        description: "Child assignment"
      })

    TaskStore.append_event(id, %AgentToolResult{
      content: [%TextContent{text: "Visible update"}],
      details: %{reasoning: "hidden reasoning"}
    })

    TaskStore.finish(id, %AgentToolResult{
      content: [%TextContent{text: "Final answer"}],
      details: %{reasoning: "hidden final"}
    })

    result = read("history://#{id}", cwd, opts)
    assert result.trust == :untrusted
    assert text(result) =~ "Child assignment"
    assert text(result) =~ "Visible update"
    assert text(result) =~ "Final answer"
    refute text(result) =~ "hidden"
    assert {:error, _} = read("history://#{id}", cwd, session_id: "foreign")
    assert {:error, _} = read("history://#{id}", cwd, [])
  end
end
