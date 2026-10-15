defmodule CodingAgent.Session.Recovery do
  @moduledoc """
  Read-only selected-branch input for control-plane reconciliation.

  The live session serializes the journal read, but its agent and other domain
  owners are independent. Consumers must compare reads and fence events arriving
  during reconciliation; this is not a cross-owner transaction or replay cursor.

  The control-plane JSON response is bounded, not this internal owner read.
  Journal entries remain complete so interrupted tools and the selected turn's
  exact provenance can be reconciled. Collecting and hashing a large existing
  transcript can copy/work proportionally to its retained size. This read does
  not claim a bounded owner-message size or a linearizable multi-owner snapshot.
  """

  alias CodingAgent.SessionManager

  def snapshot(manager, opts \\ []) do
    entries = SessionManager.get_branch(manager)
    partial = Keyword.get(opts, :partial)
    messages = Keyword.get(opts, :messages)
    streaming = Keyword.get(opts, :streaming, false)
    plan = CodingAgent.Session.Planning.status(manager)

    value = %{
      session_id: manager.header.id,
      branch_id: manager.leaf_id,
      run_id: Keyword.get(opts, :run_id),
      entries: entries,
      partial: partial,
      pending: Keyword.get(opts, :pending, []),
      streaming: streaming,
      live: Keyword.has_key?(opts, :streaming),
      failed: Keyword.get(opts, :failed, false),
      cwd: manager.header.cwd,
      plan: plan
    }

    revision =
      {value, messages, Keyword.get(opts, :turn)}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Map.put(value, :revision, revision)
  end
end
