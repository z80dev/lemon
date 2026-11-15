defmodule CodingAgent.ProcessSandboxPolicy606Test do
  use ExUnit.Case, async: false

  alias CodingAgent.{ProcessStore, ProcessStoreServer}
  alias LemonCore.TerminalBackends.Docker.Sandbox

  test "managed launch attachment retains sandbox authority for restart" do
    id = "sandbox-metadata-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    owner = "sandbox-owner-" <> id
    fingerprint = :crypto.strong_rand_bytes(32)
    deadline = System.system_time(:millisecond) + 60_000
    assert :new = ProcessStore.register_launch(id, owner, fingerprint, deadline, self())

    on_exit(fn ->
      ProcessStore.cancel_launch(id, owner)
      ProcessStore.confirm_termination(id, :startup_failed)
      ProcessStore.delete(id)
    end)

    assert ^id =
             ProcessStore.new_process(%{
               id: id,
               owner: owner,
               command: "echo isolated",
               backend: :docker,
               tool_policy: %{sandbox: true},
               launch_fingerprint: fingerprint
             })

    # This is an explicit owner mailbox barrier, not an ETS timing assertion.
    :sys.get_state(ProcessStoreServer)
    assert {:ok, record, _logs} = ProcessStore.get(id)
    assert record.tool_policy == %{sandbox: true}
    assert {:ok, :docker} = Sandbox.backend(backend: :local, tool_policy: record.tool_policy)
  end
end
