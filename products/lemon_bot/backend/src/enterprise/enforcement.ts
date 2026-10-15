import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal } from '../core/services';
import { ApiError } from '../core/errors';
import { quiesceBotInvocations } from '../runtime/runs';
import { assertWorkspaceRestrictionManagement, syncBotPolicyFloor, syncBotProfile } from '../core/bots';

/** A stored desired rule is not proof that a previously running native agent lost its authority. */
export async function refreshEffectivePolicy(services: BackendServices, actor: Principal, botIds?: string[], options: { workspace?: boolean } = {}): Promise<void> {
  if (options.workspace) assertWorkspaceRestrictionManagement(services, actor);
  const selected = botIds ? new Set(botIds) : null;
  const bots = services.store.list<P.Bot>('bots', bot => (!selected || selected.has(bot.id)) && (options.workspace || bot.ownerUserId === actor.userId));
  if (selected && bots.length !== selected.size) throw new ApiError('not_found', 'An affected bot is not available.');
  for (const bot of bots) {
    const operationId = services.id('policy_sync');
    const fenceKey = `botPolicySync:${bot.id}`;
    const previous = services.store.metadata<Record<string, unknown>>(fenceKey) ?? {};
    if (previous.state === 'outcome_unknown') throw new ApiError('outcome_unknown', 'Reconcile the prior native policy application before another synchronization.', false, { resourceIds: [bot.id] });
    services.store.setMetadata(fenceKey, { ...previous, operationId, state: 'pending', revision: bot.revision, actorUserId: actor.userId, workspace: options.workspace === true });
    try {
      const quiesced = await quiesceBotInvocations(services, actor, bot.id);
      if (quiesced.status !== 'cancelled') throw new ApiError('outcome_unknown', 'Previous native policy invocations have not been confirmed stopped.', false, { resourceIds: [bot.id, ...quiesced.runIds] });
      if (options.workspace) await syncBotPolicyFloor(services, actor, bot.id);
      else await syncBotProfile(services, actor, bot.id);
      const current = services.store.metadata<{ operationId?: string; state: string }>(fenceKey);
      if (current?.operationId !== operationId) throw new ApiError('outcome_unknown', 'A newer policy change superseded this synchronization.', false, { resourceIds: [bot.id] });
      services.store.setMetadata(fenceKey, { ...previous, operationId, state: 'acknowledged', revision: services.store.require<P.Bot>('bots', bot.id).revision, actorUserId: actor.userId, workspace: options.workspace === true, acknowledgedAtMs: services.now() });
      services.audit(actor, 'policy.native_apply', bot.id, 'succeeded', { operationId, scope: options.workspace ? 'workspace' : 'principal' });
    } catch (error) {
      const current = services.store.metadata<Record<string, unknown>>(fenceKey);
      if (current?.operationId === operationId) services.store.setMetadata(fenceKey, { ...current, state: 'outcome_unknown', revision: bot.revision, actorUserId: actor.userId });
      services.audit(actor, 'policy.native_apply', bot.id, 'outcome_unknown', { operationId });
      if (error instanceof ApiError && error.code === 'outcome_unknown') throw error;
      throw new ApiError('outcome_unknown', 'Policy was saved, but native authority synchronization is not acknowledged; no new work is admitted.', false, { resourceIds: [bot.id] });
    }
  }
}
