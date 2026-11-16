# Pre-DurableTable DETS objects: no envelope, version tag, or expiration field.
# Tests create the files using DETS directly, never a migrated application writer.
%{
  tasks: [
    {"task-running",
     %{
       id: "task-running",
       status: :running,
       agent_state: :running,
       auto_followup_join_tokens: [:old_join],
       inserted_at: 1
     }, [{:text, "retained"}]},
    {"task-tracking", %{id: "task-tracking", status: :tracking_lost}, []},
    {"task-background", %{id: "task-background", status: :queued, kind: :background_command}, []},
    {"task-queued", %{id: "task-queued", status: :queued, inserted_at: 1}, []},
    {"task-done", %{id: "task-done", status: :completed, completed_at: 1, result: "unchanged"},
     [{:done, "unchanged"}]}
  ],
  processes: [
    {"process-running",
     %{
       id: "process-running",
       status: :running,
       inserted_at: 1,
       output: %{received_bytes: 8, retained_bytes: 4, discarded_bytes: 4}
     }, ["new", "old"]},
    {"process-held",
     %{
       id: "process-held",
       status: :running,
       owner: "owner",
       launch_fingerprint: "held-fingerprint",
       capacity_held: true,
       termination_confirmed: false,
       inserted_at: 1
     }, []},
    {"process-queued",
     %{
       id: "process-queued",
       status: :queued,
       launch_fingerprint: "queued-fingerprint",
       inserted_at: 1
     }, []},
    {"process-done",
     %{id: "process-done", status: :completed, completed_at: 1, output: %{finalized: true}},
     ["tail"]},
    {"process-cleared",
     %{
       id: "process-cleared",
       status: :cleared,
       launch_fingerprint: "cleared-fingerprint",
       capacity_held: false,
       termination_confirmed: true,
       completed_at: 1
     }, []}
  ],
  runs: [
    {"run-running",
     %{id: "run-running", status: :running, children: ["run-done"], budget: %{tokens_used: 17}}},
    {"run-done",
     %{
       id: "run-done",
       status: :completed,
       completed_at: 1,
       result: %{text: "unchanged"},
       parent: "run-running"
     }}
  ],
  questions: [
    {"question-waiting",
     %{
       id: "question-waiting",
       status: :waiting,
       child_scope_id: "child",
       parent_session_key: "parent",
       parent_agent_id: "agent",
       delivery_pending: false
     }, [{:created, "retained"}]},
    {"question-done",
     %{id: "question-done", status: :answered, completed_at: 1, answer: "unchanged"},
     [{:answered, "unchanged"}]}
  ]
}
