defmodule LemonCli.BlueprintsCommandTestClient do
  def request(method, params) do
    send(
      Application.fetch_env!(:lemon_cli, :blueprints_command_test_pid),
      {:blueprint_request, method, params}
    )

    case Application.get_env(:lemon_cli, :blueprints_command_test_result) do
      nil -> response(method, params)
      result -> result
    end
  end

  defp response("blueprints.list", _params) do
    {:ok,
     %{
       "bundles" => [review()],
       "summary" => %{
         "bundleCount" => 1,
         "invalidBundleCount" => 0,
         "truncated" => false,
         "pathsReturned" => false,
         "secretValuesReturned" => false
       }
     }}
  end

  defp response(method, %{"bundleId" => "daily-note"})
       when method in ["blueprints.inspect", "blueprints.validate"],
       do: {:ok, review()}

  defp response("blueprints.preview", %{
         "bundleId" => "daily-note",
         "profileId" => "operator"
       }) do
    {:ok, preview()}
  end

  defp response("blueprints.activate", %{
         "bundleId" => "daily-note",
         "profileId" => "operator",
         "confirmationDigest" => confirmation
       }) do
    {:ok,
     %{
       "activated" => true,
       "bundleId" => "daily-note",
       "profileId" => "operator",
       "confirmationDigest" => confirmation,
       "skills" => [
         %{
           "key" => "daily-note",
           "status" => "unchanged",
           "bundleHash" => String.duplicate("b", 64),
           "trustLevel" => "untrusted",
           "auditStatus" => "pass"
         }
       ],
       "automation" => %{
         "id" => "cron_blueprint_safe",
         "status" => "unchanged",
         "kind" => "cron"
       },
       "summary" => %{
         "duplicateSafe" => true,
         "promptTextReturned" => false,
         "skillTextReturned" => false,
         "secretValuesReturned" => false,
         "pathsReturned" => false
       }
     }}
  end

  defp review do
    %{
      "format" => "lemon-skill-automation-bundle",
      "version" => 1,
      "id" => "daily-note",
      "name" => "Daily note",
      "description" => "A safe disabled reminder",
      "manifestDigest" => String.duplicate("a", 64),
      "skills" => [
        %{
          "key" => "daily-note",
          "bundleHash" => String.duplicate("b", 64),
          "fileCount" => 1,
          "bytes" => 120,
          "sourceKind" => "portable_bundle",
          "trustLevel" => "untrusted",
          "auditStatus" => "pass"
        }
      ],
      "automations" => [
        %{
          "id" => "daily-note-reminder",
          "name" => "Daily note reminder",
          "kind" => "cron",
          "schedule" => "0 0 1 1 *",
          "enabled" => false,
          "timezone" => "UTC",
          "promptBytes" => 52,
          "promptSha256" => String.duplicate("c", 64)
        }
      ],
      "validation" => %{"valid" => true, "auditStatus" => "pass"},
      "summary" => %{
        "skillCount" => 1,
        "automationCount" => 1,
        "promptTextReturned" => false,
        "skillTextReturned" => false,
        "pathsReturned" => false,
        "secretValuesReturned" => false
      }
    }
  end

  defp preview do
    %{
      "format" => "lemon-skill-automation-bundle",
      "version" => 1,
      "bundleId" => "daily-note",
      "manifestDigest" => String.duplicate("a", 64),
      "definitionDigest" => String.duplicate("d", 64),
      "confirmationDigest" => String.duplicate("e", 64),
      "profile" => %{
        "id" => "operator",
        "canonicalSessionKey" => "agent:operator:main",
        "workspaceBoundary" => "derived-profile-workspace"
      },
      "skills" => [
        %{
          "key" => "daily-note",
          "action" => "create",
          "bundleHash" => String.duplicate("b", 64),
          "fileCount" => 1,
          "bytes" => 120,
          "sourceKind" => "portable_bundle",
          "trustLevel" => "untrusted",
          "auditStatus" => "pass",
          "currentDigest" => nil
        }
      ],
      "automation" => %{
        "id" => "cron_blueprint_safe",
        "action" => "create",
        "kind" => "cron",
        "name" => "Daily note reminder",
        "schedule" => "0 0 1 1 *",
        "enabled" => false,
        "timezone" => "UTC",
        "promptBytes" => 52,
        "promptSha256" => String.duplicate("c", 64),
        "target" => %{
          "agentId" => "operator",
          "sessionKey" => "agent:operator:main"
        },
        "promptTextReturned" => false
      },
      "canActivate" => true,
      "cleanup" => %{
        "includesPromptText" => false,
        "includesSkillText" => false,
        "includesSecretValues" => false,
        "includesAbsolutePaths" => false
      }
    }
  end
end

defmodule LemonCli.BlueprintsCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI

  @confirmation String.duplicate("e", 64)
  @secret "sk-blueprint-cli-must-not-leak"
  @path "/private/blueprint/catalog/daily-note"
  @prompt "Use the daily-note skill to summarize private completed work."

  setup do
    previous_client = Application.get_env(:lemon_cli, :control_plane_client)
    previous_result = Application.get_env(:lemon_cli, :blueprints_command_test_result)
    Application.put_env(:lemon_cli, :control_plane_client, LemonCli.BlueprintsCommandTestClient)
    Application.put_env(:lemon_cli, :blueprints_command_test_pid, self())

    on_exit(fn ->
      restore_env(:lemon_cli, :control_plane_client, previous_client)
      restore_env(:lemon_cli, :blueprints_command_test_result, previous_result)
      Application.delete_env(:lemon_cli, :blueprints_command_test_pid)
    end)

    :ok
  end

  test "bare family lists and bundle shorthand previews without mutation" do
    listed = capture_io(fn -> assert CLI.run(["blueprints", "--json"]) == 0 end)

    assert %{"bundles" => [%{"id" => "daily-note"}]} = Jason.decode!(listed)
    assert_receive {:blueprint_request, "blueprints.list", %{}}

    previewed =
      capture_io(fn ->
        assert CLI.run(["blueprints", "daily-note", "--profile", "operator", "--json"]) ==
                 0
      end)

    assert %{
             "bundleId" => "daily-note",
             "canActivate" => true,
             "confirmationDigest" => @confirmation
           } = Jason.decode!(previewed)

    assert_receive {:blueprint_request, "blueprints.preview",
                    %{"bundleId" => "daily-note", "profileId" => "operator"}}

    refute_received {:blueprint_request, "blueprints.activate", _params}
    assert_clean(previewed)
  end

  test "inspect and validate request only a catalog ID and keep JSON content-free" do
    for operation <- ~w(inspect validate) do
      output =
        capture_io(fn ->
          assert CLI.run(["blueprints", operation, "daily-note", "--json"]) == 0
        end)

      assert %{"id" => "daily-note", "validation" => %{"valid" => true}} =
               Jason.decode!(output)

      assert_receive {:blueprint_request, "blueprints." <> ^operation,
                      %{"bundleId" => "daily-note"}}

      assert_clean(output)
    end
  end

  test "activation requires a shaped exact digest and sends no path or content fields" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run([
                 "blueprints",
                 "activate",
                 "daily-note",
                 "--profile",
                 "operator",
                 "--confirm",
                 "wrong"
               ]) == 2
      end)

    assert error =~ "exact 64-character preview digest"
    refute_received {:blueprint_request, "blueprints.activate", _params}

    output =
      capture_io(fn ->
        assert CLI.run([
                 "blueprints",
                 "activate",
                 "daily-note",
                 "--profile",
                 "operator",
                 "--confirm",
                 @confirmation,
                 "--json"
               ]) == 0
      end)

    assert %{"activated" => true, "summary" => %{"duplicateSafe" => true}} =
             Jason.decode!(output)

    assert_receive {:blueprint_request, "blueprints.activate", params}

    assert params == %{
             "bundleId" => "daily-note",
             "profileId" => "operator",
             "confirmationDigest" => @confirmation
           }

    refute Map.has_key?(params, "path")
    refute Map.has_key?(params, "root")
    refute Map.has_key?(params, "prompt")
    refute Map.has_key?(params, "secret")
    assert_clean(output)
  end

  test "path-like bundle IDs and unsupported options are usage errors before RPC" do
    for args <- [
          ["blueprints", "inspect", "../daily-note"],
          ["blueprints", "preview", "/tmp/daily-note", "--profile", "operator"],
          ["blueprints", "list", "--path", @path],
          ["blueprints", "activate", "daily-note", "--profile", "operator", "--script", "x"]
        ] do
      capture_io(:stderr, fn -> assert CLI.run(args) == 2 end)
    end

    refute_received {:blueprint_request, _, _}
  end

  test "operational JSON errors are stable and do not stringify transport reasons" do
    Application.put_env(
      :lemon_cli,
      :blueprints_command_test_result,
      {:error, {:control_plane_unavailable, {:econnrefused, @path, @secret}}}
    )

    output =
      capture_io(:stderr, fn ->
        assert CLI.run(["blueprints", "list", "--json"]) == 1
      end)

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "CONTROL_PLANE_UNAVAILABLE",
               "message" => "The Lemon control plane is unavailable"
             }
           } = Jason.decode!(output)

    assert_clean(output)
  end

  test "safe control-plane conflicts preserve only the protocol code and message" do
    Application.put_env(
      :lemon_cli,
      :blueprints_command_test_result,
      {:error,
       {:control_plane,
        %{
          "code" => "CONFLICT",
          "message" => "Confirmation digest is missing, stale, or incorrect",
          "details" => %{"path" => @path, "secret" => @secret}
        }}}
    )

    output =
      capture_io(:stderr, fn ->
        assert CLI.run([
                 "blueprints",
                 "activate",
                 "daily-note",
                 "--profile",
                 "operator",
                 "--confirm",
                 @confirmation,
                 "--json"
               ]) == 1
      end)

    assert %{
             "error" => %{
               "code" => "CONFLICT",
               "message" => "Confirmation digest is missing, stale, or incorrect"
             },
             "ok" => false
           } = Jason.decode!(output)

    assert_clean(output)
  end

  defp assert_clean(output) do
    refute output =~ @secret
    refute output =~ @path
    refute output =~ @prompt
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
