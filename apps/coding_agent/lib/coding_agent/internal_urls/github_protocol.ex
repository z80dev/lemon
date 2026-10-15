defmodule CodingAgent.InternalUrls.GitHubProtocol do
  @moduledoc "Bounded GitHub issue and pull-request views, preferring the authenticated gh CLI."
  alias CodingAgent.Tools.WebFetchGitHub
  alias LemonAgent.Security.ToolResultTrust
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @max_bytes 50_000
  @max_pages 10

  def read(uri, cwd, opts) do
    with {:ok, kind, owner, repo, number, view} <- parse(uri, cwd, opts),
         {:ok, text} <- render(kind, owner, repo, number, view, cwd, opts) do
      %AgentToolResult{content: [%TextContent{text: bounded(text)}], details: %{url: uri}}
      |> ToolResultTrust.untrusted(:api)
    end
  end

  defp parse(uri, cwd, opts) do
    [kind, reference] = String.split(uri, "://", parts: 2)
    segments = String.split(reference, "/")

    with {:ok, owner, repo, number, rest} <- reference(segments, cwd, opts),
         true <- valid_repo_part?(owner) and valid_repo_part?(repo),
         {number, ""} when number > 0 <- Integer.parse(number),
         {:ok, view} <- view(kind, rest) do
      {:ok, kind, owner, repo, number, view}
    else
      {:error, _} = error -> error
      _ -> {:error, "Malformed GitHub internal URL"}
    end
  end

  defp reference([number | rest] = segments, cwd, opts) do
    if Regex.match?(~r/\A[0-9]+\z/, number) do
      with {:ok, owner, repo} <- origin(cwd, opts), do: {:ok, owner, repo, number, rest}
    else
      case segments do
        [owner, repo, number | rest] -> {:ok, owner, repo, number, rest}
        _ -> {:error, "Expected issue://<N> or issue://<owner>/<repo>/<N>"}
      end
    end
  end

  defp view(_kind, []), do: {:ok, :issue}
  defp view("pr", ["diff"]), do: {:ok, :files}
  defp view("pr", ["diff", "all"]), do: {:ok, :all}

  defp view("pr", ["diff", index]) do
    case Integer.parse(index) do
      {n, ""} when n >= 0 -> {:ok, {:file, n}}
      _ -> {:error, "Diff file index must be a nonnegative integer"}
    end
  end

  defp view(_, _), do: {:error, "Malformed GitHub internal URL"}

  defp origin(cwd, opts) do
    case command("git", ["remote", "get-url", "origin"], cwd, opts) do
      {remote, 0} ->
        case Regex.run(
               ~r/\A(?:https?:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)([^\/\s]+)\/([^\/\s]+)\z/,
               String.trim(remote), capture: :all_but_first) do
          [owner, repo] ->
            {:ok, owner, String.replace_suffix(repo, ".git", "")}

          _ ->
            {:error,
             "The cwd origin remote is not a GitHub repository; use an explicit owner/repo URL"}
        end

      _ ->
        {:error, "Cannot resolve the cwd origin remote; use an explicit owner/repo URL"}
    end
  end

  defp valid_repo_part?(part),
    do: Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, part) and part not in [".", ".."]

  defp render(_kind, owner, repo, number, :issue, cwd, opts) do
    {issue_url, comments_url} = WebFetchGitHub.issue_api_urls(owner, repo, number)

    with {:ok, issue} when is_map(issue) <- api(issue_url, cwd, opts),
         {:ok, comments} when is_list(comments) <- api(comments_url, cwd, opts) do
      {_title, markdown} = WebFetchGitHub.render_issue(issue, comments)
      {:ok, markdown}
    else
      {:error, _} = error -> error
      _ -> {:error, "Unexpected GitHub issue response"}
    end
  end

  defp render("pr", owner, repo, number, view, cwd, opts) do
    endpoint = "https://api.github.com/repos/#{owner}/#{repo}/pulls/#{number}/files"

    with {:ok, files, capped?} <- files(endpoint, 1, [], cwd, opts) do
      note = if capped?, do: "\n[File list capped at 1000 files.]", else: ""

      case view do
        :files ->
          {:ok,
           Enum.map_join(Enum.with_index(files), "\n", fn {file, i} ->
             "#{i}: #{file["filename"]} (#{file["status"]}, +#{file["additions"]}/-#{file["deletions"]})"
           end) <> note}

        :all ->
          {:ok, Enum.map_join(files, "\n\n", &patch/1) <> note}

        {:file, index} ->
          case Enum.at(files, index) do
            nil -> {:error, "Diff file index is out of range"}
            file -> {:ok, patch(file)}
          end
      end
    end
  end

  defp patch(file),
    do:
      "## #{file["filename"]}\n\n" <>
        (file["patch"] || "[No patch supplied by GitHub: binary, large, or unchanged file.]")

  defp files(endpoint, page, acc, cwd, opts) do
    with {:ok, batch} when is_list(batch) <-
           api("#{endpoint}?per_page=100&page=#{page}", cwd, opts) do
      acc = acc ++ Enum.take(batch, 100)

      cond do
        length(batch) < 100 -> {:ok, acc, false}
        page == @max_pages -> {:ok, acc, true}
        true -> files(endpoint, page + 1, acc, cwd, opts)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Unexpected GitHub file response"}
    end
  end

  defp api(url, cwd, opts) do
    gh = Keyword.get(opts, :github_gh, System.find_executable("gh"))

    response =
      if is_binary(gh),
        do:
          command(
            gh,
            [
              "api",
              "--hostname",
              "github.com",
              String.replace_prefix(url, "https://api.github.com/", "")
            ],
            cwd,
            opts
          ),
        else: {"", 1}

    case response do
      {body, 0} ->
        decode(body)

      _ ->
        fetch = Keyword.get(opts, :github_http_fn, &http/1)

        case fetch.(url) do
          {:ok, body} when is_binary(body) -> decode(body)
          {:ok, body} when is_map(body) or is_list(body) -> {:ok, body}
          _ -> {:error, "GitHub request failed; authenticate gh for private repositories"}
        end
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, value} -> {:ok, value}
      _ -> {:error, "Invalid GitHub JSON response"}
    end
  end

  defp http(url) do
    case Req.get(url,
           headers: [{"accept", "application/vnd.github+json"}],
           redirect: false,
           retry: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      _ -> {:error, :request_failed}
    end
  end

  defp command(executable, args, cwd, opts) do
    run = Keyword.get(opts, :github_command_fn, &System.cmd/3)
    run.(executable, args, cd: cwd, stderr_to_stdout: true)
  rescue
    _ -> {"", 1}
  end

  defp bounded(text) when byte_size(text) <= @max_bytes, do: text

  defp bounded(text) do
    prefix = valid_prefix(binary_part(text, 0, @max_bytes))
    prefix <> "\n[Output truncated at 50 KB.]"
  end

  defp valid_prefix(text) do
    if String.valid?(text),
      do: text,
      else: valid_prefix(binary_part(text, 0, byte_size(text) - 1))
  end
end
