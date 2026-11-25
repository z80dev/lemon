# Tests that shell out to Node are excluded (not skipped) on hosts without it.
exclude_tags = if System.find_executable("node"), do: [], else: [:node]

# Case-folding tests only run on a case-insensitive filesystem.
case_probe =
  Path.join(System.tmp_dir!(), "lemon-case-probe-#{System.unique_integer([:positive])}")

File.mkdir_p!(case_probe)
File.write!(Path.join(case_probe, "Probe"), "")
case_insensitive_fs? = File.exists?(Path.join(case_probe, "PROBE"))
File.rm_rf!(case_probe)

exclude_tags =
  if case_insensitive_fs?, do: exclude_tags, else: [:case_insensitive_fs | exclude_tags]

ExUnit.start(capture_log: true, exclude: exclude_tags)
