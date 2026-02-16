defmodule CodingAgent.Security.ExternalContentTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Security.ExternalContent

  test "trust_metadata emits snake_case metadata by default" do
    metadata =
      ExternalContent.trust_metadata(:web_search,
        warning_included: false,
        wrapped_fields: ["results[].title", :description, nil, ""]
      )

    assert metadata["untrusted"] == true
    assert metadata["source"] == "web_search"
    assert metadata["source_label"] == "Web Search"
    assert metadata["wrapping_applied"] == true
    assert metadata["warning_included"] == false
    assert metadata["wrapped_fields"] == ["results[].title", "description"]
  end

  test "trust_metadata supports camelCase output" do
    metadata =
      ExternalContent.trust_metadata(:web_fetch,
        key_style: :camel_case,
        warning_included: true,
        wrapped_fields: ["text", "title"]
      )

    assert metadata["untrusted"] == true
    assert metadata["source"] == "web_fetch"
    assert metadata["sourceLabel"] == "Web Fetch"
    assert metadata["wrappingApplied"] == true
    assert metadata["warningIncluded"] == true
    assert metadata["wrappedFields"] == ["text", "title"]
    refute Map.has_key?(metadata, "source_label")
    refute Map.has_key?(metadata, "wrapped_fields")
  end

  test "web_trust_metadata applies web defaults and wrapped field normalization" do
    metadata =
      ExternalContent.web_trust_metadata(:web_search, ["content", :title, nil, ""])

    assert metadata["untrusted"] == true
    assert metadata["source"] == "web_search"
    assert metadata["source_label"] == "Web Search"
    assert metadata["wrapping_applied"] == true
    assert metadata["warning_included"] == false
    assert metadata["wrapped_fields"] == ["content", "title"]
  end

  test "untrusted_json_result encodes payload and marks trust as untrusted" do
    payload = %{"ok" => true, "nested" => %{"value" => 1}}
    result = ExternalContent.untrusted_json_result(payload)

    assert result.trust == :untrusted
    assert result.details == payload

    [content] = result.content
    assert Jason.decode!(content.text) == payload
  end
end
