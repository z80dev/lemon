defmodule CodingAgent.Session.Planning do
  @moduledoc """
  Branch-aware plan mode, modelled on omp's `/plan`.

  Plan mode is a toggle recorded as `"lemon.plan"` journal entries. While it is
  on, the working tree is read-only: tools outside the read-only set return a
  plan-mode error, except that `write`/`edit` may create or update Markdown
  files in the session-private plan directory (outside the working tree). The
  agent drafts `<slug>-plan.md` there and calls `propose_plan`, which asks the
  user through the exec-approval surface. Approval appends a code-mode entry
  carrying the approved plan, reopens the gate for the rest of the run, swaps
  the system prompt and steers the running loop into execution. Refinement
  keeps plan mode on. Leaving plan mode with `/plan` never approves anything.

  The gate is an `:atomics` cell shared with the tool wrappers, so the
  plan-to-code transition takes effect inside the run that proposed the plan.
  Entering or leaving plan mode explicitly is refused while a turn is running.

  Legacy entries (`status`/`revision` from the reviewed-artifact lifecycle) are
  read as: `mode: "plan"` stays in plan mode, `status: "approved"` becomes the
  approved-plan reference, and their artifact path is the existing plan file.
  """

  alias CodingAgent.Extensions.ToolHooks
  alias CodingAgent.Security.SecretObfuscator
  alias CodingAgent.Messages.CustomMessage
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry
  alias CodingAgent.Tools.{Edit, Write}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @entry_type "lemon.plan"
  @max_bytes 32_768
  @propose_tool "propose_plan"
  @plan_write_tools ["write", "edit"]
  # Tools that cannot change the working tree or system. Everything else is
  # blocked at execution time while plan mode is on. `tool_search` only reads the
  # session's frozen tool catalog.
  @read_only_tools ~w(read read_skill recall grep find ls websearch webfetch ask tool_search)
  @resolve_timeout_ms 30_000

  def context_boundary?(%SessionEntry{type: :custom, custom_type: @entry_type}), do: true
  def context_boundary?(_), do: false

  @doc "Shared gate read by plan-mode tool wrappers (1 = plan mode active)."
  def new_gate, do: :atomics.new(1, signed: false)

  defp empty, do: %{"mode" => "code", "path" => nil, "approved" => nil}

  @doc "Public plan state: mode, current plan file and its Markdown (when readable)."
  def status(session) do
    plan = stored(session)
    %{"mode" => plan["mode"], "path" => plan["path"], "content" => read_plan(plan["path"])}
  end

  @doc "Session-private directory holding this session's plan files."
  def plan_dir(%{header: %{id: id, cwd: cwd}}) do
    Path.join([SessionManager.get_session_dir(cwd), "plans", digest(id)])
  end

  def transition(session, :status, _opts), do: {:ok, status(session), session}

  def transition(session, :enter, _opts) do
    case stored(session) do
      %{"mode" => "plan"} -> {:ok, status(session), session}
      plan -> append(session, %{plan | "mode" => "plan"})
    end
  end

  def transition(session, :exit, _opts) do
    case stored(session) do
      %{"mode" => "plan"} = plan -> append(session, %{plan | "mode" => "code"})
      _ -> {:ok, status(session), session}
    end
  end

  def transition(_session, _action, _opts), do: {:error, :invalid_plan_action}

  defp append(session, plan) do
    session = SessionManager.append_entry(session, SessionEntry.custom(@entry_type, plan))
    {:ok, status(session), session}
  end

  defp stored(%{by_id: entries, leaf_id: leaf}), do: stored_entry(entries, leaf)
  defp stored(_), do: empty()

  defp stored_entry(_entries, nil), do: empty()

  defp stored_entry(entries, id) do
    case Map.get(entries, id) do
      %SessionEntry{type: :custom, custom_type: @entry_type, data: data} when is_map(data) ->
        normalize(data)

      %SessionEntry{parent_id: parent} ->
        stored_entry(entries, parent)

      _ ->
        empty()
    end
  end

  defp normalize(data) do
    %{
      "mode" => if(data["mode"] == "plan", do: "plan", else: "code"),
      "path" => if(is_binary(data["path"]), do: data["path"]),
      "approved" => approved(data)
    }
  end

  defp approved(%{"approved" => %{"content" => content} = approved}) when is_binary(content),
    do: Map.take(approved, ["path", "title", "content"])

  # Legacy reviewed-artifact entry approved with `/approve-plan <revision>`.
  defp approved(%{"status" => "approved", "content" => content} = data) when is_binary(content),
    do: %{"path" => data["path"], "title" => nil, "content" => content}

  defp approved(_), do: nil

  defp read_plan(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} when byte_size(content) <= @max_bytes -> content
      {:ok, content} -> binary_part(content, 0, @max_bytes) <> "\n…"
      _ -> nil
    end
  end

  defp read_plan(_), do: nil

  # ── Runtime configuration ────────────────────────────────────────────────

  @doc """
  Effective tools for `session`; also syncs the shared gate.

  `context` (see `runtime_context/2`) holds `:gate`, `:cwd`, `:session_pid`,
  `:session_id`, `:run_id`, `:session_key`, `:agent_id`, `:hooks`,
  `:secret_obfuscator` and an optional `:approval_request_fun`.
  """
  def tools(base_tools, session, context) do
    plan = stored(session)
    plan? = plan["mode"] == "plan"
    :atomics.put(context.gate, 1, if(plan?, do: 1, else: 0))

    if plan?,
      do: plan_tools(base_tools, Map.merge(context, plan_paths(session, plan))),
      else: base_tools
  end

  @doc """
  Apply the current plan gate to one authorized WASM host target.

  Unlike `tools/3`, this does not add plan-only tools or proposal capabilities
  to the host inventory; it only reuses the normal target's execution guard.
  """
  @spec host_tool(AgentTool.t(), SessionManager.Session.t(), map()) :: AgentTool.t()
  def host_tool(%AgentTool{} = tool, session, context) do
    plan = stored(session)

    if plan["mode"] == "plan",
      do: guard(tool, Map.merge(context, plan_paths(session, plan))),
      else: tool
  end

  @doc "Effective system prompt for `session`."
  def system_prompt(base, session) do
    case stored(session) do
      %{"mode" => "plan"} = plan -> base <> "\n\n" <> plan_prompt(plan_paths(session, plan))
      plan -> base <> approved_prompt(plan["approved"])
    end
  end

  defp plan_paths(session, plan), do: %{plan_dir: plan_dir(session), plan_path: plan["path"]}

  @doc "Re-derive the live session's tools and system prompt from its journal."
  def refresh(state) do
    state = %{state | plan_gate: state.plan_gate || new_gate()}

    tools =
      tools(
        state.base_tools || state.tools || [],
        state.session_manager,
        runtime_context(state, self())
      )

    prompt =
      system_prompt(state.base_system_prompt || state.system_prompt || "", state.session_manager)

    if tools != state.tools, do: :ok = LemonAgent.Agent.set_tools(state.agent, tools)

    if prompt != state.system_prompt,
      do: :ok = LemonAgent.Agent.set_system_prompt(state.agent, prompt)

    %{state | tools: tools, system_prompt: prompt}
  end

  @doc "Tool-wrapper context from session state (or the equivalent init fields)."
  def runtime_context(state, session_pid) do
    %{
      gate: state.plan_gate,
      cwd: state.cwd,
      session_pid: session_pid,
      session_id: state.session_manager.header.id,
      run_id: state.run_id,
      session_key: state.session_key,
      agent_id: state.agent_id,
      hooks: Map.get(state, :hooks, []),
      secret_obfuscator: Map.get(state, :secret_obfuscator),
      plan_write_tools:
        for(
          %AgentTool{name: name} = tool <- Map.get(state, :tools) || [],
          name in @plan_write_tools,
          into: %{},
          do: {name, tool}
        ),
      approval_request_fun: (state.approval_context || %{})[:approval_request_fun]
    }
  end

  @doc """
  Apply the user's decision on a `propose_plan` call.

  `:approve` leaves plan mode with the approved plan as durable context and,
  while a turn is running, steers it into execution under the new prompt.
  `:refine` stays in plan mode and remembers the proposed file.
  """
  def resolve_proposal(state, decision, %{"path" => path} = proposal) do
    plan = stored(state.session_manager)

    if plan["mode"] != "plan" do
      {:error, :not_planning}
    else
      next =
        case decision do
          :approve ->
            %{
              plan
              | "mode" => "code",
                "path" => path,
                "approved" => Map.take(proposal, ["path", "title", "content"])
            }

          :refine ->
            %{plan | "path" => path}
        end

      state =
        if next == plan do
          state
        else
          {:ok, _status, manager} = append(state.session_manager, next)
          refresh(%{state | session_manager: manager})
        end

      if decision == :approve and state.is_streaming do
        LemonAgent.Agent.steer(state.agent, approved_message(path),
          system_prompt: state.system_prompt
        )
      end

      {:ok, state}
    end
  end

  defp approved_message(path) do
    %CustomMessage{
      custom_type: "plan_approved",
      display: false,
      timestamp: System.system_time(:millisecond),
      content:
        "The user approved the plan (#{path}). Plan mode is off and full tool access is " <>
          "restored. Execute the approved plan from the system prompt step by step, " <>
          "verifying each step before the next."
    }
  end

  # ── Plan-mode tools ──────────────────────────────────────────────────────

  defp plan_tools(base_tools, context) do
    # Runtime host lookup projects the current write/edit guards. Do not retain
    # those prior-generation closures inside newly constructed private tools.
    context = Map.delete(context, :plan_write_tools)
    names = MapSet.new(base_tools, & &1.name)

    private_writes =
      Map.new(@plan_write_tools, fn name ->
        {name, intercept_private_tool(plan_only_tool(name, context), context)}
      end)

    context = Map.put(context, :plan_write_tools, private_writes)

    guarded = Enum.map(base_tools, &guard(&1, context))

    # Plan files must stay writable even when the session policy removed the
    # file tools; these instances only ever write inside the plan directory.
    plan_only =
      for name <- @plan_write_tools, not MapSet.member?(names, name) do
        Map.fetch!(private_writes, name)
      end

    guarded ++ plan_only ++ [intercept_private_tool(propose_tool(context), context)]
  end

  defp guard(%AgentTool{name: name} = tool, _context) when name in @read_only_tools, do: tool

  # The disclosure bridge is judged by the tool it reaches, never by its own
  # name: a bridged read stays allowed, a bridged mutation is blocked under its
  # real name.
  defp guard(%AgentTool{name: "tool_invoke", execute: execute} = tool, context) do
    private_writes = Map.get(context, :plan_write_tools, %{})

    wrapped = fn id, params, signal, on_update ->
      target = bridge_target(params)
      args = if is_map(params), do: Map.get(params, "args", %{}), else: %{}

      cond do
        not planning?(context.gate) ->
          execute.(id, params, signal, on_update)

        target in @read_only_tools ->
          execute.(id, params, signal, on_update)

        target in @plan_write_tools and Map.has_key?(private_writes, target) ->
          private_writes[target].execute.(id, args, signal, on_update)

        true ->
          blocked(target || "tool_invoke", context)
      end
    end

    %{tool | execute: wrapped}
  end

  defp guard(%AgentTool{name: name, execute: execute} = tool, context) do
    private_writes = Map.get(context, :plan_write_tools, %{})

    wrapped = fn id, params, signal, on_update ->
      cond do
        not planning?(context.gate) ->
          execute.(id, params, signal, on_update)

        name in @plan_write_tools and Map.has_key?(private_writes, name) ->
          private_writes[name].execute.(id, params, signal, on_update)

        true ->
          blocked(name, context)
      end
    end

    %{tool | execute: wrapped}
  end

  defp plan_only_tool(name, context) do
    tool =
      case name do
        "write" -> Write.tool(context.plan_dir)
        "edit" -> Edit.tool(context.plan_dir)
      end

    execute = fn id, params, signal, _on_update ->
      if plan_write?(name, params, context),
        do: plan_write(name, id, params, signal, context),
        else: blocked(name, context)
    end

    %{tool | execute: execute}
  end

  defp intercept_private_tool(tool, context) do
    [wrapped] =
      [tool]
      |> ToolHooks.wrap_tools(Map.get(context, :hooks, []), context)
      |> SecretObfuscator.wrap_tools(Map.get(context, :secret_obfuscator))

    wrapped
  end

  defp planning?(gate), do: :atomics.get(gate, 1) == 1

  # Same normalization `CodingAgent.ToolDisclosure` applies before lookup.
  defp bridge_target(%{"name" => name}) when is_binary(name), do: String.trim(name)
  defp bridge_target(_params), do: nil

  defp plan_write?(name, %{"path" => path}, context)
       when name in @plan_write_tools and is_binary(path) and path != "" do
    plan_file?(Path.expand(path, context.cwd), context)
  end

  defp plan_write?(_name, _params, _context), do: false

  defp plan_file?(path, context) do
    path == context.plan_path or
      (Path.dirname(path) == context.plan_dir and Path.extname(path) == ".md")
  end

  # Plan files are session-private server storage: write them locally even when
  # the run delegates file access to an ACP client, and without the working-tree
  # approval, checkpoint and formatter hooks bound to the regular instances.
  defp plan_write(name, id, params, signal, context) do
    path = Path.expand(params["path"], context.cwd)
    params = Map.put(params, "path", path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700) do
      case name do
        "write" -> Write.execute(id, params, signal, nil, context.plan_dir, [])
        "edit" -> Edit.execute(id, params, signal, nil, context.plan_dir, [])
      end
    else
      {:error, reason} -> {:error, "Could not prepare the plan directory: #{reason}"}
    end
  end

  defp blocked(name, context) do
    error(
      "Plan mode is active: `#{name}` is blocked because the working tree is read-only. " <>
        "Only read-only tools run; write the plan to #{context.plan_dir}/<slug>-plan.md " <>
        "and call `#{@propose_tool}` when it is decision-complete."
    )
  end

  defp propose_tool(context) do
    %AgentTool{
      name: @propose_tool,
      label: "Propose Plan",
      description:
        "Plan mode only. Submit your finished plan file for the user's approval. " <>
          "On approval plan mode ends and you execute the plan with full tool access; " <>
          "otherwise the user asks for refinement and plan mode stays on.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Plan file: #{context.plan_dir}/<slug>-plan.md"
          },
          "title" => %{"type" => "string", "description" => "Short plan title"}
        },
        "required" => ["path", "title"]
      },
      execute: fn id, params, _signal, _on_update -> propose(id, params, context) end
    }
  end

  defp propose(id, params, context) do
    with :ok <- planning(context),
         {:ok, title} <- title(params),
         {:ok, path} <- proposal_path(params, context),
         {:ok, content} <- proposal_content(path) do
      proposal = %{"title" => title, "path" => path, "content" => content}

      case request_approval(id, proposal, context) do
        {:ok, :approved, _scope} ->
          with :ok <- resolve(context, :approve, proposal) do
            text(
              "Plan approved. Plan mode exited and full tool access is restored; " <>
                "proceed with the implementation now."
            )
          end

        {:ok, :denied} ->
          with :ok <- resolve(context, :refine, proposal) do
            text(
              "The user did not approve the plan and wants it refined. Plan mode stays on. " <>
                "End your turn now and wait for the user's feedback; then update #{path} " <>
                "and call `#{@propose_tool}` again."
            )
          end

        _ ->
          error(
            "The approval prompt was unavailable, so the plan was not approved. " <>
              "Plan mode stays on; tell the user the plan is ready at #{path}."
          )
      end
    end
  end

  defp planning(context) do
    if planning?(context.gate),
      do: :ok,
      else: {:error, "Plan mode is not active; there is nothing to propose."}
  end

  defp title(%{"title" => title}) when is_binary(title) do
    case String.trim(title) do
      "" -> {:error, "title must be a non-empty string"}
      title -> {:ok, String.slice(title, 0, 200)}
    end
  end

  defp title(_), do: {:error, "missing required parameter: title"}

  defp proposal_path(%{"path" => path}, context) when is_binary(path) and path != "" do
    path = Path.expand(path, context.cwd)

    if plan_file?(path, context),
      do: {:ok, path},
      else: {:error, "The plan file must be a Markdown file in #{context.plan_dir}."}
  end

  defp proposal_path(_params, _context), do: {:error, "missing required parameter: path"}

  defp proposal_content(path) do
    case File.read(path) do
      {:ok, content} when byte_size(content) > @max_bytes ->
        {:error, "The plan exceeds 32 KiB; tighten it before proposing."}

      {:ok, content} ->
        if String.trim(content) == "",
          do: {:error, "The plan file is empty; write the plan before proposing it."},
          else: {:ok, content}

      {:error, _} ->
        {:error, "The plan file #{path} does not exist; write it before proposing it."}
    end
  end

  defp request_approval(id, proposal, context) do
    request = context.approval_request_fun || (&LemonCore.ExecApprovals.request/1)

    request.(%{
      run_id: context.run_id,
      session_id: context.session_id,
      session_key: context.session_key || context.session_id,
      agent_id: context.agent_id,
      tool_call_id: id,
      tool: @propose_tool,
      action: %{
        "title" => proposal["title"],
        "path" => proposal["path"],
        "plan" => proposal["content"]
      },
      rationale: "Approve plan #{inspect(proposal["title"])} and start implementation?",
      expires_in_ms: :infinity
    })
  catch
    _kind, _reason -> {:error, :approval_unavailable}
  end

  defp resolve(context, decision, proposal) do
    case GenServer.call(
           context.session_pid,
           {:resolve_plan_proposal, decision, proposal},
           @resolve_timeout_ms
         ) do
      :ok -> :ok
      _ -> {:error, "The session could not record the plan decision."}
    end
  catch
    :exit, _ -> {:error, "The session could not record the plan decision."}
  end

  defp text(message), do: %AgentToolResult{content: [%TextContent{type: :text, text: message}]}

  defp error(message),
    do: %AgentToolResult{content: [%TextContent{type: :text, text: message}], is_error: true}

  # ── Prompts ──────────────────────────────────────────────────────────────

  defp plan_prompt(context) do
    existing =
      if is_binary(context.plan_path) do
        "- Existing plan: `#{context.plan_path}`. Read it and update it incrementally; for a " <>
          "different task, create a new `<slug>-plan.md` instead.\n"
      else
        ""
      end

    """
    ## Plan mode (read-only)
    Plan mode is active. The working tree and system are read-only:
    - NEVER create, edit, delete, or rename working-tree files, run state-changing commands, or delegate execution. Only read-only tools run; any other tool returns a plan-mode error.
    - The plan directory `#{context.plan_dir}` is the only writable location. Create the plan as `#{context.plan_dir}/<slug>-plan.md` with `write` (`<slug>`: short kebab-case task name, e.g. `auth-token-refresh`) and refine it with `edit`. Record findings as you learn them instead of writing everything at the end.
    #{existing}- When the plan is decision-complete, call `#{@propose_tool}` with its path and a short title. The user then approves it (plan mode ends and you execute it with full tool access) or asks for refinement.
    - NEVER ask the user in prose to approve the plan or leave plan mode; approval happens only through `#{@propose_tool}`.

    ### What a plan is
    An execution spec, not a design doc: an engineer unfamiliar with this conversation must be able to execute it top to bottom without making a design decision.
    - Ground every path, symbol and behavior in files you actually read; resolve unknowns by exploring, not by asking. Mark anything unconfirmed as `unverified`. Ask the user only about genuine preferences or trade-offs.
    - Contents: **Context** (the literal ask and intended end state), **Approach** (ordered concrete steps naming exact files, symbols and new behavior; reuse existing code), **Critical files**, **Verification** (exact commands with expected observable results), **Assumptions** (only user-overridable choices, each with a default).
    - Omit decision-free material (non-goals, alternatives, risk matrices) and mechanical cleanup (changelog, formatting). Keep the plan under 32 KiB.
    """
  end

  defp approved_prompt(%{"content" => content} = approved) do
    "\n\n## Approved plan\n" <>
      "The user approved this plan in plan mode (durable copy: #{approved["path"]}). " <>
      "Continue executing it while it is relevant and incomplete, verifying each step; " <>
      "ignore it if it is stale or unrelated. New user instructions take precedence.\n\n" <>
      content
  end

  defp approved_prompt(_), do: ""

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
