# Batch dependency runner

`bash run_plan.sh PLAN JOBS RESULTS` runs shell jobs from a TSV plan and keeps separate logs. `plan.sh` is the plan-loading library. Dependencies may refer to later rows; independent work should still run after failures. Status files are consumed by a deployment dashboard. Run `python3 -m unittest discover -s tests`.
