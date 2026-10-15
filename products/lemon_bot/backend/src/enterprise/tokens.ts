import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from '../core/services';
import { fail } from '../core/errors';

export const tokenDigest = (token: string): string => createHash('sha256').update(token).digest('hex');
export const secureToken = (): string => randomBytes(32).toString('base64url');
export function equalSecret(left: string, right: string): boolean {
  const a = Buffer.from(left); const b = Buffer.from(right);
  return a.length === b.length && timingSafeEqual(a, b);
}
const nonce = z.string().regex(/^[A-Za-z0-9_-]{16,128}$/);
const issueSchema = z.strictObject({ clientNonce: nonce, name: z.string().trim().min(1).max(120), kind: z.enum(['scim', 'event_ingress', 'audit_export']), scopes: z.array(z.string().min(1).max(160)).min(1).max(32), expiresInMs: z.number().int().positive().max(365 * 86400000).optional() });
const revokeSchema = z.strictObject({ clientNonce: nonce, revision: z.number().int().positive() });
interface Credential { id: string; digest: string; workspaceId: string; issuerUserId: string }

/** Digest-only credentials cannot authenticate product sessions, bots or chat APIs. */
export function authenticateIntegration(services: BackendServices, request: Request, requiredScopes: string[] = []): Principal | null {
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get('authorization') ?? '');
  if (!match) return null;
  const digest = tokenDigest(match[1]!);
  const credential = services.store.list<Credential>('integrationCredentials').find(value => equalSecret(value.digest, digest));
  if (!credential) return null;
  const integration = services.store.get<P.IntegrationToken>('integrationTokens', credential.id);
  if (!integration || (integration.expiresAtMs !== null && integration.expiresAtMs <= services.now()) || requiredScopes.some(scope => !integration.scopes.includes(scope))) return null;
  return { kind: 'integration', id: integration.id, userId: credential.issuerUserId, workspaceId: credential.workspaceId, role: 'member', sessionId: null, deviceId: null, botId: null, scopes: integration.scopes };
}
export function createTokenRoutes(services: BackendServices): Route[] {
  return [
    { method: 'GET', path: '/v1/integration-tokens', auth: 'owner', handler: context => services.page(context, services.store.list<P.IntegrationToken>('integrationTokens')) },
    { method: 'POST', path: '/v1/integration-tokens', auth: 'owner', status: 201, handler: context => {
      const parsed = issueSchema.safeParse(context.body); if (!parsed.success) fail('invalid_request', 'Invalid integration token request.');
      const body = parsed.data;
      const allowed = body.kind === 'scim' ? ['scim.users', 'scim.groups'] : body.kind === 'audit_export' ? ['audit_export'] : [...services.config.operator.eventProviders, ...services.config.operator.channelProviders, ...services.config.operator.emailProviders].map(provider => `event_ingress:${provider.id}`).concat(services.config.operator.xProvider ? ['event_ingress:x'] : []);
      if (new Set(body.scopes).size !== body.scopes.length || body.scopes.some(scope => !allowed.includes(scope))) fail('invalid_request', 'Scopes must match the configured integration kind.');
      const token = secureToken();
      const integration = services.resource('integration_token', { name: body.name, kind: body.kind, scopes: body.scopes, expiresAtMs: body.expiresInMs === undefined ? null : services.now() + body.expiresInMs });
      services.store.transaction(() => {
        services.store.put('integrationTokens', integration);
        services.store.put('integrationCredentials', { id: integration.id, digest: tokenDigest(token), workspaceId: context.user!.workspaceId, issuerUserId: context.user!.userId });
        services.audit(context.user, 'integration_token.issue', integration.id, 'succeeded', { kind: body.kind, scopes: body.scopes }, context.requestId);
      });
      return { integration, token } satisfies P.IntegrationTokenIssued;
    } },
    { method: 'DELETE', path: '/v1/integration-tokens/:id', auth: 'owner', handler: context => {
      const parsed = revokeSchema.safeParse(context.body); if (!parsed.success) fail('invalid_request', 'Invalid token revocation.');
      return services.store.transaction(() => {
        const resource = services.store.get<P.IntegrationToken>('integrationTokens', context.params.id!); if (!resource) fail('not_found', 'Integration token not found.');
        services.mutations.checkRevision(resource, parsed.data.revision);
        services.store.remove('integrationCredentials', resource.id); services.store.remove('integrationTokens', resource.id);
        services.audit(context.user, 'integration_token.revoke', resource.id, 'succeeded', undefined, context.requestId);
        return { id: resource.id, deleted: true } satisfies P.Deleted;
      });
    } },
  ];
}
