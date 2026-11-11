import { nonce, type AccessLevel, type Bot, type BotGrant } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ErrorNotice, Loading, useQuery } from '../../ui';
import { collect, IntentNotice, useIntent } from './shared';
import { accessLabels, grantControlReason, grantGroup, grantGroups, grantName, grantStatus } from './grant-presentation';

export function GrantsPanel({ bot, editable }: { bot: Bot; editable: boolean }) {
  const { client } = useApp();
  const intent = useIntent();
  const grants = useQuery(`bot:${bot.id}:grants`, () => collect(cursor => client.call('GET /bots/:id/grants', { params: { id: bot.id }, query: { cursor, limit: 200 } })));
  const capabilities = useQuery(`machine:${bot.machineId}:grant-capabilities`, () => client.call('GET /machines/:id/capabilities', { params: { id: bot.machineId } }));
  const connectors = useQuery(`bot:${bot.id}:grant-connections`, () => collect(cursor => client.call('GET /bots/:id/connectors', { params: { id: bot.id }, query: { cursor, limit: 200 } })));
  const refresh = async () => { await Promise.all([grants.reload(), capabilities.reload(), connectors.reload()]); };
  const name = (grant: BotGrant) => grantName(grant.capabilityId, capabilities.data?.items.find(item => item.id === grant.capabilityId), connectors.data?.find(item => `connector:${item.id}` === grant.capabilityId)?.name);
  const row = (grant: BotGrant) => {
    const capability = capabilities.data?.items.find(item => item.id === grant.capabilityId);
    const label = name(grant);
    const limited = grant.requestedLevel !== grant.effectiveLevel;
    const restrictions = [...new Set((Object.keys(accessLabels) as AccessLevel[]).map(level => grantControlReason(grant.capabilityId, level, capability)).filter(Boolean))];
    return <article className="card stack" key={grant.id}>
      <strong>{label}</strong>
      <div className="segmented" role="group" aria-label={`${label} access`}>
        {(Object.keys(accessLabels) as AccessLevel[]).map(level => <button key={level} className={grant.requestedLevel === level ? 'selected' : undefined} type="button" aria-label={`${label}: ${accessLabels[level]}`} aria-pressed={grant.requestedLevel === level} aria-describedby={`grant-status-${grant.id} grant-restrictions-${grant.id}`} disabled={!editable || intent.disabled || !!grantControlReason(grant.capabilityId, level, capability)} title={grantControlReason(grant.capabilityId, level, capability)} onClick={() => void intent.run(async () => {
          const updated = await client.call('PATCH /bots/:id/grants/:grantId', { params: { id: bot.id, grantId: grant.id }, body: { clientNonce: nonce(), revision: grant.revision, requestedLevel: level } });
          grants.setData(previous => previous?.map(item => item.id === updated.id ? updated : item));
        })}>{accessLabels[level]}</button>)}
      </div>
      <p id={`grant-status-${grant.id}`} className={limited ? 'warning-text' : 'muted'} role="status">{limited && <strong>Requested {accessLabels[grant.requestedLevel]}; currently {accessLabels[grant.effectiveLevel]}. </strong>}{grantStatus(grant, capability)}</p>
      <div id={`grant-restrictions-${grant.id}`}>{restrictions.map(reason => <p className="muted" key={reason}>{reason}</p>)}</div>
    </article>;
  };
  const groups = grantGroups.map(group => {
    const items = grants.data?.filter(grant => grantGroup(grant.capabilityId, capabilities.data?.items.find(item => item.id === grant.capabilityId)) === group) ?? [];
    if (!items.length) return null;
    return group === 'Control this Mac'
      ? <details className="stack" key={group}><summary>{group}</summary>{items.map(row)}</details>
      : <section className="stack" key={group}><h3>{group}</h3>{items.map(row)}</section>;
  });
  const reasons = [...new Set(grants.data?.flatMap(grant => grant.reasons) ?? [])];
  return <section className="panel stack"><h2>Bot access</h2>
    <ErrorNotice error={grants.error ?? capabilities.error ?? connectors.error} />
    {grants.loading && <Loading />}{groups}
    <details><summary>Why</summary><p>Machine configuration, OS permissions and workspace policy can narrow access. A Bot persona is not an OS sandbox. Terminal and browser evaluation can reach other host resources. Granting access does not remove required approvals.</p>
      <ul>{grants.data?.map(grant => <li key={grant.id}>{name(grant)}: <code>{grant.capabilityId}</code> — <code>{grant.reasons[0]}</code></li>)}</ul>
      <ul>{reasons.map(reason => <li key={reason}>{reason}</li>)}</ul>
    </details>
    <button disabled={grants.loading || capabilities.loading || connectors.loading} onClick={() => void intent.run(refresh)}>Refresh access</button>
    <IntentNotice intent={intent} reconcile={refresh} />
  </section>;
}
