# The live suite drives real apps through the installed LCU runtime; it runs
# only when asked for with `--include computer_use_live` (desktop) or
# `--include computer_use_chrome_live` (Chrome).
ExUnit.start(capture_log: true, exclude: [:computer_use_live, :computer_use_chrome_live])
