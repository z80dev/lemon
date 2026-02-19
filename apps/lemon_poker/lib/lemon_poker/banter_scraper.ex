defmodule LemonPoker.BanterScraper do
  @moduledoc """
  Scraper for poker forums and content sources to extract table talk,
  banter, and authentic poker quotes for the persona system.

  Supports:
  - Reddit (r/poker, r/pokerstories)
  - TwoPlusTwo forums
  - Direct URL fetching with content extraction
  """

  require Logger

  @type source :: :reddit | :twoplustwo | :generic
  @type scraped_item :: %{
          text: String.t(),
          source: String.t(),
          context: String.t() | nil,
          category: String.t() | nil,
          author: String.t() | nil,
          score: integer() | nil
        }

  @reddit_base "https://www.reddit.com"
  @twoplustwo_base "https://forumserver.twoplustwo.com"

  @doc """
  Scrape a Reddit thread for table talk content.

  ## Options
    - `:limit` - Max comments to process (default: 50)
    - `:min_score` - Minimum upvote score to include (default: 5)
    - `:category` - Category to assign to extracted items
  """
  @spec scrape_reddit(String.t(), keyword()) :: {:ok, [scraped_item()]} | {:error, term()}
  def scrape_reddit(thread_path, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    min_score = Keyword.get(opts, :min_score, 5)
    category = Keyword.get(opts, :category)

    url = "#{@reddit_base}#{thread_path}.json?limit=#{limit}"

    case fetch_json(url) do
      {:ok, data} ->
        items = extract_reddit_comments(data, min_score, category)
        {:ok, items}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Scrape a TwoPlusTwo forum thread.

  ## Options
    - `:pages` - Number of pages to fetch (default: 1)
    - `:category` - Category to assign to extracted items
  """
  @spec scrape_twoplustwo(String.t(), keyword()) :: {:ok, [scraped_item()]} | {:error, term()}
  def scrape_twoplustwo(thread_path, opts \\ []) do
    pages = Keyword.get(opts, :pages, 1)
    category = Keyword.get(opts, :category)

    items =
      1..pages
      |> Enum.flat_map(fn page_num ->
        url = "#{@twoplustwo_base}#{thread_path}/#{page_num}"

        case fetch_html(url) do
          {:ok, html} -> extract_twoplustwo_posts(html, category)
          {:error, _} -> []
        end
      end)

    {:ok, items}
  end

  @doc """
  Scrape any URL for poker-related quotes and banter.
  Uses heuristics to identify table talk content.

  ## Options
    - `:category` - Category to assign to extracted items
  """
  @spec scrape_url(String.t(), keyword()) :: {:ok, [scraped_item()]} | {:error, term()}
  def scrape_url(url, opts \\ []) do
    category = Keyword.get(opts, :category)

    case fetch_html(url) do
      {:ok, html} ->
        items = extract_generic_content(html, url, category)
        {:ok, items}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Filter and categorize scraped items based on content analysis.
  """
  @spec categorize_items([scraped_item()]) :: %{String.t() => [scraped_item()]}
  def categorize_items(items) do
    items
    |> Enum.reduce(%{}, fn item, acc ->
      detected = detect_category(item.text)
      category = item.category || detected

      Map.update(acc, category, [item], fn existing -> [item | existing] end)
    end)
    |> Enum.map(fn {k, v} -> {k, Enum.reverse(v)} end)
    |> Enum.into(%{})
  end

  @doc """
  Clean and normalize extracted text for use in prompts.
  """
  @spec clean_text(String.t()) :: String.t()
  def clean_text(text) when is_binary(text) do
    text
    |> String.replace(~r/\[\d+\]/, "")
    |> String.replace(~r/https?:\/\/\S+/, "")
    |> String.replace(~r/\*\*|\*|__|_|~~|`/," ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(200)
  end

  def clean_text(_), do: ""

  @doc """
  Save scraped items to the banter library.
  """
  @spec save_to_banter([scraped_item()], String.t()) :: :ok | {:error, term()}
  def save_to_banter(items, category) do
    banter_dir = Path.join(:code.priv_dir(:lemon_poker), "banter")
    file_path = Path.join(banter_dir, "#{category}.txt")

    lines =
      items
      |> Enum.map(& &1.text)
      |> Enum.map(&clean_text/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    existing =
      if File.exists?(file_path) do
        case File.read(file_path) do
          {:ok, content} -> String.split(content, "\n")
          _ -> []
        end
      else
        []
      end

    combined =
      (existing ++ lines)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    content = Enum.join(combined, "\n") <> "\n"

    case File.write(file_path, content) do
      :ok ->
        Logger.info("Saved #{length(lines)} new items to #{category}.txt")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Batch scrape multiple known good sources for poker banter.
  """
  @spec scrape_batch() :: %{atom() => [scraped_item()]}
  def scrape_batch do
    sources = [
      # Reddit r/poker - Best/funniest table talk
      {:reddit, "/r/poker/comments/97sg56/bestfunniest_table_talk",
       [category: "reactions", limit: 100, min_score: 10]},

      # Reddit r/poker - Favorite quotes
      {:reddit, "/r/poker/comments/14u8whv/whats_your_favorite_poker_quote",
       [category: "reactions", limit: 100, min_score: 5]},

      # Reddit r/poker - Things you hear at a table
      {:reddit, "/r/poker/comments/vug1o4/things_you_hear_at_a_poker_table",
       [category: "reactions", limit: 100, min_score: 5]},

      # Reddit r/poker - Speech play
      {:reddit, "/r/poker/comments/1mhhbuy/live_game_speech_play",
       [category: "reactions", limit: 50, min_score: 3]},

      # Reddit r/poker - Weird/funny stories
      {:reddit, "/r/poker/comments/20u2lg/weirdfunny_poker_stories_ill_share_mine",
       [category: "stories", limit: 100, min_score: 10]},

      # PokerTube article
      {:url, "https://www.pokertube.com/article/best-phrases-one-liners-heard-round-the-poker-table",
       [category: "reactions"]}
    ]

    sources
    |> Enum.map(fn {type, path_or_url, opts} ->
      result =
        case type do
          :reddit -> scrape_reddit(path_or_url, opts)
          :url -> scrape_url(path_or_url, opts)
          :twoplustwo -> scrape_twoplustwo(path_or_url, opts)
        end

      case result do
        {:ok, items} -> {path_or_url, items}
        {:error, reason} ->
          Logger.warning("Failed to scrape #{path_or_url}: #{inspect(reason)}")
          {path_or_url, []}
      end
    end)
    |> Enum.into(%{})
  end

  # Private functions

  defp fetch_json(url) do
    headers = [
      {"User-Agent", "Mozilla/5.0 (compatible; PokerBanterBot/1.0)"},
      {"Accept", "application/json"}
    ]

    case Req.get(url, headers: headers, max_redirects: 3) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_html(url) do
    headers = [
      {"User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"}
    ]

    case Req.get(url, headers: headers, max_redirects: 3) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_reddit_comments(data, min_score, category) when is_list(data) do
    # Reddit JSON structure: [post_data, comments_data]
    comments_data = List.last(data)

    comments_data
    |> get_in(["data", "children"])
    |> List.wrap()
    |> Enum.flat_map(&extract_comment_recursive(&1, min_score, category))
  end

  defp extract_reddit_comments(_, _, _), do: []

  defp extract_comment_recursive(comment, min_score, category) do
    data = get_in(comment, ["data"]) || %{}
    body = data["body"] || ""
    score = data["score"] || 0
    author = data["author"]

    items =
      if score >= min_score and body != "" and body != "[deleted]" do
        text = clean_text(body)

        if is_banter_worthy?(text) do
          [%{
            text: text,
            source: "reddit",
            context: nil,
            category: category,
            author: author,
            score: score
          }]
        else
          []
        end
      else
        []
      end

    # Recurse into replies
    replies = get_in(data, ["replies", "data", "children"]) || []
    child_items = Enum.flat_map(replies, &extract_comment_recursive(&1, min_score, category))

    items ++ child_items
  end

  defp extract_twoplustwo_posts(html, category) do
    # TwoPlusTwo uses vBulletin-style HTML
    # Posts are typically in divs with class "post_message" or similar
    # This is a simplified extraction - may need adjustment for actual HTML structure

    html
    |> Floki.parse_document!()
    |> Floki.find(".post_message, .postcontent, .post")
    |> Enum.map(fn post ->
      text =
        post
        |> Floki.text()
        |> clean_text()

      if is_banter_worthy?(text) do
        %{
          text: text,
          source: "twoplustwo",
          context: nil,
          category: category,
          author: nil,
          score: nil
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_generic_content(html, url, category) do
    # Extract paragraphs and look for quote-like content
    # Try multiple selectors to catch different forum/article structures
    doc = Floki.parse_document!(html)

    # Try different content selectors in order of preference
    selectors = [
      # Forum quote blocks
      "blockquote.messageText, .bbCodeBlock, .quoteContainer",
      # Article content
      "article p, .article-content p, .entry-content p",
      # Generic content areas
      "p, blockquote, .quote, .content"
    ]

    # Try each selector set and use the first one that yields results
    items =
      Enum.reduce_while(selectors, [], fn selector, _acc ->
        found =
          doc
          |> Floki.find(selector)
          |> Enum.map(fn el ->
            text =
              el
              |> Floki.text()
              |> clean_forum_text()

            if is_banter_worthy?(text) do
              %{
                text: text,
                source: url,
                context: nil,
                category: category,
                author: nil,
                score: nil
              }
            else
              nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        if length(found) > 0, do: {:halt, found}, else: {:cont, []}
      end)

    # Deduplicate and return
    items
    |> Enum.uniq_by(& &1.text)
  end

  defp clean_forum_text(text) when is_binary(text) do
    text
    # Remove "Click to expand..." and similar UI text
    |> String.replace(~r/Click to expand\.\.\./i, "")
    |> String.replace(~r/\b\w+ said:"/i, "\"")
    # Remove usernames at start of quotes
    |> String.replace(~r/^\w+ said:\s*/i, "")
    # Clean up markdown and formatting
    |> clean_text()
  end

  defp clean_forum_text(_), do: ""

  defp is_banter_worthy?(text) when is_binary(text) do
    # Heuristics to identify good table talk content
    length = String.length(text)

    # Must be reasonable length (not too short, not too long)
    length >= 15 and length <= 200 and
      # Should contain conversational elements
      (String.contains?(text, "\"") or
         String.contains?(text, "said") or
         String.contains?(text, "table") or
         String.contains?(text, "dealer") or
         String.contains?(text, "player")) and
      # Avoid common low-quality patterns
      not String.contains?(text, "[removed]") and
      not String.contains?(text, "[deleted]") and
      not String.starts_with?(text, "Edit:") and
      not String.starts_with?(text, "http")
  end

  defp is_banter_worthy?(_), do: false

  defp detect_category(text) when is_binary(text) do
    lowered = String.downcase(text)

    cond do
      # Greetings
      Regex.match?(~r/\b(hi|hello|hey|evening|morning|good luck|gl)\b/i, lowered) and
          String.length(text) < 50 ->
        "greetings"

      # Bad beats
      Regex.match?(~r/\b(bad beat|variance|cooler|sick|brutal|rough|tough)\b/i, lowered) ->
        "bad_beats"

      # Big pots/all-in
      Regex.match?(~r/\b(all.in|ship it|gamble|pot|stack|all the chips)\b/i, lowered) ->
        "big_pots"

      # Leaving/cashing out
      Regex.match?(~r/\b(cashing? out|leaving|good game|gg|done|last hand)\b/i, lowered) ->
        "leaving"

      # Idle chat
      Regex.match?(~r/\b(weather|weekend|game|sports|buffet|hotel|vegas)\b/i, lowered) ->
        "idle_chat"

      # Default to reactions
      true ->
        "reactions"
    end
  end

  defp detect_category(_), do: "reactions"

  defp truncate(text, max_len) when is_binary(text) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len) <> "..."
    else
      text
    end
  end

  defp truncate(_, _), do: ""
end
