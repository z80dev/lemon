defmodule LemonCore.Doctor.ProofLaunchGatesTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.ProofLaunchGates

  defmodule GatesStubChannelProofs do
    @behaviour LemonCore.Doctor.ChannelProofs

    @impl true
    def origin_cron_checks, do: []
    def media_delivery_check_names, do: []
    def media_delivery_proof(_checks), do: %{}
    def media_delivery_check(_proofs), do: nil
    def failure_hint(_hint), do: nil
    def setup_error_hint(_error), do: nil

    @impl true
    def launch_gates(_proof_status) do
      %{
        "channelDm" => %{
          "status" => "blocked",
          "reasonKind" => "channel_dm_setup_refused",
          "evidence" => "Channel DM setup was refused."
        },
        "channelRegistration" => %{
          "status" => "passed",
          "evidence" => "Channel command registration proof is completed."
        },
        "channelClientClick" => %{
          "status" => "warning",
          "reasonKind" => "channel_client_click_missing",
          "evidence" => "Channel client-click proof has not been captured."
        }
      }
    end
  end

  setup do
    original = Application.get_env(:lemon_core, :doctor_runtime, [])

    on_exit(fn -> Application.put_env(:lemon_core, :doctor_runtime, original) end)

    :ok
  end

  defp put_channel_proofs(module) do
    original = Application.get_env(:lemon_core, :doctor_runtime, [])

    Application.put_env(
      :lemon_core,
      :doctor_runtime,
      Keyword.put(original, :channel_proofs, module)
    )

    on_exit(fn -> Application.put_env(:lemon_core, :doctor_runtime, original) end)
  end

  defp clear_channel_proofs do
    original = Application.get_env(:lemon_core, :doctor_runtime, [])

    Application.put_env(
      :lemon_core,
      :doctor_runtime,
      Keyword.delete(original, :channel_proofs)
    )

    on_exit(fn -> Application.put_env(:lemon_core, :doctor_runtime, original) end)
  end

  test "summarizes proof launch gates from redacted proof diagnostics" do
    put_channel_proofs(GatesStubChannelProofs)

    proof_status = %{
      latest_checks: [
        %{
          name: "channel_registration_all",
          status: "completed",
          proof_object: "lemon.channel_live_matrix"
        },
        %{
          name: "channel_client_click_artifact",
          status: "failed",
          reason_kind: "channel_client_click_missing"
        }
      ],
      recent_proofs: [
        %{
          status: "completed",
          proof_object: "lemon.terminal_backend_smoke",
          proof_scopes: ["terminal_backend"],
          completed_count: 4,
          failed_count: 0,
          skipped_count: 0
        },
        %{
          status: "failed",
          provider: "vertex_imagen",
          reason_kind: "vertex_imagen_http_error:permission_denied"
        }
      ],
      reason_kind_counts: %{"channel_dm_setup_refused" => 1}
    }

    gates = ProofLaunchGates.status(proof_status)

    assert gates["channelDm"]["status"] == "blocked"
    assert gates["channelDm"]["reasonKind"] == "channel_dm_setup_refused"
    assert gates["channelRegistration"]["status"] == "passed"
    assert gates["channelClientClick"]["status"] == "warning"
    assert gates["providerMedia"]["status"] == "warning"
    assert gates["providerMedia"]["failedLaneCount"] == 1
    assert gates["providerMedia"]["lanes"]["image"]["status"] == "blocked"
    assert gates["terminalBackends"]["status"] == "passed"
    assert gates["terminalBackends"]["completedCount"] == 4

    assert ProofLaunchGates.summary(gates) == %{
             "status" => "blocked",
             "gateCount" => 5,
             "passedCount" => 2,
             "blockedCount" => 1,
             "warningCount" => 2,
             "missingCount" => 0,
             "statuses" => %{
               "channelDm" => "blocked",
               "channelRegistration" => "passed",
               "channelClientClick" => "warning",
               "providerMedia" => "warning",
               "terminalBackends" => "passed"
             }
           }
  end

  test "reports only the core gates when no proof spec is registered" do
    clear_channel_proofs()

    gates =
      ProofLaunchGates.status(%{
        latest_checks: [],
        recent_proofs: [],
        reason_kind_counts: %{}
      })

    assert Map.keys(gates) |> Enum.sort() == ["providerMedia", "terminalBackends"]
    assert gates["providerMedia"]["status"] == "warning"
    assert gates["terminalBackends"]["status"] == "warning"

    assert ProofLaunchGates.summary(gates) == %{
             "status" => "warning",
             "gateCount" => 2,
             "passedCount" => 0,
             "blockedCount" => 0,
             "warningCount" => 2,
             "missingCount" => 0,
             "statuses" => %{
               "providerMedia" => "warning",
               "terminalBackends" => "warning"
             }
           }
  end

  test "keeps proof launch gates redacted by construction" do
    clear_channel_proofs()

    gates =
      ProofLaunchGates.status(%{
        latest_checks: [],
        recent_proofs: [
          %{
            status: "failed",
            provider: "openai_vision",
            reason_kind: "provider_http_error",
            proof_hash: "safe-proof-hash"
          }
        ],
        reason_kind_counts: %{}
      })

    text = inspect(gates)

    assert gates["providerMedia"]["lanes"]["vision"]["reasonKind"] == "provider_http_error"
    refute text =~ "sk-"
    refute text =~ "private prompt"
    refute text =~ "/home/"
  end
end
