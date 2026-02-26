defmodule LemonRouter.SmartRouting do
  @moduledoc """
  Classifies task complexity and routes requests to cheap vs primary models.

  Ported from Ironclaw's smart_routing.rs. Complements `LemonRouter.ModelSelection`
  which resolves WHICH model from config — this module decides WHETHER to use
  cheap vs primary based on message complexity.
  """

  @type complexity :: :simple | :moderate | :complex

  defmodule Config do
    @moduledoc false
    defstruct cascade_enabled: true,
              simple_max_chars: 200,
              complex_min_chars: 1000
  end

  @complex_keywords ~w(implement refactor analyze debug create build design fix
    write explain compare optimize review rewrite migrate architect integrate)

  @simple_keywords ["list", "show", "what is", "status", "help", "yes", "no",
    "thanks", "hello", "hi", "version"]

  @uncertain_patterns [
    "i'm not sure",
    "i cannot",
    "beyond my capabilities",
    "i need more context",
    "i need more information",
    "i'm not confident"
  ]

  # --- Classification ---

  @spec classify_message(String.t() | nil) :: complexity()
  def classify_message(nil), do: :simple
  def classify_message(""), do: :simple

  def classify_message(message) when is_binary(message) do
    trimmed = String.trim(message)
    len = String.length(trimmed)
    lower = String.downcase(trimmed)

    cond do
      trimmed == "" -> :simple
      String.contains?(trimmed, "```") -> :complex
      has_complex_keyword?(lower) -> :complex
      len >= 1000 -> :complex
      has_simple_keyword?(lower) and len <= 200 -> :simple
      len <= 10 -> :simple
      true -> :moderate
    end
  end

  # --- Routing ---

  @spec route(String.t() | nil, String.t(), String.t(), Config.t()) ::
          {:ok, String.t(), complexity()}
  def route(message, primary_model, cheap_model, config \\ %Config{})

  def route(message, primary_model, cheap_model, _config) do
    if has_tool_calls?(message) do
      {:ok, primary_model, :complex}
    else
      complexity = classify_message(message)

      selected =
        case complexity do
          :simple -> cheap_model
          :complex -> primary_model
          :moderate -> cheap_model
        end

      {:ok, selected, complexity}
    end
  end

  # --- Uncertainty detection ---

  @spec uncertain_response?(String.t() | nil) :: boolean()
  def uncertain_response?(nil), do: true
  def uncertain_response?(""), do: true

  def uncertain_response?(text) when is_binary(text) do
    lower = String.downcase(text)
    Enum.any?(@uncertain_patterns, &String.contains?(lower, &1))
  end

  # --- Stats tracking via Agent ---

  @spec start_stats() :: {:ok, pid()}
  def start_stats do
    Agent.start_link(fn -> %{cheap: 0, primary: 0, cascade_escalation: 0} end)
  end

  @spec record_request(pid(), :cheap | :primary | :cascade_escalation) :: :ok
  def record_request(stats_pid, type) when type in [:cheap, :primary, :cascade_escalation] do
    Agent.update(stats_pid, fn stats ->
      Map.update!(stats, type, &(&1 + 1))
    end)
  end

  @spec get_stats(pid()) :: map()
  def get_stats(stats_pid) do
    Agent.get(stats_pid, & &1)
  end

  # --- Private helpers ---

  defp has_complex_keyword?(lower) do
    Enum.any?(@complex_keywords, &String.contains?(lower, &1))
  end

  defp has_simple_keyword?(lower) do
    Enum.any?(@simple_keywords, &String.contains?(lower, &1))
  end

  defp has_tool_calls?(message) when is_binary(message) do
    String.contains?(message, "<tool_call>") or String.contains?(message, "\"tool_calls\"")
  end

  defp has_tool_calls?(_), do: false
end
