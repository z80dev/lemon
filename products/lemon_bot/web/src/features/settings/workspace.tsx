import { useState } from 'react';
import { nonce, type Workspace, type WorkspaceUpdate } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { useQuery, Field, ErrorNotice, Loading } from '../../ui';
import { useIntent, IntentNotice, Toggle } from './shared';

export function WorkspaceSettings() {
  const { client, refresh } = useApp();
  const workspace = useQuery('settings:workspace', () => client.call('GET /workspace'));
  const intent = useIntent(async () => { await workspace.reload(); await refresh(); });
  return <div className="stack"><IntentNotice intent={intent} /><ErrorNotice error={workspace.error} />{workspace.loading && !workspace.data && <Loading />}{workspace.data && <WorkspaceEditor key={workspace.data.revision} workspace={workspace.data} disabled={intent.disabled} onSave={async body => {
    const saved = await intent.run(() => client.call('PATCH /workspace', { body: { ...body, revision: workspace.data!.revision, clientNonce: nonce() } }));
    if (saved) { workspace.setData(saved); await refresh(); }
  }} />}</div>;
}
function WorkspaceEditor({ workspace, disabled, onSave }: { workspace: Workspace; disabled: boolean; onSave: (body: Pick<WorkspaceUpdate, 'name' | 'timezone' | 'enabled'>) => Promise<void> }) {
  const [name, setName] = useState(workspace.name);
  const [timezone, setTimezone] = useState(workspace.timezone);
  const [enabled, setEnabled] = useState(workspace.enabled);
  return <form className="panel stack" onSubmit={event => { event.preventDefault(); void onSave({ name, timezone, enabled }); }}><h2>Your workspace</h2><p className="muted">This workspace contains your own Bots and machines. Connecting a device does not invite another owner or transfer ownership.</p><fieldset className="stack" disabled={disabled}><div className="grid"><Field label="Workspace name"><input required maxLength={120} value={name} onChange={event => setName(event.target.value)} /></Field><Field label="Timezone (IANA)"><input required value={timezone} onChange={event => setTimezone(event.target.value)} /></Field></div><Toggle label="Workspace enabled" checked={enabled} onChange={setEnabled} hint="Disabling blocks assistant work; owner repair controls remain available." /><button className="primary">Save workspace</button></fieldset></form>;
}
