import { readFile, stat } from 'node:fs/promises';
import type { BackendServices } from './services';
import { fail } from './errors';
export function installSecretResolver(services:BackendServices):void {
  services.secret=async(ref:string):Promise<string>=>{
    const source=services.config.operator.serverSecrets[ref];if(!source)fail('capability_unavailable','The required operator server-secret reference is not configured.');
    let value:string|undefined;
    if(source.kind==='env')value=process.env[source.name];
    else {try{const info=await stat(source.path);if(!info.isFile()||info.size>65536||(info.mode&0o077)!==0)fail('capability_unavailable','The required secret file must be a private regular file below 64 KiB.');value=await readFile(source.path,'utf8');}catch{fail('capability_unavailable','The required private operator secret file cannot be read.');}}
    if(!value||Buffer.byteLength(value)>65536)fail('capability_unavailable','The required operator secret has not been supplied or exceeds its supported bound.');
    return value;
  };
}
