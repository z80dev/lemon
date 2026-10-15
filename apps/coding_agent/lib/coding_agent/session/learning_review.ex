defmodule CodingAgent.Session.LearningReview do
  @moduledoc false

  alias CodingAgent.Session.ModelResolver

  # Capture only model configuration, never the live session or its transcript.
  def options(state) do
    model = state.model
    settings = state.settings_manager
    cwd = state.cwd

    fn override ->
      selected = ModelResolver.resolve_session_model(override || model, settings)

      {:ok,
       [
         model: selected,
         get_api_key: ModelResolver.build_get_api_key(settings),
         stream_options: ModelResolver.build_stream_options(selected, settings, nil, cwd)
       ]}
    end
  end

  def completed(messages) do
    summary = summaries(messages)
    LemonSkills.LearningNudge.review_completed(self(), fn -> summary end)
  end

  def summaries(messages) do
    # Only the final user turn and visible final assistant response are used.
    # Tool payloads and thinking never leave the native-session boundary.
    reversed = Enum.reverse(messages)
    turn = Enum.take_while(reversed, &(Map.get(&1, :role) != :user))
    user = Enum.find(reversed, &(Map.get(&1, :role) == :user))
    answer = Enum.find(turn, &(Map.get(&1, :role) == :assistant))
    {text(user), text(answer)}
  end

  defp text(nil), do: ""

  defp text(%{content: content}) when is_binary(content),
    do: LemonMemory.Document.summary_text(content)

  defp text(%{content: content}) when is_list(content) do
    Enum.reduce_while(content, "", fn block, acc ->
      if Map.get(block, :type) in [:text, "text"] do
        value = Map.get(block, :text, "")

        summary =
          LemonMemory.Document.summary_text(if(acc == "", do: value, else: acc <> "\n" <> value))

        if byte_size(summary) > LemonMemory.Document.max_summary_bytes(),
          do: {:halt, summary},
          else: {:cont, summary}
      else
        {:cont, acc}
      end
    end)
  end

  defp text(_), do: ""
end
