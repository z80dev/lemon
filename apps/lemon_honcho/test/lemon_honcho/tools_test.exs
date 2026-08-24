defmodule LemonHoncho.ToolsTest.StubClient do
  @moduledoc false
  # A Honcho that answers every call with something distinctive, and reports the
  # arguments it was handed to the test process. Registered through
  # `Application.put_env(:lemon_honcho, :client, ...)`, which is the same seam
  # `LemonHoncho.SessionManager` resolves its client through.

  @spec ensure_workspace(term()) :: {:ok, map()}
  def ensure_workspace(_config), do: {:ok, %{}}

  @spec ensure_peer(term(), String.t()) :: {:ok, map()}
  def ensure_peer(_config, _peer), do: {:ok, %{}}

  @spec ensure_session(term(), String.t(), list()) :: {:ok, map()}
  def ensure_session(_config, _session_id, _specs), do: {:ok, %{}}

  @spec set_peer_config(term(), String.t(), String.t(), map()) :: {:ok, map()}
  def set_peer_config(_config, _session_id, _peer, _flags), do: {:ok, %{}}

  @spec chat(term(), String.t(), String.t(), keyword()) :: {:ok, String.t()}
  def chat(_config, peer, query, opts) do
    record(:chat, {peer, query, opts})
    {:ok, "They review diffs before prose."}
  end

  @spec session_search(term(), String.t(), String.t(), keyword()) :: {:ok, [map()]}
  def session_search(_config, session_id, query, opts) do
    record(:session_search, {session_id, query, opts})
    {:ok, [%{"content" => "the cache was cold", "peer_id" => "user"}]}
  end

  @spec workspace_search(term(), String.t(), keyword()) :: {:ok, [map()]}
  def workspace_search(_config, query, opts) do
    record(:workspace_search, {query, opts})
    {:ok, [%{"content" => "workspace-wide recollection", "peer_id" => "user"}]}
  end

  @spec session_context(term(), String.t(), keyword()) :: {:ok, map()}
  def session_context(_config, session_id, opts) do
    record(:session_context, {session_id, opts})

    {:ok,
     %{
       "summary" => %{"content" => "Discussed the flaky test."},
       "messages" => [%{"peer_id" => "user", "content" => "why is the build slow?"}]
     }}
  end

  @spec peer_context(term(), String.t(), keyword()) :: {:ok, map()}
  def peer_context(_config, peer, opts) do
    record(:peer_context, {peer, opts})
    {:ok, %{"representation" => "Writes Elixir.", "peer_card" => ["Prefers terse answers."]}}
  end

  @spec get_peer_card(term(), String.t(), keyword()) :: {:ok, [String.t()]}
  def get_peer_card(_config, peer, opts) do
    record(:get_peer_card, {peer, opts})
    {:ok, ["Prefers terse answers."]}
  end

  @spec set_peer_card(term(), String.t(), [String.t()], keyword()) :: {:ok, [String.t()]}
  def set_peer_card(_config, peer, card, opts) do
    record(:set_peer_card, {peer, card, opts})
    {:ok, card}
  end

  @spec create_conclusions(term(), [map()]) :: {:ok, map()}
  def create_conclusions(_config, conclusions) do
    record(:create_conclusions, conclusions)
    {:ok, %{}}
  end

  @spec delete_conclusion(term(), String.t()) :: {:ok, map()}
  def delete_conclusion(_config, conclusion_id) do
    record(:delete_conclusion, conclusion_id)
    {:ok, %{}}
  end

  # "nothing" is the one query with no matches, so the empty rendering can be
  # exercised without a second stub module.
  @spec query_conclusions(term(), String.t(), keyword()) :: {:ok, [map()]}
  def query_conclusions(_config, query, opts) do
    record(:query_conclusions, {query, opts})

    case query do
      "nothing" ->
        {:ok, []}

      _other ->
        {:ok,
         [
           %{
             "id" => "con_42",
             "content" => "Never deploys on Fridays.",
             "created_at" => "2026-08-01T09:00:00Z"
           }
         ]}
    end
  end

  defp record(name, payload) do
    case Application.get_env(:lemon_honcho, :test_owner) do
      owner when is_pid(owner) -> send(owner, {:honcho_call, name, payload})
      _other -> :ok
    end
  end
end

defmodule LemonHoncho.ToolsTest do
  @moduledoc """
  The five Honcho agent tools.

  Three properties are checked for every one of them, because a tool that gets
  any of them wrong is broken in a way the model cannot report: the schema the
  model is shown is well-formed, a missing configuration is answered rather
  than raised, and a mode that switches the tools off is enforced here rather
  than by hoping registration was skipped.
  """

  use ExUnit.Case, async: false

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonHoncho.{Config, SessionManager}
  alias LemonHoncho.Tools.{Conclude, Context, Profile, Reasoning, Search}
  alias LemonHoncho.ToolsTest.StubClient

  @env_vars ~w(
    HONCHO_API_KEY
    HONCHO_BASE_URL
    HONCHO_PEER
    HONCHO_AI_PEER
    HONCHO_WORKSPACE
    LEMON_HONCHO_ENABLED
    LEMON_HONCHO_RECALL_MODE
    LEMON_HONCHO_SESSION_STRATEGY
    LEMON_HONCHO_OBSERVATION_MODE
    LEMON_HONCHO_REASONING_LEVEL
    LEMON_HONCHO_SAVE_MESSAGES
  )

  @app_keys [
    :enabled,
    :api_key,
    :base_url,
    :user_peer,
    :ai_peer,
    :recall_mode,
    :session_strategy,
    :observation_mode,
    :reasoning_level,
    :save_messages,
    :client,
    :test_owner
  ]

  @modules [Reasoning, Search, Context, Profile, Conclude]

  @names %{
    Reasoning => "honcho_reasoning",
    Search => "honcho_search",
    Context => "honcho_context",
    Profile => "honcho_profile",
    Conclude => "honcho_conclude"
  }

  # One valid call per tool, so the mode and configuration gates can be checked
  # against parameters that would otherwise succeed.
  @valid_params %{
    Reasoning => %{"query" => "how do they like PRs described?"},
    Search => %{"query" => "cold cache"},
    Context => %{},
    Profile => %{},
    Conclude => %{"conclusion" => "Never deploys on Fridays."}
  }

  @opts [cwd: "/tmp/lemon-honcho-tools-test", session_key: "agent:tools:main"]

  setup do
    saved_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    saved_app = Map.new(@app_keys, &{&1, Application.fetch_env(:lemon_honcho, &1)})

    Enum.each(@env_vars, &System.delete_env/1)
    Enum.each(@app_keys, &Application.delete_env(:lemon_honcho, &1))

    Application.put_env(:lemon_honcho, :client, StubClient)
    Application.put_env(:lemon_honcho, :test_owner, self())

    on_exit(fn ->
      Enum.each(saved_env, &restore_env/1)
      Enum.each(saved_app, &restore_app_env/1)
    end)

    :ok
  end

  describe "the tool definitions" do
    test "every tool exposes a well-formed schema from tool/1 and tool/2" do
      Enum.each(@modules, fn module ->
        assert_valid_tool(module.tool([]), @names[module])
        assert_valid_tool(module.tool("/tmp/lemon-honcho-tools-test", []), @names[module])
      end)
    end

    test "every description tells the model what it gets back" do
      Enum.each(@modules, fn module ->
        assert String.length(module.tool([]).description) > 200
      end)
    end

    test "honcho_reasoning admits that it costs a server-side LLM call" do
      assert Reasoning.tool([]).description =~ "LLM call"
    end

    test "honcho_profile says outright that a write replaces the card" do
      description = Profile.tool([]).description

      assert description =~ "REPLACES"
      assert description =~ "deleted"
    end
  end

  describe "when Honcho is not configured" do
    test "every tool answers instead of raising, and calls nothing" do
      Enum.each(@modules, fn module ->
        result = execute(module, @valid_params[module])

        assert %AgentToolResult{details: %{error: :not_configured}} = result
        assert text(result) =~ "HONCHO_API_KEY"
        assert text(result) =~ "HONCHO_BASE_URL"
      end)

      refute_received {:honcho_call, _name, _payload}
    end
  end

  describe "when recall_mode is :context" do
    setup do
      configure(recall_mode: :context)
    end

    test "every tool reports itself inactive and calls nothing" do
      Enum.each(@modules, fn module ->
        result = execute(module, @valid_params[module])

        assert %AgentToolResult{details: %{error: :context_only}} = result
        assert text(result) =~ "context-only mode"
      end)

      refute_received {:honcho_call, _name, _payload}
    end
  end

  describe "honcho_reasoning" do
    setup do
      configure()
    end

    test "asks the assistant peer about the user and returns the answer" do
      result = execute(Reasoning, %{"query" => "what do they care about?"})

      assert text(result) =~ "They review diffs before prose."
      assert %{answer: "They review diffs before prose.", target: "user"} = result.details

      assert_received {:honcho_call, :chat, {"lemon", "what do they care about?", opts}}
      assert opts[:target] == "user"
      assert opts[:reasoning_level] == :low
      assert is_binary(opts[:session_id])
    end

    test "honours a reasoning_level the model picked" do
      execute(Reasoning, %{"query" => "anything", "reasoning_level" => "high"})

      assert_received {:honcho_call, :chat, {_peer, _query, opts}}
      assert opts[:reasoning_level] == :high
    end

    test "asks the assistant peer about itself when target is ai" do
      execute(Reasoning, %{"query" => "how do I behave?", "target" => "ai"})

      assert_received {:honcho_call, :chat, {"lemon", _query, opts}}
      refute Keyword.has_key?(opts, :target)
    end

    test "rejects a missing, blank, or non-string query" do
      assert error(execute(Reasoning, %{})) =~ "Missing required parameter: query"
      assert error(execute(Reasoning, %{"query" => "  "})) =~ "cannot be empty"
      assert error(execute(Reasoning, %{"query" => 42})) =~ "must be a string"
    end

    test "rejects an unknown reasoning_level or target" do
      params = %{"query" => "anything", "reasoning_level" => "extreme"}
      assert error(execute(Reasoning, params)) =~ "reasoning_level"

      params = %{"query" => "anything", "target" => "dog"}
      assert error(execute(Reasoning, params)) =~ "target"
    end
  end

  describe "honcho_search" do
    setup do
      configure()
    end

    test "returns the matching excerpts verbatim" do
      result = execute(Search, %{"query" => "cold cache"})

      # No session is mapped here, so this is the workspace hit; what matters is
      # that its text and peer label survive into the tool output unrewritten.
      assert text(result) =~ "user\nworkspace-wide recollection"
      assert result.details.excerpts == ["user\nworkspace-wide recollection"]
      assert result.details.count == 1
    end

    test "caps the limit and passes it through" do
      execute(Search, %{"query" => "cold cache", "limit" => 5_000})

      assert_received {:honcho_call, :workspace_search, {"cold cache", opts}}
      assert opts[:limit] == 100
    end

    test "searches the workspace when asked to" do
      result = execute(Search, %{"query" => "cold cache", "scope" => "workspace"})

      assert text(result) =~ "workspace-wide recollection"
      assert result.details.searched_scope == :workspace
      assert_received {:honcho_call, :workspace_search, _payload}
    end

    test "falls back to the workspace when the session is not mapped" do
      result = execute(Search, %{"query" => "cold cache"})

      assert result.details.requested_scope == "session"
      assert result.details.searched_scope == :workspace
      assert_received {:honcho_call, :workspace_search, _payload}
    end

    test "rejects a missing query, a non-positive limit, and an unknown scope" do
      assert error(execute(Search, %{})) =~ "Missing required parameter: query"
      assert error(execute(Search, %{"query" => "x", "limit" => 0})) =~ "positive integer"
      assert error(execute(Search, %{"query" => "x", "limit" => "many"})) =~ "positive integer"
      assert error(execute(Search, %{"query" => "x", "scope" => "galaxy"})) =~ "scope"
    end
  end

  describe "a session the manager has already mapped" do
    setup do
      configure()
      stop_application_manager()

      start_supervised!(
        {SessionManager,
         config: %Config{
           api_key: "sk-test",
           user_peer: "user",
           ai_peer: "lemon",
           first_turn_wait_ms: 2_000
         },
         client: StubClient}
      )

      # One turn of context is what resolves the Honcho session id for this key;
      # its stub traffic is drained so the assertions below see only their own.
      SessionManager.context_for(%{
        cwd: Keyword.fetch!(@opts, :cwd),
        session_key: Keyword.fetch!(@opts, :session_key),
        session_scope: :main,
        query: "why is the build slow?"
      })

      flush()
    end

    test "honcho_search scopes to the mapped Honcho session" do
      result = execute(Search, %{"query" => "cold cache"})

      assert result.details.searched_scope == :session
      assert text(result) =~ "the cache was cold"

      assert_received {:honcho_call, :session_search, {session_id, "cold cache", opts}}
      assert session_id == "lemon-honcho-tools-test"
      assert result.details.session_id == session_id
      assert opts[:limit] == 10
    end

    test "honcho_conclude tags the conclusion with that session" do
      execute(Conclude, %{"conclusion" => "Never deploys on Fridays."})

      assert_received {:honcho_call, :create_conclusions, [conclusion]}
      assert conclusion.session_id == "lemon-honcho-tools-test"
    end
  end

  describe "honcho_context" do
    setup do
      configure()
    end

    test "returns the summary, the representation, the card, and recent messages" do
      result = execute(Context, %{})

      assert text(result) =~ "Discussed the flaky test."
      assert text(result) =~ "Writes Elixir."
      assert text(result) =~ "Prefers terse answers."
      assert text(result) =~ "why is the build slow?"
      assert result.details.message_count == 1
    end

    test "forwards a token budget to Honcho rather than trimming locally" do
      execute(Context, %{"tokens" => 800})

      assert_received {:honcho_call, :session_context, {_session_id, opts}}
      assert opts[:tokens] == 800
      assert opts[:summary] == true
    end

    test "rejects a token budget that is not a positive integer" do
      assert error(execute(Context, %{"tokens" => "lots"})) =~ "positive integer"
      assert error(execute(Context, %{"tokens" => -3})) =~ "positive integer"
    end
  end

  describe "honcho_profile" do
    setup do
      configure()
    end

    test "reads the card when no card is passed" do
      result = execute(Profile, %{})

      assert text(result) =~ "Prefers terse answers."
      assert result.details.action == :read
      assert_received {:honcho_call, :get_peer_card, {"user", _opts}}
    end

    test "replaces the card and echoes exactly what was written" do
      result = execute(Profile, %{"card" => ["Ships on Mondays.", "Runs Arch."]})

      assert result.details.action == :write
      assert result.details.card == ["Ships on Mondays.", "Runs Arch."]
      assert text(result) =~ "Ships on Mondays."
      assert text(result) =~ "Runs Arch."
      assert_received {:honcho_call, :set_peer_card, {"user", card, _opts}}
      assert card == ["Ships on Mondays.", "Runs Arch."]
    end

    test "refuses to erase the card, and refuses malformed entries" do
      assert error(execute(Profile, %{"card" => []})) =~ "erase"
      assert error(execute(Profile, %{"card" => "one fact"})) =~ "array of strings"
      assert error(execute(Profile, %{"card" => ["fine", 7]})) =~ "non-empty string"
      assert error(execute(Profile, %{"card" => ["fine", "  "]})) =~ "non-empty string"

      refute_received {:honcho_call, :set_peer_card, _payload}
    end
  end

  describe "honcho_conclude" do
    setup do
      configure()
    end

    test "records a conclusion as the assistant observing the user" do
      result = execute(Conclude, %{"conclusion" => "Never deploys on Fridays."})

      assert text(result) =~ "Never deploys on Fridays."
      assert result.details.action == :create
      assert_received {:honcho_call, :create_conclusions, [conclusion]}
      assert conclusion.observer_id == "lemon"
      assert conclusion.observed_id == "user"
      assert conclusion.content == "Never deploys on Fridays."
      assert is_binary(conclusion.session_id)
    end

    test "deletes a conclusion by id" do
      result = execute(Conclude, %{"delete_id" => "con_123"})

      assert text(result) =~ "con_123"
      assert result.details.action == :delete
      assert_received {:honcho_call, :delete_conclusion, "con_123"}
    end

    test "searches stored conclusions and renders each one with its id" do
      result = execute(Conclude, %{"query" => "fridays"})

      assert text(result) =~ "con_42"
      assert text(result) =~ "Never deploys on Fridays."
      # The id is only useful if the model is told what to do with it.
      assert text(result) =~ "delete_id"
      assert result.details.action == :query
      assert result.details.count == 1

      assert_received {:honcho_call, :query_conclusions, {"fridays", opts}}
      assert opts[:observer_id] == "lemon"
      assert opts[:observed_id] == "user"
      assert opts[:top_k] == 10
    end

    test "says so plainly when a search matches nothing" do
      result = execute(Conclude, %{"query" => "nothing"})

      assert text(result) =~ "No stored conclusions"
      assert result.details.count == 0
      assert result.details.excerpts == []
    end

    test "caps top_k and passes it through" do
      execute(Conclude, %{"query" => "fridays", "top_k" => 5_000})

      assert_received {:honcho_call, :query_conclusions, {_query, opts}}
      assert opts[:top_k] == 50
    end

    test "rejects a top_k that is not a positive integer" do
      assert error(execute(Conclude, %{"query" => "x", "top_k" => 0})) =~ "positive integer"
      assert error(execute(Conclude, %{"query" => "x", "top_k" => "many"})) =~ "positive integer"

      refute_received {:honcho_call, :query_conclusions, _payload}
    end

    test "requires exactly one of conclusion, query, and delete_id" do
      both = %{"conclusion" => "A fact.", "delete_id" => "con_123"}

      assert error(execute(Conclude, both)) =~ "exactly one"

      assert error(execute(Conclude, %{"conclusion" => "A fact.", "query" => "x"})) =~
               "exactly one"

      assert error(execute(Conclude, %{"query" => "x", "delete_id" => "con_1"})) =~ "exactly one"
      assert error(execute(Conclude, %{})) =~ "exactly one"
      assert error(execute(Conclude, %{"conclusion" => "   "})) =~ "exactly one"
      assert error(execute(Conclude, %{"delete_id" => 7})) =~ "must be a string"
      assert error(execute(Conclude, %{"query" => 7})) =~ "must be a string"

      refute_received {:honcho_call, _name, _payload}
    end
  end

  # A model-authored parameter is routinely a verbatim paste of the user's
  # message, so every one of these tools can carry a pasted credential to a
  # third-party service. Two properties per tool: what does reach the wire is cut
  # to the documented cap, and what looks like a secret does not reach it at all.
  describe "the egress screen" do
    setup do
      configure()
    end

    test "honcho_search clips a long query to 1,500 characters on the wire" do
      execute(Search, %{"query" => long()})

      assert_received {:honcho_call, :workspace_search, {query, _opts}}
      assert String.length(query) == 1_500
    end

    test "honcho_search refuses a secret-shaped query and calls nothing" do
      Enum.each([secret(), probe()], fn query ->
        result = execute(Search, %{"query" => query})

        assert_refusal(result, "query")
        assert text(result) =~ "no search ran"
      end)

      refute_received {:honcho_call, _name, _payload}
    end

    test "honcho_reasoning clips a long query to 1,500 characters on the wire" do
      execute(Reasoning, %{"query" => long()})

      assert_received {:honcho_call, :chat, {_peer, query, _opts}}
      assert String.length(query) == 1_500
    end

    test "honcho_reasoning refuses a secret-shaped query and calls nothing" do
      Enum.each([secret(), probe()], fn query ->
        result = execute(Reasoning, %{"query" => query})

        assert_refusal(result, "query")
        assert text(result) =~ "no question was asked"
      end)

      refute_received {:honcho_call, _name, _payload}
    end

    test "honcho_conclude clips a long search query to 1,500 characters on the wire" do
      execute(Conclude, %{"query" => long()})

      assert_received {:honcho_call, :query_conclusions, {query, _opts}}
      assert String.length(query) == 1_500
    end

    test "honcho_conclude refuses a secret-shaped query and calls nothing" do
      Enum.each([secret(), probe()], fn query ->
        result = execute(Conclude, %{"query" => query})

        assert_refusal(result, "query")
        assert text(result) =~ "no search ran"
      end)

      refute_received {:honcho_call, _name, _payload}
    end

    # A conclusion is rejected rather than clipped at its cap — half a durable
    # fact reads as a whole one forever after — so the boundary is what is
    # asserted: exactly at the cap goes through whole, one over it never leaves.
    test "honcho_conclude sends a conclusion up to its 2,000-character cap and no further" do
      body = String.duplicate("a", 2_000)

      execute(Conclude, %{"conclusion" => body})

      assert_received {:honcho_call, :create_conclusions, [conclusion]}
      assert String.length(conclusion.content) == 2_000

      assert error(execute(Conclude, %{"conclusion" => long()})) =~ "at most 2000 characters"
      refute_received {:honcho_call, :create_conclusions, _payload}
    end

    test "honcho_conclude refuses a secret-shaped conclusion and records nothing" do
      result = execute(Conclude, %{"conclusion" => "They told me #{secret()}"})

      assert_refusal(result, "conclusion")
      assert text(result) =~ "the conclusion was not recorded"
      refute_received {:honcho_call, _name, _payload}
    end

    test "honcho_profile sends a card line up to its 500-character cap and no further" do
      line = String.duplicate("a", 500)

      execute(Profile, %{"card" => [line]})

      assert_received {:honcho_call, :set_peer_card, {"user", [sent], _opts}}
      assert String.length(sent) == 500

      assert error(execute(Profile, %{"card" => [long()]})) =~ "at most 500 characters"
      refute_received {:honcho_call, :set_peer_card, _payload}
    end

    # A card write is a replace, so a screen that dropped the offending line
    # would delete it from the stored card. The whole write is refused instead.
    test "honcho_profile refuses the whole card when one line looks like a secret" do
      result = execute(Profile, %{"card" => ["Ships on Mondays.", secret()]})

      assert_refusal(result, "card")
      assert text(result) =~ "was not replaced"
      refute_received {:honcho_call, _name, _payload}
    end

    test "an ordinary input still reaches Honcho unmodified" do
      execute(Search, %{"query" => "cold cache"})
      execute(Reasoning, %{"query" => "how do they like PRs described?"})
      execute(Conclude, %{"query" => "fridays"})
      execute(Conclude, %{"conclusion" => "Never deploys on Fridays."})
      execute(Profile, %{"card" => ["Ships on Mondays."]})

      assert_received {:honcho_call, :workspace_search, {"cold cache", _search_opts}}
      assert_received {:honcho_call, :chat, {_peer, "how do they like PRs described?", _opts}}
      assert_received {:honcho_call, :query_conclusions, {"fridays", _query_opts}}
      assert_received {:honcho_call, :create_conclusions, [conclusion]}
      assert conclusion.content == "Never deploys on Fridays."
      assert_received {:honcho_call, :set_peer_card, {"user", ["Ships on Mondays."], _card_opts}}
    end
  end

  describe "when uploads are disabled (save_messages? false)" do
    setup do
      configure(save_messages: false)
    end

    test "honcho_profile still reads the card" do
      result = execute(Profile, %{})

      assert result.details.action == :read
      assert text(result) =~ "Prefers terse answers."
      assert_received {:honcho_call, :get_peer_card, {"user", _opts}}
    end

    test "honcho_profile refuses to replace the card and calls nothing" do
      result = execute(Profile, %{"card" => ["Ships on Mondays."]})

      assert %AgentToolResult{details: %{error: :uploads_disabled, action: :write}} = result
      assert text(result) =~ "LEMON_HONCHO_SAVE_MESSAGES"
      assert text(result) =~ "not replaced"

      refute_received {:honcho_call, :set_peer_card, _payload}
    end

    test "honcho_conclude refuses to create or to delete, and calls nothing" do
      created = execute(Conclude, %{"conclusion" => "Never deploys on Fridays."})
      deleted = execute(Conclude, %{"delete_id" => "con_123"})

      assert %AgentToolResult{details: %{error: :uploads_disabled, action: :create}} = created
      assert %AgentToolResult{details: %{error: :uploads_disabled, action: :delete}} = deleted
      assert text(created) =~ "LEMON_HONCHO_SAVE_MESSAGES"
      assert text(created) =~ "not recorded"
      assert text(deleted) =~ "not deleted"

      refute_received {:honcho_call, :create_conclusions, _payload}
      refute_received {:honcho_call, :delete_conclusion, _payload}
    end

    test "honcho_conclude still searches stored conclusions" do
      result = execute(Conclude, %{"query" => "fridays"})

      assert result.details.action == :query
      assert text(result) =~ "Never deploys on Fridays."
      assert_received {:honcho_call, :query_conclusions, _payload}
    end
  end

  describe "when uploads are enabled (save_messages? true)" do
    setup do
      configure(save_messages: true)
    end

    test "every write reaches Honcho" do
      assert execute(Profile, %{"card" => ["Ships on Mondays."]}).details.action == :write
      assert execute(Conclude, %{"conclusion" => "A fact."}).details.action == :create
      assert execute(Conclude, %{"delete_id" => "con_123"}).details.action == :delete

      assert_received {:honcho_call, :set_peer_card, {"user", ["Ships on Mondays."], _opts}}
      assert_received {:honcho_call, :create_conclusions, [_conclusion]}
      assert_received {:honcho_call, :delete_conclusion, "con_123"}
    end
  end

  ## Helpers

  # One assertion for all five schemas: the model is shown a JSON object schema
  # whose `required` names only properties that are actually declared. A
  # `required` entry with no property is the failure that makes a provider
  # reject an entire tool list, so it is checked rather than reviewed.
  defp assert_valid_tool(%AgentTool{} = tool, expected_name) do
    assert tool.name == expected_name
    assert String.trim(tool.description) != ""
    assert String.trim(tool.label) != ""
    assert is_function(tool.execute, 4)

    assert %{"type" => "object", "properties" => properties, "required" => required} =
             tool.parameters

    assert is_map(properties)
    assert is_list(required)
    assert Enum.all?(required, &is_binary/1)
    assert Enum.all?(required, &Map.has_key?(properties, &1))

    Enum.each(properties, fn {name, schema} ->
      assert is_binary(name)
      assert is_binary(schema["type"])
      assert String.trim(schema["description"]) != ""
    end)
  end

  defp configure(overrides \\ []) do
    Application.put_env(:lemon_honcho, :api_key, "sk-test")
    Application.put_env(:lemon_honcho, :user_peer, "user")
    Application.put_env(:lemon_honcho, :ai_peer, "lemon")
    Enum.each(overrides, fn {key, value} -> Application.put_env(:lemon_honcho, key, value) end)

    :ok
  end

  defp execute(module, params), do: module.execute("call-1", params, nil, nil, @opts)

  # The shape `LemonMemory.Safety.contains_secret?/1` actually matches: a
  # `name: value` pair whose name is one of its credential words.
  defp secret, do: "api_key: hunter2please"

  # Longer than every cap in this app, and carrying nothing that should stop it:
  # what a clip does to an over-long but ordinary input.
  defp long, do: String.duplicate("a", 9_066)

  # The probe the review measured with: long enough to be clipped, with the
  # secret at the front so it survives the clip. A path that clips but does not
  # screen sends the credential; a path that screens sends nothing.
  defp probe, do: secret() <> " " <> long()

  # A refusal is a normal tool result, not an error tuple and not a raise: the
  # turn has to survive for the model to be able to rephrase. It names the
  # parameter and never the value.
  defp assert_refusal(result, parameter) do
    assert %AgentToolResult{details: %{error: :withheld, parameter: ^parameter}} = result
    assert text(result) =~ "credential"
    assert text(result) =~ parameter
    refute text(result) =~ "hunter2please"
  end

  defp text(%AgentToolResult{content: [%{text: text} | _rest]}), do: text

  defp error(%AgentToolResult{details: %{error: error}}), do: error

  # The application starts a manager under the real client; a test that needs a
  # mapped session runs its own instead.
  defp stop_application_manager do
    if is_pid(Process.whereis(SessionManager)) do
      Supervisor.terminate_child(LemonHoncho.Supervisor, SessionManager)
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  defp flush do
    receive do
      {:honcho_call, _name, _payload} -> flush()
    after
      0 -> :ok
    end
  end

  defp restore_env({key, nil}), do: System.delete_env(key)
  defp restore_env({key, value}), do: System.put_env(key, value)

  defp restore_app_env({key, :error}), do: Application.delete_env(:lemon_honcho, key)
  defp restore_app_env({key, {:ok, value}}), do: Application.put_env(:lemon_honcho, key, value)
end
