export function findCommand(input: string): string | undefined {
  return ['list', 'show', 'delete'].find(name => name === input);
}
export function runCli(argv: string[]): {code: number; output: string} {
  const name = findCommand(argv[0] ?? '');
  if (!name) return {code: 2, output: 'unknown command'};
  if (name !== 'list' && !argv[1]) return {code: 2, output: 'missing id'};
  return {code: 0, output: name === 'list' ? 'items' : `${name === 'show' ? 'item' : 'deleted'}:${argv[1]}`};
}
