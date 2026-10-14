defmodule LemonAi.Models.CLI do
  @moduledoc """
  List known Lemon AI models.

  ## Usage

      lemon models
      lemon models --provider anthropic
      lemon models --vision
      lemon models --thinking
      lemon models --json
      lemon models --provider ollama --discover
      lemon models --provider lm-studio --discover --base-url http://gpu-box:1234/v1

  ## Options

    * `--provider` - Filter by provider id.
    * `--vision` - Show only image-capable models.
    * `--thinking` - Show only reasoning/thinking-capable models.
    * `--limit` - Limit returned rows.
    * `--json` - Emit JSON with models and summary.
    * `--discover` - Query the endpoint of an OpenAI-compatible preset provider
      (`ollama`, `lm_studio`, `llama_cpp`, `vllm`, `litellm`, `together`, ...)
      for the models it serves. Requires `--provider`.
    * `--base-url` - Endpoint for `--discover`. Defaults to the preset's
      base-URL environment variable (for example `OLLAMA_HOST`) or its local
      default. The preset's API-key environment variable is sent when set.
  """

  alias LemonAi.Models
  alias LemonAi.Models.Presets

  defmodule Error do
    @moduledoc false
    defexception [:message, exit_code: 2]
  end

  @discovery_timeout_ms 5_000

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        switches: [
          provider: :string,
          vision: :boolean,
          thinking: :boolean,
          limit: :integer,
          json: :boolean,
          discover: :boolean,
          base_url: :string,
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
        IO.puts(@moduledoc)

      rest != [] or invalid != [] ->
        raise(Error, message: "Invalid arguments. Run `lemon models --help`.")

      opts[:base_url] && !opts[:discover] ->
        raise(Error, message: "--base-url requires --discover.")

      true ->
        {models, source} = list_models(opts)

        models
        |> Enum.map(&format_model/1)
        |> filter_provider(opts[:provider])
        |> filter_capabilities(opts)
        |> Enum.sort_by(&{&1.provider, &1.id})
        |> limit_rows(opts[:limit])
        |> render(source, opts)
    end
  end

  defp list_models(opts) do
    if opts[:discover] do
      {discover(opts[:provider], opts[:base_url]), "discovery"}
    else
      {Models.list_models(discover_openai: false), "ai_models"}
    end
  end

  defp discover(nil, _base_url),
    do: raise(Error, message: "--discover requires --provider. #{preset_hint()}")

  defp discover(provider_name, base_url) do
    preset =
      Presets.resolve(provider_name) ||
        raise(Error, message: "--discover supports preset providers only. #{preset_hint()}")

    base_url = base_url || Presets.base_url(preset)
    # The source mix task only loads paths; discovery needs the HTTP client.
    {:ok, _} = Application.ensure_all_started(:req)

    case Models.discover_preset(preset,
           base_url: base_url,
           api_key: Presets.env_api_key(preset),
           timeout_ms: @discovery_timeout_ms,
           force_refresh: true
         ) do
      {:ok, models} ->
        models

      {:error, reason} ->
        raise Error,
          message:
            "Model discovery for #{preset} at #{base_url} failed: #{format_reason(reason)}",
          exit_code: 1
    end
  end

  defp preset_hint do
    "Presets: " <> Enum.map_join(Presets.ids(), ", ", &Atom.to_string/1) <> "."
  end

  defp format_reason({:authentication_rejected, status}),
    do:
      "authentication rejected (HTTP #{status}); set the provider's API key environment variable"

  defp format_reason({:http_error, status}), do: "HTTP #{status}"
  defp format_reason(:transport_failure), do: "connection failed; is the server running?"
  defp format_reason(:invalid_discovery_response), do: "unexpected response shape"
  defp format_reason(:invalid_base_url), do: "invalid base URL"
  defp format_reason(_reason), do: "discovery unavailable"

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
    provider =
      case Presets.resolve(provider) do
        nil -> String.trim(provider)
        preset -> Atom.to_string(preset)
      end

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

  defp limit_rows(_models, _limit),
    do: raise(Error, message: "--limit must be a non-negative integer")

  defp render(models, source, opts) do
    summary = summarize(models, source)

    if opts[:json] do
      IO.puts(Jason.encode!(%{models: models, summary: summary}))
    else
      render_text(models, summary)
    end
  end

  defp summarize(models, source) do
    providers =
      models
      |> Enum.map(& &1.provider)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      source: source,
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
    IO.puts("No models matched.")
    IO.puts("Providers: #{summary.provider_count}")
    IO.puts("Includes credentials: false")
    IO.puts("Includes secret values: false")
  end

  defp render_text(models, summary) do
    IO.puts("Lemon Models")
    IO.puts("Source: #{summary.source}")
    IO.puts("Total: #{summary.total}")
    IO.puts("Providers: #{Enum.join(summary.providers, ", ")}")
    IO.puts("Vision models: #{summary.vision_model_count}")
    IO.puts("Thinking models: #{summary.thinking_model_count}")
    IO.puts("Includes credentials: false")
    IO.puts("Includes secret values: false")
    IO.puts("")

    Enum.each(models, fn model ->
      caps =
        [
          if(model.supports_vision, do: "vision"),
          if(model.supports_thinking, do: "thinking"),
          if(model.supports_streaming, do: "streaming")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")

      IO.puts("#{model.provider}:#{model.id}")
      IO.puts("  name: #{model.name}")
      IO.puts("  context_window: #{model.context_window}")
      IO.puts("  max_output: #{model.max_output}")
      IO.puts("  capabilities: #{caps}")
      IO.puts("")
    end)
  end
end
