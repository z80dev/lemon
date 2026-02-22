defmodule MarketIntel.Commentary.CommentaryHistoryDbTest do
  @moduledoc """
  Database integration tests for commentary history persistence.

  Spins up a dedicated in-memory SQLite repo so the tests are fully
  self-contained and do not depend on the application Repo being connected
  to a real database file.
  """

  use ExUnit.Case, async: false

  alias MarketIntel.Schema.CommentaryHistory
  alias MarketIntel.Commentary.Pipeline

  # ---------------------------------------------------------------------------
  # Test-local Repo that points at an in-memory SQLite database.
  # We run the same migration that production uses, so the schema is identical.
  # ---------------------------------------------------------------------------

  setup_all do
    # Temporarily reconfigure MarketIntel.Repo to use :memory:
    original_config = Application.get_env(:market_intel, MarketIntel.Repo)

    Application.put_env(:market_intel, MarketIntel.Repo,
      database: ":memory:",
      pool_size: 1
    )

    # Stop the existing Repo if running (it may be stuck on a bad file path)
    case Process.whereis(MarketIntel.Repo) do
      nil -> :ok
      _pid -> Supervisor.terminate_child(MarketIntel.Supervisor, MarketIntel.Repo)
    end

    # Restart with in-memory config
    {:ok, _} = Supervisor.restart_child(MarketIntel.Supervisor, MarketIntel.Repo)

    # Run migrations
    Ecto.Migrator.run(MarketIntel.Repo, migrations_path(), :up, all: true)

    on_exit(fn ->
      # Restore original config
      if original_config do
        Application.put_env(:market_intel, MarketIntel.Repo, original_config)
      end
    end)

    :ok
  end

  setup do
    # Clean the table between tests
    MarketIntel.Repo.delete_all(CommentaryHistory)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "insert_commentary_history/1 with live Repo" do
    test "inserts a valid commentary record" do
      record = %{
        tweet_id: "tw_001",
        content: "market update: $ZEEBOT is up 12%",
        trigger_event: "price_spike",
        market_context: %{
          token: %{price_usd: 1.23},
          eth: %{price_usd: 3500.0}
        }
      }

      assert {:ok, %CommentaryHistory{} = inserted} =
               Pipeline.insert_commentary_history(record)

      assert inserted.tweet_id == "tw_001"
      assert inserted.content == "market update: $ZEEBOT is up 12%"
      assert inserted.trigger_event == "price_spike"
      assert inserted.id != nil
      assert %DateTime{} = inserted.inserted_at
      assert %DateTime{} = inserted.updated_at

      # Reload from DB and verify market_context round-trip (keys become strings)
      reloaded = MarketIntel.Repo.get!(CommentaryHistory, inserted.id)
      assert reloaded.market_context["token"]["price_usd"] == 1.23
      assert reloaded.market_context["eth"]["price_usd"] == 3500.0
    end

    test "upserts on duplicate tweet_id" do
      record = %{
        tweet_id: "tw_dup",
        content: "first version",
        trigger_event: "scheduled",
        market_context: %{}
      }

      assert {:ok, %CommentaryHistory{} = first} =
               Pipeline.insert_commentary_history(record)

      # Capture the original inserted_at from the database
      original = MarketIntel.Repo.get_by!(CommentaryHistory, tweet_id: "tw_dup")
      original_inserted_at = original.inserted_at

      updated_record = %{
        tweet_id: "tw_dup",
        content: "second version (updated)",
        trigger_event: "manual",
        market_context: %{updated: true}
      }

      assert {:ok, %CommentaryHistory{}} =
               Pipeline.insert_commentary_history(updated_record)

      # Reload from DB and verify the upsert worked
      reloaded = MarketIntel.Repo.get_by!(CommentaryHistory, tweet_id: "tw_dup")
      assert reloaded.content == "second version (updated)"
      assert reloaded.trigger_event == "manual"

      # inserted_at should be preserved from the first insert
      assert reloaded.inserted_at == original_inserted_at

      # Only one row in the table
      assert MarketIntel.Repo.aggregate(CommentaryHistory, :count) == 1
    end

    test "returns {:error, changeset} when required fields are missing" do
      record = %{tweet_id: "tw_bad"}

      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
               Pipeline.insert_commentary_history(record)

      error_fields = Keyword.keys(changeset.errors)
      assert :content in error_fields
      assert :trigger_event in error_fields
    end

    test "allows nil tweet_id" do
      record = %{
        content: "no tweet id yet",
        trigger_event: "scheduled",
        market_context: %{}
      }

      assert {:ok, %CommentaryHistory{tweet_id: nil}} =
               Pipeline.insert_commentary_history(record)
    end

    test "persists market_context as a map" do
      complex_context = %{
        timestamp: "2026-02-22T00:00:00Z",
        token: %{price_usd: 1.23, volume_24h: 50_000},
        eth: %{price_usd: 3500.0},
        polymarket: nil
      }

      record = %{
        tweet_id: "tw_ctx",
        content: "context test",
        trigger_event: "scheduled",
        market_context: complex_context
      }

      assert {:ok, inserted} = Pipeline.insert_commentary_history(record)

      # Reload from DB to confirm round-trip
      reloaded = MarketIntel.Repo.get!(CommentaryHistory, inserted.id)
      assert reloaded.market_context["timestamp"] == "2026-02-22T00:00:00Z"
      assert reloaded.market_context["token"]["price_usd"] == 1.23
    end

    test "handles multiple distinct records" do
      for i <- 1..5 do
        record = %{
          tweet_id: "tw_batch_#{i}",
          content: "batch tweet ##{i}",
          trigger_event: "scheduled",
          market_context: %{index: i}
        }

        assert {:ok, _} = Pipeline.insert_commentary_history(record)
      end

      assert MarketIntel.Repo.aggregate(CommentaryHistory, :count) == 5
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp migrations_path do
    Path.join([
      Application.app_dir(:market_intel),
      "priv",
      "repo",
      "migrations"
    ])
  end
end
