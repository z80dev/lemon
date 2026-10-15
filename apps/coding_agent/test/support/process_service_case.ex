defmodule CodingAgent.ExecutionNode.ProcessServiceCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias CodingAgent.ExecutionNode.ProcessService
  alias LemonCore.Store

  using do
    quote do
      alias CodingAgent.ExecutionNode.ProcessService
      alias LemonCore.Store
      import CodingAgent.ExecutionNode.ProcessServiceCase
      @moduletag :tmp_dir
    end
  end

  setup %{tmp_dir: root, test: test} do
    ctx = %{
      store: scoped_name(test, :store),
      server: scoped_name(test, :service)
    }

    start_supervised!(
      Supervisor.child_spec(
        {Store,
         name: ctx.store,
         backend: LemonCore.Store.SqliteBackend,
         backend_opts: [path: Path.join(root, "receipts.sqlite3"), ephemeral_tables: []]},
        id: ctx.store
      )
    )

    start_service(ctx)
    python = System.find_executable("python3")
    assert is_binary(python), "python3 is required for destination process execution"
    fixture = Path.join(__DIR__, "node_process_fixture.py")

    opts = [
      server: ctx.server,
      node_id: "process-node",
      session_generation: 11,
      invoke_id: "original-invocation",
      owner: self(),
      default_cwd: root,
      allowed_roots: [root]
    ]

    Map.merge(ctx, %{root: root, python: python, fixture: fixture, opts: opts})
  end

  def start_service(ctx) do
    start_supervised!({ProcessService, name: ctx.server, store: ctx.store})
  end

  def start_unavailable_service(ctx) do
    name = scoped_name(ctx.test, :unavailable_service)

    start_supervised!(
      Supervisor.child_spec(
        {ProcessService, name: name, store: scoped_name(ctx.test, :missing_store)},
        id: name
      )
    )

    name
  end

  # Names derive from the finite set of test names, not an unbounded unique counter.
  def scoped_name(test, role), do: :"#{__MODULE__}.#{test}.#{role}"

  def args(ctx, id, extra),
    do: %{
      "nodeId" => "process-node",
      "processId" => id,
      "cwd" => ctx.root,
      "argv" => [ctx.python, ctx.fixture | extra],
      "stdinBase64" => "",
      "timeoutMs" => 10_000,
      "maxOutputBytes" => 1_048_576
    }

  def run(args, opts), do: ProcessService.handle("node.process.run", args, opts)

  def get(id, opts),
    do:
      ProcessService.handle(
        "node.process.get",
        %{"nodeId" => "process-node", "processId" => id},
        opts
      )

  def cancel(id, opts),
    do:
      ProcessService.handle(
        "node.process.cancel",
        %{"nodeId" => "process-node", "processId" => id},
        opts
      )

  def unavailable(id, state),
    do: %{
      "nodeId" => "process-node",
      "processId" => id,
      "state" => state,
      "exitCode" => nil,
      "stdoutBase64" => nil,
      "stderrBase64" => nil,
      "outputTruncated" => true
    }

  def await_file(path, attempts \\ 200)
  def await_file(path, 0), do: flunk("fixture did not become ready: #{path}")

  def await_file(path, attempts) do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_file(path, attempts - 1)
        )
  end

  def await_state(id, expected, opts, attempts \\ 200)
  def await_state(_id, _expected, _opts, 0), do: flunk("process did not terminalize")

  def await_state(id, expected, opts, attempts) do
    case get(id, opts) do
      {:ok, %{"state" => ^expected} = receipt} ->
        receipt

      _ ->
        Process.sleep(10)
        await_state(id, expected, opts, attempts - 1)
    end
  end
end
