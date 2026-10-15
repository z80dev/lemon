defmodule CodingAgent.Session.LearningReviewTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.LearningReview

  alias LemonAi.Types.{
    AssistantMessage,
    TextContent,
    ThinkingContent,
    ToolCall,
    ToolResultMessage,
    UserMessage
  }

  test "summaries freeze only the finished user turn and visible final answer" do
    messages = [
      %UserMessage{content: "old private conversation"},
      %AssistantMessage{content: [%TextContent{text: "old response"}]},
      %UserMessage{content: "finished task"},
      %AssistantMessage{
        content: [
          %ThinkingContent{thinking: "private reasoning"},
          %ToolCall{name: "bash", arguments: %{"command" => "secret command"}}
        ]
      },
      %ToolResultMessage{content: [%TextContent{text: "secret tool payload"}]},
      %AssistantMessage{
        content: [
          %ThinkingContent{thinking: "more reasoning"},
          %TextContent{text: "visible answer"}
        ]
      }
    ]

    assert {"finished task", "visible answer"} == LearningReview.summaries(messages)
  end

  test "summaries use the memory document UTF-8 byte bound" do
    long = String.duplicate("界", 4_000)

    {prompt, answer} =
      LearningReview.summaries([
        %UserMessage{content: long},
        %AssistantMessage{content: [%TextContent{text: long}]}
      ])

    assert prompt == LemonMemory.Document.summary_text(long)
    assert answer == LemonMemory.Document.summary_text(long)
    assert byte_size(prompt) < byte_size(long)
    assert String.valid?(prompt)
    assert String.valid?(answer)
  end
end
