defmodule LemonSkills.NativeMemoryContextTest do
  use ExUnit.Case, async: false

  alias LemonMemory.{Document, Preferences, Project, Store}
  alias LemonSkills.MemoryRecall
  alias LemonSkills.Tools.{Recall, Remember}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    store = :"native_context_store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: store, path: Path.join(tmp_dir, "store")})
    cwd = Path.join(tmp_dir, "repository")
    home = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(Path.join(cwd, ".git"))
    File.mkdir_p!(Path.join(home, "memory"))
    File.write!(Path.join(home, "USER.md"), "Birthday gift legacy recipient has sapphire code.\n")
    File.write!(Path.join(home, "MEMORY.md"), "Birthday gift legacy memory contains obsidian.\n")

    File.write!(
      Path.join(home, "memory/diary.md"),
      "Birthday gift journal contains black opal.\n"
    )

    a = %{
      cwd: cwd,
      workspace_dir: home,
      agent_id: "shared-bot",
      session_scope: :main,
      session_key: "agent:shared-bot:main",
      invocation_context_key: "invocation-epoch-1",
      memory_context_key: "private_bot_v1.actor-a",
      memory_context_verified: true,
      shared_memory_grant: false,
      query: "birthday gift"
    }

    %{store: store, a: a, b: %{a | memory_context_key: "private_bot_v1.actor-b"}, home: home}
  end

  test "native remember stays private despite model scope/grant claims and never modifies legacy files",
       ctx do
    before_user = File.read!(Path.join(ctx.home, "USER.md"))
    before_memory = File.read!(Path.join(ctx.home, "MEMORY.md"))

    result =
      remember(
        ctx.a,
        ctx.store,
        "Birthday gift recipient Priya likes cedar notebooks.",
        "user",
        %{
          "memoryScope" => "shared",
          "memoryContextKey" => ctx.b.memory_context_key,
          "sharedMemoryGrant" => true,
          "memory_context_verified" => true
        }
      )

    assert %{details: %{changed: true, memory_scope: "private"}} = result

    assert {:ok, ["Birthday gift recipient Priya likes cedar notebooks."]} =
             Preferences.read(ctx.a, store: ctx.store)

    assert {:ok, []} = Preferences.read(ctx.b, store: ctx.store)
    assert {:ok, []} = Preferences.read_shared(ctx.a, store: ctx.store)
    assert File.read!(Path.join(ctx.home, "USER.md")) == before_user
    assert File.read!(Path.join(ctx.home, "MEMORY.md")) == before_memory
    refute inspect(result) =~ ctx.a.memory_context_key
    same_actor = %{ctx.a | invocation_context_key: "invocation-epoch-2"}
    assert {:ok, [_]} = Preferences.read(same_actor, store: ctx.store)
    room = %{ctx.a | memory_context_key: "shared_room_v1.actor-a-room-a"}
    assert {:ok, []} = Preferences.read(room, store: ctx.store)

    assert {:error, _} =
             remember(%{ctx.a | memory_context_verified: false}, ctx.store, "Must not write.")
  end

  test "native recall and actual volatile contributor exclude other actors, legacy runs and raw files",
       ctx do
    remember(ctx.a, ctx.store, "Birthday gift recipient Priya likes cedar notebooks.", "user")
    remember(ctx.b, ctx.store, "Birthday gift recipient Omar likes copper bowls.", "user")

    remember(
      %{ctx.a | shared_memory_grant: true},
      ctx.store,
      "Birthday gift budget is forty dollars.",
      "user"
    )

    assert {:ok, _} =
             Project.remember(ctx.a, "Birthday gift packaging uses violet ribbons.", nil,
               store: ctx.store
             )

    assert {:ok, _} =
             Project.remember(ctx.b, "Birthday gift packaging uses silver ribbons.", nil,
               store: ctx.store
             )

    insert_run(ctx.store, ctx.a, "actor-a-run", "Birthday gift history mentions saffron.")
    insert_run(ctx.store, ctx.b, "actor-b-run", "Birthday gift history mentions graphite.")

    legacy =
      Map.drop(ctx.a, [
        :memory_context_key,
        :memory_context_verified,
        :invocation_context_key,
        :shared_memory_grant
      ])

    insert_run(ctx.store, legacy, "legacy-run", "Birthday gift legacy history mentions granite.")
    {:ok, identity} = Project.scope(ctx.a)

    :ok =
      Store.put_sync(
        ctx.store,
        Document.new(
          agent_id: ctx.a.agent_id,
          workspace_key: ctx.a.cwd,
          session_key: ctx.a.session_key,
          answer_summary: "Birthday gift unproven history mentions jasper.",
          meta: %{"home_digest" => identity.home_digest, "memory_scope" => "unproven"}
        )
      )

    result = recall(ctx.a, ctx.store)
    assert %{details: %{notes: 2, conversations: 1}} = result
    text = Enum.map_join(result.content, "\n", & &1.text)
    assert text =~ "cedar notebooks"
    assert text =~ "forty dollars"
    assert text =~ "saffron"

    for excluded <- [
          "copper bowls",
          "graphite",
          "granite",
          "jasper",
          "sapphire",
          "obsidian",
          "black opal"
        ],
        do: refute(text =~ excluded)

    assert {:ok, section} = MemoryRecall.contribute(ctx.a, store: ctx.store, auto_recall: true)
    assert section.placement == :user_message
    assert section.body =~ "cedar notebooks"
    assert section.body =~ "violet ribbons"
    assert section.body =~ "saffron"
    assert section.body =~ "forty dollars"

    for excluded <- [
          "copper bowls",
          "silver ribbons",
          "graphite",
          "granite",
          "jasper",
          "sapphire",
          "obsidian",
          "black opal"
        ],
        do: refute(section.body =~ excluded)

    b_text = recall(ctx.b, ctx.store).content |> Enum.map_join("\n", & &1.text)
    assert b_text =~ "copper bowls"
    assert b_text =~ "graphite"
    refute b_text =~ "cedar notebooks"
    refute b_text =~ "saffron"

    forged =
      ctx.a |> Map.delete(:memory_context_verified) |> Map.put("memory_context_verified", true)

    assert MemoryRecall.contribute(forged, store: ctx.store, auto_recall: true) == :skip
  end

  test "explicit shared writes authorize only exact new facts and capture never promotes private facts",
       ctx do
    remember(ctx.a, ctx.store, "Birthday gift private preference mentions indigo.", "user")
    trusted_shared = %{ctx.a | shared_memory_grant: true}

    assert %{details: %{memory_scope: "shared"}} =
             remember(
               trusted_shared,
               ctx.store,
               "Birthday gift shared preference mentions amber.",
               "user"
             )

    assert {:ok, files} = Preferences.shared_bootstrap(ctx.b, store: ctx.store)
    assert files["USER.md"] =~ "amber"
    for excluded <- ["indigo", "sapphire", "obsidian"], do: refute(files["USER.md"] =~ excluded)

    assert {:ok, _} =
             Project.capture(trusted_shared, ["Birthday gift automatic capture mentions jade."],
               store: ctx.store
             )

    assert {:ok, a_facts} = Project.read(ctx.a, store: ctx.store)
    assert Enum.any?(a_facts, &String.contains?(&1, "jade"))
    assert {:ok, []} = Project.read(ctx.b, store: ctx.store)

    assert {:ok, _} =
             Project.remember(
               trusted_shared,
               "Birthday gift shared project uses paper wrapping.",
               nil, store: ctx.store)

    assert {:ok, ["Birthday gift shared project uses paper wrapping."]} =
             Project.read(ctx.b, store: ctx.store)

    assert {:ok, a_after} = Project.read(ctx.a, store: ctx.store)
    assert Enum.any?(a_after, &String.contains?(&1, "jade"))
    assert File.read!(Path.join(ctx.home, "USER.md")) =~ "sapphire"
  end

  defp remember(context, store, text, target \\ "memory", params \\ %{}) do
    tool = Remember.tool(context.cwd, tool_opts(context, store))
    tool.execute.("remember", Map.merge(%{"text" => text, "target" => target}, params), nil, nil)
  end

  defp recall(context, store) do
    opts =
      Keyword.put(tool_opts(context, store), :search_fn, fn _, _ ->
        flunk("private recall must not use the legacy provider path")
      end)

    tool = Recall.tool(context.cwd, opts)
    tool.execute.("recall", %{"query" => "birthday gift", "scope" => "agent"}, nil, nil)
  end

  defp tool_opts(context, store),
    do: context |> Map.drop([:cwd, :query]) |> Map.to_list() |> Keyword.put(:store, store)

  defp insert_run(store, context, id, answer) do
    {:ok, identity} = Project.scope(context)

    meta =
      context
      |> Map.take([:invocation_context_key, :memory_context_key, :memory_context_verified])
      |> Map.put("home_digest", identity.home_digest)

    doc =
      Document.from_run(id, %{events: []}, %{
        session_key: context.session_key,
        agent_id: context.agent_id,
        cwd: context.cwd,
        meta: meta,
        prompt: "Birthday gift planning history",
        completed: %{ok: true, answer: answer}
      })

    :ok = Store.put_sync(store, doc)
  end
end
