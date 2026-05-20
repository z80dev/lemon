defmodule LemonControlPlane.Methods.OptionalParityMethodsExtendedTest do
  @moduledoc """
  Extended tests for optional parity methods with full implementations.

  Tests cover:
  - browser.request forwarding to browser nodes
  - tts.convert with system TTS
  - update.run with update manifest fetching
  - usage.cost with record_usage tracking
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.{NodeStore, UpdateStore}
  alias LemonCore.Checkpoint

  alias LemonControlPlane.Methods.{
    CheckpointDiff,
    CheckpointRestore,
    BrowserRequest,
    BrowserStatus,
    ChannelsStatus,
    CheckpointStatus,
    ExtensionsStatus,
    LspDiagnosticsStatus,
    LspDocumentChange,
    LspDocumentClose,
    LspDocumentOpen,
    LspServerInitialize,
    LspServerRequest,
    LspServerStart,
    LspServerStop,
    MemoryStatus,
    MediaStatus,
    ProofsStatus,
    ProvidersStatus,
    ReadinessStatus,
    SkillsStatus,
    TerminalBackendsStatus,
    TtsConvert,
    UpdateRun,
    UsageCost
  }

  @ctx %{conn_id: "test-conn", auth: %{role: :operator}}

  setup do
    # Clean up test data
    on_exit(fn ->
      # Clean up any test nodes
      case LemonCore.Store.get(:nodes_registry, "test-browser-node") do
        nil -> :ok
        _ -> LemonCore.Store.delete(:nodes_registry, "test-browser-node")
      end

      # Clean up TTS config
      LemonCore.Store.delete(:tts_config, :global)

      # Clean up usage data
      LemonCore.Store.delete(:usage_data, :current)

      # Clean up update config
      UpdateStore.delete_config()
      UpdateStore.delete_pending()
    end)

    :ok
  end

  describe "BrowserRequest" do
    test "requires method parameter" do
      {:error, error} = BrowserRequest.handle(%{}, @ctx)
      assert error == {:invalid_request, "method is required"}
    end

    test "returns not_found when no browser node available" do
      {:error, error} = BrowserRequest.handle(%{"method" => "navigate"}, @ctx)
      assert error == {:not_found, "No browser node available. Pair a browser node first."}
    end

    test "returns unavailable when browser node is offline" do
      # Create an offline browser node
      node = %{
        id: "test-browser-node",
        type: "browser",
        status: :offline,
        name: "Test Browser"
      }

      LemonCore.Store.put(:nodes_registry, "test-browser-node", node)

      {:error, error} =
        BrowserRequest.handle(
          %{
            "method" => "navigate",
            "nodeId" => "test-browser-node"
          },
          @ctx
        )

      assert error == {:unavailable, "Browser node is not online"}
    end

    test "forwards request to online browser node" do
      # Create an online browser node
      node = %{
        id: "test-browser-node",
        type: "browser",
        status: :online,
        name: "Test Browser"
      }

      LemonCore.Store.put(:nodes_registry, "test-browser-node", node)

      # This will forward to node.invoke which creates a pending invocation
      {:ok, result} =
        BrowserRequest.handle(
          %{
            "method" => "navigate",
            "args" => %{"url" => "https://example.com"},
            "nodeId" => "test-browser-node"
          },
          @ctx
        )

      assert result["nodeId"] == "test-browser-node"
      assert result["method"] == "browser.navigate"
      assert result["status"] == "pending"
      assert is_binary(result["invokeId"])
      assert result["summary"]["mode"] == "node"
      assert result["summary"]["method"] == "browser.navigate"
      assert result["summary"]["resultReturned"] == false
      assert result["summary"]["networkPolicyReturned"] == true
      assert result["summary"]["cleanup"]["includesRawUrl"] == false
      assert result["summary"]["cleanup"]["includesPageContent"] == false
      assert result["nodeInvokeSummary"]["cleanup"]["includesArgs"] == false
    end

    test "accepts already-prefixed browser methods without double-prefixing" do
      node = %{
        id: "test-browser-node",
        type: "browser",
        status: :online,
        name: "Test Browser"
      }

      LemonCore.Store.put(:nodes_registry, "test-browser-node", node)

      {:ok, result} =
        BrowserRequest.handle(
          %{
            "method" => "browser.navigate",
            "args" => %{"url" => "https://example.com", "route" => "public"},
            "nodeId" => "test-browser-node"
          },
          @ctx
        )

      assert result["method"] == "browser.navigate"

      assert result["networkPolicy"] == %{
               "route" => "public",
               "effectiveRoute" => "public",
               "targetKind" => "public_network"
             }

      assert result["summary"]["networkPolicyReturned"] == true
      assert result["summary"]["cleanup"]["includesRawUrl"] == false

      invocation = NodeStore.get_invocation(result["invokeId"])
      assert invocation.method == "browser.navigate"
      assert invocation.args == %{"url" => "https://example.com"}
    end

    test "rejects browser navigation to metadata endpoints before dispatch" do
      node = %{
        id: "test-browser-node",
        type: "browser",
        status: :online,
        name: "Test Browser"
      }

      LemonCore.Store.put(:nodes_registry, "test-browser-node", node)

      {:error, error} =
        BrowserRequest.handle(
          %{
            "method" => "navigate",
            "args" => %{"url" => "http://169.254.169.254/latest/meta-data"},
            "nodeId" => "test-browser-node"
          },
          @ctx
        )

      assert error == {:invalid_request, "browser navigation blocked metadata endpoint"}
    end

    test "enforces public and local route guards before dispatch" do
      node = %{
        id: "test-browser-node",
        type: "browser",
        status: :online,
        name: "Test Browser"
      }

      LemonCore.Store.put(:nodes_registry, "test-browser-node", node)

      assert {:error, {:invalid_request, "browser navigation requires a public http(s) URL"}} =
               BrowserRequest.handle(
                 %{
                   "method" => "navigate",
                   "args" => %{"url" => "http://127.0.0.1:4000", "route" => "public"},
                   "nodeId" => "test-browser-node"
                 },
                 @ctx
               )

      assert {:error, {:invalid_request, "browser navigation requires a local or private URL"}} =
               BrowserRequest.handle(
                 %{
                   "method" => "navigate",
                   "args" => %{"url" => "https://example.com", "route" => "local"},
                   "nodeId" => "test-browser-node"
                 },
                 @ctx
               )
    end

    test "finds default browser node when nodeId not specified" do
      # Create an online browser node
      node = %{
        id: "default-browser-node",
        type: "browser",
        status: :online,
        name: "Default Browser"
      }

      LemonCore.Store.put(:nodes_registry, "default-browser-node", node)

      on_exit(fn ->
        LemonCore.Store.delete(:nodes_registry, "default-browser-node")
      end)

      {:ok, result} =
        BrowserRequest.handle(
          %{
            "method" => "screenshot"
          },
          @ctx
        )

      assert result["nodeId"] == "default-browser-node"
      assert result["method"] == "browser.screenshot"
      assert result["summary"]["cleanup"]["includesScreenshotData"] == false
    end

    test "has correct method name and scopes" do
      assert BrowserRequest.name() == "browser.request"
      assert BrowserRequest.scopes() == [:write]
    end
  end

  describe "BrowserStatus" do
    test "returns local driver status, recent artifacts, and browser nodes" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "browser_status_test_#{System.unique_integer([:positive])}")

      artifacts_dir = Path.join([tmp_dir, ".lemon", "browser-artifacts"])
      File.mkdir_p!(artifacts_dir)
      screenshot = Path.join(artifacts_dir, "capture.png")
      File.write!(screenshot, "png")

      proof_dir = Path.join([tmp_dir, ".lemon", "proofs"])
      File.mkdir_p!(proof_dir)
      proof_path = Path.join(proof_dir, "browser-smoke-latest.json")

      File.write!(
        proof_path,
        Jason.encode!(%{
          result: "passed",
          proof_object: "lemon.browser_smoke",
          completed_count: 20,
          failed_count: 0,
          skipped_count: 0,
          generated_at: "2026-05-17T12:00:00Z",
          exercised_tools: ["browser_navigate", "browser_screenshot"],
          progress_update_count: 40,
          progress_browser_child_action_count: 20,
          model_visible_image_included: true,
          browser_to_media_vision_completed: true,
          browser_cdp_attach_completed: true,
          progress_cleanup: %{
            contains_raw_sensitive_values: false,
            includes_raw_urls: false,
            includes_selectors: false,
            includes_typed_text: false,
            includes_cookie_values: false,
            includes_page_text: false,
            includes_artifact_paths: false,
            includes_raw_paths: false,
            includes_screenshot_bytes: false
          },
          checks: [
            %{
              name: "browser_screenshot",
              status: "completed",
              raw_url: "https://private.example.test"
            }
          ]
        })
      )

      node = %{
        id: "status-browser-node",
        type: "browser",
        status: :online,
        name: "Status Browser"
      }

      LemonCore.Store.put(:nodes_registry, "status-browser-node", node)

      on_exit(fn ->
        LemonCore.Store.delete(:nodes_registry, "status-browser-node")
        File.rm_rf!(tmp_dir)
      end)

      assert {:ok, result} =
               BrowserStatus.handle(%{"projectDir" => tmp_dir, "limit" => 5}, @ctx)

      assert result["local"]["available"] == true
      assert result["local"]["driver_config"]["mode"] in ["local_cdp", "remote_cdp"]
      assert is_boolean(result["local"]["driver_config"]["attach_only"])
      refute inspect(result["local"]["driver_config"]) =~ "LEMON_BROWSER_CDP_ENDPOINT"
      assert result["artifactsDir"] == artifacts_dir
      assert [%{"name" => "capture.png", "bytes" => 3}] = result["recentArtifacts"]
      assert result["liveProof"]["status"] == "completed"
      assert result["liveProof"]["completedCount"] == 20
      assert result["liveProof"]["failedCount"] == 0
      assert result["liveProof"]["proofObject"] == "lemon.browser_smoke"
      assert result["liveProof"]["browserProof"]["model_visible_image_included"] == true
      assert result["liveProof"]["browserProof"]["browser_cdp_attach_completed"] == true
      assert result["liveProof"]["cleanup"]["includesRawPaths"] == false

      assert Enum.any?(
               result["liveProof"]["latestChecks"],
               &(&1["name"] == "browser_screenshot" and &1["status"] == "completed")
             )

      assert Enum.any?(result["nodes"], fn node ->
               node["id"] == "status-browser-node" and node["status"] == "online"
             end)

      refute inspect(result) =~ proof_path
      refute inspect(result) =~ "private.example.test"
    end

    test "has correct method name and scopes" do
      assert BrowserStatus.name() == "browser.status"
      assert BrowserStatus.scopes() == [:read]
    end
  end

  describe "MediaStatus" do
    test "returns redacted media job and artifact status" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "media_status_test_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      artifact_dir = LemonCore.MediaJobs.default_artifacts_dir(tmp_dir)
      File.mkdir_p!(artifact_dir)
      artifact_path = Path.join(artifact_dir, "generated.png")
      File.write!(artifact_path, "png")

      proof_dir = Path.join([tmp_dir, ".lemon", "proofs"])
      File.mkdir_p!(proof_dir)

      File.write!(
        Path.join(proof_dir, "media-image-smoke-latest.json"),
        Jason.encode!(%{
          status: "failed",
          completed_count: 0,
          failed_count: 1,
          skipped_count: 0,
          generated_at: "2026-05-17T12:00:00Z",
          proof_object: "lemon.media_provider_image",
          details: %{
            provider: "vertex_imagen",
            model: "imagen-test",
            reason_kind: "vertex_imagen_http_error:permission_denied",
            raw_prompt: "private image prompt"
          },
          checks: [
            %{
              name: "media_provider_vertex_imagen",
              status: "failed",
              raw_provider_response: "private provider response"
            }
          ]
        })
      )

      File.write!(
        Path.join(proof_dir, "media-transcription-smoke-latest.json"),
        Jason.encode!(%{
          status: "completed",
          completed_count: 1,
          failed_count: 0,
          skipped_count: 0,
          generated_at: "2026-05-17T12:01:00Z",
          proof_object: "lemon.media_provider_transcription",
          details: %{
            provider: "deepgram_transcribe",
            model: "nova-test"
          },
          checks: [%{name: "media_provider_deepgram_transcribe", status: "completed"}]
        })
      )

      assert {:ok, _job} =
               LemonCore.MediaJobs.record(
                 %{
                   job_id: "control-plane-media",
                   type: :image,
                   status: :completed,
                   channel: "discord",
                   prompt: "private generated media prompt",
                   artifact_path: artifact_path,
                   mime_type: "image/png",
                   created_at: "2026-05-16T12:00:00Z"
                 },
                 project_dir: tmp_dir
               )

      assert {:ok, result} = MediaStatus.handle(%{"projectDir" => tmp_dir, "limit" => 5}, @ctx)

      assert result["jobsDir"] == LemonCore.MediaJobs.default_dir(tmp_dir)
      assert result["artifactsDir"] == artifact_dir
      assert result["workerStatus"]["supervised"] == true
      assert result["workerStatus"]["running"] == true
      assert is_integer(result["workerStatus"]["active_jobs"])
      assert result["summary"]["count"] == 1
      assert result["summary"]["status_counts"]["completed"] == 1
      assert result["summary"]["type_counts"]["image"] == 1
      assert result["summary"]["artifact_count"] == 1
      assert result["summary"]["cleanup"]["includes_raw_paths"] == false
      assert result["summary"]["cleanup"]["includes_prompts"] == false
      assert result["summary"]["cleanup"]["includes_provider_responses"] == false
      assert result["summary"]["cleanup"]["includes_channel_message_bodies"] == false
      assert result["providerProofs"]["status"] == "incomplete"
      assert result["providerProofs"]["completed_count"] == 1
      assert result["providerProofs"]["required_count"] == 5
      assert result["providerProofs"]["cleanup"]["includes_raw_api_keys"] == false
      assert result["providerProofs"]["cleanup"]["includes_raw_prompts"] == false
      assert result["providerProofs"]["cleanup"]["includes_provider_answers"] == false
      assert result["providerProofs"]["cleanup"]["includes_artifact_bytes"] == false

      image_proof =
        Enum.find(result["providerProofs"]["providers"], &(&1["label"] == "image"))

      assert image_proof["provider"] == "vertex_imagen"
      assert image_proof["status"] == "blocked"
      assert image_proof["proof_status"] == "failed"
      assert image_proof["reason_kind"] == "vertex_imagen_http_error:permission_denied"
      assert image_proof["next_action"] =~ "enable provider API/IAM/billing"

      stt_proof =
        Enum.find(result["providerProofs"]["providers"], &(&1["label"] == "STT"))

      assert stt_proof["provider"] == "deepgram_transcribe"
      assert stt_proof["status"] == "proven"
      assert stt_proof["proof_status"] == "completed"

      assert [job] = result["recentJobs"]
      assert job["job_id"] == "control-plane-media"
      assert job["artifact"]["name"] == "generated.png"
      assert is_binary(job["artifact"]["path_hash"])
      refute inspect(result) =~ artifact_path
      refute inspect(result) =~ "private generated media prompt"
      refute inspect(result) =~ "private image prompt"
      refute inspect(result) =~ "private provider response"
    end

    test "has correct method name and scopes" do
      assert MediaStatus.name() == "media.status"
      assert MediaStatus.scopes() == [:read]
    end
  end

  describe "ProofsStatus" do
    test "returns redacted proof artifact status" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "proofs_status_test_#{System.unique_integer([:positive])}"
        )

      proof_dir = Path.join([tmp_dir, ".lemon", "proofs"])
      File.mkdir_p!(proof_dir)
      proof_path = Path.join(proof_dir, "private-proof.json")

      File.write!(
        proof_path,
        Jason.encode!(%{
          status: "failed",
          completed_count: 0,
          failed_count: 1,
          skipped_count: 0,
          generated_at: "2026-05-16T12:02:00Z",
          proof_object: "lemon.provider_fallback_smoke",
          proof_scope: "provider live media",
          coverage: %{
            check_count: 5,
            registered_command_count: 16,
            decode_command_count: 3,
            local_response_command_count: 13,
            client_click_command_count: 1,
            real_client_click_proof: true,
            contains_dm: true,
            contains_file_delivery: true,
            contains_slash_registration: true,
            contains_rollback_slash_registration: true,
            contains_media_slash_registration: true,
            contains_all_slash_registration: true,
            ignored_raw_field: "/private/path"
          },
          checks: [
            %{
              name: "provider_media_round_trip",
              ok: false,
              failure_hint: "Provider HTTP error"
            }
          ],
          cleanup: %{
            includes_raw_api_keys: false,
            includes_raw_prompts: false,
            includes_raw_provider_responses: false
          },
          details: %{
            provider: "openai_vision",
            model: "openrouter:test-model",
            artifact_mime_type: "application/json",
            artifact_bytes: 59,
            analysis_chars: 43,
            artifact_hash: "private-artifact-hash",
            job_id_hash: "private-job-hash",
            primary_provider: "openai",
            fallback_provider: "zai",
            final_provider: "zai",
            reason_kind: "provider_http_error",
            raw_prompt: "private proof prompt"
          }
        })
      )

      File.write!(
        Path.join([tmp_dir, ".lemon", "proofs", "wasm-lifecycle-latest.json"]),
        Jason.encode!(%{
          status: "completed",
          proof: "wasm_lifecycle_smoke",
          completed_count: 5,
          failed_count: 0,
          generated_at: "2026-05-17T02:35:01.331778Z",
          checks: [
            %{name: "wasm_lifecycle_stop_terminates_sidecar", status: "completed"}
          ],
          redaction: %{
            contains_raw_cwd: false,
            contains_raw_session_ids: false,
            contains_raw_tool_names: false,
            contains_raw_params: false
          }
        })
      )

      File.write!(
        Path.join([tmp_dir, ".lemon", "proofs", "telegram-voice-local-latest.json"]),
        Jason.encode!(%{
          status: "completed",
          proof_object: "lemon.telegram_voice_local_smoke",
          proof_scope: "telegram_voice_local_transcript",
          completed_count: 3,
          failed_count: 0,
          skipped_count: 0,
          generated_at: "2026-05-17T13:05:08.639510Z",
          coverage: %{check_count: 3},
          checks: [
            %{
              name: "telegram_voice_local_transcript_provider",
              status: "completed",
              proof_scope: "telegram_voice_local_transcript"
            },
            %{
              name: "telegram_voice_local_no_api_key",
              status: "completed",
              proof_scope: "telegram_voice_local_transcript"
            },
            %{
              name: "telegram_voice_local_inbound_metadata",
              status: "completed",
              proof_scope: "telegram_voice_local_transcript",
              raw_transcript: "private transcript"
            }
          ],
          cleanup: %{
            includes_raw_bot_token: false,
            includes_raw_chat_ids: false,
            includes_raw_sender_ids: false,
            includes_raw_audio_bytes: false,
            includes_raw_transcript: false,
            includes_raw_message_body: false
          }
        })
      )

      File.write!(
        Path.join([tmp_dir, ".lemon", "proofs", "terminal-backend-latest.json"]),
        Jason.encode!(%{
          status: "completed",
          completed_count: 4,
          failed_count: 0,
          skipped_count: 0,
          generated_at: "2026-05-17T06:26:25.028059Z",
          results: [
            %{backend: "local", status: "completed", output_hash: "safe-local-output"},
            %{backend: "local_pty", status: "completed", output_hash: "safe-pty-output"},
            %{
              backend: "docker",
              status: "completed",
              output_hash: "safe-docker-output",
              hardening: %{
                read_only_rootfs: true,
                tmpfs_noexec: true,
                drops_capabilities: true,
                no_new_privileges: true,
                cgroup_memory_limit: true,
                cgroup_cpu_quota: true,
                cgroup_pids_limit: true,
                pull_policy: "never",
                network: "none",
                memory: "1g",
                cpus: "2",
                pids_limit: "256",
                raw_command: "private command"
              }
            },
            %{backend: "ssh", status: "completed", output_hash: "safe-ssh-output"}
          ]
        })
      )

      File.write!(
        Path.join([tmp_dir, ".lemon", "proofs", "discord-media-directive-latest.json"]),
        Jason.encode!(%{
          status: "completed",
          proof_object: "lemon.discord_live_matrix",
          proof_scope: "discord_live_matrix",
          completed_count: 1,
          failed_count: 0,
          skipped_count: 0,
          generated_at: "2026-05-17T15:26:25.028059Z",
          coverage: %{
            check_count: 1,
            contains_media_directive: true,
            contains_file_delivery: true,
            contains_all_slash_registration: true
          },
          checks: [
            %{
              name: "discord_media_directive_delivery",
              status: "completed",
              bot_reply: %{
                attachment_count: 1,
                directive_leaked: false
              }
            },
            %{
              name: "discord_all_slash_registration",
              status: "completed",
              proof_scope: "discord_application_command_registration"
            }
          ],
          cleanup: %{
            includes_raw_bot_tokens: false,
            includes_raw_channel_ids: false,
            includes_raw_user_ids: false,
            includes_raw_message_bodies: false
          }
        })
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:ok, result} =
               ProofsStatus.handle(%{"projectDir" => tmp_dir, "limit" => 5}, @ctx)

      assert result["proofCount"] == 5
      assert result["failedCount"] == 1
      assert result["completedCount"] == 4
      assert result["invalidCount"] == 0
      assert result["summary"]["action"] == "proofs.status"
      assert result["summary"]["limit"] == 5
      assert result["summary"]["proofCount"] == 5
      assert result["summary"]["completedCount"] == 4
      assert result["summary"]["failedCount"] == 1
      assert result["summary"]["recentProofCount"] == 5
      assert result["summary"]["latestCheckCount"] == 5
      assert result["summary"]["launchGateStatuses"]["terminalBackends"] == "passed"
      assert result["summary"]["launchGateStatuses"]["discordSlashRegistration"] == "passed"

      assert result["launchGates"] ==
               LemonCore.Doctor.ProofLaunchGates.status(
                 LemonCore.Doctor.ProofDiagnostics.status(project_dir: tmp_dir, limit: 1_000)
               )

      assert result["summary"]["cleanup"] == result["cleanup"]
      assert result["reasonKindCounts"]["provider_http_error"] == 1
      assert result["proofScopeCounts"]["provider_live_media"] == 1
      assert result["proofScopeCounts"]["provider_fallback"] == 1
      assert result["proofScopeCounts"]["media_provider"] == 1
      assert result["proofScopeCounts"]["wasm_lifecycle_smoke"] == 1
      assert result["proofScopeCounts"]["terminal_backend"] == 1
      assert result["proofScopeCounts"]["telegram_voice_local_transcript"] == 1
      assert result["proofScopeCounts"]["discord_live_matrix"] == 1
      assert result["proofScopeCounts"]["channel_generated_media_delivery"] == 1
      assert result["checkNameCounts"]["provider_media_round_trip"] == 1
      assert result["checkNameCounts"]["wasm_lifecycle_stop_terminates_sidecar"] == 1
      assert result["checkNameCounts"]["terminal_backend_docker"] == 1
      assert result["checkNameCounts"]["telegram_voice_local_inbound_metadata"] == 1
      assert result["checkNameCounts"]["discord_media_directive_delivery"] == 1
      assert result["checkNameCounts"]["discord_all_slash_registration"] == 1
      assert result["launchGates"]["discordDm"]["status"] == "warning"
      assert result["launchGates"]["discordDm"]["reasonKind"] == "discord_dm_missing"
      assert result["launchGates"]["discordSlashRegistration"]["status"] == "passed"
      assert result["launchGates"]["discordSlashClientClick"]["status"] == "warning"

      assert result["launchGates"]["providerMedia"]["completedLaneCount"] == 0
      assert result["launchGates"]["providerMedia"]["failedLaneCount"] == 1
      assert result["launchGates"]["providerMedia"]["totalLaneCount"] == 5
      assert result["launchGates"]["providerMedia"]["lanes"]["vision"]["status"] == "blocked"

      assert result["launchGates"]["providerMedia"]["lanes"]["vision"]["provider"] ==
               "openai_vision"

      assert result["launchGates"]["terminalBackends"]["status"] == "passed"
      assert result["launchGates"]["terminalBackends"]["completedCount"] == 4

      check =
        Enum.find(result["latestChecks"], &(&1["name"] == "provider_media_round_trip"))

      assert check["status"] == "failed"
      assert check["proofObject"] == "lemon.provider_fallback_smoke"
      assert is_binary(check["fileHash"])
      assert is_binary(check["proofHash"])
      assert result["cleanup"]["includesRawPaths"] == false
      assert result["cleanup"]["includesRawFilenames"] == false
      assert result["cleanup"]["includesRawProofDetails"] == false
      assert result["cleanup"]["includesRawPrompts"] == false
      assert result["cleanup"]["includesRawProviderResponses"] == false
      assert result["cleanup"]["embedsProofFileContents"] == false
      assert Enum.any?(result["directories"], &(&1["label"] == ".lemon/proofs"))
      assert length(result["recentProofs"]) == 5

      proof =
        Enum.find(
          result["recentProofs"],
          &(&1["proofObject"] == "lemon.provider_fallback_smoke")
        )

      assert proof["status"] == "failed"
      assert proof["provider"] == "openai_vision"
      assert proof["model"] == "openrouter:test-model"
      assert proof["proofObject"] == "lemon.provider_fallback_smoke"
      assert proof["primaryProvider"] == "openai"
      assert proof["fallbackProvider"] == "zai"
      assert proof["finalProvider"] == "zai"
      assert "provider_live_media" in proof["proofScopes"]
      assert "provider_fallback" in proof["proofScopes"]
      assert "media_provider" in proof["proofScopes"]
      assert proof["coverage"]["registeredCommandCount"] == 16
      assert proof["coverage"]["decodeCommandCount"] == 3
      assert proof["coverage"]["localResponseCommandCount"] == 13
      assert proof["coverage"]["clientClickCommandCount"] == 1
      assert proof["coverage"]["realClientClickProof"] == true
      assert proof["coverage"]["checkCount"] == 5
      assert proof["coverage"]["containsDm"] == true
      assert proof["coverage"]["containsFileDelivery"] == true
      assert proof["coverage"]["containsSlashRegistration"] == true
      assert proof["coverage"]["containsRollbackSlashRegistration"] == true
      assert proof["coverage"]["containsMediaSlashRegistration"] == true
      assert proof["coverage"]["containsAllSlashRegistration"] == true
      refute Map.has_key?(proof["coverage"], "ignoredRawField")
      assert proof["reasonKind"] == "provider_http_error"
      assert proof["mediaProof"]["provider"] == "openai_vision"
      assert proof["mediaProof"]["model"] == "openrouter:test-model"
      assert proof["mediaProof"]["artifactMimeType"] == "application/json"
      assert proof["mediaProof"]["artifactBytes"] == 59
      assert proof["mediaProof"]["analysisChars"] == 43
      assert proof["mediaProof"]["hasArtifactHash"] == true
      assert proof["mediaProof"]["hasJobIdHash"] == true
      assert is_binary(proof["fileHash"])
      assert is_binary(proof["proofHash"])

      discord_media_proof =
        Enum.find(result["recentProofs"], &(&1["proofObject"] == "lemon.discord_live_matrix"))

      assert discord_media_proof["status"] == "completed"
      assert discord_media_proof["coverage"]["containsMediaDirective"] == true
      assert discord_media_proof["coverage"]["containsFileDelivery"] == true
      assert discord_media_proof["mediaProof"]["channelDelivery"] == true
      assert discord_media_proof["mediaProof"]["discordDelivery"] == true
      assert discord_media_proof["mediaProof"]["discordAttachmentCount"] == 1
      assert discord_media_proof["mediaProof"]["mediaDirectiveDelivery"] == true
      assert discord_media_proof["mediaProof"]["directiveLeaked"] == false

      telegram_voice_proof =
        Enum.find(
          result["recentProofs"],
          &(&1["proofObject"] == "lemon.telegram_voice_local_smoke")
        )

      assert telegram_voice_proof["status"] == "completed"
      assert telegram_voice_proof["completedCount"] == 3
      assert telegram_voice_proof["failedCount"] == 0
      assert "telegram_voice_local_transcript" in telegram_voice_proof["proofScopes"]
      assert telegram_voice_proof["coverage"]["checkCount"] == 3
      assert telegram_voice_proof["cleanup"]["includes_raw_transcript"] == false

      lifecycle_proof =
        Enum.find(result["recentProofs"], &(&1["proofObject"] == "wasm_lifecycle_smoke"))

      assert lifecycle_proof["status"] == "completed"
      assert "wasm_lifecycle_smoke" in lifecycle_proof["proofScopes"]
      assert lifecycle_proof["redaction"]["containsRawCwd"] == false
      assert lifecycle_proof["redaction"]["containsRawSessionIds"] == false
      assert lifecycle_proof["redaction"]["containsRawToolNames"] == false
      assert lifecycle_proof["redaction"]["containsRawParams"] == false
      refute Map.has_key?(lifecycle_proof["redaction"], "contains_raw_cwd")
      assert lifecycle_proof["cleanup"] == %{}

      terminal_proof =
        Enum.find(result["recentProofs"], &("terminal_backend" in &1["proofScopes"]))

      docker = terminal_proof["terminalHardening"]["docker"]
      assert docker["readOnlyRootfs"] == true
      assert docker["tmpfsNoexec"] == true
      assert docker["dropsCapabilities"] == true
      assert docker["noNewPrivileges"] == true
      assert docker["cgroupMemoryLimit"] == true
      assert docker["cgroupCpuQuota"] == true
      assert docker["cgroupPidsLimit"] == true
      assert docker["pullPolicy"] == "never"
      assert docker["network"] == "none"
      assert docker["memory"] == "1g"
      assert docker["cpus"] == "2"
      assert docker["pidsLimit"] == "256"

      refute inspect(result) =~ proof_path
      refute inspect(result) =~ "private-proof.json"
      refute inspect(result) =~ "private proof prompt"
      refute inspect(result) =~ "private transcript"
      refute inspect(result) =~ "private command"
    end

    test "launch gate summaries are not truncated by response limit" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "proofs_status_limit_test_#{System.unique_integer([:positive])}"
        )

      proof_dir = Path.join([tmp_dir, ".lemon", "proofs"])
      File.mkdir_p!(proof_dir)

      File.write!(
        Path.join(proof_dir, "media-image-latest.json"),
        Jason.encode!(%{
          status: "completed",
          proof_object: "lemon.media_provider_image",
          completed_count: 1,
          failed_count: 0,
          generated_at: "2026-05-17T12:00:00Z",
          details: %{provider: "openai_image"},
          checks: [%{name: "media_provider_openai_image", status: "completed"}]
        })
      )

      File.write!(
        Path.join(proof_dir, "media-stt-latest.json"),
        Jason.encode!(%{
          status: "completed",
          proof_object: "lemon.media_provider_stt",
          completed_count: 1,
          failed_count: 0,
          generated_at: "2026-05-17T12:01:00Z",
          details: %{provider: "deepgram_transcribe"},
          checks: [%{name: "media_provider_deepgram_transcribe", status: "completed"}]
        })
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:ok, result} =
               ProofsStatus.handle(%{"projectDir" => tmp_dir, "limit" => 1}, @ctx)

      assert length(result["recentProofs"]) == 1
      assert length(result["latestChecks"]) == 1
      assert result["launchGates"]["providerMedia"]["completedLaneCount"] == 2
      assert result["launchGates"]["providerMedia"]["lanes"]["image"]["status"] == "passed"
      assert result["launchGates"]["providerMedia"]["lanes"]["stt"]["status"] == "passed"
    end

    test "reports rollback-only slash registration as partial launch-gate evidence" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "proofs_status_rollback_test_#{System.unique_integer([:positive])}"
        )

      proof_dir = Path.join([tmp_dir, ".lemon", "proofs"])
      File.mkdir_p!(proof_dir)

      File.write!(
        Path.join(proof_dir, "discord-rollback-slash-registration-latest.json"),
        Jason.encode!(%{
          status: "completed",
          proof_object: "lemon.discord_live_matrix",
          proof_scope: "discord_live_matrix",
          completed_count: 1,
          failed_count: 0,
          generated_at: "2026-05-18T03:45:00Z",
          coverage: %{
            contains_slash_registration: true,
            contains_rollback_slash_registration: true
          },
          checks: [
            %{name: "discord_rollback_slash_registration", status: "completed"}
          ],
          cleanup: %{includes_raw_bot_tokens: false}
        })
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:ok, result} = ProofsStatus.handle(%{"projectDir" => tmp_dir}, @ctx)

      gate = result["launchGates"]["discordSlashRegistration"]
      assert gate["status"] == "warning"
      assert gate["reasonKind"] == "discord_all_slash_registration_missing"
      assert gate["evidence"] =~ "/rollback"
      assert gate["nextAction"] =~ "--check-all-slash-registration"
    end

    test "has correct method name and scopes" do
      assert ProofsStatus.name() == "proofs.status"
      assert ProofsStatus.scopes() == [:read]
    end
  end

  describe "CheckpointStatus" do
    test "returns redacted checkpoint store status" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "checkpoint_status_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      File.write!(
        Path.join(tmp_dir, "chk_control_plane.json"),
        Jason.encode!(%{
          id: "chk_control_plane",
          session_id: "agent:private-session",
          timestamp: "2026-05-15T11:00:00Z",
          metadata: %{
            kind: "filesystem",
            tool: "patch",
            action: "patch",
            path_count: 1
          },
          state: %{
            filesystem: %{
              files: [
                %{path: "/private/repo/file.ex", content_b64: Base.encode64("secret")}
              ]
            }
          }
        })
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:ok, result} =
               CheckpointStatus.handle(%{"checkpointDir" => tmp_dir, "limit" => 5}, @ctx)

      assert result["store_dir"] == tmp_dir
      assert result["count"] == 1
      assert result["filesystem_count"] == 1
      assert result["cleanup"]["includes_raw_paths"] == false
      assert result["cleanup"]["includes_raw_session_ids"] == false
      assert result["cleanup"]["embeds_file_contents_in_support_bundle"] == false

      assert [
               %{
                 "checkpoint_id" => "chk_control_plane",
                 "session_hash" => session_hash,
                 "kind" => "filesystem",
                 "tool" => "patch",
                 "action" => "patch",
                 "path_count" => 1
               }
             ] = result["recent"]

      assert is_binary(session_hash)
      refute inspect(result) =~ "agent:private-session"
      refute inspect(result) =~ "/private/repo/file.ex"
      refute inspect(result) =~ "secret"
    end

    test "returns redacted checkpoint lifecycle event status" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "checkpoint_status_events_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      run_id = "checkpoint-status-run-#{System.unique_integer([:positive])}"
      session_key = "agent:private-checkpoint-session-#{System.unique_integer([:positive])}"
      agent_id = "checkpoint-agent-#{System.unique_integer([:positive])}"

      for {event_type, extra} <- [
            {:checkpoint_created, %{path_count: 2}},
            {:checkpoint_restored, %{restored_count: 1}},
            {:checkpoint_deleted, %{path_count: 2}}
          ] do
        :ok =
          LemonCore.Introspection.record(
            event_type,
            Map.merge(
              %{
                checkpoint_id: "chk_event_control_plane",
                checkpoint_kind: "filesystem",
                session_id: session_key,
                tool: "patch",
                action: Atom.to_string(event_type),
                paths: ["/private/repo/a.ex", "/private/repo/b.ex"]
              },
              extra
            ),
            run_id: run_id,
            session_key: session_key,
            agent_id: agent_id
          )
      end

      assert {:ok, result} =
               CheckpointStatus.handle(
                 %{
                   "checkpointDir" => tmp_dir,
                   "runId" => run_id,
                   "sessionKey" => session_key,
                   "agentId" => agent_id,
                   "eventLimit" => 2
                 },
                 @ctx
               )

      assert result["events"]["counts"] == %{
               "created" => 1,
               "restored" => 1,
               "deleted" => 1
             }

      assert length(result["events"]["recent"]) == 2

      assert Enum.all?(
               result["events"]["recent"],
               &(&1["checkpoint_id"] == "chk_event_control_plane")
             )

      assert Enum.all?(result["events"]["recent"], &is_binary(&1["session_hash"]))
      assert result["events"]["cleanup"]["includes_raw_paths"] == false
      assert result["events"]["cleanup"]["includes_raw_session_ids"] == false
      assert result["events"]["cleanup"]["includes_file_contents"] == false
      assert result["events"]["cleanup"]["includes_raw_payload"] == false

      refute inspect(result) =~ session_key
      refute inspect(result) =~ "/private/repo"
    end

    test "has correct method name and scopes" do
      assert CheckpointStatus.name() == "checkpoint.status"
      assert CheckpointStatus.scopes() == [:read]
    end
  end

  describe "CheckpointDiff and CheckpointRestore" do
    @tag :tmp_dir
    test "previews and restores a filesystem checkpoint without returning raw session ids", %{
      tmp_dir: tmp_dir
    } do
      session_id = "checkpoint-control-plane-#{System.unique_integer([:positive])}"
      path = Path.join(tmp_dir, "file.txt")
      File.write!(path, "before\n")

      on_exit(fn -> Checkpoint.delete_all(session_id) end)

      {:ok, checkpoint} =
        Checkpoint.create_filesystem(session_id, [path],
          cwd: tmp_dir,
          tool: "test",
          metadata: %{action: "control_plane_test"}
        )

      File.write!(path, "after\n")

      assert {:ok, diff} = CheckpointDiff.handle(%{"checkpointId" => checkpoint.id}, @ctx)
      assert diff["checkpoint_id"] == checkpoint.id
      assert diff["changed"] == [path]
      assert diff["changed_count"] == 1
      assert diff["output"] =~ "-before"
      assert diff["output"] =~ "+after"
      assert diff["summary"]["changedCount"] == 1
      assert diff["summary"]["changedPathsReturned"] == true
      assert diff["summary"]["diffOutputReturned"] == true
      assert diff["summary"]["rawSessionIdReturned"] == false
      assert diff["summary"]["cleanup"]["includesRawSessionId"] == false
      assert diff["summary"]["cleanup"]["includesRawFilePaths"] == true
      assert diff["summary"]["cleanup"]["includesDiffText"] == true
      refute inspect(diff) =~ session_id

      assert {:ok, restored} =
               CheckpointRestore.handle(
                 %{"checkpointId" => checkpoint.id, "paths" => [path]},
                 @ctx
               )

      assert restored["checkpoint_id"] == checkpoint.id
      assert restored["restored"] == [path]
      assert restored["restored_count"] == 1
      assert restored["summary"]["restoredCount"] == 1
      assert restored["summary"]["restoredPathsReturned"] == true
      assert restored["summary"]["rawSessionIdReturned"] == false
      assert restored["summary"]["cleanup"]["includesRawSessionId"] == false
      assert restored["summary"]["cleanup"]["includesFileContentText"] == false
      refute inspect(restored) =~ session_id
      assert File.read!(path) == "before\n"
    end

    test "has correct method names and scopes" do
      assert CheckpointDiff.name() == "checkpoint.diff"
      assert CheckpointDiff.scopes() == [:read]
      assert CheckpointRestore.name() == "checkpoint.restore"
      assert CheckpointRestore.scopes() == [:write]
    end
  end

  describe "TerminalBackendsStatus" do
    test "returns registered terminal backend metadata without process secrets" do
      assert {:ok, result} = TerminalBackendsStatus.handle(%{}, @ctx)

      assert result["count"] == 4
      assert result["defaultBackend"] == "local"
      assert result["summary"]["action"] == "terminal.backends.status"
      assert result["summary"]["backendCount"] == 4
      assert result["summary"]["availableBackendCount"] >= 1
      assert result["summary"]["defaultBackend"] == "local"
      assert result["summary"]["allowlistConfigured"] == false
      assert result["summary"]["allowedBackendCount"] >= 1
      assert result["summary"]["cleanup"] == result["cleanup"]
      assert result["policy"]["backend_allowlist_configured"] == false
      assert "local" in result["policy"]["allowed_backends"]
      assert result["policy"]["approval_required_backends"] == []
      assert result["cleanup"]["includesCommands"] == false
      assert result["cleanup"]["includesEnvironment"] == false
      assert result["cleanup"]["includesProcessOutput"] == false
      assert result["cleanup"]["includesRawProofDetails"] == false

      local = Enum.find(result["backends"], &(&1["id"] == "local"))
      local_pty = Enum.find(result["backends"], &(&1["id"] == "local_pty"))
      docker = Enum.find(result["backends"], &(&1["id"] == "docker"))
      ssh = Enum.find(result["backends"], &(&1["id"] == "ssh"))

      assert %{
               "label" => "Local shell",
               "available" => true,
               "transport" => "erlang_port",
               "pty" => false,
               "supervised" => true,
               "capabilities" => capabilities
             } = local

      assert "shell" in capabilities
      assert "stdin" in capabilities
      assert "kill" in capabilities
      assert local_pty["label"] == "Local PTY shell"
      assert local_pty["transport"] == "util_linux_script"
      assert local_pty["pty"] == true
      assert "pty" in local_pty["capabilities"]
      assert docker["label"] == "Docker container shell"
      assert docker["transport"] == "docker_cli"
      assert docker["isolation"] == "container"
      assert docker["network"] == "none"
      assert docker["pull_policy"] == "never"
      assert docker["drops_capabilities"] == true
      assert docker["no_new_privileges"] == true
      assert docker["policy"]["allowed"] == true
      assert docker["policy"]["requires_approval"] == false
      assert docker["policy"]["docker"]["pull_policy"] == "never"
      assert "container" in docker["capabilities"]
      assert ssh["label"] == "SSH shell"
      assert ssh["transport"] == "openssh_cli"
      assert ssh["isolation"] == "remote_host"
      assert ssh["configured"] == System.get_env("LEMON_SSH_TERMINAL_TARGET") not in [nil, ""]
      assert ssh["policy"]["ssh"]["allowed_targets_configured"] == false
      refute Map.has_key?(ssh, "target")
      assert "ssh" in ssh["capabilities"]
    end

    test "returns terminal backend live proof and Docker hardening summary" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "terminal_backends_status_test_#{System.unique_integer([:positive])}"
        )

      proof_dir = Path.join([tmp_dir, ".lemon", "proofs"])
      File.mkdir_p!(proof_dir)

      File.write!(
        Path.join(proof_dir, "terminal-backend-latest.json"),
        Jason.encode!(%{
          status: "completed",
          completed_count: 4,
          failed_count: 0,
          skipped_count: 0,
          proof_object: "lemon.terminal_backend_smoke",
          generated_at: "2026-05-17T06:26:25.028059Z",
          results: [
            %{backend: "local", status: "completed", output: "private local output"},
            %{backend: "local_pty", status: "completed", output: "private pty output"},
            %{
              backend: "docker",
              status: "completed",
              output: "private docker output",
              hardening: %{
                read_only_rootfs: true,
                tmpfs_noexec: true,
                drops_capabilities: true,
                no_new_privileges: true,
                cgroup_memory_limit: true,
                cgroup_cpu_quota: true,
                cgroup_pids_limit: true,
                pull_policy: "never",
                network: "none",
                memory: "1g",
                cpus: "2",
                pids_limit: "256",
                raw_command: "private command"
              }
            },
            %{backend: "ssh", status: "completed", output: "private ssh output"}
          ]
        })
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:ok, result} = TerminalBackendsStatus.handle(%{"projectDir" => tmp_dir}, @ctx)

      assert result["liveProof"]["status"] == "completed"
      assert result["liveProof"]["completedCount"] == 4
      assert result["liveProof"]["missingCount"] == 0
      assert result["liveProof"]["proofObject"] == "lemon.terminal_backend_smoke"
      assert result["summary"]["liveProofStatus"] == "completed"
      assert result["summary"]["liveProofCompletedCount"] == 4
      assert result["summary"]["liveProofMissingCount"] == 0
      assert result["summary"]["dockerHardeningReturned"] == true

      assert Enum.all?(
               result["liveProof"]["backendStatuses"],
               &(&1["status"] == "completed")
             )

      docker = result["liveProof"]["terminalHardening"]["docker"]
      assert docker["readOnlyRootfs"] == true
      assert docker["tmpfsNoexec"] == true
      assert docker["dropsCapabilities"] == true
      assert docker["noNewPrivileges"] == true
      assert docker["cgroupMemoryLimit"] == true
      assert docker["cgroupCpuQuota"] == true
      assert docker["cgroupPidsLimit"] == true
      assert docker["pullPolicy"] == "never"
      assert docker["network"] == "none"
      assert docker["memory"] == "1g"
      assert docker["cpus"] == "2"
      assert docker["pidsLimit"] == "256"

      rendered = inspect(result)
      refute rendered =~ tmp_dir
      refute rendered =~ "private local output"
      refute rendered =~ "private docker output"
      refute rendered =~ "private command"
    end

    test "has correct method name and scopes" do
      assert TerminalBackendsStatus.name() == "terminal.backends.status"
      assert TerminalBackendsStatus.scopes() == [:read]
    end
  end

  describe "ProvidersStatus" do
    test "returns redacted provider readiness without credential material" do
      previous = System.get_env("OPENAI_API_KEY")

      on_exit(fn ->
        if previous do
          System.put_env("OPENAI_API_KEY", previous)
        else
          System.delete_env("OPENAI_API_KEY")
        end
      end)

      System.put_env("OPENAI_API_KEY", "fake-provider-secret")

      assert {:ok, result} = ProvidersStatus.handle(%{"provider" => "openai"}, @ctx)

      assert result["count"] == 1
      assert result["readyCount"] == 1
      assert result["summary"]["action"] == "providers.status"
      assert result["summary"]["providerCount"] == 1
      assert result["summary"]["readyProviderCount"] == 1
      assert result["summary"]["selectedProvider"] == "openai"
      assert result["summary"]["routingDecision"] == "selected_primary"

      assert result["summary"]["fallbackProofStatus"] in [
               "missing",
               "proven",
               "blocked",
               "skipped"
             ]

      assert result["summary"]["cleanup"] == result["cleanup"]
      assert result["cleanup"]["includesRawApiKeys"] == false
      assert result["cleanup"]["includesSecretNames"] == false
      assert result["cleanup"]["includesRawBaseUrls"] == false
      assert result["cleanup"]["includesEnvVarNames"] == false
      assert result["routing"]["selectedProvider"] == "openai"
      assert result["routing"]["decision"] == "selected_primary"
      assert result["routing"]["cleanup"]["includesRawApiKeys"] == false

      assert [
               %{
                 "provider" => "openai",
                 "configName" => "openai",
                 "known" => true,
                 "configured" => true,
                 "credentialReady" => true,
                 "config" => %{"apiKeyConfigured" => true},
                 "ambient" => %{"envConfigured" => true}
               }
             ] = result["providers"]

      refute inspect(result) =~ "fake-provider-secret"
      refute inspect(result) =~ "OPENAI_API_KEY"
    end

    test "previews fallback routing without leaking credential material" do
      previous_openai = System.get_env("OPENAI_API_KEY")
      previous_zai = System.get_env("ZAI_API_KEY")

      on_exit(fn ->
        if previous_openai,
          do: System.put_env("OPENAI_API_KEY", previous_openai),
          else: System.delete_env("OPENAI_API_KEY")

        if previous_zai,
          do: System.put_env("ZAI_API_KEY", previous_zai),
          else: System.delete_env("ZAI_API_KEY")
      end)

      System.delete_env("OPENAI_API_KEY")
      System.put_env("ZAI_API_KEY", "fake-zai-secret")

      assert {:ok, result} =
               ProvidersStatus.handle(
                 %{"provider" => "openai", "fallbackProviders" => ["zai"]},
                 @ctx
               )

      assert result["routing"]["requestedProvider"] == "openai"
      assert result["routing"]["selectedProvider"] == "zai"
      assert result["routing"]["decision"] == "selected_fallback"
      assert "zai" in result["routing"]["fallbackProviders"]

      refute inspect(result) =~ "fake-zai-secret"
      refute inspect(result) =~ "ZAI_API_KEY"
    end

    test "returns redacted provider fallback proof status" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "providers_status_proof_test_#{System.unique_integer([:positive])}"
        )

      proof_dir = Path.join([tmp_dir, ".lemon", "proofs"])
      File.mkdir_p!(proof_dir)

      File.write!(
        Path.join(proof_dir, "provider-fallback-latest.json"),
        Jason.encode!(%{
          status: "completed",
          proof_object: "lemon.provider_fallback_smoke",
          proof_scope: "provider_fallback",
          completed_count: 3,
          failed_count: 0,
          details: %{
            primary_provider: "openai",
            fallback_provider: "zai",
            final_provider: "zai",
            prompt: "private prompt",
            provider_response: "private answer",
            api_key: "private-key"
          },
          checks: [
            %{
              name: "provider_fallback_uses_ready_fallback",
              status: "completed",
              ok: true
            }
          ],
          cleanup: %{
            includes_raw_api_keys: false,
            includes_raw_prompts: false,
            includes_provider_answers: false
          }
        })
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:ok, result} =
               ProvidersStatus.handle(
                 %{"projectDir" => tmp_dir, "provider" => "openai"},
                 @ctx
               )

      assert result["liveProofs"]["fallback"]["status"] == "proven"
      assert result["liveProofs"]["fallback"]["proofStatus"] == "completed"
      assert result["liveProofs"]["fallback"]["proofObject"] == "lemon.provider_fallback_smoke"
      assert result["liveProofs"]["fallback"]["primaryProvider"] == "openai"
      assert result["liveProofs"]["fallback"]["fallbackProvider"] == "zai"
      assert result["liveProofs"]["fallback"]["finalProvider"] == "zai"
      assert is_binary(result["liveProofs"]["fallback"]["proofHash"])
      assert result["liveProofs"]["fallback"]["nextAction"] == "keep live fallback proof current"
      assert result["liveProofs"]["proofScopeCounts"]["provider_fallback"] == 1
      assert result["liveProofs"]["cleanup"]["includesRawApiKeys"] == false
      assert result["liveProofs"]["cleanup"]["includesRawPrompts"] == false
      assert result["liveProofs"]["cleanup"]["includesProviderAnswers"] == false
      assert result["liveProofs"]["cleanup"]["includesProviderResponses"] == false

      refute inspect(result) =~ "private prompt"
      refute inspect(result) =~ "private answer"
      refute inspect(result) =~ "private-key"
    end

    test "reports unknown requested providers as not ready" do
      assert {:ok, result} = ProvidersStatus.handle(%{"provider" => "opencode-go"}, @ctx)

      assert [
               %{
                 "provider" => "opencode_go",
                 "known" => false,
                 "configured" => false,
                 "credentialReady" => false
               }
             ] = result["providers"]
    end

    test "has correct method name and scopes" do
      assert ProvidersStatus.name() == "providers.status"
      assert ProvidersStatus.scopes() == [:read]
    end
  end

  describe "MemoryStatus" do
    test "returns redacted memory-provider shape" do
      assert {:ok, result} = MemoryStatus.handle(%{}, @ctx)

      assert result["providerCount"] >= 1
      assert result["enabledProviderCount"] >= 1
      assert result["health"]["status"] == "ready"
      assert result["health"]["enabledCount"] >= 1
      assert result["health"]["disabledCount"] >= 0
      assert result["health"]["moduleLoadedCount"] >= 1
      assert result["health"]["moduleMissingCount"] >= 0
      assert "session" in result["health"]["searchableScopes"]
      assert result["health"]["scopeCounts"]["session"] >= 1
      assert result["cleanup"]["includesMemoryContents"] == false
      assert result["cleanup"]["includesRawProviderConfig"] == false
      assert result["cleanup"]["includesSecretValues"] == false
      assert result["summary"]["action"] == "memory.status"
      assert result["summary"]["providerCount"] == result["providerCount"]
      assert result["summary"]["enabledProviderCount"] == result["enabledProviderCount"]
      assert result["summary"]["healthStatus"] == result["health"]["status"]

      assert result["summary"]["searchableScopeCount"] ==
               length(result["health"]["searchableScopes"])

      assert result["summary"]["cleanup"] == result["cleanup"]

      local = Enum.find(result["providers"], &(&1["id"] == "local"))
      assert local["enabled"] == true
      assert local["source"] == "builtin"
      assert "session" in local["scopes"]
      assert local["moduleLoaded"] == true

      refute inspect(result) =~ "prompt_summary"
      refute inspect(result) =~ "answer_summary"
    end

    test "has correct method name and scopes" do
      assert MemoryStatus.name() == "memory.status"
      assert MemoryStatus.scopes() == [:read]
    end
  end

  describe "SkillsStatus" do
    test "preserves not-ready skill requirements and summary counts" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "skills_status_test_#{System.unique_integer([:positive])}")

      missing_bin = "missing-lemon-skill-bin-#{System.unique_integer([:positive])}"

      write_skill!(
        tmp_dir,
        "ready-skill",
        """
        ---
        name: Ready Skill
        description: Ready skill
        ---

        Body.
        """
      )

      write_skill!(
        tmp_dir,
        "not-ready-skill",
        """
        ---
        name: Not Ready Skill
        description: Not ready skill
        requires:
          bins:
            - #{missing_bin}
        ---

        Body.
        """
      )

      LemonSkills.Registry.refresh(cwd: tmp_dir)

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
      end)

      assert {:ok, result} = SkillsStatus.handle(%{"cwd" => tmp_dir}, @ctx)

      ready = Enum.find(result["skills"], &(&1["key"] == "ready-skill"))
      not_ready = Enum.find(result["skills"], &(&1["key"] == "not-ready-skill"))

      assert ready["status"]["ready"] == true
      assert ready["status"]["activationState"] == "active"

      assert not_ready["status"]["ready"] == false
      assert not_ready["status"]["activationState"] == "not_ready"
      assert missing_bin in not_ready["status"]["missingBins"]
      assert result["summary"]["readyCount"] >= 1
      assert result["summary"]["notReadyCount"] >= 1
      assert result["summary"]["missingRequirementCounts"]["bins"] >= 1

      refute inspect(result) =~ tmp_dir
    end

    test "has correct method name and scopes" do
      assert SkillsStatus.name() == "skills.status"
      assert SkillsStatus.scopes() == [:read]
    end
  end

  describe "ExtensionsStatus" do
    test "keeps default extension directories diagnostics-only until trusted" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "extensions_trust_status_test_#{System.unique_integer([:positive])}"
        )

      extensions_dir = Path.join([tmp_dir, ".lemon", "extensions"])
      File.mkdir_p!(extensions_dir)

      module_name = "LemonControlPlaneTrustBoundaryExt#{System.unique_integer([:positive])}"

      File.write!(
        Path.join(extensions_dir, "trust_boundary_extension.exs"),
        """
        defmodule #{module_name} do
          @behaviour CodingAgent.Extensions.Extension

          def name, do: "trust-boundary-extension"
          def version, do: "1.0.0"
        end
        """
      )

      module = Module.concat([module_name])

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
        :code.purge(module)
        :code.delete(module)
      end)

      assert {:ok, result} = ExtensionsStatus.handle(%{"cwd" => tmp_dir}, @ctx)

      assert result["totalLoaded"] == 0
      assert result["paths"] == []
      assert result["execution"]["autoLoadDefaultPaths"] == false
      assert result["execution"]["defaultDirectoriesDiagnosticsOnly"] == true

      File.write!(
        Path.join([tmp_dir, ".lemon", "config.toml"]),
        """
        [runtime.extensions]
        auto_load_default_paths = true
        """
      )

      assert {:ok, trusted_result} = ExtensionsStatus.handle(%{"cwd" => tmp_dir}, @ctx)

      assert trusted_result["totalLoaded"] == 1
      assert trusted_result["execution"]["autoLoadDefaultPaths"] == true
      assert trusted_result["execution"]["defaultDirectoriesDiagnosticsOnly"] == false
      assert Enum.any?(trusted_result["paths"], &(&1["exists"] == true))
    end

    test "global extension disable policy blocks explicit status execution" do
      System.put_env("LEMON_EXTENSIONS_ENABLED", "false")
      on_exit(fn -> System.delete_env("LEMON_EXTENSIONS_ENABLED") end)

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "extensions_disabled_status_test_#{System.unique_integer([:positive])}"
        )

      extensions_dir = Path.join([tmp_dir, ".lemon", "extensions"])
      File.mkdir_p!(extensions_dir)

      module_name = "LemonControlPlaneDisabledExt#{System.unique_integer([:positive])}"

      File.write!(
        Path.join([tmp_dir, ".lemon", "config.toml"]),
        """
        [runtime.extensions]
        enabled = false
        auto_load_default_paths = true
        """
      )

      File.write!(
        Path.join(extensions_dir, "disabled_extension.exs"),
        """
        defmodule #{module_name} do
          @behaviour CodingAgent.Extensions.Extension

          File.write!(#{inspect(Path.join(tmp_dir, "should_not_exist.txt"))}, "loaded")

          def name, do: "disabled-extension"
          def version, do: "1.0.0"
        end
        """
      )

      module = Module.concat([module_name])

      on_exit(fn ->
        File.rm_rf!(tmp_dir)
        :code.purge(module)
        :code.delete(module)
      end)

      assert {:ok, result} =
               ExtensionsStatus.handle(
                 %{"cwd" => tmp_dir, "extensionPaths" => [extensions_dir]},
                 @ctx
               )

      assert result["status"] == "disabled"
      assert result["totalLoaded"] == 0
      assert result["summary"]["action"] == "extensions.status"
      assert result["summary"]["status"] == "disabled"
      assert result["summary"]["enabled"] == false
      assert result["summary"]["candidatePathCount"] == 1
      assert result["summary"]["loadedPathCount"] == 0
      assert result["execution"]["enabled"] == false
      assert result["execution"]["candidatePathCount"] == 1
      assert result["execution"]["loadedPathCount"] == 0
      assert result["hostRuntime"]["beam"]["status"] == "disabled"
      refute File.exists?(Path.join(tmp_dir, "should_not_exist.txt"))
    end

    test "returns redacted extension load, conflict, and provider shape" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "extensions_status_test_#{System.unique_integer([:positive])}"
        )

      extensions_dir = Path.join([tmp_dir, ".lemon", "extensions"])
      File.mkdir_p!(extensions_dir)

      suffix = System.unique_integer([:positive])
      module_name = "LemonControlPlaneTestExtension#{suffix}"
      provider_module_name = "LemonControlPlaneTestExtensionProvider#{suffix}"
      extension_path = Path.join(extensions_dir, "good_extension.exs")
      broken_path = Path.join(extensions_dir, "broken_extension.exs")
      manifest_path = Path.join(extensions_dir, "lemon_extension.json")

      File.write!(
        extension_path,
        """
        defmodule #{provider_module_name} do
        end

        defmodule #{module_name} do
          @behaviour CodingAgent.Extensions.Extension

          def name, do: "operator-test-extension"
          def version, do: "1.0.0"
          def capabilities, do: [:tools, :providers]
          def config_schema, do: %{"type" => "object"}

          def tools(_cwd) do
            [
              %AgentCore.Types.AgentTool{
                name: "read",
                description: "shadowed read",
                parameters: %{"type" => "object"},
                label: "Shadowed Read",
                execute: fn _, _, _, _ -> %AgentCore.Types.AgentToolResult{} end
              }
            ]
          end

          def providers do
            [
              %{type: :model, name: :operator_test_provider, module: #{provider_module_name}}
            ]
          end
        end
        """
      )

      File.write!(broken_path, "defmodule BrokenExtension#{suffix} do\n  def broken(\nend\n")

      File.write!(
        manifest_path,
        Jason.encode!(%{
          schema_version: 1,
          name: "operator-private-plugin",
          version: "1.0.0",
          capabilities: ["tools"],
          hosts: [%{type: "beam"}, %{type: "wasm"}, %{type: "external"}],
          distribution: %{source: "registry", url: "https://secret.invalid/plugin"}
        })
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:ok, result} =
               ExtensionsStatus.handle(
                 %{"cwd" => tmp_dir, "extensionPaths" => [extensions_dir]},
                 @ctx
               )

      assert ExtensionsStatus.name() == "extensions.status"
      assert ExtensionsStatus.scopes() == [:read]
      assert result["totalLoaded"] == 1
      assert result["totalErrors"] == 1
      assert result["status"] in ["degraded", "conflicts"]
      assert result["summary"]["action"] == "extensions.status"
      assert result["summary"]["extensionCount"] == 1
      assert result["summary"]["pathCount"] == 1
      assert result["summary"]["totalLoaded"] == 1
      assert result["summary"]["totalErrors"] == 1
      assert result["summary"]["providerCount"] == 1
      assert result["summary"]["hostStatuses"]["beam"] == "degraded"
      assert result["summary"]["cleanup"] == result["cleanup"]

      assert [%{"name" => "operator-test-extension", "hasConfigSchema" => true}] =
               result["extensions"]

      assert [%{"exists" => true, "pathHash" => path_hash}] = result["paths"]
      assert is_binary(path_hash)

      assert [%{"sourcePathHash" => error_path_hash, "errorMessageHash" => message_hash}] =
               result["loadErrors"]

      assert is_binary(error_path_hash)
      assert is_binary(message_hash)
      assert result["toolConflicts"]["shadowedCount"] >= 1
      assert result["executionTelemetry"]["proofPresent"] in [true, false]
      assert is_binary(result["executionTelemetry"]["telemetryCheckStatus"])
      assert is_binary(result["executionTelemetry"]["disabledCheckStatus"])
      assert is_binary(result["executionTelemetry"]["envDisabledCheckStatus"])
      assert result["executionTelemetry"]["emitsRedactedStartStopException"] in [true, false]
      assert result["executionTelemetry"]["blocksDisabledExplicitPaths"] in [true, false]
      assert result["executionTelemetry"]["redaction"]["containsRawPaths"] == false
      assert result["executionTelemetry"]["redaction"]["containsFileContents"] == false
      assert result["executionTelemetry"]["redaction"]["containsLoadErrorMessages"] == false
      assert result["executionTelemetry"]["redaction"]["containsToolResultPayload"] == false
      assert result["wasmTelemetry"]["proofPresent"] in [true, false]
      assert is_binary(result["wasmTelemetry"]["successCheckStatus"])
      assert is_binary(result["wasmTelemetry"]["errorCheckStatus"])
      assert is_binary(result["wasmTelemetry"]["exceptionCheckStatus"])
      assert is_binary(result["wasmTelemetry"]["redactionCheckStatus"])
      assert result["wasmTelemetry"]["emitsRedactedStartStopException"] in [true, false]
      assert result["wasmTelemetry"]["hostBoundary"]["emitsStartStopException"] in [true, false]
      assert result["wasmTelemetry"]["hostBoundary"]["usesHashedWasmPaths"] in [true, false]
      assert is_integer(result["wasmTelemetry"]["hostBoundary"]["toolCount"])
      assert result["wasmTelemetry"]["redaction"]["containsRawPaths"] == false
      assert result["wasmTelemetry"]["redaction"]["containsRawParams"] == false
      assert result["wasmTelemetry"]["redaction"]["containsRawToolCallIds"] == false
      assert result["wasmTelemetry"]["redaction"]["containsSidecarErrorText"] == false
      assert result["wasmTelemetry"]["redaction"]["containsToolResultPayload"] == false
      assert result["wasmPolicy"]["proofPresent"] in [true, false]
      assert is_binary(result["wasmPolicy"]["httpCheckStatus"])
      assert is_binary(result["wasmPolicy"]["toolInvokeCheckStatus"])
      assert is_binary(result["wasmPolicy"]["execCheckStatus"])
      assert is_binary(result["wasmPolicy"]["safeCheckStatus"])
      assert is_binary(result["wasmPolicy"]["overrideCheckStatus"])
      assert result["wasmPolicy"]["capabilityApprovalDefaults"] in [true, false]
      assert result["wasmPolicy"]["explicitOverrideSupported"] in [true, false]

      assert result["wasmPolicy"]["policyBoundary"]["httpRequiresApprovalByDefault"] in [
               true,
               false
             ]

      assert result["wasmPolicy"]["policyBoundary"]["toolInvokeRequiresApprovalByDefault"] in [
               true,
               false
             ]

      assert result["wasmPolicy"]["policyBoundary"]["execRequiresApprovalByDefault"] in [
               true,
               false
             ]

      assert result["wasmPolicy"]["redaction"]["containsRawPaths"] == false
      assert result["wasmPolicy"]["redaction"]["containsRawParams"] == false
      assert result["wasmPolicy"]["redaction"]["containsRawToolCallIds"] == false
      assert result["registryAudit"]["proofPresent"] in [true, false]
      assert is_binary(result["registryAudit"]["validateCheckStatus"])
      assert is_binary(result["registryAudit"]["blockCheckStatus"])
      assert is_binary(result["registryAudit"]["updateCheckStatus"])
      assert is_binary(result["registryAudit"]["noCodeCheckStatus"])
      assert is_binary(result["registryAudit"]["redactionCheckStatus"])
      assert result["registryAudit"]["registryWorkflowSupported"] in [true, false]
      assert result["registryAudit"]["registryBoundary"]["loadsExtensionCode"] in [true, false]
      assert is_integer(result["registryAudit"]["registryBoundary"]["installableCount"])
      assert is_integer(result["registryAudit"]["registryBoundary"]["blockedCount"])
      assert is_integer(result["registryAudit"]["registryBoundary"]["updateCandidateCount"])
      assert result["registryAudit"]["redaction"]["containsRawRegistryPaths"] == false
      assert result["registryAudit"]["redaction"]["containsDistributionUrls"] == false
      assert result["registryAudit"]["redaction"]["containsPackageNames"] == false
      assert result["registryAudit"]["redaction"]["containsManifestContents"] == false
      assert result["wasmLifecycle"]["proofPresent"] in [true, false]
      assert is_binary(result["wasmLifecycle"]["discoverCheckStatus"])
      assert is_binary(result["wasmLifecycle"]["invokeCheckStatus"])
      assert is_binary(result["wasmLifecycle"]["statusCheckStatus"])
      assert is_binary(result["wasmLifecycle"]["stopCheckStatus"])
      assert is_binary(result["wasmLifecycle"]["redactionCheckStatus"])
      assert result["wasmLifecycle"]["lifecycleSupported"] in [true, false]

      assert result["wasmLifecycle"]["lifecycleBoundary"]["discoverEmitsRedactedStartStop"] in [
               true,
               false
             ]

      assert result["wasmLifecycle"]["lifecycleBoundary"]["invokeEmitsRedactedStartStop"] in [
               true,
               false
             ]

      assert result["wasmLifecycle"]["lifecycleBoundary"]["statusTracksRunningSidecar"] in [
               true,
               false
             ]

      assert result["wasmLifecycle"]["lifecycleBoundary"]["stopTerminatesSidecar"] in [
               true,
               false
             ]

      assert is_integer(result["wasmLifecycle"]["lifecycleBoundary"]["toolCount"])
      assert result["wasmLifecycle"]["redaction"]["containsRawCwd"] == false
      assert result["wasmLifecycle"]["redaction"]["containsRawSessionIds"] == false
      assert result["wasmLifecycle"]["redaction"]["containsRawToolNames"] == false
      assert result["wasmLifecycle"]["redaction"]["containsRawParams"] == false

      assert Enum.any?(result["toolConflicts"]["conflicts"], fn conflict ->
               conflict["toolName"] == "read" and conflict["winner"]["type"] == "builtin"
             end)

      assert result["providerRegistration"]["configuredProviderCount"] == 1
      assert result["hostRuntime"]["beam"]["status"] == "degraded"
      assert result["hostRuntime"]["beam"]["loadedExtensionCount"] == 1
      assert result["hostRuntime"]["beam"]["loadErrorCount"] == 1
      assert result["hostRuntime"]["beam"]["manifestCount"] >= 1
      assert result["hostRuntime"]["wasm"]["manifestCount"] >= 1
      assert result["hostRuntime"]["wasm"]["status"] in ["disabled", "enabled_idle", "running"]
      assert result["hostRuntime"]["wasm"]["supervisorRunning"] in [true, false]
      assert result["hostRuntime"]["external"]["status"] == "manifest_only"
      assert result["hostRuntime"]["cleanup"]["includesRawSourcePaths"] == false
      assert result["hostRuntime"]["cleanup"]["includesLoadErrorMessages"] == false
      assert result["hostRuntime"]["cleanup"]["loadsDefaultDirectoryCode"] == false

      assert [
               %{
                 "type" => "model",
                 "name" => "operator_test_provider",
                 "extension" => ^module_name
               }
             ] = result["providerRegistration"]["providers"]

      assert result["cleanup"]["includesRawSourcePaths"] == false
      assert result["cleanup"]["includesLoadErrorMessages"] == false
      assert result["cleanup"]["includesConfigSchemas"] == false
      assert result["cleanup"]["includesProviderModules"] == false

      result_text = inspect(result)
      refute result_text =~ tmp_dir
      refute result_text =~ extension_path
      refute result_text =~ broken_path
      refute result_text =~ "syntax"
    end
  end

  describe "LspDiagnosticsStatus" do
    test "returns redacted diagnostics capability status" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "lsp_diagnostics_status_test_#{System.unique_integer([:positive])}"
        )

      proof_dir = Path.join([tmp_dir, ".lemon", "proofs"])
      File.mkdir_p!(proof_dir)

      proof_path = Path.join(proof_dir, "lsp-server-smoke-latest.json")

      File.write!(
        proof_path,
        Jason.encode!(%{
          status: "completed",
          proof_object: "lemon.lsp_server_smoke",
          proof_scope: "lsp_real_repo_fixtures_smoke",
          completed_count: 6,
          failed_count: 0,
          skipped_count: 0,
          generated_at: "2026-05-17T12:00:00Z",
          checks: [
            %{
              name: "pyright_editor_flow",
              status: "completed",
              proof_scope: "lsp_real_repo_fixtures_smoke",
              raw_path: "/private/project/app.py"
            },
            %{
              name: "gopls_editor_flow",
              status: "completed",
              proof_scope: "lsp_real_repo_fixtures_smoke"
            }
          ],
          cleanup: %{
            includes_raw_paths: false,
            includes_file_contents: false,
            includes_diagnostics_output: false,
            includes_server_io: false
          }
        })
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:ok, result} =
               LspDiagnosticsStatus.handle(
                 %{"diagnosticsTimeoutMs" => 12_345, "projectDir" => tmp_dir},
                 @ctx
               )

      assert result["status"] == "preview"
      assert result["default_timeout_ms"] == 12_345
      assert result["supported_language_count"] >= 6
      assert result["summary"]["action"] == "lsp.diagnostics.status"
      assert result["summary"]["status"] == "preview"
      assert result["summary"]["defaultTimeoutMs"] == 12_345
      assert result["summary"]["supportedLanguageCount"] >= 6
      assert result["summary"]["serverManagerRunning"] == true
      assert Enum.any?(result["supported_languages"], &(&1["language"] == "elixir"))
      assert is_integer(result["executable_summary"]["available_count"])
      assert result["cleanup"]["includes_raw_paths"] == false
      assert result["cleanup"]["includes_file_contents"] == false
      assert result["cleanup"]["includes_diagnostics_output"] == false
      assert result["cleanup"]["includes_workspace_roots"] == false
      assert result["cleanup"]["includes_server_io"] == false
      assert result["cleanup"]["includes_raw_session_ids"] == false
      assert result["server_manager"]["running"] == true
      assert result["server_manager"]["mode"] == "registry_and_sessions"
      assert result["server_manager"]["registry"]["count"] == 6
      assert result["server_manager"]["registry"]["cleanup"]["includes_executable_paths"] == false
      assert result["proofs"]["proof_count"] == 1
      assert result["proofs"]["check_count"] == 2
      assert result["summary"]["proofCount"] == 1
      assert result["summary"]["checkCount"] == 2
      assert result["summary"]["cleanup"] == result["cleanup"]
      assert result["summary"]["proofCleanup"] == result["proofs"]["cleanup"]
      assert result["proofs"]["cleanup"]["includes_raw_paths"] == false
      assert result["proofs"]["cleanup"]["includes_raw_proof_details"] == false

      assert [
               %{
                 "proof_object" => "lemon.lsp_server_smoke",
                 "status" => "completed",
                 "completed_count" => 6
               }
             ] = result["proofs"]["recent_proofs"]

      assert Enum.any?(
               result["proofs"]["latest_checks"],
               &(&1["name"] == "pyright_editor_flow" and &1["status"] == "completed")
             )

      refute inspect(result) =~ proof_path
      refute inspect(result) =~ "/private/project"
    end

    test "has correct method name and scopes" do
      assert LspDiagnosticsStatus.name() == "lsp.diagnostics.status"
      assert LspDiagnosticsStatus.scopes() == [:read]
    end
  end

  describe "LspServerStart and LspServerStop" do
    test "starts and stops a redacted supervised LSP session through the control plane" do
      cat = System.find_executable("cat")

      if cat do
        previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")
        session_id = "control-plane-lsp-#{System.unique_integer([:positive])}"

        on_exit(fn ->
          _ = LemonCore.LspServerManager.stop_session(session_id)

          if previous do
            System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
          else
            System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
          end
        end)

        System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", cat)

        assert {:ok, result} =
                 LspServerStart.handle(
                   %{
                     "serverId" => "elixir-ls",
                     "sessionId" => session_id,
                     "cwd" => File.cwd!()
                   },
                   @ctx
                 )

        assert result["session_id"] == session_id
        assert result["server_id"] == "elixir_ls"
        assert result["status"] == "running"
        assert result["command"] == "cat"
        assert is_binary(result["cwd_hash"])
        assert result["summary"]["action"] == "start"
        assert result["summary"]["session_id_returned"] == true
        assert result["summary"]["session_hash_returned"] == true
        assert result["summary"]["command_name_returned"] == true
        assert result["summary"]["cwd_hash_returned"] == true
        assert result["summary"]["cleanup"]["includes_raw_session_id"] == true
        assert result["summary"]["cleanup"]["includes_raw_cwd"] == false
        assert result["summary"]["cleanup"]["includes_executable_path"] == false
        refute inspect(result) =~ File.cwd!()
        refute inspect(result) =~ cat

        assert {:ok, stopped} =
                 LspServerStop.handle(%{"sessionId" => session_id}, @ctx)

        assert stopped["session_id"] == session_id
        assert stopped["status"] == "stopped"
        assert stopped["summary"]["action"] == "stop"
        assert stopped["summary"]["session_id_returned"] == true
        assert stopped["summary"]["cleanup"]["includes_server_io"] == false
      end
    end

    test "sends a JSON-RPC request through a supervised LSP session" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "control_plane_lsp_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      server_path = Path.join(tmp_dir, "fake_lsp_server")
      File.write!(server_path, fake_lsp_server_script())
      File.chmod!(server_path, 0o755)

      previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")
      session_id = "control-plane-lsp-rpc-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        _ = LemonCore.LspServerManager.stop_session(session_id)
        File.rm_rf!(tmp_dir)

        if previous do
          System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
        else
          System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
        end
      end)

      System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", server_path)

      assert {:ok, start} =
               LspServerStart.handle(
                 %{"serverId" => "elixir-ls", "sessionId" => session_id, "cwd" => tmp_dir},
                 @ctx
               )

      assert start["session_id"] == session_id

      assert {:ok, response} =
               LspServerRequest.handle(
                 %{
                   "sessionId" => session_id,
                   "method" => "initialize",
                   "params" => %{"capabilities" => %{}},
                   "timeoutMs" => 1_000
                 },
                 @ctx
               )

      assert response["jsonrpc"] == "2.0"
      assert is_integer(response["id"])
      assert response["result"]["capabilities"]["textDocumentSync"] == 1
      assert response["summary"]["action"] == "request"
      assert response["summary"]["method"] == "initialize"
      assert response["summary"]["timeout_ms"] == 1_000
      assert response["summary"]["result_returned"] == true
      assert response["summary"]["raw_session_id_returned"] == false
      assert response["summary"]["cleanup"]["includes_request_params"] == false
      assert response["summary"]["cleanup"]["includes_protocol_result"] == true

      assert {:ok, stopped} = LspServerStop.handle(%{"sessionId" => session_id}, @ctx)
      assert stopped["status"] == "stopped"
    end

    test "initializes a supervised LSP session and reports redacted diagnostics" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "control_plane_lsp_init_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      server_path = Path.join(tmp_dir, "fake_diagnostic_lsp_server")
      raw_uri = "file:///private/control-plane/lib/secret.ex"
      raw_message = "private diagnostic"
      File.write!(server_path, fake_diagnostic_lsp_server_script(raw_uri, raw_message))
      File.chmod!(server_path, 0o755)

      previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")
      session_id = "control-plane-lsp-init-#{System.unique_integer([:positive])}"

      on_exit(fn ->
        _ = LemonCore.LspServerManager.stop_session(session_id)
        File.rm_rf!(tmp_dir)

        if previous do
          System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
        else
          System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
        end
      end)

      System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", server_path)

      assert {:ok, start} =
               LspServerStart.handle(
                 %{"serverId" => "elixir-ls", "sessionId" => session_id, "cwd" => tmp_dir},
                 @ctx
               )

      assert {:ok, response} =
               LspServerInitialize.handle(
                 %{
                   "sessionId" => session_id,
                   "params" => %{"capabilities" => %{}, "rootUri" => raw_uri},
                   "timeoutMs" => 1_000
                 },
                 @ctx
               )

      assert response["result"]["capabilities"]["textDocumentSync"] == 1
      assert response["summary"]["action"] == "initialize"
      assert response["summary"]["method"] == "initialize"
      assert response["summary"]["timeout_ms"] == 1_000
      assert response["summary"]["result_returned"] == true
      assert response["summary"]["raw_session_id_returned"] == false
      assert response["summary"]["cleanup"]["includes_request_params"] == false
      assert response["summary"]["cleanup"]["includes_protocol_result"] == true

      active =
        wait_until(fn ->
          status = LemonCore.LspServerManager.status()

          active =
            Enum.find(status.active_servers, fn active ->
              active.session_hash == start["session_hash"]
            end)

          if active && active.diagnostic_count == 2 do
            active
          end
        end)

      assert active.initialized == true
      assert active.notification_count == 1
      assert active.diagnostic_batch_count == 1
      assert active.diagnostic_count == 2
      refute inspect(active) =~ raw_uri
      refute inspect(active) =~ raw_message
      refute inspect(active) =~ session_id
      refute inspect(active) =~ server_path

      assert {:ok, stopped} = LspServerStop.handle(%{"sessionId" => session_id}, @ctx)
      assert stopped["diagnostic_count"] == 2
      assert stopped["status"] == "stopped"
      assert stopped["summary"]["diagnostic_count"] == 2
      assert stopped["summary"]["cleanup"]["includes_diagnostic_text"] == false
    end

    test "opens changes and closes an LSP document through the control plane" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "control_plane_lsp_document_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      log_path = Path.join(tmp_dir, "document_notifications.log")
      server_path = Path.join(tmp_dir, "fake_document_lsp_server")
      File.write!(server_path, fake_document_lsp_server_script(log_path))
      File.chmod!(server_path, 0o755)

      previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")
      session_id = "control-plane-lsp-document-#{System.unique_integer([:positive])}"
      raw_uri = "file:///private/control-plane/lib/document_secret.ex"
      raw_text = "defmodule Secret do\nend\n"
      changed_text = "defmodule Secret do\n  def hidden, do: :ok\nend\n"

      on_exit(fn ->
        _ = LemonCore.LspServerManager.stop_session(session_id)
        File.rm_rf!(tmp_dir)

        if previous do
          System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
        else
          System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
        end
      end)

      System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", server_path)

      assert {:ok, start} =
               LspServerStart.handle(
                 %{"serverId" => "elixir-ls", "sessionId" => session_id, "cwd" => tmp_dir},
                 @ctx
               )

      assert {:ok, _response} =
               LspServerInitialize.handle(
                 %{
                   "sessionId" => session_id,
                   "params" => %{"capabilities" => %{}, "rootUri" => raw_uri},
                   "timeoutMs" => 1_000
                 },
                 @ctx
               )

      assert {:ok, opened} =
               LspDocumentOpen.handle(
                 %{
                   "sessionId" => session_id,
                   "uri" => raw_uri,
                   "languageId" => "elixir",
                   "text" => raw_text,
                   "version" => 1
                 },
                 @ctx
               )

      assert opened["status"] == "open"
      assert opened["language_id"] == "elixir"
      assert opened["version"] == 1
      assert opened["text_bytes"] == byte_size(raw_text)
      assert opened["summary"]["action"] == "open"
      assert opened["summary"]["text_bytes"] == byte_size(raw_text)
      assert opened["summary"]["raw_uri_returned"] == false
      assert opened["summary"]["document_text_returned"] == false
      assert opened["summary"]["cleanup"]["includes_raw_uri"] == false
      assert opened["summary"]["cleanup"]["includes_document_text"] == false

      assert {:ok, changed} =
               LspDocumentChange.handle(
                 %{
                   "sessionId" => session_id,
                   "uri" => raw_uri,
                   "text" => changed_text,
                   "version" => 2
                 },
                 @ctx
               )

      assert changed["status"] == "changed"
      assert changed["version"] == 2
      assert changed["change_count"] == 1
      assert changed["summary"]["action"] == "change"
      assert changed["summary"]["text_bytes"] == byte_size(changed_text)
      assert changed["summary"]["document_text_returned"] == false

      assert {:ok, closed} =
               LspDocumentClose.handle(%{"sessionId" => session_id, "uri" => raw_uri}, @ctx)

      assert closed["status"] == "closed"
      assert closed["summary"]["action"] == "close"
      assert closed["summary"]["raw_uri_returned"] == false
      assert closed["summary"]["cleanup"]["includes_document_text"] == false

      assert wait_until(fn ->
               if File.exists?(log_path) and File.read!(log_path) =~ "textDocument/didClose" do
                 true
               end
             end)

      status = LemonCore.LspServerManager.status()

      active =
        Enum.find(status.active_servers, fn active ->
          active.session_hash == start["session_hash"]
        end)

      assert active.notification_count == 4
      assert active.document_count == 1
      assert active.open_document_count == 0
      refute inspect(active) =~ raw_uri
      refute inspect(active) =~ raw_text
      refute inspect(active) =~ changed_text
      refute inspect(active) =~ session_id
      refute inspect(active) =~ server_path
    end

    test "has correct method names and scopes" do
      assert LspServerStart.name() == "lsp.server.start"
      assert LspServerStart.scopes() == [:write]
      assert LspServerInitialize.name() == "lsp.server.initialize"
      assert LspServerInitialize.scopes() == [:write]
      assert LspServerRequest.name() == "lsp.server.request"
      assert LspServerRequest.scopes() == [:write]
      assert LspServerStop.name() == "lsp.server.stop"
      assert LspServerStop.scopes() == [:write]
      assert LspDocumentOpen.name() == "lsp.document.open"
      assert LspDocumentOpen.scopes() == [:write]
      assert LspDocumentChange.name() == "lsp.document.change"
      assert LspDocumentChange.scopes() == [:write]
      assert LspDocumentClose.name() == "lsp.document.close"
      assert LspDocumentClose.scopes() == [:write]
    end
  end

  describe "ChannelsStatus" do
    test "returns redacted support diagnostics with registry status" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "channels_status_test_#{System.unique_integer([:positive])}"
        )

      config_dir = Path.join(tmp_dir, ".lemon")
      File.mkdir_p!(config_dir)

      File.write!(
        Path.join(config_dir, "config.toml"),
        """
        [gateway]
        enable_telegram = true
        enable_discord = true

        [gateway.telegram]
        bot_token = "123456:private-token"
        allowed_chat_ids = [123456789]

        [gateway.discord]
        bot_token = "discord-private-token"
        allowed_guild_ids = ["987654321"]
        allowed_channel_ids = ["111222333"]
        message_content_intent_enabled = true

        [[gateway.bindings]]
        transport = "telegram"
        chat_id = 123456789
        topic_id = 35
        session_key = "agent:private-session"

        [[gateway.bindings]]
        transport = "discord"
        channel_id = "111222333"
        session_key = "agent:private-discord-session"
        """
      )

      proof_dir = Path.join([tmp_dir, ".lemon", "proofs"])
      File.mkdir_p!(proof_dir)

      File.write!(
        Path.join(proof_dir, "discord-media-directive-latest.json"),
        Jason.encode!(%{
          status: "completed",
          proof_object: "lemon.discord_media_directive",
          proof_scope: "discord_media_directive",
          completed_count: 2,
          failed_count: 0,
          details: %{
            channel_id: "111222333",
            guild_id: "987654321",
            prompt: "private prompt",
            message_body: "private body"
          },
          checks: [
            %{
              name: "discord_media_directive_attachment_delivered",
              status: "completed",
              ok: true
            }
          ],
          cleanup: %{
            includes_raw_paths: false,
            includes_raw_channel_ids: false,
            includes_message_bodies: false
          }
        })
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:ok, result} = ChannelsStatus.handle(%{"projectDir" => tmp_dir}, @ctx)

      assert is_list(result["channels"])
      assert result["diagnostics"]["binding_count"] == 2
      assert result["diagnostics"]["unsupported_binding_count"] == 0
      assert result["diagnostics"]["cleanup"]["includes_raw_bot_tokens"] == false
      assert result["diagnostics"]["cleanup"]["includes_chat_ids"] == false
      assert result["diagnostics"]["cleanup"]["includes_channel_ids"] == false
      assert result["diagnostics"]["cleanup"]["includes_guild_ids"] == false
      assert result["diagnostics"]["cleanup"]["includes_message_bodies"] == false

      telegram =
        Enum.find(result["diagnostics"]["transports"], &(&1["transport"] == "telegram"))

      discord =
        Enum.find(result["diagnostics"]["transports"], &(&1["transport"] == "discord"))

      assert telegram["enabled"] == true
      assert telegram["token_configured"] == true
      assert telegram["binding_count"] == 1
      assert telegram["topic_binding_count"] == 1
      assert discord["enabled"] == true
      assert discord["token_configured"] == true
      assert discord["binding_count"] == 1
      assert discord["free_response"]["message_content_intent_declared"] == true
      assert discord["slash_commands"]["expected_command_count"] == 16
      assert result["proofs"]["proof_count"] == 1
      assert result["proofs"]["check_count"] == 1
      assert result["proofs"]["cleanup"]["includes_raw_paths"] == false
      assert result["proofs"]["cleanup"]["includes_raw_proof_details"] == false
      assert result["readiness"]["promoted_platforms"] == ["telegram", "discord"]
      assert result["readiness"]["gate_count"] == 9
      assert result["readiness"]["cleanup"]["includes_raw_bot_tokens"] == false
      assert result["readiness"]["cleanup"]["includes_raw_proof_details"] == false

      slash_gate =
        Enum.find(result["readiness"]["gates"], &(&1["id"] == "discord.slash_client_click"))

      assert slash_gate["reason_kind"] == "discord_slash_client_click_missing"
      assert slash_gate["next_action"] =~ "--wait-slash-client-click-proof"
      assert result["summary"]["bindingCount"] == 2
      assert result["summary"]["proofCount"] == 1
      assert result["summary"]["checkCount"] == 1
      assert result["summary"]["launchGateStatus"] in ["blocked", "warning", "passed"]
      assert result["summary"]["launchGateCount"] == 9
      assert is_integer(result["summary"]["launchGateWarningCount"])
      assert result["summary"]["launchGateStatuses"]["discord.slash_client_click"] == "warning"

      assert result["summary"]["launchGateReasonKinds"]["discord.slash_client_click"] ==
               "discord_slash_client_click_missing"

      assert result["summary"]["promotedPlatforms"] == ["telegram", "discord"]
      assert result["summary"]["cleanup"]["includesRawBotTokens"] == false
      assert result["summary"]["cleanup"]["includesChannelIds"] == false
      assert result["summary"]["cleanup"]["includesMessageBodies"] == false
      assert result["summary"]["cleanup"]["includesRawProofDetails"] == false

      assert [
               %{
                 "proof_object" => "lemon.discord_media_directive",
                 "status" => "completed",
                 "proof_scopes" => ["discord_media_directive"]
               }
             ] = result["proofs"]["recent_proofs"]

      assert [
               %{
                 "name" => "discord_media_directive_attachment_delivered",
                 "status" => "completed"
               }
             ] = result["proofs"]["latest_checks"]

      rendered = inspect(result)
      refute rendered =~ "private-token"
      refute rendered =~ "discord-private-token"
      refute rendered =~ "123456789"
      refute rendered =~ "111222333"
      refute rendered =~ "987654321"
      refute rendered =~ "agent:private"
      refute rendered =~ "private prompt"
      refute rendered =~ "private body"
    end

    test "has correct method name and scopes" do
      assert ChannelsStatus.name() == "channels.status"
      assert ChannelsStatus.scopes() == [:read]
    end
  end

  describe "ReadinessStatus" do
    test "returns compact redacted launch readiness summary" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "readiness_status_test_#{System.unique_integer([:positive])}"
        )

      config_dir = Path.join(tmp_dir, ".lemon")
      File.mkdir_p!(config_dir)

      File.write!(
        Path.join(config_dir, "config.toml"),
        """
        [gateway]
        enable_telegram = true
        enable_discord = true

        [gateway.telegram]
        bot_token = "123456:private-token"
        allowed_chat_ids = [123456789]

        [gateway.discord]
        bot_token = "discord-private-token"
        allowed_channel_ids = ["111222333"]
        message_content_intent_enabled = true
        """
      )

      proof_dir = Path.join([tmp_dir, ".lemon", "proofs"])
      File.mkdir_p!(proof_dir)

      File.write!(
        Path.join(proof_dir, "discord-free-response-latest.json"),
        Jason.encode!(%{
          status: "completed",
          proof_object: "lemon.discord_free_response",
          proof_scope: "discord_free_response",
          completed_count: 1,
          failed_count: 0,
          details: %{
            channel_id: "111222333",
            prompt: "private readiness prompt",
            provider_response: "private readiness provider response"
          },
          cleanup: %{
            includes_raw_paths: false,
            includes_raw_channel_ids: false,
            includes_message_bodies: false,
            includes_raw_prompts: false,
            includes_raw_provider_responses: false
          }
        })
      )

      File.write!(
        Path.join(proof_dir, "media-image-smoke-latest.json"),
        Jason.encode!(%{
          status: "failed",
          proof_object: "lemon.media_provider_image",
          reason_kind: "vertex_imagen_http_error:permission_denied",
          details: %{provider: "vertex_imagen"},
          checks: [%{name: "media_provider_vertex_imagen", status: "failed"}]
        })
      )

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      assert {:ok, result} =
               ReadinessStatus.handle(%{"projectDir" => tmp_dir, "limit" => 10}, @ctx)

      assert result["status"] in ["blocked", "warning", "ready", "failed"]
      assert result["doctor"]["overall"] in ["pass", "warn", "fail"]
      assert result["channels"]["promotedPlatforms"] == ["telegram", "discord"]
      assert is_integer(result["channels"]["gateCount"])
      assert result["mediaProvider"]["status"] in ["pass", "warn", "fail", "unknown"]
      assert result["proofs"]["proofCount"] >= 1
      assert result["proofGates"]["providerMedia"]["status"] in ["passed", "warning"]
      assert result["proofGateSummary"]["gateCount"] == 5
      assert length(result["unresolvedGates"]) <= 10
      provider_media_gate = Enum.find(result["unresolvedGates"], &(&1["id"] == "provider_media"))
      assert provider_media_gate["reasonKinds"] == ["vertex_imagen_http_error:permission_denied"]
      assert result["cleanup"]["includesRawBotTokens"] == false
      assert result["cleanup"]["includesSecretNames"] == false
      assert result["cleanup"]["includesChatIds"] == false
      assert result["cleanup"]["includesChannelIds"] == false
      assert result["cleanup"]["includesMessageBodies"] == false
      assert result["cleanup"]["includesRawProofPaths"] == false
      assert result["cleanup"]["includesRawProofDetails"] == false
      assert result["cleanup"]["includesRawPrompts"] == false
      assert result["cleanup"]["includesRawProviderResponses"] == false
      assert result["cleanup"]["includesSecretValues"] == false
      assert result["summary"]["action"] == "readiness.status"
      assert result["summary"]["limit"] == 10
      assert result["summary"]["status"] == result["status"]
      assert result["summary"]["promotedPlatforms"] == ["telegram", "discord"]
      assert result["summary"]["proofGateStatus"] == result["proofGateSummary"]["status"]
      assert result["summary"]["proofGateCount"] == 5
      assert result["summary"]["proofGateStatuses"] == result["proofGateSummary"]["statuses"]
      assert is_integer(result["summary"]["unresolvedGateCount"])
      assert result["summary"]["unresolvedGateReasonKindCount"] >= 1

      assert "vertex_imagen_http_error:permission_denied" in result["summary"][
               "unresolvedGateReasonKinds"
             ]

      rendered = inspect(result)
      refute rendered =~ "private-token"
      refute rendered =~ "discord-private-token"
      refute rendered =~ "123456789"
      refute rendered =~ "111222333"
      refute rendered =~ "private readiness prompt"
      refute rendered =~ "private readiness provider response"
    end

    test "has correct method name and scopes" do
      assert ReadinessStatus.name() == "readiness.status"
      assert ReadinessStatus.scopes() == [:read]
    end
  end

  describe "TtsConvert" do
    test "requires text parameter" do
      {:error, error} = TtsConvert.handle(%{}, @ctx)
      assert error == {:invalid_request, "text is required"}
    end

    test "returns forbidden when TTS is not enabled" do
      LemonCore.Store.put(:tts_config, :global, %{enabled: false})

      {:error, error} = TtsConvert.handle(%{"text" => "Hello"}, @ctx)
      assert error == {:forbidden, "TTS is not enabled"}
    end

    test "returns not_implemented for cloud providers without API keys" do
      LemonCore.Store.put(:tts_config, :global, %{enabled: true, provider: "openai"})

      {:error, error} = TtsConvert.handle(%{"text" => "Hello"}, @ctx)

      assert error ==
               {:not_implemented,
                "Method not implemented: OpenAI TTS requires api key. Set openai_api_key in tts_config."}
    end

    test "returns not_implemented for elevenlabs without API key" do
      LemonCore.Store.put(:tts_config, :global, %{enabled: true, provider: "elevenlabs"})

      {:error, error} = TtsConvert.handle(%{"text" => "Hello"}, @ctx)

      assert error ==
               {:not_implemented,
                "Method not implemented: ElevenLabs TTS requires api key. Set elevenlabs_api_key in tts_config."}
    end

    test "returns error for unknown provider" do
      LemonCore.Store.put(:tts_config, :global, %{enabled: true, provider: "unknown"})

      {:error, error} = TtsConvert.handle(%{"text" => "Hello"}, @ctx)
      assert elem(error, 0) == :internal_error
    end

    # Skip system TTS test on CI or when say command not available
    @tag :system_tts
    test "converts text with system TTS on macOS" do
      # Only run on macOS
      case :os.type() do
        {:unix, :darwin} ->
          LemonCore.Store.put(:tts_config, :global, %{enabled: true, provider: "system"})

          {:ok, result} = TtsConvert.handle(%{"text" => "Test"}, @ctx)

          assert result["success"] == true
          assert result["provider"] == "system"
          assert result["format"] in ["audio/wav", "audio/aiff"]
          assert is_binary(result["data"])
          # Data should be base64 encoded
          assert {:ok, _} = Base.decode64(result["data"])
          assert result["summary"]["action"] == "tts.convert"
          assert result["summary"]["provider"] == "system"
          assert result["summary"]["format"] == result["format"]
          assert result["summary"]["textChars"] == 4
          assert result["summary"]["audioBytes"] > 0
          assert result["summary"]["audioDataReturned"] == true
          assert result["summary"]["cleanup"]["includesText"] == false
          assert result["summary"]["cleanup"]["includesAudioData"] == true
          assert result["summary"]["cleanup"]["includesSecretValues"] == false

        _ ->
          :skip
      end
    end

    test "has correct method name and scopes" do
      assert TtsConvert.name() == "tts.convert"
      assert TtsConvert.scopes() == [:write]
    end
  end

  describe "UpdateRun" do
    test "returns version info when update URL not configured" do
      {:ok, result} = UpdateRun.handle(%{}, @ctx)

      assert is_binary(result["currentVersion"])
      assert result["updateAvailable"] == false
      assert String.contains?(result["message"], "not configured")
      assert result["summary"]["action"] == "update.run"
      assert result["summary"]["configured"] == false
      assert result["summary"]["force"] == false
      assert result["summary"]["checkOnly"] == false
      assert result["summary"]["updateAvailable"] == false
      assert result["summary"]["messageReturned"] == true
      assert result["summary"]["cleanup"]["includesDownloadUrl"] == false
      assert result["summary"]["cleanup"]["includesChecksum"] == false
      assert result["summary"]["cleanup"]["includesDownloadedBytes"] == false
    end

    test "respects force parameter" do
      {:ok, result} = UpdateRun.handle(%{"force" => true}, @ctx)

      assert is_binary(result["currentVersion"])
      assert result["summary"]["force"] == true
      assert result["summary"]["checkOnly"] == false
    end

    test "respects checkOnly parameter" do
      {:ok, result} = UpdateRun.handle(%{"checkOnly" => true}, @ctx)

      assert is_binary(result["currentVersion"])
      assert result["summary"]["force"] == false
      assert result["summary"]["checkOnly"] == true
    end

    test "has correct method name and scopes" do
      assert UpdateRun.name() == "update.run"
      assert UpdateRun.scopes() == [:admin]
    end
  end

  describe "UsageCost" do
    test "returns cost breakdown with default date range" do
      {:ok, result} = UsageCost.handle(%{}, @ctx)

      assert is_binary(result["startDate"])
      assert is_binary(result["endDate"])
      assert is_number(result["totalCost"])
      assert is_map(result["breakdown"])
      assert is_integer(result["totalRequests"])
      assert is_map(result["totalTokens"])
      assert result["summary"]["providerCount"] == map_size(result["breakdown"])
      assert result["summary"]["totalRequests"] == result["totalRequests"]
      assert result["summary"]["totalTokenCount"] >= 0
      assert result["summary"]["cleanup"]["includesPrompts"] == false
      assert result["summary"]["cleanup"]["includesResponses"] == false
      assert result["summary"]["cleanup"]["includesMessageBodies"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "accepts date range parameters" do
      {:ok, result} =
        UsageCost.handle(
          %{
            "startDate" => "2024-01-01",
            "endDate" => "2024-01-31"
          },
          @ctx
        )

      assert result["startDate"] == "2024-01-01"
      assert result["endDate"] == "2024-01-31"
    end

    test "accepts snake_case parameters" do
      {:ok, result} =
        UsageCost.handle(
          %{
            "start_date" => "2024-01-01",
            "end_date" => "2024-01-31",
            "group_by" => "day"
          },
          @ctx
        )

      assert result["startDate"] == "2024-01-01"
    end

    test "has correct method name and scopes" do
      assert UsageCost.name() == "usage.cost"
      assert UsageCost.scopes() == [:read]
    end
  end

  describe "UsageCost.record_usage/1" do
    test "records usage and updates totals" do
      # Record some usage
      :ok =
        UsageCost.record_usage(%{
          provider: "claude",
          cost: 0.05,
          input_tokens: 500,
          output_tokens: 200
        })

      :ok =
        UsageCost.record_usage(%{
          provider: "openai",
          cost: 0.03,
          input_tokens: 300,
          output_tokens: 100
        })

      # Get the cost report
      {:ok, result} = UsageCost.handle(%{}, @ctx)

      assert result["totalCost"] >= 0.08
      assert result["totalRequests"] >= 2
      assert result["breakdown"]["claude"] >= 0.05
      assert result["breakdown"]["openai"] >= 0.03
    end

    test "records usage with string keys" do
      :ok =
        UsageCost.record_usage(%{
          "provider" => "claude",
          "cost" => 0.10,
          "input_tokens" => 1000,
          "output_tokens" => 500
        })

      # Verify it was recorded
      summary = LemonCore.Store.get(:usage_data, :current)
      assert summary != nil
      assert summary.total_cost >= 0.10
    end

    test "defaults to 'other' provider when not specified" do
      :ok = UsageCost.record_usage(%{cost: 0.01})

      summary = LemonCore.Store.get(:usage_data, :current)
      assert Map.get(summary.breakdown, "other", 0) >= 0.01
    end

    test "accumulates usage across multiple calls" do
      for _ <- 1..5 do
        :ok =
          UsageCost.record_usage(%{
            provider: "claude",
            cost: 0.01,
            input_tokens: 100,
            output_tokens: 50
          })
      end

      summary = LemonCore.Store.get(:usage_data, :current)
      assert summary.total_cost >= 0.05
      assert summary.total_requests >= 5
      assert summary.total_tokens.input >= 500
      assert summary.total_tokens.output >= 250
    end

    test "stores daily records" do
      :ok =
        UsageCost.record_usage(%{
          provider: "claude",
          cost: 0.05,
          input_tokens: 500,
          output_tokens: 200
        })

      # Get today's date key
      date_key = Date.utc_today() |> Date.to_iso8601()

      # Check daily record exists
      record = LemonCore.Store.get(:usage_records, date_key)
      assert record != nil
      assert record.total_cost >= 0.05
      assert record.breakdown["claude"] >= 0.05

      # Clean up
      on_exit(fn ->
        LemonCore.Store.delete(:usage_records, date_key)
      end)
    end
  end

  describe "UsageCost daily grouping" do
    test "returns daily breakdown when grouped by day" do
      # Get today's date
      today = Date.utc_today() |> Date.to_iso8601()

      # Create a usage record for today
      record = %{
        date: today,
        total_cost: 1.50,
        breakdown: %{"claude" => 1.00, "openai" => 0.50},
        requests: %{"claude" => 10, "openai" => 5},
        tokens: %{
          "claude" => %{input: 5000, output: 2000},
          "openai" => %{input: 3000, output: 1000}
        }
      }

      LemonCore.Store.put(:usage_records, today, record)

      on_exit(fn ->
        LemonCore.Store.delete(:usage_records, today)
      end)

      # Query with groupBy=day
      {:ok, result} = UsageCost.handle(%{"groupBy" => "day"}, @ctx)

      assert is_map(result["daily"])
      assert Map.has_key?(result["daily"], today)
      assert result["daily"][today]["cost"] == 1.50
      assert result["summary"]["dailyReturned"] == true
      assert result["summary"]["dailyCount"] >= 1
    end
  end

  defp fake_lsp_server_script do
    """
    #!/bin/sh
    IFS= read -r header || exit 1
    len=$(printf '%s' "$header" | tr -dc '0-9')
    IFS= read -r _blank || true
    request=$(dd bs=1 count="$len" 2>/dev/null)
    id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
    body='{"jsonrpc":"2.0","id":'"${id:-1}"',"result":{"capabilities":{"textDocumentSync":1}}}'
    printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#body}" "$body"
    sleep 30
    """
  end

  defp fake_diagnostic_lsp_server_script(raw_uri, raw_message) do
    diagnostics =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "textDocument/publishDiagnostics",
        "params" => %{
          "uri" => raw_uri,
          "version" => 7,
          "diagnostics" => [
            %{"severity" => 1, "message" => raw_message},
            %{"severity" => 2, "message" => "hidden detail"}
          ]
        }
      })

    """
    #!/bin/sh
    IFS= read -r header || exit 1
    len=$(printf '%s' "$header" | tr -dc '0-9')
    IFS= read -r _blank || true
    request=$(dd bs=1 count="$len" 2>/dev/null)
    id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
    body='{"jsonrpc":"2.0","id":'"${id:-1}"',"result":{"capabilities":{"textDocumentSync":1}}}'
    diagnostic='#{diagnostics}'
    printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#body}" "$body"
    printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#diagnostic}" "$diagnostic"
    sleep 30
    """
  end

  defp write_skill!(tmp_dir, key, skill_md) do
    skill_dir = Path.join([tmp_dir, ".lemon", "skill", key])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), skill_md)
  end

  defp fake_document_lsp_server_script(log_path) do
    """
    #!/bin/sh
    while true; do
      IFS= read -r header || exit 0
      len=$(printf '%s' "$header" | tr -dc '0-9')
      IFS= read -r _blank || true
      request=$(dd bs=1 count="$len" 2>/dev/null)
      printf '%s\\n' "$request" >> #{log_path}
      case "$request" in
        *'"method":"initialize"'*)
          id=$(printf '%s' "$request" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          body='{"jsonrpc":"2.0","id":'"${id:-1}"',"result":{"capabilities":{"textDocumentSync":2}}}'
          printf 'Content-Length: %s\\r\\n\\r\\n%s' "${#body}" "$body"
          ;;
      esac
    done
    """
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    case fun.() do
      nil ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)

      false ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)

      value ->
        value
    end
  end

  defp wait_until(fun, 0), do: fun.()
end
