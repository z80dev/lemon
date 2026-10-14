import { randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';
import { mkdir, readFile, writeFile, chmod, stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { z } from 'zod';
import type { BackendConfiguration } from './services';
import { parseOperatorConfiguration } from '../integrations/config';
export function isLoopback(host:string):boolean { return host==='localhost'||host==='127.0.0.1'||host==='[::1]'||host==='::1'; }
export async function loadConfiguration(environment:Record<string,string|undefined>=process.env):Promise<{config:BackendConfiguration;key:Uint8Array}> {
  const required=z.string().min(1);
  const dataDir=resolve(required.parse(environment.LEMON_BOT_DATA_DIR));
  const operatorToken=required.parse(environment.LEMON_BOT_OPERATOR_TOKEN);
  const controlUrl=new URL(required.parse(environment.LEMON_BOT_CONTROL_URL));
  const publicUrl=new URL(required.parse(environment.LEMON_BOT_PUBLIC_URL));
  const trustedOverlay=environment.LEMON_BOT_TRUSTED_OVERLAY==='true';
  if(!['ws:','wss:'].includes(controlUrl.protocol)||controlUrl.pathname!=='/ws'||controlUrl.username||controlUrl.password||controlUrl.search||controlUrl.hash) throw new Error('LEMON_BOT_CONTROL_URL must be the credential-free exact /ws WebSocket endpoint.');
  if(!['http:','https:'].includes(publicUrl.protocol)||publicUrl.username||publicUrl.password||publicUrl.search||publicUrl.hash||publicUrl.pathname!=='/')throw new Error('LEMON_BOT_PUBLIC_URL must be a credential-free product origin.');
  if(controlUrl.protocol!=='wss:'&&!isLoopback(controlUrl.hostname)&&!trustedOverlay)throw new Error('Off-loopback control-plane transport requires WSS or explicit LEMON_BOT_TRUSTED_OVERLAY=true.');
  if(publicUrl.protocol!=='https:'&&!isLoopback(publicUrl.hostname)&&!trustedOverlay)throw new Error('Off-loopback public transport requires HTTPS or explicit trusted encrypted overlay.');
  await mkdir(dataDir,{recursive:true,mode:0o700});await chmod(dataDir,0o700);
  const keyPath=join(dataDir,'master.key'); let key:Buffer;
  if(environment.LEMON_BOT_ENCRYPTION_KEY) {key=Buffer.from(environment.LEMON_BOT_ENCRYPTION_KEY,'base64');if(key.length!==32)throw new Error('LEMON_BOT_ENCRYPTION_KEY must encode exactly 32 bytes.');}
  else {
    try {key=Buffer.from((await readFile(keyPath,'utf8')).trim(),'base64');}
    catch(error) {
      if(!(error instanceof Error && 'code' in error && error.code==='ENOENT'))throw error;
      try {await stat(join(dataDir,'product.sqlite'));throw new Error('Existing product data has no encryption key; restore its original master.key.');}catch(probe){if(!(probe instanceof Error && 'code' in probe && probe.code==='ENOENT'))throw probe;}
      key=randomBytes(32);await writeFile(keyPath,key.toString('base64'),{mode:0o600,flag:'wx'});
    }
    if(key.length!==32)throw new Error('Private master.key is invalid.');await chmod(keyPath,0o600);
  }
  const configPath=environment.LEMON_BOT_CONFIG_FILE??join(dataDir,'config.json');let raw:unknown={version:1};
  try {raw=JSON.parse(await readFile(configPath,'utf8'));}catch(error){if(!(error instanceof Error&&'code' in error&&error.code==='ENOENT'))throw error;}
  const operator=parseOperatorConfiguration(raw,{firstPartyOrigin:publicUrl.origin});
  const port=z.coerce.number().int().min(1).max(65535).parse(environment.LEMON_BOT_PORT??4080);
  const host=environment.LEMON_BOT_HOST??'127.0.0.1';
  return {config:{publicUrl:publicUrl.origin,controlUrl:controlUrl.href,operatorToken,dataDir,host,port,trustedOverlay,operator},key};
}
export function createPrivateCodec(key:Uint8Array):{encrypt(value:unknown):string;decrypt<T=unknown>(value:string):T} {
  return {
    encrypt(value) {const iv=randomBytes(12);const cipher=createCipheriv('aes-256-gcm',key,iv);const ciphertext=Buffer.concat([cipher.update(JSON.stringify(value),'utf8'),cipher.final()]);return Buffer.concat([Buffer.from([1]),iv,cipher.getAuthTag(),ciphertext]).toString('base64url');},
    decrypt<T>(value:string):T {const bytes=Buffer.from(value,'base64url');if(bytes.length<30||bytes[0]!==1)throw new Error('Private record envelope is invalid.');const decipher=createDecipheriv('aes-256-gcm',key,bytes.subarray(1,13));decipher.setAuthTag(bytes.subarray(13,29));const plaintext=Buffer.concat([decipher.update(bytes.subarray(29)),decipher.final()]).toString('utf8');const decoded:unknown=JSON.parse(plaintext);return decoded as T;}
  };
}
