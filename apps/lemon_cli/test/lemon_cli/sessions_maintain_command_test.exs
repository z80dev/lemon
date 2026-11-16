defmodule LemonCli.SessionsMaintainCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.{CLI, CommandRegistry, CompletionCommand, SessionClient}
  alias LemonControlPlane.Methods.Registry

  @cutoff 1_700_000_000_000
  @token "maintenance-preview-token"

  defmodule Handler do
    @behaviour LemonControlPlane.Method

    def name, do: "sessions.maintain"
    def scopes, do: [:admin]

    def handle(params, _ctx) do
      state = Agent.get(__MODULE__, & &1)
      send(state.owner, {:maintenance_request, params})
      state.reply.(params)
    end
  end

  setup do
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    original_handler = Registry.lookup("sessions.maintain")
    owner = self()

    state =
      start_supervised!(%{
        id: Handler,
        start:
          {Agent, :start_link,
           [fn -> %{owner: owner, reply: &preview_reply/1} end, [name: Handler]]}
      })

    system_keys =
      ~w(LEMON_CONTROL_PLANE_PORT LEMON_CONTROL_PLANE_OPERATOR_TOKEN LEMON_WS_TOKEN LEMON_LAUNCHER)

    previous_system = Map.new(system_keys, &{&1, System.get_env(&1)})
    app_keys = [:operator_token, :allow_unauthenticated_loopback_operator]
    previous_app = Map.new(app_keys, &{&1, Application.fetch_env(:lemon_control_plane, &1)})

    on_exit(fn ->
      if Process.whereis(Registry) do
        case original_handler do
          {:ok, handler} -> Registry.register(handler)
          {:error, :not_found} -> Registry.unregister("sessions.maintain")
        end
      end

      Enum.each(previous_system, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Enum.each(previous_app, fn
        {key, :error} -> Application.delete_env(:lemon_control_plane, key)
        {key, {:ok, value}} -> Application.put_env(:lemon_control_plane, key, value)
      end)
    end)

    :ok = Registry.register(Handler)
    token = "maintenance-cli-wire-operator"
    Application.put_env(:lemon_control_plane, :operator_token, token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)

    bandit =
      start_supervised!(
        {Bandit,
         plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    System.put_env("LEMON_CONTROL_PLANE_PORT", Integer.to_string(port))
    System.put_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN", token)
    System.delete_env("LEMON_WS_TOKEN")
    System.delete_env("LEMON_LAUNCHER")

    %{state: state}
  end

  test "default preview sends only a cutoff and dryRun and projects redacted JSON" do
    result = run_json(~w(sessions maintain --older-than #{@cutoff} --json))
    assert_receive {:maintenance_request, %{"olderThanMs" => @cutoff, "dryRun" => true} = request}
    assert map_size(request) == 2
    assert result["maintenance"]["dry_run"]
    assert result["maintenance"]["confirmation_token"] == @token
    assert result["maintenance"]["archive_count"] == 1
    assert result["maintenance"]["orphan_count"] == 1
    assert length(result["maintenance"]["candidates"]) == 2
    refute Jason.encode!(result) =~ "/private/"
    refute Jason.encode!(result) =~ "rawError"
  end

  test "adapter itself defaults to preview" do
    assert {:ok, %{dry_run: true}} = SessionClient.maintenance(older_than_ms: @cutoff)
    assert_receive {:maintenance_request, %{"olderThanMs" => @cutoff, "dryRun" => true}}
  end

  test "confirmed request preserves the exact cutoff and token", %{state: state} do
    preview = run_json(~w(sessions maintain --older-than #{@cutoff} --json))["maintenance"]
    assert_receive {:maintenance_request, %{"dryRun" => true}}

    Agent.update(state, fn state ->
      %{
        state
        | reply: fn params ->
            {:ok,
             report(params["olderThanMs"])
             |> Map.merge(%{
               "dryRun" => false,
               "archivedCount" => 1,
               "sweptCount" => 1,
               "verified" => true
             })}
          end
      }
    end)

    result =
      run_json([
        "sessions",
        "maintain",
        "--older-than",
        Integer.to_string(preview["older_than_ms"]),
        "--confirm",
        preview["confirmation_token"],
        "--json"
      ])

    assert_receive {:maintenance_request,
                    %{"olderThanMs" => @cutoff, "dryRun" => false, "confirmToken" => @token} =
                      request}

    assert map_size(request) == 3
    assert result["maintenance"]["verified"]
    assert result["maintenance"]["archived_count"] == 1
    assert result["maintenance"]["swept_count"] == 1
  end

  test "preview accepts dates and relative ages while text prints the exact execution command" do
    output =
      capture_io(fn -> assert CLI.run(~w(sessions maintain --older-than 2023-01-01)) == 0 end)

    cutoff = DateTime.to_unix(~U[2023-01-01 00:00:00Z], :millisecond)
    assert_receive {:maintenance_request, %{"olderThanMs" => ^cutoff, "dryRun" => true}}
    assert output =~ "lemon sessions maintain --older-than #{cutoff} --confirm #{@token}"
    assert output =~ "archive safe-native-id (17 bytes)"
    assert output =~ "orphan_artifact safe-orphan-id (29 bytes)"
    refute output =~ "/private/"

    before_ms = System.system_time(:millisecond) - 86_400_000
    _ = run_json(~w(sessions maintain --older-than 1d --json))
    after_ms = System.system_time(:millisecond) - 86_400_000
    assert_receive {:maintenance_request, %{"olderThanMs" => relative_cutoff, "dryRun" => true}}
    assert relative_cutoff >= before_ms and relative_cutoff <= after_ms
  end

  test "invalid options and non-exact confirmation cutoffs never reach the runtime" do
    for args <- [
          ~w(sessions maintain),
          ~w(sessions maintain extra --older-than 1d),
          ~w(sessions maintain --older-than 1d --all),
          ~w(sessions maintain --older-than 1d --include-pinned),
          ~w(sessions maintain --older-than 1d --dry-run),
          ~w(sessions maintain --older-than nope),
          ~w(sessions maintain --older-than 0),
          ~w(sessions maintain --older-than 0d),
          ~w(sessions maintain --older-than 1960-01-01),
          ~w(sessions maintain --older-than 2999-01-01),
          ~w(sessions maintain --older-than 1d --confirm token),
          ~w(sessions maintain --older-than 2023-01-01 --confirm token),
          ~w(sessions maintain --confirm token),
          ["sessions", "maintain", "--older-than", "#{@cutoff}", "--confirm", ""]
        ] do
      assert capture_io(:stderr, fn -> assert CLI.run(args) == 2 end) =~ "Usage: lemon sessions"
      refute_received {:maintenance_request, _}
    end
  end

  test "service errors use stable messages without echoing runtime details or retrying", %{
    state: state
  } do
    for {reason, code, expected} <- [
          {"confirmation_mismatch", :conflict, "confirmation_mismatch"},
          {"confirmation_required", :conflict, "confirmation_required"},
          {"invalid_older_than_ms", :invalid_params, "invalid_older_than_ms"},
          {"maintenance_unavailable", :unavailable, "maintenance_unavailable"}
        ],
        json? <- [false, true] do
      Agent.update(state, fn state ->
        %{
          state
          | reply: fn _ ->
              {:error,
               {code, "/private/runtime-secret",
                %{"reason" => reason, "path" => "/private/store"}}}
            end
        }
      end)

      args = ~w(sessions maintain --older-than #{@cutoff} --confirm #{@token})
      args = if json?, do: args ++ ["--json"], else: args
      error = capture_io(:stderr, fn -> assert CLI.run(args) == 1 end)
      refute error =~ "/private/"
      refute error =~ "runtime-secret"
      if json?, do: assert(Jason.decode!(error)["error"]["code"] == expected)
      assert_receive {:maintenance_request, %{"dryRun" => false}}
      refute_received {:maintenance_request, _}
    end
  end

  test "partial failures report safe counts without success or automatic retry", %{state: state} do
    partial =
      Map.merge(report(@cutoff), %{"dryRun" => false, "archivedCount" => 1, "verified" => false})

    Agent.update(state, fn state ->
      %{
        state
        | reply: fn _ ->
            {:error,
             {:internal_error, "/private/failure",
              %{"reason" => "partial_failure", "report" => partial}}}
          end
      }
    end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(~w(sessions maintain --older-than #{@cutoff} --confirm #{@token} --json)) ==
                 1
      end)
      |> Jason.decode!()

    refute error["ok"]
    assert error["error"]["code"] == "partial_maintenance_failure"
    assert error["maintenance"]["archived_count"] == 1
    refute error["maintenance"]["verified"]
    refute Jason.encode!(error) =~ "/private/"
    assert_receive {:maintenance_request, %{"dryRun" => false}}
    refute_received {:maintenance_request, _}
  end

  test "help and all completions include maintenance" do
    help = CommandRegistry.help("sessions")
    assert help =~ "maintain"
    assert help =~ "exact epoch millisecond cutoff"

    for launcher <- [:source, :release], shell <- ~w(bash zsh fish) do
      assert CompletionCommand.render(shell, launcher) =~ "maintain"
    end
  end

  defp preview_reply(params), do: {:ok, report(params["olderThanMs"])}

  defp report(cutoff) do
    %{
      "dryRun" => true,
      "olderThanMs" => cutoff,
      "confirmationToken" => @token,
      "archiveCount" => 1,
      "orphanCount" => 1,
      "archivedCount" => 0,
      "sweptCount" => 0,
      "verified" => false,
      "candidates" => [
        %{
          "kind" => "archive",
          "id" => "safe-native-id",
          "bytes" => 17,
          "path" => "/private/journal"
        },
        %{"kind" => "orphan_artifact", "id" => "safe-orphan-id", "bytes" => 29}
      ],
      "rawError" => "/private/diagnostic"
    }
  end

  defp run_json(args) do
    capture_io(fn -> assert CLI.run(args) == 0 end) |> Jason.decode!()
  end
end
