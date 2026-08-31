defmodule LemonCore.Context.DocumentTest do
  use ExUnit.Case, async: true

  alias LemonCore.Context.Document

  test "sniffs and extracts DOCX text independent of extension" do
    binary =
      zip!([
        {"word/document.xml", "<w:document><w:p><w:t>Hello &amp; bye</w:t></w:p></w:document>"}
      ])

    assert {:ok, result} = Document.extract_binary(binary)
    assert result.format == :docx
    assert result.text =~ "Hello & bye"
  end

  test "extracts shared-string and numeric XLSX cells" do
    binary =
      zip!([
        {"xl/sharedStrings.xml", "<sst><si><t>Name</t></si></sst>"},
        {"xl/worksheets/sheet1.xml",
         "<worksheet><row><c t=\"s\"><v>0</v></c><c><v>42</v></c></row></worksheet>"}
      ])

    assert {:ok, %{format: :xlsx, text: text}} = Document.extract_binary(binary)
    assert text =~ "Name\t42"
  end

  test "extracts PPTX slides and enforces the page limit" do
    binary =
      zip!([
        {"ppt/slides/slide1.xml", "<p:sld><a:p><a:t>One</a:t></a:p></p:sld>"},
        {"ppt/slides/slide2.xml", "<p:sld><a:p><a:t>Two</a:t></a:p></p:sld>"}
      ])

    assert {:ok, %{format: :pptx, text: text}} = Document.extract_binary(binary, max_pages: 1)
    assert text =~ "One"
    refute text =~ "Two"
  end

  test "extracts notebook source while excluding outputs and bounding cells" do
    binary =
      Jason.encode!(%{
        "nbformat" => 4,
        "cells" => [
          %{
            "cell_type" => "markdown",
            "source" => ["# Title"],
            "outputs" => [%{"text" => "secret output"}]
          },
          %{"cell_type" => "code", "source" => ["print(1)"]}
        ]
      })

    assert {:ok, %{format: :ipynb, text: text, omitted: omissions}} =
             Document.extract_binary(binary, max_items: 1)

    assert text =~ "# Title"
    refute text =~ "secret output"
    assert Enum.any?(omissions, &(&1.reason == "item_limit"))
  end

  test "extracts literal PDF text and rejects excessive pages" do
    pdf = "%PDF-1.4\n1 0 obj <</Type /Page>> stream BT (Hello\\nPDF) Tj ET endstream\n%%EOF"

    assert {:ok, %{format: :pdf, text: "Hello\nPDF"}} = Document.extract_binary(pdf)

    two_pages = pdf <> "\n2 0 obj <</Type /Page>> endobj"
    assert {:error, {:page_limit, 2, 1}} = Document.extract_binary(two_pages, max_pages: 1)
  end

  test "rejects traversal members before archive extraction" do
    binary =
      zip!([
        {"word/document.xml", "<w:t>safe</w:t>"},
        {"../outside.txt", "escape"}
      ])

    assert {:error, :archive_path_traversal} = Document.extract_binary(binary)
  end

  test "rejects archive expansion ratios before extraction" do
    binary = zip!([{"word/document.xml", "<w:t>#{String.duplicate("A", 50_000)}</w:t>"}])
    assert {:error, :archive_ratio_limit} = Document.extract_binary(binary, max_archive_ratio: 2)
  end

  test "enforces input and selected-output byte budgets" do
    assert {:error, {:input_too_large, 10, 5}} =
             Document.extract_binary("0123456789", max_input_bytes: 5)

    assert {:ok, %{text: "abc", omitted: [%{reason: "output_budget"}]}} =
             Document.extract_binary("abcdef", max_output_bytes: 3)
  end

  defp zip!(entries) do
    entries = Enum.map(entries, fn {name, body} -> {String.to_charlist(name), body} end)
    {:ok, {_name, binary}} = :zip.create(~c"fixture.zip", entries, [:memory])
    binary
  end
end
