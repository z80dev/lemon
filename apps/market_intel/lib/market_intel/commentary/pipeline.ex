defmodule MarketIntel.Commentary.Pipeline do
  @moduledoc """
  Generates market commentary tweets based on ingested data.

  Triggered by:
  - scheduled intervals (every 30 min)
  - significant price movements (> configured threshold)
  - high-engagement mentions
  - interesting Polymarket events
  - manual requests

  Uses GenStage for backpressure and batching.
  """

  use GenStage
  require Logger

  alias MarketIntel.Commentary.PromptBuilder

  @typedoc "Trigger type for commentary generation"
  @type trigger_type ::
          :scheduled
          | :price_spike
          | :price_drop
          | :mention_reply
          | :weird_market
          | :volume_surge
          | :manual

  @typedoc "Vibe/theme for commentary style"
  @type vibe :: :crypto_commentary | :gaming_joke | :agent_self_aware | :lemon_persona

  @typedoc "Market data snapshot"
  @type market_snapshot :: %{
          timestamp: DateTime.t(),
          token: {:ok, map()} | :error | :expired,
          eth: {:ok, map()} | :error | :expired,
          polymarket: {:ok, map()} | :error | :expired
        }

  @typedoc "Trigger context map"
  @type trigger_context :: %{
          optional(:immediate) => boolean(),
          optional(:change) => number(),
          optional(atom()) => any()
        }

  @typedoc "Commentary record for storage"
  @type commentary_record :: %{
          tweet_id: String.t(),
          content: String.t(),
          trigger_event: String.t(),
          market_context: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  # Commentary vibes/themes
  @vibes [
    :crypto_commentary,
    :gaming_joke,
    :agent_self_aware,
    :lemon_persona
  ]

  # Trigger types
  @triggers %{
    scheduled: "Regular market update",
    price_spike: "Significant price movement",
    price_drop: "Significant price drop",
    mention_reply: "High-engagement mention",
    weird_market: "Interesting Polymarket event",
    volume_surge: "Unusual trading volume",
    manual: "User requested"
  }

  # Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger commentary generation"
  @spec trigger(trigger_type(), trigger_context()) :: :ok
  def trigger(trigger_type, context \\ %{}) do
    GenStage.cast(__MODULE__, {:trigger, trigger_type, context})
  end

  @doc "Generate and post commentary immediately"
  @spec generate_now() :: :ok
  def generate_now do
    trigger(:manual, %{immediate: true})
  end

  # GenStage callbacks

  @impl true
  @spec init(keyword()) :: {:producer_consumer, map(), list()}
  def init(_opts) do
    # Buffer of pending commentary requests
    {:producer_consumer, %{pending: []}, subscribe_to: []}
  end

  @impl true
  @spec handle_cast({:trigger, trigger_type(), trigger_context()}, map()) ::
          {:noreply, list(), map()}
  def handle_cast({:trigger, trigger_type, context}, state) do
    # Add to pending queue
    new_pending = [
      %{type: trigger_type, context: context, timestamp: DateTime.utc_now()} | state.pending
    ]

    # Process if immediate
    if context[:immediate] do
      process_commentary(hd(new_pending))
      {:noreply, [], %{state | pending: tl(new_pending)}}
    else
      {:noreply, [], %{state | pending: new_pending}}
    end
  end

  @impl true
  @spec handle_events(list(), GenServer.from(), map()) :: {:noreply, list(), map()}
  def handle_events(events, _from, state) do
    # Process batched events
    Enum.each(events, &process_commentary/1)
    {:noreply, [], state}
  end

  # Private functions

  @spec process_commentary(%{type: trigger_type(), context: trigger_context()}) :: :ok
  defp process_commentary(%{type: trigger_type, context: context}) do
    Logger.info("[MarketIntel] Generating commentary for: #{@triggers[trigger_type]}")

    # Get current market snapshot
    snapshot = MarketIntel.Cache.get_snapshot()

    # Build prompt using the PromptBuilder module
    prompt = build_prompt(trigger_type, snapshot, context)

    # Generate tweet (integrates with AI module)
    {:ok, tweet_text} = generate_tweet(prompt)

    # Post to X
    post_commentary(tweet_text, trigger_type, snapshot)
  end

  @spec build_prompt(trigger_type(), market_snapshot(), trigger_context()) :: String.t()
  defp build_prompt(trigger_type, snapshot, context) do
    vibe = select_vibe()
    token_name = MarketIntel.Config.tracked_token_name()
    token_ticker = MarketIntel.Config.tracked_token_ticker()

    builder = %PromptBuilder{
      vibe: vibe,
      market_data: %{
        token: snapshot.token,
        eth: snapshot.eth,
        polymarket: snapshot.polymarket
      },
      token_name: token_name,
      token_ticker: token_ticker,
      trigger_type: trigger_type,
      trigger_context: context
    }

    PromptBuilder.build(builder)
  end

  @spec select_vibe() :: vibe()
  defp select_vibe do
    Enum.random(@vibes)
  end

  @spec generate_tweet(String.t()) :: {:ok, String.t()}
  defp generate_tweet(prompt) do
    case generate_with_ai(prompt) do
      {:ok, tweet} ->
        Logger.info("[MarketIntel] AI-generated tweet (#{String.length(tweet)} chars)")
        {:ok, tweet}

      {:error, reason} ->
        Logger.info("[MarketIntel] AI generation failed (#{inspect(reason)}), using fallback")
        {:ok, generate_fallback_tweet()}
    end
  end

  @spec generate_with_ai(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp generate_with_ai(prompt) do
    cond do
      MarketIntel.Secrets.configured?(:openai_key) ->
        generate_with_provider(:openai, "gpt-4o-mini", prompt)

      MarketIntel.Secrets.configured?(:anthropic_key) ->
        generate_with_provider(:anthropic, "claude-3-5-haiku-20241022", prompt)

      true ->
        Logger.info("[MarketIntel] No AI provider configured, using fallback tweets")
        {:error, :no_provider_configured}
    end
  end

  @doc false
  @spec generate_with_provider(atom(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_with_provider(provider, model_id, prompt) do
    case Ai.Models.get_model(provider, model_id) do
      nil ->
        Logger.warning("[MarketIntel] Model #{model_id} not found for provider #{provider}")
        {:error, {:model_not_found, provider, model_id}}

      model ->
        context =
          Ai.Types.Context.new(
            system_prompt: "You are a tweet author. Reply with ONLY the tweet text, nothing else."
          )
          |> Ai.Types.Context.add_user_message(prompt)

        case Ai.complete(model, context, %{max_tokens: 300, temperature: 0.9}) do
          {:ok, message} ->
            text =
              message
              |> Ai.get_text()
              |> String.trim()
              |> String.trim("\"")
              |> truncate_to_tweet_length()

            if text == "" do
              {:error, :empty_response}
            else
              {:ok, text}
            end

          {:error, reason} ->
            Logger.warning("[MarketIntel] AI completion failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  rescue
    e ->
      Logger.error("[MarketIntel] AI generation error: #{Exception.message(e)}")
      {:error, {:ai_exception, Exception.message(e)}}
  end

  @spec truncate_to_tweet_length(String.t()) :: String.t()
  defp truncate_to_tweet_length(text) when byte_size(text) <= 280, do: text

  defp truncate_to_tweet_length(text) do
    text
    |> String.slice(0, 277)
    |> Kernel.<>("...")
  end

  @spec generate_fallback_tweet() :: String.t()
  defp generate_fallback_tweet do
    token_ticker = MarketIntel.Config.tracked_token_ticker()
    developer_alias = MarketIntel.Config.commentary_developer_alias()

    templates =
      [
        "market update: #{token_ticker} is moving and I'm an AI agent running on BEAM 🍋",
        "just ingested some market data. my memory files are getting full 📊",
        "another day, another DEX scan. base fees still cheap thankfully",
        "polymarket has some wild markets today. humans keep things interesting",
        "my BEAM processes are humming. how's your containerized python agent doing? 😴"
      ]
      |> maybe_append_developer_template(developer_alias)

    Enum.random(templates)
  end

  @spec maybe_append_developer_template(list(String.t()), String.t() | nil) :: list(String.t())
  defp maybe_append_developer_template(templates, nil), do: templates
  defp maybe_append_developer_template(templates, ""), do: templates

  defp maybe_append_developer_template(templates, developer_alias) do
    templates ++
      [
        "runtime status: green. #{developer_alias} gave me another market loop and i survived 🍋"
      ]
  end

  @spec post_commentary(String.t(), trigger_type(), market_snapshot()) :: :ok
  defp post_commentary(text, trigger_type, snapshot) do
    # Post to X using LemonChannels
    case do_post_tweet(text) do
      {:ok, %{tweet_id: id}} ->
        Logger.info("[MarketIntel] Posted tweet #{id}: #{String.slice(text, 0, 50)}...")
        store_commentary(text, trigger_type, snapshot, id)

      {:error, reason} ->
        Logger.error("[MarketIntel] Failed to post: #{inspect(reason)}")
    end
  end

  @spec do_post_tweet(String.t()) :: {:ok, %{tweet_id: String.t()}} | {:error, any()}
  defp do_post_tweet(text) do
    # Use the existing X API client from lemon_channels when available
    client_module = Module.concat([LemonChannels, Adapters, XAPI, Client])

    if Code.ensure_loaded?(client_module) and function_exported?(client_module, :post_text, 1) do
      apply(client_module, :post_text, [text])
    else
      {:error, :x_api_client_unavailable}
    end
  rescue
    error ->
      {:error, "X API error: #{inspect(error)}"}
  end

  @spec store_commentary(String.t(), trigger_type(), market_snapshot(), String.t()) :: :ok
  defp store_commentary(text, trigger_type, snapshot, tweet_id) do
    record = %{
      tweet_id: tweet_id,
      content: text,
      trigger_event: Atom.to_string(trigger_type),
      market_context: snapshot_to_map(snapshot)
    }

    case insert_commentary_history(record) do
      {:ok, _inserted} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc """
  Inserts a commentary record into the commentary_history table.

  Uses `MarketIntel.Repo.insert/2` with upsert semantics: when a record with
  the same `tweet_id` already exists, all columns except `:id` and
  `:inserted_at` are replaced.

  Returns `{:ok, schema}` on success or `{:error, reason}` on failure.
  Degrades gracefully when the Repo process is unavailable.

  ## Example

      iex> record = %{
      ...>   tweet_id: "1234567890",
      ...>   content: "market update...",
      ...>   trigger_event: "scheduled",
      ...>   market_context: %{token: %{price_usd: 1.23}}
      ...> }
      iex> {:ok, %MarketIntel.Schema.CommentaryHistory{}} = insert_commentary_history(record)

  """
  @spec insert_commentary_history(commentary_record()) :: {:ok, Ecto.Schema.t()} | {:error, any()}
  def insert_commentary_history(record) do
    alias MarketIntel.Schema.CommentaryHistory

    changeset =
      CommentaryHistory.changeset(%CommentaryHistory{}, record)

    case repo_insert(changeset) do
      {:ok, inserted} ->
        Logger.info("[MarketIntel] Stored commentary history #{inserted.tweet_id}")
        {:ok, inserted}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error("[MarketIntel] Failed to store commentary: #{inspect(changeset.errors)}")

        {:error, changeset}

      {:error, reason} ->
        Logger.warning("[MarketIntel] Commentary history storage unavailable: #{inspect(reason)}")

        {:error, reason}
    end
  end

  # Attempt Repo.insert with upsert semantics. Falls back gracefully when the
  # Repo process is not running (e.g. lightweight test environments).
  @spec repo_insert(Ecto.Changeset.t()) :: {:ok, Ecto.Schema.t()} | {:error, any()}
  defp repo_insert(changeset) do
    MarketIntel.Repo.insert(changeset,
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :tweet_id
    )
  rescue
    e in [ArgumentError, DBConnection.ConnectionError] ->
      {:error, {:repo_unavailable, Exception.message(e)}}
  catch
    :exit, reason ->
      {:error, {:repo_unavailable, reason}}
  end

  @spec snapshot_to_map(market_snapshot()) :: map()
  defp snapshot_to_map(snapshot) do
    %{
      timestamp: DateTime.to_iso8601(snapshot.timestamp),
      token: format_maybe(snapshot.token),
      eth: format_maybe(snapshot.eth),
      polymarket: format_maybe(snapshot.polymarket)
    }
  end

  @spec format_maybe({:ok, any()} | any()) :: any() | nil
  defp format_maybe({:ok, data}), do: data
  defp format_maybe(_), do: nil
end
