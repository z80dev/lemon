defmodule Ai.Types do
  @moduledoc """
  Core type definitions for the AI library.

  This module defines the data structures used throughout the library
  for representing conversations, messages, tool calls, and model metadata.
  """

  @typedoc """
  Trust level for tool-generated content.

  - `:trusted` - Content can be treated as trusted
  - `:untrusted` - Content should be handled as untrusted
  """
  @type trust_level :: :trusted | :untrusted

  # ============================================================================
  # Content Types
  # ============================================================================

  defmodule TextContent do
    @moduledoc "Plain text content block"
    @type t :: %__MODULE__{
            type: :text,
            text: String.t(),
            text_signature: String.t() | nil
          }
    defstruct type: :text, text: "", text_signature: nil
  end

  defmodule ThinkingContent do
    @moduledoc "Model reasoning/thinking content block"
    @type t :: %__MODULE__{
            type: :thinking,
            thinking: String.t(),
            thinking_signature: String.t() | nil
          }
    defstruct type: :thinking, thinking: "", thinking_signature: nil
  end

  defmodule ImageContent do
    @moduledoc "Base64-encoded image content block"
    @type t :: %__MODULE__{
            type: :image,
            data: String.t(),
            mime_type: String.t()
          }
    defstruct type: :image, data: "", mime_type: "image/png"
  end

  defmodule ToolCall do
    @moduledoc "Tool/function call from the model"
    @type t :: %__MODULE__{
            type: :tool_call,
            id: String.t(),
            name: String.t(),
            arguments: map(),
            thought_signature: String.t() | nil
          }
    defstruct type: :tool_call, id: "", name: "", arguments: %{}, thought_signature: nil
  end

  # ============================================================================
  # Message Types
  # ============================================================================

  defmodule UserMessage do
    @moduledoc "A message from the user"
    @type content :: String.t() | [TextContent.t() | ImageContent.t()]
    @type t :: %__MODULE__{
            role: :user,
            content: content(),
            timestamp: integer()
          }
    defstruct role: :user, content: "", timestamp: 0
  end

  defmodule AssistantMessage do
    @moduledoc "A message from the assistant/model"
    @type content_block :: TextContent.t() | ThinkingContent.t() | ToolCall.t()
    @type t :: %__MODULE__{
            role: :assistant,
            content: [content_block()],
            api: atom() | String.t(),
            provider: atom() | String.t(),
            model: String.t(),
            usage: Usage.t(),
            stop_reason: stop_reason(),
            error_message: String.t() | nil,
            timestamp: integer()
          }
    @type stop_reason :: :stop | :length | :tool_use | :error | :aborted

    defstruct role: :assistant,
              content: [],
              api: nil,
              provider: nil,
              model: "",
              usage: nil,
              stop_reason: nil,
              error_message: nil,
              timestamp: 0
  end

  defmodule ToolResultMessage do
    @moduledoc "Result of a tool call"
    @type t :: %__MODULE__{
            role: :tool_result,
            tool_call_id: String.t(),
            tool_name: String.t(),
            content: [TextContent.t() | ImageContent.t()],
            details: any(),
            trust: Ai.Types.trust_level(),
            is_error: boolean(),
            timestamp: integer()
          }
    defstruct role: :tool_result,
              tool_call_id: "",
              tool_name: "",
              content: [],
              details: nil,
              trust: :trusted,
              is_error: false,
              timestamp: 0
  end

  @type message :: UserMessage.t() | AssistantMessage.t() | ToolResultMessage.t()

  # ============================================================================
  # Usage & Cost Tracking
  # ============================================================================

  defmodule Cost do
    @moduledoc "Cost breakdown in dollars"
    @type t :: %__MODULE__{
            input: float(),
            output: float(),
            cache_read: float(),
            cache_write: float(),
            total: float()
          }
    defstruct input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0
  end

  defmodule Usage do
    @moduledoc "Token usage and cost for a response"
    @type t :: %__MODULE__{
            input: non_neg_integer(),
            output: non_neg_integer(),
            cache_read: non_neg_integer(),
            cache_write: non_neg_integer(),
            total_tokens: non_neg_integer(),
            cost: Cost.t()
          }
    defstruct input: 0, output: 0, cache_read: 0, cache_write: 0, total_tokens: 0, cost: %Cost{}
  end

  # ============================================================================
  # Tool Definitions
  # ============================================================================

  defmodule Tool do
    @moduledoc "Tool/function definition for the model"
    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t(),
            parameters: map()
          }
    defstruct name: "", description: "", parameters: %{}
  end

  # ============================================================================
  # Context
  # ============================================================================

  defmodule Context do
    @moduledoc "Conversation context containing messages, tools, and system prompt"
    @type message ::
            Ai.Types.UserMessage.t()
            | Ai.Types.AssistantMessage.t()
            | Ai.Types.ToolResultMessage.t()
    @type t :: %__MODULE__{
            system_prompt: String.t() | nil,
            messages: [message()],
            tools: [Ai.Types.Tool.t()]
          }
    defstruct system_prompt: nil, messages: [], tools: []

    @doc "Create a new empty context"
    def new(opts \\ []) do
      %__MODULE__{
        system_prompt: Keyword.get(opts, :system_prompt),
        messages: Keyword.get(opts, :messages, []),
        tools: Keyword.get(opts, :tools, [])
      }
    end

    @doc "Add a user message to the context"
    def add_user_message(%__MODULE__{} = ctx, content) when is_binary(content) do
      message = %Ai.Types.UserMessage{
        content: content,
        timestamp: System.system_time(:millisecond)
      }

      %{ctx | messages: ctx.messages ++ [message]}
    end

    @doc "Add an assistant message to the context"
    def add_assistant_message(%__MODULE__{} = ctx, %Ai.Types.AssistantMessage{} = message) do
      %{ctx | messages: ctx.messages ++ [message]}
    end

    @doc "Add a tool result to the context"
    def add_tool_result(%__MODULE__{} = ctx, %Ai.Types.ToolResultMessage{} = result) do
      %{ctx | messages: ctx.messages ++ [result]}
    end
  end

  # ============================================================================
  # Model Definition
  # ============================================================================

  defmodule ModelCost do
    @moduledoc "Cost per million tokens for a model"
    @type t :: %__MODULE__{
            input: float(),
            output: float(),
            cache_read: float(),
            cache_write: float()
          }
    defstruct input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0
  end

  defmodule Model do
    @moduledoc "Model definition with capabilities and pricing"
    @type input_type :: :text | :image
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            api: atom() | String.t(),
            provider: atom() | String.t(),
            base_url: String.t(),
            reasoning: boolean(),
            input: [input_type()],
            cost: ModelCost.t(),
            context_window: non_neg_integer(),
            max_tokens: non_neg_integer(),
            headers: map(),
            compat: map() | nil
          }
    defstruct id: "",
              name: "",
              api: nil,
              provider: nil,
              base_url: "",
              reasoning: false,
              input: [:text],
              cost: %ModelCost{},
              context_window: 0,
              max_tokens: 0,
              headers: %{},
              compat: nil
  end

  # ============================================================================
  # Stream Options
  # ============================================================================

  defmodule StreamOptions do
    @moduledoc "Options for streaming requests"
    @type thinking_level :: :minimal | :low | :medium | :high | :xhigh
    @type t :: %__MODULE__{
            temperature: float() | nil,
            max_tokens: non_neg_integer() | nil,
            api_key: String.t() | nil,
            session_id: String.t() | nil,
            headers: map(),
            reasoning: thinking_level() | nil,
            thinking_budgets: map(),
            stream_timeout: timeout(),
            tool_choice: atom() | nil,
            project: String.t() | nil,
            location: String.t() | nil,
            access_token: String.t() | nil
          }
    defstruct temperature: nil,
              max_tokens: nil,
              api_key: nil,
              session_id: nil,
              headers: %{},
              reasoning: nil,
              thinking_budgets: %{},
              stream_timeout: 300_000,
              tool_choice: nil,
              project: nil,
              location: nil,
              access_token: nil
  end
end
