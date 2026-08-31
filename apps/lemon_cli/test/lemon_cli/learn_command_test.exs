defmodule LemonCli.LearnCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.LearnCommand

  defmodule FakeLearn do
    def review(references, opts), do: response("review", references, opts)

    def confirm(references, digest, opts) do
      send(self(), {:confirmed, references, digest, opts})
      response("confirmed", references, opts)
    end

    defp response(status, references, _opts) do
      {:ok,
       %{
         "status" => status,
         "canConfirm" => true,
         "confirmationDigest" => String.duplicate("a", 64),
         "sources" => %{"count" => length(references), "selectedBytes" => 12},
         "memory" => %{"action" => "create", "id" => "mem_learn_safe"},
         "skill" => %{
           "action" => "create",
           "key" => "learned-source-safe",
           "auditVerdict" => "pass"
         },
         "conflicts" => []
       }}
    end
  end

  setup do
    old = Application.get_env(:lemon_cli, :learn_service)
    Application.put_env(:lemon_cli, :learn_service, FakeLearn)

    on_exit(fn ->
      if old,
        do: Application.put_env(:lemon_cli, :learn_service, old),
        else: Application.delete_env(:lemon_cli, :learn_service)
    end)
  end

  test "review is the default and emits one sanitized JSON document" do
    output =
      capture_io(fn ->
        assert LearnCommand.run(["@file:guide.md", "--json", "--agent-id", "operator"]) == 0
      end)

    assert Jason.decode!(output)["status"] == "review"
  end

  test "confirm forwards the exact digest and bounded options" do
    digest = String.duplicate("b", 64)

    capture_io(fn ->
      assert LearnCommand.run([
               "confirm",
               "@folder:docs",
               "--confirm",
               digest,
               "--root",
               "/safe/root",
               "--project"
             ]) == 0
    end)

    assert_received {:confirmed, ["@folder:docs"], ^digest, opts}
    assert opts[:root] == "/safe/root"
    assert opts[:global] == false
  end

  test "confirm without a digest is a usage error and never invokes the service" do
    stderr =
      capture_io(:stderr, fn ->
        assert LearnCommand.run(["confirm", "@file:guide.md"]) == 2
      end)

    assert stderr =~ "exact digest"
    refute_received {:confirmed, _, _, _}
  end
end
