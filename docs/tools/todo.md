# Todo Plans

`todo` manages the selected branch's session plan. `action: "write"` replaces the
complete list; `read`, `progress`, and `actionable` are read-only views. Include
all items you want to retain, including terminal tasks. An empty array clears
the plan.

## Entries

Only `content` is required. `status` defaults to `pending` and `priority` defaults
to `medium` (`high`, `medium`, `low`). An omitted ID reuses the preceding
same-content task's unclaimed ID or generates one. Keep the returned ID when
renaming a task. Duplicate explicit IDs reject the write.

| Status | Meaning | Actionable? |
| --- | --- | --- |
| `pending` | Ready to start once dependencies complete | Yes, if dependencies complete |
| `in_progress` | Currently active | Yes, if dependencies complete |
| `completed` | Finished successfully | No |
| `blocked` | Waiting on an external prerequisite | No |
| `abandoned` | Intentionally dropped, not completed | No |

Items may include a `phase` string to group work and a `blocker` string explaining
why a blocked task cannot proceed. These optional fields, IDs and priorities
round-trip through the session journal. Todo results and plan projections retain
blocked and abandoned statuses rather than disguising them as pending/completed.
The terminal client groups native checklists by phase and shows blocker notes.

```json
{"action":"write","todos":[
  {"id":"inspect","content":"Inspect the deployment","status":"completed","phase":"Investigate"},
  {"id":"deploy","content":"Deploy the fix","status":"blocked","blocker":"Need production access","phase":"Release","priority":"high"},
  {"id":"old","content":"Try the old approach","status":"abandoned"}
]}
```

Every successful write keeps only the **first** `in_progress` item active and
changes later `in_progress` items to `pending`, preserving list order and other
fields. It does not automatically start a pending item.

## Counts and views

`progress` counts all five statuses and includes every item in `total`.
`percentage` is completed items divided by total, rounded down; abandoning an item
does not falsely mark it completed. `actionable` excludes blocked, abandoned and
completed items, checks dependencies, and retains priority ordering. Its details
include the full status counts and complete plan as well as the actionable list.
Open-task titles exclude completed and abandoned items.

Session branch navigation, rewind and resume restore the journaled plan, including
its statuses and optional notes. The in-memory TodoStore is a projection, not a
second authority. ACP plan updates preserve Lemon's five statuses and optional
phase/blocker fields as well.
