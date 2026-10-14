import { useEffect, useState } from 'react';
import type { AccountCleanupResult, AccountTeardown, ProviderCleanupResult } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { Badge, EmptyState, ErrorNotice, Field, Loading, formatTime, useQuery } from '../../ui';
import { readCleanupHandoff } from '../../cleanup-handoff';

export function AccountCleanupScreen({ id }: { id?: string }) {
  const { snapshot } = useApp();
  if (snapshot.workspace.ownerUserId !== snapshot.user.id) return <EmptyState title="Workspace Owner required">Only an enabled workspace Owner can inspect account cleanup metadata. This never grants access to deleted private conversations, notes, credentials or files.</EmptyState>;
  return <OwnerCleanup id={id}/>;
}
function OwnerCleanup({ id }: { id?: string }) {
  const { client, snapshot, navigate } = useApp();
  const handoff = readCleanupHandoff();
  const matchingHandoff = handoff?.workspaceId === snapshot.workspace.id && handoff.backendUrl === client.baseUrl ? handoff : undefined;
  const [userInput, setUserInput] = useState(matchingHandoff?.userId || '');
  const [userId, setUserId] = useState(matchingHandoff?.userId || '');
  const [state, setState] = useState<AccountTeardown['state'] | ''>('');
  const [cursor, setCursor] = useState<string>();
  const [operationInput, setOperationInput] = useState(id || matchingHandoff?.teardownId || '');
  const [selectedId, setSelectedId] = useState(id || matchingHandoff?.teardownId || '');
  const [watch, setWatch] = useState(false);
  const [pollError, setPollError] = useState<unknown>();
  const [copyError, setCopyError] = useState<unknown>();
  const list = useQuery(`account-teardowns:${userId}:${state}:${cursor || ''}`, () => client.call('GET /account-teardowns', { query: { limit: 50, cursor, userId: userId || undefined, state: state || undefined } }));
  const detail = useQuery(`account-teardown:${selectedId}`, () => selectedId ? client.call('GET /account-teardowns/:id', { params: { id: selectedId } }) : Promise.resolve(undefined));
  useEffect(() => { if (id) { setSelectedId(id); setOperationInput(id); } }, [id]);
  useEffect(() => {
    if (!watch || !selectedId) return;
    const timer = window.setInterval(() => void detail.reload().then(() => setPollError(undefined)).catch(setPollError), 15000);
    return () => clearInterval(timer);
  }, [watch, selectedId]);
  const record = detail.data;
  return <div className="stack">
    <section className="panel stack"><h2>Read-only account cleanup ledger</h2>
      <p>Actor sessions revoke immediately. Product removal and actual provider cleanup are separate outcomes. This Owner-only ledger survives revocation but contains operational metadata only—not private child content or credentials.</p>
      <p className="muted">Refresh performs authenticated reads of the original operation and provider receipt observations. It never resubmits Delete, renews a grant, restores the account or retries provider revocation. Unknown or unavailable receipt evidence is not completion.</p>
      <form className="toolbar" onSubmit={event => { event.preventDefault(); setUserId(userInput.trim()); setCursor(undefined); }}>
        <Field label="Deleted user ID"><input value={userInput} onChange={event => setUserInput(event.target.value)} placeholder="Optional fixed user ID from diagnostic handoff"/></Field>
        <Field label="Operation state"><select value={state} onChange={event => { setState(event.target.value as AccountTeardown['state'] | ''); setCursor(undefined); }}><option value="">All states</option>{(['pending', 'running', 'completed', 'failed', 'outcome_unknown'] as const).map(value => <option value={value} key={value}>{value.replaceAll('_', ' ')}</option>)}</select></Field>
        <button>Filter ledger</button><button type="button" onClick={() => void list.reload().catch(setPollError)}>Refresh read-only list</button>
      </form>
      <ErrorNotice error={list.error || pollError}/>{list.loading && <Loading/>}
      {list.data && <div className="table-wrap"><table><thead><tr><th>Operation / user</th><th>Overall</th><th>Product cleanup</th><th>Provider targets</th><th>Recorded times</th><th>Inspect</th></tr></thead><tbody>{list.data.items.map(item => <tr key={item.id}><td><code>{item.id}</code><br/><code>{item.userId}</code></td><td><CleanupBadge state={item.state}/></td><td><CleanupBadge state={item.productCleanup.state}/>{item.productCleanup.errorCode && <p>{item.productCleanup.errorCode}</p>}</td><td>{item.providerCleanup.length} recorded targets</td><td>Started {formatTime(item.startedAtMs)}<br/>Completed {formatTime(item.completedAtMs)}</td><td><button onClick={() => { setSelectedId(item.id); setOperationInput(item.id); navigate({ screen: 'settings.account-cleanup', id: item.id }); }}>Inspect fixed operation</button></td></tr>)}</tbody></table></div>}
      {list.data && !list.loading && !list.error && list.data.items.length === 0 && <EmptyState title="No matching recorded operations">This is a successful filtered ledger read, not proof that an unrecorded or unavailable provider cleanup completed.</EmptyState>}
      <div className="row">{cursor && <button onClick={() => setCursor(undefined)}>First page</button>}{list.data?.nextCursor && <button disabled={list.loading} onClick={() => setCursor(list.data!.nextCursor!)}>Older recorded operations</button>}</div>
    </section>
    <section className="panel stack"><h2>Inspect a fixed teardown ID</h2><form className="row" onSubmit={event => { event.preventDefault(); setSelectedId(operationInput.trim()); navigate({ screen: 'settings.account-cleanup', id: operationInput.trim() }); }}><Field label="Teardown operation ID"><input required value={operationInput} onChange={event => setOperationInput(event.target.value)}/></Field><button>Read operation</button></form>
      <ErrorNotice error={detail.error}/>{detail.loading && selectedId && <Loading/>}
      {record && <>
        <div className="row spread"><h3>Account removal · {record.id}</h3><CleanupBadge state={record.state}/></div>
        <dl><dt>User ID</dt><dd><code>{record.userId}</code></dd><dt>Workspace</dt><dd><code>{record.workspaceId}</code></dd><dt>Request ID</dt><dd><code>{record.requestId}</code></dd><dt>Started</dt><dd>{formatTime(record.startedAtMs)}</dd><dt>Completed</dt><dd>{formatTime(record.completedAtMs)}</dd><dt>Resource revision / updated</dt><dd>{record.revision} · {formatTime(record.updatedAtMs)}</dd></dl>
        <section className="card stack"><h3>Product-owned cleanup</h3><CleanupResult result={record.productCleanup}/><p className="small muted">This state reports reachable product removal independently of external provider outages. It does not erase host files, independent provider subscriptions, previous collector copies or operator backups.</p></section>
        <h3>Actual provider cleanup observations</h3>
        {record.providerCleanup.map((provider, index) => <section className="card stack" key={`${provider.kind}:${provider.providerId}:${provider.receiptId || ''}:${index}`}><h4>{provider.kind} · registered provider {provider.providerId}</h4><CleanupResult result={provider}/><p className="small">Product receipt ID: {provider.receiptId || 'Not reported; cleanup state is shown independently.'}</p></section>)}
        {!record.providerCleanup.length && <p className="muted">No provider targets are recorded. No provider completion is inferred from an empty array; the durable pre-revocation resource snapshot controls whether cleanup was not required.</p>}
        <label className="row"><input type="checkbox" checked={watch} onChange={event => setWatch(event.target.checked)}/>Watch read-only status every 15 seconds</label>
        <div className="row"><button onClick={() => void detail.reload().then(() => setPollError(undefined)).catch(setPollError)}>Refresh original receipt observations</button><button onClick={() => void navigator.clipboard.writeText(JSON.stringify({ operationId: record.id, userId: record.userId, workspaceId: record.workspaceId, requestId: record.requestId, state: record.state, observedAtMs: record.updatedAtMs }, null, 2)).catch(setCopyError)}>Copy safe operation diagnostics</button></div><ErrorNotice error={copyError}/>
      </>}
    </section>
  </div>;
}
function CleanupBadge({ state }: { state: AccountCleanupResult['state'] }) { return <Badge tone={state === 'completed' ? 'good' : state === 'failed' || state === 'outcome_unknown' ? 'warning' : 'muted'}>{state.replaceAll('_', ' ')}</Badge>; }
function CleanupResult({ result }: { result: AccountCleanupResult | ProviderCleanupResult }) { return <div className="stack"><CleanupBadge state={result.state}/><p>Last observation: {formatTime(result.updatedAtMs)}. Retained timestamps are not a fresh health guarantee.</p>{result.errorCode && <p role="status">Actual bounded outcome code: {result.errorCode}</p>}</div>; }
