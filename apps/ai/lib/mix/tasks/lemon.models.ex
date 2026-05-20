defmodule Mix.Tasks.Lemon.Models do
  @moduledoc """
  List known Lemon AI models.

  ## Usage

      mix lemon.models
      mix lemon.models --provider anthropic
      mix lemon.models --vision
      mix lemon.models --thinking
      mix lemon.models --json

  ## Options

    * `--provider` - Filter by provider id.
    * `--vision` - Show only image-capable models.
    * `--thinking` - Show only reasoning/thinking-capable models.
    * `--limit` - Limit returned rows.
    * `--json` - Emit JSON with models and summary.
  """

  use Mix.Task

  alias Ai.Models

  @shortdoc "List known Lemon AI models"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        switches: [
          provider: :string,
          vision: :boolean,
          thinking: :boolean,
          limit: :integer,
          json: :boolean,
          help: :boolean
        ],
        aliases: [
          p: :provider,
          l: :limit,
          h: :help
        ]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      rest != [] or invalid != [] ->
        Mix.raise("Invalid arguments. Run `mix lemon.models --help`.")

      true ->
        opts
        |> list_models()
        |> render(opts)
    end
  end

  defp list_models(opts) do
    Models.list_models(discover_openai: false)
    |> Enum.map(&format_model/1)
    |> filter_provider(opts[:provider])
    |> filter_capabilities(opts)
    |> Enum.sort_by(&{&1.provider, &1.id})
    |> limit_rows(opts[:limit])
  end

  defp format_model(model) do
    %{
      id: model.id,
      provider: to_string(model.provider),
      name: model.name || model.id,
      context_window: model.context_window,
      max_output: model.max_tokens,
      supports_thinking: model.reasoning == true,
      supports_vision: :image in model.input,
      supports_streaming: true
    }
  end

  defp filter_provider(models, nil), do: models

  defp filter_provider(models, provider) do
    provider = String.trim(provider)
    Enum.filter(models, &(&1.provider == provider))
  end

  defp filter_capabilities(models, opts) do
    models
    |> maybe_filter(opts[:vision], & &1.supports_vision)
    |> maybe_filter(opts[:thinking], & &1.supports_thinking)
  end

  defp maybe_filter(models, true, fun), do: Enum.filter(models, fun)
  defp maybe_filter(models, _flag, _fun), do: models

  defp limit_rows(models, limit) when is_integer(limit) and limit >= 0,
    do: Enum.take(models, limit)

  defp limit_rows(models, nil), do: models
  defp limit_rows(_models, _limit), do: Mix.raise("--limit must be a non-negative integer")

  defp render(models, opts) do
    summary = summarize(models)

    if opts[:json] do
      Mix.shell().info(Jason.encode!(%{models: models, summary: summary}))
    else
      render_text(models, summary)
    end
  end

  defp summarize(models) do
    providers =
      models
      |> Enum.map(& &1.provider)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      source: "ai_models",
      total: length(models),
      provider_count: length(providers),
      providers: providers,
      vision_model_count: Enum.count(models, & &1.supports_vision),
      thinking_model_count: Enum.count(models, & &1.supports_thinking),
      includes_credentials: false,
      includes_secret_values: false
    }
  end

  defp render_text([], summary) do
    Mix.shell().info("No models matched.")
    Mix.shell().info("Providers: #{summary.provider_count}")
    Mix.shell().info("Includes credentials: false")
    Mix.shell().info("Includes secret values: false")
  end

  defp render_text(models, summary) do
    Mix.shell().info("Lemon Models")
    Mix.shell().info("Source: #{summary.source}")
    Mix.shell().info("Total: #{summary.total}")
    Mix.shell().info("Providers: #{Enum.join(summary.providers, ", ")}")
    Mix.shell().info("Vision models: #{summary.vision_model_count}")
    Mix.shell().info("Thinking models: #{summary.thinking_model_count}")
    Mix.shell().info("Includes credentials: false")
    Mix.shell().info("Includes secret values: false")
    Mix.shell().info("")

    Enum.each(models, fn model ->
      caps =
        [
          if(model.supports_vision, do: "vision"),
          if(model.supports_thinking, do: "thinking"),
          if(model.supports_streaming, do: "streaming")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")

      Mix.shell().info("#{model.provider}:#{model.id}")
      Mix.shell().info("  name: #{model.name}")
      Mix.shell().info("  context_window: #{model.context_window}")
      Mix.shell().info("  max_output: #{model.max_output}")
      Mix.shell().info("  capabilities: #{caps}")
      Mix.shell().info("")
    end)
  end
end
