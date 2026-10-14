import { useEffect, useState } from 'react';
import type { Approval, Card, Connector, ConnectorConsent, Draft, DraftContent, Field as QuestionField, Gate, HumanStep, JSONValue, Question, SecretRequest } from '@lemon-bot/sdk';
import { nonce } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ErrorNotice, Field, Loading, formatTime, safeExternal, useQuery } from '../../ui';
import { IntentNotice, copyText, useClock, useIntent } from './common';
import { AttachmentLink, RichText, VoiceMemo } from './files';

function GateState({ gate }: { gate: Gate }) {
  const { snapshot, online } = useApp(); const now = useClock();
  const state = gate.state === 'pending' && gate.expiresAtMs <= now ? 'expired' : gate.state;
  return <div className="chat-gate-state"><span className="badge">{state.replaceAll('_', ' ')}</span><span className="muted small">Expires {formatTime(gate.expiresAtMs)}</span>{gate.targetUserId !== snapshot.user.id && <p>Only the designated person can answer this request.</p>}{!online && <p>Offline. Actions are disabled; nothing will be queued.</p>}{['denied', 'declined', 'expired', 'cancelled'].includes(state) && <p>No action was authorized. Ask the Bot for a new request if needed.</p>}{state === 'approved' && <p>Permission granted only. This is not proof the proposed action completed.</p>}{state === 'outcome_unknown' && <p role="alert">Result not confirmed. Inspect the destination and reconcile before requesting any new action.</p>}</div>;
}
function useGate(gate: Gate) { const { snapshot, online } = useApp(); const now = useClock(); return online && gate.targetUserId === snapshot.user.id && gate.state === 'pending' && now < gate.expiresAtMs; }

function InputField({ field, value, change, disabled }: { field: QuestionField; value: JSONValue | undefined; change: (value: JSONValue | undefined) => void; disabled: boolean }) {
  if (field.kind === 'boolean') return <Field label={field.label + (field.required ? ' (required)' : '')}><select disabled={disabled} required={field.required} value={value === undefined ? '' : value === true ? 'yes' : 'no'} onChange={event => change(event.target.value === '' ? undefined : event.target.value === 'yes')}><option value="">Choose an answer</option><option value="yes">Yes</option><option value="no">No</option></select></Field>;
  const props = { disabled, required: field.required };
  return <Field label={field.label + (field.required ? ' (required)' : '')}>{field.kind === 'multiline' ? <textarea {...props} value={typeof value === 'string' ? value : ''} onChange={event => change(event.target.value || undefined)} /> : field.kind === 'number' ? <input {...props} type="number" min={field.min} max={field.max} value={typeof value === 'number' ? value : ''} onChange={event => change(event.target.value === '' ? undefined : Number(event.target.value))} /> : field.kind === 'single_select' ? <select {...props} value={typeof value === 'string' ? value : ''} onChange={event => change(event.target.value || undefined)}><option value="">Choose an option</option>{field.options?.map(option => <option value={option.value} key={option.value}>{option.label}</option>)}</select> : field.kind === 'multi_select' ? <select {...props} multiple value={Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []} onChange={event => change(Array.from(event.target.selectedOptions, option => option.value))}>{field.options?.map(option => <option value={option.value} key={option.value}>{option.label}</option>)}</select> : <input {...props} type="text" value={typeof value === 'string' ? value : ''} onChange={event => change(event.target.value || undefined)} />}</Field>;
}
function validateAnswers(fields: QuestionField[], answers: Record<string, JSONValue>) {
  for (const field of fields) {
    const value = answers[field.id];
    if (value === undefined || value === '' || (Array.isArray(value) && !value.length)) { if (field.required) throw new Error(`${field.label} is required.`); continue; }
    if (field.kind === 'number' && (typeof value !== 'number' || !Number.isFinite(value) || (field.min !== undefined && value < field.min) || (field.max !== undefined && value > field.max))) throw new Error(`${field.label} must be a number within the shown range.`);
    if (field.kind === 'boolean' && typeof value !== 'boolean') throw new Error(`${field.label} must be yes or no.`);
    if (field.kind === 'single_select' && !field.options?.some(option => option.value === value)) throw new Error(`Choose a valid ${field.label} option.`);
    if (field.kind === 'multi_select' && (!Array.isArray(value) || new Set(value).size !== value.length || value.some(item => !field.options?.some(option => option.value === item)))) throw new Error(`Choose valid unique ${field.label} options.`);
  }
}
function QuestionCard({ id, initial }: { id: string; initial?: Question }) {
  const { client } = useApp(); const query = useQuery(`question:${id}`, () => client.call('GET /questions/:id', { params: { id } })); const question = query.data || initial;
  const [answers, setAnswers] = useState<Record<string, JSONValue>>({}); const [validation, setValidation] = useState<unknown>(); const intent = useIntent();
  const allowed = useGate(question?.gate || { id, targetUserId: '', state: 'cancelled', expiresAtMs: 0, resolvedAtMs: null, resolvedByUserId: null, revision: 0 });
  async function resolve(decision: 'answer' | 'decline') {
    if (!question || !allowed) return;
    if (decision === 'answer') { try { validateAnswers(question.fields, answers); setValidation(undefined); } catch (error) { setValidation(error); return; } }
    await intent.run(async () => { const result = await client.call('POST /questions/:id/resolve', { params: { id }, body: { revision: question.revision, clientNonce: nonce(), decision, ...(decision === 'answer' ? { answers } : {}) } }); query.setData(result); });
  }
  if (!question) return <><ErrorNotice error={query.error} />{query.loading && <Loading />}</>;
  return <form className="stack" onSubmit={event => { event.preventDefault(); void resolve('answer'); }}><h3>{question.title}</h3><p className="muted small">Not for passwords, OTPs or confidential credentials. Answers are visible to the Bot.</p><GateState gate={question.gate} />{question.fields.map(field => <InputField key={field.id} field={field} value={question.gate.state === 'completed' ? question.answers?.[field.id] : answers[field.id]} disabled={!allowed || intent.busy || intent.uncertain} change={value => setAnswers(current => { const next = { ...current }; if (value === undefined) delete next[field.id]; else next[field.id] = value; return next; })} />)}<ErrorNotice error={validation || query.error} /><IntentNotice intent={intent} reconcile={query.reload} /><div className="row"><button className="primary" disabled={!allowed || intent.busy || intent.uncertain}>Submit answer</button><button type="button" disabled={!allowed || intent.busy || intent.uncertain} onClick={() => void resolve('decline')}>Decline</button></div></form>;
}
function ApprovalCard({ initial }: { initial: Approval }) {
  const { client, navigate, snapshot } = useApp(); const query = useQuery(`approval:${initial.id}`, () => client.call('GET /approvals/:id', { params: { id: initial.id } })); const approval = query.data || initial; const allowed = useGate(approval.gate); const intent = useIntent();
  async function resolve(decision: 'approve_once' | 'deny') { if (allowed) await intent.run(async () => query.setData(await client.call('POST /approvals/:id/resolve', { params: { id: approval.id }, body: { revision: approval.revision, clientNonce: nonce(), decision } }))); }
  return <div className="stack"><div className="row spread"><h3>{approval.title}</h3><span className="badge">{approval.scope.kind} · {approval.category.replaceAll('_', ' ')}</span></div><p>{approval.description}</p><dl><dt>Bot / destination machine</dt><dd>{snapshot.bots.find(bot => bot.id === approval.botId)?.name || approval.botId} · {approval.scope.machineLabel}</dd><dt>Exact target</dt><dd>{approval.target}</dd><dt>Review</dt><dd>{approval.policyMode} · {approval.review}{approval.ruleId && ` · rule ${approval.ruleId}`}</dd><dt>Origin</dt><dd>{approval.scope.origin || 'Not specified'}</dd></dl><h4>Consequences</h4><ul>{approval.scope.consequences.map((text, i) => <li key={i}>{text}</li>)}</ul><details><summary>Exact proposed inputs</summary><dl>{Object.entries(approval.inputs).map(([key, value]) => <div key={key}><dt>{key}</dt><dd>{typeof value === 'string' ? value : JSON.stringify(value)}</dd></div>)}</dl></details><GateState gate={approval.gate} /><ErrorNotice error={query.error} /><IntentNotice intent={intent} reconcile={query.reload} /><div className="row"><button className="primary" disabled={!allowed || intent.busy || intent.uncertain} onClick={() => void resolve('approve_once')}>Allow once</button><button className="danger" disabled={!allowed || intent.busy || intent.uncertain} onClick={() => void resolve('deny')}>Deny</button><button onClick={() => navigate({ screen: 'settings.policies', botId: approval.botId })}>Review separate future rules</button></div></div>;
}
function HumanCard({ initial }: { initial: HumanStep }) {
  const { client, navigate, snapshot } = useApp(); const query = useQuery(`human-step:${initial.id}`, () => client.call('GET /human-steps/:id', { params: { id: initial.id } })); const step = query.data || initial; const allowed = useGate(step.gate); const intent = useIntent(); const external = step.externalUrl && safeExternal(step.externalUrl);
  const hostAccess = snapshot.machines.some(machine => machine.id === step.machineId && (machine.ownerUserId === snapshot.user.id || machine.accessUserIds.includes(snapshot.user.id) || snapshot.member.role === 'owner' || snapshot.member.role === 'admin'));
  return <div className="stack"><h3>{step.title}</h3><span className="badge">Human step · {step.reason}</span><RichText text={step.instructions} /><p className="muted">Use your own browser/machine for secrets and login. “I'm done” asks the Bot to verify the result; it does not prove login succeeded.</p><GateState gate={step.gate} /><div className="row">{hostAccess && <><button onClick={() => navigate({ screen: 'machine.detail', id: step.machineId })}>Open machine</button><button onClick={() => navigate({ screen: 'machine.terminal', id: step.machineId })}>Open terminal</button></>}{external && <a href={external} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">Open external step</a>}</div><ErrorNotice error={query.error} /><IntentNotice intent={intent} reconcile={query.reload} /><div className="row">{(['done', 'skip'] as const).map(decision => <button key={decision} disabled={!allowed || intent.busy || intent.uncertain} onClick={() => void intent.run(async () => query.setData(await client.call('POST /human-steps/:id/resolve', { params: { id: step.id }, body: { revision: step.revision, clientNonce: nonce(), decision } })))}>{decision === 'done' ? "I'm done" : 'Skip'}</button>)}</div></div>;
}
function SecretCard({ initial }: { initial: SecretRequest }) {
  const { client, snapshot } = useApp(); const query = useQuery(`secret-request:${initial.id}`, () => client.call('GET /secret-requests/:id', { params: { id: initial.id } })); const request = query.data || initial; const allowed = useGate(request.gate); const intent = useIntent(); const [value, setValue] = useState('');
  useEffect(() => { if (!allowed) setValue(''); }, [allowed]);
  async function resolve(decision: 'save' | 'decline') { if (!allowed) return; const secret = value; setValue(''); await intent.run(async () => query.setData(await client.call('POST /secret-requests/:id/resolve', { params: { id: request.id }, body: { revision: request.revision, clientNonce: nonce(), decision, ...(decision === 'save' ? { value: secret } : {}) } }))); }
  return <form className="stack" onSubmit={event => { event.preventDefault(); void resolve('save'); }}><h3>Save securely: {request.name}</h3><p>{request.description}</p><p>Scope: {request.scope} · Machine: {snapshot.machines.find(machine => machine.id === request.machineId)?.name || request.machineId}</p><p className="muted">Write-only to destination storage, not chat. Co-resident Bots and privileged host users can access shared machine credentials. This is not OS isolation.</p><GateState gate={request.gate} /><Field label="Secret value"><input type="password" autoComplete="off" required maxLength={32768} value={value} disabled={!allowed || intent.busy || intent.uncertain} onChange={event => setValue(event.target.value)} /></Field><ErrorNotice error={query.error} /><IntentNotice intent={intent} reconcile={query.reload} /><div className="row"><button className="primary" disabled={!allowed || intent.busy || intent.uncertain || !value || new TextEncoder().encode(value).length > 32768}>Save securely</button><button type="button" disabled={!allowed || intent.busy || intent.uncertain} onClick={() => void resolve('decline')}>Decline and erase</button></div></form>;
}

function Recipients({ label, initial, required, disabled, change }: { label: string; initial: string[]; required: boolean; disabled: boolean; change: (recipients: string[]) => void }) {
  const [raw, setRaw] = useState(initial.join(', '));
  return <Field label={label} hint="Separate complete addresses with commas"><input disabled={disabled} required={required} value={raw} onChange={event => { setRaw(event.target.value); change(event.target.value.split(',').map(value => value.trim()).filter(Boolean)); }} /></Field>;
}

function DraftCard({ initial }: { initial: Draft }) {
  const { client, snapshot, online } = useApp();
  const query = useQuery(`draft:${initial.id}`, () => client.call('GET /drafts/:id', { params: { id: initial.id } }));
  const draft = query.data || initial; const intent = useIntent();
  const [content, setContent] = useState<DraftContent>(initial.content); const [baseRevision, setBaseRevision] = useState(initial.revision);
  const [dirty, setDirty] = useState(false); const [validation, setValidation] = useState<unknown>();
  const sources = useQuery(`draft-sources:${draft.botId}:${content.kind}`, async () => {
    const items: { id: string; label: string }[] = []; let cursor: string | undefined;
    if (content.kind === 'message') {
      do { const page = await client.call('GET /channels', { query: { botId: draft.botId, limit: 200, ...(cursor ? { cursor } : {}) } }); items.push(...page.items.filter(channel => channel.capabilities.outbound).map(channel => ({ id: channel.id, label: `${channel.adapter}: ${channel.accountId} (${channel.state})` }))); cursor = page.nextCursor || undefined; } while (cursor);
    } else {
      do { const page = await client.call('GET /bots/:id/connectors', { params: { id: draft.botId }, query: { limit: 200, ...(cursor ? { cursor } : {}) } }); items.push(...page.items.map(connector => ({ id: connector.id, label: `${connector.name}: ${connector.accountLabel} (${connector.state})` }))); cursor = page.nextCursor || undefined; } while (cursor);
    }
    return items;
  });
  useEffect(() => { if (!dirty) { setContent(draft.content); setBaseRevision(draft.revision); } }, [draft.revision, dirty]);
  const allowed = online && draft.ownerUserId === snapshot.user.id && draft.state === 'editable' && !intent.busy && !intent.uncertain && baseRevision === draft.revision;
  function change(next: DraftContent) { setDirty(true); setContent(next); }
  async function action(kind: 'save' | 'send' | 'discard') {
    if (!allowed) return;
    if (kind !== 'discard') {
      if (content.kind === 'email') {
        const recipients = [...content.to, ...content.cc, ...content.bcc];
        if (!content.from.trim() || !content.to.length || recipients.length > 50 || recipients.some(email => !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) { setValidation(new Error('Provide a From identity and valid recipients (at most 50 total).')); return; }
        if (content.attachmentIds.length > 10) { setValidation(new Error('Email allows at most 10 attachments.')); return; }
      } else if (!content.target.trim() || (content.kind === 'slack' && !content.workspace.trim())) { setValidation(new Error('Provide the exact destination and workspace.')); return; }
      if (!content.body.trim() && !content.attachmentIds.length) { setValidation(new Error('Provide a message body or an attachment.')); return; }
    }
    setValidation(undefined);
    await intent.run(async () => {
      const body = { revision: baseRevision, clientNonce: nonce() };
      const result = kind === 'send' ? await client.call('POST /drafts/:id/send', { params: { id: draft.id }, body: { ...body, content } }) : kind === 'save' ? await client.call('PATCH /drafts/:id', { params: { id: draft.id }, body: { ...body, content } }) : await client.call('POST /drafts/:id/discard', { params: { id: draft.id }, body });
      query.setData(result); setContent(result.content); setBaseRevision(result.revision); setDirty(false);
    });
  }
  async function upload(files: FileList | null) {
    if (!files || !allowed) return;
    await intent.run(async () => {
      const limit = content.kind === 'email' ? 10 : 6;
      if (content.attachmentIds.length + files.length > limit) throw new Error(`This draft allows at most ${limit} attachments.`);
      const ids = [...content.attachmentIds];
      for (const file of Array.from(files)) {
        if (content.kind === 'email' && (file.size > 10 * 1024 * 1024 || /\.(exe|com|bat|cmd|sh|ps1|msi|scr|app)$/i.test(file.name))) throw new Error('Email attachments must be non-executable and at most 10 MiB each.');
        const attachment = await client.upload(file, { clientNonce: nonce(), conversationId: draft.conversationId, purpose: 'message' }, file.name);
        ids.push(attachment.id); change({ ...content, attachmentIds: [...ids] });
      }
      if (content.kind === 'email') {
        const attachments = await Promise.all(ids.map(id => client.call('GET /attachments/:id', { params: { id } })));
        if (attachments.reduce((sum, attachment) => sum + attachment.size, 0) > 25 * 1024 * 1024) throw new Error('Email attachments exceed 25 MiB total. Remove files before sending.');
      }
    });
  }
  return <form className="stack" onSubmit={event => { event.preventDefault(); void action('send'); }}>
    <div className="row spread"><h3>Review {content.kind} draft</h3><span className="badge">{draft.state.replaceAll('_', ' ')}</span></div>
    <p className="muted small">Only explicit Send authorizes the exact content below. Reactions do not send. Source identity is not borrowed from another user.</p>
    <p>Bot: {snapshot.bots.find(bot => bot.id === draft.botId)?.name || draft.botId} · {content.kind === 'message' ? `Channel ${content.channelBindingId}` : `Connector ${content.connectorId}`}</p>
    <Field label={content.kind === 'message' ? 'Source channel identity' : 'Source connector account'}><select disabled={!allowed} value={content.kind === 'message' ? content.channelBindingId : content.connectorId} onChange={event => change(content.kind === 'message' ? { ...content, channelBindingId: event.target.value } : { ...content, connectorId: event.target.value })}><option value={content.kind === 'message' ? content.channelBindingId : content.connectorId}>Current source: {content.kind === 'message' ? content.channelBindingId : content.connectorId}</option>{sources.data?.filter(source => source.id !== (content.kind === 'message' ? content.channelBindingId : content.connectorId)).map(source => <option key={source.id} value={source.id}>{source.label}</option>)}</select></Field>
    <ErrorNotice error={sources.error} />
    {content.kind === 'email' ? <>
      <Field label="From"><input disabled={!allowed} value={content.from} required onChange={event => change({ ...content, from: event.target.value })} /></Field>
      {(['to', 'cc', 'bcc'] as const).map(key => <Recipients key={`${key}:${baseRevision}`} label={key.toUpperCase()} initial={content[key]} required={key === 'to'} disabled={!allowed} change={recipients => change({ ...content, [key]: recipients })} />)}
      <Field label="Subject"><input disabled={!allowed} value={content.subject} onChange={event => change({ ...content, subject: event.target.value })} /></Field>
    </> : <>
      {content.kind === 'slack' && <Field label="Slack workspace"><input disabled={!allowed} required value={content.workspace} onChange={event => change({ ...content, workspace: event.target.value })} /></Field>}
      <Field label="Exact target / channel / recipient"><input disabled={!allowed} required value={content.target} onChange={event => change({ ...content, target: event.target.value })} /></Field>
      <Field label="Thread (empty starts a new message)"><input disabled={!allowed} value={content.thread || ''} onChange={event => change({ ...content, thread: event.target.value || null })} /></Field>
    </>}
    <Field label="Message body"><textarea rows={8} disabled={!allowed} value={content.body} onChange={event => change({ ...content, body: event.target.value })} /></Field>
    <fieldset disabled={!allowed}><legend>Exact attachments</legend>{content.attachmentIds.map(id => <div className="row" key={id}><AttachmentLink id={id} /><button type="button" onClick={() => change({ ...content, attachmentIds: content.attachmentIds.filter(value => value !== id) })}>Remove from draft</button></div>)}<label>Add files<input type="file" multiple onChange={event => { void upload(event.target.files); event.target.value = ''; }} /></label></fieldset>
    {baseRevision !== draft.revision && dirty && <p className="error-notice">This draft changed on another device. Your unsaved content is retained. <button type="button" onClick={() => { setContent(draft.content); setBaseRevision(draft.revision); setDirty(false); }}>Use current server draft</button></p>}
    {draft.state === 'sending' && <p role="status">Send authorized; awaiting actual provider confirmation. Not yet sent.</p>}
    {draft.state === 'sent' && <p>Provider confirmed: {draft.providerMessageId || 'Sent receipt recorded'}</p>}
    {draft.state === 'outcome_unknown' && <p className="error-notice">Not confirmed. Inspect the actual provider before requesting another send. Do not resend this draft.</p>}
    {draft.state === 'failed' && <p className="error-notice">Send failed. Only backend reconciliation proving it was unsent can return this draft to editable.</p>}
    {draft.error && <p className="error-notice">{draft.error}</p>}
    <ErrorNotice error={validation || query.error} /><IntentNotice intent={intent} reconcile={query.reload} />
    <div className="row"><button className="primary" disabled={!allowed}>Send exact draft</button><button type="button" disabled={!allowed} onClick={() => void action('save')}>Save edits</button><button type="button" className="danger" disabled={!allowed} onClick={() => void action('discard')}>Discard</button><button type="button" onClick={() => void query.reload()}>Reconcile provider status</button></div>
  </form>;
}

function ConsentCard({ initial }: { initial: ConnectorConsent }) {
  const { client, snapshot } = useApp(); const query = useQuery(`consents:${initial.id}`, async () => {
    const items: ConnectorConsent[] = []; let cursor: string | undefined;
    do { const page = await client.call('GET /consents', { query: { limit: 200, ...(cursor ? { cursor } : {}) } }); items.push(...page.items); cursor = page.nextCursor || undefined; } while (cursor);
    return { items, nextCursor: null };
  });
  const consent = query.data?.items.find(item => item.id === initial.id) || initial;
  const connector = useQuery(`connector-consent-account:${consent.botId}`, async () => {
    const items: Connector[] = []; let cursor: string | undefined;
    do { const page = await client.call('GET /bots/:id/connectors', { params: { id: consent.botId }, query: { limit: 200, ...(cursor ? { cursor } : {}) } }); items.push(...page.items); cursor = page.nextCursor || undefined; } while (cursor);
    return { items, nextCursor: null };
  });
  const account = connector.data?.items.find(item => item.id === consent.connectorId);
  const [expiry, setExpiry] = useState(''); const intent = useIntent(); const allowed = useGate(consent.gate) && consent.accountOwnerUserId === snapshot.user.id;
  async function resolve(decision: 'allow_once' | 'allow_bot' | 'decline') {
    if (!allowed) return;
    await intent.run(async () => { const expiresAtMs = expiry ? new Date(expiry).getTime() : undefined; if (expiresAtMs !== undefined && (!Number.isFinite(expiresAtMs) || expiresAtMs <= Date.now())) throw new Error('Remembered consent expiry must be in the future.'); await client.call('POST /consents/:id/resolve', { params: { id: consent.id }, body: { revision: consent.revision, clientNonce: nonce(), decision, ...(decision === 'allow_bot' && expiresAtMs !== undefined ? { expiresAtMs } : {}) } }); await query.reload(); });
  }
  return <div className="stack"><h3>Connector account permission</h3><p>{account?.name || 'Connector'} · {account?.accountLabel || consent.connectorId}</p><p>Server: {account?.url || 'Inspect account configuration'}</p><p>Bot: {snapshot.bots.find(bot => bot.id === consent.botId)?.name || consent.botId}</p><p className="muted">Exact account-owner consent, not authorization for unrelated or consequential writes. Shared host access is separate.</p><GateState gate={consent.gate} /><Field label="Optional remembered permission expiry"><input type="datetime-local" value={expiry} disabled={!allowed || intent.busy || intent.uncertain} onChange={event => setExpiry(event.target.value)} /></Field><ErrorNotice error={query.error || connector.error} /><IntentNotice intent={intent} reconcile={query.reload} /><div className="row">{(['allow_once', 'allow_bot', 'decline'] as const).map(decision => <button key={decision} disabled={!allowed || intent.busy || intent.uncertain} onClick={() => void resolve(decision)}>{decision === 'allow_once' ? 'Allow once' : decision === 'allow_bot' ? 'Allow this Bot' : 'Decline'}</button>)}</div></div>;
}

function ConnectorRow({ connector }: { connector: Connector }) {
  const { navigate, snapshot } = useApp();
  const bot = snapshot.bots.find(value => value.id === connector.botId); const manage = connector.ownerUserId === snapshot.user.id || (connector.shared && (bot?.ownerUserId === snapshot.user.id || bot?.managerUserIds.includes(snapshot.user.id)));
  return <div className="panel stack"><div className="row spread"><strong>{connector.name}</strong><span className="badge">{connector.state.replaceAll('_', ' ')}</span></div><p>{connector.accountLabel} · {connector.url}</p>{connector.lastError && <p className="error-notice">{connector.lastError}</p>}<div className="row"><button onClick={() => navigate({ screen: 'connect.apps', botId: connector.botId, id: connector.id })}>{manage ? 'Configure / authenticate / reconnect / remove' : 'Inspect connection'}</button>{connector.state === 'blocked' && <span>Blocked by product policy; installation cannot override this.</span>}</div></div>;
}

function TeamCard({ card }: { card: Extract<Card, { type: 'team_access' }> }) {
  const { client, snapshot, navigate, online } = useApp(); const query = useQuery(`bot:${card.botId}`, () => client.call('GET /bots/:id', { params: { id: card.botId } })); const bot = query.data; const intent = useIntent();
  return <div className="stack"><h3>{bot?.name || 'Team Bot'}</h3><p>Owner: {card.ownerUserId} · {bot ? bot.published ? 'Published' : 'Unpublished' : card.state}</p><p>{card.reason}</p><p className="muted">A private DM is yours alone. No other member’s history, notes or credentials are imported.</p><ErrorNotice error={query.error} /><IntentNotice intent={intent} reconcile={query.reload} /><div className="row">{bot?.ownerUserId === snapshot.user.id && <button disabled={!online || intent.busy || intent.uncertain} onClick={() => void intent.run(async () => query.setData(await client.call('PATCH /bots/:id', { params: { id: bot.id }, body: { revision: bot.revision, clientNonce: nonce(), published: !bot.published } })))}>{bot.published ? 'Unpublish' : 'Publish for the team'}</button>}{bot && (bot.ownerUserId === snapshot.user.id || bot.managerUserIds.includes(snapshot.user.id)) && <button onClick={() => navigate({ screen: 'bot.settings', id: bot.id })}>Maintain setup</button>}<button disabled={!online || !bot?.published || intent.busy || intent.uncertain || card.state === 'unavailable'} onClick={() => void intent.run(async () => { const conversation = await client.call('POST /conversations', { body: { clientNonce: nonce(), kind: 'team_dm', botIds: [card.botId] } }); navigate({ screen: 'conversation', id: conversation.id }); })}>Start my private DM</button></div></div>;
}

export function TranscriptCard({ card }: { card: Card }) {
  const { navigate, reportError, snapshot } = useApp();
  if ((card.type === 'secret_request' && card.request.gate.targetUserId !== snapshot.user.id) ||
      (card.type === 'human_step' && card.step.gate.targetUserId !== snapshot.user.id) ||
      ((card.type === 'email_draft' || card.type === 'slack_draft' || card.type === 'message_draft') && card.draft.ownerUserId !== snapshot.user.id) ||
      ((card.type === 'permission_request' || card.type === 'auto_review_approval' || card.type === 'local_tool_permission' || card.type === 'publish_approval') && card.approval.gate.targetUserId !== snapshot.user.id) ||
      (card.type === 'connector_grant' && card.consent.accountOwnerUserId !== snapshot.user.id)) return <p className="muted">Private request for its designated account owner. Its content and actions are not available here.</p>;
  switch (card.type) {
    case 'text': return <RichText text={card.text} />;
    case 'attachment': return <><RichText text={card.caption} /><AttachmentLink id={card.attachmentId} /></>;
    case 'link': { const url = safeExternal(card.url); return <div className="stack"><strong>{card.title}</strong><p>{card.description}</p>{url ? <><span className="muted">{new URL(url).host}</span><a href={url} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">Open source</a><button onClick={() => void copyText(url).catch(reportError)}>Copy link</button></> : <p>Unsupported or unsafe link. Only HTTP(S) sources can be opened.</p>}</div>; }
    case 'widget': return <QuestionCard id={card.questionId} />;
    case 'user_form': return <QuestionCard id={card.question.id} initial={card.question} />;
    case 'secret_request': return <SecretCard initial={card.request} />;
    case 'human_step': return <HumanCard initial={card.step} />;
    case 'email_draft': case 'slack_draft': case 'message_draft': return <DraftCard initial={card.draft} />;
    case 'permission_request': case 'auto_review_approval': case 'local_tool_permission': case 'publish_approval': return <ApprovalCard initial={card.approval} />;
    case 'connector_grant': return <ConsentCard initial={card.consent} />;
    case 'connector': return <ConnectorRow connector={card.connector} />;
    case 'connectors': return <div className="stack">{card.connectors.map(connector => <ConnectorRow key={connector.id} connector={connector} />)}</div>;
    case 'scm_connect': return <div className="stack"><h3>{card.provider} source control</h3><p>{card.reason}</p><button onClick={() => navigate({ screen: 'connect.apps', id: card.connectorId })}>Configure / authenticate verified connector</button></div>;
    case 'listener_connect': case 'slack_connect': return <div className="stack"><h3>{card.channelBinding.adapter} connection</h3><p>{card.channelBinding.accountId} · {card.channelBinding.target}</p><span className="badge">{card.channelBinding.state} · {card.channelBinding.enabled ? 'Enabled' : 'Disabled'}</span><p>Inbound: {card.channelBinding.capabilities.inbound ? 'Supported' : 'Unavailable'} · Outbound: {card.channelBinding.capabilities.outbound ? 'Supported' : 'Unavailable'}</p><p>Events: {card.channelBinding.capabilities.events.join(', ') || 'None advertised'}</p>{card.channelBinding.lastError && <p className="error-notice">{card.channelBinding.lastError}</p>}<button onClick={() => navigate({ screen: 'integrations.channels', id: card.channelBinding.id, botId: card.channelBinding.botId })}>Install / authorize / check / reopen / remove</button></div>;
    case 'team_access': return <TeamCard card={card} />;
    case 'bot_template_share': return <div className="stack"><h3>{card.name}</h3><span className="badge">{card.state.replaceAll('_', ' ')}</span><p>Import creates a separate owned Bot, not access to the sender’s credentials, history or learned memory.</p><button onClick={() => navigate({ screen: 'templates', id: card.templateId })}>Review provenance, terms and details</button><button disabled={card.state !== 'available'} onClick={() => navigate({ screen: 'templates', id: card.templateId, tab: 'import' })}>Import a reviewed copy</button>{safeExternal(card.shareUrl) && <button onClick={() => void copyText(card.shareUrl).catch(reportError)}>Copy share link</button>}</div>;
    case 'voice_memo': return <VoiceMemo attachmentId={card.attachmentId} transcript={card.transcript} durationMs={card.durationMs} peaks={card.peaks} />;
    case 'handoff': return <div className="stack"><h3>Specialist: {snapshot.bots.find(bot => bot.id === card.targetBotId)?.name || card.targetBotId}</h3><span className="badge">{card.state}</span><RichText text={card.text} /><button onClick={() => navigate({ screen: 'conversation', id: card.targetConversationId })}>Open specialist task and results</button></div>;
    case 'calendar_event': { const event = card.event; const url = event.sourceUrl && safeExternal(event.sourceUrl); return <div className="stack"><h3>{event.subject}</h3><span className="badge">{event.status} · {event.allDay ? 'All day' : 'Timed'}</span><p>{formatTime(event.startAtMs)} – {formatTime(event.endAtMs)} · {event.timezone}</p><p>Guests: {event.guests.join(', ') || 'None'} · Location: {event.location || 'None'}</p><p className="muted">Read-only preview. A proposed change still needs its separate approval; viewing is not consent.</p>{url && <a href={url} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">Open source calendar</a>}</div>; }
    default: return <p className="error-notice">Unsupported card. Update this client to view it. No action has been authorized.</p>;
  }
}
