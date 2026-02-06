defmodule CodingAgent.SessionManager do
  @moduledoc """
  JSONL session persistence with tree structure support.

  Sessions are stored as JSONL files where each line is a JSON entry.
  The first entry is always a SessionHeader, followed by session entries.

  ## Tree Structure

  Messages form a tree structure where each entry has an `id` and optional `parent_id`.
  This enables branching conversations and navigation between branches.

  ## Session Format Version

  Current version is 3. Migrations handle:
  - v1 -> v2: Add id/parentId to entries, convert compaction index to id
  - v2 -> v3: Rename "hookMessage" role to "custom"
  """

  alias CodingAgent.SessionManager.{Session, SessionHeader, SessionEntry}

  @current_version 3
  @id_length 8

  # ============================================================================
  # Data Structures
  # ============================================================================

  defmodule SessionHeader do
    @moduledoc "Header entry for session files (always first line)"
    @type t :: %__MODULE__{
            type: :session,
            version: pos_integer(),
            id: String.t(),
            timestamp: integer(),
            cwd: String.t(),
            parent_session: String.t() | nil
          }
    defstruct type: :session,
              version: 3,
              id: "",
              timestamp: 0,
              cwd: "",
              parent_session: nil
  end

  defmodule SessionEntry do
    @moduledoc """
    Session entry types for the tree structure.

    Entry types:
    - `:message` - Contains message data with id, parent_id, timestamp
    - `:thinking_level_change` - thinkingLevel field
    - `:model_change` - provider, modelId fields
    - `:compaction` - summary, first_kept_entry_id, tokens_before, details, from_hook
    - `:branch_summary` - from_id, summary, details, from_hook
    - `:label` - target_id, label (string or nil to remove)
    - `:session_info` - name field
    - `:custom` - custom_type, data fields
    - `:custom_message` - custom_type, content, display, details
    """

    @type entry_type ::
            :message
            | :thinking_level_change
            | :model_change
            | :compaction
            | :branch_summary
            | :label
            | :session_info
            | :custom
            | :custom_message

    @type t :: %__MODULE__{
            id: String.t(),
            parent_id: String.t() | nil,
            timestamp: integer(),
            type: entry_type(),
            # message type
            message: map() | nil,
            # thinking_level_change type
            thinking_level: atom() | nil,
            # model_change type
            provider: String.t() | nil,
            model_id: String.t() | nil,
            # compaction type
            summary: String.t() | nil,
            first_kept_entry_id: String.t() | nil,
            tokens_before: non_neg_integer() | nil,
            details: map() | nil,
            from_hook: boolean() | nil,
            # branch_summary type
            from_id: String.t() | nil,
            # label type
            target_id: String.t() | nil,
            label: String.t() | nil,
            # session_info type
            name: String.t() | nil,
            # custom type
            custom_type: String.t() | nil,
            data: map() | nil,
            # custom_message type
            content: any() | nil,
            display: boolean() | nil
          }

    defstruct [
      :id,
      :parent_id,
      :timestamp,
      :type,
      # message
      :message,
      # thinking_level_change
      :thinking_level,
      # model_change
      :provider,
      :model_id,
      # compaction
      :summary,
      :first_kept_entry_id,
      :tokens_before,
      :details,
      :from_hook,
      # branch_summary
      :from_id,
      # label
      :target_id,
      :label,
      # session_info
      :name,
      # custom
      :custom_type,
      :data,
      # custom_message
      :content,
      :display
    ]

    @doc "Create a new message entry"
    def message(message, opts \\ []) do
      %__MODULE__{
        type: :message,
        message: message,
        id: Keyword.get(opts, :id),
        parent_id: Keyword.get(opts, :parent_id),
        timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
      }
    end

    @doc "Create a thinking level change entry"
    def thinking_level_change(level, opts \\ []) do
      %__MODULE__{
        type: :thinking_level_change,
        thinking_level: level,
        id: Keyword.get(opts, :id),
        parent_id: Keyword.get(opts, :parent_id),
        timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
      }
    end

    @doc "Create a model change entry"
    def model_change(provider, model_id, opts \\ []) do
      %__MODULE__{
        type: :model_change,
        provider: provider,
        model_id: model_id,
        id: Keyword.get(opts, :id),
        parent_id: Keyword.get(opts, :parent_id),
        timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
      }
    end

    @doc "Create a compaction entry"
    def compaction(summary, first_kept_entry_id, tokens_before, opts \\ []) do
      %__MODULE__{
        type: :compaction,
        summary: summary,
        first_kept_entry_id: first_kept_entry_id,
        tokens_before: tokens_before,
        details: Keyword.get(opts, :details),
        from_hook: Keyword.get(opts, :from_hook, false),
        id: Keyword.get(opts, :id),
        parent_id: Keyword.get(opts, :parent_id),
        timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
      }
    end

    @doc "Create a branch summary entry"
    def branch_summary(from_id, summary, opts \\ []) do
      %__MODULE__{
        type: :branch_summary,
        from_id: from_id,
        summary: summary,
        details: Keyword.get(opts, :details),
        from_hook: Keyword.get(opts, :from_hook, false),
        id: Keyword.get(opts, :id),
        parent_id: Keyword.get(opts, :parent_id),
        timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
      }
    end

    @doc "Create a label entry"
    def label(target_id, label_text, opts \\ []) do
      %__MODULE__{
        type: :label,
        target_id: target_id,
        label: label_text,
        id: Keyword.get(opts, :id),
        parent_id: Keyword.get(opts, :parent_id),
        timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
      }
    end

    @doc "Create a session info entry"
    def session_info(name, opts \\ []) do
      %__MODULE__{
        type: :session_info,
        name: name,
        id: Keyword.get(opts, :id),
        parent_id: Keyword.get(opts, :parent_id),
        timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
      }
    end

    @doc "Create a custom entry"
    def custom(custom_type, data, opts \\ []) do
      %__MODULE__{
        type: :custom,
        custom_type: custom_type,
        data: data,
        id: Keyword.get(opts, :id),
        parent_id: Keyword.get(opts, :parent_id),
        timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
      }
    end

    @doc "Create a custom message entry"
    def custom_message(custom_type, content, opts \\ []) do
      %__MODULE__{
        type: :custom_message,
        custom_type: custom_type,
        content: content,
        display: Keyword.get(opts, :display),
        details: Keyword.get(opts, :details),
        id: Keyword.get(opts, :id),
        parent_id: Keyword.get(opts, :parent_id),
        timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
      }
    end
  end

  defmodule Session do
    @moduledoc "Session state containing entries and navigation state"
    @type t :: %__MODULE__{
            header: SessionHeader.t(),
            entries: [SessionEntry.t()],
            by_id: %{String.t() => SessionEntry.t()},
            leaf_id: String.t() | nil
          }
    defstruct header: %SessionHeader{},
              entries: [],
              by_id: %{},
              leaf_id: nil
  end

  # ============================================================================
  # Core Functions
  # ============================================================================

  @doc """
  Create a new session state with header.

  ## Options

  - `:id` - Session ID (auto-generated if not provided)
  - `:parent_session` - ID of parent session for forking
  """
  @spec new(String.t(), keyword()) :: Session.t()
  def new(cwd, opts \\ []) do
    header = %SessionHeader{
      type: :session,
      version: @current_version,
      id: Keyword.get(opts, :id) || generate_session_id(),
      timestamp: System.system_time(:millisecond),
      cwd: cwd,
      parent_session: Keyword.get(opts, :parent_session)
    }

    %Session{
      header: header,
      entries: [],
      by_id: %{},
      leaf_id: nil
    }
  end

  @doc """
  Load and parse JSONL session file, applying migrations.

  Returns `{:ok, session}` or `{:error, reason}`.
  """
  @spec load_from_file(String.t()) :: {:ok, Session.t()} | {:error, term()}
  def load_from_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, {header, entries}} <- parse_jsonl(content),
         {:ok, migrated_entries} <- migrate_to_current_version(header.version, entries) do
      by_id = Map.new(migrated_entries, fn entry -> {entry.id, entry} end)
      leaf_id = find_latest_leaf(migrated_entries)

      {:ok,
       %Session{
         header: %{header | version: @current_version},
         entries: migrated_entries,
         by_id: by_id,
         leaf_id: leaf_id
       }}
    end
  end

  @doc """
  Write session to JSONL file.
  """
  @spec save_to_file(String.t(), Session.t()) :: :ok | {:error, term()}
  def save_to_file(path, %Session{} = session) do
    # Ensure directory exists
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    lines =
      [encode_header(session.header) | Enum.map(session.entries, &encode_entry/1)]
      |> Enum.join("\n")

    File.write(path, lines <> "\n")
  end

  @doc """
  Add entry with auto-generated id, set parent_id to current leaf.
  """
  @spec append_entry(Session.t(), SessionEntry.t()) :: Session.t()
  def append_entry(%Session{} = session, %SessionEntry{} = entry) do
    existing_ids = Map.keys(session.by_id)
    new_id = entry.id || generate_id(existing_ids)
    parent_id = entry.parent_id || session.leaf_id

    entry = %{entry | id: new_id, parent_id: parent_id}

    %{
      session
      | entries: session.entries ++ [entry],
        by_id: Map.put(session.by_id, new_id, entry),
        leaf_id: new_id
    }
  end

  @doc """
  Convenience function for appending message entries.
  """
  @spec append_message(Session.t(), map()) :: Session.t()
  def append_message(%Session{} = session, message) do
    entry = SessionEntry.message(message)
    append_entry(session, entry)
  end

  @doc """
  Add compaction entry.
  """
  @spec append_compaction(Session.t(), String.t(), String.t(), non_neg_integer(), map() | nil) ::
          Session.t()
  def append_compaction(
        %Session{} = session,
        summary,
        first_kept_entry_id,
        tokens_before,
        details \\ nil
      ) do
    entry = SessionEntry.compaction(summary, first_kept_entry_id, tokens_before, details: details)
    append_entry(session, entry)
  end

  # ============================================================================
  # Tree Operations
  # ============================================================================

  @doc """
  Get current leaf entry id (nil if at root).
  """
  @spec get_leaf_id(Session.t()) :: String.t() | nil
  def get_leaf_id(%Session{leaf_id: leaf_id}), do: leaf_id

  @doc """
  Navigate to different point in tree.
  """
  @spec set_leaf_id(Session.t(), String.t() | nil) :: Session.t()
  def set_leaf_id(%Session{} = session, id) do
    %{session | leaf_id: id}
  end

  @doc """
  Walk from leaf to root, return path (ordered from root to leaf).
  """
  @spec get_branch(Session.t(), String.t() | nil) :: [SessionEntry.t()]
  def get_branch(%Session{} = session, leaf_id \\ nil) do
    target_id = leaf_id || session.leaf_id
    walk_to_root(session.by_id, target_id, [])
  end

  defp walk_to_root(_by_id, nil, acc), do: acc

  defp walk_to_root(by_id, id, acc) do
    case Map.get(by_id, id) do
      nil -> acc
      entry -> walk_to_root(by_id, entry.parent_id, [entry | acc])
    end
  end

  @doc """
  Look up entry by id.
  """
  @spec get_entry(Session.t(), String.t()) :: SessionEntry.t() | nil
  def get_entry(%Session{by_id: by_id}, id) do
    Map.get(by_id, id)
  end

  @doc """
  Get all direct children of an entry.
  """
  @spec get_children(Session.t(), String.t() | nil) :: [SessionEntry.t()]
  def get_children(%Session{entries: entries}, parent_id) do
    Enum.filter(entries, fn entry -> entry.parent_id == parent_id end)
  end

  # ============================================================================
  # Context Building
  # ============================================================================

  @doc """
  Build messages list for LLM.

  Walks from leaf to root to get path, finds latest compaction entry in path.
  If compaction exists: emit summary first, then kept entries.
  Extracts thinking_level and model from path.

  Returns `%{messages: [...], thinking_level: atom, model: %{provider: str, model_id: str} | nil}`
  """
  @spec build_session_context(Session.t(), String.t() | nil) :: %{
          messages: [map()],
          thinking_level: atom(),
          model: %{provider: String.t(), model_id: String.t()} | nil
        }
  def build_session_context(%Session{} = session, leaf_id \\ nil) do
    branch = get_branch(session, leaf_id)

    # Find latest compaction entry in path
    {compaction_entry, compaction_index} =
      branch
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _idx} -> entry.type == :compaction end)
      |> List.last()
      |> case do
        nil -> {nil, -1}
        {entry, idx} -> {entry, idx}
      end

    # Build messages
    messages =
      if compaction_entry do
        # Find where to start based on first_kept_entry_id
        kept_start_idx =
          Enum.find_index(branch, fn entry ->
            entry.id == compaction_entry.first_kept_entry_id
          end) || compaction_index + 1

        # Summary message + kept entries
        summary_msg = %{
          "role" => "user",
          "content" => "[Conversation summary: #{compaction_entry.summary}]"
        }

        kept_entries =
          branch
          |> Enum.drop(kept_start_idx)
          |> extract_messages()

        [summary_msg | kept_entries]
      else
        extract_messages(branch)
      end

    # Extract thinking level (find latest thinking_level_change)
    thinking_level =
      branch
      |> Enum.filter(fn entry -> entry.type == :thinking_level_change end)
      |> List.last()
      |> case do
        nil -> :off
        entry -> entry.thinking_level || :off
      end

    # Extract model (find latest model_change)
    model =
      branch
      |> Enum.filter(fn entry -> entry.type == :model_change end)
      |> List.last()
      |> case do
        nil -> nil
        entry -> %{provider: entry.provider, model_id: entry.model_id}
      end

    %{
      messages: messages,
      thinking_level: thinking_level,
      model: model
    }
  end

  defp extract_messages(entries) do
    entries
    |> Enum.filter(fn entry -> entry.type in [:message, :custom_message, :branch_summary] end)
    |> Enum.map(&entry_to_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp entry_to_message(%{type: :message, message: message}), do: message

  defp entry_to_message(%{type: :custom_message} = entry) do
    %{
      "role" => "custom",
      "custom_type" => entry.custom_type,
      "content" => entry.content,
      "display" => if(is_nil(entry.display), do: true, else: entry.display),
      "details" => entry.details,
      "timestamp" => entry.timestamp
    }
  end

  defp entry_to_message(%{type: :branch_summary} = entry) do
    %{
      "role" => "branch_summary",
      "summary" => entry.summary,
      "from_id" => entry.from_id,
      "timestamp" => entry.timestamp
    }
  end

  defp entry_to_message(_), do: nil

  # ============================================================================
  # Migrations
  # ============================================================================

  @doc """
  Apply migrations from version to current version.
  """
  @spec migrate_to_current_version(pos_integer(), [map()]) ::
          {:ok, [SessionEntry.t()]} | {:error, term()}
  def migrate_to_current_version(version, entries) when version >= @current_version do
    {:ok, Enum.map(entries, &map_to_entry/1)}
  end

  def migrate_to_current_version(1, entries) do
    # v1 -> v2: Add id/parentId to entries, convert compaction index to id
    entries_with_ids = add_ids_to_entries(entries)
    migrate_to_current_version(2, entries_with_ids)
  end

  def migrate_to_current_version(2, entries) do
    # v2 -> v3: Rename "hookMessage" role to "custom"
    migrated =
      Enum.map(entries, fn entry ->
        case entry do
          %{"message" => %{"role" => "hookMessage"} = msg} = e ->
            %{e | "message" => %{msg | "role" => "custom"}}

          other ->
            other
        end
      end)

    migrate_to_current_version(3, migrated)
  end

  defp add_ids_to_entries(entries) do
    {migrated, _last_id, _ids} =
      Enum.reduce(entries, {[], nil, MapSet.new()}, fn entry, {acc, parent_id, ids} ->
        new_id = generate_id(MapSet.to_list(ids))

        entry_with_id =
          entry
          |> Map.put("id", new_id)
          |> Map.put("parentId", parent_id)
          |> maybe_migrate_compaction_index(acc)

        {acc ++ [entry_with_id], new_id, MapSet.put(ids, new_id)}
      end)

    migrated
  end

  defp maybe_migrate_compaction_index(
         %{"type" => "compaction", "firstKeptEntryIndex" => idx} = entry,
         previous_entries
       )
       when is_integer(idx) do
    # Find the entry at that index and use its id
    case Enum.at(previous_entries, idx) do
      %{"id" => id} ->
        entry
        |> Map.put("firstKeptEntryId", id)
        |> Map.delete("firstKeptEntryIndex")

      _ ->
        Map.delete(entry, "firstKeptEntryIndex")
    end
  end

  defp maybe_migrate_compaction_index(entry, _previous), do: entry

  defp map_to_entry(map) when is_map(map) do
    type = parse_entry_type(map["type"])

    %SessionEntry{
      id: map["id"],
      parent_id: map["parentId"],
      timestamp: map["timestamp"],
      type: type,
      message: map["message"],
      thinking_level: parse_thinking_level(map["thinkingLevel"]),
      provider: map["provider"],
      model_id: map["modelId"],
      summary: map["summary"],
      first_kept_entry_id: map["firstKeptEntryId"],
      tokens_before: map["tokensBefore"],
      details: map["details"],
      from_hook: map["fromHook"],
      from_id: map["fromId"],
      target_id: map["targetId"],
      label: map["label"],
      name: map["name"],
      custom_type: map["customType"],
      data: map["data"],
      content: map["content"],
      display: map["display"]
    }
  end

  defp parse_entry_type("message"), do: :message
  defp parse_entry_type("thinkingLevelChange"), do: :thinking_level_change
  defp parse_entry_type("modelChange"), do: :model_change
  defp parse_entry_type("compaction"), do: :compaction
  defp parse_entry_type("branchSummary"), do: :branch_summary
  defp parse_entry_type("label"), do: :label
  defp parse_entry_type("sessionInfo"), do: :session_info
  defp parse_entry_type("custom"), do: :custom
  defp parse_entry_type("customMessage"), do: :custom_message
  defp parse_entry_type(_), do: :custom

  defp parse_thinking_level(nil), do: nil
  defp parse_thinking_level("off"), do: :off
  defp parse_thinking_level("minimal"), do: :minimal
  defp parse_thinking_level("low"), do: :low
  defp parse_thinking_level("medium"), do: :medium
  defp parse_thinking_level("high"), do: :high
  defp parse_thinking_level("xhigh"), do: :xhigh
  defp parse_thinking_level(level) when is_atom(level), do: level
  defp parse_thinking_level(_), do: :off

  # ============================================================================
  # ID Generation
  # ============================================================================

  @doc """
  Generate 8-char hex ID, collision-checked.
  """
  @spec generate_id([String.t()]) :: String.t()
  def generate_id(existing_ids) when is_list(existing_ids) do
    existing_set = MapSet.new(existing_ids)
    generate_unique_id(existing_set)
  end

  defp generate_unique_id(existing_set) do
    id = :crypto.strong_rand_bytes(@id_length) |> Base.encode16(case: :lower) |> binary_part(0, 8)

    if MapSet.member?(existing_set, id) do
      generate_unique_id(existing_set)
    else
      id
    end
  end

  defp generate_session_id do
    UUID.uuid4()
  end

  # ============================================================================
  # File Path Helpers
  # ============================================================================

  @doc """
  Encode path for session directory name.

  Delegates to `CodingAgent.Config.encode_cwd/1` to ensure consistent encoding
  across the codebase.
  """
  @spec encode_cwd(String.t()) :: String.t()
  defdelegate encode_cwd(cwd), to: CodingAgent.Config

  @doc """
  Get ~/.lemon/agent/sessions/{encoded-cwd}/

  Delegates to `CodingAgent.Config.sessions_dir/1` to ensure consistent path
  resolution across the codebase.
  """
  @spec get_session_dir(String.t()) :: String.t()
  defdelegate get_session_dir(cwd), to: CodingAgent.Config, as: :sessions_dir

  @doc """
  List all sessions for a cwd with metadata.

  Returns a list of maps with `:path`, `:id`, `:timestamp`, and `:cwd`.
  """
  @spec list_sessions(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_sessions(cwd) do
    session_dir = get_session_dir(cwd)

    case File.ls(session_dir) do
      {:ok, files} ->
        sessions =
          files
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.map(fn file ->
            path = Path.join(session_dir, file)
            load_session_metadata(path)
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.timestamp, :desc)

        {:ok, sessions}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_session_metadata(path) do
    case File.open(path, [:read, :utf8]) do
      {:ok, file} ->
        first_line = IO.read(file, :line)
        File.close(file)

        case Jason.decode(first_line) do
          {:ok, %{"type" => "session"} = header} ->
            %{
              path: path,
              id: header["id"],
              timestamp: header["timestamp"],
              cwd: header["cwd"]
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  # ============================================================================
  # JSONL Parsing and Encoding
  # ============================================================================

  defp parse_jsonl(content) do
    lines =
      content
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == ""))

    case lines do
      [] ->
        {:error, :empty_file}

      [header_line | entry_lines] ->
        with {:ok, header_data} <- Jason.decode(header_line),
             {:ok, header} <- parse_header(header_data),
             {:ok, entries} <- parse_entries(entry_lines) do
          {:ok, {header, entries}}
        end
    end
  end

  defp parse_header(%{"type" => "session"} = data) do
    header = %SessionHeader{
      type: :session,
      version: data["version"] || 1,
      id: data["id"],
      timestamp: data["timestamp"],
      cwd: data["cwd"],
      parent_session: data["parentSession"]
    }

    {:ok, header}
  end

  defp parse_header(_), do: {:error, :invalid_header}

  defp parse_entries(lines) do
    entries =
      Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
        case Jason.decode(line) do
          {:ok, data} -> {:cont, {:ok, acc ++ [data]}}
          {:error, reason} -> {:halt, {:error, {:json_parse_error, reason, line}}}
        end
      end)

    entries
  end

  defp encode_header(%SessionHeader{} = header) do
    %{
      "type" => "session",
      "version" => header.version,
      "id" => header.id,
      "timestamp" => header.timestamp,
      "cwd" => header.cwd,
      "parentSession" => header.parent_session
    }
    |> reject_nil_values()
    |> json_safe()
    |> Jason.encode!()
  end

  defp encode_entry(%SessionEntry{} = entry) do
    base = %{
      "id" => entry.id,
      "parentId" => entry.parent_id,
      "timestamp" => entry.timestamp,
      "type" => encode_entry_type(entry.type)
    }

    type_fields =
      case entry.type do
        :message ->
          %{"message" => entry.message}

        :thinking_level_change ->
          %{"thinkingLevel" => encode_thinking_level(entry.thinking_level)}

        :model_change ->
          %{"provider" => entry.provider, "modelId" => entry.model_id}

        :compaction ->
          %{
            "summary" => entry.summary,
            "firstKeptEntryId" => entry.first_kept_entry_id,
            "tokensBefore" => entry.tokens_before,
            "details" => entry.details,
            "fromHook" => entry.from_hook
          }

        :branch_summary ->
          %{
            "fromId" => entry.from_id,
            "summary" => entry.summary,
            "details" => entry.details,
            "fromHook" => entry.from_hook
          }

        :label ->
          %{"targetId" => entry.target_id, "label" => entry.label}

        :session_info ->
          %{"name" => entry.name}

        :custom ->
          %{"customType" => entry.custom_type, "data" => entry.data}

        :custom_message ->
          %{
            "customType" => entry.custom_type,
            "content" => entry.content,
            "display" => entry.display,
            "details" => entry.details
          }
      end

    base
    |> Map.merge(type_fields)
    |> reject_nil_values()
    |> json_safe()
    |> Jason.encode!()
  end

  defp encode_entry_type(:message), do: "message"
  defp encode_entry_type(:thinking_level_change), do: "thinkingLevelChange"
  defp encode_entry_type(:model_change), do: "modelChange"
  defp encode_entry_type(:compaction), do: "compaction"
  defp encode_entry_type(:branch_summary), do: "branchSummary"
  defp encode_entry_type(:label), do: "label"
  defp encode_entry_type(:session_info), do: "sessionInfo"
  defp encode_entry_type(:custom), do: "custom"
  defp encode_entry_type(:custom_message), do: "customMessage"

  defp encode_thinking_level(nil), do: nil
  defp encode_thinking_level(:off), do: "off"
  defp encode_thinking_level(:minimal), do: "minimal"
  defp encode_thinking_level(:low), do: "low"
  defp encode_thinking_level(:medium), do: "medium"
  defp encode_thinking_level(:high), do: "high"
  defp encode_thinking_level(:xhigh), do: "xhigh"

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Jason can't encode arbitrary structs by default (it falls back to Jason.Encoder.Any which raises).
  # Session persistence should never crash due to "details" containing richer runtime structs.
  @json_safe_structs [
    AgentCore.Types.AgentToolResult,
    Ai.Types.TextContent,
    Ai.Types.ThinkingContent,
    Ai.Types.ImageContent,
    Ai.Types.ToolCall,
    Ai.Types.UserMessage,
    Ai.Types.AssistantMessage,
    Ai.Types.ToolResultMessage,
    Ai.Types.Usage,
    Ai.Types.Cost
  ]

  defp json_safe(%_{} = term) do
    # If the protocol dispatch would go to Jason.Encoder.Any, it will raise; convert to map instead.
    case Jason.Encoder.impl_for(term) do
      Jason.Encoder.Any ->
        # Only expand known-safe "data" structs. For everything else, store an inspect string
        # so we don't accidentally persist secrets from unrelated structs.
        if term.__struct__ in @json_safe_structs do
          term
          |> Map.from_struct()
          |> Map.delete(:__struct__)
          |> json_safe()
        else
          inspect(term)
        end

      _impl ->
        term
    end
  end

  defp json_safe(term) when is_map(term) do
    term
    |> Enum.map(fn {k, v} -> {json_safe_key(k), json_safe(v)} end)
    |> Map.new()
  end

  defp json_safe(term) when is_list(term), do: Enum.map(term, &json_safe/1)
  defp json_safe(term) when is_tuple(term), do: term |> Tuple.to_list() |> json_safe()
  defp json_safe(%MapSet{} = term), do: term |> MapSet.to_list() |> json_safe()

  defp json_safe(term)
       when is_pid(term) or is_port(term) or is_reference(term) or is_function(term),
       do: inspect(term)

  defp json_safe(term), do: term

  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key), do: inspect(key)

  # Find the latest entry that has no children (a leaf node)
  defp find_latest_leaf([]), do: nil

  defp find_latest_leaf(entries) do
    # Get all ids that are referenced as parent_id
    parent_ids = MapSet.new(entries, & &1.parent_id)

    # Find entries that are not parents (leaves)
    leaves = Enum.filter(entries, fn entry -> not MapSet.member?(parent_ids, entry.id) end)

    # Return the last leaf (most recently added)
    case List.last(leaves) do
      nil -> List.last(entries) && List.last(entries).id
      entry -> entry.id
    end
  end
end
