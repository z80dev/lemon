# Quality ratchets. `mix lemon.ratchet --update` only lowers these values.
# Raising one requires an explicit edit and justification in code review.
%{
  # Elixir library files longer than 1000 physical lines
  large_lib_files: 73,
  # literal :"Elixir.Some.Module" atoms in library AST
  dynamic_module_atoms: 17,
  # Code.ensure_loaded/1, Code.ensure_loaded?/1, and function_exported?/3 calls in library AST
  reflection_calls: 349,
  # rescue clauses in library AST
  rescue_clauses: 1266,
  # catch clauses in library AST
  catch_clauses: 488,
  # library files whose basename ends in _store.ex
  store_wrapper_modules: 48,
  # Process.sleep/1 and :timer.sleep/1 calls in test AST
  test_sleep_calls: 1247
}
