import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal } from '../core/services';
import { fail } from '../core/errors';

/** Team bot configuration is shared; private active invocation IDs are not. */
export function emitBotRuntimeProjection(services: BackendServices, bot: P.Bot): void {
  const workspaceId = services.store.metadata<string>('workspaceId');
  if (!workspaceId) fail('internal_error', 'Workspace identity is unavailable.', false);
  for (const member of services.store.list<P.Member>('members', member => member.enabled)) {
    const viewer: Principal = { kind: 'user', id: member.userId, userId: member.userId, workspaceId, role: member.role, sessionId: null, botId: null, deviceId: null };
    if (!services.auth.canRead(viewer, 'bots', bot)) continue;
    const activeRunIds = bot.activeRunIds.filter(runId => { const run = services.store.get<P.Run>('runs', runId); return run !== null && services.auth.canRead(viewer, 'runs', run); });
    const projection = services.auth.bot(viewer, bot.id);
    services.events.emit('bot.upserted', { ...projection, activeRunIds, activity: bot.activity }, { userIds: [viewer.userId], botId: bot.id });
  }
}
