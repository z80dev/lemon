defmodule LemonRouter.IngressProvenancePolicyTest do
  @moduledoc """
  The group approval floor follows authenticated provenance (`meta.channel_context`), not
  the submission origin. Webhook and A2A ingress submit as `:webhook` and
  `:control_plane`; their producers derive `webhook`/`a2a` provenance from the
  authenticated integration or peer (`LemonGateway.WebhookChannelProvenanceTest`,
  `LemonControlPlane.A2A.ChannelPolicyTest`), classified `:automation` (group
  approval floor) unless the operator marks it `trusted_automation` (`:dm`).
  The router refuses such a request without provenance rather than run it with
  no channel restrictions.
  """
  use ExUnit.Case, async: false

  alias LemonCore.{RunRequest, SessionKey, ToolPolicy}
  alias LemonRouter.SubmissionBuilder

  @floor_tools ~w(bash write edit patch hashline_edit)

  test "untrusted webhook and A2A provenance get the approval floor" do
    for request <- [
          webhook_request(webhook_context("deploys")),
          a2a_request(a2a_context())
        ] do
      assert {:ok, policy} = build_policy(request)

      for tool <- @floor_tools do
        assert policy.approvals[tool] == :always,
               "expected #{tool} to require approval, got #{inspect(policy)}"
      end
    end
  end

  test "trusted_automation provenance runs without the approval floor" do
    for request <- [
          webhook_request(webhook_context("deploys", :dm)),
          a2a_request(a2a_context(:dm))
        ] do
      assert {:ok, policy} = build_policy(request)
      assert ToolPolicy.allowed?(policy, "bash")
      for tool <- @floor_tools, do: assert(policy.approvals[tool] == nil)
    end
  end

  test "a webhook run without provenance is refused, not run unrestricted" do
    assert {:error, :missing_channel_provenance} = build_policy(webhook_request(nil))
  end

  test "webhook provenance cannot name another channel" do
    spoofed = %{webhook_context("deploys") | channel_id: "telegram"}

    assert {:error, :missing_channel_provenance} = build_policy(webhook_request(spoofed))
  end

  test "an A2A run keeps the peer allow-list" do
    assert {:ok, policy} = build_policy(a2a_request(a2a_context()))
    assert ToolPolicy.allowed?(policy, "read")
    refute ToolPolicy.allowed?(policy, "write")
  end

  test "an A2A run without a2a provenance is refused" do
    assert {:error, :missing_channel_provenance} = build_policy(a2a_request(nil))

    assert {:error, :missing_channel_provenance} =
             build_policy(a2a_request(%{a2a_context() | channel_id: "webhook"}))
  end

  test "channel provenance applies the group floor whatever the submission origin" do
    context = %{
      channel_id: "telegram",
      account_id: "default",
      peer_kind: :group,
      peer_id: "-100555",
      thread_id: nil
    }

    for origin <- [:control_plane, :node, :cron, :unknown] do
      request =
        RunRequest.new(%{
          origin: origin,
          run_id: LemonCore.Id.run_id(),
          session_key: SessionKey.main("default"),
          agent_id: "default",
          prompt: "edit the file",
          meta: %{channel_context: context}
        })

      assert {:ok, policy} = build_policy(request)

      for tool <- ~w(bash write edit patch hashline_edit) do
        assert ToolPolicy.approval_mode(policy, tool) == :always,
               "expected #{tool} to require approval for origin #{inspect(origin)}"
      end
    end
  end

  test "malformed channel provenance fails closed instead of dropping the channel layer" do
    request =
      RunRequest.new(%{
        origin: :control_plane,
        run_id: LemonCore.Id.run_id(),
        session_key: SessionKey.main("default"),
        agent_id: "default",
        prompt: "edit the file",
        meta: %{channel_context: "telegram"}
      })

    assert {:error, :invalid_channel_context} = build_policy(request)
  end

  defp webhook_context(integration_id, peer_kind \\ :automation) do
    %{
      channel_id: "webhook",
      account_id: integration_id,
      peer_kind: peer_kind,
      peer_id: integration_id,
      thread_id: nil
    }
  end

  defp webhook_request(context) do
    meta = %{webhook: %{integration_id: "deploys"}}

    RunRequest.new(%{
      origin: :webhook,
      run_id: LemonCore.Id.run_id(),
      session_key: SessionKey.main("default"),
      agent_id: "default",
      prompt: "deploy",
      meta: if(context, do: Map.put(meta, :channel_context, context), else: meta)
    })
  end

  defp a2a_context(peer_kind \\ :automation) do
    %{
      channel_id: "a2a",
      account_id: "lemon",
      peer_kind: peer_kind,
      peer_id: "peer",
      thread_id: "ctx"
    }
  end

  defp a2a_request(context) do
    meta = %{a2a: true, a2a_peer_id: "hermes", a2a_context_id: "ctx"}

    RunRequest.new(%{
      origin: :control_plane,
      run_id: LemonCore.Id.run_id(),
      session_key:
        SessionKey.channel_peer(%{
          agent_id: "default",
          channel_id: "a2a",
          account_id: "lemon",
          peer_kind: :dm,
          peer_id: "peer",
          thread_id: "ctx"
        }),
      agent_id: "default",
      prompt: "hello",
      tool_policy: %{allow: ["read", "bash"]},
      meta: if(context, do: Map.put(meta, :channel_context, context), else: meta)
    })
  end

  defp build_policy(request) do
    case SubmissionBuilder.build(request, %{
           run_supervisor: LemonRouter.RunSupervisor,
           run_process_module: LemonRouter.RunProcess,
           run_process_opts: %{notify_pid: self()}
         }) do
      {:ok, submission} -> {:ok, submission.execution_request.tool_policy}
      {:error, _reason} = error -> error
    end
  end
end
