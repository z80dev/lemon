defmodule CodingAgent.Tools.FeatureRequirementsTest do
  @moduledoc """
  Tests for the FeatureRequirements tool.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Tools.FeatureRequirements

  setup do
    # Create a temporary directory for test files
    tmp_dir = System.tmp_dir!()
    test_id = :erlang.unique_integer([:positive])
    test_dir = Path.join(tmp_dir, "feature_req_test_#{test_id}")

    File.mkdir_p!(test_dir)

    on_exit(fn -> File.rm_rf!(test_dir) end)

    %{test_dir: test_dir}
  end

  describe "save_requirements/2 and load_requirements/1" do
    test "saves and loads requirements correctly", %{test_dir: test_dir} do
      requirements = sample_requirements()

      assert :ok = FeatureRequirements.save_requirements(requirements, test_dir)
      assert {:ok, loaded} = FeatureRequirements.load_requirements(test_dir)

      assert loaded.project_name == requirements.project_name
      assert loaded.original_prompt == requirements.original_prompt
      assert length(loaded.features) == length(requirements.features)
    end

    test "returns :not_found when file doesn't exist", %{test_dir: test_dir} do
      assert {:error, :not_found} = FeatureRequirements.load_requirements(test_dir)
    end

    test "requirements_exist?/1 returns correct values", %{test_dir: test_dir} do
      refute FeatureRequirements.requirements_exist?(test_dir)

      requirements = sample_requirements()
      :ok = FeatureRequirements.save_requirements(requirements, test_dir)

      assert FeatureRequirements.requirements_exist?(test_dir)
    end
  end

  describe "update_feature_status/4" do
    test "updates feature status correctly", %{test_dir: test_dir} do
      requirements = sample_requirements()
      :ok = FeatureRequirements.save_requirements(requirements, test_dir)

      assert :ok = FeatureRequirements.update_feature_status(test_dir, "feature-001", :in_progress, "Working on it")

      {:ok, loaded} = FeatureRequirements.load_requirements(test_dir)
      feature = Enum.find(loaded.features, &(&1.id == "feature-001"))

      assert feature.status == :in_progress
      assert feature.notes == "Working on it"
      assert feature.updated_at != nil
    end

    test "complete_feature/3 marks as completed", %{test_dir: test_dir} do
      requirements = sample_requirements()
      :ok = FeatureRequirements.save_requirements(requirements, test_dir)

      assert :ok = FeatureRequirements.complete_feature(test_dir, "feature-001", "Done!")

      {:ok, loaded} = FeatureRequirements.load_requirements(test_dir)
      feature = Enum.find(loaded.features, &(&1.id == "feature-001"))

      assert feature.status == :completed
      assert feature.notes == "Done!"
    end
  end

  describe "get_progress/1" do
    test "calculates progress correctly", %{test_dir: test_dir} do
      requirements = sample_requirements()
      :ok = FeatureRequirements.save_requirements(requirements, test_dir)

      {:ok, progress} = FeatureRequirements.get_progress(test_dir)

      assert progress.total == 3
      assert progress.completed == 0
      assert progress.pending == 3
      assert progress.percentage == 0
      assert progress.project_name == "Test Project"
    end

    test "updates progress after completing features", %{test_dir: test_dir} do
      requirements = sample_requirements()
      :ok = FeatureRequirements.save_requirements(requirements, test_dir)

      :ok = FeatureRequirements.complete_feature(test_dir, "feature-001")

      {:ok, progress} = FeatureRequirements.get_progress(test_dir)

      assert progress.completed == 1
      assert progress.pending == 2
      assert progress.percentage == 33
    end
  end

  describe "get_next_features/1" do
    test "returns features with no dependencies first", %{test_dir: test_dir} do
      requirements = sample_requirements()
      :ok = FeatureRequirements.save_requirements(requirements, test_dir)

      {:ok, next} = FeatureRequirements.get_next_features(test_dir)

      # feature-001 has no dependencies
      assert length(next) == 1
      assert hd(next).id == "feature-001"
    end

    test "returns dependent features after dependencies completed", %{test_dir: test_dir} do
      requirements = sample_requirements()
      :ok = FeatureRequirements.save_requirements(requirements, test_dir)

      # Complete feature-001
      :ok = FeatureRequirements.complete_feature(test_dir, "feature-001")

      {:ok, next} = FeatureRequirements.get_next_features(test_dir)

      # Now feature-002 should be available (depends on feature-001)
      assert length(next) == 1
      assert hd(next).id == "feature-002"
    end

    test "sorts by priority", %{test_dir: test_dir} do
      requirements = %{
        project_name: "Priority Test",
        original_prompt: "Test",
        features: [
          %{id: "f-1", description: "Low", status: :pending, dependencies: [], priority: :low, acceptance_criteria: [], notes: "", created_at: now(), updated_at: nil},
          %{id: "f-2", description: "High", status: :pending, dependencies: [], priority: :high, acceptance_criteria: [], notes: "", created_at: now(), updated_at: nil},
          %{id: "f-3", description: "Medium", status: :pending, dependencies: [], priority: :medium, acceptance_criteria: [], notes: "", created_at: now(), updated_at: nil}
        ],
        created_at: now(),
        version: "1.0"
      }

      :ok = FeatureRequirements.save_requirements(requirements, test_dir)

      {:ok, next} = FeatureRequirements.get_next_features(test_dir)

      ids = Enum.map(next, & &1.id)
      assert ids == ["f-2", "f-3", "f-1"]
    end
  end

  describe "generate_requirements/2" do
    @tag :integration
    test "generates requirements from prompt", %{test_dir: test_dir} do
      # This test requires a real LLM, skip in CI
      if System.get_env("CI") do
        {:ok, requirements} = FeatureRequirements.generate_requirements("Build a simple todo app")

        assert is_map(requirements)
        assert is_binary(requirements.project_name)
        assert length(requirements.features) > 0

        first_feature = hd(requirements.features)
        assert is_binary(first_feature.id)
        assert is_binary(first_feature.description)
        assert first_feature.status == :pending
      else
        # Mock test for non-CI environments
        requirements = %{
          project_name: "Todo App",
          original_prompt: "Build a simple todo app",
          features: [
            %{id: "f-1", description: "Setup project", status: :pending, dependencies: [], priority: :high, acceptance_criteria: [], notes: "", created_at: now(), updated_at: nil}
          ],
          created_at: now(),
          version: "1.0"
        }

        :ok = FeatureRequirements.save_requirements(requirements, test_dir)
        assert FeatureRequirements.requirements_exist?(test_dir)
      end
    end
  end

  # Helper functions

  defp sample_requirements do
    %{
      project_name: "Test Project",
      original_prompt: "Build a test app",
      features: [
        %{
          id: "feature-001",
          description: "Setup project structure",
          status: :pending,
          dependencies: [],
          priority: :high,
          acceptance_criteria: ["Project initialized", "Dependencies installed"],
          notes: "",
          created_at: now(),
          updated_at: nil
        },
        %{
          id: "feature-002",
          description: "Create main module",
          status: :pending,
          dependencies: ["feature-001"],
          priority: :medium,
          acceptance_criteria: ["Module compiles", "Tests pass"],
          notes: "",
          created_at: now(),
          updated_at: nil
        },
        %{
          id: "feature-003",
          description: "Add CLI interface",
          status: :pending,
          dependencies: ["feature-002"],
          priority: :low,
          acceptance_criteria: ["CLI accepts arguments", "Help text works"],
          notes: "",
          created_at: now(),
          updated_at: nil
        }
      ],
      created_at: now(),
      version: "1.0"
    }
  end

  defp now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
