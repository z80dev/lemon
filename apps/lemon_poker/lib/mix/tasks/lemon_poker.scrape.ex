defmodule Mix.Tasks.LemonPoker.Scrape do
  @shortdoc "Scrape poker forums for table talk and banter"
  @moduledoc """
  Scrapes poker forums and websites for authentic table talk content.

  ## Examples

      # Scrape all known sources
      mix lemon_poker.scrape

      # Scrape specific Reddit thread
      mix lemon_poker.scrape --reddit /r/poker/comments/97sg56/bestfunniest_table_talk

      # Scrape specific URL
      mix lemon_poker.scrape --url https://example.com/poker-quotes

      # Preview without saving
      mix lemon_poker.scrape --dry-run

      # Save to specific category
      mix lemon_poker.scrape --reddit /r/poker/comments/abc123 --category reactions
  """

  use Mix.Task

  alias LemonPoker.BanterScraper

  @switches [
    reddit: :string,
    url: :string,
    category: :string,
    dry_run: :boolean,
    limit: :integer,
    min_score: :integer
  ]

  @aliases [r: :reddit, u: :url, c: :category, d: :dry_run]

  @impl true
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    # Start required apps
    Application.ensure_all_started(:req)

    results =
      cond do
        opts[:reddit] ->
          scrape_reddit(opts)

        opts[:url] ->
          scrape_url(opts)

        true ->
          scrape_batch()
      end

    display_results(results, opts)
  end

  defp scrape_reddit(opts) do
    path = opts[:reddit]
    category = opts[:category] || "reactions"
    limit = opts[:limit] || 50
    min_score = opts[:min_score] || 5

    Mix.shell().info("Scraping Reddit: #{path}")

    case BanterScraper.scrape_reddit(path,
           category: category,
           limit: limit,
           min_score: min_score
         ) do
      {:ok, items} ->
        %{reddit: items}

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
        %{}
    end
  end

  defp scrape_url(opts) do
    url = opts[:url]
    category = opts[:category] || "reactions"

    Mix.shell().info("Scraping URL: #{url}")

    case BanterScraper.scrape_url(url, category: category) do
      {:ok, items} ->
        %{url => items}

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
        %{}
    end
  end

  defp scrape_batch do
    Mix.shell().info("Running batch scrape of known sources...")
    BanterScraper.scrape_batch()
  end

  defp display_results(results, opts) do
    total_items =
      results
      |> Map.values()
      |> List.flatten()
      |> length()

    Mix.shell().info("")
    Mix.shell().info("Found #{total_items} items total")

    # Categorize and display
    all_items =
      results
      |> Map.values()
      |> List.flatten()

    categorized = BanterScraper.categorize_items(all_items)

    for {category, items} <- categorized do
      Mix.shell().info("")
      Mix.shell().info("#{category}: #{length(items)} items")

      # Show first 3 examples
      items
      |> Enum.take(3)
      |> Enum.each(fn item ->
        Mix.shell().info("  - #{truncate(item.text, 80)}")
      end)
    end

    # Save unless dry-run
    unless opts[:dry_run] do
      Mix.shell().info("")
      Mix.shell().info("Saving to banter library...")

      for {category, items} <- categorized do
        case BanterScraper.save_to_banter(items, category) do
          :ok ->
            Mix.shell().info("  Saved #{length(items)} items to #{category}.txt")

          {:error, reason} ->
            Mix.shell().error("  Failed to save #{category}: #{inspect(reason)}")
        end
      end
    else
      Mix.shell().info("")
      Mix.shell().info("(Dry run - not saving)")
    end
  end

  defp truncate(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len) <> "..."
    else
      text
    end
  end
end
