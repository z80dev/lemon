defmodule LemonCli.LearningCommandTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias LemonCli.{CLI, LearningCommand}

  defmodule Timeline do
    def for_profile(profile, opts) do
      send(self(), {:timeline, profile, opts})

      if profile == "unavailable" do
        {:error, {:private_error, "/private/path", "secret"}}
      else
        {:ok,
         %{
           "items" => [
             %{
               "at" => 1_700_000_000_000,
               "kind" => "skill",
               "action" => "patched",
               "id" => "safe-skill",
               "title" => "Safe skill",
               "preview" => "Current redacted preview"
             }
           ],
           "limit" => opts[:limit],
           "history" => "current_state"
         }}
      end
    end
  end

  setup do
    old = Application.get_env(:lemon_cli, :timeline_service)
    Application.put_env(:lemon_cli, :timeline_service, Timeline)

    on_exit(fn ->
      if old,
        do: Application.put_env(:lemon_cli, :timeline_service, old),
        else: Application.delete_env(:lemon_cli, :timeline_service)
    end)
  end

  test "registry dispatch prints human timeline and management hints" do
    text = capture_io(fn -> assert CLI.run(["learning"]) == 0 end)
    assert text =~ "skill/patched  safe-skill"
    assert text =~ "Current redacted preview"
    assert text =~ "remember(text, replaces)"
    assert text =~ "lemon skill draft"
    assert_received {:timeline, "default", [kind: "all", limit: 50]}
  end

  test "json is one document and forwards profile, kind and limit" do
    text =
      capture_io(fn ->
        assert LearningCommand.run([
                 "--profile",
                 "alice",
                 "--kind",
                 "skill",
                 "--limit",
                 "3",
                 "--json"
               ]) == 0
      end)

    assert Jason.decode!(text)["items"] |> hd() |> Map.fetch!("id") == "safe-skill"
    assert_received {:timeline, "alice", [kind: "skill", limit: 3]}
    refute text =~ "Manage memory"
  end

  test "invalid input is a usage error before service access" do
    for args <- [
          ["--limit", "0"],
          ["--limit", "101"],
          ["--kind", "run"],
          ["--profile", "../bob"],
          ["--wat"],
          ["delete"]
        ] do
      capture_io(:stderr, fn -> assert LearningCommand.run(args) == 2 end)
    end

    refute_received {:timeline, _, _}
  end

  test "service failure is redacted in json and text" do
    for suffix <- [[], ["--json"]] do
      text =
        capture_io(:stderr, fn ->
          assert LearningCommand.run(["--profile", "unavailable"] ++ suffix) == 1
        end)

      refute text =~ "/private/path"
      refute text =~ "secret"
      if suffix != [], do: assert(Jason.decode!(text)["error"] == "timeline_unavailable")
    end
  end
end
