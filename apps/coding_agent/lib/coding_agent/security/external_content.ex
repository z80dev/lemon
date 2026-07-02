defmodule CodingAgent.Security.ExternalContent do
  defdelegate wrap_external_content(content, opts \\ []), to: AgentCore.Security.ExternalContent

  defdelegate wrap_web_content(content, source \\ :web_search),
    to: AgentCore.Security.ExternalContent

  defdelegate trust_metadata(source \\ :unknown, opts \\ []),
    to: AgentCore.Security.ExternalContent

  defdelegate web_trust_metadata(source, wrapped_fields, opts \\ []),
    to: AgentCore.Security.ExternalContent

  defdelegate untrusted_json_result(payload), to: AgentCore.Security.ExternalContent
end
