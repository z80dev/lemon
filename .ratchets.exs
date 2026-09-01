# Quality ratchets. Each value is the highest measurement `mix lemon.quality`
# accepts for that metric; LemonCore.Quality.RatchetCheck says what is counted.
# `mix lemon.ratchet --update` lowers a value to the current measurement and
# never raises one. Raising a value is a deliberate edit that needs a reason
# in the commit message.
%{
  # lines in apps/*/lib/**/*.ex
  lib_lines: 337815,
  # lib files over 1000 lines, excluding the lemon_ai model catalogs
  large_lib_files: 50,
  # :"Elixir.Some.Module" atoms in lib
  dynamic_module_atoms: 1,
  # Code.ensure_loaded?/1 and function_exported?/3 calls in lib
  reflection_sites: 295,
  # rescue clauses in lib
  rescue_clauses: 1130,
  # catch clauses in lib
  catch_clauses: 381,
  # distinct tables named in generic LemonCore.Store calls outside Store.Table modules
  generic_store_tables: 66,
  # *_store.ex modules in lib
  store_wrapper_modules: 48,
  # source-pattern rules in LemonCore.Quality.ArchitectureRulesCheck
  architecture_rules: 33,
  # Process.sleep/1 and :timer.sleep/1 calls in tests
  test_sleeps: 1222,
  # *_test.exs files that are not async: true
  sync_test_files: 563,
  # bytes across apps/*/AGENTS.md
  agents_md_bytes: 440828
}
