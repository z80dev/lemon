import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, RequestContext, Route } from '../core/services';
import { ApiError } from '../core/errors';
import { authenticateIntegration } from './tokens';
import { createIdentityServices, createProvisionedUser } from './identity';

const prefix = 'urn:ietf:params:scim:';
const URN = { user: `${prefix}schemas:core:2.0:User`, group: `${prefix}schemas:core:2.0:Group`, patch: `${prefix}api:messages:2.0:PatchOp`, list: `${prefix}api:messages:2.0:ListResponse`, error: `${prefix}api:messages:2.0:Error`, schema: `${prefix}schemas:core:2.0:Schema`, resourceType: `${prefix}schemas:core:2.0:ResourceType`, config: `${prefix}schemas:core:2.0:ServiceProviderConfig` };
const string = z.string().min(1).max(256);
const nameSchema = z.strictObject({ givenName: z.string().max(120).optional(), familyName: z.string().max(120).optional(), formatted: z.string().max(240).optional() });
const emailSchema = z.strictObject({ value: z.email().max(254), primary: z.boolean().optional(), type: z.string().max(40).optional() });
const memberSchema = z.strictObject({ value: string, display: z.string().max(120).optional() });
const userSchema = z.strictObject({ schemas: z.array(z.string()).length(1).refine(value => value[0] === URN.user), externalId: string.optional(), userName: z.email().max(254), name: nameSchema.optional(), displayName: z.string().max(120).optional(), active: z.boolean(), emails: z.array(emailSchema).max(100).optional() });
const groupSchema = z.strictObject({ schemas: z.array(z.string()).length(1).refine(value => value[0] === URN.group), externalId: string.optional(), displayName: z.string().trim().min(1).max(120), members: z.array(memberSchema).max(10000) });
const patchSchema = z.strictObject({ schemas: z.array(z.string()).length(1).refine(value => value[0] === URN.patch), Operations: z.array(z.strictObject({ op: z.string().transform(value => value.toLowerCase()).pipe(z.enum(['add', 'replace', 'remove'])), path: z.string().max(512).optional(), value: z.unknown().optional() })).min(1).max(100) });
class SCIMFailure extends Error {
  constructor(readonly status: number, detail: string, readonly scimType?: string) { super(detail); }
}
function invalid(detail: string, type = 'invalidValue'): never { throw new SCIMFailure(400, detail, type); }
const attributeNames: Record<string, string> = { schemas: 'schemas', externalid: 'externalId', username: 'userName', name: 'name', givenname: 'givenName', familyname: 'familyName', formatted: 'formatted', displayname: 'displayName', active: 'active', emails: 'emails', value: 'value', primary: 'primary', type: 'type', members: 'members', display: 'display', operations: 'Operations', op: 'op', path: 'path', id: 'id', meta: 'meta', groups: 'groups' };
function canonicalAttributes(value: unknown, depth = 0): unknown {
  if (depth > 16) invalid('SCIM attributes exceed the schema nesting limit.');
  if (Array.isArray(value)) return value.map(item => canonicalAttributes(item, depth + 1));
  if (!value || typeof value !== 'object') return value;
  const seen = new Set<string>(); const entries: [string, unknown][] = [];
  for (const [key, child] of Object.entries(value)) {
    const lower = key.toLowerCase(); const canonical = Object.hasOwn(attributeNames, lower) ? attributeNames[lower]! : key;
    if (seen.has(canonical)) invalid('A SCIM attribute was supplied more than once.');
    seen.add(canonical); entries.push([canonical, canonicalAttributes(child, depth + 1)]);
  }
  return Object.fromEntries(entries);
}
function validate<T>(schema: z.ZodType<T>, value: unknown): T {
  const result = schema.safeParse(canonicalAttributes(value)); if (!result.success) invalid('The SCIM resource contains invalid or unsupported attributes.'); return result.data;
}
function scimResponse(context: RequestContext, value: unknown, status = 200, etag?: string, location?: string): Response {
  const headers = new Headers({ 'Content-Type': 'application/scim+json', 'Cache-Control': 'no-store', 'X-Request-Id': context.requestId });
  if (etag) headers.set('ETag', etag); if (location) headers.set('Location', location);
  return new Response(status === 204 ? null : JSON.stringify(value), { status, headers });
}
function ifMatch(context: RequestContext, version: string): void {
  if (!context.request.headers.has('if-match')) throw new SCIMFailure(428, 'If-Match is required for existing resources.');
  if (context.request.headers.get('if-match') !== version) throw new SCIMFailure(412, 'The SCIM resource version changed.');
}
function meta(services: BackendServices, type: 'User' | 'Group', resource: P.Resource): P.SCIMMeta {
  return { resourceType: type, created: new Date(resource.createdAtMs).toISOString(), lastModified: new Date(resource.updatedAtMs).toISOString(), location: `${services.config.publicUrl.replace(/\/$/, '')}/v1/scim/v2/${type}s/${encodeURIComponent(resource.id)}`, version: `"${resource.revision}"` };
}
function userView(services: BackendServices, user: P.SCIMUser): P.SCIMUser {
  const directory = services.store.list<P.DirectoryGroup>('directoryGroups', group => group.memberUserIds.includes(user.id)).sort((a, b) => a.id.localeCompare(b.id));
  const groups = directory.map(group => ({ value: group.id, display: group.name }));
  const version = groups.length ? `"${user.meta.version.slice(1, -1)}-${services.mutations.digest(directory.map(group => ({ id: group.id, name: group.name, updatedAtMs: group.updatedAtMs })))}"` : user.meta.version;
  return { ...user, groups, meta: { ...user.meta, lastModified: new Date(Math.max(Date.parse(user.meta.lastModified), ...directory.map(group => group.updatedAtMs))).toISOString(), version } };
}
function groupView(services: BackendServices, group: P.DirectoryGroup): P.SCIMGroup {
  const users = group.memberUserIds.map(value => services.store.require<P.User>('users', value));
  const members = users.map(user => ({ value: user.id, display: user.displayName }));
  const metadata = meta(services, 'Group', group);
  return { schemas: [URN.group], id: group.id, ...(group.externalId !== null ? { externalId: group.externalId } : {}), displayName: group.name, members, meta: { ...metadata, lastModified: new Date(Math.max(group.updatedAtMs, ...users.map(user => user.updatedAtMs))).toISOString(), version: members.length ? `"${group.revision}-${services.mutations.digest(users.map(user => ({ id: user.id, displayName: user.displayName, updatedAtMs: user.updatedAtMs })))}"` : metadata.version } };
}
interface CreateFence { id: string; requestDigest: string; resourceId: string }
function createFence(services: BackendServices, context: RequestContext, kind: 'User' | 'Group', input: unknown): { key: string | null; resourceId: string | null; digest: string } {
  const requestId = context.request.headers.get('x-scim-request-id') ?? context.request.headers.get('x-request-id');
  const digest = services.mutations.digest(input);
  if (requestId === null) return { key: null, resourceId: null, digest };
  if (!/^[A-Za-z0-9_.:-]{1,256}$/.test(requestId)) invalid('Invalid SCIM request correlation header.');
  const key = services.mutations.digest({ workspaceId: context.user!.workspaceId, principalId: context.user!.id, kind, requestId });
  const fence = services.store.get<CreateFence>('scimCreateFences', key);
  if (fence && fence.requestDigest !== digest) throw new SCIMFailure(409, 'The delivery identifier was reused with different attributes.', 'uniqueness');
  return { key, resourceId: fence?.resourceId ?? null, digest };
}
function normalize(input: P.SCIMUserInput): P.SCIMUserInput {
  const userName = input.userName.trim().toLowerCase(); const emails = input.emails?.map(email => ({ ...email, value: email.value.trim().toLowerCase() }));
  if (emails && (emails.filter(email => email.primary).length > 1 || new Set(emails.map(email => email.value)).size !== emails.length)) invalid('Email values must be unique and have at most one primary.');
  return { ...input, userName, ...(emails ? { emails } : {}) };
}
function userUniqueness(services: BackendServices, input: P.SCIMUserInput, id?: string): void {
  if (services.store.list<P.SCIMUser>('scimUsers', user => user.id !== id && (user.userName === input.userName || input.externalId !== undefined && user.externalId === input.externalId)).length || services.store.list<P.User>('users', user => user.id !== id && user.email === input.userName).length) throw new SCIMFailure(409, 'The userName or externalId already belongs to an identity.', 'uniqueness');
}
function groupUniqueness(services: BackendServices, input: P.SCIMGroupInput, id?: string): void {
  if (services.store.list<P.DirectoryGroup>('directoryGroups', group => group.id !== id && (group.name.toLowerCase() === input.displayName.toLowerCase() || input.externalId !== undefined && group.externalId === input.externalId)).length) throw new SCIMFailure(409, 'The group displayName or externalId is already in use.', 'uniqueness');
  if (new Set(input.members.map(member => member.value)).size !== input.members.length) invalid('Group members must be unique.');
  for (const member of input.members) if (!services.store.get<P.SCIMUser>('scimUsers', member.value)) invalid('Group members must reference existing SCIM Users.');
}
function protectOwner(services: BackendServices, userId: string): void {
  const member = services.store.list<P.Member>('members').find(value => value.userId === userId);
  if (member?.role === 'owner' && member.enabled && services.store.list<P.Member>('members', value => value.enabled && value.role === 'owner').length <= 1) throw new SCIMFailure(409, 'The final owner cannot be deprovisioned.', 'mutability');
}
const userFields: Record<string, true> = { schemas: true, id: true, externalId: true, userName: true, name: true, displayName: true, active: true, emails: true, groups: true, meta: true };
const groupFields: Record<string, true> = { schemas: true, id: true, externalId: true, displayName: true, members: true, meta: true };
const subFields: Record<string, string[]> = { name: ['givenName', 'familyName', 'formatted'], emails: ['value', 'primary', 'type'], groups: ['value', 'display'], members: ['value', 'display'], meta: ['resourceType', 'created', 'lastModified', 'location', 'version'] };
function projection(context: RequestContext, fields: Record<string, true>): { include: string | null; paths: string[] } {
  const include = context.query.get('attributes'); const exclude = context.query.get('excludedAttributes');
  if (include !== null && exclude !== null) invalid('attributes and excludedAttributes are mutually exclusive.');
  const paths = include === null && exclude === null ? [] : (include ?? exclude)!.split(',').map(value => {
    const parts = value.trim().split('.'); const field = Object.keys(fields).find(key => key.toLowerCase() === parts[0]?.toLowerCase());
    if (!field || parts.length > 2) invalid('Unknown SCIM attribute projection.');
    if (parts.length === 1) return field;
    const child = subFields[field]?.find(key => key.toLowerCase() === parts[1]?.toLowerCase());
    if (!child) invalid('Unknown SCIM attribute projection.');
    return `${field}.${child}`;
  });
  return { include, paths };
}
function selected(context: RequestContext, resource: P.SCIMUser | P.SCIMGroup): Record<string, unknown> {
  const { include, paths } = projection(context, 'userName' in resource ? userFields : groupFields);
  if (!paths.length) return { ...resource };
  const source = resource as unknown as Record<string, unknown>; const result: Record<string, unknown> = { schemas: resource.schemas, id: resource.id, meta: resource.meta };
  for (const [key, value] of Object.entries(source)) {
    if (key === 'schemas' || key === 'id' || key === 'meta') continue;
    const whole = paths.includes(key); const children = paths.filter(path => path.startsWith(`${key}.`)).map(path => path.slice(key.length + 1));
    if (include !== null) { if (whole) result[key] = value; else if (children.length) result[key] = projectChildren(value, children, true); }
    else if (!whole) result[key] = children.length ? projectChildren(value, children, false) : value;
  }
  return result;
}
function projectChildren(value: unknown, children: string[], include: boolean): unknown {
  if (Array.isArray(value)) return value.map(item => projectChildren(item, children, include));
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).filter(([key]) => include === children.includes(key)));
}
function selectedDiscovery(context: RequestContext, resource: Record<string, unknown>): Record<string, unknown> {
  const fields = Object.fromEntries(Object.keys(resource).map(key => [key, true])) as Record<string, true>;
  const { include, paths } = projection(context, fields);
  if (!paths.length) return resource;
  return Object.fromEntries(Object.entries(resource).filter(([key]) => ['schemas', 'id', 'schema'].includes(key) || (include !== null ? paths.includes(key) : !paths.includes(key))));
}
/** The advertised RFC filter subset is parsed completely, not partially regex-matched. */
export function scimFilter(filter: string | null): (resource: Record<string, unknown>) => boolean {
  if (filter === null) return () => true;
  let remaining = filter.trim(); const predicates: { field: string; value: string | boolean }[] = [];
  while (remaining) {
    const match = /^(userName|externalId|displayName|active)\s+eq\s+("(?:[^"\\]|\\.)*"|true|false)(?=\s|$)/i.exec(remaining);
    if (!match) invalid('Unsupported or malformed SCIM filter.', 'invalidFilter');
    const canonical: Record<string, string> = { username: 'userName', externalid: 'externalId', displayname: 'displayName', active: 'active' }; const field = canonical[match[1]!.toLowerCase()]!;
    let value: unknown; try { value = JSON.parse(match[2]!) as unknown; } catch { invalid('Invalid SCIM filter value.', 'invalidFilter'); }
    if (field === 'active' ? typeof value !== 'boolean' : typeof value !== 'string') invalid('Invalid SCIM filter value type.', 'invalidFilter');
    predicates.push({ field, value: value as string | boolean }); remaining = remaining.slice(match[0].length).trim();
    if (!remaining) break; const and = /^and\s+/i.exec(remaining); if (!and) invalid('Only conjunctions are supported in SCIM filters.', 'invalidFilter'); remaining = remaining.slice(and[0].length); if (!remaining) invalid('Incomplete SCIM filter.', 'invalidFilter');
  }
  if (!predicates.length) invalid('Empty SCIM filter.', 'invalidFilter');
  return resource => predicates.every(({ field, value }) => field !== 'externalId' && typeof value === 'string' && typeof resource[field] === 'string' ? (resource[field] as string).toLowerCase() === value.toLowerCase() : resource[field] === value);
}
function list(context: RequestContext, resources: Record<string, unknown>[]): P.SCIMList<Record<string, unknown>> {
  for (const key of context.query.keys()) if (!['startIndex', 'count', 'filter', 'attributes', 'excludedAttributes'].includes(key)) invalid('Unsupported SCIM query parameter.');
  const integer = (key: string, fallback: number, min: number, max: number): number => { const value = context.query.get(key); if (value === null) return fallback; if (!/^\d+$/.test(value)) invalid('Invalid SCIM pagination.'); const result = Number(value); if (!Number.isSafeInteger(result) || result < min || result > max) invalid('Invalid SCIM pagination.'); return result; };
  const startIndex = integer('startIndex', 1, 1, Number.MAX_SAFE_INTEGER); const count = integer('count', 50, 0, 200); const matches = resources.filter(scimFilter(context.query.get('filter'))); const page = matches.slice(startIndex - 1, startIndex - 1 + count);
  return { schemas: [URN.list], totalResults: matches.length, startIndex, itemsPerPage: page.length, Resources: page };
}
function groupInput(resource: P.SCIMGroup): P.SCIMGroupInput { const { id: _, meta: __, ...input } = resource; return input; }
function userInput(resource: P.SCIMUser): P.SCIMUserInput { const { id: _, meta: __, groups: ___, ...input } = resource; return input; }
function addMultiValues(current: unknown, addition: unknown, field: string): unknown[] {
  const values = [...(Array.isArray(current) ? current : []), ...(Array.isArray(addition) ? addition : [addition])];
  const seen = new Set<string>();
  return values.filter(value => {
    if (!value || typeof value !== 'object' || !('value' in value) || typeof value.value !== 'string') return true;
    const raw = value.value; const key = field === 'emails' ? raw.toLowerCase() : raw;
    if (seen.has(key)) return false;
    seen.add(key); return true;
  });
}
function patched(input: P.SCIMUserInput | P.SCIMGroupInput, body: unknown, kind: 'User' | 'Group'): P.SCIMUserInput | P.SCIMGroupInput {
  const patch = validate(patchSchema, body); const result = structuredClone(input) as unknown as Record<string, unknown>;
  const names: Record<string, string> = kind === 'User' ? { username: 'userName', displayname: 'displayName', externalid: 'externalId', name: 'name', emails: 'emails', active: 'active' } : { displayname: 'displayName', externalid: 'externalId', members: 'members' };
  for (const operation of patch.Operations) {
    if (operation.op !== 'remove' && operation.value === undefined) invalid('PATCH add/replace requires value.');
    if (!operation.path) {
      if (operation.op === 'remove' || !operation.value || typeof operation.value !== 'object' || Array.isArray(operation.value)) invalid('PATCH without a path requires an object value.');
      for (const [key, value] of Object.entries(operation.value)) {
        const field = Object.hasOwn(names, key.toLowerCase()) ? names[key.toLowerCase()] : undefined; if (!field) invalid('Unsupported SCIM PATCH path.', ['id', 'meta', 'schemas', 'groups'].includes(key.toLowerCase()) ? 'mutability' : 'invalidPath');
        result[field] = operation.op === 'add' && field === 'name' && value && typeof value === 'object' && !Array.isArray(value) ? { ...(result.name as Record<string, unknown> | undefined), ...value } : operation.op === 'add' && ['members', 'emails'].includes(field) ? addMultiValues(result[field], value, field) : value;
      }
      continue;
    }
    const path = /^(\w+)(?:\[value\s+eq\s+("(?:[^"\\]|\\.)*")\])?(?:\.(\w+))?$/i.exec(operation.path);
    if (!path) invalid('Unsupported SCIM PATCH path.', 'invalidPath');
    const field = Object.hasOwn(names, path[1]!.toLowerCase()) ? names[path[1]!.toLowerCase()] : undefined; if (!field) invalid('Unsupported SCIM PATCH path.', ['id', 'meta', 'schemas', 'groups'].includes(path[1]!.toLowerCase()) ? 'mutability' : 'invalidPath');
    if (path[2]) {
      if (!['members', 'emails'].includes(field) || path[3]) invalid('Unsupported SCIM value-filter path.', 'invalidPath');
      let target: string; try { target = JSON.parse(path[2]) as string; } catch { invalid('Invalid PATCH filter.', 'invalidFilter'); }
      if (field === 'emails') target = target.toLowerCase();
      const values = (result[field] ?? []) as { value: string }[]; const found = values.some(value => value.value === target);
      if (!found && operation.op !== 'add') invalid('PATCH filter matched no target.', 'noTarget');
      if (operation.op === 'remove') result[field] = values.filter(value => value.value !== target);
      else { const replacement = Array.isArray(operation.value) ? operation.value : [operation.value]; result[field] = [...values.filter(value => value.value !== target), ...replacement]; }
      continue;
    }
    if (path[3]) {
      if (field !== 'name') invalid('Unsupported SCIM subattribute path.', 'invalidPath');
      const key = ['givenName', 'familyName', 'formatted'].find(value => value.toLowerCase() === path[3]!.toLowerCase()); if (!key) invalid('Unsupported name subattribute.', 'invalidPath');
      const object = { ...(result.name as Record<string, unknown> | undefined) }; if (operation.op === 'remove') delete object[key]; else object[key] = operation.value; result.name = object; continue;
    }
    if (operation.op === 'remove') {
      if (['userName', 'active', 'displayName'].includes(field) && (field !== 'displayName' || kind === 'Group')) invalid('A required SCIM attribute cannot be removed.', 'mutability');
      if (field === 'members') result.members = []; else delete result[field];
    } else if (operation.op === 'add' && ['members', 'emails'].includes(field)) {
      result[field] = addMultiValues(result[field], operation.value, field);
    } else if (operation.op === 'add' && field === 'name' && operation.value && typeof operation.value === 'object' && !Array.isArray(operation.value)) {
      result.name = { ...(result.name as Record<string, unknown> | undefined), ...operation.value };
    } else result[field] = operation.value;
  }
  return kind === 'User' ? normalize(validate(userSchema, result)) : validate(groupSchema, result);
}
function discoverySchemas(): P.SCIMSchema[] {
  const attribute = (name: string, type: string, required = false, multiValued = false, subAttributes?: P.JSONObject[]): P.JSONObject => ({ name, type, multiValued, description: `SCIM ${name}`, required, caseExact: name === 'externalId', mutability: 'readWrite', returned: 'default', uniqueness: ['userName', 'externalId'].includes(name) ? 'server' : 'none', ...(subAttributes ? { subAttributes } : {}) });
  return [
    { schemas: [URN.schema], id: URN.user, name: 'User', description: 'Product identity and enabled workspace membership; no passwords or private content.', attributes: [attribute('userName', 'string', true), attribute('externalId', 'string'), attribute('displayName', 'string'), attribute('active', 'boolean', true), attribute('name', 'complex', false, false, [attribute('givenName', 'string'), attribute('familyName', 'string'), attribute('formatted', 'string')]), attribute('emails', 'complex', false, true, [attribute('value', 'string', true), attribute('primary', 'boolean'), attribute('type', 'string')]), { ...attribute('groups', 'complex', false, true, [attribute('value', 'string', true), attribute('display', 'string')]), mutability: 'readOnly' }] },
    { schemas: [URN.schema], id: URN.group, name: 'Group', description: 'Enterprise DirectoryGroup, not a conversation or product role.', attributes: [attribute('displayName', 'string', true), attribute('externalId', 'string'), attribute('members', 'complex', false, true, [attribute('value', 'string', true), { ...attribute('display', 'string'), mutability: 'readOnly' }])] },
  ];
}
/** Routes own the standard SCIM envelope and bypass product mutation nonces. */
export function createSCIMRoutes(services: BackendServices): Route[] {
  const identities = createIdentityServices(services);
  const route = (method: string, path: string, scope: string | null, handler: (context: RequestContext) => Response | Promise<Response>): Route => ({ method, path: `/v1/scim/v2/${path}`, auth: 'public', mutation: false, body: ['GET', 'DELETE'].includes(method) ? 'none' : 'json', handler: async context => {
    try {
      const principal = authenticateIntegration(services, context.request);
      if (!principal) throw new SCIMFailure(401, 'A live scoped SCIM bearer is required.');
      const token = services.store.get<P.IntegrationToken>('integrationTokens', principal.id);
      if (token?.kind !== 'scim' || (scope ? !principal.scopes?.includes(scope) : !principal.scopes?.some(value => value === 'scim.users' || value === 'scim.groups'))) throw new SCIMFailure(403, 'The SCIM token lacks the required scope.');
      if (!['GET', 'DELETE'].includes(method) && context.request.headers.get('content-type')?.split(';')[0]?.trim().toLowerCase() !== 'application/scim+json') throw new SCIMFailure(415, 'SCIM mutations require application/scim+json.');
      if (path.startsWith('Users')) projection(context, userFields);
      if (path.startsWith('Groups')) projection(context, groupFields);
      return await handler({ ...context, user: principal });
    } catch (error) {
      if (error instanceof SCIMFailure) return scimResponse(context, { schemas: [URN.error], status: String(error.status), detail: error.message, ...(error.scimType ? { scimType: error.scimType } : {}) } satisfies P.SCIMError, error.status);
      if (error instanceof ApiError) {
        const status = error.code === 'not_found' ? 404 : error.code === 'unauthenticated' ? 401 : error.code === 'forbidden' || error.code === 'policy_denied' ? 403 : error.code === 'conflict' ? 409 : 500;
        return scimResponse(context, { schemas: [URN.error], status: String(status), detail: status === 500 ? 'SCIM operation could not be completed.' : error.message } satisfies P.SCIMError, status);
      }
      return scimResponse(context, { schemas: [URN.error], status: '500', detail: 'SCIM operation could not be completed.' } satisfies P.SCIMError, 500);
    }
  } });
  const resources: P.SCIMResourceType[] = [{ schemas: [URN.resourceType], id: 'User', name: 'User', endpoint: '/Users', schema: URN.user }, { schemas: [URN.resourceType], id: 'Group', name: 'Group', endpoint: '/Groups', schema: URN.group }];
  const schemas = discoverySchemas();
  const requireUser = (userId: string): P.SCIMUser => { const user = services.store.get<P.SCIMUser>('scimUsers', userId); if (!user) throw new SCIMFailure(404, 'SCIM User not found.'); return user; };
  const requireGroup = (groupId: string): P.DirectoryGroup => { const group = services.store.get<P.DirectoryGroup>('directoryGroups', groupId); if (!group || group.source !== 'scim') throw new SCIMFailure(404, 'SCIM Group not found.'); return group; };
  const updateUser = async (context: RequestContext, patch: boolean): Promise<Response> => {
    const updated = services.store.transaction(() => {
      const current = requireUser(context.params.id!); ifMatch(context, userView(services, current).meta.version);
      const input = patch ? patched(userInput(current), context.body, 'User') as P.SCIMUserInput : normalize(validate(userSchema, context.body)); userUniqueness(services, input, current.id);
      if (!input.active) protectOwner(services, current.id);
      const productUser = services.store.require<P.User>('users', current.id); const user = services.update(productUser, { email: input.userName, displayName: input.displayName || input.name?.formatted || input.userName });
      services.store.put('users', user);
      const member = services.store.list<P.Member>('members').find(value => value.userId === user.id); if (!member) throw new SCIMFailure(404, 'SCIM membership not found.');
      services.store.put('members', services.update(member, { email: user.email, displayName: user.displayName, enabled: input.active }));
      const result: P.SCIMUser = { ...input, id: current.id, meta: meta(services, 'User', user) }; services.store.put('scimUsers', result); services.audit(context.user, 'scim.user_update', result.id, 'succeeded', { active: result.active }, context.requestId); return result;
    });
    if (!updated.active) await identities.deprovisionUser(updated.id);
    const result = userView(services, updated); return scimResponse(context, selected(context, result), 200, result.meta.version, result.meta.location);
  };
  const updateGroup = (context: RequestContext, patch: boolean): Response => services.store.transaction(() => {
    const current = requireGroup(context.params.id!); ifMatch(context, groupView(services, current).meta.version);
    const input = patch ? patched(groupInput(groupView(services, current)), context.body, 'Group') as P.SCIMGroupInput : validate(groupSchema, context.body); groupUniqueness(services, input, current.id);
    const group = services.update(current, { name: input.displayName, externalId: input.externalId ?? null, memberUserIds: input.members.map(member => member.value) }); services.store.put('directoryGroups', group); services.events.emit('directory_group.upserted', group, { admin: true }); services.audit(context.user, 'scim.group_update', group.id, 'succeeded', undefined, context.requestId);
    const result = groupView(services, group); return scimResponse(context, selected(context, result), 200, result.meta.version, result.meta.location);
  });
  return [
    route('GET', 'ServiceProviderConfig', null, context => scimResponse(context, { schemas: [URN.config], patch: { supported: true }, bulk: { supported: false, maxOperations: 0, maxPayloadSize: 0 }, filter: { supported: true, maxResults: 200 }, changePassword: { supported: false }, sort: { supported: false }, etag: { supported: true }, authenticationSchemes: [{ type: 'oauthbearertoken', name: 'Scoped SCIM bearer', description: 'Owner-issued digest-only integration token with scim.users and/or scim.groups.', primary: true }] } satisfies P.SCIMServiceProviderConfig)),
    route('GET', 'ResourceTypes', null, context => { const result = list(context, resources.map(value => ({ ...value }))); result.Resources = result.Resources.map(value => selectedDiscovery(context, value)); return scimResponse(context, result); }),
    route('GET', 'ResourceTypes/:id', null, context => { const resource = resources.find(value => value.id === context.params.id); if (!resource) throw new SCIMFailure(404, 'ResourceType not found.'); return scimResponse(context, selectedDiscovery(context, { ...resource })); }),
    route('GET', 'Schemas', null, context => { const result = list(context, schemas.map(value => ({ ...value }))); result.Resources = result.Resources.map(value => selectedDiscovery(context, value)); return scimResponse(context, result); }),
    route('GET', 'Schemas/:id', null, context => { const schema = schemas.find(value => value.id === context.params.id); if (!schema) throw new SCIMFailure(404, 'Schema not found.'); return scimResponse(context, selectedDiscovery(context, { ...schema })); }),
    route('GET', 'Users', 'scim.users', context => {
      const users = services.store.list<P.SCIMUser>('scimUsers').sort((a, b) => a.id.localeCompare(b.id)).map(value => userView(services, value));
      const result = list(context, users.map(value => ({ ...value }))); result.Resources = result.Resources.map(value => selected(context, value as unknown as P.SCIMUser)); return scimResponse(context, result);
    }),
    route('GET', 'Users/:id', 'scim.users', context => { const result = userView(services, requireUser(context.params.id!)); return scimResponse(context, selected(context, result), 200, result.meta.version, result.meta.location); }),
    route('POST', 'Users', 'scim.users', async context => {
      const input = normalize(validate(userSchema, context.body));
      const result = services.store.transaction(() => {
        const fence = createFence(services, context, 'User', input);
        if (fence.resourceId) return { resource: requireUser(fence.resourceId), status: 200 };
        const existing = input.externalId ? services.store.list<P.SCIMUser>('scimUsers').find(value => value.externalId === input.externalId) : undefined;
        if (existing) {
          if (services.mutations.digest(userInput(existing)) !== services.mutations.digest(input)) throw new SCIMFailure(409, 'externalId was already used with different attributes.', 'uniqueness');
          if (fence.key) services.store.put('scimCreateFences', { id: fence.key, requestDigest: fence.digest, resourceId: existing.id });
          return { resource: existing, status: 200 };
        }
        userUniqueness(services, input);
        const user = createProvisionedUser(services, input.userName, input.displayName || input.name?.formatted || input.userName);
        const member = services.store.list<P.Member>('members').find(value => value.userId === user.id)!; if (!input.active) services.store.put('members', services.update(member, { enabled: false }));
        const resource: P.SCIMUser = { ...input, id: user.id, meta: meta(services, 'User', user) }; services.store.put('scimUsers', resource); services.store.setMetadata(`scimManaged:${user.id}`, true);
        if (fence.key) services.store.put('scimCreateFences', { id: fence.key, requestDigest: fence.digest, resourceId: user.id });
        services.store.put('managedIdentities', { id: user.id, requireSSO: services.store.list<P.OIDCProvider>('oidcProviders').some(provider => provider.requireSSO), providerIds: [] });
        services.audit(context.user, 'scim.user_create', user.id, 'succeeded', undefined, context.requestId); return { resource, status: 201 };
      });
      if (!result.resource.active) await identities.deprovisionUser(result.resource.id);
      const resource = userView(services, result.resource);
      return scimResponse(context, selected(context, resource), result.status, resource.meta.version, resource.meta.location);
    }),
    route('PUT', 'Users/:id', 'scim.users', context => updateUser(context, false)),
    route('PATCH', 'Users/:id', 'scim.users', context => updateUser(context, true)),
    route('DELETE', 'Users/:id', 'scim.users', async context => {
      const userId = services.store.transaction(() => {
        const user = requireUser(context.params.id!); ifMatch(context, userView(services, user).meta.version); protectOwner(services, user.id);
        const member = services.store.list<P.Member>('members').find(value => value.userId === user.id); if (member) services.store.put('members', services.update(member, { enabled: false }));
        services.store.remove('scimUsers', user.id);
        for (const group of services.store.list<P.DirectoryGroup>('directoryGroups', value => value.memberUserIds.includes(user.id))) { const updated = services.update(group, { memberUserIds: group.memberUserIds.filter(id => id !== user.id) }); services.store.put('directoryGroups', updated); services.events.emit('directory_group.upserted', updated, { admin: true }); }
        services.audit(context.user, 'scim.user_delete', user.id, 'succeeded', undefined, context.requestId); return user.id;
      });
      await identities.deprovisionUser(userId); return scimResponse(context, undefined, 204);
    }),
    route('GET', 'Groups', 'scim.groups', context => {
      const groups = services.store.list<P.DirectoryGroup>('directoryGroups', value => value.source === 'scim').sort((a, b) => a.id.localeCompare(b.id)).map(group => groupView(services, group));
      const result = list(context, groups.map(value => ({ ...value }))); result.Resources = result.Resources.map(value => selected(context, value as unknown as P.SCIMGroup)); return scimResponse(context, result);
    }),
    route('GET', 'Groups/:id', 'scim.groups', context => { const result = groupView(services, requireGroup(context.params.id!)); return scimResponse(context, selected(context, result), 200, result.meta.version, result.meta.location); }),
    route('POST', 'Groups', 'scim.groups', context => services.store.transaction(() => {
      const input = validate(groupSchema, context.body); const fence = createFence(services, context, 'Group', input);
      const existing = fence.resourceId ? requireGroup(fence.resourceId) : input.externalId ? services.store.list<P.DirectoryGroup>('directoryGroups', group => group.source === 'scim' && group.externalId === input.externalId)[0] : undefined;
      if (existing) {
        const current = groupInput(groupView(services, existing));
        if (!fence.resourceId && (current.displayName !== input.displayName || current.members.map(value => value.value).sort().join('\0') !== input.members.map(value => value.value).sort().join('\0'))) throw new SCIMFailure(409, 'externalId was already used with different attributes.', 'uniqueness');
        if (fence.key) services.store.put('scimCreateFences', { id: fence.key, requestDigest: fence.digest, resourceId: existing.id });
        const result = groupView(services, existing); return scimResponse(context, selected(context, result), 200, result.meta.version, result.meta.location);
      }
      groupUniqueness(services, input); const group = services.resource('directory_group', { name: input.displayName, externalId: input.externalId ?? null, source: 'scim' as const, memberUserIds: input.members.map(member => member.value) }); services.store.put('directoryGroups', group);
      if (fence.key) services.store.put('scimCreateFences', { id: fence.key, requestDigest: fence.digest, resourceId: group.id });
      const policy = services.resource('group_policy', { directoryGroupId: group.id, productAccess: true, defaultBotIds: [] as string[], capabilityModes: {}, requiredRuleIds: [] as string[], localExecutionCeiling: 'ask' as const, allowEgress: false, allowSudo: false, networkPolicyId: null, reviewExempt: false }); services.store.put('groupPolicies', policy); services.events.emit('directory_group.upserted', group, { admin: true }); services.events.emit('group_policy.upserted', policy, { admin: true }); services.audit(context.user, 'scim.group_create', group.id, 'succeeded', undefined, context.requestId);
      const result = groupView(services, group); return scimResponse(context, selected(context, result), 201, result.meta.version, result.meta.location);
    })),
    route('PUT', 'Groups/:id', 'scim.groups', context => updateGroup(context, false)),
    route('PATCH', 'Groups/:id', 'scim.groups', context => updateGroup(context, true)),
    route('DELETE', 'Groups/:id', 'scim.groups', context => services.store.transaction(() => {
      const group = requireGroup(context.params.id!); ifMatch(context, groupView(services, group).meta.version); services.store.remove('directoryGroups', group.id);
      for (const policy of services.store.list<P.GroupPolicy>('groupPolicies', value => value.directoryGroupId === group.id)) services.store.remove('groupPolicies', policy.id);
      services.events.emit('directory_group.deleted', { id: group.id, deleted: true }, { admin: true }); services.audit(context.user, 'scim.group_delete', group.id, 'succeeded', undefined, context.requestId); return scimResponse(context, undefined, 204);
    })),
  ];
}
