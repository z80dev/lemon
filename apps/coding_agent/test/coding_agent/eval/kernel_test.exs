defmodule CodingAgent.Eval.KernelTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Eval.{Kernel, Output}

  @marker "\x1eLEMONEVAL:tok:"

  describe "split_frames/2" do
    test "separates frames from raw output, including frames after a partial line" do
      data = "hello\npartial" <> @marker <> ~s({"type":"result","id":1}\n) <> "tail\n"

      assert {[%{"type" => "result", "id" => 1}], raw, ""} = Kernel.split_frames(data, @marker)
      assert IO.iodata_to_binary(raw) == "hello\npartialtail\n"
    end

    test "keeps incomplete frames and possible marker prefixes for the next chunk" do
      assert {[], raw, rest} = Kernel.split_frames("out\x1eLEMON", @marker)
      assert IO.iodata_to_binary(raw) == "out"

      assert {[], raw, rest} = Kernel.split_frames(rest <> "EVAL:tok:{\"id\":", @marker)
      assert IO.iodata_to_binary(raw) == ""
      assert {[%{"id" => 2}], _raw, ""} = Kernel.split_frames(rest <> "2}\n", @marker)
    end

    test "a malformed framed line degrades to raw output" do
      assert {[], raw, ""} = Kernel.split_frames(@marker <> "not json\n", @marker)
      assert IO.iodata_to_binary(raw) == "not json\n"
    end
  end

  test "Output decodes UTF-8 split across chunks and strips ANSI sequences" do
    <<first::binary-size(1), second::binary>> = "é"
    {acc, ""} = Output.append(Output.new(), first)
    {acc, "é"} = Output.append(acc, second)
    {acc, "red"} = Output.append(acc, "\e[31mred\e[0m")
    assert Output.finalize(acc) == %{output: "éred", truncated: false, full_output_path: nil}
    acc = Output.append_block(Output.new(), "\e[31mframed error\e[0m")
    assert Output.finalize(acc).output == "framed error"
  end

  @tag :tmp_dir
  test "rich output side channel rejects oversized, invalid and excessive records", %{
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "display.jsonl")
    File.write!(path, Jason.encode!(%{mime: "text/markdown", data: "**ok**"}) <> "\n")
    assert {:ok, [%LemonAi.Types.TextContent{text: "**ok**"}]} = Output.read_displays(path)
    File.write!(path, String.duplicate("x", 4 * 1024 * 1024 + 1))
    assert {:error, _} = Output.read_displays(path)
    File.write!(path, String.duplicate(~s({"mime":"text/markdown","data":"x"}\n), 33))
    assert {:error, _} = Output.read_displays(path)
    File.write!(path, ~s({"mime":"image/png","data":"invalid base64"}\n))
    assert {:error, _} = Output.read_displays(path)
    File.write!(path, ~s({"mime":"image/png","data":"eA=="}\n))
    assert {:error, _} = Output.read_displays(path)
  end
end
