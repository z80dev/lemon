defmodule LemonWeb.SkillsLive do
  @moduledoc """
  Skills: installed skills (search, filters, detail drawer, enable/disable)
  and the official Hermes catalog with install.

  Reads and mutations go through the control plane (`skills.list`,
  `skills.enable`/`skills.disable`, `skills.hermes.catalog`, `skills.install`,
  `exec.approval.resolve`). `skills.install` is async and may wait on an
  operator approval, which this page surfaces inline from the
  `exec_approvals` bus. An install whose outcome is unknown is never retried
  automatically; the operator is asked to check the installed list.
  """

  use LemonWeb, :live_view

  import LemonWeb.KnowledgeComponents

  alias LemonWeb.Rpc

  @catalog_limit 200
  @approval_limit 5

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: LemonCore.Bus.subscribe("exec_approvals")

    {:ok,
     socket
     |> assign(
       nav: :skills,
       page_title: "Skills · Lemon",
       tab: "installed",
       query: "",
       filter: "all",
       source: "all",
       selected: nil,
       toggling: nil,
       catalog: :idle,
       catalog_query: "",
       catalog_category: "all",
       installs: %{},
       approvals: [],
       resolving: nil
     )
     |> load_skills()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] == "catalog", do: "catalog", else: "installed"
    {:noreply, socket |> assign(tab: tab) |> maybe_load_catalog()}
  end

  # ── Installed ────────────────────────────────────────────────────────────

  @impl true
  def handle_event("search", %{"q" => q}, socket),
    do: {:noreply, assign(socket, query: String.slice(q, 0, 200))}

  def handle_event("filter", %{"value" => value}, socket)
      when value in ~w(all enabled disabled attention),
      do: {:noreply, assign(socket, filter: value)}

  def handle_event("source", %{"source" => value}, socket),
    do: {:noreply, assign(socket, source: value)}

  def handle_event("refresh", _params, socket), do: {:noreply, load_skills(socket)}

  def handle_event("select", %{"key" => key}, socket),
    do: {:noreply, assign(socket, selected: key)}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, selected: nil)}

  def handle_event("toggle", %{"key" => key}, socket) do
    case find_skill(socket, key) do
      nil ->
        {:noreply, put_flash(socket, :error, "That skill is no longer installed.")}

      skill ->
        method = if skill["enabled"], do: "skills.disable", else: "skills.enable"

        case Rpc.call(method, %{"skillKey" => key}) do
          {:ok, %{"enabled" => enabled}} ->
            verb = if enabled, do: "enabled", else: "disabled"

            {:noreply,
             socket
             |> load_skills()
             |> put_flash(:info, "#{skill["name"]} #{verb}. New sessions pick up the change.")}

          {:error, error} ->
            {:noreply, put_flash(socket, :error, Rpc.message(error))}
        end
    end
  end

  # ── Catalog ──────────────────────────────────────────────────────────────

  def handle_event("catalog_search", %{"q" => q}, socket),
    do: {:noreply, assign(socket, catalog_query: String.slice(q, 0, 200))}

  def handle_event("catalog_category", %{"category" => value}, socket),
    do: {:noreply, assign(socket, catalog_category: value)}

  def handle_event("reload_catalog", _params, socket),
    do: {:noreply, socket |> assign(catalog: :idle) |> maybe_load_catalog()}

  def handle_event("install", %{"id" => id}, socket) do
    cond do
      Map.get(socket.assigns.installs, id) in [:running, :unknown] ->
        {:noreply, socket}

      not catalog_id?(socket, id) ->
        {:noreply, put_flash(socket, :error, "That catalog entry is no longer available.")}

      true ->
        {:noreply,
         socket
         |> update(:installs, &Map.put(&1, id, :running))
         |> start_async({:install, id}, fn -> Rpc.call("skills.install", %{"skillKey" => id}) end)}
    end
  end

  def handle_event("dismiss_install", %{"id" => id}, socket),
    do: {:noreply, update(socket, :installs, &Map.delete(&1, id))}

  # ── Approvals ────────────────────────────────────────────────────────────

  def handle_event("resolve", %{"id" => id, "decision" => decision}, socket)
      when decision in ["approve_once", "deny"] do
    if Enum.any?(socket.assigns.approvals, &(&1.id == id)) do
      case Rpc.call("exec.approval.resolve", %{"approvalId" => id, "decision" => decision}) do
        {:ok, _} ->
          {:noreply, update(socket, :approvals, &Enum.reject(&1, fn a -> a.id == id end))}

        {:error, error} ->
          {:noreply, put_flash(socket, :error, Rpc.message(error))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:catalog, {:ok, {:ok, payload}}, socket) when is_map(payload) do
    entries =
      payload
      |> Map.get("skills", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&catalog_entry/1)
      |> Enum.reject(&is_nil(&1.id))

    {:noreply, assign(socket, catalog: {:ok, entries})}
  end

  def handle_async(:catalog, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, catalog: {:error, Rpc.message(error)})}

  def handle_async(:catalog, _other, socket),
    do: {:noreply, assign(socket, catalog: {:error, "The Hermes catalog could not be loaded."})}

  def handle_async({:install, id}, {:ok, {:ok, payload}}, socket) do
    name = (is_map(payload) && payload["name"]) || id

    {:noreply,
     socket
     |> update(:installs, &Map.put(&1, id, {:done, name}))
     |> mark_installed(id)
     |> load_skills()
     |> put_flash(:info, "Installed #{name}.")}
  end

  def handle_async({:install, id}, {:ok, {:error, error}}, socket) do
    state =
      case error do
        %{code: :unavailable} -> :unknown
        _ -> {:error, Rpc.message(error)}
      end

    {:noreply, update(socket, :installs, &Map.put(&1, id, state))}
  end

  # The task died: the install may or may not have completed. Never retry.
  def handle_async({:install, id}, _exit, socket),
    do: {:noreply, socket |> update(:installs, &Map.put(&1, id, :unknown)) |> load_skills()}

  @impl true
  def handle_info(%LemonCore.Event{} = event, socket) do
    case LemonControlPlane.EventBridge.project(event) do
      {"exec.approval.requested", %{"tool" => "skills." <> _} = payload} ->
        {:noreply, update(socket, :approvals, &add_approval(&1, payload))}

      {"exec.approval.resolved", %{"approvalId" => id}} ->
        {:noreply, update(socket, :approvals, &Enum.reject(&1, fn a -> a.id == id end))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Data ─────────────────────────────────────────────────────────────────

  defp load_skills(socket) do
    case Rpc.call("skills.list", %{}) do
      {:ok, %{"skills" => skills} = payload} when is_list(skills) ->
        assign(socket, skills: skills, skills_error: nil, summary: payload["summary"] || %{})

      {:ok, _} ->
        assign(socket,
          skills: [],
          skills_error: "Unexpected response from the skill registry.",
          summary: %{}
        )

      {:error, error} ->
        assign(socket, skills: [], skills_error: Rpc.message(error), summary: %{})
    end
  end

  defp maybe_load_catalog(%{assigns: %{tab: "catalog", catalog: :idle}} = socket) do
    if connected?(socket) do
      socket
      |> assign(catalog: :loading)
      |> start_async(:catalog, fn -> Rpc.call("skills.hermes.catalog", %{}) end)
    else
      socket
    end
  end

  defp maybe_load_catalog(socket), do: socket

  defp catalog_entry(entry) do
    %{
      id: text(entry["id"], 200),
      key: text(entry["key"], 200),
      name: text(entry["name"] || entry["key"], 160),
      description: text(entry["description"], 400),
      category: text(entry["category"], 80) || "other",
      collection: text(entry["collection"], 80),
      installed: entry["installed"] == true
    }
  end

  defp text(value, max) when is_binary(value) do
    value = value |> String.replace(~r/[\x00-\x1F\x7F]+/u, " ") |> String.trim()
    if String.length(value) > max, do: String.slice(value, 0, max - 1) <> "…", else: value
  end

  defp text(_value, _max), do: nil

  defp catalog_id?(socket, id) do
    match?({:ok, entries} when is_list(entries), socket.assigns.catalog) and
      Enum.any?(elem(socket.assigns.catalog, 1), &(&1.id == id))
  end

  defp mark_installed(%{assigns: %{catalog: {:ok, entries}}} = socket, id) do
    assign(socket,
      catalog: {:ok, Enum.map(entries, &if(&1.id == id, do: %{&1 | installed: true}, else: &1))}
    )
  end

  defp mark_installed(socket, _id), do: socket

  defp add_approval(approvals, payload) do
    action = payload["action"] || %{}

    approval = %{
      id: payload["approvalId"],
      operation: text(to_string(action["operation"] || "install"), 20),
      skill: text(action["skill_name"], 120) || "skill",
      override: payload["tool"] |> to_string() |> String.ends_with?(".security_override"),
      findings:
        action["findings"] |> List.wrap() |> Enum.take(3) |> Enum.map(&text(to_string(&1), 200)),
      expires_at_ms: payload["expiresAtMs"]
    }

    if is_binary(approval.id) and not Enum.any?(approvals, &(&1.id == approval.id)),
      do: Enum.take([approval | approvals], @approval_limit),
      else: approvals
  end

  defp find_skill(socket, key), do: Enum.find(socket.assigns.skills, &(&1["key"] == key))

  # ── View helpers ─────────────────────────────────────────────────────────

  defp visible_skills(assigns) do
    q = String.downcase(String.trim(assigns.query))

    assigns.skills
    |> Enum.filter(fn skill ->
      matches_filter?(skill, assigns.filter) and
        (assigns.source == "all" or skill["sourceKind"] == assigns.source or
           (assigns.source == "unknown" and is_nil(skill["sourceKind"]))) and
        (q == "" or
           Enum.any?(
             [skill["key"], skill["name"], skill["description"], skill["category"]],
             fn v ->
               is_binary(v) and String.contains?(String.downcase(v), q)
             end
           ))
    end)
  end

  defp matches_filter?(_skill, "all"), do: true
  defp matches_filter?(skill, "enabled"), do: skill["enabled"] == true
  defp matches_filter?(skill, "disabled"), do: skill["enabled"] == false
  defp matches_filter?(skill, "attention"), do: attention?(skill)

  defp attention?(skill),
    do:
      skill["enabled"] == true and
        skill["activation"] in ["not_ready", "blocked", "platform_incompatible", "unaudited"]

  defp sources(skills) do
    skills
    |> Enum.map(&(&1["sourceKind"] || "unknown"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp visible_catalog(assigns) do
    case assigns.catalog do
      {:ok, entries} ->
        q = String.downcase(String.trim(assigns.catalog_query))

        entries
        |> Enum.filter(fn entry ->
          (assigns.catalog_category == "all" or entry.category == assigns.catalog_category) and
            (q == "" or
               Enum.any?([entry.name, entry.key, entry.description, entry.category], fn v ->
                 is_binary(v) and String.contains?(String.downcase(v), q)
               end))
        end)

      _ ->
        []
    end
  end

  defp catalog_categories({:ok, entries}),
    do: entries |> Enum.map(& &1.category) |> Enum.uniq() |> Enum.sort()

  defp catalog_categories(_), do: []

  defp activation_badge(assigns) do
    {tone, label} =
      case assigns.skill["activation"] do
        "active" -> {"success", "Ready"}
        "not_ready" -> {"warning", "Needs setup"}
        "hidden" -> {"neutral", "Disabled"}
        "blocked" -> {"danger", "Blocked"}
        "unaudited" -> {"warning", "Needs audit"}
        "platform_incompatible" -> {"neutral", "Unsupported OS"}
        _ -> {"neutral", "Unknown"}
      end

    assigns = assign(assigns, tone: tone, label: label)

    ~H"""
    <.badge tone={@tone}>{@label}</.badge>
    """
  end

  defp trust_tone("builtin"), do: "accent"
  defp trust_tone("official"), do: "info"
  defp trust_tone("trusted"), do: "success"
  defp trust_tone("community"), do: "warning"
  defp trust_tone(_), do: "neutral"

  defp humanize(nil), do: "Unknown"
  defp humanize(value), do: value |> String.replace(["_", "-"], " ") |> String.capitalize()

  defp missing_count(skill) do
    missing = skill["missing"] || %{}
    Enum.sum(for k <- ~w(bins envVars tools), do: length(List.wrap(missing[k])))
  end

  # ── Render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        visible: visible_skills(assigns),
        selected_skill: assigns.selected && find_skill(%{assigns: assigns}, assigns.selected),
        attention_count: Enum.count(assigns.skills, &attention?/1),
        enabled_count: Enum.count(assigns.skills, & &1["enabled"])
      )

    ~H"""
    <.page>
      <.page_header title="Skills" icon="sparkles" subtitle="Reusable instructions agents load on demand.">
        <:meta :if={@skills_error == nil}>
          <.badge>{length(@skills)} installed</.badge>
          <.badge tone="success">{@enabled_count} enabled</.badge>
          <.badge :if={@attention_count > 0} tone="warning" icon="alert-triangle">
            {@attention_count} need setup
          </.badge>
        </:meta>
        <:actions>
          <.button :if={@tab == "installed"} size="sm" icon="refresh" phx-click="refresh">Refresh</.button>
          <.button :if={@tab == "catalog"} size="sm" icon="refresh" phx-click="reload_catalog">
            Reload catalog
          </.button>
        </:actions>
      </.page_header>

      <section :if={@approvals != []} aria-label="Pending skill approvals" class="mb-4 space-y-2">
        <.callout
          :for={approval <- @approvals}
          id={"approval-#{approval.id}"}
          tone={if approval.override, do: "danger", else: "warning"}
          title={
            if approval.override,
              do: "Security override requested: #{approval.operation} #{approval.skill}",
              else: "Approval needed: #{approval.operation} #{approval.skill}"
          }
        >
          <p :if={!approval.override}>
            The installer is waiting for your decision. Skill content is audited before it is activated.
          </p>
          <div :if={approval.override}>
            <p>The security audit blocked this bundle. Approving permits its flagged instructions.</p>
            <ul :if={approval.findings != []} class="mt-1 list-disc pl-4 text-xs">
              <li :for={finding <- approval.findings}>{finding}</li>
            </ul>
          </div>
          <:actions>
            <.button
              size="sm"
              variant={if approval.override, do: "danger", else: "primary"}
              mutation
              phx-click="resolve"
              phx-value-id={approval.id}
              phx-value-decision="approve_once"
            >
              {if approval.override, do: "Override once", else: "Approve"}
            </.button>
            <.button size="sm" mutation phx-click="resolve" phx-value-id={approval.id} phx-value-decision="deny">
              Deny
            </.button>
          </:actions>
        </.callout>
      </section>

      <.tabs active={@tab} label="Skill views" class="mb-4">
        <:tab id="installed" label="Installed" icon="sparkles" patch={~p"/skills"} count={length(@skills)} />
        <:tab id="catalog" label="Hermes catalog" icon="book-open" patch={~p"/skills?tab=catalog"} />
      </.tabs>

      <div :if={@tab == "installed"} id="skills-installed">
        <.callout :if={@skills_error} tone="danger" title="Skills are unavailable" class="mb-4">
          {@skills_error}
          <:actions><.button size="sm" phx-click="refresh">Retry</.button></:actions>
        </.callout>

        <div :if={!@skills_error} class="mb-3 flex flex-wrap items-center gap-2">
          <.search_field
            id="skills-search"
            event="search"
            value={@query}
            placeholder="Search skills"
            label="Search installed skills"
            class="w-full sm:w-72"
          />
          <.segmented_filter
            event="filter"
            value={@filter}
            label="Filter by state"
            options={[
              {"all", "All", nil},
              {"enabled", "Enabled", nil},
              {"disabled", "Disabled", nil},
              {"attention", "Needs setup", if(@attention_count > 0, do: @attention_count)}
            ]}
          />
          <form id="skills-source-form" phx-change="source" class="ml-auto">
            <label for="skills-source" class="sr-only">Source</label>
            <select id="skills-source" name="source" class="input h-8 w-auto py-0 pr-8 text-xs">
              <option value="all" selected={@source == "all"}>All sources</option>
              <option :for={source <- sources(@skills)} value={source} selected={@source == source}>
                {humanize(source)}
              </option>
            </select>
          </form>
        </div>

        <.empty_state
          :if={!@skills_error && @skills == []}
          icon="sparkles"
          title="No skills installed"
          description="Install one from the Hermes catalog, or add a SKILL.md bundle under ~/.lemon/agent/skill/<name>/."
        >
          <.button size="sm" variant="primary" icon="book-open" patch={~p"/skills?tab=catalog"}>
            Browse catalog
          </.button>
        </.empty_state>

        <div :if={!@skills_error && @skills != []} class="card overflow-hidden">
          <ul id="skills-list" role="list" class="divide-y divide-line">
            <li :if={@visible == []} class="px-4 py-8 text-center text-[13px] text-muted">
              No skills match these filters.
            </li>
            <li
              :for={skill <- @visible}
              id={"skill-#{skill["key"]}"}
              class="group flex items-center gap-3 px-4 py-2.5 hover:bg-surface-2/60"
            >
              <button
                type="button"
                class="flex min-w-0 flex-1 items-start gap-3 text-left focus-visible:outline-none"
                phx-click="select"
                phx-value-key={skill["key"]}
                aria-label={"Show details for #{skill["name"]}"}
              >
                <span class={[
                  "mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-md border border-line",
                  if(skill["enabled"], do: "bg-surface text-accent-text", else: "bg-surface-2 text-subtle")
                ]}>
                  <.icon name="sparkles" class="h-3.5 w-3.5" />
                </span>
                <span class="min-w-0 flex-1">
                  <span class="flex flex-wrap items-center gap-x-2 gap-y-0.5">
                    <span class={["truncate text-[13px] font-medium", if(skill["enabled"], do: "text-fg", else: "text-muted")]}>
                      {skill["name"]}
                    </span>
                    <span :if={skill["name"] != skill["key"]} class="truncate font-mono text-2xs text-subtle">
                      {skill["key"]}
                    </span>
                  </span>
                  <span class="mt-0.5 line-clamp-1 text-xs text-muted">
                    {skill["description"] || "No description."}
                  </span>
                </span>
              </button>
              <div class="hidden shrink-0 items-center gap-1.5 md:flex">
                <.badge :if={skill["category"]}>{skill["category"]}</.badge>
                <.badge tone={trust_tone(skill["trustLevel"])}>{humanize(skill["trustLevel"] || skill["sourceKind"])}</.badge>
              </div>
              <div class="hidden w-28 shrink-0 justify-end sm:flex">
                <.activation_badge skill={skill} />
              </div>
              <.toggle
                id={"skill-toggle-#{skill["key"]}"}
                checked={skill["enabled"] == true}
                label={"Enable #{skill["name"]}"}
                phx-click="toggle"
                phx-value-key={skill["key"]}
              />
            </li>
          </ul>
          <div :if={@summary["truncated"]} class="border-t border-line px-4 py-2 text-xs text-subtle">
            Showing {length(@skills)} of {@summary["count"]} skills.
          </div>
        </div>
      </div>

      <div :if={@tab == "catalog"} id="skills-catalog">
        <.catalog
          catalog={@catalog}
          entries={visible_catalog(assigns)}
          categories={catalog_categories(@catalog)}
          query={@catalog_query}
          category={@catalog_category}
          installs={@installs}
          limit={catalog_limit()}
        />
      </div>

      <.drawer
        :if={@selected_skill}
        id="skill-drawer"
        show
        title={@selected_skill["name"]}
        description={@selected_skill["key"]}
        on_cancel={JS.push("close")}
      >
        <.skill_details skill={@selected_skill} />
        <:footer>
          <.button size="sm" phx-click="close">Close</.button>
          <.button
            size="sm"
            variant={if @selected_skill["enabled"], do: "secondary", else: "primary"}
            mutation
            phx-click="toggle"
            phx-value-key={@selected_skill["key"]}
          >
            {if @selected_skill["enabled"], do: "Disable", else: "Enable"}
          </.button>
        </:footer>
      </.drawer>
    </.page>
    """
  end

  defp catalog_limit, do: @catalog_limit

  attr(:skill, :map, required: true)

  defp skill_details(assigns) do
    missing = assigns.skill["missing"] || %{}
    assigns = assign(assigns, missing: missing, missing_total: missing_count(assigns.skill))

    ~H"""
    <div class="space-y-5">
      <p class="text-[13px] text-fg">{@skill["description"] || "No description."}</p>

      <.callout :if={@skill["activation"] == "blocked"} tone="danger" title="Blocked by security audit">
        This skill has unapproved audit findings and is not offered to agents.
      </.callout>
      <.callout :if={@skill["enabled"] && @missing_total > 0} tone="warning" title="Missing requirements">
        Agents see this skill but it may fail until these are available on the runtime host.
      </.callout>

      <.key_value>
        <:item label="Status"><.activation_badge skill={@skill} /></:item>
        <:item label="Scope">{humanize(@skill["scope"])}</:item>
        <:item label="Source">{humanize(@skill["sourceKind"])}</:item>
        <:item label="Trust">
          <.badge tone={trust_tone(@skill["trustLevel"])}>{humanize(@skill["trustLevel"])}</.badge>
        </:item>
        <:item label="Audit">
          {humanize(@skill["auditStatus"])}
          <span :if={@skill["auditFindingCount"] > 0} class="text-subtle">
            · {@skill["auditFindingCount"]} finding(s)
          </span>
        </:item>
        <:item label="Category">{@skill["category"] || "—"}</:item>
        <:item label="Platforms"><.chips items={@skill["platforms"] || []} /></:item>
        <:item label="Installed"><.time_ago ms={@skill["installedAtMs"]} /></:item>
        <:item label="Updated"><.time_ago ms={@skill["updatedAtMs"]} /></:item>
      </.key_value>

      <div :if={@missing_total > 0}>
        <h3 class="mb-2 text-2xs font-semibold uppercase tracking-wide text-subtle">Missing</h3>
        <.key_value>
          <:item :if={@missing["bins"] != []} label="Binaries"><.chips items={@missing["bins"]} tone="warning" /></:item>
          <:item :if={@missing["envVars"] != []} label="Env vars"><.chips items={@missing["envVars"]} tone="warning" /></:item>
          <:item :if={@missing["tools"] != []} label="Tools"><.chips items={@missing["tools"]} tone="warning" /></:item>
        </.key_value>
      </div>

      <p class="text-xs text-subtle">
        Disabling hides the skill from agents in new sessions; files stay installed.
      </p>
    </div>
    """
  end

  attr(:catalog, :any, required: true)
  attr(:entries, :list, required: true)
  attr(:categories, :list, required: true)
  attr(:query, :string, required: true)
  attr(:category, :string, required: true)
  attr(:installs, :map, required: true)
  attr(:limit, :integer, required: true)

  defp catalog(assigns) do
    assigns =
      assign(assigns,
        shown: Enum.take(assigns.entries, assigns.limit),
        total: match?({:ok, _}, assigns.catalog) && length(elem(assigns.catalog, 1))
      )

    ~H"""
    <div :if={@catalog in [:idle, :loading]} class="card flex items-center justify-center gap-2 px-4 py-12 text-[13px] text-muted">
      <.spinner label="Loading catalog" /> Loading the official Hermes catalog…
    </div>

    <.callout :if={match?({:error, _}, @catalog)} tone="danger" title="Catalog unavailable">
      {elem(@catalog, 1)}
      <:actions><.button size="sm" phx-click="reload_catalog">Retry</.button></:actions>
    </.callout>

    <div :if={match?({:ok, _}, @catalog)}>
      <div class="mb-3 flex flex-wrap items-center gap-2">
        <.search_field
          id="catalog-search"
          event="catalog_search"
          value={@query}
          placeholder="Search catalog"
          label="Search the Hermes catalog"
          class="w-full sm:w-72"
        />
        <form id="catalog-category-form" phx-change="catalog_category">
          <label for="catalog-category" class="sr-only">Category</label>
          <select id="catalog-category" name="category" class="input h-8 w-auto py-0 pr-8 text-xs">
            <option value="all" selected={@category == "all"}>All categories</option>
            <option :for={category <- @categories} value={category} selected={@category == category}>
              {humanize(category)}
            </option>
          </select>
        </form>
        <span class="ml-auto text-xs text-subtle">
          From NousResearch/hermes-agent · installs are audited and may ask for approval
        </span>
      </div>

      <.empty_state :if={@entries == []} icon="search" title="No catalog skills match" />

      <ul :if={@entries != []} id="catalog-list" role="list" class="grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
        <li :for={entry <- @shown} id={"catalog-#{entry_dom_id(entry.id)}"} class="card flex flex-col gap-2 p-3">
          <div class="flex items-start justify-between gap-2">
            <div class="min-w-0">
              <p class="truncate text-[13px] font-medium text-fg">{entry.name}</p>
              <p class="truncate text-2xs text-subtle">{humanize(entry.collection)} · {humanize(entry.category)}</p>
            </div>
            <.install_control entry={entry} state={Map.get(@installs, entry.id)} />
          </div>
          <p :if={entry.description not in [nil, ""]} class="line-clamp-2 text-xs text-muted">
            {entry.description}
          </p>
          <.install_status id={entry.id} state={Map.get(@installs, entry.id)} />
        </li>
      </ul>
      <p :if={length(@entries) > length(@shown)} class="mt-3 text-xs text-subtle">
        Showing {length(@shown)} of {length(@entries)} matching skills ({@total} in catalog). Refine the search to see more.
      </p>
    </div>
    """
  end

  defp entry_dom_id(id), do: id |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")

  attr(:entry, :map, required: true)
  attr(:state, :any, required: true)

  defp install_control(assigns) do
    ~H"""
    <%= cond do %>
      <% @entry.installed || match?({:done, _}, @state) -> %>
        <.badge tone="success" icon="check">Installed</.badge>
      <% @state == :running -> %>
        <.button size="sm" loading disabled>Installing</.button>
      <% @state == :unknown -> %>
        <.badge tone="warning">Outcome unknown</.badge>
      <% true -> %>
        <.button
          size="sm"
          icon="download"
          mutation
          phx-click="install"
          phx-value-id={@entry.id}
          aria-label={"Install #{@entry.name}"}
        >
          {if match?({:error, _}, @state), do: "Retry", else: "Install"}
        </.button>
    <% end %>
    """
  end

  attr(:id, :string, required: true)
  attr(:state, :any, required: true)

  defp install_status(assigns) do
    ~H"""
    <p :if={@state == :running} class="flex items-center gap-1.5 text-xs text-info" role="status">
      <.spinner class="h-3 w-3" label="Installing" /> Fetching and auditing… approve the request above if asked.
    </p>
    <p :if={match?({:error, _}, @state)} class="text-xs text-danger" role="alert">{elem(@state, 1)}</p>
    <div :if={@state == :unknown} class="flex items-start justify-between gap-2 text-xs text-warning" role="alert">
      <span>The install may have completed. Check the Installed tab before trying again.</span>
      <button type="button" class="shrink-0 underline" phx-click="dismiss_install" phx-value-id={@id}>
        Dismiss
      </button>
    </div>
    """
  end
end
