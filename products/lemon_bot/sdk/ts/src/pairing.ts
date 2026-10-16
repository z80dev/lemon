import type { PairingLink } from '../../../contracts/protocol.ts';
import { localError } from './errors.ts';

/** Parse only the one-use native pairing link; never infer an overlay or accept credentials. */
export function parsePairUrl(value: string): PairingLink {
  if (typeof value !== 'string' || new TextEncoder().encode(value).byteLength > 4096
    || !/^lemonbot:\/\/pair\/?\?/.test(value) || value.includes('#') || /[\u0000-\u0020\u007f]/.test(value)) {
    throw localError('invalid_request', 'Invalid Lemon Bot pairing link.');
  }
  let url: URL;
  try { url = new URL(value); }
  catch { throw localError('invalid_request', 'Invalid Lemon Bot pairing link.'); }
  if (url.protocol !== 'lemonbot:' || url.hostname !== 'pair' || url.port || url.username || url.password
    || (url.pathname !== '' && url.pathname !== '/') || url.hash) {
    throw localError('invalid_request', 'Invalid pairing link authority or path.');
  }
  const fields: Partial<Record<'backend' | 'instance' | 'cluster' | 'code', string>> = {};
  for (const parameter of url.search.slice(1).split('&')) {
    const separator = parameter.indexOf('=');
    if (separator < 0) throw localError('invalid_request', 'Pairing links require exactly one backend, instance, cluster and code.');
    let key: string, decoded: string;
    try {
      key = decodeURIComponent(parameter.slice(0, separator).replace(/\+/g, ' '));
      decoded = decodeURIComponent(parameter.slice(separator + 1).replace(/\+/g, ' '));
    } catch { throw localError('invalid_request', 'Pairing link has invalid percent encoding.'); }
    if ((key !== 'backend' && key !== 'instance' && key !== 'cluster' && key !== 'code') || fields[key] !== undefined) {
      throw localError('invalid_request', 'Pairing links require exactly one backend, instance, cluster and code.');
    }
    fields[key] = decoded;
  }
  const { backend: backendUrl, instance: instanceId, cluster: workspaceId, code: pairCode } = fields;
  if (backendUrl === undefined || instanceId === undefined || workspaceId === undefined || pairCode === undefined) {
    throw localError('invalid_request', 'Pairing links require exactly one backend, instance, cluster and code.');
  }
  if (!instanceId || instanceId.length > 128 || /[\u0000-\u001f\u007f]/.test(instanceId)
    || !workspaceId || workspaceId.length > 128 || /[\u0000-\u001f\u007f]/.test(workspaceId)
    || !/^[A-Za-z0-9_-]{43}$/.test(pairCode)) {
    throw localError('invalid_request', 'Pairing cluster or one-use code is invalid.');
  }
  let backend: URL;
  try { backend = new URL(backendUrl); }
  catch { throw localError('invalid_request', 'Pairing backend must be an exact HTTPS origin.'); }
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(backend.hostname);
  if (backendUrl !== backend.origin || backend.username || backend.password || backend.search || backend.hash
    || (backend.protocol !== 'https:' && !(backend.protocol === 'http:' && loopback))) {
    throw localError('invalid_request', 'Pairing backend requires HTTPS; loopback HTTP is only for same-machine development.');
  }
  return { backendUrl, instanceId, workspaceId, pairCode };
}
