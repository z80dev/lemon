import { useEffect, useState } from 'react';
import { LemonBotError, nonce } from '@lemon-bot/sdk';
import type { Confirmation, HostAction, HostManagement, Machine } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { Badge, ConfirmDialog, ErrorNotice, Field, PageHeader, formatTime, useQuery } from '../../ui';
import { IntentNotice, PrivilegeWarning, useIntent, usePages, usePoll } from './shared';

const actionLabels: Record<HostAction, string> = { update: 'Update Lemon worker', recover: 'Recover host service', restart_worker: 'Restart worker', stop_worker: 'Stop worker', suspend: 'Suspend', recreate_environment: 'Recreate isolated environment', delete_environment: 'Delete isolated environment' };

export function HostOperations() {
  const { snapshot } = useApp();
  if (snapshot.workspace.ownerUserId !== snapshot.user.id) return <main className="page"><PageHeader title="Host operations" /><p className="error-notice">The workspace owner must have explicit authority over every affected owned host.</p></main>;
  return <OperationsPanel />;
}

function OperationsPanel() {
  const { client, online, reportError } = useApp();
  const machines = usePages('host-operation-machines', cursor => client.call('GET /machines', { query: { limit: 100, cursor } }), item => item.id);
  const history = usePages('host-operation-history', cursor => client.call('GET /host-operations', { query: { limit: 50, cursor } }), item => item.id);
  const [management, setManagement] = useState<Record<string, HostManagement>>({});
  const [action, setAction] = useState<HostAction>('update');
  const [selected, setSelected] = useState<string[]>([]);
  const [review, setReview] = useState<{ confirmation: Confirmation; machineIds: string[]; action: HostAction }>();
  const [operationId, setOperationId] = useState<string>();
  const operation = useQuery(`host-operation:${operationId || 'none'}`, () => operationId ? client.call('GET /host-operations/:id', { params: { id: operationId } }) : Promise.resolve(null));
  const intent = useIntent();
  useEffect(() => {
    if (operation.data?.state === 'outcome_unknown' || operation.data?.results.some(result => result.state === 'outcome_unknown')) intent.markUncertain();
  }, [operation.data]);
  usePoll(operation.reload, online && !!operationId, 3000);
  usePoll(history.reload, online, 10000);
  const candidates = selected.filter(id => management[id]?.supportedActions.includes(action));
  const supported = Object.keys(actionLabels).filter(value => Object.values(management).some(item => item.supportedActions.includes(value as HostAction))) as HostAction[];
  const finished = operation.data?.results.filter(result => result.state === 'succeeded' || result.state === 'skipped' || result.state === 'failed').length ?? 0;
  return <main className="page stack"><PageHeader title="Host operations" eyebrow="Real configured destination drivers · durable per-target results" /><PrivilegeWarning /><IntentNotice intent={intent} reconcile={async () => {
    if (operationId) {
      const current = await client.call('GET /host-operations/:id', { params: { id: operationId } });
      operation.setData(current);
      if (current.state === 'outcome_unknown' || current.results.some(result => result.state === 'outcome_unknown')) throw new Error('This exact operation is still uncertain. The existing operation must be reconciled by the host driver; no redispatch is permitted.');
    }
    const page = await client.call('GET /host-operations', { query: { limit: 100 } });
    history.setData(page);
    if (!operationId) {
      const ids = intent.error instanceof LemonBotError ? intent.error.details?.resourceIds : undefined;
      const identified = Array.isArray(ids) ? page.items.find(item => ids.includes(item.id)) : undefined;
      if (!identified) throw new Error('No exact operation receipt identified. Inspect the server history and select the operation with the matching action, target set and timestamp before reconciling. Do not start another operation to infer its outcome.');
      const current = await client.call('GET /host-operations/:id', { params: { id: identified.id } });
      setOperationId(identified.id);
      if (current.state === 'outcome_unknown' || current.results.some(result => result.state === 'outcome_unknown')) throw new Error('The identified operation remains uncertain. Keep reconciling its exact ID; do not repeat the action.');
    }
    setReview(undefined);
  }} /><section className="panel stack"><h2>Choose action and exact hosts</h2><p>Only actions this computer supports are available. Queued means it hasn’t finished yet — not that it worked. If the outcome is unknown, check its status before trying again.</p><Field label="Host action"><select value={action} disabled={intent.busy || !!review} onChange={event => { setAction(event.target.value as HostAction); setSelected([]); }}>{Object.entries(actionLabels).map(([value, label]) => <option key={value} value={value} disabled={!supported.includes(value as HostAction)}>{label}{!supported.includes(value as HostAction) ? ' (no loaded host supports this)' : ''}</option>)}</select></Field>{supported.length === 0 && <p className="muted">Load machines below to inspect actual driver support. An operator must configure destination-local commands/service or isolated-container management; a provider error is not an empty capability list.</p>}<ErrorNotice error={machines.error} /><div className="stack">{machines.data?.items.map(machine => <ManagementTarget key={machine.id} machine={machine} action={action} selected={candidates.includes(machine.id)} locked={intent.busy || !!review || !online} onManagement={value => setManagement(previous => { const next = { ...previous }; if (value) next[machine.id] = value; else delete next[machine.id]; return next; })} onSelect={checked => setSelected(previous => checked ? [...new Set([...previous, machine.id])] : previous.filter(id => id !== machine.id))} />)}</div><ErrorNotice error={machines.moreError} />{machines.data?.nextCursor && <button disabled={machines.moreBusy} onClick={() => void machines.loadMore()}>Load more machines</button>}<p>{candidates.length} exact supported targets selected · maximum 1000.</p><p className="machine-warning">Update/recover/restart preserve disk and identity and must wait for a verified safe point. Stop/suspend retain disk and trust. Recreate/delete affect only each configured isolated Lemon-owned root, never the whole host/home/SSH. Recent unsaved data may be lost; review root, backup age and retained/lost scope in the server preview. Detach is a separate trust-revocation action.</p><button className={action === 'delete_environment' || action === 'recreate_environment' ? 'danger' : 'primary'} disabled={intent.disabled || !candidates.length || candidates.length > 1000} onClick={() => void intent.run(async () => { const ids = [...candidates].sort(); const confirmation = await client.call('POST /host-operations/preview', { body: { clientNonce: nonce(), machineIds: ids, action } }); setReview({ confirmation, machineIds: ids, action }); })}>Preview {actionLabels[action]} for selected hosts</button></section>{review && <ConfirmDialog title={`${actionLabels[review.action]} · ${review.machineIds.length} targets`} confirmation={review.confirmation} onCancel={() => setReview(undefined)} onConfirm={async confirm => { await intent.run(async () => { const accepted = await client.call('POST /host-operations', { body: { ...confirm, clientNonce: nonce(), machineIds: review.machineIds, action: review.action } }); setOperationId(accepted.id); if (accepted.state === 'outcome_unknown') intent.markUncertain(); setReview(undefined); await history.reload(); }); }} disabled={intent.disabled} />}{operationId && <section className="panel stack"><div className="row spread"><h2>Operation {operationId}</h2><button disabled={operation.loading} onClick={() => void operation.reload().catch(reportError)}>Reconcile status (GET only)</button></div><ErrorNotice error={operation.error} />{operation.data && <><Badge tone={operation.data.state === 'completed' ? 'good' : operation.data.state === 'failed' || operation.data.state === 'outcome_unknown' ? 'danger' : 'warning'}>{operation.data.state.replaceAll('_', ' ')}</Badge><p>{actionLabels[operation.data.action]} · accepted {formatTime(operation.data.createdAtMs)}. This job continues on the server if you close the page.</p><p>Finished: {finished} of {operation.data.results.length}</p><progress aria-label={`Finished: ${finished} of ${operation.data.results.length}`} max={operation.data.results.length || 1} value={finished} /><div className="table-wrap"><table><thead><tr><th>Exact machine</th><th>Result</th><th>Reason</th></tr></thead><tbody>{operation.data.results.map(result => <tr key={result.machineId}><th scope="row">{machines.data?.items.find(machine => machine.id === result.machineId)?.name || result.machineId}<br /><code>{result.machineId}</code></th><td>{result.state.replaceAll('_', ' ')}</td><td>{result.reason || 'No additional reason reported'}</td></tr>)}</tbody></table></div>{operation.data.results.some(result => result.state === 'outcome_unknown') && <p className="error-notice">One or more effects are uncertain. Reconciliation probes the existing operation ID; never repeat the destructive action to infer success.</p>}</>}</section>}<section className="panel stack"><div className="row spread"><h2>Durable operation history</h2><button onClick={() => void history.reload().catch(reportError)}>Refresh history</button></div><ErrorNotice error={history.error} />{history.data?.items.map(item => <div className="list-row" key={item.id}><button onClick={() => setOperationId(item.id)}>{actionLabels[item.action]} · {formatTime(item.createdAtMs)}</button><Badge>{item.state.replaceAll('_', ' ')}</Badge><span>{item.results.length} targets</span></div>)}{history.data?.items.length === 0 && <p className="muted">No operations recorded.</p>}<ErrorNotice error={history.moreError} />{history.data?.nextCursor && <button disabled={history.moreBusy} onClick={() => void history.loadMore()}>Load older operations</button>}</section></main>;
}

function ManagementTarget({ machine, action, selected, locked, onManagement, onSelect }: { machine: Machine; action: HostAction; selected: boolean; locked: boolean; onManagement: (management: HostManagement | undefined) => void; onSelect: (selected: boolean) => void }) {
  const { client, reportError } = useApp();
  const query = useQuery(`host-management:${machine.id}`, () => client.call('GET /machines/:id/management', { params: { id: machine.id } }));
  useEffect(() => { onManagement(query.error ? undefined : query.data); }, [query.data, query.error]);
  const supported = !query.error && query.data?.supportedActions.includes(action);
  return <article className="card stack"><label className="row"><input type="checkbox" checked={selected && !!supported} disabled={locked || !supported || machine.status === 'revoked'} onChange={event => onSelect(event.target.checked)} /><strong>{machine.name}</strong><Badge>{machine.status}</Badge></label><ErrorNotice error={query.error} />{query.data && <><p className="small">Driver: {query.data.provider} · isolated root: <code>{query.data.environmentRoot || 'None configured'}</code> · last backup {formatTime(query.data.lastBackupAtMs)}</p><p className="muted">Supports: {query.data.supportedActions.map(value => actionLabels[value]).join(', ') || 'No actions'}</p><p className="small">Network enforcement: {query.data.supportsNetworkPolicy ? 'supported' : 'unavailable'} · egress: {query.data.supportsEgress ? 'supported' : 'unavailable'} · setup: {query.data.supportsSetup ? 'supported' : 'unavailable'}</p></>}<button disabled={query.loading} onClick={() => void query.reload().catch(reportError)}>Refresh driver capabilities</button></article>;
}
