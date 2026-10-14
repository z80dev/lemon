defmodule Mix.Tasks.Lemon.Eval.Coding do
  use Mix.Task

  @shortdoc "Run the opt-in live production-CLI coding benchmark"
  @moduledoc """
  Runs twelve real coding tasks in temporary git repositories through `lemon -p`.
  The repeated --paired lane writes an offline plan unless --live and an exact
  operator-approved bounded plan are supplied; live attempts boot fresh runtimes.
  Does not start umbrella applications in this Mix VM.

      mix lemon.eval.coding --output /tmp/lemon-coding-benchmark.json

  Options include --model, --lemon, --output, --timeout, --paired, --repetitions,
  --seed, --config, --run-timeout, --plan, --approve-plan-digest, --live,
  --profile-python and --schema-budgets. Live work is excluded from fast checks.
  """

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          model: :string,
          lemon: :string,
          output: :string,
          timeout: :integer,
          failure_dir: :string,
          compare_omp: :boolean,
          omp: :string,
          omp_model: :string,
          tasks: :string,
          paired: :boolean,
          repetitions: :integer,
          seed: :integer,
          config: :string,
          run_timeout: :integer,
          plan: :string,
          approve_plan_digest: :string,
          live: :boolean,
          schema_budgets: :string,
          profile_python: :string
        ]
      )

    if rest != [] or invalid != [], do: Mix.raise("Invalid coding benchmark arguments")

    paired_only = [
      :repetitions,
      :seed,
      :config,
      :run_timeout,
      :plan,
      :approve_plan_digest,
      :live,
      :schema_budgets,
      :profile_python
    ]

    if opts[:paired] != true and Enum.any?(paired_only, &Keyword.has_key?(opts, &1)),
      do: Mix.raise("Paired authorization/options require --paired")

    timeout = opts[:timeout] || 660
    if timeout <= 0, do: Mix.raise("--timeout must be positive")
    python = System.find_executable("python3") || Mix.raise("python3 is required")
    launcher = Path.expand(opts[:lemon] || "bin/lemon")
    script = Path.join(:code.priv_dir(:lemon_evals), "coding_benchmark.py")

    argv = [
      script,
      "--lemon",
      launcher,
      "--model",
      opts[:model] || "openai-codex:gpt-6.1-sol",
      "--output",
      Path.expand(opts[:output] || "/tmp/lemon-coding-benchmark.json"),
      "--timeout",
      Integer.to_string(timeout)
    ]

    argv =
      if opts[:failure_dir],
        do: argv ++ ["--failure-dir", Path.expand(opts[:failure_dir])],
        else: argv

    argv = if opts[:compare_omp], do: argv ++ ["--compare-omp"], else: argv
    argv = if opts[:paired], do: argv ++ ["--paired"], else: argv
    argv = if opts[:live], do: argv ++ ["--live"], else: argv

    argv =
      Enum.reduce(
        [
          {:omp, "--omp"},
          {:omp_model, "--omp-model"},
          {:tasks, "--tasks"},
          {:repetitions, "--repetitions"},
          {:seed, "--seed"},
          {:config, "--config"},
          {:run_timeout, "--run-timeout"},
          {:plan, "--plan"},
          {:approve_plan_digest, "--approve-plan-digest"},
          {:schema_budgets, "--schema-budgets"},
          {:profile_python, "--profile-python"}
        ],
        argv,
        fn {key, flag}, current ->
          if opts[key], do: current ++ [flag, to_string(opts[key])], else: current
        end
      )

    {_output, status} =
      System.cmd(python, argv, into: IO.stream(:stdio, :line), stderr_to_stdout: true)

    if status != 0, do: Mix.raise("Live coding benchmark failed; inspect its result artifact")
  end
end
