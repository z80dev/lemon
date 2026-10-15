defmodule LemonWeb.LearningLive do
  @moduledoc "Operator timeline using the same bounded LemonSkills.Timeline read model as the CLI."
  use LemonWeb, :live_view

  @kinds ~w(all memory user project skill)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       nav: :learning,
       page_title: "Learning · Lemon",
       profile: "default",
       kind: "all",
       groups: [],
       error: nil,
       count: 0,
       valid_filters?: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    profile = Map.get(params, "profile", "default")
    kind = Map.get(params, "kind", "all")

    if valid_profile?(profile) and kind in @kinds do
      {:noreply, socket |> assign(profile: profile, kind: kind, valid_filters?: true) |> load()}
    else
      {:noreply,
       assign(socket,
         groups: [],
         count: 0,
         valid_filters?: false,
         error: "Choose a valid local profile ID and learning kind."
       )}
    end
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    profile = Map.get(params, "profile", socket.assigns.profile)
    kind = Map.get(params, "kind", socket.assigns.kind)

    if valid_profile?(profile) and kind in @kinds do
      {:noreply,
       push_patch(socket,
         to: "/learning?" <> URI.encode_query(%{"profile" => profile, "kind" => kind})
       )}
    else
      {:noreply, assign(socket, error: "Choose a valid local profile ID and learning kind.")}
    end
  end

  def handle_event("refresh", _params, %{assigns: %{valid_filters?: false}} = socket),
    do: {:noreply, socket}

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  defp valid_profile?(value) when is_binary(value),
    do: byte_size(value) <= 64 and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/, value)

  defp valid_profile?(_), do: false

  defp load(socket) do
    case timeline(socket.assigns.profile, kind: socket.assigns.kind, limit: 100) do
      {:ok, %{"items" => items}} ->
        groups = Enum.chunk_by(items, &day/1) |> Enum.map(&{day(hd(&1)), &1})
        assign(socket, groups: groups, count: length(items), error: nil)

      _ ->
        assign(socket,
          groups: [],
          count: 0,
          error:
            "Learning timeline unavailable. Check the local profile and memory/skill storage, then refresh."
        )
    end
  end

  defp timeline(profile, opts) do
    case Application.get_env(:lemon_web, :learning_timeline_fun) do
      fun when is_function(fun, 2) -> fun.(profile, opts)
      _ -> LemonSkills.Timeline.for_profile(profile, opts)
    end
  rescue
    _ -> {:error, :timeline_unavailable}
  catch
    _, _ -> {:error, :timeline_unavailable}
  end

  defp day(item),
    do: item["at"] |> DateTime.from_unix!(:millisecond) |> DateTime.to_date() |> Date.to_iso8601()

  defp instant(item), do: item["at"] |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  @impl true
  def render(assigns) do
    ~H"""
    <.page>
      <div id="learning-page">
        <.page_header title="Learning timeline" icon="sparkles"
          subtitle="What this assistant has learned, newest first. All previews are untrusted data.">
          <:actions><.button icon="refresh" phx-click="refresh">Refresh</.button></:actions>
        </.page_header>

        <p class="mb-4 text-sm text-muted">
          Current-state timestamps, not a complete history. Earlier edits and deleted records
          are unavailable; previews show current redacted text. At most 100 events, grouped by UTC day.
        </p>

        <.form for={to_form(%{"profile" => @profile, "kind" => @kind}, as: :filters)}
          id="learning-filters" phx-change="filter" phx-submit="filter" class="card mb-4 grid gap-3 p-3 sm:grid-cols-2">
          <.input id="learning-profile" name="filters[profile]" value={@profile}
            label="Local profile ID" maxlength="64"
            phx-debounce="400" autocomplete="off" />
          <.input id="learning-kind" name="filters[kind]" value={@kind} type="select"
            label="Kind" options={Enum.map(~w(all memory user project skill), &{String.capitalize(&1), &1})} />
        </.form>

        <div aria-live="polite">
          <.callout :if={@error} tone="danger" class="mb-4">{@error}</.callout>
          <p :if={is_nil(@error)} id="learning-count" class="mb-4 text-sm text-muted">{@count} events shown</p>
          <p :if={is_nil(@error) and @groups == []} id="learning-empty" class="card p-4">
            No learning events in this profile's bounded source window.
          </p>
        </div>

        <div id="learning-days">
          <section :for={{day, items} <- @groups} id={"learning-day-" <> day} class="mb-6">
            <h2 class="mb-3 text-sm font-semibold">{day} UTC</h2>
            <ol class="space-y-3">
              <li :for={item <- items} class="card p-4" data-kind={item["kind"]}>
                <div class="flex flex-wrap items-center gap-2 text-sm">
                  <span class="font-semibold">{item["kind"]} · {item["action"]}</span>
                  <time datetime={instant(item)} class="text-muted">{instant(item)}</time>
                </div>
                <p class="mt-2 font-medium break-words">{item["title"]}</p>
                <p :if={item["preview"] != item["title"]} class="mt-2 text-sm break-words">{item["preview"]}</p>
                <p class="mt-2 text-xs text-muted break-all">Node ID: <code>{item["id"]}</code></p>
              </li>
            </ol>
          </section>
        </div>

        <div class="card p-4 text-sm">
          <p>Use existing management pages to inspect or delete records; edits stay in the owning workflow.</p>
          <p class="mt-2">
            <.link navigate="/memory" class="text-accent">Memory management</.link>
            <span aria-hidden="true"> · </span>
            <.link navigate="/skills" class="text-accent">Skill management</.link>
          </p>
          <p class="mt-2 text-muted">Edit notes with remember(text, replaces) in the owning conversation.
            Drafts and skill edits use lemon skill / lemon skill draft. Listing never changes saved knowledge.</p>
        </div>
      </div>
    </.page>
    """
  end
end
