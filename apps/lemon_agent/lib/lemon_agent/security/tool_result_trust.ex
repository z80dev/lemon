defmodule LemonAgent.Security.ToolResultTrust do
  @moduledoc """
  Central trust policy for data-bearing tool results.

  Tool output is trusted only when the platform authored its semantics. Local
  files, search matches, shell output, network/API data, and community/project
  skills are untrusted data even though Lemon intentionally invoked the tool.
  Marking the result here lets the pre-LLM boundary fence it without changing
  persisted or operator-facing output.
  """

  alias LemonAgent.Security.ExternalContent
  alias LemonAgent.Types.AgentToolResult

  @type source :: ExternalContent.source()

  @doc "Mark a successful data-bearing result as untrusted with source metadata."
  @spec untrusted(term(), source()) :: term()
  def untrusted(%AgentToolResult{} = result, source) do
    metadata =
      ExternalContent.trust_metadata(source,
        wrapped_fields: [],
        wrapping_applied: false
      )

    %{
      result
      | trust: :untrusted,
        details: put_trust_metadata(result.details, metadata)
    }
  end

  def untrusted({:ok, %AgentToolResult{} = result}, source), do: {:ok, untrusted(result, source)}
  def untrusted(other, _source), do: other

  @doc "Apply the skill-content policy, keeping only bundled builtins trusted."
  @spec skill(term(), map()) :: term()
  def skill(%AgentToolResult{} = result, entry) when is_map(entry) do
    if builtin_skill?(entry) do
      metadata = %{policy: "audited_builtin", source: "skill", untrusted: false}
      %{result | trust: :trusted, details: put_trust_metadata(result.details, metadata)}
    else
      untrusted(result, :skill)
    end
  end

  def skill(other, _entry), do: other

  defp builtin_skill?(entry) do
    Map.get(entry, :source_kind) == :builtin and Map.get(entry, :trust_level) == :builtin and
      Map.get(entry, :audit_status) not in [:warn, :block]
  end

  defp put_trust_metadata(nil, metadata), do: %{trust_boundary: metadata}

  defp put_trust_metadata(details, metadata) when is_map(details),
    do: Map.put(details, :trust_boundary, metadata)

  defp put_trust_metadata(details, metadata),
    do: %{value: details, trust_boundary: metadata}
end
