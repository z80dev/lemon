import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal } from '../core/services';
import { fail } from '../core/errors';
import { botAgentProjection } from '../core/agent-addressing';

/** SSH addresses are management data; legacy rows predate the required direct-link field. */
export function machineProjection(services: BackendServices, viewer: Principal | null, machine: P.Machine): P.Machine {
  const link = machine.link ?? { kind: 'direct' as const };
  if (link.kind === 'direct') return { ...machine, link };
  let manage = false;
  if (viewer?.kind === 'user') {
    try { services.auth.machine(viewer, machine.id, true); manage = true; } catch { /* Read access alone never exposes SSH destinations. */ }
  }
  return { ...machine, link: { ...link, sshDestination: manage ? link.sshDestination : null } };
}

/** Team bot configuration is shared; private active invocation IDs are not. */
export function emitBotRuntimeProjection(services: BackendServices, bot: P.Bot): void {
  const workspaceId = services.store.metadata<string>('workspaceId');
  if (!workspaceId) fail('internal_error', 'Workspace identity is unavailable.', false);
  for (const member of services.store.list<P.Member>('members', member => member.enabled)) {
    const viewer: Principal = { kind: 'user', id: member.userId, userId: member.userId, workspaceId, role: member.role, sessionId: null, botId: null, deviceId: null };
    if (!services.auth.canRead(viewer, 'bots', bot)) continue;
    const activeRunIds = bot.activeRunIds.filter(runId => { const run = services.store.get<P.Run>('runs', runId); return run !== null && services.auth.canRead(viewer, 'runs', run); });
    const projection = services.auth.bot(viewer, bot.id);
    services.events.emit('bot.upserted', { ...projection, activeRunIds, activity: bot.activity, ...botAgentProjection(services, bot) }, { userIds: [viewer.userId], botId: bot.id });
  }
}
