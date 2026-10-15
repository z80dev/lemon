import { expect, test } from 'bun:test';
import { createIdentityRoutes } from '../../src/enterprise/identity';
import { identityFixture, invokeRoute } from './identity.test';
const registration = { clientNonce: 'register-oidc-origin', name: 'Reviewed provider', issuer: 'https://idp.example', clientId: 'client', clientSecretRef: 'oidc', scopes: ['openid', 'email'], allowedEmailDomains: ['example.com'], requireSSO: false };

test('product Owner cannot send configured server credentials without exact operator origin/client approval', async () => {
  const f = identityFixture();
  try {
    let requests = 0, secrets = 0;
    f.services.http = (async () => { requests++; return Response.json({}); });
    f.services.secret = async () => { secrets++; return 'private-server-secret'; };
    f.services.config.operator.oidcAllowedOrigins = [];
    await expect(invokeRoute(createIdentityRoutes(f.services), f.services, 'POST', '/v1/admin/oidc/providers', registration, { principal: f.principal })).rejects.toMatchObject({ code: 'capability_unavailable' });
    expect(requests).toBe(0); expect(secrets).toBe(0);
    f.services.config.operator.oidcAllowedOrigins = ['https://idp.example'];
    f.services.config.operator.oidcClientApprovals = [{ origin: 'https://idp.example', clientId: 'another-client', clientSecretRef: 'oidc' }];
    await expect(invokeRoute(createIdentityRoutes(f.services), f.services, 'POST', '/v1/admin/oidc/providers', registration, { principal: f.principal })).rejects.toMatchObject({ code: 'capability_unavailable' });
    expect(requests).toBe(0); expect(secrets).toBe(0);
  } finally { f.close(); }
});

test('split-origin discovery requires independently approved endpoint credential association', async () => {
  const f = identityFixture();
  try {
    const metadata = { issuer: registration.issuer, authorization_endpoint: 'https://idp.example/authorize', token_endpoint: 'https://tokens.example/token', jwks_uri: 'https://idp.example/jwks', code_challenge_methods_supported: ['S256'] };
    let secrets = 0;
    f.services.secret = async () => { secrets++; return 'private-server-secret'; };
    f.services.http = (async () => Response.json(metadata));
    const routes = createIdentityRoutes(f.services);
    await expect(invokeRoute(routes, f.services, 'POST', '/v1/admin/oidc/providers', registration, { principal: f.principal })).rejects.toMatchObject({ code: 'capability_unavailable' });
    expect(secrets).toBe(0);
    f.services.config.operator.oidcAllowedOrigins!.push('https://tokens.example');
    f.services.config.operator.oidcClientApprovals!.push({ origin: 'https://tokens.example', clientId: 'client', clientSecretRef: 'oidc' });
    const registered = await invokeRoute(routes, f.services, 'POST', '/v1/admin/oidc/providers', registration, { principal: f.principal });
    expect(registered).toMatchObject({ issuer: registration.issuer, clientId: 'client' });
    expect(secrets).toBe(1);
  } finally { f.close(); }
});
