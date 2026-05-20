defmodule LemonCore.Doctor.ProofLaunchGatesTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.ProofLaunchGates

  test "summarizes proof launch gates from redacted proof diagnostics" do
    proof_status = %{
      latest_checks: [
        %{
          name: "discord_all_slash_registration",
          status: "completed",
          proof_object: "lemon.discord_live_matrix"
        },
        %{
          name: "discord_slash_client_click_proof_artifact",
          status: "failed",
          reason_kind: "discord_slash_client_click_missing"
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
      reason_kind_counts: %{"discord_dm_setup_refused" => 1}
    }

    gates = ProofLaunchGates.status(proof_status)

    assert gates["discordDm"]["status"] == "blocked"
    assert gates["discordDm"]["reasonKind"] == "discord_dm_setup_refused"
    assert gates["discordSlashRegistration"]["status"] == "passed"
    assert gates["discordSlashClientClick"]["status"] == "warning"
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
               "discordDm" => "blocked",
               "discordSlashRegistration" => "passed",
               "discordSlashClientClick" => "warning",
               "providerMedia" => "warning",
               "terminalBackends" => "passed"
             }
           }
  end

  test "keeps proof launch gates redacted by construction" do
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
