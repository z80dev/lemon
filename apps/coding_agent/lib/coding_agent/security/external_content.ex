defmodule CodingAgent.Security.ExternalContent do
  @moduledoc """
  Coding-agent external content compatibility wrapper.

  The implementation lives in `LemonAgent.Security.ExternalContent`. This module
  preserves the existing import surface; new code should use the LemonAgent
  module directly.
  """

  defdelegate wrap_external_content(content, opts \\ []), to: LemonAgent.Security.ExternalContent

  defdelegate wrap_web_content(content, source \\ :web_search),
    to: LemonAgent.Security.ExternalContent

  defdelegate trust_metadata(source \\ :unknown, opts \\ []),
    to: LemonAgent.Security.ExternalContent

  defdelegate web_trust_metadata(source, wrapped_fields, opts \\ []),
    to: LemonAgent.Security.ExternalContent

  defdelegate untrusted_json_result(payload), to: LemonAgent.Security.ExternalContent
end
