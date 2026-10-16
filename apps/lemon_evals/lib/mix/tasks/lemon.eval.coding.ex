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
  --profile-python. Live work is excluded from fast checks.

  `--campaign` runs the resumable multi-provider baseline/coding paired campaign
  (see the app README): --providers, --variants, --repetitions, --timeout,
  --control-plane-port, --output-dir, --resume, plus --seed, --config, --tasks and
  --profile-python. Without --live it only writes a plan; with --live it calls
  the named providers using only their own credential variable.

      mix lemon.eval.coding --campaign --live --resume --output-dir /OPERATOR/PATH/campaign
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
          profile_python: :string,
          campaign: :boolean,
          providers: :string,
          variants: :string,
          control_plane_port: :integer,
          output_dir: :string,
          resume: :boolean
        ]
      )

    if rest != [] or invalid != [], do: Mix.raise("Invalid coding benchmark arguments")

    validate_lane!(opts)

    timeout = opts[:timeout] || 660
    if timeout <= 0, do: Mix.raise("--timeout must be positive")
    python = System.find_executable("python3") || Mix.raise("python3 is required")
    launcher = Path.expand(opts[:lemon] || "bin/lemon")
    script = Path.join(:code.priv_dir(:lemon_evals), "coding_benchmark.py")

    argv =
      if opts[:campaign] == true,
        do: campaign_argv(opts, script, launcher, timeout),
        else: benchmark_argv(opts, script, launcher, timeout)

    {_output, status} =
      System.cmd(python, argv, into: IO.stream(:stdio, :line), stderr_to_stdout: true)

    if status != 0, do: Mix.raise("Live coding benchmark failed; inspect its result artifact")
  end

  @paired_only [
    :repetitions,
    :seed,
    :config,
    :run_timeout,
    :plan,
    :approve_plan_digest,
    :live,
    :profile_python
  ]
  @campaign_only [:providers, :variants, :control_plane_port, :output_dir, :resume]
  @campaign_excluded [
    :paired,
    :compare_omp,
    :omp,
    :omp_model,
    :output,
    :model,
    :failure_dir,
    :run_timeout,
    :plan,
    :approve_plan_digest
  ]

  # Paired and campaign options can never fall through to the nonpaired paid lane.
  defp validate_lane!(opts) do
    has? = fn keys -> Enum.any?(keys, &Keyword.has_key?(opts, &1)) end

    cond do
      opts[:campaign] == true and has?.(@campaign_excluded) ->
        Mix.raise(
          "--campaign cannot be combined with paired, omp, --output, --model or --failure-dir options"
        )

      opts[:campaign] == true and opts[:output_dir] in [nil, ""] ->
        Mix.raise("--campaign requires --output-dir")

      opts[:campaign] == true ->
        :ok

      has?.(@campaign_only) ->
        Mix.raise("Campaign options require --campaign")

      opts[:paired] != true and has?.(@paired_only) ->
        Mix.raise("Paired authorization/options require --paired")

      true ->
        :ok
    end
  end

  defp campaign_argv(opts, script, launcher, timeout) do
    argv = [script, "--campaign", "--lemon", launcher, "--timeout", Integer.to_string(timeout)]
    argv = if opts[:live], do: argv ++ ["--live"], else: argv
    argv = if opts[:resume], do: argv ++ ["--resume"], else: argv
    argv = argv ++ ["--output-dir", Path.expand(opts[:output_dir])]

    Enum.reduce(
      [
        {:providers, "--providers"},
        {:variants, "--variants"},
        {:repetitions, "--repetitions"},
        {:seed, "--seed"},
        {:control_plane_port, "--control-plane-port"},
        {:tasks, "--tasks"},
        {:profile_python, "--profile-python"}
      ],
      argv,
      fn {key, flag}, current ->
        if opts[key], do: current ++ [flag, to_string(opts[key])], else: current
      end
    )
    |> then(fn current ->
      if opts[:config], do: current ++ ["--config", Path.expand(opts[:config])], else: current
    end)
  end

  defp benchmark_argv(opts, script, launcher, timeout) do
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
        {:profile_python, "--profile-python"}
      ],
      argv,
      fn {key, flag}, current ->
        if opts[key], do: current ++ [flag, to_string(opts[key])], else: current
      end
    )
  end
end
