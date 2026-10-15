import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { createSCIMRoutes, scimFilter } from '../../src/enterprise/scim';
import { createTokenRoutes, secureToken } from '../../src/enterprise/tokens';
import { identityFixture, invokeRoute } from './identity.test';
const userURN = 'urn:ietf:params:scim:schemas:core:2.0:User'; const groupURN = 'urn:ietf:params:scim:schemas:core:2.0:Group'; const patchURN = 'urn:ietf:params:scim:api:messages:2.0:PatchOp';
async function scimFixture(scopes = ['scim.users', 'scim.groups']) {
  const fixture = identityFixture(); const issued = await invokeRoute(createTokenRoutes(fixture.services), fixture.services, 'POST', '/v1/integration-tokens', { clientNonce: secureToken(), name: 'Directory', kind: 'scim', scopes }, { principal: fixture.principal }) as P.IntegrationTokenIssued;
  const routes = createSCIMRoutes(fixture.services);
  const call = async (method: string, path: string, body?: unknown, options: { id?: string; etag?: string; query?: string; headers?: Record<string, string> } = {}): Promise<Response> => await invokeRoute(routes, fixture.services, method, `/v1/scim/v2/${path}`, body, { params: options.id ? { id: options.id } : {}, query: options.query, headers: { authorization: `Bearer ${issued.token}`, 'content-type': 'application/scim+json', ...(options.etag ? { 'if-match': options.etag } : {}), ...options.headers } }) as Response;
  return { ...fixture, routes, call, issued };
}
const input = (externalId: string, userName = `${externalId}@example.com`): P.SCIMUserInput => ({ schemas: [userURN], externalId, userName, displayName: externalId, active: true, name: { givenName: 'Directory', familyName: 'Member' }, emails: [{ value: userName, primary: true, type: 'work' }] });

describe('RFC SCIM directory behavior', () => {
  test('discovery truthfully advertises supported schemas, scopes and no bulk', async () => {
    const f = await scimFixture(['scim.users']); try {
      const config = await f.call('GET', 'ServiceProviderConfig'); expect(config.status).toBe(200); expect(config.headers.get('content-type')).toBe('application/scim+json'); const value = await config.json() as P.SCIMServiceProviderConfig; expect(value.bulk.supported).toBe(false); expect(value.etag.supported).toBe(true); expect(value.patch.supported).toBe(true);
      expect((await f.call('GET', 'Groups')).status).toBe(403);
      const schemas = await (await f.call('GET', 'Schemas')).json() as P.SCIMList<P.SCIMSchema>; expect(schemas.totalResults).toBe(2); expect(schemas.Resources[0]!.attributes.some(attribute => attribute.name === 'userName')).toBe(true);
      expect((await f.call('GET', 'Schemas/:id', undefined, { id: userURN })).status).toBe(200);
      expect((await f.call('GET', 'ResourceTypes/:id', undefined, { id: 'User' })).status).toBe(200);
      const unauthenticated = await invokeRoute(f.routes, f.services, 'GET', '/v1/scim/v2/Users') as Response; expect(unauthenticated.status).toBe(401); expect((await unauthenticated.json() as P.SCIMError).schemas).toEqual(['urn:ietf:params:scim:api:messages:2.0:Error']);
    } finally { f.close(); }
  });
  test('create deduplicates externalId, preserves privacy and applies normalized filters/projections', async () => {
    const f = await scimFixture(); try {
      const created = await f.call('POST', 'Users', input('alice', 'ALICE@example.com')); expect(created.status).toBe(201); const alice = await created.json() as P.SCIMUser; expect(alice.userName).toBe('alice@example.com'); expect(created.headers.get('etag')).toBe('"1"'); expect(alice.meta.created).toBe(new Date(f.services.now()).toISOString());
      expect((await f.call('POST', 'Users', input('alice', 'alice@example.com'))).status).toBe(200);
      expect((await f.call('POST', 'Users', { ...input('alice'), displayName: 'Changed' })).status).toBe(409);
      expect((await f.call('POST', 'Users', input('bob'))).status).toBe(201);
      const listed = await (await f.call('GET', 'Users', undefined, { query: 'filter=userName%20eq%20%22ALICE%40example.com%22%20and%20active%20eq%20true&attributes=userName,name.givenName&count=1' })).json() as P.SCIMList<P.SCIMUser>; expect(listed.totalResults).toBe(1); expect(listed.Resources[0]!.id).toBe(alice.id); expect(listed.Resources[0]!.displayName).toBeUndefined(); expect(listed.Resources[0]!.name).toEqual({ givenName: 'Directory' }); expect(listed.Resources[0]!.schemas).toEqual([userURN]); expect(listed.Resources[0]!.meta).toBeDefined();
      const omitted = await (await f.call('GET', 'Users/:id', undefined, { id: alice.id, query: 'excludedAttributes=emails,name.familyName,id,meta' })).json() as P.SCIMUser; expect(omitted.emails).toBeUndefined(); expect(omitted.id).toBe(alice.id); expect(omitted.meta).toBeDefined();
      const serialized = JSON.stringify(listed); expect(serialized).not.toContain('password'); expect(serialized).not.toContain('token'); expect(serialized).not.toContain('preferences');
      expect((await f.call('GET', 'Users', undefined, { query: 'filter=userName%20co%20%22alice%22' })).status).toBe(400);
      expect((await f.call('GET', 'Users', undefined, { query: 'filter=userName%20eq%20%22alice%40example.com%22%20or%20active%20eq%20true' })).status).toBe(400);
      const zero = await (await f.call('GET', 'Users', undefined, { query: 'count=0' })).json() as P.SCIMList<P.SCIMUser>; expect(zero.totalResults).toBe(2); expect(zero.Resources).toHaveLength(0);
    } finally { f.close(); }
  });
  test('PUT replaces optional attributes; If-Match fences racing PATCH and deletion', async () => {
    const f = await scimFixture(); try {
      const user = await (await f.call('POST', 'Users', input('racing'))).json() as P.SCIMUser;
      expect((await f.call('PATCH', 'Users/:id', { schemas: [patchURN], Operations: [{ op: 'replace', path: 'displayName', value: 'No version' }] }, { id: user.id })).status).toBe(428);
      const [first, second] = await Promise.all(['First', 'Second'].map(value => f.call('PATCH', 'Users/:id', { schemas: [patchURN], Operations: [{ op: 'replace', path: 'displayName', value }] }, { id: user.id, etag: user.meta.version })));
      expect([first.status, second.status].sort()).toEqual([200, 412]); const winner = await (first.status === 200 ? first : second).json() as P.SCIMUser;
      const replacement = await f.call('PUT', 'Users/:id', { schemas: [userURN], userName: user.userName, active: true }, { id: user.id, etag: winner.meta.version }); expect(replacement.status).toBe(200); const replaced = await replacement.json() as P.SCIMUser; expect(replaced.name).toBeUndefined(); expect(replaced.externalId).toBeUndefined(); expect(replaced.emails).toBeUndefined();
      expect((await f.call('PATCH', 'Users/:id', { schemas: [patchURN], Operations: [{ op: 'add', path: 'roles', value: ['owner'] }] }, { id: user.id, etag: replaced.meta.version })).status).toBe(400);
      expect((await f.call('DELETE', 'Users/:id', undefined, { id: user.id, etag: winner.meta.version })).status).toBe(412);
      const deleted = await f.call('DELETE', 'Users/:id', undefined, { id: user.id, etag: replaced.meta.version }); expect(deleted.status).toBe(204); expect(await deleted.text()).toBe(''); expect(f.services.store.get('users', user.id)).not.toBeNull(); expect(f.services.auth.member(user.id).enabled).toBe(false);
    } finally { f.close(); }
  });
  test('inactive directory users immediately revoke sessions/devices/gates/future routines without host content deletion', async () => {
    const f = await scimFixture(); try {
      const user = await (await f.call('POST', 'Users', input('inactive'))).json() as P.SCIMUser; await f.services.auth.session(user.id);
      const device = f.services.resource('device', { userId: user.id, platform: 'web' as const, name: 'Browser', appVersion: '1', pushEnabled: true, lastSeenAtMs: f.services.now() }); f.services.store.put('devices', device);
      const routine = f.services.resource('routine', { ownerUserId: user.id, botId: 'bot', name: 'Future task', instruction: 'Retain host files', trigger: { kind: 'webhook' as const }, enabled: true, nextRunAtMs: null, scheduleDescription: 'Webhook', lastRunId: null, webhookUrl: null, cronJobId: null }); f.services.store.put('routines', routine);
      f.services.store.put('privateContent', { id: 'private', userId: user.id, text: 'Retained private content' });
      const response = await f.call('PATCH', 'Users/:id', { schemas: [patchURN], Operations: [{ op: 'replace', path: 'active', value: false }] }, { id: user.id, etag: user.meta.version }); expect(response.status).toBe(200); expect(f.revoked).toContain(user.id); expect(f.cancelled).toContain(user.id); expect(f.services.store.list('authSessions')).toHaveLength(0); expect(f.services.store.list('devices')).toHaveLength(0); expect(f.services.store.get<P.Routine>('routines', routine.id)?.enabled).toBe(false); expect(f.services.store.get('privateContent', 'private')).not.toBeNull();
      expect(f.services.auth.member(user.id).role).toBe('member');
    } finally { f.close(); }
  });
  test('groups are directory provenance, support filtered membership PATCH and never grant owner', async () => {
    const f = await scimFixture(); try {
      const alice = await (await f.call('POST', 'Users', input('a'))).json() as P.SCIMUser; const bob = await (await f.call('POST', 'Users', input('b'))).json() as P.SCIMUser;
      const created = await f.call('POST', 'Groups', { schemas: [groupURN], externalId: 'engineering', displayName: 'Engineering', members: [{ value: alice.id }] }); expect(created.status).toBe(201); const group = await created.json() as P.SCIMGroup;
      const patched = await f.call('PATCH', 'Groups/:id', { schemas: [patchURN], Operations: [{ op: 'add', path: 'members', value: [{ value: bob.id }] }, { op: 'remove', path: `members[value eq "${alice.id}"]` }] }, { id: group.id, etag: group.meta.version }); expect(patched.status).toBe(200); const result = await patched.json() as P.SCIMGroup; expect(result.members.map(value => value.value)).toEqual([bob.id]);
      expect(f.services.store.get<P.DirectoryGroup>('directoryGroups', group.id)?.source).toBe('scim'); expect(f.services.store.list<P.GroupPolicy>('groupPolicies').find(policy => policy.directoryGroupId === group.id)?.reviewExempt).toBe(false); expect(f.services.auth.member(bob.id).role).toBe('member');
      const user = await (await f.call('GET', 'Users/:id', undefined, { id: bob.id })).json() as P.SCIMUser; expect(user.groups).toEqual([{ value: group.id, display: 'Engineering' }]);
      expect((await f.call('PATCH', 'Groups/:id', { schemas: [patchURN], Operations: [{ op: 'add', path: 'members', value: [{ value: 'missing' }] }] }, { id: group.id, etag: result.meta.version })).status).toBe(400);
      expect((await f.call('DELETE', 'Groups/:id', undefined, { id: group.id, etag: result.meta.version })).status).toBe(204); expect(f.services.store.list('groupPolicies')).toHaveLength(0);
    } finally { f.close(); }
  });
  test('provider delivery headers fence creates without externalId and invalid projections never mutate', async () => {
    const f = await scimFixture(); try {
      const body = { schemas: [userURN], userName: 'header@example.com', active: true };
      const [first, second] = await Promise.all([f.call('POST', 'Users', body, { headers: { 'x-scim-request-id': 'delivery-1' } }), f.call('POST', 'Users', body, { headers: { 'x-scim-request-id': 'delivery-1' } })]);
      expect([first.status, second.status].sort()).toEqual([200, 201]);
      expect(f.services.store.list('scimUsers')).toHaveLength(1);
      expect((await f.call('POST', 'Users', { ...body, displayName: 'Conflicting' }, { headers: { 'x-scim-request-id': 'delivery-1' } })).status).toBe(409);
      expect((await f.call('POST', 'Users', input('invalid-projection'), { query: 'attributes=constructor' })).status).toBe(400);
      expect(f.services.store.list('scimUsers')).toHaveLength(1);
      const user = await first.json() as P.SCIMUser;
      const nameAdded = await f.call('PATCH', 'Users/:id', { schemas: [patchURN], Operations: [{ op: 'add', path: 'name', value: { familyName: 'Surname' } }, { op: 'add', path: 'name', value: { givenName: 'Given' } }] }, { id: user.id, etag: user.meta.version });
      expect((await nameAdded.json() as P.SCIMUser).name).toEqual({ familyName: 'Surname', givenName: 'Given' });
    } finally { f.close(); }
  });
  test('strong ETags change when read-only membership and member displays change', async () => {
    const f = await scimFixture(); try {
      const user = await (await f.call('POST', 'Users', input('versions'))).json() as P.SCIMUser;
      const group = await (await f.call('POST', 'Groups', { schemas: [groupURN], displayName: 'Versions', members: [{ value: user.id }] })).json() as P.SCIMGroup;
      const currentUser = await (await f.call('GET', 'Users/:id', undefined, { id: user.id })).json() as P.SCIMUser;
      expect(currentUser.meta.version).not.toBe(user.meta.version);
      expect((await f.call('PATCH', 'Users/:id', { schemas: [patchURN], Operations: [{ op: 'replace', path: 'displayName', value: 'Changed' }] }, { id: user.id, etag: user.meta.version })).status).toBe(412);
      expect((await f.call('PATCH', 'Users/:id', { schemas: [patchURN], Operations: [{ op: 'replace', path: 'displayName', value: 'Changed' }] }, { id: user.id, etag: currentUser.meta.version })).status).toBe(200);
      const currentGroup = await (await f.call('GET', 'Groups/:id', undefined, { id: group.id })).json() as P.SCIMGroup;
      expect(currentGroup.meta.version).not.toBe(group.meta.version);
      expect((await f.call('DELETE', 'Groups/:id', undefined, { id: group.id, etag: group.meta.version })).status).toBe(412);
    } finally { f.close(); }
  });
  test('RFC attribute names are case-insensitive and adding existing multi-values is idempotent', async () => {
    const f = await scimFixture(); try {
      const created = await f.call('POST', 'Users', { SCHEMAS: [userURN], USERNAME: 'CASE@example.com', ACTIVE: true, EMAILS: [{ VALUE: 'CASE@example.com', PRIMARY: true }] });
      expect(created.status).toBe(201); const user = await created.json() as P.SCIMUser;
      const patched = await f.call('PATCH', 'Users/:id', { schemas: [patchURN], operations: [{ OP: 'ADD', PATH: 'EMAILS', VALUE: [{ VALUE: 'case@example.com', PRIMARY: true }] }] }, { id: user.id, etag: user.meta.version });
      expect(patched.status).toBe(200); const result = await patched.json() as P.SCIMUser; expect(result.emails).toHaveLength(1);
      const projection = await (await f.call('GET', 'Users/:id', undefined, { id: user.id, query: 'attributes=USERNAME' })).json() as P.SCIMUser;
      expect(projection.userName).toBe('case@example.com'); expect(projection.emails).toBeUndefined();
      expect((await f.call('POST', 'Users', { schemas: [userURN], userName: 'duplicate@example.com', USERNAME: 'other@example.com', active: true })).status).toBe(400);
    } finally { f.close(); }
  });
  test('final owner cannot be deprovisioned and filters reject all unsupported syntax', async () => {
    const f = await scimFixture(); try {
      const owner = f.services.auth.user(f.principal.userId); f.services.store.put('scimUsers', { ...input('owner'), id: owner.id, userName: owner.email, meta: { resourceType: 'User', created: new Date(owner.createdAtMs).toISOString(), lastModified: new Date(owner.updatedAtMs).toISOString(), location: 'https://product.example/v1/scim/v2/Users/owner', version: '"1"' } });
      expect((await f.call('PATCH', 'Users/:id', { schemas: [patchURN], Operations: [{ op: 'replace', path: 'active', value: false }] }, { id: owner.id, etag: '"1"' })).status).toBe(409); expect((await f.call('DELETE', 'Users/:id', undefined, { id: owner.id, etag: '"1"' })).status).toBe(409); expect(f.services.auth.member(owner.id).enabled).toBe(true); expect(f.revoked).toHaveLength(0);
      for (const filter of ['', 'active eq "true"', 'active eq true and', 'userName eq "a" junk', 'password eq "secret"', 'active pr', 'userName eq "a" or active eq true']) expect(() => scimFilter(filter)).toThrow();
      expect(scimFilter('externalId eq "A and B"')({ externalId: 'A and B' })).toBe(true);
      expect(scimFilter('externalId eq "A and B"')({ externalId: 'a and b' })).toBe(false);
    } finally { f.close(); }
  });
});
