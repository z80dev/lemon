defmodule LemonGateway.Types do
  @moduledoc false

  @type engine_id :: String.t()

  defmodule ResumeToken do
    @moduledoc false
    @enforce_keys [:engine, :value]
    defstruct [:engine, :value]

    @type t :: %__MODULE__{engine: LemonGateway.Types.engine_id(), value: String.t()}
  end

  defmodule ChatScope do
    @moduledoc """
    Legacy struct for Telegram-specific chat identification.
    Kept for backward compatibility during migration.
    """
    @enforce_keys [:transport, :chat_id]
    defstruct [:transport, :chat_id, :topic_id]

    @type t :: %__MODULE__{transport: atom(), chat_id: integer(), topic_id: integer() | nil}
  end

  @type queue_mode :: :collect | :followup | :steer | :steer_backlog | :interrupt
  @type lane :: :main | :subagent | :background_exec

  defmodule Job do
    @moduledoc """
    Transport-agnostic job definition for run orchestration.

    ## Fields

    - `:run_id` - Unique run identifier (UUID)
    - `:session_key` - Stable session key for routing and state
    - `:prompt` - User prompt text (or synthesized prompt)
    - `:engine_id` - Resolved engine identifier
    - `:cwd` - Working directory (optional)
    - `:resume` - Resume token for session continuation
    - `:queue_mode` - How to handle queuing (:collect, :followup, :steer, :steer_backlog, :interrupt)
    - `:lane` - Execution lane (:main, :subagent, :background_exec)
    - `:tool_policy` - Tool execution policy map
    - `:meta` - Additional metadata (origin, channel info, etc.)

    ## Legacy Fields (deprecated, for backward compatibility)

    - `:scope` - ChatScope struct (use session_key instead)
    - `:user_msg_id` - Telegram message ID (use meta[:user_msg_id] instead)
    - `:text` - Alias for prompt (use prompt instead)
    - `:engine_hint` - Alias for engine_id (use engine_id instead)
    """

    defstruct [
      # New transport-agnostic fields
      :run_id,
      :session_key,
      :prompt,
      :engine_id,
      :cwd,
      :resume,
      :lane,
      :tool_policy,
      :meta,
      # Legacy fields (for backward compatibility during migration)
      :scope,
      :user_msg_id,
      :text,
      :engine_hint,
      # Fields with defaults must be last
      queue_mode: :collect
    ]

    @type t :: %__MODULE__{
            run_id: String.t() | nil,
            session_key: String.t() | nil,
            prompt: String.t() | nil,
            engine_id: LemonGateway.Types.engine_id() | nil,
            cwd: String.t() | nil,
            resume: LemonGateway.Types.ResumeToken.t() | nil,
            queue_mode: LemonGateway.Types.queue_mode(),
            lane: LemonGateway.Types.lane() | nil,
            tool_policy: map() | nil,
            meta: map() | nil,
            # Legacy
            scope: LemonGateway.Types.ChatScope.t() | nil,
            user_msg_id: integer() | nil,
            text: String.t() | nil,
            engine_hint: LemonGateway.Types.engine_id() | nil
          }

    @doc """
    Get the effective prompt text (handles legacy text field).
    """
    @spec get_prompt(t()) :: String.t() | nil
    def get_prompt(%__MODULE__{prompt: prompt}) when is_binary(prompt), do: prompt
    def get_prompt(%__MODULE__{text: text}) when is_binary(text), do: text
    def get_prompt(_), do: nil

    @doc """
    Get the effective engine ID (handles legacy engine_hint field).
    """
    @spec get_engine_id(t()) :: String.t() | nil
    def get_engine_id(%__MODULE__{engine_id: id}) when is_binary(id), do: id
    def get_engine_id(%__MODULE__{engine_hint: hint}) when is_binary(hint), do: hint
    def get_engine_id(_), do: nil
  end

  defmodule Job.Legacy do
    @moduledoc """
    Compatibility bridge for converting between old and new Job formats.
    """

    alias LemonGateway.Types.{ChatScope, Job}

    @doc """
    Create a Job from a ChatScope (legacy Telegram format).

    This function creates a Job with both legacy and new fields populated
    for backward compatibility.
    """
    @spec from_chat_scope(ChatScope.t(), integer(), String.t(), keyword()) :: Job.t()
    def from_chat_scope(%ChatScope{} = scope, user_msg_id, text, opts \\ []) do
      resume = Keyword.get(opts, :resume)
      engine_hint = Keyword.get(opts, :engine_hint)
      queue_mode = Keyword.get(opts, :queue_mode, :collect)
      meta = Keyword.get(opts, :meta, %{})

      # Generate session_key from scope
      session_key = session_key_from_scope(scope)

      # Include channel info in meta
      meta =
        meta
        |> Map.put(:chat_id, scope.chat_id)
        |> Map.put(:user_msg_id, user_msg_id)
        |> Map.put(:origin, :telegram)
        |> Map.put(:transport, scope.transport)

      meta =
        if scope.topic_id do
          Map.put(meta, :topic_id, scope.topic_id)
        else
          meta
        end

      %Job{
        # New fields
        session_key: session_key,
        prompt: text,
        engine_id: engine_hint,
        resume: resume,
        queue_mode: queue_mode,
        meta: meta,
        # Legacy fields (for compatibility)
        scope: scope,
        user_msg_id: user_msg_id,
        text: text,
        engine_hint: engine_hint
      }
    end

    @doc """
    Generate a session key from a ChatScope.
    """
    @spec session_key_from_scope(ChatScope.t()) :: String.t()
    def session_key_from_scope(%ChatScope{transport: transport, chat_id: chat_id, topic_id: nil}) do
      "channel:telegram:#{transport}:#{chat_id}"
    end

    def session_key_from_scope(%ChatScope{
          transport: transport,
          chat_id: chat_id,
          topic_id: topic_id
        }) do
      "channel:telegram:#{transport}:#{chat_id}:thread:#{topic_id}"
    end

    @doc """
    Check if a Job uses legacy format (has scope but no session_key).
    """
    @spec legacy?(Job.t()) :: boolean()
    def legacy?(%Job{scope: scope, session_key: nil}) when not is_nil(scope), do: true
    def legacy?(_), do: false

    @doc """
    Migrate a legacy Job to use new fields.
    """
    @spec migrate(Job.t()) :: Job.t()
    def migrate(%Job{scope: %ChatScope{} = scope, session_key: nil} = job) do
      session_key = session_key_from_scope(scope)
      meta = job.meta || %{}

      meta =
        meta
        |> Map.put_new(:chat_id, scope.chat_id)
        |> Map.put_new(:user_msg_id, job.user_msg_id)
        |> Map.put_new(:origin, :telegram)

      %{job | session_key: session_key, prompt: job.text, engine_id: job.engine_hint, meta: meta}
    end

    def migrate(job), do: job
  end
end
