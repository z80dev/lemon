defmodule LemonSim.Examples.PhilosopherChat do
  @moduledoc """
  PhilosopherChat: a multi-agent group-chat world.

  The world is a durable message thread. Members are the human user ("you")
  plus persona agents. Each agent has its own file-based memory root (built
  from `memory_root` + `memory_namespace` options) where it keeps notes and
  opinions about the other members — the projector feeds those notes back
  into the agent's context, so opinions accumulate and evolve across turns.

  The hosted layer (`LemonSimUi.PhilosopherChat.ThreadServer`) drives turns
  one at a time with `LemonSim.Kernel.Runner.decide_once/3` +
  `decision_adapter` + `ingest_events/3`, exactly like hosted Werewolf rooms.
  """

  import LemonSim.Examples.Helpers

  alias LemonSim.Examples.PhilosopherChat.{
    ActionSpace,
    DecisionAdapter,
    Events,
    Persona,
    Updater
  }

  alias LemonSim.Kernel.{Runner, State}
  alias LemonSim.LLM.Deciders.ToolLoopDecider
  alias LemonSim.LLM.GameHelpers.Runner, as: GameRunner
  alias LemonSim.LLM.Projectors.SectionedProjector

  @user_id "you"
  @transcript_window 40
  @max_transcript_chars 7_000
  @max_opinions_chars 5_000

  @doc "The user's reserved member id."
  def user_id, do: @user_id

  @spec modules() :: map()
  def modules do
    %{
      action_space: ActionSpace,
      projector: SectionedProjector,
      decider: ToolLoopDecider,
      updater: Updater,
      decision_adapter: DecisionAdapter
    }
  end

  @doc "Builds a fresh thread world and State for a new conversation."
  @spec initial_state(String.t(), String.t(), [String.t()], keyword()) :: State.t()
  def initial_state(thread_id, name, member_ids, opts \\ []) do
    pace = Keyword.get(opts, :pace, "relaxed")
    now = System.system_time(:millisecond)

    personas =
      member_ids
      |> Enum.reject(&(&1 == @user_id))
      |> Enum.map(&{&1, Persona.get(&1)})
      |> Enum.reject(fn {_id, persona} -> is_nil(persona) end)
      |> Enum.into(%{})

    world = %{
      status: "active",
      thread_id: thread_id,
      name: name,
      members: member_ids,
      personas: personas,
      messages: [],
      next_seq: 1,
      pace: pace,
      created_at_ms: now,
      last_agent_at_ms: nil,
      last_author: nil
    }

    State.new(
      sim_id: thread_id,
      world: world,
      intent: %{
        goal:
          "Continue the group conversation as yourself. React to what was just said, " <>
            "answer questions addressed to you, challenge what you genuinely would challenge, " <>
            "and keep your written opinions in memory up to date."
      }
    )
  end

  @doc "Sets which agent is being prompted this turn (world mutation)."
  @spec with_actor(State.t(), String.t()) :: State.t()
  def with_actor(%State{} = state, agent_id) do
    State.put_world(state, Map.put(state.world, :active_actor_id, agent_id))
  end

  @doc "Clears the active actor after a turn."
  @spec clear_actor(State.t()) :: State.t()
  def clear_actor(%State{} = state) do
    State.put_world(state, Map.delete(state.world, :active_actor_id))
  end

  @doc "Applies a user/agent message to the world through the updater."
  @spec post_message(State.t(), String.t(), String.t()) ::
          {:ok, State.t(), map()} | {:error, term()}
  def post_message(%State{} = state, author, text) do
    case Runner.ingest_events(state, [Events.message_posted(author, text)], Updater, []) do
      {:ok, next_state, signal} -> {:ok, next_state, signal}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Applies a status change (active/paused/closed)."
  @spec set_status(State.t(), String.t()) :: {:ok, State.t()} | {:error, term()}
  def set_status(%State{} = state, status) do
    case Runner.ingest_events(state, [Events.status_changed(status)], Updater, []) do
      {:ok, next_state, _signal} -> {:ok, next_state}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Projector options for the SectionedProjector.

  `:memory_root` / `:memory_namespace` are read at decision time from the
  runner opts (the hosted layer passes them per turn).
  """
  @spec projector_opts() :: keyword()
  def projector_opts do
    [
      system_prompt:
        "You are participating in a lively group conversation across centuries. " <>
          "Stay entirely in character as yourself. Never break character, never " <>
          "mention that you are an AI or a simulation, and never summarize the " <>
          "conversation — be a participant, not a narrator.",
      section_builders: %{
        thread_context: fn frame, _tools, _opts ->
          %{
            id: :thread_context,
            title: "The Conversation So Far",
            format: :markdown,
            content: build_transcript(frame.world)
          }
        end,
        persona: fn frame, _tools, _opts ->
          actor_id = get(frame.world, :active_actor_id)
          persona = get(frame.world, :personas, %{}) |> Map.get(actor_id)

          content =
            case persona do
              nil -> "Unknown member."
              p -> Persona.describe(p)
            end

          %{id: :persona, title: "Your Identity", format: :markdown, content: content}
        end,
        opinions: fn frame, _tools, opts ->
          actor_id = get(frame.world, :active_actor_id)
          content = read_opinions(opts, actor_id)

          %{
            id: :opinions,
            title: "Your Written Opinions (from memory)",
            format: :markdown,
            content: content
          }
        end
      },
      section_overrides: %{
        world_state: nil,
        plan_history: nil,
        decision_contract: """
        CONVERSATION RULES:
        - React to the latest messages first. Answer direct questions addressed to you.
        - Speak as yourself. Use your own vocabulary, rhythm, and concerns.
          Never list your doctrines mechanically; let them color what you say.
        - Keep messages conversational: usually 1-4 sentences. Occasional longer turns
          (a short paragraph) are fine when the moment demands it.
        - Address others by name when you mean them. Argue, agree, tease, and digress
          as you naturally would.
        - You have file memory. After significant exchanges, write or update your
          opinions about the other members using the memory tools
          (e.g. write memory file opinions/socrates.md describing what you think of
          Socrates). Your opinions persist and shape you later.
        - End your turn with a speak call so the group sees your message. Memory
          notes are optional extras before or after it.
        """,
        memory: """
        You have a private memory directory with files you can read and write
        (memory_read_file, memory_write_file, memory_patch_file, memory_list_files,
        memory_delete_file). Keep concise notes — especially your evolving opinions
        of the other philosophers in opinions/<name>.md. Read your own notes when
        they matter; you never see anyone else's memory.
        """
      },
      section_order: [
        :thread_context,
        :persona,
        :opinions,
        :current_intent,
        :available_actions,
        :decision_contract,
        :memory
      ]
    ]
  end

  @spec default_opts(keyword()) :: keyword()
  def default_opts(overrides \\ []) when is_list(overrides) do
    GameRunner.build_default_opts(projector_opts(), overrides,
      game_name: "philosopher_chat",
      max_turns: 6,
      terminal?: fn _state -> false end,
      on_before_step: fn _turn, _state -> :ok end,
      on_after_step: fn _turn, _result -> :ok end
    )
    |> Keyword.put(:support_tool_matcher, &support_tool?/1)
    |> Keyword.put_new(:stream_options_for_model, &stream_options_for_model/1)
  end

  @doc "Memory tools are support tools; `speak` is the only decision tool."
  @spec support_tool?(map()) :: boolean()
  def support_tool?(%{name: name}) when is_binary(name), do: String.starts_with?(name, "memory_")
  def support_tool?(_), do: false

  defp stream_options_for_model(%{provider: :opencode_go, id: "deepseek" <> _}),
    do: %{max_tokens: 900, reasoning: :none, tool_choice: :any}

  defp stream_options_for_model(%{provider: provider}) when provider in [:opencode_go, :zai],
    do: %{max_tokens: 900, reasoning: false, tool_choice: :any}

  defp stream_options_for_model(_model), do: %{max_tokens: 900, tool_choice: :any}

  @doc "Pure world -> API projection (messages, members, personas)."
  @spec thread_projection(map()) :: map()
  def thread_projection(world) do
    %{
      id: get(world, :thread_id),
      name: get(world, :name, ""),
      status: get(world, :status, "active"),
      pace: get(world, :pace, "relaxed"),
      created_at_ms: get(world, :created_at_ms),
      members:
        get(world, :members, [])
        |> Enum.map(&member_projection(world, &1)),
      messages:
        get(world, :messages, [])
        |> Enum.map(fn m ->
          %{
            seq: get(m, :seq),
            author: get(m, :author),
            text: get(m, :text),
            at_ms: get(m, :at_ms)
          }
        end)
    }
  end

  @spec member_projection(map(), String.t()) :: map()
  def member_projection(world, member_id) do
    base = %{id: member_id, is_user: member_id == @user_id}

    case get(world, :personas, %{}) |> Map.get(member_id) do
      nil ->
        base |> Map.merge(%{name: "You", emoji: "🙂", color: "#4caf9d"})

      persona ->
        base
        |> Map.merge(%{
          name: get(persona, :name),
          emoji: get(persona, :emoji),
          color: get(persona, :color),
          era: get(persona, :era),
          tradition: get(persona, :tradition)
        })
    end
  end

  # -- projection helpers --

  defp build_transcript(world) do
    names =
      get(world, :personas, %{})
      |> Map.new(fn {id, p} -> {id, get(p, :name)} end)
      |> Map.put(@user_id, "You")

    world
    |> get(:messages, [])
    |> Enum.take(-@transcript_window)
    |> Enum.map(fn m ->
      author = get(m, :author)
      name = Map.get(names, author, author)
      "#{name}: #{get(m, :text)}"
    end)
    |> Enum.join("\n")
    |> truncate_chars(@max_transcript_chars)
  end

  defp read_opinions(opts, actor_id) do
    with memory_root when is_binary(memory_root) <- Keyword.get(opts, :memory_root),
         namespace when is_binary(namespace) <- Keyword.get(opts, :memory_namespace) do
      dir = Path.join([memory_root, namespace, actor_id, "opinions"])

      case File.ls(dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.sort()
          |> Enum.map(fn file ->
            name = Path.basename(file, ".md")

            content =
              case File.read(Path.join(dir, file)) do
                {:ok, text} -> text
                _ -> ""
              end

            "## #{name}\n\n#{String.trim(content)}"
          end)
          |> Enum.join("\n\n")
          |> truncate_chars(@max_opinions_chars)

        {:error, _} ->
          "You have not written any opinion notes yet. Write some after interesting exchanges."
      end
    else
      _ -> "Memory is not available this turn."
    end
  end

  defp truncate_chars(text, max) when byte_size(text) <= max, do: text

  defp truncate_chars(text, max) do
    # String.slice keeps the cut on a grapheme boundary (binary_part can
    # split a multi-byte UTF-8 codepoint).
    String.slice(text, 0, max) <> "\n…[truncated]"
  end
end
