import { resolveCommand, executeCommand } from './commands.ts';
export function runCli(argv: string[]): {code: number; output: string} {
  const command = resolveCommand(argv[0] ?? '');
  if (!command) return {code: 2, output: 'unknown command'};
  const payload = argv[1] ?? '';
  if (command.name !== 'list' && !payload) return {code: 2, output: 'missing id'};
  return {code: 0, output: executeCommand(command, payload)};
}
