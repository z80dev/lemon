defmodule CodingAgent.PythonRepl.OutputTest do
  use ExUnit.Case, async: true

  alias CodingAgent.PythonRepl.Output

  describe "new/1" do
    test "creates an empty bounded capture" do
      output = Output.new(50_000)
      assert %Output{} = output
      assert output.max_bytes == 50_000
      assert output.truncated == false
    end

    test "rejects non-positive bounds" do
      assert_raise ArgumentError, ~r/positive integer/, fn -> Output.new(0) end
      assert_raise ArgumentError, ~r/positive integer/, fn -> Output.new(-1) end
      assert_raise ArgumentError, ~r/positive integer/, fn -> Output.new("50") end
    end
  end

  describe "append/3" do
    test "raises on invalid stream or bytes" do
      output = Output.new(100)

      assert_raise ArgumentError, ~r/:stdout or :stderr/, fn ->
        Output.append(output, :stdin, "x")
      end

      assert_raise ArgumentError, ~r/binary/, fn -> Output.append(output, :stdout, :not_bytes) end
    end

    test "empty chunks are a no-op" do
      output = Output.new(10) |> Output.append(:stdout, "")
      assert output.total_bytes == 0
      assert Output.finish(output).output == ""
    end
  end

  describe "finish/1 without truncation" do
    test "returns verbatim combined output and totals, with no spill" do
      result =
        Output.new(100)
        |> Output.append(:stdout, "one\n")
        |> Output.append(:stderr, "two\n")
        |> Output.append(:stdout, "three\n")
        |> Output.finish()

      assert %Output.Result{} = result
      assert result.output == "one\ntwo\nthree\n"
      assert result.truncated == false
      assert result.dropped_bytes == 0
      assert result.full_output_path == nil
      assert result.total_bytes == 14
      assert result.stdout_bytes == 10
      assert result.stderr_bytes == 4
    end

    test "preserves stdout/stderr arrival order across interleaved chunks" do
      result =
        Output.new(1000)
        |> Output.append(:stderr, "err-1\n")
        |> Output.append(:stdout, "out-1\n")
        |> Output.append(:stderr, "err-2\n")
        |> Output.append(:stdout, "out-2\n")
        |> Output.finish()

      assert result.output == "err-1\nout-1\nerr-2\nout-2\n"
      assert result.stdout_bytes == 12
      assert result.stderr_bytes == 12
    end

    test "sanitizes like BashExecutor output" do
      result =
        Output.new(1000)
        |> Output.append(:stdout, "\e[31mred\e[0m\n")
        |> Output.append(:stderr, "win\r\ndos\r")
        |> Output.append(:stdout, "a\x01b")
        |> Output.append(:stderr, "abc" <> <<0xFF>> <> "def")
        |> Output.finish()

      assert result.output == "red\nwin\ndosab" <> "abc"
    end

    test "counts sanitized bytes in totals" do
      result =
        Output.new(1000)
        |> Output.append(:stdout, "a\r\n")
        |> Output.finish()

      assert result.output == "a\n"
      assert result.total_bytes == 2
      assert result.stdout_bytes == 2
    end

    test "an empty capture finishes empty" do
      result = Output.new(10) |> Output.finish()

      assert result.output == ""
      assert result.truncated == false
      assert result.total_bytes == 0
      assert result.full_output_path == nil
    end
  end

  describe "chunk boundary sanitization" do
    test "ANSI escapes sanitize identically at every split point" do
      raw = "before\e[31mred\e[0mafter"

      expected =
        Output.new(1000)
        |> Output.append(:stdout, raw)
        |> Output.finish()
        |> Map.take([:output, :total_bytes, :stdout_bytes, :stderr_bytes])

      for split <- 1..(byte_size(raw) - 1) do
        left = binary_part(raw, 0, split)
        right = binary_part(raw, split, byte_size(raw) - split)

        actual =
          Output.new(1000)
          |> Output.append(:stdout, left)
          |> Output.append(:stdout, right)
          |> Output.finish()
          |> Map.take([:output, :total_bytes, :stdout_bytes, :stderr_bytes])

        assert actual == expected
      end
    end

    test "UTF-8 codepoints sanitize identically at every split point" do
      raw = "A€文🙂Z"

      expected =
        Output.new(1000)
        |> Output.append(:stdout, raw)
        |> Output.finish()
        |> Map.take([:output, :total_bytes, :stdout_bytes, :stderr_bytes])

      for split <- 1..(byte_size(raw) - 1) do
        left = binary_part(raw, 0, split)
        right = binary_part(raw, split, byte_size(raw) - split)

        actual =
          Output.new(1000)
          |> Output.append(:stdout, left)
          |> Output.append(:stdout, right)
          |> Output.finish()
          |> Map.take([:output, :total_bytes, :stdout_bytes, :stderr_bytes])

        assert actual == expected
      end

      bytewise =
        for <<byte <- raw>>, reduce: Output.new(1000) do
          output -> Output.append(output, :stdout, <<byte>>)
        end

      bytewise_result =
        bytewise
        |> Output.finish()
        |> Map.take([:output, :total_bytes, :stdout_bytes, :stderr_bytes])

      assert bytewise_result == expected
    end

    test "preserves arrival order and per-stream totals around a pending escape" do
      result =
        Output.new(1000)
        |> Output.append(:stdout, "out:\e[")
        |> Output.append(:stdout, "32mgreen\e[0m")
        |> Output.append(:stderr, ":err")
        |> Output.finish()

      assert result.output == "out:green:err"
      assert result.stdout_bytes == 9
      assert result.stderr_bytes == 4
      assert result.total_bytes == 13
    end

    test "split boundaries preserve truncation, totals, and the full-output spill" do
      suffix = String.duplicate("x", 30)
      expected_full = "HEADé-" <> suffix

      unsplit =
        Output.new(20)
        |> Output.append(:stdout, "HEAD\e[31mé\e[0m-")
        |> Output.append(:stderr, suffix)
        |> Output.finish()

      <<first, second>> = "é"

      chunked =
        Output.new(20)
        |> Output.append(:stdout, "HEAD\e[")
        |> Output.append(:stdout, "31m" <> <<first>>)
        |> Output.append(:stdout, <<second>> <> "\e[0")
        |> Output.append(:stdout, "m-")
        |> Output.append(:stderr, suffix)
        |> Output.finish()

      on_exit(fn ->
        File.rm(unsplit.full_output_path)
        File.rm(chunked.full_output_path)
      end)

      assert Map.delete(Map.from_struct(chunked), :full_output_path) ==
               Map.delete(Map.from_struct(unsplit), :full_output_path)

      assert chunked.truncated
      assert chunked.total_bytes == 37
      assert chunked.stdout_bytes == 7
      assert chunked.stderr_bytes == 30
      assert File.read!(unsplit.full_output_path) == expected_full
      assert File.read!(chunked.full_output_path) == expected_full
    end
  end

  describe "truncation boundaries" do
    test "output exactly at max_bytes is kept verbatim" do
      content = String.duplicate("x", 100)

      result =
        Output.new(100)
        |> Output.append(:stdout, content)
        |> Output.finish()

      assert result.truncated == false
      assert result.output == content
      assert result.full_output_path == nil
    end

    test "output one byte over max_bytes truncates" do
      content = String.duplicate("x", 101)

      result =
        Output.new(100)
        |> Output.append(:stdout, content)
        |> Output.finish()

      assert result.truncated == true
      assert result.dropped_bytes == 1
      assert result.full_output_path != nil
    end
  end

  describe "40% head / 60% rolling tail retention" do
    test "keeps the deterministic head/tail split with a dropped-byte marker" do
      content = Enum.map_join(0..499, &Integer.to_string(rem(&1, 10)))

      result =
        Output.new(100)
        |> Output.append(:stdout, content)
        |> Output.finish()

      head = binary_part(content, 0, 40)
      tail = binary_part(content, byte_size(content) - 60, 60)

      assert result.output == head <> "\n... [400 bytes truncated] ...\n" <> tail
      assert result.truncated == true
      assert result.dropped_bytes == 400
      assert result.total_bytes == 500
    end

    test "rolls the tail across many streaming chunks" do
      content =
        0..99
        |> Enum.map(fn i -> String.pad_leading(Integer.to_string(i), 10, "0") end)
        |> Enum.join()

      output =
        for <<chunk::binary-10 <- content>>, reduce: Output.new(100) do
          acc -> Output.append(acc, :stdout, chunk)
        end

      result = Output.finish(output)

      head = binary_part(content, 0, 40)
      tail = binary_part(content, byte_size(content) - 60, 60)

      assert result.output == head <> "\n... [900 bytes truncated] ...\n" <> tail
      assert result.total_bytes == 1000
      assert result.dropped_bytes == 900
    end

    test "retained text stays valid UTF-8 when cuts split multi-byte characters" do
      content = String.duplicate("é", 40)

      result =
        Output.new(10)
        |> Output.append(:stdout, content)
        |> Output.finish()

      assert result.truncated == true
      assert String.valid?(result.output)
      assert result.output =~ "bytes truncated"
    end

    test "truncation is deterministic across identical runs" do
      content = String.duplicate("ab", 500)

      run = fn ->
        Output.new(100)
        |> Output.append(:stdout, content)
        |> Output.finish()
        |> Map.take([:output, :truncated, :total_bytes, :dropped_bytes])
      end

      assert run.() == run.()
    end
  end

  describe "full-output spill" do
    test "spills the full output at 0600 only when truncated" do
      content = String.duplicate("z", 300)

      result =
        Output.new(100)
        |> Output.append(:stdout, content)
        |> Output.finish()

      path = result.full_output_path
      assert is_binary(path)
      on_exit(fn -> File.rm(path) end)

      assert Path.dirname(path) == System.tmp_dir!()
      assert File.read!(path) == content

      stat = File.stat!(path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600

      untruncated =
        Output.new(1000)
        |> Output.append(:stdout, content)
        |> Output.finish()

      assert untruncated.truncated == false
      assert untruncated.full_output_path == nil
    end

    test "spill receives sanitized bytes appended after truncation began" do
      output =
        Output.new(50)
        |> Output.append(:stdout, String.duplicate("a", 60))

      output = Output.append(output, :stdout, "\e[31mCOLOR\e[0m tail")
      result = Output.finish(output)

      path = result.full_output_path
      assert is_binary(path)
      on_exit(fn -> File.rm(path) end)

      assert File.read!(path) == String.duplicate("a", 60) <> "COLOR tail"
      assert result.output =~ "COLOR tail"
    end
  end
end
