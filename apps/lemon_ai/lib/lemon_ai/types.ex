defmodule LemonAi.Types do
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
            usage: LemonAi.Types.Usage.t(),
            stop_reason: stop_reason(),
            error_message: String.t() | nil,
            error_details: LemonAi.Error.parsed_error() | nil,
            retry_after_ms: non_neg_integer() | nil,
            timestamp: integer()
          }
    @type stop_reason :: :stop | :length | :tool_use | :error | :aborted | :redirected

    defstruct role: :assistant,
              content: [],
              api: nil,
              provider: nil,
              model: "",
              usage: nil,
              stop_reason: nil,
              error_message: nil,
              error_details: nil,
              retry_after_ms: nil,
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
            trust: LemonAi.Types.trust_level(),
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
            input: float() | nil,
            output: float() | nil,
            cache_read: float() | nil,
            cache_write: float() | nil,
            total: float() | nil
          }
    defstruct input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0
  end

  defmodule Usage do
    @moduledoc """
    Token usage and cost for a response. `cache_write_long` is the hourly
    Anthropic cache-write subset of `cache_write`, not an additional token count.
    Counters and costs may be nil when the provider did not report them; nil is
    unknown, never a measured zero. Input excludes cache-read/write tokens.
    """
    @type t :: %__MODULE__{
            input: non_neg_integer() | nil,
            output: non_neg_integer() | nil,
            cache_read: non_neg_integer() | nil,
            cache_write: non_neg_integer() | nil,
            cache_write_long: non_neg_integer() | nil,
            total_tokens: non_neg_integer() | nil,
            cost: Cost.t() | nil
          }
    defstruct input: 0,
              output: 0,
              cache_read: 0,
              cache_write: 0,
              cache_write_long: 0,
              total_tokens: 0,
              cost: %Cost{}
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
            LemonAi.Types.UserMessage.t()
            | LemonAi.Types.AssistantMessage.t()
            | LemonAi.Types.ToolResultMessage.t()
    @type t :: %__MODULE__{
            system_prompt: String.t() | nil,
            messages: [message()],
            tools: [LemonAi.Types.Tool.t()]
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
      message = %LemonAi.Types.UserMessage{
        content: content,
        timestamp: System.system_time(:millisecond)
      }

      %{ctx | messages: [message | ctx.messages]}
    end

    @doc "Add an assistant message to the context"
    def add_assistant_message(%__MODULE__{} = ctx, %LemonAi.Types.AssistantMessage{} = message) do
      %{ctx | messages: [message | ctx.messages]}
    end

    @doc "Add a tool result to the context"
    def add_tool_result(%__MODULE__{} = ctx, %LemonAi.Types.ToolResultMessage{} = result) do
      %{ctx | messages: [result | ctx.messages]}
    end

    @doc """
    Returns messages in chronological order (oldest first).

    Messages are stored internally in reverse order for O(1) append performance.
    Use this function when you need messages in chronological order for LLM APIs.
    """
    def get_messages_chronological(%__MODULE__{} = ctx) do
      Enum.reverse(ctx.messages)
    end
  end

  # ============================================================================
  # Model Definition
  # ============================================================================

  defmodule ModelCost do
    @moduledoc """
    Per-million-token prices. Optional `long_context` supplies `input_threshold`
    and replacement input/output/cache prices when total input (including cache)
    exceeds the threshold.
    """
    @type t :: %__MODULE__{
            input: float(),
            output: float(),
            cache_read: float(),
            cache_write: float(),
            long_context: map() | nil
          }
    defstruct input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, long_context: nil
  end

  defmodule Model do
    @moduledoc """
    Model definition with capabilities and pricing.

    Reasoning capability flags:

      * `reasoning` - the model accepts a reasoning/thinking request at all.
      * `adaptive_thinking` - Anthropic Messages models that take
        `thinking: %{type: "adaptive"}` plus `output_config.effort` instead of a
        manual `budget_tokens` thinking budget (manual budgets are rejected on
        Claude Opus 4.7 and later).
      * `reasoning_efforts` - the Lemon reasoning levels the model accepts
        natively, in ascending order. An empty list means undeclared: levels
        pass through unchanged. See `LemonAi.Models.reasoning_effort_for/2`.

    `service_tier_cost` maps `"flex"` / `"priority"` to billing multipliers;
    absent entries retain base prices for that surface.
    """
    @type input_type :: :text | :image
    @type reasoning_level :: :minimal | :low | :medium | :high | :xhigh
    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            api: atom() | String.t(),
            provider: atom() | String.t(),
            base_url: String.t(),
            reasoning: boolean(),
            adaptive_thinking: boolean(),
            reasoning_efforts: [reasoning_level()],
            input: [input_type()],
            cost: ModelCost.t(),
            context_window: non_neg_integer(),
            service_tier_cost: %{optional(String.t()) => number()},
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
              adaptive_thinking: false,
              reasoning_efforts: [],
              input: [:text],
              cost: %ModelCost{},
              context_window: 0,
              service_tier_cost: %{},
              max_tokens: 0,
              headers: %{},
              compat: nil
  end

  # ============================================================================
  # Stream Options
  # ============================================================================

  defmodule StreamOptions do
    @moduledoc """
    Options for streaming requests.

    `on_payload` is an opt-in Codex or OpenAI-compatible request observer, called
    with the finalized JSON-safe body and provider/model/session metadata before
    HTTP submission. `on_usage` observes terminal raw usage before normalization.
    Both callbacks run in the provider worker; their return values are ignored and observer
    errors fail the stream. Bodies can contain private conversation content;
    observers must keep them in memory and persist only safe measurements.

    `provider_retry` overrides the local HTTP retry policy for this request.
    `LemonAi.complete/3` sets one HTTP attempt because its oneshot policy owns
    the total attempt budget; ordinary streams retain the provider defaults.
    Provider fallback sets `provider_retry.alternate_available` when an untried
    healthy candidate exists. Rate limits then surface without in-provider sleeps;
    other failures and single-candidate retry behavior are unchanged.

    `api_key_authoritative` marks caller-resolved credential authority. A missing
    or empty key then fails before provider fallback or HTTP, even on a keyless
    model. Leave it false for ordinary low-level environment/keyless resolution.

    `caller_headers` retains the original caller override layer when Lemon-owned
    options are rebuilt for another model. Derived provider/model headers must
    not become caller overrides on the next request.
    """
    @type thinking_level :: :minimal | :low | :medium | :high | :xhigh
    @type t :: %__MODULE__{
            temperature: float() | nil,
            max_tokens: non_neg_integer() | nil,
            api_key: String.t() | nil,
            api_key_authoritative: boolean(),
            session_id: String.t() | nil,
            cwd: String.t() | nil,
            headers: map(),
            caller_headers: map() | nil,
            reasoning: thinking_level() | nil,
            thinking_budgets: map(),
            stream_timeout: timeout(),
            tool_choice: atom() | String.t() | nil,
            project: String.t() | nil,
            location: String.t() | nil,
            access_token: String.t() | nil,
            service_account_json: String.t() | nil,
            provider_options: map(),
            provider_retry: map() | nil,
            on_payload: (map(), map() -> term()) | nil,
            on_usage: (map(), map() -> term()) | nil
          }
    defstruct temperature: nil,
              max_tokens: nil,
              api_key: nil,
              api_key_authoritative: false,
              session_id: nil,
              cwd: nil,
              headers: %{},
              caller_headers: nil,
              reasoning: nil,
              thinking_budgets: %{},
              stream_timeout: 300_000,
              tool_choice: nil,
              project: nil,
              location: nil,
              access_token: nil,
              service_account_json: nil,
              provider_options: %{},
              provider_retry: nil,
              on_payload: nil,
              on_usage: nil
  end
end
