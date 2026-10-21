defmodule LemonEvals.CodingBenchmarkTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lemon.Eval.Coding

  test "omp metrics count assistant messages once rather than replay snapshots" do
    script = ~S'''
    import json, sys
    sys.path.insert(0, sys.argv[1])
    from coding_benchmark import parse_omp
    message = {'role':'assistant','content':[{'type':'text','text':'answer'}],
      'stopReason':'stop','usage':{'input':10,'cacheRead':90,'output':3,'totalTokens':103}}
    events = [{'type':'message_end','message':message},
      {'type':'turn_end','message':message},
      {'type':'tool_execution_end','isError':True},
      {'type':'agent_end','messages':[message]}]
    result = parse_omp('\n'.join(json.dumps(event) for event in events))
    assert result['ok'] and result['answer']=='answer'
    assert result['usage']['totalTokens']==103
    assert result['usage']['cacheReadTokens']==90
    assert result['metrics']=={'turns':1,'tool_errors':1}
    '''

    assert_python(script)
  end

  test "profile reports join request and terminal usage without counting ungraded probes" do
    script = ~S'''
    import json, pathlib, subprocess, sys, tempfile
    with tempfile.TemporaryDirectory() as directory:
      root=pathlib.Path(directory)
      benchmark={'results':[{'agent':'lemon','task':'case','run_id':'main'}]}
      (root/'benchmark.json').write_text(json.dumps(benchmark))
      base={'run_id':'main','session_id':'session','request_index':1}
      records=[dict(base,event='payload',estimates={'instructions':8,'tool_schemas':12},repeated_estimates={}),
        dict(base,event='usage',provider_usage={'input_tokens':100,'cache_read_tokens':90,'output_tokens':3,
          'request_fields':{'instructions':{'input_tokens':8,'cached_tokens':8},'tools':{'input_tokens':12,'cached_tokens':12}}}),
        dict(base,event='usage',run_id='probe',provider_usage={'input_tokens':90000})]
      (root/'profile.jsonl').write_text('\n'.join(json.dumps(row) for row in records)+'\n')
      result=subprocess.run([sys.executable,str(pathlib.Path(sys.argv[1])/'profile_report.py'),
        '--input',str(root/'profile.jsonl'),'--benchmark',str(root/'benchmark.json'),'--output',str(root/'report.json')],capture_output=True,text=True)
      assert result.returncode==0,result.stderr
      report=json.loads((root/'report.json').read_text())
      assert report['requests']==1 and report['vendor_usage']['input_tokens']==100
      assert report['vendor_usage']['cached_input_tokens']==90
      assert report['vendor_request_fields']['tools']['input_tokens']==12
      assert report['visible_wire_estimates']['tool_schemas']==12
    '''

    assert_python(script)
  end

  test "profiling crash diagnostics cannot disclose in-memory request bodies" do
    secret = "private-prompt-that-must-not-be-logged"

    status =
      LemonEvals.PayloadProfile.format_status(%{
        message: {:record, :payload, %{instructions: secret}},
        reason: {:encoding_failed, secret},
        log: [secret],
        state: %{port: :profile_port}
      })

    refute inspect(status) =~ secret
    assert status.message == :redacted
  end

  test "negated paired authorization cannot enter the paid nonpaired command" do
    for args <- [
          ["--no-live"],
          ["--no-paired", "--no-live"],
          ["--no-paired", "--config", "private.toml"]
        ] do
      assert_raise Mix.Error, "Paired authorization/options require --paired", fn ->
        Coding.run(args)
      end
    end
  end

  test "unsupported schema budgets are rejected before launching the Python benchmark" do
    for lane <- [[], ["--paired"], ["--paired", "--live"]],
        option <- [
          ["--schema-budgets", "500,50000"],
          ["--schema-budgets=500,50000"]
        ] do
      assert_raise Mix.Error, "Invalid coding benchmark arguments", fn ->
        Coding.run(lane ++ option)
      end
    end
  end

  test "repeated paired trials satisfy offline scheduling, isolation, accounting and approval contracts" do
    script = ~S'''
    import sys, unittest
    sys.path.insert(0, sys.argv[1])
    suite = unittest.defaultTestLoader.loadTestsFromName('test_coding_benchmark_paired')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    assert result.wasSuccessful(), 'offline paired-trial contracts failed'
    '''

    assert_python(script)
  end

  test "campaign options cannot mix with paid or paired lanes or fall through without --campaign" do
    for {args, message} <- [
          {["--output-dir", "/tmp/never"], "Campaign options require --campaign"},
          {["--providers", "zai:glm-5.3"], "Campaign options require --campaign"},
          {["--paired", "--resume"], "Campaign options require --campaign"},
          {["--no-campaign", "--control-plane-port", "4290"],
           "Campaign options require --campaign"},
          {["--campaign"], "--campaign requires --output-dir"},
          {["--campaign", "--output-dir", ""], "--campaign requires --output-dir"},
          {["--campaign", "--paired", "--output-dir", "/tmp/never"], :combined},
          {["--campaign", "--output", "/tmp/never.json", "--output-dir", "/tmp/never"],
           :combined},
          {["--campaign", "--model", "zai:glm-5.3", "--output-dir", "/tmp/never"], :combined},
          {["--campaign", "--failure-dir", "/tmp/f", "--output-dir", "/tmp/never"], :combined},
          {["--campaign", "--plan", "p.json", "--output-dir", "/tmp/never"], :combined}
        ] do
      error =
        assert_raise Mix.Error, fn -> Coding.run(args) end

      case message do
        :combined -> assert error.message =~ "--campaign cannot be combined"
        text -> assert error.message == text
      end
    end
  end

  test "campaign work deadlines and durable stop continuations are validated before launch" do
    for seconds <- ["0", "-1", "28801"] do
      assert_raise Mix.Error,
                   "--run-timeout must be positive and at most 28800 seconds (8h) per provider",
                   fn ->
                     Coding.run([
                       "--campaign",
                       "--output-dir",
                       "/tmp/never",
                       "--run-timeout",
                       seconds
                     ])
                   end
    end

    for flags <- [[], ["--live"], ["--resume"]] do
      assert_raise Mix.Error, "--continue-after-stop requires --campaign --live --resume", fn ->
        Coding.run(
          [
            "--campaign",
            "--output-dir",
            "/tmp/never",
            "--continue-after-stop",
            String.duplicate("a", 64)
          ] ++
            flags
        )
      end
    end

    assert_raise Mix.Error, "--continue-after-stop must be a durable stop SHA256", fn ->
      Coding.run([
        "--campaign",
        "--live",
        "--resume",
        "--output-dir",
        "/tmp/never",
        "--continue-after-stop",
        "invalid"
      ])
    end

    assert_raise Mix.Error, "Campaign options require --campaign", fn ->
      Coding.run(["--continue-after-stop", String.duplicate("a", 64)])
    end
  end

  test "campaign work deadline and exact continuation are forwarded without launching a provider" do
    directory = Path.join(System.tmp_dir!(), "lemon-campaign-options")
    stop_id = String.duplicate("a", 64)

    assert Coding.campaign_argv(
             [
               providers: "zai:glm-5.3",
               run_timeout: 60,
               output_dir: directory,
               live: true,
               resume: true,
               continue_after_stop: stop_id
             ],
             "coding_benchmark.py",
             "bin/lemon",
             660
           ) == [
             "coding_benchmark.py",
             "--campaign",
             "--lemon",
             "bin/lemon",
             "--timeout",
             "660",
             "--live",
             "--resume",
             "--output-dir",
             Path.expand(directory),
             "--providers",
             "zai:glm-5.3",
             "--run-timeout",
             "60",
             "--continue-after-stop",
             stop_id
           ]
  end

  test "repeated multi-provider campaign satisfies offline ID, isolation, resume and spend contracts" do
    script = ~S'''
    import sys, unittest
    sys.path.insert(0, sys.argv[1])
    suite = unittest.defaultTestLoader.loadTestsFromName('test_coding_benchmark_campaign')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    assert result.wasSuccessful(), 'offline campaign contracts failed'
    '''

    assert_python(script)
  end

  test "disclosure telemetry hashes resolved bridge targets before profiling" do
    target = "private.bridge.resolved-tool-name"
    digest = Base.encode16(:crypto.hash(:sha256, target), case: :lower)

    LemonEvals.PayloadProfile.handle_disclosure_event(
      [:coding_agent, :tool_disclosure, :invoke],
      %{duration_us: 27},
      %{tool_name: target, status: :error, arguments: target, result: target},
      self()
    )

    assert_receive {:"$gen_cast", {:record, :disclosure_invoke, data, %{}}}
    assert data == %{resolved_tool_digest: digest, status: "error", duration_us: 27}
    refute inspect(data) =~ target

    for status <- [:unknown, :schema_invalid, :pending, nil] do
      LemonEvals.PayloadProfile.handle_disclosure_event(
        [:coding_agent, :tool_disclosure, :invoke],
        %{duration_us: 27},
        %{tool_name: target, status: status},
        self()
      )
    end

    refute_receive {:"$gen_cast", {:record, :disclosure_invoke, _, _}}
  end

  test "disclosure profile telemetry retains only known applied profiles" do
    LemonEvals.PayloadProfile.handle_disclosure_event(
      [:coding_agent, :tool_disclosure, :applied],
      %{},
      %{
        profile: :coding,
        active: true,
        diagnostic_events_version: 1,
        config: "private-configuration"
      },
      self()
    )

    assert_receive {:"$gen_cast", {:record, :disclosure_applied, applied, %{}}}
    assert applied.profile == "coding"
    assert applied.active == true
    assert applied.diagnostic_events_version == 1
    refute inspect(applied) =~ "private-configuration"

    LemonEvals.PayloadProfile.handle_disclosure_event(
      [:coding_agent, :tool_disclosure, :applied],
      %{},
      %{profile: :unknown, active: true},
      self()
    )

    refute_receive {:"$gen_cast", {:record, :disclosure_applied, _, _}}
  end

  test "disclosure diagnostic telemetry retains counts and rejection enums without raw requests" do
    for {status, count} <- [{:ok, 0}, {:ok, 3}, {:error, 0}] do
      LemonEvals.PayloadProfile.handle_disclosure_event(
        [:coding_agent, :tool_disclosure, :search],
        %{matched_count: count, query: "private-query"},
        %{status: status, query: "private-query"},
        self()
      )

      expected = %{status: Atom.to_string(status), matched_count: count}
      assert_receive {:"$gen_cast", {:record, :disclosure_search, ^expected, %{}}}
    end

    for {status, count} <- [{:unknown, 0}, {:ok, -1}, {:ok, nil}, {:ok, 1.5}] do
      LemonEvals.PayloadProfile.handle_disclosure_event(
        [:coding_agent, :tool_disclosure, :search],
        %{matched_count: count},
        %{status: status},
        self()
      )
    end

    refute_receive {:"$gen_cast", {:record, :disclosure_search, _, _}}

    for reason <- [:unknown_tool, :invalid_arguments, :invalid_request] do
      LemonEvals.PayloadProfile.handle_disclosure_event(
        [:coding_agent, :tool_disclosure, :invoke_rejected],
        %{arguments: "private-arguments"},
        %{reason: reason, tool_name: "private-target", arguments: "private-arguments"},
        self()
      )

      expected = %{reason: Atom.to_string(reason)}
      assert_receive {:"$gen_cast", {:record, :disclosure_rejected, ^expected, %{}}}
    end

    LemonEvals.PayloadProfile.handle_disclosure_event(
      [:coding_agent, :tool_disclosure, :invoke_rejected],
      %{},
      %{reason: :unknown_reason},
      self()
    )

    refute_receive {:"$gen_cast", {:record, :disclosure_rejected, _, _}}
  end

  defp assert_python(script) do
    python = System.find_executable("python3") || flunk("python3 is required")
    priv = Path.join(:code.priv_dir(:lemon_evals), "")
    {output, status} = System.cmd(python, ["-c", script, priv], stderr_to_stdout: true)
    assert status == 0, output
  end
end
