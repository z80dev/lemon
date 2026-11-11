defmodule LemonWeb.ManagementTextTest do
  use ExUnit.Case, async: true

  alias LemonWeb.ManagementText

  test "long near-path tokens cannot crash redaction or disclose trailing secrets" do
    assert ManagementText.text(String.duplicate("a", 1_000_000), max_bytes: 96) == "[REDACTED]"
    path = String.duplicate("a", 60_000) <> "/private-secret"
    assert ManagementText.text(path, max_bytes: 96) == "[PATH HIDDEN]"

    refute ManagementText.text(String.duplicate("a", 60_000) <> " token=hidden", max_bytes: 96) =~
             "hidden"
  end

  test "operator labels omit credentials and absolute, relative, and Windows paths before bounds" do
    text =
      "Review api_key=super-secret /private/repo src/main.ex C:\\Users\\operator\\repo https://private.example/config"

    projected = ManagementText.text(text, max_bytes: 200)

    assert projected =~ "Review"
    refute projected =~ "super-secret"
    refute projected =~ "private"
    refute projected =~ "main.ex"
    refute projected =~ "operator"
    assert String.valid?(projected)
    assert byte_size(projected) <= 203

    refute ManagementText.text("api_key=super-secret", max_bytes: 8) =~ "super"
    assert String.valid?(ManagementText.text(String.duplicate("é", 20), max_bytes: 7))
  end

  test "nested history retains status but masks sensitive keys and paths" do
    projected =
      ManagementText.term(%{
        ok: true,
        prompt: "Read /private/repo and src/main.ex",
        detail: %{"token" => "not-public", "cwd" => "/private/repo"},
        tools: [%{title: "Read source", status: :completed}]
      })

    assert projected.ok
    assert projected.tools == [%{title: "Read source", status: :completed}]
    refute inspect(projected) =~ "/private/repo"
    refute inspect(projected) =~ "src/main.ex"
    refute inspect(projected) =~ "not-public"
    assert ManagementText.term(Enum.to_list(1..300)) == Enum.to_list(1..200)
    assert ManagementText.text(nil) == nil
    assert ManagementText.text(<<255>>) == "[Invalid text]"
  end
end
