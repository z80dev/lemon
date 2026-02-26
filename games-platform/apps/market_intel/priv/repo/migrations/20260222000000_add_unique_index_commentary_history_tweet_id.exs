defmodule MarketIntel.Repo.Migrations.AddUniqueIndexCommentaryHistoryTweetId do
  use Ecto.Migration

  def change do
    create unique_index(:commentary_history, [:tweet_id])
  end
end
