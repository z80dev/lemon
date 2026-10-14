defmodule LemonCore.ToolPolicy do
  @moduledoc """
  Canonical native tool-policy data: validated JSON projections and restrictive
  composition. This module owns no policy state; callers supply current policy.
  Tool names are exact registry names, not operating-system sandbox capabilities.
  """

  @profiles ~w(full_access orchestrator leaf_worker minimal_core read_only safe_mode subagent_restricted no_external custom)
  @list_keys ~w(deny blocked_tools require_approval)
  @max_tool_entries 16_384
  @execution_json_items 131_072
  @execution_json_bytes 16_777_216

  @read_tools ["read", "read_skill", "recall", "grep", "find", "ls"]

  @minimal_core_tools [
    "read",
    "read_skill",
    "skill_manage",
    "remember",
    "recall",
    "checkpoint",
    "write",
    "edit",
    "patch",
    "ast_grep",
    "bash",
    "bash_output",
    "kill_process",
    "grep",
    "find",
    "ls",
    "webfetch",
    "websearch",
    "browser_tabs",
    "browser_tab_open",
    "browser_tab_activate",
    "browser_tab_close",
    "browser_navigate",
    "browser_snapshot",
    "browser_get_content",
    "browser_click",
    "browser_type",
    "browser_hover",
    "browser_select_option",
    "browser_upload_file",
    "browser_download",
    "browser_press",
    "browser_scroll",
    "browser_back",
    "browser_wait_for_selector",
    "browser_evaluate",
    "browser_events",
    "browser_get_cookies",
    "browser_set_cookies",
    "browser_clear_state",
    "browser_screenshot",
    "browser_analyze",
    "media_status",
    "media_generate_image",
    "media_generate_speech",
    "media_transcribe_audio",
    "media_analyze_image",
    "media_generate_video",
    "todo",
    "kanban",
    "goal",
    "cron",
    "task",
    "agent",
    "extensions_status"
  ]

  @external_tools [
    "webfetch",
    "websearch",
    "browser_tabs",
    "browser_tab_open",
    "browser_tab_activate",
    "browser_tab_close",
    "browser_navigate",
    "browser_snapshot",
    "browser_get_content",
    "browser_click",
    "browser_type",
    "browser_hover",
    "browser_select_option",
    "browser_upload_file",
    "browser_download",
    "browser_press",
    "browser_scroll",
    "browser_back",
    "browser_wait_for_selector",
    "browser_evaluate",
    "browser_events",
    "browser_get_cookies",
    "browser_set_cookies",
    "browser_clear_state",
    "browser_screenshot",
    "browser_analyze",
    "media_status",
    "media_generate_image",
    "media_generate_speech",
    "media_transcribe_audio",
    "media_analyze_image",
    "media_generate_video"
  ]

  @dangerous_tools [
    "write",
    "edit",
    "patch",
    "ast_grep",
    "checkpoint",
    "skill_manage",
    "remember",
    "bash",
    # Runs project compilers/checkers (`mix compile`, `cargo check`, `go test`),
    # which execute project code.
    "lsp_diagnostics",
    "kill_process",
    "agent",
    "task",
    "goal",
    "kanban",
    "cron",
    "browser_click",
    "browser_type",
    "browser_select_option",
    "browser_upload_file",
    "browser_download",
    "browser_press",
    "browser_set_cookies",
    "browser_clear_state",
    "browser_evaluate",
    "browser_screenshot",
    "browser_analyze",
    "media_generate_image",
    "media_generate_speech",
    "media_transcribe_audio",
    "media_analyze_image",
    "media_generate_video"
  ]
  @doc """
  JSON boundary defaults for rich native execution policy/connector payloads.
  Explicit lower transport limits remain authoritative; unrelated JSON payloads
  retain `LemonCore.JSONPayload` defaults.
  """
  def execution_json_opts(opts \\ []) do
    opts
    |> Keyword.put_new(:max_items, @execution_json_items)
    |> Keyword.put_new(:max_bytes, @execution_json_bytes)
  end
  @doc false
  def execution_max_bytes, do: @execution_json_bytes

  @doc false
  def execution_max_items, do: @execution_json_items

  @doc "Validate a native policy and return a bounded JSON-safe map."
  def normalize(policy) when is_map(policy) and not is_struct(policy) do
    Enum.reduce_while(policy, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key

      case normalize_field(key, value) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        :error -> {:halt, {:error, {:invalid_field, :tool_policy}}}
      end
    end)
  end

  def normalize(_), do: {:error, {:invalid_field, :tool_policy}}

  defp normalize_field("profile", value) do
    value = if is_atom(value), do: Atom.to_string(value), else: value
    if value in @profiles, do: {:ok, value}, else: :error
  end

  defp normalize_field("allow", value) when value in [:all, "all"], do: {:ok, "all"}
  defp normalize_field(key, value) when key in ["allow" | @list_keys], do: tool_names(value)
  defp normalize_field("no_reply", value) when is_boolean(value), do: {:ok, value}

  defp normalize_field("approvals", value) when is_map(value) and map_size(value) <= @max_tool_entries do
    Enum.reduce_while(value, {:ok, %{}}, fn {tool, mode}, {:ok, acc} ->
      mode = if is_atom(mode), do: Atom.to_string(mode), else: mode

      if tool_name?(tool) and mode in ["always", "never"] do
        {:cont, {:ok, Map.put(acc, tool, mode)}}
      else
        {:halt, :error}
      end
    end)
  end

  defp normalize_field(_, _), do: :error

  defp tool_names(names) when is_list(names) and length(names) <= @max_tool_entries do
    if Enum.all?(names, &tool_name?/1), do: {:ok, Enum.uniq(names)}, else: :error
  end

  defp tool_names(_), do: :error
  defp tool_name?(name) do
    is_binary(name) and String.valid?(name) and byte_size(name) in 1..256 and
      not Regex.match?(~r/[\x00-\x20\x7f]/, name)
  end

  @doc "Expand a native preset and intersect explicit restrictions with it."
  def expand(policy) when is_map(policy) do
    policy = atomize(policy)

    case Map.get(policy, :profile) do
      profile when is_atom(profile) and not is_nil(profile) -> intersect_fields(from_profile(profile), policy)
      profile when is_binary(profile) ->
        preset = Enum.find(@profiles, &(&1 == profile))
        if preset, do: intersect_fields(from_profile(String.to_existing_atom(preset)), policy), else: policy
      _ -> policy
    end
  end

  def expand(_), do: %{}

  @doc "Intersect allow-lists, union denials/approval gates; no caller can widen a floor."
  def intersect(left, right), do: intersect_fields(expand(left), expand(right))

  defp intersect_fields(left, right) do
    Map.merge(left, right, fn
      :allow, a, b -> intersect_allow(a, b)
      key, a, b when key in [:deny, :blocked_tools, :require_approval] -> Enum.uniq(a ++ b)
      :approvals, a, b ->
        Map.merge(a, b, fn _tool, first, second ->
          if first in [:always, "always"] or second in [:always, "always"], do: :always, else: second
        end)
      :no_reply, a, b -> a or b
      _key, _a, b -> b
    end)
  end

  defp intersect_allow(a, b) when a in [:all, "all"], do: b
  defp intersect_allow(a, b) when b in [:all, "all"], do: a
  defp intersect_allow(a, b) when is_list(a) and is_list(b) do
    if a == b do
      a
    else
      allowed = MapSet.new(b)
      Enum.filter(a, &MapSet.member?(allowed, &1))
    end
  end
  defp intersect_allow(_, _), do: []

  @doc "Normalize only known top-level keys without creating atoms from input."
  def atomize(policy) when is_map(policy) do
    Map.new(policy, fn {key, value} ->
      atom = Enum.find([:profile, :allow, :deny, :blocked_tools, :require_approval, :approvals, :no_reply], &(Atom.to_string(&1) == key))
      {atom || key, value}
    end)
  end
  def from_profile(:full_access) do
    %{
      allow: :all,
      deny: [],
      blocked_tools: [],
      require_approval: [],
      approvals: %{},
      no_reply: false,
      profile: :full_access
    }
  end

  def from_profile(:orchestrator) do
    %{
      allow: :all,
      deny: [],
      blocked_tools: [],
      require_approval: [],
      approvals: %{},
      no_reply: false,
      profile: :orchestrator
    }
  end

  def from_profile(:leaf_worker) do
    %{
      allow: :all,
      deny: ["task", "agent", "goal", "kanban", "cron"],
      blocked_tools: [],
      require_approval: [],
      approvals: %{},
      no_reply: false,
      profile: :leaf_worker
    }
  end

  def from_profile(:minimal_core) do
    %{
      allow: @minimal_core_tools,
      deny: [],
      blocked_tools: [],
      require_approval: [],
      approvals: %{},
      no_reply: false,

[Showing lines 1-300 of 367. Use :301 to continue]