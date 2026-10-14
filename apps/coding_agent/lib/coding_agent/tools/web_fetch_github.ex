defmodule CodingAgent.Tools.WebFetchGitHub do
  @moduledoc """
  GitHub URL handling for `webfetch`.

  * `github.com/<owner>/<repo>/blob/<ref>/<path>` fetches the file's raw bytes
    from `raw.githubusercontent.com` instead of the HTML page chrome.
  * `github.com/<owner>/<repo>/(issues|pull)/<n>` renders the issue or pull
    request and its first page of comments from the public REST API as Markdown.

  Requests go through the caller's guarded fetch; no credentials are attached.
  """

  @api "https://api.github.com"
  @max_comments 100

  @type route :: {:raw, String.t()} | {:issue, String.t(), String.t(), pos_integer()} | :none

  @doc "Classifies a URL as a GitHub raw-file rewrite, an issue/PR, or neither."
  @spec route(String.t()) :: route()
  def route(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and host in ["github.com", "www.github.com"] and
             is_binary(path) ->
        path |> String.split("/", trim: true) |> classify()

      _ ->
        :none
    end
  end

  defp classify([owner, repo, "blob", ref | [_ | _] = file]) do
    {:raw, Enum.join(["https://raw.githubusercontent.com", owner, repo, ref | file], "/")}
  end

  defp classify([owner, repo, kind, number | _]) when kind in ["issues", "pull"] do
    case Integer.parse(number) do
      {n, ""} when n > 0 -> {:issue, owner, repo, n}
      _ -> :none
    end
  end

  defp classify(_segments), do: :none

  @doc "REST API URLs for an issue/PR and its first page of comments."
  @spec issue_api_urls(String.t(), String.t(), pos_integer()) :: {String.t(), String.t()}
  def issue_api_urls(owner, repo, number) do
    base = "#{@api}/repos/#{URI.encode(owner)}/#{URI.encode(repo)}/issues/#{number}"
    {base, base <> "/comments?per_page=#{@max_comments}"}
  end

  @doc "Renders decoded issue and comment JSON as Markdown, returning `{title, markdown}`."
  @spec render_issue(map(), list()) :: {String.t(), String.t()}
  def render_issue(issue, comments) when is_map(issue) and is_list(comments) do
    number = issue["number"]
    kind = if is_map(issue["pull_request"]), do: "Pull request", else: "Issue"
    title = "#{issue["title"]} (##{number})"

    meta =
      [
        "#{kind} · #{pr_state(issue)}",
        user(issue["user"]) && "Author: @#{user(issue["user"])}",
        issue["created_at"] && "Opened: #{issue["created_at"]}",
        labels(issue["labels"]),
        issue["html_url"]
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    body = blank_to(issue["body"], "_No description._")
    total = issue["comments"]

    comment_section =
      case comments do
        [] ->
          ""

        _ ->
          shown = length(comments)

          heading =
            if is_integer(total) and total > shown,
              do: "## Comments (#{shown} of #{total})",
              else: "## Comments (#{shown})"

          "\n\n" <>
            heading <>
            "\n\n" <>
            Enum.map_join(comments, "\n\n", fn comment ->
              "### @#{user(comment["user"]) || "unknown"} · #{comment["created_at"]}\n\n" <>
                blank_to(comment["body"], "_Empty comment._")
            end)
      end

    {title, "# #{title}\n\n#{meta}\n\n#{body}#{comment_section}"}
  end

  defp pr_state(%{"pull_request" => %{"merged_at" => merged}}) when is_binary(merged),
    do: "merged"

  defp pr_state(issue), do: to_string(issue["state"] || "unknown")

  defp user(%{"login" => login}) when is_binary(login), do: login
  defp user(_), do: nil

  defp labels(labels) when is_list(labels) and labels != [] do
    names = labels |> Enum.map(&(is_map(&1) && &1["name"])) |> Enum.filter(&is_binary/1)
    if names == [], do: nil, else: "Labels: " <> Enum.join(names, ", ")
  end

  defp labels(_), do: nil

  defp blank_to(value, fallback) when is_binary(value) do
    if String.trim(value) == "", do: fallback, else: String.trim(value)
  end

  defp blank_to(_value, fallback), do: fallback
end
