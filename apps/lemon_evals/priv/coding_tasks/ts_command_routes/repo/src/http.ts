export function findCommand(input: string): string | undefined {
  return ['list', 'show', 'delete'].find(name => name === input);
}
export function dispatch(request: {command: string; payload?: string; authorized?: boolean}): {status: number; body: string} {
  const name = findCommand(request.command);
  if (!name) return {status: 404, body: 'unknown command'};
  if (name === 'delete' && !request.authorized) return {status: 403, body: 'forbidden'};
  if (name !== 'list' && !request.payload) return {status: 400, body: 'missing id'};
  return {status: 200, body: name === 'list' ? 'items' : `${name === 'show' ? 'item' : 'deleted'}:${request.payload}`};
}
