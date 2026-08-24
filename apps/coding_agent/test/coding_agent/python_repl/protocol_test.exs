defmodule CodingAgent.PythonRepl.ProtocolTest do
  use ExUnit.Case, async: true

  alias CodingAgent.PythonRepl.Key
  alias CodingAgent.PythonRepl.Protocol

  @prefix "\x1Elemon-python\t"

  defp frame(doc), do: @prefix <> Jason.encode!(doc) <> "\n"

  defp proto, do: Protocol.new() |> elem(1)

  defp realpath(path) do
    {out, 0} = System.cmd("realpath", [path])
    String.trim_trailing(out)
  end

  defp started_frames(id), do: frame(%{"v" => 1, "type" => "started", "id" => id})

  describe "new/0" do
    test "creates an empty parser" do
      assert {:ok, %Protocol{}, []} = Protocol.new()
    end
  end

  describe "feed/2 decoding" do
    test "decodes ready with pid" do
      assert {:ok, _proto, [%{type: :ready, pid: 4242}]} =
               proto() |> Protocol.feed(frame(%{"v" => 1, "type" => "ready", "pid" => 4242}))
    end

    test "decodes ready without pid" do
      assert {:ok, _proto, [%{type: :ready, pid: nil}]} =
               proto() |> Protocol.feed(frame(%{"v" => 1, "type" => "ready"}))
    end

    test "decodes started" do
      assert {:ok, _proto, [%{type: :started, id: "cell-1"}]} =
               proto() |> Protocol.feed(frame(%{"v" => 1, "type" => "started", "id" => "cell-1"}))
    end

    test "decodes stdout stream frames with base64 data" do
      doc = %{
        "v" => 1,
        "type" => "stream",
        "id" => "c",
        "stream" => "stdout",
        "data" => Base.encode64("hello")
      }

      assert {:ok, _proto,
              [%{type: :started}, %{type: :stream, id: "c", stream: :stdout, data: "hello"}]} =
               proto() |> Protocol.feed(started_frames("c") <> frame(doc))
    end

    test "decodes stderr stream frames" do
      doc = %{
        "v" => 1,
        "type" => "stream",
        "id" => "c",
        "stream" => "stderr",
        "data" => Base.encode64("bad")
      }

      assert {:ok, _proto,
              [%{type: :started}, %{type: :stream, id: "c", stream: :stderr, data: "bad"}]} =
               proto() |> Protocol.feed(started_frames("c") <> frame(doc))
    end

    test "decodes exception frames with required name, kind, message and traceback" do
      doc = %{
        "v" => 1,
        "type" => "exception",
        "id" => "c",
        "kind" => "interrupted",
        "name" => "ValueError",
        "message" => "boom",
        "traceback" => "Traceback ..."
      }

      assert {:ok, _proto,
              [
                %{type: :started},
                %{
                  type: :exception,
                  id: "c",
                  kind: :interrupted,
                  name: "ValueError",
                  message: "boom",
                  traceback: "Traceback ..."
                }
              ]} = proto() |> Protocol.feed(started_frames("c") <> frame(doc))
    end

    test "exception frames tolerate absent message and traceback" do
      doc = %{
        "v" => 1,
        "type" => "exception",
        "id" => "c",
        "kind" => "error",
        "name" => "NameError"
      }

      assert {:ok, _proto,
              [
                %{type: :started},
                %{type: :exception, kind: :error, name: "NameError", message: nil, traceback: nil}
              ]} =
               proto() |> Protocol.feed(started_frames("c") <> frame(doc))
    end

    test "decodes done, fatal and bye" do
      assert {:ok, _proto, [%{type: :started}, %{type: :done, id: "c"}]} =
               proto()
               |> Protocol.feed(
                 started_frames("c") <> frame(%{"v" => 1, "type" => "done", "id" => "c"})
               )

      assert {:ok, _proto, [%{type: :fatal, reason: "boom"}]} =
               proto() |> Protocol.feed(frame(%{"v" => 1, "type" => "fatal", "reason" => "boom"}))

      assert {:ok, _proto, [%{type: :bye}]} =
               proto() |> Protocol.feed(frame(%{"v" => 1, "type" => "bye"}))
    end
  end

  describe "feed/2 chunk boundaries" do
    test "decodes several coalesced frames in one chunk, preserving order" do
      input =
        frame(%{"v" => 1, "type" => "ready", "pid" => 7}) <>
          started_frames("c1") <>
          frame(%{
            "v" => 1,
            "type" => "stream",
            "id" => "c1",
            "stream" => "stdout",
            "data" => Base.encode64("one")
          }) <>
          frame(%{
            "v" => 1,
            "type" => "stream",
            "id" => "c1",
            "stream" => "stderr",
            "data" => Base.encode64("two")
          }) <>
          frame(%{"v" => 1, "type" => "done", "id" => "c1"})

      assert {:ok, _proto, frames} = proto() |> Protocol.feed(input)

      assert Enum.map(frames, & &1.type) == [:ready, :started, :stream, :stream, :done]
      assert Enum.map(frames, &Map.get(&1, :data)) == [nil, nil, "one", "two", nil]
    end

    test "decodes frames split byte by byte" do
      input =
        frame(%{"v" => 1, "type" => "ready"}) <>
          started_frames("c1") <>
          frame(%{"v" => 1, "type" => "done", "id" => "c1"})

      {final, frames} =
        for <<byte <- input>>, reduce: {proto(), []} do
          {parser, acc} ->
            {:ok, parser, decoded} = Protocol.feed(parser, <<byte>>)
            {parser, acc ++ decoded}
        end

      assert final.buffer == ""
      assert Enum.map(frames, & &1.type) == [:ready, :started, :done]
    end

    test "split feed mid-prefix, mid-json and mid-base64 still parses" do
      stream_frame =
        started_frames("c") <>
          frame(%{
            "v" => 1,
            "type" => "stream",
            "id" => "c",
            "stream" => "stdout",
            "data" => Base.encode64("payload")
          })

      {:ok, parser, []} = proto() |> Protocol.feed(binary_part(stream_frame, 0, 1))
      {:ok, parser, []} = Protocol.feed(parser, binary_part(stream_frame, 1, 20))

      {:ok, _parser, frames} =
        Protocol.feed(parser, binary_part(stream_frame, 21, byte_size(stream_frame) - 21))

      assert Enum.map(frames, & &1.type) == [:started, :stream]
      assert List.last(frames).data == "payload"
    end

    test "a frame completing on a later feed is returned then" do
      whole = frame(%{"v" => 1, "type" => "bye"})
      {:ok, parser, []} = proto() |> Protocol.feed(binary_part(whole, 0, byte_size(whole) - 1))
      assert {:ok, _parser, [%{type: :bye}]} = Protocol.feed(parser, "\n")
    end

    test "empty chunks are accepted" do
      assert {:ok, _proto, []} = proto() |> Protocol.feed("")
    end
  end

  describe "feed/2 cell correlation" do
    test "exception keeps the cell open until done" do
      input =
        started_frames("c1") <>
          frame(%{
            "v" => 1,
            "type" => "exception",
            "id" => "c1",
            "kind" => "error",
            "name" => "ValueError"
          }) <>
          frame(%{
            "v" => 1,
            "type" => "stream",
            "id" => "c1",
            "stream" => "stdout",
            "data" => Base.encode64("x")
          }) <>
          frame(%{"v" => 1, "type" => "done", "id" => "c1"})

      assert {:ok, _proto, frames} = proto() |> Protocol.feed(input)
      assert Enum.map(frames, & &1.type) == [:started, :exception, :stream, :done]
    end

    test "a new cell may start after done with a different id" do
      first = started_frames("c1") <> frame(%{"v" => 1, "type" => "done", "id" => "c1"})
      {:ok, parser, _} = proto() |> Protocol.feed(first)

      second = started_frames("c2") <> frame(%{"v" => 1, "type" => "done", "id" => "c2"})

      assert {:ok, _proto, [%{type: :started, id: "c2"}, %{type: :done, id: "c2"}]} =
               Protocol.feed(parser, second)
    end

    test "stream or done without an open cell is rejected" do
      stream =
        frame(%{
          "v" => 1,
          "type" => "stream",
          "id" => "c",
          "stream" => "stdout",
          "data" => Base.encode64("x")
        })

      assert {:error, :no_active_cell} = proto() |> Protocol.feed(stream)

      assert {:error, :no_active_cell} =
               proto() |> Protocol.feed(frame(%{"v" => 1, "type" => "done", "id" => "c"}))
    end

    test "duplicate done is rejected as cell-less" do
      input =
        started_frames("c") <>
          frame(%{"v" => 1, "type" => "done", "id" => "c"}) <>
          frame(%{"v" => 1, "type" => "done", "id" => "c"})

      assert {:error, :no_active_cell} = proto() |> Protocol.feed(input)
    end

    test "a second started while a cell is open is rejected" do
      input = started_frames("c1") <> started_frames("c2")
      assert {:error, {:cell_already_active, "c1"}} = proto() |> Protocol.feed(input)
    end

    test "frames carrying the wrong id are rejected" do
      input =
        started_frames("c1") <>
          frame(%{
            "v" => 1,
            "type" => "stream",
            "id" => "c2",
            "stream" => "stdout",
            "data" => Base.encode64("x")
          })

      assert {:error, {:wrong_id, "c1", "c2"}} = proto() |> Protocol.feed(input)

      input2 = started_frames("c1") <> frame(%{"v" => 1, "type" => "done", "id" => "c9"})
      assert {:error, {:wrong_id, "c1", "c9"}} = proto() |> Protocol.feed(input2)
    end

    test "a second ready is rejected" do
      {:ok, parser, _} = proto() |> Protocol.feed(frame(%{"v" => 1, "type" => "ready"}))

      assert {:error, {:unexpected_frame, :ready}} =
               Protocol.feed(parser, frame(%{"v" => 1, "type" => "ready"}))
    end
  end

  describe "feed/2 process terminals" do
    test "duplicate bye is rejected" do
      input = frame(%{"v" => 1, "type" => "bye"}) <> frame(%{"v" => 1, "type" => "bye"})
      assert {:error, {:unexpected_frame, :bye}} = proto() |> Protocol.feed(input)
    end

    test "any frame after bye is rejected" do
      input = frame(%{"v" => 1, "type" => "bye"}) <> started_frames("c")
      assert {:error, {:unexpected_frame, :started}} = proto() |> Protocol.feed(input)
    end

    test "any frame after fatal is rejected, including a second fatal" do
      {:ok, parser, _} =
        proto() |> Protocol.feed(frame(%{"v" => 1, "type" => "fatal", "reason" => "dead"}))

      assert {:error, {:unexpected_frame, :stream}} =
               Protocol.feed(
                 parser,
                 frame(%{
                   "v" => 1,
                   "type" => "stream",
                   "id" => "c",
                   "stream" => "stdout",
                   "data" => Base.encode64("x")
                 })
               )

      assert {:error, {:unexpected_frame, :fatal}} =
               Protocol.feed(parser, frame(%{"v" => 1, "type" => "fatal", "reason" => "again"}))
    end
  end

  describe "feed/2 fails closed on malformed input" do
    test "unprefixed bytes are never accepted as output or frames" do
      assert {:error, {:bad_prefix, sample}} = proto() |> Protocol.feed("hello stdout\n")
      assert is_binary(sample)

      # Even without a newline, garbage is rejected immediately.
      assert {:error, {:bad_prefix, _}} = proto() |> Protocol.feed("raw user output")
    end

    test "a partial buffer that diverges from the prefix is rejected before the newline" do
      assert {:error, {:bad_prefix, _}} = proto() |> Protocol.feed("\x1Elemon-pythX")
    end

    test "unprefixed bytes between valid frames are rejected" do
      input = frame(%{"v" => 1, "type" => "bye"}) <> "not a frame\n"
      assert {:error, {:bad_prefix, _}} = proto() |> Protocol.feed(input)
    end

    test "invalid JSON is rejected" do
      assert {:error, {:invalid_json, _}} = proto() |> Protocol.feed(@prefix <> "{oops\n")
    end

    test "a JSON document that is not an object is rejected" do
      assert {:error, {:invalid_json, :not_an_object}} =
               proto() |> Protocol.feed(@prefix <> "[1]\n")
    end

    test "wrong or missing version is rejected" do
      assert {:error, {:invalid_version, 2}} =
               proto() |> Protocol.feed(frame(%{"v" => 2, "type" => "bye"}))

      assert {:error, {:missing_field, "v"}} =
               proto() |> Protocol.feed(@prefix <> "{\"type\":\"bye\"}\n")
    end

    test "unknown or missing type is rejected" do
      assert {:error, {:unknown_type, "bogus"}} =
               proto() |> Protocol.feed(frame(%{"v" => 1, "type" => "bogus"}))

      assert {:error, {:missing_field, "type"}} =
               proto() |> Protocol.feed(@prefix <> "{\"v\":1}\n")
    end

    test "missing, empty or invalid required fields are rejected" do
      assert {:error, {:missing_field, "id"}} =
               proto() |> Protocol.feed(frame(%{"v" => 1, "type" => "started"}))

      assert {:error, {:invalid_field, {"id", ""}}} =
               proto() |> Protocol.feed(frame(%{"v" => 1, "type" => "started", "id" => ""}))

      stream = %{
        "v" => 1,
        "type" => "stream",
        "id" => "c",
        "stream" => "stdout",
        "data" => Base.encode64("x")
      }

      open_cell = started_frames("c")

      assert {:error, {:missing_field, "stream"}} =
               proto() |> Protocol.feed(open_cell <> frame(Map.delete(stream, "stream")))

      assert {:error, {:invalid_stream, "stdin"}} =
               proto() |> Protocol.feed(open_cell <> frame(Map.put(stream, "stream", "stdin")))

      assert {:error, {:missing_field, "data"}} =
               proto() |> Protocol.feed(open_cell <> frame(Map.delete(stream, "data")))

      assert {:error, {:invalid_field, {"pid", "x"}}} =
               proto() |> Protocol.feed(frame(%{"v" => 1, "type" => "ready", "pid" => "x"}))

      assert {:error, {:missing_field, "kind"}} =
               proto()
               |> Protocol.feed(
                 open_cell <>
                   frame(%{
                     "v" => 1,
                     "type" => "exception",
                     "id" => "c",
                     "name" => "ValueError"
                   })
               )

      assert {:error, {:invalid_field, {"kind", "weird"}}} =
               proto()
               |> Protocol.feed(
                 open_cell <>
                   frame(%{
                     "v" => 1,
                     "type" => "exception",
                     "id" => "c",
                     "kind" => "weird",
                     "name" => "E"
                   })
               )

      assert {:error, {:missing_field, "name"}} =
               proto()
               |> Protocol.feed(
                 open_cell <>
                   frame(%{"v" => 1, "type" => "exception", "id" => "c", "kind" => "error"})
               )

      assert {:error, {:missing_field, "name"}} =
               proto()
               |> Protocol.feed(
                 open_cell <>
                   frame(%{
                     "v" => 1,
                     "type" => "exception",
                     "id" => "c",
                     "kind" => "error",
                     "exc_type" => "LegacyError"
                   })
               )

      assert {:error, {:invalid_field, {"name", 42}}} =
               proto()
               |> Protocol.feed(
                 open_cell <>
                   frame(%{
                     "v" => 1,
                     "type" => "exception",
                     "id" => "c",
                     "kind" => "error",
                     "name" => 42
                   })
               )
    end

    test "invalid base64 stream data is rejected" do
      input =
        started_frames("c") <>
          frame(%{
            "v" => 1,
            "type" => "stream",
            "id" => "c",
            "stream" => "stdout",
            "data" => "!!!not-base64!!!"
          })

      assert {:error, {:invalid_base64, _}} = proto() |> Protocol.feed(input)
    end
  end

  describe "feed/2 bounds" do
    test "rejects complete frames above the frame cap" do
      cap = Protocol.frame_max_bytes()
      input = frame(%{"v" => 1, "type" => "fatal", "reason" => String.duplicate("a", cap)})

      assert byte_size(input) - 1 > cap
      assert {:error, {:frame_too_large, size}} = proto() |> Protocol.feed(input)
      assert size > cap
    end

    test "rejects incomplete buffers that exceed the frame cap without a newline" do
      too_big = @prefix <> String.duplicate("a", Protocol.frame_max_bytes() + 10)
      assert {:error, {:frame_too_large, size}} = proto() |> Protocol.feed(too_big)
      assert size > Protocol.frame_max_bytes()
    end

    test "accepts a frame exactly at the frame cap" do
      cap = Protocol.frame_max_bytes()
      skeleton = Jason.encode!(%{"v" => 1, "type" => "fatal", "reason" => ""})
      pad = cap - byte_size(@prefix) - byte_size(skeleton)

      input =
        @prefix <>
          Jason.encode!(%{"v" => 1, "type" => "fatal", "reason" => String.duplicate("a", pad)}) <>
          "\n"

      assert byte_size(input) - 1 == cap
      assert {:ok, _proto, [%{type: :fatal}]} = proto() |> Protocol.feed(input)
    end

    test "rejects stream chunks above the chunk cap" do
      chunk_cap = Protocol.stream_chunk_max_bytes()
      oversized = Base.encode64(String.duplicate("x", chunk_cap + 1))

      input =
        started_frames("c") <>
          frame(%{
            "v" => 1,
            "type" => "stream",
            "id" => "c",
            "stream" => "stdout",
            "data" => oversized
          })

      assert {:error, {:stream_too_large, size}} = proto() |> Protocol.feed(input)
      assert size == chunk_cap + 1
    end

    test "accepts a stream chunk exactly at the chunk cap" do
      chunk_cap = Protocol.stream_chunk_max_bytes()

      input =
        started_frames("c") <>
          frame(%{
            "v" => 1,
            "type" => "stream",
            "id" => "c",
            "stream" => "stdout",
            "data" => Base.encode64(String.duplicate("x", chunk_cap))
          })

      assert {:ok, _proto, [%{type: :started}, %{type: :stream, data: data}]} =
               proto() |> Protocol.feed(input)

      assert byte_size(data) == chunk_cap
    end
  end

  describe "Key.new/1" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "pi-repl-key-test-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
        )

      File.mkdir_p!(dir)
      real = realpath(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir, real: real}
    end

    defp attrs(dir, overrides \\ []) do
      Map.merge(
        %{
          scope_id: "sess-1234",
          agent_id: "default",
          cwd: dir,
          interpreter: System.find_executable("sh"),
          helpers: ["read", "grep"],
          protocol_version: 1
        },
        Map.new(overrides)
      )
    end

    test "canonicalizes required identity", %{dir: dir} do
      assert {:ok, %Key{} = key} = Key.new(attrs(dir))
      assert key.scope_id == "sess-1234"
      assert key.agent_id == "default"
      assert key.interpreter == realpath(System.find_executable("sh"))
      assert key.helpers == ["grep", "read"]
      assert key.protocol_version == 1
      assert byte_size(Key.digest(key)) == 64
    end

    test "resolves a symlinked cwd to its real path", %{real: real} do
      link = real <> "-link"
      File.ln_s!(real, link)
      on_exit(fn -> File.rm(link) end)

      assert {:ok, key} = Key.new(attrs(real, cwd: link))
      assert key.cwd == real
    end

    test "expands relative cwd" do
      assert {:ok, key} = Key.new(attrs(System.tmp_dir!(), cwd: "."))
      assert key.cwd == realpath(Path.expand("."))
    end

    test "resolves bare interpreter names through PATH" do
      assert {:ok, key} = Key.new(attrs(System.tmp_dir!(), interpreter: "sh"))
      assert key.interpreter == realpath(System.find_executable("sh"))
    end

    test "sorts and de-duplicates helpers, keeping the digest stable", %{dir: dir} do
      assert {:ok, a} = Key.new(attrs(dir, helpers: ["webfetch", "read", "grep", "read"]))
      assert a.helpers == ["grep", "read", "webfetch"]

      assert {:ok, b} = Key.new(attrs(dir, helpers: ["read", "grep", "webfetch"]))
      assert a == b
      assert Key.digest(a) == Key.digest(b)

      assert {:ok, c} = Key.new(attrs(dir, helpers: ["read"]))
      assert Key.digest(a) != Key.digest(c)
    end

    test "changes in any identity component change the digest", %{dir: dir} do
      {:ok, base} = Key.new(attrs(dir))
      {:ok, other_agent} = Key.new(attrs(dir, agent_id: "reviewer"))
      {:ok, other_version} = Key.new(attrs(dir, protocol_version: 2))

      assert Key.digest(base) != Key.digest(other_agent)
      assert Key.digest(base) != Key.digest(other_version)
    end

    test "accepts keyword lists", %{dir: dir} do
      assert {:ok, %Key{scope_id: "sess-1234"}} =
               Key.new(
                 scope_id: "sess-1234",
                 agent_id: "default",
                 cwd: dir,
                 interpreter: System.find_executable("sh"),
                 helpers: [],
                 protocol_version: 1
               )
    end

    test "rejects missing or blank identity", %{dir: dir} do
      assert {:error, {:missing_field, :scope_id}} = Key.new(Map.delete(attrs(dir), :scope_id))
      assert {:error, {:missing_field, :agent_id}} = Key.new(Map.delete(attrs(dir), :agent_id))
      assert {:error, {:invalid_scope_id, ""}} = Key.new(attrs(dir, scope_id: ""))
      assert {:error, {:invalid_agent_id, "  "}} = Key.new(attrs(dir, agent_id: "  "))
      assert {:error, {:missing_field, :cwd}} = Key.new(Map.delete(attrs(dir), :cwd))

      assert {:error, {:missing_field, :interpreter}} =
               Key.new(Map.delete(attrs(dir), :interpreter))

      assert {:error, {:missing_field, :helpers}} = Key.new(Map.delete(attrs(dir), :helpers))

      assert {:error, {:missing_field, :protocol_version}} =
               Key.new(Map.delete(attrs(dir), :protocol_version))
    end

    test "rejects unusable or non-canonicalizable paths", %{dir: dir} do
      assert {:error, {:cwd_not_found, _}} = Key.new(attrs(dir, cwd: dir <> "/missing"))

      plain = Path.join(dir, "plain")
      File.write!(plain, "x")
      assert {:error, {:cwd_not_directory, _}} = Key.new(attrs(dir, cwd: plain))

      assert {:error, {:interpreter_not_found, _}} =
               Key.new(attrs(dir, interpreter: "no-such-interp-xyz"))

      assert {:error, {:interpreter_not_found, _}} =
               Key.new(attrs(dir, interpreter: dir <> "/no-python"))

      noexec = Path.join(dir, "noexec")
      File.write!(noexec, "x")
      File.chmod!(noexec, 0o600)
      assert {:error, {:interpreter_not_executable, _}} = Key.new(attrs(dir, interpreter: noexec))
    end

    test "rejects invalid helpers and protocol version", %{dir: dir} do
      assert {:error, {:invalid_helper, ""}} = Key.new(attrs(dir, helpers: ["read", ""]))
      assert {:error, {:invalid_helper, 5}} = Key.new(attrs(dir, helpers: [5]))
      assert {:error, {:invalid_protocol_version, 0}} = Key.new(attrs(dir, protocol_version: 0))

      assert {:error, {:invalid_protocol_version, "1"}} =
               Key.new(attrs(dir, protocol_version: "1"))
    end

    test "never keys on volatile caller-overridable fields", %{dir: dir} do
      assert {:error, {:forbidden_field, :run_id}} =
               Key.new(Map.put(attrs(dir), :run_id, "run-9"))

      assert {:error, {:forbidden_field, :session_key}} =
               Key.new(Map.put(attrs(dir), :session_key, "custom"))

      assert {:error, {:forbidden_field, :policy}} =
               Key.new(Map.put(attrs(dir), :policy, %{bash: true}))

      assert {:error, {:forbidden_field, :tool_call_id}} =
               Key.new(Map.put(attrs(dir), :tool_call_id, "tc-1"))
    end
  end
end
