{:ok, _} = Application.ensure_all_started(:lemon_core)

alias AgentCore.Types.AgentToolResult
alias Ai.Types.TextContent
alias CodingAgent.ToolRegistry

defmodule LemonScripts.ExtensionHostSmoke.TelemetryHandler do
  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:extension_tool_telemetry, event, measurements, metadata})
  end
end

ToolRegistry.invalidate_extension_cache()
CodingAgent.Extensions.clear_extension_cache()

now = DateTime.utc_now()
suffix = System.system_time(:millisecond) |> rem(1_000_000_000)
project_dir = Path.join(System.tmp_dir!(), "lemon-extension-host-proof-#{suffix}")
default_dir = Path.join([project_dir, ".lemon", "extensions"])
trusted_dir = Path.join(project_dir, "trusted_extensions")
disabled_project_dir = Path.join(System.tmp_dir!(), "lemon-extension-disabled-proof-#{suffix}")
disabled_trusted_dir = Path.join(disabled_project_dir, "trusted_extensions")
disabled_marker_path = Path.join(disabled_project_dir, "disabled-extension-loaded.txt")

env_disabled_project_dir =
  Path.join(System.tmp_dir!(), "lemon-extension-env-disabled-proof-#{suffix}")

env_disabled_trusted_dir = Path.join(env_disabled_project_dir, "trusted_extensions")

env_disabled_marker_path =
  Path.join(env_disabled_project_dir, "env-disabled-extension-loaded.txt")

telemetry_ref = "extension-host-smoke-#{suffix}"

:ok =
  :telemetry.attach_many(
    telemetry_ref,
    [
      [:coding_agent, :extension, :tool, :start],
      [:coding_agent, :extension, :tool, :stop],
      [:coding_agent, :extension, :tool, :exception]
    ],
    &LemonScripts.ExtensionHostSmoke.TelemetryHandler.handle_event/4,
    self()
  )

File.rm_rf!(project_dir)
File.rm_rf!(disabled_project_dir)
File.rm_rf!(env_disabled_project_dir)
File.mkdir_p!(default_dir)
File.mkdir_p!(trusted_dir)
File.mkdir_p!(Path.join(disabled_project_dir, ".lemon"))
File.mkdir_p!(disabled_trusted_dir)
File.mkdir_p!(Path.join(env_disabled_project_dir, ".lemon"))
File.mkdir_p!(env_disabled_trusted_dir)

default_module = "LemonDefaultExtensionProof#{suffix}"
trusted_module = "LemonTrustedExtensionProof#{suffix}"
conflict_module = "LemonConflictExtensionProof#{suffix}"
exception_module = "LemonExceptionExtensionProof#{suffix}"
disabled_module = "LemonDisabledExtensionProof#{suffix}"
env_disabled_module = "LemonEnvDisabledExtensionProof#{suffix}"

extension_code = fn module_name, extension_name, tool_name, body ->
  """
  defmodule #{module_name} do
    @behaviour CodingAgent.Extensions.Extension

    @impl true
    def name, do: "#{extension_name}"

    @impl true
    def version, do: "1.0.0"

    @impl true
    def capabilities, do: [:tools]

    @impl true
    def tools(_cwd) do
      [
        %AgentCore.Types.AgentTool{
          name: "#{tool_name}",
          description: "extension host proof tool",
          parameters: %{
            "type" => "object",
            "properties" => %{"input" => %{"type" => "string"}},
            "required" => ["input"]
          },
          label: "Extension Host Proof",
          execute: fn tool_call_id, params, _signal, on_update ->
            _ = params

            if is_function(on_update, 1) do
              on_update.(%AgentCore.Types.AgentToolResult{
                content: [%Ai.Types.TextContent{text: "extension update"}],
                details: %{tool_call_id_seen: is_binary(tool_call_id)}
              })
            end

            #{body}
          end
        }
      ]
    end
  end
  """
end

File.write!(
  Path.join(default_dir, "default_extension.exs"),
  extension_code.(
    default_module,
    "default-extension-proof",
    "untrusted_default_extension_tool",
    """
    %AgentCore.Types.AgentToolResult{content: [%Ai.Types.TextContent{text: "default"}], details: %{}}
    """
  )
)

File.write!(
  Path.join(trusted_dir, "trusted_extension.exs"),
  extension_code.(
    trusted_module,
    "trusted-extension-proof",
    "lemon_extension_echo",
    """
    %AgentCore.Types.AgentToolResult{
      content: [%Ai.Types.TextContent{text: "extension_echo:" <> Map.get(params, "input", "")}],
      details: %{host: :beam, trusted_path: true}
    }
    """
  )
)

File.write!(
  Path.join(trusted_dir, "conflict_extension.exs"),
  extension_code.(
    conflict_module,
    "conflict-extension-proof",
    "read",
    """
    %AgentCore.Types.AgentToolResult{content: [%Ai.Types.TextContent{text: "shadowed"}], details: %{}}
    """
  )
)

File.write!(
  Path.join(trusted_dir, "exception_extension.exs"),
  extension_code.(
    exception_module,
    "exception-extension-proof",
    "lemon_extension_raises",
    """
    raise "private extension smoke exception"
    """
  )
)

File.write!(
  Path.join([disabled_project_dir, ".lemon", "config.toml"]),
  """
  [runtime.extensions]
  enabled = false
  auto_load_default_paths = true
  """
)

File.write!(
  Path.join(disabled_trusted_dir, "disabled_extension.exs"),
  extension_code.(
    disabled_module,
    "disabled-extension-proof",
    "disabled_extension_tool",
    """
    File.write!(#{inspect(disabled_marker_path)}, "loaded")
    %AgentCore.Types.AgentToolResult{content: [%Ai.Types.TextContent{text: "disabled"}], details: %{}}
    """
  )
)

File.write!(
  Path.join([env_disabled_project_dir, ".lemon", "config.toml"]),
  """
  [runtime.extensions]
  enabled = true
  auto_load_default_paths = true
  """
)

File.write!(
  Path.join(env_disabled_trusted_dir, "env_disabled_extension.exs"),
  extension_code.(
    env_disabled_module,
    "env-disabled-extension-proof",
    "env_disabled_extension_tool",
    """
    File.write!(#{inspect(env_disabled_marker_path)}, "loaded")
    %AgentCore.Types.AgentToolResult{content: [%Ai.Types.TextContent{text: "disabled"}], details: %{}}
    """
  )
)

default_tool_present? =
  project_dir
  |> ToolRegistry.list_tool_names()
  |> Enum.member?("untrusted_default_extension_tool")

{:ok, extension_tool} =
  ToolRegistry.get_tool(project_dir, "lemon_extension_echo", extension_paths: [trusted_dir])

{:ok, exception_tool} =
  ToolRegistry.get_tool(project_dir, "lemon_extension_raises", extension_paths: [trusted_dir])

updates = []

result =
  extension_tool.execute.(
    "extension-proof-call",
    %{"input" => "ok"},
    nil,
    fn update -> send(self(), {:extension_update, update}) end
  )

exception_result =
  try do
    exception_tool.execute.(
      "extension-exception-call",
      %{"input" => "boom", "secret" => "do-not-leak"},
      nil,
      nil
    )

    :unexpected_success
  rescue
    RuntimeError -> :raised
  end

telemetry_events =
  Enum.reduce(1..6, [], fn _, events ->
    receive do
      {:extension_tool_telemetry, event, measurements, metadata} ->
        [{event, measurements, metadata} | events]
    after
      50 -> events
    end
  end)
  |> Enum.reverse()

updates =
  receive do
    {:extension_update, update} -> [update | updates]
  after
    100 -> updates
  end

conflict_report = ToolRegistry.tool_conflict_report(project_dir, extension_paths: [trusted_dir])
read_tool = ToolRegistry.get_tool(project_dir, "read", extension_paths: [trusted_dir])

disabled_tool =
  ToolRegistry.get_tool(disabled_project_dir, "disabled_extension_tool",
    extension_paths: [disabled_trusted_dir]
  )

previous_extensions_enabled = System.get_env("LEMON_EXTENSIONS_ENABLED")

env_disabled_tool =
  try do
    System.put_env("LEMON_EXTENSIONS_ENABLED", "false")

    ToolRegistry.get_tool(env_disabled_project_dir, "env_disabled_extension_tool",
      extension_paths: [env_disabled_trusted_dir]
    )
  after
    if is_nil(previous_extensions_enabled) do
      System.delete_env("LEMON_EXTENSIONS_ENABLED")
    else
      System.put_env("LEMON_EXTENSIONS_ENABLED", previous_extensions_enabled)
    end
  end

result_text =
  case result do
    %AgentToolResult{content: [%TextContent{text: text} | _]} -> text
    _ -> nil
  end

update_text =
  case updates do
    [%AgentToolResult{content: [%TextContent{text: text} | _]} | _] -> text
    _ -> nil
  end

run_check = fn name, fun ->
  status =
    try do
      if fun.(), do: "completed", else: "failed"
    rescue
      _ -> "failed"
    end

  %{name: name, status: status}
end

checks = [
  run_check.("default_extension_directory_does_not_execute_without_trust", fn ->
    default_tool_present? == false
  end),
  run_check.("explicit_extension_path_loads_beam_tool", fn ->
    extension_tool.name == "lemon_extension_echo"
  end),
  run_check.("extension_tool_executes_through_registry", fn ->
    result_text == "extension_echo:ok" and update_text == "extension update"
  end),
  run_check.("extension_tool_execution_emits_redacted_telemetry", fn ->
    has_start? =
      Enum.any?(telemetry_events, fn
        {[:coding_agent, :extension, :tool, :start], %{count: 1}, metadata} ->
          metadata.tool_name == "lemon_extension_echo" and metadata.host == :beam and
            is_binary(metadata.extension_hash) and is_binary(metadata.tool_call_hash)

        _ ->
          false
      end)

    has_stop? =
      Enum.any?(telemetry_events, fn
        {[:coding_agent, :extension, :tool, :stop], %{count: 1, duration_us: duration_us},
         metadata} ->
          metadata.tool_name == "lemon_extension_echo" and metadata.host == :beam and
            metadata.status == :ok and is_integer(duration_us)

        _ ->
          false
      end)

    has_exception? =
      Enum.any?(telemetry_events, fn
        {[:coding_agent, :extension, :tool, :exception], %{count: 1, duration_us: duration_us},
         metadata} ->
          metadata.tool_name == "lemon_extension_raises" and metadata.host == :beam and
            metadata.kind == :error and metadata.error_type == "Elixir.RuntimeError" and
            is_integer(duration_us)

        _ ->
          false
      end)

    telemetry_text = inspect(telemetry_events)

    has_start? and has_stop? and has_exception? and exception_result == :raised and
      not String.contains?(telemetry_text, "extension-proof-call") and
      not String.contains?(telemetry_text, "extension-exception-call") and
      not String.contains?(telemetry_text, "do-not-leak") and
      not String.contains?(telemetry_text, "private extension smoke exception") and
      not String.contains?(telemetry_text, trusted_dir) and
      not String.contains?(telemetry_text, project_dir)
  end),
  run_check.("builtin_tool_wins_extension_conflict", fn ->
    match?({:ok, %{name: "read"}}, read_tool) and
      Enum.any?(conflict_report.conflicts, fn conflict ->
        conflict.tool_name == "read" and conflict.winner == :builtin and conflict.shadowed != []
      end)
  end),
  run_check.("extensions_disabled_blocks_explicit_path_execution", fn ->
    match?({:error, _}, disabled_tool) and not File.exists?(disabled_marker_path)
  end),
  run_check.("extensions_env_disabled_blocks_explicit_path_execution", fn ->
    match?({:error, _}, env_disabled_tool) and not File.exists?(env_disabled_marker_path)
  end)
]

completed_count = Enum.count(checks, &(&1.status == "completed"))
failed_count = Enum.count(checks, &(&1.status == "failed"))

proof = %{
  "proof" => "extension_host_smoke",
  "status" => if(failed_count == 0, do: "completed", else: "failed"),
  "generated_at" => DateTime.to_iso8601(now),
  "completed_count" => completed_count,
  "failed_count" => failed_count,
  "checks" => checks,
  "host_boundary" => %{
    "host" => "beam",
    "default_directories_diagnostics_only" => true,
    "explicit_trust_boundary" => "extension_paths",
    "disabled_execution_blocks_explicit_paths" => true,
    "extension_tool_count" => conflict_report.extension_count,
    "shadowed_tool_count" => conflict_report.shadowed_count
  },
  "redaction" => %{
    "contains_raw_paths" => false,
    "contains_file_contents" => false,
    "contains_load_error_messages" => false,
    "contains_tool_result_payload" => false
  }
}

File.mkdir_p!(".lemon/proofs")
json = Jason.encode!(proof, pretty: true)
File.write!(".lemon/proofs/extension-host-smoke-latest.json", json <> "\n")

archive =
  ".lemon/proofs/extension-host-smoke-" <>
    (now |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")) <> ".json"

File.write!(archive, json <> "\n")

for module_name <- [
      default_module,
      trusted_module,
      conflict_module,
      exception_module,
      disabled_module,
      env_disabled_module
    ] do
  module = Module.concat([module_name])
  :code.purge(module)
  :code.delete(module)
end

File.rm_rf!(project_dir)
File.rm_rf!(disabled_project_dir)
File.rm_rf!(env_disabled_project_dir)
ToolRegistry.invalidate_extension_cache()
CodingAgent.Extensions.clear_extension_cache()
:telemetry.detach(telemetry_ref)

if failed_count == 0 do
  IO.puts("extension host smoke proof passed: #{completed_count} completed")
else
  IO.puts("extension host smoke proof failed: #{failed_count} failed")
  System.halt(1)
end
