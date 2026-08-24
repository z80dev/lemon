defmodule LemonHoncho.Client.Tripwire do
  @moduledoc """
  A `LemonHoncho.Client` stand-in that refuses every request and says why.

  This is the second half of the test suite's opt-out, and it exists because the
  first half is defeatable. `config/test.exs` pins `enabled: false`, but
  `LemonHoncho.Config` resolves *OS environment first*, so a developer with
  `LEMON_HONCHO_ENABLED=true` exported in a shell rc — an entirely reasonable
  thing to have for a real Honcho install — turns the suite back on: the memory
  provider registers, the context contributor registers, and every memory search
  in the umbrella fans out to a live workspace carrying the suite's queries.

  Configuration cannot stop that on its own, because the variable that would
  stop it is the one being overridden. So the test environment also pins
  `config :lemon_honcho, :client` here. Application env has no OS-environment
  fallback, which makes this pin unloseable from a shell: even if activation is
  forced, the transport is not the real one and no request can leave the
  machine. Belt, and separately, braces.

  ## Why it lives in `lib/` rather than `test/support/`

  The umbrella's convention for a test-only module is `test/support`, loaded by
  the owning app's `test_helper.exs` or through `elixirc_paths(:test)`. Both are
  scoped to *one app's* suite, and the hole this closes is umbrella-wide: it is
  `mix test` in `coding_agent`, or `lemon_gateway`, or anywhere memory is
  searched, that would otherwise reach a live Honcho. Only a compiled module in
  `lib/` is resolvable from every app's test run, and a module that fails closed
  is a reasonable thing for a library to ship in any case — an operator who
  wants an install that definitely cannot talk to Honcho can pin the same value.

  ## What a call gets

  A `RuntimeError` naming the function that tried to leave, from every function
  in the client's surface. Raising rather than returning `{:error, _}` is the
  point: every caller in this app is written to degrade quietly on an error
  tuple, so an error tuple here would hide the very thing the tripwire exists to
  make visible. The raise is still contained — `LemonHoncho.SessionManager`
  rescues its refresh, `LemonHoncho.MemoryProvider` rescues its search — so a
  tripped wire fails the suite loudly where it is asserted and degrades to "no
  memory" everywhere else, rather than taking a test run down.
  """

  @doc false
  @spec ensure_workspace(term()) :: no_return()
  @spec ensure_workspace(term(), keyword()) :: no_return()
  def ensure_workspace(_config, _opts \\ []), do: blocked!(:ensure_workspace)

  @doc false
  @spec ensure_peer(term(), term()) :: no_return()
  def ensure_peer(_config, _peer_id), do: blocked!(:ensure_peer)

  @doc false
  @spec ensure_session(term(), term(), term()) :: no_return()
  def ensure_session(_config, _session_id, _peer_specs), do: blocked!(:ensure_session)

  @doc false
  @spec set_peer_config(term(), term(), term(), term()) :: no_return()
  def set_peer_config(_config, _session_id, _peer_id, _flags), do: blocked!(:set_peer_config)

  @doc false
  @spec add_messages(term(), term(), term()) :: no_return()
  def add_messages(_config, _session_id, _messages), do: blocked!(:add_messages)

  @doc false
  @spec session_context(term(), term()) :: no_return()
  @spec session_context(term(), term(), keyword()) :: no_return()
  def session_context(_config, _session_id, _opts \\ []), do: blocked!(:session_context)

  @doc false
  @spec peer_context(term(), term()) :: no_return()
  @spec peer_context(term(), term(), keyword()) :: no_return()
  def peer_context(_config, _peer_id, _opts \\ []), do: blocked!(:peer_context)

  @doc false
  @spec chat(term(), term(), term()) :: no_return()
  @spec chat(term(), term(), term(), keyword()) :: no_return()
  def chat(_config, _peer_id, _query, _opts \\ []), do: blocked!(:chat)

  @doc false
  @spec session_search(term(), term(), term()) :: no_return()
  @spec session_search(term(), term(), term(), keyword()) :: no_return()
  def session_search(_config, _session_id, _query, _opts \\ []), do: blocked!(:session_search)

  @doc false
  @spec workspace_search(term(), term()) :: no_return()
  @spec workspace_search(term(), term(), keyword()) :: no_return()
  def workspace_search(_config, _query, _opts \\ []), do: blocked!(:workspace_search)

  @doc false
  @spec get_peer_card(term(), term()) :: no_return()
  @spec get_peer_card(term(), term(), keyword()) :: no_return()
  def get_peer_card(_config, _peer_id, _opts \\ []), do: blocked!(:get_peer_card)

  @doc false
  @spec set_peer_card(term(), term(), term()) :: no_return()
  @spec set_peer_card(term(), term(), term(), keyword()) :: no_return()
  def set_peer_card(_config, _peer_id, _card, _opts \\ []), do: blocked!(:set_peer_card)

  @doc false
  @spec create_conclusions(term(), term()) :: no_return()
  def create_conclusions(_config, _conclusions), do: blocked!(:create_conclusions)

  @doc false
  @spec query_conclusions(term(), term()) :: no_return()
  @spec query_conclusions(term(), term(), keyword()) :: no_return()
  def query_conclusions(_config, _query, _opts \\ []), do: blocked!(:query_conclusions)

  @doc false
  @spec delete_conclusion(term(), term()) :: no_return()
  def delete_conclusion(_config, _conclusion_id), do: blocked!(:delete_conclusion)

  # One message for every entry point, naming the call, so a tripped wire in a
  # far-away suite reads as "this test reached for Honcho" rather than as an
  # arbitrary failure inside a stub.
  @spec blocked!(atom()) :: no_return()
  defp blocked!(function) do
    raise """
    honcho: a request (#{function}) was attempted through LemonHoncho.Client.Tripwire.

    The test environment pins `config :lemon_honcho, :client` to this module so
    that no suite can reach a real Honcho deployment. Something activated the
    integration anyway — most likely HONCHO_API_KEY or LEMON_HONCHO_ENABLED
    exported in this shell, which `LemonHoncho.Config` reads ahead of
    application env.

    A test that means to exercise the client should set its own stub with
    `Application.put_env(:lemon_honcho, :client, MyStub)`.
    """
  end
end
