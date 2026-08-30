defmodule LemonWeb.ProviderManagementLive do
  @moduledoc "Authenticated, redacted provider-routing management surface."

  use LemonWeb, :live_view

  alias LemonAgent.ModelRuntime.ProviderConfiguration
  alias LemonCore.Config

  @safe_identifier ~r/^[a-z0-9][a-z0-9._-]{0,63}$/
  @max_provider_count 16

  @empty_routing %{
    "enabled" => true,
    "requireCredentials" => true,
    "fallbackProviders" => [],
    "defaultPool" => nil,
    "defaultProfile" => nil,
    "credentialPools" => [],
    "credentialPoolCount" => 0,
    "credentialReferenceCount" => 0
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Provider routing · Lemon Management")
     |> assign(:routing, @empty_routing)
     |> assign(:routing_available?, false)
     |> assign(:fallback_draft, %{"provider" => ""})
     |> assign(:pool_draft, %{
       "pool" => "",
       "providers" => "",
       "strategy" => "priority",
       "activate" => false
     })
     |> assign(:credential_draft, %{
       "pool" => "",
       "provider" => "",
       "operation" => "add"
     })
     |> assign(:pending_change, nil)
     |> assign(:notice, nil)
     |> assign(:error, nil)
     |> refresh_routing()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_change, nil)
     |> assign(:notice, "Provider routing state refreshed.")
     |> assign(:error, nil)
     |> refresh_routing()}
  end

  def handle_event("preview-fallback-add", %{"fallback" => params}, socket) do
    provider = safe_draft_identifier(params["provider"])
    socket = assign(socket, :fallback_draft, %{"provider" => provider})

    if provider == "" do
      {:noreply, reject_preview(socket, "Choose a known provider name.")}
    else
      {:noreply, preview_change(socket, %{"action" => "fallback.add", "provider" => provider})}
    end
  end

  def handle_event("preview-fallback-remove", %{"provider" => provider}, socket) do
    provider = safe_draft_identifier(provider)

    if provider == "" do
      {:noreply, reject_preview(socket, "That fallback provider is not available.")}
    else
      {:noreply, preview_change(socket, %{"action" => "fallback.remove", "provider" => provider})}
    end
  end

  def handle_event("preview-fallback-clear", _params, socket) do
    {:noreply, preview_change(socket, %{"action" => "fallback.clear"})}
  end

  def handle_event("preview-pool-upsert", %{"pool" => params}, socket) do
    draft = normalize_pool_draft(params)
    socket = assign(socket, :pool_draft, draft)

    with {:ok, pool} <- required_identifier(draft["pool"], "Enter a valid pool name."),
         {:ok, providers} <- parse_provider_list(draft["providers"]),
         {:ok, strategy} <- normalize_strategy(draft["strategy"]) do
      {:noreply,
       preview_change(socket, %{
         "action" => "pool.upsert",
         "pool" => pool,
         "providers" => providers,
         "strategy" => strategy,
         "activate" => draft["activate"]
       })}
    else
      {:error, message} -> {:noreply, reject_preview(socket, message)}
    end
  end

  def handle_event("preview-pool-activate", %{"pool" => pool_name}, socket) do
    with {:ok, pool_name} <- required_identifier(pool_name, "That pool is not available."),
         %{} = pool <- find_pool(socket.assigns.routing, pool_name) do
      {:noreply,
       preview_change(socket, %{
         "action" => "pool.upsert",
         "pool" => pool_name,
         "providers" => pool["providers"],
         "strategy" => pool["strategy"],
         "activate" => true
       })}
    else
      _ -> {:noreply, reject_preview(socket, "That pool is not available.")}
    end
  end

  def handle_event("preview-pool-delete", %{"pool" => pool}, socket) do
    pool = safe_draft_identifier(pool)

    if pool == "" or is_nil(find_pool(socket.assigns.routing, pool)) do
      {:noreply, reject_preview(socket, "That pool is not available.")}
    else
      {:noreply, preview_change(socket, %{"action" => "pool.delete", "pool" => pool})}
    end
  end

  def handle_event("preview-credential", %{"credential" => params}, socket) do
    draft = normalize_credential_draft(params)
    socket = assign(socket, :credential_draft, draft)

    with {:ok, pool} <- required_identifier(draft["pool"], "Choose a credential pool."),
         true <- not is_nil(find_pool(socket.assigns.routing, pool)),
         {:ok, provider} <- required_identifier(draft["provider"], "Enter a provider name."),
         {:ok, action} <- credential_action(draft["operation"]),
         {:ok, credential_ref} <- credential_ref(action, params["credential_ref"]) do
      change = %{"action" => action, "pool" => pool, "provider" => provider}

      change =
        if credential_ref, do: Map.put(change, "credentialRef", credential_ref), else: change

      {:noreply, preview_change(socket, change, credential_ref)}
    else
      false -> {:noreply, reject_preview(socket, "Choose an existing credential pool.")}
      {:error, message} -> {:noreply, reject_preview(socket, message)}
    end
  end

  def handle_event("cancel-preview", _params, socket) do
    {:noreply,
     socket
     |> assign(:pending_change, nil)
     |> assign(:notice, "Preview dismissed. Your non-secret drafts were kept.")
     |> assign(:error, nil)}
  end

  def handle_event("apply-preview", event_params, socket) do
    params = Map.get(event_params, "apply", %{})

    case socket.assigns.pending_change do
      nil ->
        {:noreply, assign(socket, :error, "Preview an exact provider change before applying it.")}

      pending ->
        apply_preview(socket, pending, params)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main-content" class="management-page">
      <div class="management-container">
        <header class="management-header">
          <div>
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Lemon</p>
            <h1 class="mt-1 text-lg font-semibold text-slate-900 sm:text-xl">
              Provider routing
            </h1>
            <p class="mt-1 text-sm text-slate-600">
              Preview and apply fallback and credential-pool changes without exposing credentials.
            </p>
          </div>
          <nav aria-label="Management sections" class="management-header-actions">
            <.link href={~p"/manage"} class="management-secondary-link">Sessions</.link>
            <.link href={~p"/"} class="management-secondary-link">Open chat</.link>
            <button type="button" phx-click="refresh" class="management-primary-button">
              Refresh
            </button>
          </nav>
        </header>

        <section aria-labelledby="provider-status-title" class="management-status-grid">
          <h2 id="provider-status-title" class="sr-only">Provider routing status</h2>
          <div class="management-status-card">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Routing</p>
            <div class="management-status-line">
              <span class={status_dot_class(@routing_available?)} aria-hidden="true"></span>
              <strong>{routing_status_label(@routing_available?, @routing["enabled"])}</strong>
            </div>
            <p class="text-xs text-slate-500">
              Credential checks {if @routing["requireCredentials"], do: "required", else: "optional"}
            </p>
          </div>
          <div class="management-status-card">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Fallbacks</p>
            <p class="management-status-value">{length(@routing["fallbackProviders"])} ordered</p>
            <p class="text-xs text-slate-500">Used after the primary provider.</p>
          </div>
          <div class="management-status-card">
            <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Credential pools</p>
            <p class="management-status-value">{@routing["credentialPoolCount"]} pools</p>
            <p class="text-xs text-slate-500">
              {@routing["credentialReferenceCount"]} opaque reference(s)
            </p>
          </div>
        </section>

        <div id="provider-feedback" aria-live="polite" class="management-feedback">
          <%= if @notice do %>
            <p class="management-notice">{@notice}</p>
          <% end %>
          <%= if @error do %>
            <p role="alert" class="management-error">{@error}</p>
          <% end %>
        </div>

        <%= if @pending_change do %>
          <section id="provider-change-preview" aria-labelledby="preview-title" class="provider-preview">
            <div>
              <p class="text-xs font-medium uppercase tracking-wide text-amber-700">Exact preview</p>
              <h2 id="preview-title" class="font-semibold text-slate-950">
                {@pending_change.label}
              </h2>
              <p class="mt-1 text-sm text-slate-700">
                {preview_summary(@pending_change.proposed)}
              </p>
              <%= if @pending_change.destructive do %>
                <p class="mt-2 text-sm text-rose-800">
                  Destructive change. Type <code>{@pending_change.confirmation}</code> exactly to apply.
                </p>
              <% end %>
              <%= if @pending_change.credential_required do %>
                <p class="mt-2 text-xs text-slate-600">
                  Re-enter the same credential reference. It was validated but never retained or rendered.
                </p>
              <% end %>
            </div>
            <.form
              for={to_form(%{"confirmation" => "", "credential_ref" => ""}, as: :apply)}
              id="provider-apply-form"
              phx-submit="apply-preview"
              class="provider-apply-form"
            >
              <%= if @pending_change.destructive do %>
                <label for="apply_confirmation" class="provider-label">Exact confirmation</label>
                <input
                  id="apply_confirmation"
                  name="apply[confirmation]"
                  type="text"
                  autocomplete="off"
                  maxlength="64"
                  class="management-input"
                />
              <% end %>
              <%= if @pending_change.credential_required do %>
                <label for="apply_credential_ref" class="provider-label">
                  Credential reference
                </label>
                <input
                  id="apply_credential_ref"
                  name="apply[credential_ref]"
                  type="password"
                  autocomplete="new-password"
                  spellcheck="false"
                  maxlength="160"
                  placeholder="secret:… or env:…"
                  class="management-input"
                />
              <% end %>
              <div class="provider-form-actions">
                <button
                  type="submit"
                  class={if @pending_change.destructive, do: "management-danger-button", else: "management-primary-button"}
                  disabled={not @pending_change.changed}
                >
                  Apply exact change
                </button>
                <button
                  type="button"
                  phx-click="cancel-preview"
                  class="management-secondary-button"
                >
                  Keep draft, cancel preview
                </button>
              </div>
            </.form>
          </section>
        <% end %>

        <div class="provider-management-grid">
          <section aria-labelledby="fallback-title" class="management-panel provider-panel">
            <div class="management-panel-header">
              <div>
                <h2 id="fallback-title" class="font-semibold text-slate-900">Ordered fallbacks</h2>
                <p class="text-xs text-slate-500">New providers append to the route order.</p>
              </div>
              <button
                type="button"
                phx-click="preview-fallback-clear"
                class="management-danger-button"
                disabled={@routing["fallbackProviders"] == []}
              >
                Preview clear
              </button>
            </div>

            <ol id="fallback-list" class="provider-fallback-list">
              <%= if @routing["fallbackProviders"] == [] do %>
                <li class="management-empty">No fallback providers configured.</li>
              <% else %>
                <%= for {provider, index} <- Enum.with_index(@routing["fallbackProviders"], 1) do %>
                  <li class="provider-fallback-row">
                    <span class="provider-order">{index}</span>
                    <strong>{provider}</strong>
                    <button
                      type="button"
                      phx-click="preview-fallback-remove"
                      phx-value-provider={provider}
                      class="management-icon-button"
                      aria-label={"Preview removal of #{provider}"}
                    >
                      Preview remove
                    </button>
                  </li>
                <% end %>
              <% end %>
            </ol>

            <.form
              for={to_form(@fallback_draft, as: :fallback)}
              id="fallback-add-form"
              phx-submit="preview-fallback-add"
              class="provider-form"
            >
              <label for="fallback_provider" class="provider-label">Provider to append</label>
              <input
                id="fallback_provider"
                name="fallback[provider]"
                type="text"
                value={@fallback_draft["provider"]}
                maxlength="64"
                autocomplete="off"
                placeholder="anthropic"
                class="management-input"
              />
              <button type="submit" class="management-secondary-button">Preview add</button>
            </.form>
          </section>

          <section aria-labelledby="pool-title" class="management-panel provider-panel">
            <div class="management-panel-header">
              <div>
                <h2 id="pool-title" class="font-semibold text-slate-900">Credential pools</h2>
                <p class="text-xs text-slate-500">
                  Counts are visible; credential references and secret names are not.
                </p>
              </div>
            </div>

            <div id="credential-pool-list" class="provider-pool-list">
              <%= if @routing["credentialPools"] == [] do %>
                <p class="management-empty">No credential pools configured.</p>
              <% else %>
                <%= for pool <- @routing["credentialPools"] do %>
                  <article id={"pool-#{pool["name"]}"} class="provider-pool-card">
                    <header>
                      <div>
                        <h3>{pool["name"]}</h3>
                        <p>{pool["strategy"]} · {pool["credentialReferenceCount"]} reference(s)</p>
                      </div>
                      <%= if @routing["defaultPool"] == pool["name"] do %>
                        <span class="provider-active-badge">Active</span>
                      <% end %>
                    </header>
                    <p class="provider-pool-providers">
                      {Enum.join(pool["providers"], " → ")}
                    </p>
                    <dl class="provider-counts">
                      <%= for {provider, count} <- pool["credentialCounts"] do %>
                        <div><dt>{provider}</dt><dd>{count}</dd></div>
                      <% end %>
                    </dl>
                    <div class="provider-form-actions">
                      <button
                        type="button"
                        phx-click="preview-pool-activate"
                        phx-value-pool={pool["name"]}
                        class="management-secondary-button"
                        disabled={@routing["defaultPool"] == pool["name"]}
                      >
                        Preview activate
                      </button>
                      <button
                        type="button"
                        phx-click="preview-pool-delete"
                        phx-value-pool={pool["name"]}
                        class="management-danger-button"
                      >
                        Preview delete
                      </button>
                    </div>
                  </article>
                <% end %>
              <% end %>
            </div>

            <.form
              for={to_form(@pool_draft, as: :pool)}
              id="pool-upsert-form"
              phx-submit="preview-pool-upsert"
              class="provider-form provider-form-grid"
            >
              <div>
                <label for="pool_pool" class="provider-label">Pool name</label>
                <input
                  id="pool_pool"
                  name="pool[pool]"
                  type="text"
                  value={@pool_draft["pool"]}
                  maxlength="64"
                  autocomplete="off"
                  placeholder="primary"
                  class="management-input"
                />
              </div>
              <div>
                <label for="pool_strategy" class="provider-label">Strategy</label>
                <select id="pool_strategy" name="pool[strategy]" class="management-select">
                  <option value="priority" selected={@pool_draft["strategy"] == "priority"}>Priority</option>
                  <option value="round_robin" selected={@pool_draft["strategy"] == "round_robin"}>Round robin</option>
                </select>
              </div>
              <div class="provider-form-wide">
                <label for="pool_providers" class="provider-label">Providers in order</label>
                <input
                  id="pool_providers"
                  name="pool[providers]"
                  type="text"
                  value={@pool_draft["providers"]}
                  maxlength="512"
                  autocomplete="off"
                  placeholder="openai, anthropic"
                  class="management-input"
                />
              </div>
              <label class="provider-checkbox provider-form-wide">
                <input
                  type="checkbox"
                  name="pool[activate]"
                  value="true"
                  checked={@pool_draft["activate"]}
                />
                Make this the active credential pool
              </label>
              <div class="provider-form-actions provider-form-wide">
                <button type="submit" class="management-secondary-button">
                  Preview create or update
                </button>
              </div>
            </.form>
          </section>

          <section aria-labelledby="credential-title" class="management-panel provider-panel provider-panel-wide">
            <div class="management-panel-header">
              <div>
                <h2 id="credential-title" class="font-semibold text-slate-900">
                  Credential references
                </h2>
                <p class="text-xs text-slate-500">
                  Add, remove, or clear references. Values are password-masked and never echoed.
                </p>
              </div>
            </div>
            <.form
              for={to_form(@credential_draft, as: :credential)}
              id="credential-reference-form"
              phx-submit="preview-credential"
              class="provider-form provider-form-grid provider-credential-form"
            >
              <div>
                <label for="credential_pool" class="provider-label">Pool</label>
                <select id="credential_pool" name="credential[pool]" class="management-select">
                  <option value="">Choose a pool</option>
                  <%= for pool <- @routing["credentialPools"] do %>
                    <option
                      value={pool["name"]}
                      selected={@credential_draft["pool"] == pool["name"]}
                    >
                      {pool["name"]}
                    </option>
                  <% end %>
                </select>
              </div>
              <div>
                <label for="credential_provider" class="provider-label">Provider</label>
                <input
                  id="credential_provider"
                  name="credential[provider]"
                  type="text"
                  value={@credential_draft["provider"]}
                  maxlength="64"
                  autocomplete="off"
                  placeholder="openai"
                  class="management-input"
                />
              </div>
              <div>
                <label for="credential_operation" class="provider-label">Operation</label>
                <select id="credential_operation" name="credential[operation]" class="management-select">
                  <option value="add" selected={@credential_draft["operation"] == "add"}>Add one</option>
                  <option value="remove" selected={@credential_draft["operation"] == "remove"}>Remove one</option>
                  <option value="clear" selected={@credential_draft["operation"] == "clear"}>Clear provider</option>
                </select>
              </div>
              <div>
                <label for="credential_credential_ref" class="provider-label">
                  Reference for add/remove
                </label>
                <input
                  id="credential_credential_ref"
                  name="credential[credential_ref]"
                  type="password"
                  autocomplete="new-password"
                  spellcheck="false"
                  maxlength="160"
                  placeholder="secret:… or env:…"
                  class="management-input"
                />
              </div>
              <div class="provider-form-actions provider-form-wide">
                <button type="submit" class="management-secondary-button">
                  Preview credential change
                </button>
              </div>
            </.form>
          </section>
        </div>
      </div>
    </main>
    """
  end

  defp preview_change(socket, params, credential_ref \\ nil) do
    socket = assign(socket, notice: nil, error: nil, pending_change: nil)

    case configure(params) do
      {:ok, result} ->
        proposed = sanitize_routing(result["proposedRoutingConfig"])
        confirmation = sanitize_confirmation(get_in(result, ["confirmation", "value"]))

        pending = %{
          label: action_label(params),
          action: params["action"],
          params: Map.drop(params, ["credentialRef"]),
          credential_digest: credential_digest(credential_ref),
          credential_required: is_binary(credential_ref),
          config_revision: result["configRevision"],
          destructive: result["destructive"] == true,
          confirmation: confirmation,
          changed: result["changed"] == true,
          proposed: proposed
        }

        notice =
          if pending.changed,
            do: "Preview ready. No provider configuration was written.",
            else: "Preview complete. The requested state is already configured."

        assign(socket, pending_change: pending, notice: notice)

      {:error, code, _message} ->
        assign(socket, :error, provider_error(code))
    end
  end

  defp apply_preview(socket, pending, params) do
    confirmation = normalize_confirmation(params["confirmation"])
    credential_ref = normalize_credential_ref(params["credential_ref"])

    cond do
      pending.destructive and confirmation != pending.confirmation ->
        {:noreply,
         assign(
           socket,
           :error,
           "Exact confirmation did not match. Your draft and preview were kept."
         )}

      pending.credential_required and not credential_matches?(pending, credential_ref) ->
        {:noreply,
         assign(socket, :error, "Re-enter the same credential reference used for this preview.")}

      true ->
        change =
          pending.params
          |> Map.put("apply", true)
          |> Map.put("expectedRevision", pending.config_revision)
          |> maybe_put("confirm", if(pending.destructive, do: confirmation, else: nil))
          |> maybe_put(
            "credentialRef",
            if(pending.credential_required, do: credential_ref, else: nil)
          )

        case configure(change) do
          {:ok, result} ->
            routing = sanitize_routing(result["proposedRoutingConfig"])

            {:noreply,
             socket
             |> assign(:routing, routing)
             |> assign(:routing_available?, true)
             |> assign(:pending_change, nil)
             |> assign(:notice, "Provider routing change applied and configuration reloaded.")
             |> assign(:error, nil)}

          {:error, :stale_configuration, _message} ->
            {:noreply,
             socket
             |> assign(:pending_change, nil)
             |> assign(
               :error,
               "Provider configuration changed after preview. Your non-secret drafts were kept; preview again."
             )
             |> refresh_routing()}

          {:error, code, _message} ->
            {:noreply, assign(socket, :error, provider_error(code))}
        end
    end
  end

  defp refresh_routing(socket) do
    case snapshot() do
      {:ok, routing} ->
        assign(socket, routing: sanitize_routing(routing), routing_available?: true)

      {:error, _reason} ->
        socket
        |> assign(routing: @empty_routing, routing_available?: false)
        |> assign(
          :error,
          socket.assigns.error || "Provider routing status is temporarily unavailable."
        )
    end
  end

  defp snapshot do
    fun = Application.get_env(:lemon_web, :provider_snapshot_fun)

    result =
      if is_function(fun, 0) do
        fun.()
      else
        project_dir = provider_project_dir()
        {:ok, project_dir |> Config.load(cache: false) |> ProviderConfiguration.snapshot()}
      end

    case result do
      {:ok, routing} when is_map(routing) -> {:ok, routing}
      routing when is_map(routing) -> {:ok, routing}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp configure(params) do
    params = Map.merge(%{"scope" => "global", "projectDir" => provider_project_dir()}, params)
    fun = Application.get_env(:lemon_web, :provider_configuration_fun)

    result =
      if is_function(fun, 1),
        do: fun.(params),
        else: ProviderConfiguration.configure(params)

    case result do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, code, message} when is_atom(code) and is_binary(message) -> {:error, code, message}
      _ -> {:error, :configuration_failed, "Provider routing configuration failed"}
    end
  rescue
    _ -> {:error, :configuration_failed, "Provider routing configuration failed"}
  catch
    :exit, _ -> {:error, :configuration_failed, "Provider routing configuration failed"}
  end

  defp provider_project_dir do
    case Application.get_env(:lemon_web, :provider_configuration_project_dir) do
      value when is_binary(value) and value != "" -> value
      _ -> File.cwd!()
    end
  end

  defp sanitize_routing(routing) when is_map(routing) do
    fallbacks = safe_identifier_list(routing["fallbackProviders"])

    pools =
      routing
      |> Map.get("credentialPools", [])
      |> List.wrap()
      |> Enum.flat_map(&sanitize_pool/1)
      |> Enum.sort_by(& &1["name"])

    %{
      "enabled" => routing["enabled"] != false,
      "requireCredentials" => routing["requireCredentials"] != false,
      "fallbackProviders" => fallbacks,
      "defaultPool" => safe_optional_identifier(routing["defaultPool"]),
      "defaultProfile" => safe_optional_identifier(routing["defaultProfile"]),
      "credentialPools" => pools,
      "credentialPoolCount" => length(pools),
      "credentialReferenceCount" =>
        pools |> Enum.map(& &1["credentialReferenceCount"]) |> Enum.sum()
    }
  end

  defp sanitize_routing(_routing), do: @empty_routing

  defp sanitize_pool(pool) when is_map(pool) do
    with name when is_binary(name) <- safe_optional_identifier(pool["name"]) do
      counts =
        pool
        |> Map.get("credentialCounts", %{})
        |> Enum.flat_map(fn {provider, count} ->
          case {safe_optional_identifier(provider), safe_count(count)} do
            {provider, count} when is_binary(provider) -> [{provider, count}]
            _ -> []
          end
        end)
        |> Enum.sort()
        |> Map.new()

      [
        %{
          "name" => name,
          "providers" => safe_identifier_list(pool["providers"]),
          "strategy" =>
            if(pool["strategy"] == "round_robin", do: "round_robin", else: "priority"),
          "credentialCounts" => counts,
          "credentialReferenceCount" => counts |> Map.values() |> Enum.sum()
        }
      ]
    else
      _ -> []
    end
  end

  defp sanitize_pool(_pool), do: []

  defp safe_identifier_list(values) do
    values
    |> List.wrap()
    |> Enum.map(&safe_optional_identifier/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(@max_provider_count)
  end

  defp safe_optional_identifier(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    if Regex.match?(@safe_identifier, value), do: value, else: nil
  end

  defp safe_optional_identifier(_value), do: nil

  defp safe_draft_identifier(value), do: safe_optional_identifier(value) || ""

  defp required_identifier(value, message) do
    case safe_optional_identifier(value) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, message}
    end
  end

  defp normalize_pool_draft(params) do
    providers =
      params
      |> Map.get("providers", "")
      |> to_string()
      |> String.slice(0, 512)

    %{
      "pool" => safe_draft_identifier(params["pool"]),
      "providers" => safe_provider_draft(providers),
      "strategy" => if(params["strategy"] == "round_robin", do: "round_robin", else: "priority"),
      "activate" => params["activate"] in [true, "true", "1", "on"]
    }
  end

  defp safe_provider_draft(value) do
    values = value |> String.split(",") |> Enum.map(&String.trim/1)

    if Enum.all?(values, &(&1 == "" or not is_nil(safe_optional_identifier(&1)))) do
      Enum.join(values, ", ")
    else
      ""
    end
  end

  defp parse_provider_list(value) do
    providers =
      value
      |> String.split(",")
      |> Enum.map(&safe_optional_identifier/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    cond do
      providers == [] -> {:error, "Enter at least one known provider."}
      length(providers) > @max_provider_count -> {:error, "Use at most 16 providers in one pool."}
      true -> {:ok, providers}
    end
  end

  defp normalize_strategy(value) when value in ["priority", "round_robin"], do: {:ok, value}
  defp normalize_strategy(_value), do: {:error, "Choose priority or round robin."}

  defp normalize_credential_draft(params) do
    %{
      "pool" => safe_draft_identifier(params["pool"]),
      "provider" => safe_draft_identifier(params["provider"]),
      "operation" =>
        if(params["operation"] in ["add", "remove", "clear"],
          do: params["operation"],
          else: "add"
        )
    }
  end

  defp credential_action("add"), do: {:ok, "pool.credential.add"}
  defp credential_action("remove"), do: {:ok, "pool.credential.remove"}
  defp credential_action("clear"), do: {:ok, "pool.credential.clear"}
  defp credential_action(_operation), do: {:error, "Choose a supported credential operation."}

  defp credential_ref("pool.credential.clear", _value), do: {:ok, nil}

  defp credential_ref(_action, value) do
    case normalize_credential_ref(value) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "Enter a secret: or env: credential reference."}
    end
  end

  defp normalize_credential_ref(value) when is_binary(value) do
    value = String.trim(value)

    if byte_size(value) <= 160 and
         (Regex.match?(~r/^secret:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/, value) or
            Regex.match?(~r/^env:[A-Za-z_][A-Za-z0-9_]{0,127}$/, value)) do
      value
    else
      nil
    end
  end

  defp normalize_credential_ref(_value), do: nil

  defp credential_digest(nil), do: nil
  defp credential_digest(value), do: :crypto.hash(:sha256, value)

  defp credential_matches?(%{credential_digest: expected}, value)
       when is_binary(expected) and is_binary(value) do
    actual = credential_digest(value)
    byte_size(expected) == byte_size(actual) and :crypto.hash_equals(expected, actual)
  rescue
    _ -> false
  end

  defp credential_matches?(_pending, _value), do: false

  defp sanitize_confirmation(value), do: safe_optional_identifier(value) || "clear"
  defp normalize_confirmation(value), do: safe_optional_identifier(value) || ""

  defp find_pool(routing, name) do
    Enum.find(routing["credentialPools"], &(&1["name"] == name))
  end

  defp safe_count(value) when is_integer(value) and value >= 0, do: min(value, 10_000)
  defp safe_count(_value), do: 0

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_preview(socket, message) do
    assign(socket, pending_change: nil, notice: nil, error: message)
  end

  defp provider_error(:confirmation_required),
    do: "Exact confirmation was refused. Your draft and preview were kept."

  defp provider_error(:stale_configuration),
    do: "Provider configuration changed after preview. Preview the draft again."

  defp provider_error(code)
       when code in [
              :invalid_action,
              :invalid_credential_reference,
              :invalid_name,
              :invalid_provider,
              :invalid_providers,
              :invalid_revision,
              :invalid_scope,
              :invalid_strategy,
              :missing_parameter
            ],
       do: "The provider change is not valid. Review the fields and preview again."

  defp provider_error(:invalid_config),
    do: "The current Lemon configuration is not valid, so no provider change was written."

  defp provider_error(_code), do: "Provider configuration is temporarily unavailable."

  defp action_label(%{"action" => "fallback.add", "provider" => provider}),
    do: "Append fallback #{provider}"

  defp action_label(%{"action" => "fallback.remove", "provider" => provider}),
    do: "Remove fallback #{provider}"

  defp action_label(%{"action" => "fallback.clear"}), do: "Clear every fallback provider"

  defp action_label(%{"action" => "pool.upsert", "pool" => pool}),
    do: "Create or update pool #{pool}"

  defp action_label(%{"action" => "pool.delete", "pool" => pool}),
    do: "Delete pool #{pool}"

  defp action_label(%{"action" => action, "pool" => pool, "provider" => provider})
       when action in [
              "pool.credential.add",
              "pool.credential.remove",
              "pool.credential.clear"
            ],
       do: "Update credential-reference count for #{pool} / #{provider}"

  defp action_label(_params), do: "Provider routing change"

  defp preview_summary(routing) do
    "#{length(routing["fallbackProviders"])} fallback(s), " <>
      "#{routing["credentialPoolCount"]} pool(s), " <>
      "#{routing["credentialReferenceCount"]} opaque credential reference(s)"
  end

  defp status_dot_class(true), do: "management-status-dot management-status-dot-ok"
  defp status_dot_class(false), do: "management-status-dot management-status-dot-warning"

  defp routing_status_label(false, _enabled), do: "Unavailable"
  defp routing_status_label(true, true), do: "Enabled"
  defp routing_status_label(true, false), do: "Disabled"
end
