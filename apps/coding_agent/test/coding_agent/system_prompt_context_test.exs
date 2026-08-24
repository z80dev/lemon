defmodule CodingAgent.SystemPromptContextTest.Alpha do
  @moduledoc false

  @owner CodingAgent.SystemPromptContextTest.Owner

  def contribute(request) do
    send(Process.whereis(@owner), {:contributed, __MODULE__, request})
    {:ok, %{title: "Alpha Context", body: "alpha body line"}}
  end
end

defmodule CodingAgent.SystemPromptContextTest.Beta do
  @moduledoc false

  def contribute(_request), do: {:ok, %{title: "Beta Context", body: "beta body line"}}
end

defmodule CodingAgent.SystemPromptContextTest.Patient do
  @moduledoc false

  # A contributor with a cold cache asking for the budget it needs on this one
  # turn, exactly as `LemonHoncho.ContextContributor` does on a session's first
  # turn. The prompt builder passes no ceiling of its own, so this must be
  # honoured rather than clipped to the registry's 250ms default.
  def timeout_ms(_request), do: 1_500

  def contribute(_request) do
    Process.sleep(400)
    {:ok, %{title: "Patient Context", body: "patient body line"}}
  end
end

defmodule CodingAgent.SystemPromptContextTest.Splitter do
  @moduledoc false

  # A contributor with something stable to say and something that changes every
  # turn. Only the stable half may reach the system prompt: the volatile half
  # would invalidate the prompt cache on every turn it changed.
  def contribute(_request) do
    {:ok,
     [
       %{title: "Stable Context", body: "stable body line", placement: :system},
       %{title: "Volatile Context", body: "volatile body line", placement: :user_message}
     ]}
  end
end

defmodule CodingAgent.SystemPromptContextTest.Tripwire do
  @moduledoc false

  @owner CodingAgent.SystemPromptContextTest.Owner

  # Registered and then expected never to be asked: if `build/2` collects even
  # though the caller handed it sections, this fires.
  def contribute(request) do
    send(Process.whereis(@owner), {:collected, __MODULE__, request})
    {:ok, %{title: "Tripwire Context", body: "tripwire body line"}}
  end
end

defmodule CodingAgent.SystemPromptContextTest.Exploding do
  @moduledoc false

  def contribute(_request), do: raise("contributor is broken")
end

defmodule CodingAgent.SystemPromptContextTest do
  # `:persistent_term` backs the registry, so registrations are global to the
  # node and these tests must not run beside anything else that builds a prompt.
  use ExUnit.Case, async: false

  alias CodingAgent.SystemPrompt
  alias CodingAgent.SystemPromptContextTest.Alpha
  alias CodingAgent.SystemPromptContextTest.Beta
  alias CodingAgent.SystemPromptContextTest.Exploding
  alias CodingAgent.SystemPromptContextTest.Patient
  alias CodingAgent.SystemPromptContextTest.Splitter
  alias CodingAgent.SystemPromptContextTest.Tripwire
  alias LemonAgent.ContextRegistry

  @names [
    :test_alpha,
    :test_beta,
    :test_exploding,
    :test_patient,
    :test_splitter,
    :test_tripwire
  ]

  setup do
    Process.register(self(), CodingAgent.SystemPromptContextTest.Owner)
    Enum.each(@names, &ContextRegistry.unregister/1)
    on_exit(fn -> Enum.each(@names, &ContextRegistry.unregister/1) end)
    :ok
  end

  @tag :tmp_dir
  test "registering a contributor changes nothing else in the prompt", %{tmp_dir: tmp_dir} do
    opts = build_opts(tmp_dir)

    baseline = SystemPrompt.build(tmp_dir, opts)

    refute String.contains?(baseline, "## Alpha Context")

    :ok = ContextRegistry.register(:test_alpha, Alpha)

    contributed = SystemPrompt.build(tmp_dir, opts)

    expected =
      String.replace(
        baseline,
        "## Boundaries",
        "## Alpha Context\n\nalpha body line\n\n## Boundaries"
      )

    assert contributed == expected
  end

  @tag :tmp_dir
  test "a contributed title and body appear under a markdown heading", %{tmp_dir: tmp_dir} do
    :ok = ContextRegistry.register(:test_alpha, Alpha)

    prompt = SystemPrompt.build(tmp_dir, build_opts(tmp_dir))

    assert String.contains?(prompt, "## Alpha Context\n\nalpha body line")
  end

  @tag :tmp_dir
  test "the contributor receives the turn's identifiers and query", %{tmp_dir: tmp_dir} do
    :ok = ContextRegistry.register(:test_alpha, Alpha)

    opts =
      tmp_dir
      |> build_opts()
      |> Map.merge(%{
        session_scope: :main,
        session_key: "session-key-1",
        session_id: "session-id-1",
        agent_id: "agent-id-1",
        run_id: "run-id-1",
        skill_context: "what did we decide about billing"
      })

    SystemPrompt.build(tmp_dir, opts)

    # The registry is global to the node, so background work left running by an
    # earlier test can build its own prompt and reach this contributor too.
    # Match on this turn's run id rather than on whichever contribution happens
    # to arrive first.
    assert_receive {:contributed, Alpha, %{run_id: "run-id-1"} = request}, 2_000

    assert request.cwd == tmp_dir
    assert request.session_scope == :main
    assert request.session_key == "session-key-1"
    assert request.session_id == "session-id-1"
    assert request.agent_id == "agent-id-1"
    assert request.run_id == "run-id-1"
    assert request.query == "what did we decide about billing"
  end

  @tag :tmp_dir
  test "a contributor that raises does not break prompt building", %{tmp_dir: tmp_dir} do
    :ok = ContextRegistry.register(:test_exploding, Exploding)
    :ok = ContextRegistry.register(:test_beta, Beta)

    prompt = SystemPrompt.build(tmp_dir, build_opts(tmp_dir))

    assert String.contains?(prompt, "You are a personal assistant running inside Lemon.")
    assert String.contains?(prompt, "## Boundaries")
    assert String.contains?(prompt, "## Beta Context")
    refute String.contains?(prompt, "contributor is broken")
  end

  # The regression this guards: the builder used to bound the whole collect at
  # the registry's default, so a contributor that asked for longer — the only
  # way to be useful on the first turn of a cold session — was killed on every
  # turn and never reached the prompt.
  @tag :tmp_dir
  test "a contributor's own budget survives the prompt builder", %{tmp_dir: tmp_dir} do
    :ok = ContextRegistry.register(:test_patient, Patient)

    {micros, prompt} = :timer.tc(fn -> SystemPrompt.build(tmp_dir, build_opts(tmp_dir)) end)

    assert String.contains?(prompt, "## Patient Context\n\npatient body line")
    assert micros > 300_000
    assert micros < 3_000_000
  end

  @tag :tmp_dir
  test "two contributors both appear, in registration order", %{tmp_dir: tmp_dir} do
    :ok = ContextRegistry.register(:test_alpha, Alpha)
    :ok = ContextRegistry.register(:test_beta, Beta)

    prompt = SystemPrompt.build(tmp_dir, build_opts(tmp_dir))

    alpha_at = index_of(prompt, "## Alpha Context")
    beta_at = index_of(prompt, "## Beta Context")
    boundaries_at = index_of(prompt, "## Boundaries")

    assert alpha_at < beta_at
    assert beta_at < boundaries_at
  end

  @tag :tmp_dir
  test "only the system half of a split contribution is rendered", %{tmp_dir: tmp_dir} do
    :ok = ContextRegistry.register(:test_splitter, Splitter)

    prompt = SystemPrompt.build(tmp_dir, build_opts(tmp_dir))

    assert String.contains?(prompt, "## Stable Context\n\nstable body line")

    # The volatile half is the caller's to put in the user message. Rendered
    # here it would change the cached system prefix on the turns it changed,
    # which is the cost this split exists to avoid.
    refute String.contains?(prompt, "Volatile Context")
    refute String.contains?(prompt, "volatile body line")
  end

  @tag :tmp_dir
  test "given sections are used as they are, and nothing is collected", %{tmp_dir: tmp_dir} do
    :ok = ContextRegistry.register(:test_tripwire, Tripwire)

    opts =
      tmp_dir
      |> build_opts()
      |> Map.merge(%{
        run_id: "no-collect-run",
        contributed_sections: [
          %{name: :given, title: "Given Context", body: "given body line", placement: :system},
          %{name: :given, title: "Given Volatile", body: "elsewhere", placement: :user_message}
        ]
      })

    prompt = SystemPrompt.build(tmp_dir, opts)

    assert String.contains?(prompt, "## Given Context\n\ngiven body line")
    refute String.contains?(prompt, "Given Volatile")
    refute String.contains?(prompt, "Tripwire Context")

    # A second collect on the same turn would pay every contributor's budget
    # twice and could answer differently the second time. Matched on this turn's
    # run id because the registry is global to the node and background work from
    # another test can build its own prompt and reach this contributor.
    refute_receive {:collected, Tripwire, %{run_id: "no-collect-run"}}, 500
  end

  @tag :tmp_dir
  test "a given section with no placement is rendered as a system section", %{tmp_dir: tmp_dir} do
    # The plausible third-party shape: a caller assembling the list by hand
    # writes a title and a body, because `:placement` is optional and documented
    # to default to `:system`. Filtering on the key dropped it silently.
    opts =
      tmp_dir
      |> build_opts()
      |> Map.put(:contributed_sections, [%{name: :given, title: "Hand Built", body: "hand body"}])

    prompt = SystemPrompt.build(tmp_dir, opts)

    assert String.contains?(prompt, "## Hand Built\n\nhand body")
  end

  @tag :tmp_dir
  test "a given section naming an unrecognised placement is not rendered", %{tmp_dir: tmp_dir} do
    opts =
      tmp_dir
      |> build_opts()
      |> Map.put(:contributed_sections, [
        %{name: :given, title: "Kept", body: "kept body", placement: :system},
        %{name: :given, title: "Elsewhere", body: "elsewhere body", placement: :prompt_suffix}
      ])

    prompt = SystemPrompt.build(tmp_dir, opts)

    # A missing key takes the documented default; a wrong value is a statement
    # that this is not a system section and is believed. The direction that is
    # never guessed is *into* the cached prefix, which bills every turn.
    assert String.contains?(prompt, "## Kept\n\nkept body")
    refute String.contains?(prompt, "Elsewhere")
  end

  @tag :tmp_dir
  test "a :contributed_sections that is not a list raises instead of collecting",
       %{tmp_dir: tmp_dir} do
    :ok = ContextRegistry.register(:test_tripwire, Tripwire)

    opts =
      tmp_dir
      |> build_opts()
      |> Map.merge(%{
        run_id: "malformed-run",
        contributed_sections: %{name: :given, title: "Not A List", body: "body"}
      })

    # Loud, not an empty and not a fallback. Falling back ran every contributor
    # a second time on a turn that had already collected — the exact double
    # collect this option exists to prevent — while an empty would have shipped
    # a prompt with the caller's recalled context silently missing from it.
    assert_raise ArgumentError, ~r/:contributed_sections/, fn ->
      SystemPrompt.build(tmp_dir, opts)
    end

    refute_receive {:collected, Tripwire, %{run_id: "malformed-run"}}, 500
  end

  @tag :tmp_dir
  test "an empty section list renders exactly what no contributor does", %{tmp_dir: tmp_dir} do
    opts = build_opts(tmp_dir)

    baseline = SystemPrompt.build(tmp_dir, opts)
    given = SystemPrompt.build(tmp_dir, Map.put(opts, :contributed_sections, []))

    # Byte-for-byte: with nothing contributed the section renders empty and is
    # dropped from the prompt entirely, so neither path leaves a stray heading
    # or separator behind.
    assert given == baseline
    refute String.contains?(baseline, "## Alpha Context")
  end

  defp build_opts(tmp_dir) do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    %{workspace_dir: workspace_dir, session_scope: :main}
  end

  defp index_of(haystack, needle) do
    {index, _length} = :binary.match(haystack, needle)
    index
  end
end
