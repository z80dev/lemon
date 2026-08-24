defmodule LemonHoncho.Tools.Common do
  @moduledoc """
  The plumbing every Honcho agent tool shares: gating, scoping, and the two
  results that are not about any one tool's subject.

  The five tools in `LemonHoncho.Tools.*` answer different questions, but they
  all have to do the same four things first — decide whether the integration is
  in a state that permits the call at all, work out which Honcho session and
  which pair of peers the call belongs to, reach the client through the seam
  tests substitute at, and turn a refusal into a result the model can read.
  None of that is tool-specific, and all of it is load-bearing: a tool that
  scopes differently from its neighbours would silently read one session and
  write another.

  It is a plain module of public functions rather than a `use` macro. Nothing
  here varies per tool — no function closes over a module attribute or a
  callback — so injection would buy only a shorter call site, and would cost
  the two things that matter more: these functions would stop being greppable
  from the tools that use them, and they could not be tested directly, which is
  what `LemonHoncho.ToolsCommonTest` does with the precedence rule below.

  ## The session-key precedence rule lives here

  `session_key/1` states it once: the first present of `:session_key`,
  `:session_id`, `:cwd`. `LemonHoncho.SessionManager` and
  `LemonHoncho.ContextContributor` each restate it in their own terms because
  they derive it from a request map rather than a keyword list and run before
  this module is reachable — but they restate a rule that is *defined* here,
  and a change to the manager's keying has to be reflected in exactly those two
  places plus this one, not in five copies scattered through the tools.
  """

  require Logger

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias LemonHoncho.{Config, SessionManager, SessionName}

  @typedoc """
  Which Honcho session and peers a tool call belongs to.

  `mapped?` distinguishes a session id the manager resolved from one derived
  locally, which is the difference between "Honcho has never heard of this
  session" and "this session is empty" — see `scope/2`.
  """
  @type scope :: %{
          session_id: String.t(),
          mapped?: boolean(),
          peers: %{user: String.t(), ai: String.t()}
        }

  @typedoc "The access a call needs; see `gate/2`."
  @type access :: :read | :write

  @doc """
  Whether a tool call may proceed, for the access it needs.

  Registration is unconditional — every Honcho tool exists on every host — so
  both of the read gates are enforced here rather than by hiding the tool: a
  model that asked a question deserves an answer saying why it cannot be
  answered, not a tool that was never offered.

  `:read` checks the two conditions that switch the whole integration off: an
  unconfigured Honcho (`{:error, :not_configured}`) and `recall_mode: :context`,
  which serves memory through the system prompt only
  (`{:error, :context_only}`). `:write` adds `save_messages?`, since
  `LEMON_HONCHO_SAVE_MESSAGES=false` is documented as making the integration
  read-only and that promise has to hold at every point that changes Honcho's
  store (`{:error, :uploads_disabled}`).

  The two writing tools call this twice: once with `:read` before the
  parameters are parsed, and once with `:write` after, because their
  uploads-disabled answer names the action that was refused and cannot do that
  until the action is known.
  """
  @spec gate(Config.t(), access()) ::
          :ok | {:error, :not_configured | :context_only | :uploads_disabled}
  def gate(config, access \\ :read)

  def gate(%Config{} = config, access) when access in [:read, :write] do
    cond do
      not Config.configured?(config) -> {:error, :not_configured}
      config.recall_mode == :context -> {:error, :context_only}
      access == :write and not config.save_messages? -> {:error, :uploads_disabled}
      true -> :ok
    end
  end

  @doc """
  The Honcho session and peers the tool options in `opts` name.

  `LemonHoncho.SessionManager` keys its sessions by `session_key/1`, so asking
  it with the same key is what makes a tool call land on the session the
  injected context came from — and, through `peers/2`, on the same pair of
  peers that context was assembled for.

  When that lookup fails — a tool called outside a session, or before the first
  refresh resolved the id — `LemonHoncho.SessionName` derives the id the
  manager itself would have derived, which is the same string under every
  strategy but `:per_session`. `mapped?` records which of the two happened,
  because a derived id may name a session Honcho holds no messages for, and a
  search of it would return nothing and read as "the user never mentioned it".
  """
  @spec scope(Config.t(), keyword()) :: scope()
  def scope(%Config{} = config, opts) do
    key = session_key(opts) || latest_session_key()

    case key && SessionManager.honcho_session_id(key) do
      {:ok, session_id} ->
        %{session_id: session_id, mapped?: true, peers: peers(config, key)}

      _other ->
        %{session_id: derived_session_id(config, opts), mapped?: false, peers: peers(config, nil)}
    end
  end

  @doc """
  The session key `opts` names: the first present of `:session_key`,
  `:session_id`, `:cwd`, or `nil` when it names none of them.

  This is the rule `LemonHoncho.SessionManager` keys its sessions by, stated
  for a keyword list; the manager and `LemonHoncho.ContextContributor` state
  the same order for a request map. "Present" means a non-blank binary
  (`present?/1`), so an empty `:session_key` falls through to `:session_id`
  rather than keying a session on `""`.
  """
  @spec session_key(keyword()) :: String.t() | nil
  def session_key(opts) do
    [Keyword.get(opts, :session_key), Keyword.get(opts, :session_id), Keyword.get(opts, :cwd)]
    |> Enum.find(&present?/1)
  end

  @doc """
  The key of the most recently served session, or `nil` when none is tracked.

  The fallback for a tool called with no session key at all — a REPL, a test, a
  host that builds its tools without options. Guessing the most recent session
  is better than guessing none, because the alternative is a derived id that
  may name an empty session.

  This is the one call in the tool path that asks `SessionManager.sessions/0`,
  which the manager's own documentation calls the wrong thing to ask on the
  turn path: it builds a list of every tracked session (up to the manager's cap
  of 500) inside the server and copies it to the caller. That is affordable
  here and would not be on the turn path — this runs once per tool call, only
  when no key was supplied, and the manager exposes no cheaper accessor for
  "which session was served last" (`cold?/1` answers a different question, and
  `honcho_session_id/1` and `peers/1` both need the key we are looking for).
  Keeping it to one call site is what makes adding such an accessor a one-line
  change later. The scan itself is a single pass rather than a sort, since only
  the maximum is wanted.
  """
  @spec latest_session_key() :: String.t() | nil
  def latest_session_key do
    SessionManager.sessions()
    |> Enum.filter(&is_binary(&1.honcho_session_id))
    |> case do
      [] -> nil
      tracked -> tracked |> Enum.max_by(&(&1.last_context_at_ms || 0)) |> Map.fetch!(:session_key)
    end
  end

  @doc """
  The Honcho session id `opts` resolves to without consulting the manager.

  Used when the manager has no mapping for the key; see `scope/2`.
  """
  @spec derived_session_id(Config.t(), keyword()) :: String.t()
  def derived_session_id(%Config{} = config, opts) do
    SessionName.resolve(config,
      cwd: Keyword.get(opts, :cwd),
      session_key: Keyword.get(opts, :session_key),
      session_id: Keyword.get(opts, :session_id)
    )
  end

  @doc """
  The user and assistant peers for `key`, falling back to the configured pair.

  The manager records the peers a session was initialised with, and reading
  them back is what keeps a conclusion written by a tool call and one derived
  from injected context on the same pair even after an operator changes
  `HONCHO_PEER` mid-run. `nil` — or a key the manager does not know — yields
  the configured pair, which is what the session would have been given anyway.
  """
  @spec peers(Config.t(), String.t() | nil) :: %{user: String.t(), ai: String.t()}
  def peers(%Config{} = config, key) do
    case key && SessionManager.peers(key) do
      {:ok, peers} -> peers
      _other -> %{user: config.user_peer, ai: config.ai_peer}
    end
  end

  @doc """
  The Honcho client module.

  Resolved from application env on every call rather than at compile time,
  because that is the seam tests substitute a stub at — the same one
  `LemonHoncho.SessionManager` resolves its client through.
  """
  @spec client() :: module()
  def client, do: Application.get_env(:lemon_honcho, :client, LemonHoncho.Client)

  @doc """
  Whether `value` is a binary with something in it.

  Blank strings are treated as absent everywhere in this integration: a session
  keyed on `""` would collect every run that failed to name itself.
  """
  @spec present?(term()) :: boolean()
  def present?(value) when is_binary(value), do: String.trim(value) != ""
  def present?(_value), do: false

  @doc """
  The result for a tool called against an unconfigured Honcho.

  `consequence` completes "Honcho memory is not configured, so …" in the
  tool's own terms; the two variables that fix it are named here, because an
  operator who reads this in one tool's output should not find a different
  remedy in another's.
  """
  @spec not_configured(String.t()) :: AgentToolResult.t()
  def not_configured(consequence) do
    text = """
    Honcho memory is not configured, so #{consequence}.

    Set HONCHO_API_KEY for the hosted service, or HONCHO_BASE_URL for a \
    self-hosted deployment.
    """

    result(text, :not_configured)
  end

  @doc """
  The result for a tool called while `recall_mode: :context`.

  `consequence` finishes the sentence opening "…so its tools are inactive" and
  `remedy` finishes "Set LEMON_HONCHO_RECALL_MODE to hybrid or tools to". Both
  are per-tool copy — where the answer already is, and what the model would be
  able to do — while the mode's name, the variable that changes it, and the
  `:context_only` marker live here.
  """
  @spec context_only(String.t(), String.t()) :: AgentToolResult.t()
  def context_only(consequence, remedy) do
    text =
      "Honcho is in context-only mode (recall_mode: context), so its tools are inactive" <>
        consequence <> " Set LEMON_HONCHO_RECALL_MODE to hybrid or tools to " <> remedy <> ".\n"

    result(text, :context_only)
  end

  @doc """
  The result for a request that failed, reported to the model as prose.

  Nothing a Honcho tool does is worth ending a turn over, so an outage, a bad
  parameter, and a rejected key are all results rather than raises. `tool` is
  the model-facing tool name and appears in the debug line, which is what makes
  a log entry traceable back to a call site now that this lives in one place.
  """
  @spec failure(String.t(), String.t()) :: AgentToolResult.t()
  def failure(tool, message) do
    Logger.debug("honcho: #{tool} returned an error result: #{message}")

    %AgentToolResult{content: [%TextContent{text: message}], details: %{error: message}}
  end

  @doc "The message for a Honcho call rejected with HTTP 401."
  @spec unauthorized_message() :: String.t()
  def unauthorized_message do
    "Honcho rejected the credentials (HTTP 401). Check HONCHO_API_KEY."
  end

  @doc """
  The message for a Honcho call that failed with `status`.

  The body is inspected rather than parsed: it is whatever the service chose to
  send, and an operator debugging a 500 wants to see it as it arrived.
  """
  @spec api_message(non_neg_integer(), term()) :: String.t()
  def api_message(status, body) do
    "Honcho API error (HTTP #{status}): #{inspect(body)}"
  end

  defp result(text, error) do
    %AgentToolResult{content: [%TextContent{text: text}], details: %{error: error}}
  end
end
