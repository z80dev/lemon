import { resolveCommand, executeCommand } from './commands.ts';
export function dispatch(request: {command: string; payload?: string; authorized?: boolean}): {status: number; body: string} {
  const command = resolveCommand(request.command);
  if (!command) return {status: 404, body: 'unknown command'};
  if (command.mutating && request.authorized !== true) return {status: 403, body: 'forbidden'};
  const payload = request.payload ?? '';
  if (command.name !== 'list' && !payload) return {status: 400, body: 'missing id'};
  return {status: 200, body: executeCommand(command, payload)};
}
