import { useEffect, useState } from 'react';
import { nonce, type ApprovalAllowance, type Bot, type BotResetScope, type Confirmation, type PreviewRequest } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ConfirmDialog, ErrorNotice, Field, formatBytes, useAction, useQuery } from '../../ui';
import { AccessChoice, canManage, Check, collect, downloadJson, IntentNotice, MachineChoice, machineAccess, Selection, useIntent, useMachines } from './shared';
import { GrantsPanel } from './grants';
const resetScopeLabels: Record<BotResetScope, string> = { conversations: 'Conversations', memory: 'Memory', job: 'Job and instructions', routines: 'Routines', connectors: 'Connections', attachments: 'Files' };
const lifecycleLabels: Record<string, string> = { duplicate: 'Make a copy', move: 'Move to another computer', reset: 'Reset', delete: 'Delete' };
const botDestinationLabels: Record<string, string> = { 'machine.detail': 'Computer', routines: 'Routines', memory: 'Memory', skills: 'Skills', 'connect.apps': 'Connections' };

export function SettingsPanel({ bot, reload, openApprovalConfirm = false }: { bot: Bot; reload: () => Promise<void>; openApprovalConfirm?: boolean }) {
  const { client, snapshot, navigate } = useApp();
  const owner = bot.ownerUserId === snapshot.user.id; const admin = snapshot.member.role !== 'member'; const editable = canManage(bot, snapshot.user.id);
  const skills = useQuery(`bot:${bot.id}:skill-library`, () => collect(cursor => client.call('GET /skills', { query: { cursor, limit: 200 } })));
  const attachments = useQuery(`bot:${bot.id}:attachments`, () => collect(cursor => client.call('GET /attachments', { query: { cursor, limit: 200, botId: bot.id } })));
  const [selectedSkills, setSelectedSkills] = useState(bot.skillIds); const [references, setReferences] = useState(bot.referenceAttachmentIds);
  const [referenceFile, setReferenceFile] = useState<File>();
  const [referenceReady, setReferenceReady] = useState<{ id: string; name: string }[]>([]);
  const intent = useIntent(); const read = useAction();
  const machine = snapshot.machines.find(item => item.id === bot.machineId);
  const mediaItems = attachments.data ?? [];
  return <section className="stack">
    <section className="panel stack"><h2>Details and assigned machine</h2><dl><dt>Owner</dt><dd>{snapshot.user.displayName}</dd><dt>Machine</dt><dd>{machine?.name ?? bot.machineId} · {machine?.status ?? 'unknown'}</dd></dl><div className="row">{['machine.detail', 'routines', 'memory', 'skills', 'connect.apps'].map(screen => <button key={screen} onClick={() => navigate({ screen, id: screen === 'machine.detail' ? bot.machineId : undefined, botId: bot.id })}>{botDestinationLabels[screen]}</button>)}</div><Check checked={bot.sidebar.notificationsEnabled} disabled={intent.disabled} onChange={notificationsEnabled => void intent.run(async () => { await client.call('PATCH /bots/:id/sidebar', { params: { id: bot.id }, body: { clientNonce: nonce(), revision: bot.revision, notificationsEnabled } }); await reload(); })}>My notifications for this Bot</Check><Check checked={bot.sidebar.hidden} disabled={intent.disabled} onChange={hidden => void intent.run(async () => { await client.call('PATCH /bots/:id/sidebar', { params: { id: bot.id }, body: { clientNonce: nonce(), revision: bot.revision, hidden } }); await reload(); })}>Hide in my sidebar (suppresses my notifications; does not pause work)</Check></section>
    <GrantsPanel key={bot.id} bot={bot} editable={editable} />
    <ApprovalSettings bot={bot} owner={owner} reload={reload} openConfirm={openApprovalConfirm} />
    <ErrorNotice error={skills.error} /><Selection title="Bot skills" items={skills.data ?? []} selected={selectedSkills} onChange={setSelectedSkills} disabled={!editable || intent.disabled} /><button disabled={!editable || intent.disabled} onClick={() => void intent.run(async () => { await client.call('PATCH /bots/:id', { params: { id: bot.id }, body: { clientNonce: nonce(), revision: bot.revision, skillIds: selectedSkills } }); await reload(); })}>Save skill references</button>
    <section className="panel stack"><h2>Reference files</h2><ErrorNotice error={attachments.error} /><Selection title="Files injected as references" items={[...mediaItems.map(item => ({ id: item.id, name: item.filename, description: `${item.mime} · ${formatBytes(item.size)}` })), ...referenceReady.filter(item => !mediaItems.some(media => media.id === item.id))]} selected={references} onChange={setReferences} disabled={!editable || intent.disabled} /><Field label="Upload a reference file"><input type="file" disabled={!editable || intent.disabled} onChange={event => setReferenceFile(event.target.files?.[0])} /></Field><button disabled={!editable || intent.disabled || !referenceFile} onClick={() => void intent.run(async () => { if (!referenceFile) return; const attachment = await client.upload(referenceFile, { clientNonce: nonce(), purpose: 'reference', botId: bot.id }, referenceFile.name); setReferenceReady(previous => [...previous, { id: attachment.id, name: attachment.filename }]); setReferences(previous => [...previous, attachment.id]); setReferenceFile(undefined); await attachments.reload(); })}>Upload real reference (save association separately)</button><button disabled={!editable || intent.disabled} onClick={() => void intent.run(async () => { await client.call('PATCH /bots/:id', { params: { id: bot.id }, body: { clientNonce: nonce(), revision: bot.revision, referenceAttachmentIds: references } }); await reload(); })}>Save reference associations</button><h3>Media and deliverables</h3>{mediaItems.map(item => <div className="row spread" key={item.id}><span>{item.filename} · {formatBytes(item.size)} · {item.mime}</span><button onClick={() => navigate({ screen: 'file.viewer', id: item.id, botId: bot.id })}>Preview / download original</button></div>)}</section>
    <button disabled={read.busy} onClick={() => void read.run(async () => downloadJson(await client.call('GET /bots/:id/export', { params: { id: bot.id } }), `${bot.name}-template.json`))}>Export declarative Bot template</button><ErrorNotice error={read.error} /><IntentNotice intent={intent} reconcile={reload} /><BotLifecycle bot={bot} editable={editable} canDelete={owner} canReset={owner && machineAccess(machine, snapshot.user.id, admin)} reload={reload} />
  </section>;
}
function ApprovalSettings({ bot, owner, reload, openConfirm }: { bot: Bot; owner: boolean; reload: () => Promise<void>; openConfirm: boolean }) {
  const { client } = useApp();
  const effective = useQuery(`bot:${bot.id}:approval-policy`, () => owner ? client.call('GET /policies/effective', { query: { botId: bot.id } }) : Promise.resolve(null));
  const allowances = useQuery(`bot:${bot.id}:approval-allowances`, () => owner ? collect(cursor => client.call('GET /bots/:id/approval-allowances', { params: { id: bot.id }, query: { cursor, limit: 200, state: 'active' } })) : Promise.resolve([] as ApprovalAllowance[]));
  const intent = useIntent();
  const [confirmation, setConfirmation] = useState<Confirmation>();
  const [previewOnLoad, setPreviewOnLoad] = useState(openConfirm);
  const review = bot.approvalReview ?? 'per_chat';
  const botWideAllowed = !!effective.data?.rememberedApprovals?.bot.length;
  const previewBotWide = async () => {
    const value = await intent.run(() => client.call('POST /bots/:id/approval-allowances/preview', { params: { id: bot.id }, body: { clientNonce: nonce() } }));
    if (value) setConfirmation(value);
  };
  useEffect(() => {
    if (!previewOnLoad || effective.loading) return;
    setPreviewOnLoad(false);
    if (owner && review !== 'bot_wide' && botWideAllowed) void previewBotWide();
  }, [previewOnLoad, effective.loading, owner, review, botWideAllowed]);
  const setReview = (mode: 'every_time' | 'per_chat') => void intent.run(async () => {
    await client.call('PATCH /bots/:id/approval-review', { params: { id: bot.id }, body: { revision: bot.revision, clientNonce: nonce(), mode } });
    await Promise.all([reload(), allowances.reload()]);
  });
  const activeChats = allowances.data?.filter(allowance => allowance.scope === 'chat') ?? [];
  return <section className="panel stack" aria-labelledby={`approval-settings-${bot.id}`}>
    <h2 id={`approval-settings-${bot.id}`}>Approvals</h2>
    <p>Choose how often {bot.name} asks before using Terminal or changing and reading files. Required rules and workspace policy still apply.</p>
    {!owner && <p className="muted">Only this Bot’s owner can change remembered approvals.</p>}
    <ErrorNotice error={effective.error || allowances.error} />
    <fieldset className="stack" disabled={!owner || intent.disabled}>
      <legend>Review mode</legend>
      <label className="row"><input type="radio" name={`approval-review-${bot.id}`} checked={review === 'every_time'} onChange={() => setReview('every_time')} />Ask every time</label>
      <label className="row"><input type="radio" name={`approval-review-${bot.id}`} checked={review === 'per_chat'} onChange={() => setReview('per_chat')} />Ask once per chat</label>
      <label className="row"><input type="radio" name={`approval-review-${bot.id}`} checked={review === 'bot_wide'} disabled={!botWideAllowed && review !== 'bot_wide'} onChange={() => void previewBotWide()} />Don't ask for Terminal &amp; Files</label>
    </fieldset>
    {!effective.loading && !botWideAllowed && review !== 'bot_wide' && <p className="small muted">Bot-wide approval is disabled by workspace governance or an effective ask-first rule.</p>}
    <h3>Allowed in active chats</h3>
    {activeChats.length === 0 ? <p className="muted">No chats currently remember an approval.</p> : <ul className="list">{activeChats.map(allowance => <li className="list-row" key={allowance.id}><div><strong>{allowance.label}</strong><p className="small muted">Used {allowance.useCount} {allowance.useCount === 1 ? 'time' : 'times'}{allowance.lastUsedAtMs ? ` · last used ${new Date(allowance.lastUsedAtMs).toLocaleString()}` : ''}</p></div><button disabled={intent.disabled} onClick={() => void intent.run(async () => { await client.call('POST /approval-allowances/:id/stop', { params: { id: allowance.id }, body: { revision: allowance.revision, clientNonce: nonce() } }); await allowances.reload(); })}>Stop</button></li>)}</ul>}
    <IntentNotice intent={intent} reconcile={async () => { await Promise.all([effective.reload(), allowances.reload(), reload()]); }} />
    {confirmation && <ConfirmDialog title={`Let ${bot.name} run Terminal & Files without asking?`} confirmation={confirmation} disabled={intent.disabled} onCancel={() => setConfirmation(undefined)} onConfirm={async confirm => {
      const created = await intent.run(() => client.call('POST /bots/:id/approval-allowances', { params: { id: bot.id }, body: { ...confirm, clientNonce: nonce() } }));
      if (created) { setConfirmation(undefined); await Promise.all([allowances.reload(), reload()]); }
    }} />}
  </section>;
}
function BotLifecycle({ bot, editable, canDelete, canReset, reload }: { bot: Bot; editable: boolean; canDelete: boolean; canReset: boolean; reload: () => Promise<void> }) {
  const { client, navigate, refresh, snapshot } = useApp();
  const intent = useIntent(); const [mode, setMode] = useState<'duplicate' | 'move' | 'reset' | 'delete'>('duplicate');
  const machines = useMachines();
  const rows = machines.data ?? snapshot.machines;
  const [name, setName] = useState(`${bot.name} copy`); const [machineId, setMachineId] = useState(''); const [consent, setConsent] = useState(false);
  const [access, setAccess] = useState<'standard' | 'none'>('standard');
  const [includeSkills, setIncludeSkills] = useState(true); const [includeRoutines, setIncludeRoutines] = useState(false);
  const [scopes, setScopes] = useState<BotResetScope[]>([]); const [confirmation, setConfirmation] = useState<{ value: Confirmation; action: 'move' | 'reset' | 'delete'; machineId: string; scopes: BotResetScope[] }>(); const [result, setResult] = useState('');
  const [resetDetails, setResetDetails] = useState('');
  useEffect(() => {
    if (mode === 'duplicate' && !machineId) {
      const online = rows.filter(m => m.status === 'online' && m.ownerUserId === snapshot.user.id);
      if (online.length === 1) setMachineId(online[0].id);
    }
  }, [mode, machineId, rows, snapshot.user.id]);
  const selectedMachine = rows.find(m => m.id === machineId);
  const copyName = name.trim() || 'This copy';
  const machineName = selectedMachine?.name || 'this computer';
  return <section className="panel stack"><h2>Copy, move, reset or delete</h2><Field label="Operation"><select value={mode} onChange={event => { const value = event.target.value; setMode(value === 'move' || value === 'reset' || value === 'delete' ? value : 'duplicate'); setConfirmation(undefined); }}>{['duplicate', 'move', 'reset', 'delete'].map(value => <option key={value} value={value}>{lifecycleLabels[value]}</option>)}</select></Field>{mode === 'duplicate' && <><Field label="Copy name"><input required maxLength={120} value={name} onChange={event => setName(event.target.value)} /></Field><MachineChoice value={machineId} onChange={setMachineId} showConsent={false} /><AccessChoice value={access} onChange={setAccess} disabled={intent.disabled} /><p>Separate rescopable Bot with no learned memory, chats, attachments, secrets, logins or connector tokens. Copied routines start paused. Edit its Job after creation.</p><Check checked={includeSkills} onChange={setIncludeSkills}>Include configured skills</Check><Check checked={includeRoutines} onChange={setIncludeRoutines}>Include routines, paused</Check><p className="consent-notice">{copyName} works on {machineName} as you, with your files, tools and logins. It asks before running commands.</p><button disabled={!editable || intent.disabled || !machineId || !name.trim()} onClick={() => void intent.run(async () => { const copy = await client.call('POST /bots/:id/duplicate', { params: { id: bot.id }, body: { clientNonce: nonce(), name, machineId, includeSkills, includeRoutines, access } }); await refresh(); navigate({ screen: 'bot.edit', id: copy.id }); })}>Create separate copy to rescope</button></>}{mode === 'move' && <><MachineChoice value={machineId} onChange={setMachineId} consent={consent} onConsent={setConsent} showConsent={true} exclude={bot.machineId} /><p>Move only while idle, with no active or unknown runs. Persona, skills and scoped memory must be acknowledged on destination before cutover. Product history stays; native continuation starts fresh. Files, cookies, credentials and terminals do not transfer.</p></>}{mode === 'reset' && <><p>Identity and assigned host remain. Only checked scopes change. Shared host files/browser sessions/provider logins remain untouched.</p><Selection title="Exact reset scopes — no defaults" items={(['conversations', 'memory', 'job', 'routines', 'connectors', 'attachments'] satisfies BotResetScope[]).map(scope => ({ id: scope, name: resetScopeLabels[scope] }))} selected={scopes} onChange={ids => setScopes(ids.filter((id): id is BotResetScope => ['conversations', 'memory', 'job', 'routines', 'connectors', 'attachments'].includes(id)))} /></>}{mode === 'delete' && <p className="error-notice">Delete affects the exact Bot and resources disclosed by preview for your Bot. Host files/logins and operator backups remain. Hiding in your sidebar is a reversible alternative.</p>}{(mode === 'move' || mode === 'reset' || mode === 'delete') && <button className={mode === 'delete' ? 'danger' : ''} disabled={intent.disabled || (mode === 'delete' ? !canDelete : mode === 'reset' ? !canReset || !scopes.length : !editable || !consent || !machineId || bot.activeRunIds.length > 0 || bot.activity !== 'idle')} onClick={() => void intent.run(async () => { const body: PreviewRequest = { clientNonce: nonce(), action: mode, ...(mode === 'move' ? { targetMachineId: machineId } : mode === 'reset' ? { resetScopes: scopes } : {}) }; const value = await client.call('POST /bots/:id/preview', { params: { id: bot.id }, body }); setConfirmation({ value, action: mode, machineId, scopes: [...scopes] }); })}>Preview exact {mode} scope</button>}{confirmation && <ConfirmDialog disabled={intent.disabled} title={`Review ${confirmation.action} and residual data`} confirmation={confirmation.value} onCancel={() => setConfirmation(undefined)} onConfirm={async confirm => { await intent.run(async () => {
    if (confirmation.action === 'delete') { await client.call('DELETE /bots/:id', { params: { id: bot.id }, body: { ...confirm, clientNonce: nonce() } }); await refresh(); navigate({ screen: 'bot.create' }); }
    else if (confirmation.action === 'move') { await client.call('POST /bots/:id/move', { params: { id: bot.id }, body: { ...confirm, clientNonce: nonce(), machineId: confirmation.machineId } }); setConfirmation(undefined); await reload(); }
    else { const response = await client.call('POST /bots/:id/reset', { params: { id: bot.id }, body: { ...confirm, clientNonce: nonce(), resetScopes: confirmation.scopes } }); if (response.status === 'outcome_unknown') intent.markUnknown(); setResult(response.status === 'outcome_unknown' ? 'The reset may not have finished. Reload this Bot before trying again.' : `Reset complete. Changed: ${confirmation.scopes.map(scope => resetScopeLabels[scope]).join(', ')}. Kept: ${response.retainedScopes.map(scope => resetScopeLabels[scope]).join(', ') || 'None of the reset categories'}.`); setResetDetails(`Removed item references: ${response.removedIds.join(', ') || 'None'}`); setConfirmation(undefined); await reload(); }
  }); }} />}{result && <p role="status">{result}</p>}{resetDetails && <details><summary>Details</summary><p>{resetDetails}</p><button onClick={() => void navigator.clipboard.writeText(resetDetails)}>Copy details</button></details>}<IntentNotice intent={intent} reconcile={async () => { await reload(); await refresh(); }} /></section>;
}
