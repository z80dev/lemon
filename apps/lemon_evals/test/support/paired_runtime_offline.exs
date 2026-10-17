# Trusted fixture loaded only in the disposable compiled-runtime gate. Every AI
# API is replaced with this in-memory transport; no HTTP provider can be reached.
defmodule LemonEvals.PairedRuntimeOffline do
  alias LemonAi.Types.{AssistantMessage, Cost, TextContent, Usage}

  def api_id, do: :offline_fixture
  def provider_id, do: :offline_fixture

  def stream(model, _context, options) do
    root = System.fetch_env!("LEMON_EVAL_STATE")
    File.write!(Path.join(root, "offline-requests"), "fixture\n", [:append])

    if is_function(options.on_payload, 2) do
      options.on_payload.(
        %{"instructions" => "offline fixture", "tools" => [], "input" => []},
        %{}
      )
    end

    if is_function(options.on_usage, 2) do
      options.on_usage.(%{input_tokens: 1, output_tokens: 1, cache_read_tokens: 0}, %{})
    end

    message = %AssistantMessage{
      role: :assistant,
      content: [%TextContent{text: "Production uses 7317; staging uses 7304."}],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: %Usage{input: 1, output: 1, total_tokens: 2, cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }

    {:ok, stream} = LemonAi.EventStream.start_link()
    LemonAi.EventStream.complete(stream, message)
    {:ok, stream}
  end

  def install! do
    for api <- LemonAi.ProviderRegistry.list() do
      :ok = LemonAi.ProviderRegistry.register(api, __MODULE__)
    end

    listeners =
      for {label, supervisor} <- [
            {:control, LemonControlPlane.Supervisor},
            {:gateway, LemonGateway.Supervisor},
            {:router, LemonRouter.Supervisor},
            {:web, LemonWeb.Endpoint},
            {:sim, LemonSimUi.Endpoint}
          ],
          into: %{} do
        sockets =
          for {_id, pid, :supervisor, _modules} <- Supervisor.which_children(supervisor),
              is_pid(pid),
              {:ok, {ip, port}} <- [ThousandIsland.listener_info(pid)] do
            %{ip: to_string(:inet.ntoa(ip)), port: port}
          end

        {label, sockets}
      end

    proof = %{
      profile: LemonCore.Config.load().agent.tools.disclosure[:profile],
      listeners: listeners,
      tracked_live_groups:
        Enum.count(LemonCore.NativeProcess.snapshot(), fn {_id, record, _logs} ->
          record.backend == :local and
            match?(
              {:alive, _},
              LemonCore.ProcessGroup.workload_group_status(record.workload_identity)
            )
        end),
      unsupported:
        Enum.count(LemonCore.NativeProcess.snapshot(), fn {_id, record, _logs} ->
          record.backend == :unsupported
        end)
    }

    File.write!(
      Path.join(System.fetch_env!("LEMON_EVAL_STATE"), "boot-proof.json"),
      Jason.encode!(proof)
    )
  end
end
