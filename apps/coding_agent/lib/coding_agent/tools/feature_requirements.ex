defmodule CodingAgent.Tools.FeatureRequirements do
  @moduledoc """
  Generates comprehensive feature requirements from user prompts.
  Creates structured checklist for agents to work through.

  This tool helps prevent agents from "one-shotting" projects by creating
  detailed feature requirements that serve as a roadmap for implementation.

  ## Usage

      # Generate requirements from a project description
      {:ok, requirements} = FeatureRequirements.generate_requirements(
        "Build a todo app with user authentication",
        model: Ai.Models.get_model(:anthropic, "claude-sonnet-4")
      )

      # Save to project directory
      :ok = FeatureRequirements.save_requirements(requirements, "/path/to/project")

      # Load and track progress
      {:ok, reqs} = FeatureRequirements.load_requirements("/path/to/project")
      {:ok, progress} = FeatureRequirements.get_progress("/path/to/project")
  """

  require Logger

  @requirements_filename "FEATURE_REQUIREMENTS.json"

  @type feature :: %{
          id: String.t(),
          description: String.t(),
          status: :pending | :in_progress | :completed | :failed,
          dependencies: [String.t()],
          priority: :high | :medium | :low,
          acceptance_criteria: [String.t()],
          notes: String.t(),
          created_at: String.t(),
          updated_at: String.t() | nil
        }

  @type requirements_file :: %{
          project_name: String.t(),
          original_prompt: String.t(),
          features: [feature()],
          created_at: String.t(),
          version: String.t()
        }

  @doc """
  Generate feature requirements from a user prompt using LLM.

  ## Parameters

    * `prompt` - The project description or user request
    * `opts` - Options:
      * `:model` - The AI model to use for generation
      * `:max_features` - Maximum number of features to generate (default: 50)

  ## Returns

    * `{:ok, requirements_file}` - The generated requirements
    * `{:error, reason}` - If generation fails

  ## Examples

      {:ok, reqs} = FeatureRequirements.generate_requirements(
        "Create a chat app with real-time messaging"
      )

      reqs.project_name
      # => "Real-Time Chat Application"

      length(reqs.features)
      # => 15
  """
  @spec generate_requirements(String.t(), keyword()) ::
          {:ok, requirements_file()} | {:error, term()}
  def generate_requirements(prompt, opts \\ []) when is_binary(prompt) do
    model = Keyword.get(opts, :model, default_model())
    max_features = Keyword.get(opts, :max_features, 50)

    system_prompt = build_system_prompt(max_features)

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: prompt}
    ]

    case call_llm(model, messages) do
      {:ok, response} ->
        parse_requirements_response(response, prompt)

      {:error, reason} ->
        Logger.warning("Failed to generate requirements: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Save requirements to a file in the project directory.

  ## Parameters

    * `requirements` - The requirements struct to save
    * `cwd` - The project working directory

  ## Returns

    * `:ok` - Successfully saved
    * `{:error, reason}` - If save fails
  """
  @spec save_requirements(requirements_file(), String.t()) :: :ok | {:error, term()}
  def save_requirements(requirements, cwd) when is_map(requirements) do
    path = Path.join(cwd, @requirements_filename)

    content = Jason.encode!(requirements, pretty: true)

    case File.write(path, content) do
      :ok ->
        Logger.debug("Saved requirements to #{path}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to save requirements: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Load requirements from project directory.

  ## Parameters

    * `cwd` - The project working directory

  ## Returns

    * `{:ok, requirements_file}` - The loaded requirements
    * `{:error, :not_found}` - If no requirements file exists
    * `{:error, reason}` - If loading/parsing fails
  """
  @spec load_requirements(String.t()) :: {:ok, requirements_file()} | {:error, term()}
  def load_requirements(cwd) do
    path = Path.join(cwd, @requirements_filename)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content, keys: :atoms!) do
          {:ok, data} -> {:ok, atomize_statuses(data)}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if a requirements file exists in the project directory.

  ## Parameters

    * `cwd` - The project working directory

  ## Returns

    * `true` - If requirements file exists
    * `false` - If not found
  """
  @spec requirements_exist?(String.t()) :: boolean()
  def requirements_exist?(cwd) do
    path = Path.join(cwd, @requirements_filename)
    File.exists?(path)
  end

  @doc """
  Update feature status in requirements file.

  ## Parameters

    * `cwd` - The project working directory
    * `feature_id` - The ID of the feature to update
    * `status` - The new status (:pending, :in_progress, :completed, :failed)
    * `notes` - Optional notes about the update

  ## Returns

    * `:ok` - Successfully updated
    * `{:error, reason}` - If update fails
  """
  @spec update_feature_status(String.t(), String.t(), atom(), String.t()) ::
          :ok | {:error, term()}
  def update_feature_status(cwd, feature_id, status, notes \\ "")
      when is_binary(feature_id) and status in [:pending, :in_progress, :completed, :failed] do
    with {:ok, requirements} <- load_requirements(cwd) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      updated_features =
        Enum.map(requirements.features, fn feature ->
          if feature.id == feature_id do
            feature
            |> Map.put(:status, status)
            |> Map.put(:updated_at, now)
            |> Map.put(:notes, notes)
          else
            feature
          end
        end)

      updated = %{requirements | features: updated_features}
      save_requirements(updated, cwd)
    end
  end

  @doc """
  Get progress statistics for requirements.

  ## Parameters

    * `cwd` - The project working directory

  ## Returns

    * `{:ok, stats}` - Progress statistics map
    * `{:error, reason}` - If loading fails

  ## Statistics Map

      %{
        total: integer(),
        completed: integer(),
        failed: integer(),
        in_progress: integer(),
        pending: integer(),
        percentage: integer(),
        project_name: String.t()
      }
  """
  @spec get_progress(String.t()) :: {:ok, map()} | {:error, term()}
  def get_progress(cwd) do
    with {:ok, requirements} <- load_requirements(cwd) do
      total = length(requirements.features)
      completed = Enum.count(requirements.features, &(&1.status == :completed))
      failed = Enum.count(requirements.features, &(&1.status == :failed))
      in_progress = Enum.count(requirements.features, &(&1.status == :in_progress))
      pending = Enum.count(requirements.features, &(&1.status == :pending))

      percentage = if total > 0, do: div(completed * 100, total), else: 0

      {:ok,
       %{
         total: total,
         completed: completed,
         failed: failed,
         in_progress: in_progress,
         pending: pending,
         percentage: percentage,
         project_name: requirements.project_name
       }}
    end
  end

  @doc """
  Get next actionable features (dependencies met, not started).

  Returns features that are:
  - Status is :pending or :in_progress
  - All dependencies have status :completed

  ## Parameters

    * `cwd` - The project working directory

  ## Returns

    * `{:ok, features}` - List of actionable features, sorted by priority
    * `{:error, reason}` - If loading fails
  """
  @spec get_next_features(String.t()) :: {:ok, [feature()]} | {:error, term()}
  def get_next_features(cwd) do
    with {:ok, requirements} <- load_requirements(cwd) do
      completed_ids =
        requirements.features
        |> Enum.filter(&(&1.status == :completed))
        |> Enum.map(& &1.id)

      priority_order = %{high: 0, medium: 1, low: 2}

      next =
        requirements.features
        |> Enum.filter(fn feature ->
          feature.status in [:pending, :in_progress] and
            Enum.all?(feature.dependencies, &(&1 in completed_ids))
        end)
        |> Enum.sort_by(&priority_order[&1.priority])

      {:ok, next}
    end
  end

  @doc """
  Mark a feature as completed.

  Convenience function that wraps `update_feature_status/4`.

  ## Parameters

    * `cwd` - The project working directory
    * `feature_id` - The ID of the feature to mark complete
    * `notes` - Optional completion notes

  ## Returns

    * `:ok` - Successfully updated
    * `{:error, reason}` - If update fails
  """
  @spec complete_feature(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def complete_feature(cwd, feature_id, notes \\ "") do
    update_feature_status(cwd, feature_id, :completed, notes)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_system_prompt(max_features) do
    """
    You are a requirements analyst specializing in breaking down projects into detailed, actionable features.

    Your task is to expand a user's project description into a comprehensive list of features.

    Guidelines:
    - Generate at most #{max_features} features
    - Each feature should be specific, testable, and implementable in one session
    - Include clear acceptance criteria for each feature
    - Identify dependencies between features
    - Assign priority (high/medium/low) based on critical path
    - Start all features as "pending" status

    Return ONLY valid JSON with this exact structure:
    {
      "project_name": "Human-readable project name",
      "features": [
        {
          "id": "feature-001",
          "description": "Clear, specific description of what to implement",
          "status": "pending",
          "dependencies": [],
          "priority": "high",
          "acceptance_criteria": [
            "Specific, testable criterion 1",
            "Specific, testable criterion 2"
          ],
          "notes": ""
        }
      ]
    }

    Feature ID format: feature-XXX (zero-padded, sequential)
    Priority levels: high (critical path), medium (important), low (nice to have)
    Dependencies: List of feature IDs that must be completed first

    Be thorough but practical. Focus on user-visible functionality.
    """
  end

  defp default_model do
    # Try to get a capable model, fall back to any available
    case Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514") do
      nil ->
        # Fall back to first available model
        Ai.Models.list_models()
        |> List.first()

      model ->
        model
    end
  end

  defp call_llm(nil, _messages) do
    {:error, :no_model_available}
  end

  defp call_llm(model, messages) do
    # Use the Ai module for chat completion
    context = %Ai.Types.Context{
      system_prompt: nil,
      messages: messages,
      tools: []
    }

    opts = [
      temperature: 0.3,
      max_tokens: 4000
    ]

    case Ai.chat(model, context, opts) do
      {:ok, %{content: content}} -> {:ok, content}
      {:ok, content} when is_binary(content) -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_requirements_response(response, original_prompt) do
    # Extract JSON from response (handle markdown code blocks)
    json_text =
      case Regex.run(~r/```json\s*(.*?)\s*```/s, response) do
        [_, content] -> content
        _ -> response
      end

    case Jason.decode(json_text) do
      {:ok, data} ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        # Ensure all required fields exist
        features =
          Enum.map(data["features"] || [], fn f ->
            %{
              id: f["id"] || generate_feature_id(),
              description: f["description"] || "",
              status: :pending,
              dependencies: f["dependencies"] || [],
              priority: parse_priority(f["priority"]),
              acceptance_criteria: f["acceptance_criteria"] || [],
              notes: f["notes"] || "",
              created_at: now,
              updated_at: nil
            }
          end)

        requirements = %{
          project_name: data["project_name"] || "Untitled Project",
          original_prompt: original_prompt,
          features: features,
          created_at: now,
          version: "1.0"
        }

        {:ok, requirements}

      {:error, reason} ->
        Logger.error("Failed to parse requirements JSON: #{inspect(reason)}")
        {:error, {:json_decode, reason}}
    end
  end

  defp parse_priority(nil), do: :medium
  defp parse_priority("high"), do: :high
  defp parse_priority("medium"), do: :medium
  defp parse_priority("low"), do: :low
  defp parse_priority(_), do: :medium

  defp generate_feature_id do
    "feature-" <> Integer.to_string(:erlang.unique_integer([:positive]))
  end

  defp atomize_statuses(data) do
    features =
      Enum.map(data.features, fn f ->
        %{
          id: f.id,
          description: f.description,
          status: String.to_existing_atom(f.status),
          dependencies: f.dependencies,
          priority: String.to_existing_atom(f.priority),
          acceptance_criteria: f.acceptance_criteria,
          notes: Map.get(f, :notes, ""),
          created_at: f.created_at,
          updated_at: Map.get(f, :updated_at)
        }
      end)

    %{data | features: features}
  end
end
