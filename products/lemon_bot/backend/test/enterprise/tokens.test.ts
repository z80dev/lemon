import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { authenticateIntegration, createTokenRoutes, secureToken } from '../../src/enterprise/tokens';
import { identityFixture, invokeRoute } from './identity.test';

describe('digest-only scoped integration tokens', () => {
  test('issue stores no raw credential; scopes, expiry and revoke are immediate', async () => {
    const f = identityFixture(); try {
      const routes = createTokenRoutes(f.services); const issued = await invokeRoute(routes, f.services, 'POST', '/v1/integration-tokens', { clientNonce: secureToken(), name: 'Directory', kind: 'scim', scopes: ['scim.users', 'scim.groups'], expiresInMs: 1000 }, { principal: f.principal }) as P.IntegrationTokenIssued;
      const request = new Request('https://product.example/v1/scim/v2/Users', { headers: { Authorization: `Bearer ${issued.token}` } });
      const principal = authenticateIntegration(f.services, request, ['scim.users']); expect(principal?.kind).toBe('integration'); expect(principal?.role).toBe('member'); expect(principal?.sessionId).toBeNull();
      expect(JSON.stringify(f.services.store.list('integrationCredentials'))).not.toContain(issued.token); expect(JSON.stringify(f.services.store.list('integrationTokens'))).not.toContain(issued.token);
      expect(authenticateIntegration(f.services, request, ['event_ingress:github'])).toBeNull();
      const list = await invokeRoute(routes, f.services, 'GET', '/v1/integration-tokens', undefined, { principal: f.principal }) as P.Page<P.IntegrationToken>; expect(JSON.stringify(list)).not.toContain(issued.token);
      f.advance(1000); expect(authenticateIntegration(f.services, request)).toBeNull();
      await invokeRoute(routes, f.services, 'DELETE', '/v1/integration-tokens/:id', { clientNonce: secureToken(), revision: issued.integration.revision }, { principal: f.principal, params: { id: issued.integration.id } }); expect(f.services.store.list('integrationCredentials')).toHaveLength(0);
    } finally { f.close(); }
  });
  test('unregistered provider, mismatched kinds and duplicate scopes cannot mint authority', async () => {
    const f = identityFixture(); try { const routes = createTokenRoutes(f.services);
      for (const request of [{ kind: 'scim', scopes: ['event_ingress:github'] }, { kind: 'event_ingress', scopes: ['event_ingress:evil'] }, { kind: 'scim', scopes: ['scim.users', 'scim.users'] }, { kind: 'audit_export', scopes: ['scim.users'] }]) await expect(invokeRoute(routes, f.services, 'POST', '/v1/integration-tokens', { clientNonce: secureToken(), name: 'Invalid', ...request }, { principal: f.principal })).rejects.toThrow();
      expect(f.services.store.list('integrationTokens')).toHaveLength(0);
      const issued = await invokeRoute(routes, f.services, 'POST', '/v1/integration-tokens', { clientNonce: secureToken(), name: 'GitHub ingress', kind: 'event_ingress', scopes: ['event_ingress:github'] }, { principal: f.principal }) as P.IntegrationTokenIssued;
      const request = new Request('https://product.example', { headers: { authorization: `Bearer ${issued.token}` } }); expect(authenticateIntegration(f.services, request, ['event_ingress:github'])?.scopes).toEqual(['event_ingress:github']);
      await expect(invokeRoute(routes, f.services, 'DELETE', '/v1/integration-tokens/:id', { clientNonce: secureToken(), revision: 99 }, { principal: f.principal, params: { id: issued.integration.id } })).rejects.toThrow(); expect(authenticateIntegration(f.services, request)).not.toBeNull();
      await invokeRoute(routes, f.services, 'DELETE', '/v1/integration-tokens/:id', { clientNonce: secureToken(), revision: 1 }, { principal: f.principal, params: { id: issued.integration.id } }); expect(authenticateIntegration(f.services, request)).toBeNull();
    } finally { f.close(); }
  });
});
