defmodule LemonCore.PersistentTermHygieneTest do
  use ExUnit.Case, async: true

  # Only immutable snapshots published at boot or explicit configuration
  # registration/reload belong here. Never allow request caches, warning flags,
  # expiring credentials or lifecycle state by adding them to this list.
  @allowed %{
    "apps/coding_agent/lib/coding_agent/search/registry.ex" => [
      :init,
      :reset,
      :register,
      :unregister
    ],
    "apps/lemon_ai/lib/lemon_ai/provider_registry.ex" => [:init, :mutate_providers],
    "apps/lemon_agent/lib/lemon_agent/context_registry.ex" => [:put],
    "apps/lemon_agent/lib/lemon_agent/security/external_content.ex" => [:init_key],
    "apps/lemon_agent/lib/lemon_agent/security/untrusted_tool_boundary.ex" => [:init_key],
    "apps/lemon_agent/lib/lemon_agent/tool_registry.ex" => [:put],
    "apps/lemon_browser/lib/lemon_browser/registry.ex" => [:put_runtime],
    "apps/lemon_channels/lib/lemon_channels/registry.ex" => [:init, :publish_plugins],
    "apps/lemon_channels/lib/lemon_channels/inbound_http/routes.ex" => [:init, :handle_call],
    "apps/lemon_gateway/lib/lemon_gateway/transport_registry.ex" => [:init],
    "apps/lemon_core/lib/lemon_core/config_cache.ex" => [:init],
    "apps/lemon_core/lib/lemon_core/browser_provider.ex" => [:put_computer_use_enabled],
    "apps/lemon_core/lib/lemon_core/bus.ex" => [:child_spec_for_backend],
    "apps/lemon_core/lib/lemon_core/exec_approval_expiry.ex" => [:init_runtime_id],
    # Session lifecycle participants register once at each owning app's start.
    "apps/lemon_core/lib/lemon_core/session_lifecycle/participant.ex" => [:update_registry],
    # Rare one-shot fail-stop write: at most once per VM, never cleared, so the
    # trip survives a restart of the latch's own process.
    "apps/lemon_core/lib/lemon_core/runtime_latch.ex" => [:record_trip],
    # This OS process's identity and uid, published once at application boot.
    "apps/lemon_core/lib/lemon_core/service/identity.ex" => [:boot_check],
    "apps/lemon_skills/lib/lemon_skills/curator_references.ex" => [:register],
    "apps/lemon_skills/lib/lemon_skills/skill_root.ex" => [:init_uid]
  }

  test "persistent_term writes are confined to boot and configuration publication" do
    root = Path.expand("../../../..", __DIR__)

    violations =
      root
      |> Path.join("apps/*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        path = Path.relative_to(file, root)
        ast = file |> File.read!() |> Code.string_to_quoted!()
        allowed = Map.get(@allowed, path, [])

        {_ast, {_stack, violations}} =
          Macro.traverse(
            ast,
            {[], []},
            fn
              {kind, _, [head, _body]} = node, {stack, errors}
              when kind in [:def, :defp, :defmacro, :defmacrop] ->
                {node, {[function_name(head) | stack], errors}}

              {{:., _, [:persistent_term, :put]}, meta, _args} = node, {stack, errors} ->
                function = List.first(stack)

                if function in allowed do
                  {node, {stack, errors}}
                else
                  {node, {stack, [{path, meta[:line], function} | errors]}}
                end

              node, acc ->
                {node, acc}
            end,
            fn
              {kind, _, [_head, _body]} = node, {[_ | stack], errors}
              when kind in [:def, :defp, :defmacro, :defmacrop] ->
                {node, {stack, errors}}

              node, acc ->
                {node, acc}
            end
          )

        violations
      end)

    assert violations == [],
           "Runtime persistent_term writes require supervised ETS instead: #{inspect(violations)}"
  end

  defp function_name({:when, _, [head | _guards]}), do: function_name(head)
  defp function_name({name, _, _args}), do: name
end
