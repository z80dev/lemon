import { randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';
import { mkdir, readFile, writeFile, chmod, stat, access, rename } from 'node:fs/promises';
import { constants, lstatSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, resolve, isAbsolute } from 'node:path';
import { z } from 'zod';
import type { BackendConfiguration } from './services';
import { parseOperatorConfiguration } from '../integrations/config';
import { defaultWebRoot } from './layout';
export function isLoopback(host:string):boolean { return host==='localhost'||host==='127.0.0.1'||host==='[::1]'||host==='::1'; }
/** Product listener default. Lemon's own runtime owns 4040 (control plane), 4080 (Web) and 4090 (simulation UI). */
export const defaultBotPort=4100;
type Environment=Record<string,string|undefined>;
function lemonHome(environment:Environment):string { return join(environment.HOME||homedir(),'.lemon'); }
const portPattern=/^[0-9]{1,5}$/;
/** Same resolution as the Lemon launchers: explicit LEMON_CONTROL_PLANE_PORT, then `lemon setup`'s ports.env, then 4040. */
async function localControlPort(environment:Environment):Promise<string> {
  const explicit=environment.LEMON_CONTROL_PLANE_PORT;
  if(explicit)return explicit;
  try {
    for(const line of (await readFile(join(lemonHome(environment),'ports.env'),'utf8')).split('\n')){const [key,value]=line.split('=',2);if(key==='LEMON_CONTROL_PLANE_PORT'&&value!==undefined&&portPattern.test(value))return value;}
  }catch(error){if(!(error instanceof Error&&'code' in error&&error.code==='ENOENT'))throw error;}
  return '4040';
}
/** Listener, public origin and private state; shared by the backend and `lemon-bot setup`. */
export function localSettings(environment:Environment=process.env):{dataDir:string;host:string;port:number;publicUrl:URL} {
  const port=z.coerce.number().int().min(1).max(65535).parse(environment.LEMON_BOT_PORT||defaultBotPort);
  const host=environment.LEMON_BOT_HOST||'127.0.0.1';
  const dataDir=resolve(environment.LEMON_BOT_DATA_DIR||join(lemonHome(environment),'lemon_bot'));
  const explicitPublic=environment.LEMON_BOT_PUBLIC_URL;
  if(!explicitPublic&&!isLoopback(host))throw new Error('LEMON_BOT_PUBLIC_URL is required when LEMON_BOT_HOST is not loopback. See the env table in products/lemon_bot/backend/README.md.');
  return {dataDir,host,port,publicUrl:new URL(explicitPublic||`http://127.0.0.1:${port}`)};
}
export type ManagedToken={token:string}|{problem:'missing'|'unsafe'};
/** Reads the launcher-managed operator credential with the launchers' own safety rules: a private 0600 regular file owned by this user. */
export function readManagedToken(path:string):ManagedToken {
  try {
    const info=lstatSync(path);
    if(!info.isFile()||(info.mode&0o777)!==0o600||(process.getuid!==undefined&&info.uid!==process.getuid()))return {problem:'unsafe'};
    const token=readFileSync(path,'utf8').split('\n',1)[0]??'';
    return /^[0-9a-fA-F]{64}$/.test(token)?{token}:{problem:'unsafe'};
  }catch(error){
    if(error instanceof Error&&'code' in error&&error.code==='ENOENT')return {problem:'missing'};
    return {problem:'unsafe'};
  }
}
export async function validateRuntimeLauncher(path: string | undefined): Promise<void> {
  if (path === undefined) return;
  try { if (!isAbsolute(path) || !(await stat(path)).isFile()) throw new Error(); await access(path, constants.X_OK); }
  catch { throw new Error('LEMON_BOT_RUNTIME_LAUNCHER must be an absolute path to an existing executable launcher.'); }
}
/** Working directory and environment for the Lemon launcher. Lemon Bot's own private LEMON_BOT_* settings never reach Lemon. */
export function launcherProcess(launcher:string):{cwd:string;env:Record<string,string|undefined>} {
  const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!key.startsWith('LEMON_BOT_')));
  return {cwd:basename(dirname(launcher))==='bin'?dirname(dirname(launcher)):env.HOME??dirname(launcher),env};
}
export type ControllerChoice={mode:'local'}|{mode:'remote';url:string;token:string};
/** Where the controller settings came from: explicit environment, the saved `lemon-bot` choice, or the same-machine default. */
export type ControllerSource='environment'|'saved'|'default';
export type ControllerSettings=Pick<BackendConfiguration,'controlUrl'|'operatorToken'|'operatorTokenFile'|'runtimeLauncher'>;
export function validateControlUrl(value:string,trustedOverlay:boolean):URL {
  let url:URL;
  try{url=new URL(value);}catch{throw new Error('The Lemon controller address must be a ws:// or wss:// URL ending in /ws.');}
  if(!['ws:','wss:'].includes(url.protocol)||url.pathname!=='/ws'||url.username||url.password||url.search||url.hash) throw new Error('The Lemon controller address must be the credential-free exact /ws WebSocket endpoint.');
  if(url.protocol!=='wss:'&&!isLoopback(url.hostname)&&!trustedOverlay)throw new Error('A controller on another machine requires wss:// (or explicit LEMON_BOT_TRUSTED_OVERLAY=true).');
  return url;
}
/**
 * Which Lemon to attach to. Explicit LEMON_BOT_CONTROL_URL/LEMON_BOT_OPERATOR_TOKEN win, then the choice saved by
 * `lemon-bot`, then the runtime on this machine: the launchers' control port, their managed operator credential
 * (re-read on every connection attempt) and, when installed, `~/.lemon/bin/lemon` as the Start/Stop/Restart launcher.
 */
export async function controllerSettings(environment:Environment,choice:ControllerChoice|null):Promise<ControllerSettings> {
  const trustedOverlay=environment.LEMON_BOT_TRUSTED_OVERLAY==='true';
  const explicit=Boolean(environment.LEMON_BOT_CONTROL_URL||environment.LEMON_BOT_OPERATOR_TOKEN);
  const remote=!explicit&&choice?.mode==='remote'?choice:null;
  const discovered=!environment.LEMON_BOT_CONTROL_URL&&!remote;
  const controlUrl=validateControlUrl(environment.LEMON_BOT_CONTROL_URL||remote?.url||`ws://127.0.0.1:${await localControlPort(environment)}/ws`,trustedOverlay);
  const localController=isLoopback(controlUrl.hostname);
  // Same-machine credentials never travel to a controller on another host.
  const operatorToken=environment.LEMON_BOT_OPERATOR_TOKEN||remote?.token||(localController?environment.LEMON_CONTROL_PLANE_OPERATOR_TOKEN:undefined)||'';
  let operatorTokenFile:string|undefined;
  if(!operatorToken){
    if(!localController)throw new Error('LEMON_BOT_OPERATOR_TOKEN is required for a controller on another machine. See the env table in products/lemon_bot/backend/README.md.');
    operatorTokenFile=join(lemonHome(environment),'run',`control-plane-${controlUrl.port||(controlUrl.protocol==='wss:'?'443':'80')}.token`);
  }
  let runtimeLauncher=environment.LEMON_BOT_RUNTIME_LAUNCHER;
  await validateRuntimeLauncher(runtimeLauncher);
  if(runtimeLauncher===undefined&&discovered){
    // The installed launcher starts the runtime on the same discovered port; an explicit controller URL may not match it.
    const installed=join(lemonHome(environment),'bin','lemon');
    try{await validateRuntimeLauncher(installed);runtimeLauncher=installed;}catch{/* Lemon is not installed here; Start stays unavailable. */}
  }
  return {controlUrl:controlUrl.href,operatorToken,operatorTokenFile,runtimeLauncher};
}
const choiceFile='controller.json';
const savedChoice=z.discriminatedUnion('mode',[z.object({version:z.literal(1),mode:z.literal('local')}),z.object({version:z.literal(1),mode:z.literal('remote'),url:z.string(),token:z.string()})]);
/** The saved choice lives in private DATA_DIR; a remote operator token is encrypted with the product master key. */
export async function readControllerChoice(dataDir:string,codec:Pick<PrivateCodec,'decrypt'>):Promise<ControllerChoice|null> {
  let raw:string;
  try{raw=await readFile(join(dataDir,choiceFile),'utf8');}catch(error){if(error instanceof Error&&'code' in error&&error.code==='ENOENT')return null;throw error;}
  const saved=savedChoice.parse(JSON.parse(raw));
  if(saved.mode==='local')return {mode:'local'};
  const token=codec.decrypt<unknown>(saved.token);
  if(typeof token!=='string'||!token)throw new Error('The saved Lemon controller credential is invalid; run lemon-bot --choose-lemon.');
  return {mode:'remote',url:saved.url,token};
}
export async function saveControllerChoice(dataDir:string,codec:Pick<PrivateCodec,'encrypt'>,choice:ControllerChoice):Promise<void> {
  const value=choice.mode==='local'?{version:1,mode:'local'}:{version:1,mode:'remote',url:choice.url,token:codec.encrypt(choice.token)};
  const temporary=join(dataDir,`.${choiceFile}.${randomBytes(6).toString('hex')}`);
  await writeFile(temporary,`${JSON.stringify(value)}\n`,{mode:0o600,flag:'wx'});
  await rename(temporary,join(dataDir,choiceFile));
}
export async function loadConfiguration(environment:Environment=process.env):Promise<{config:BackendConfiguration;key:Uint8Array;controllerSource:ControllerSource}> {
  const {dataDir,host,port,publicUrl}=localSettings(environment);
  const trustedOverlay=environment.LEMON_BOT_TRUSTED_OVERLAY==='true';
  if(!['http:','https:'].includes(publicUrl.protocol)||publicUrl.username||publicUrl.password||publicUrl.search||publicUrl.hash||publicUrl.pathname!=='/')throw new Error('LEMON_BOT_PUBLIC_URL must be a credential-free product origin.');
  if(publicUrl.protocol!=='https:'&&!isLoopback(publicUrl.hostname)&&!trustedOverlay)throw new Error('Off-loopback public transport requires HTTPS or explicit trusted encrypted overlay.');
  if(environment.LEMON_BOT_CONTROL_URL)validateControlUrl(environment.LEMON_BOT_CONTROL_URL,trustedOverlay);
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
  const webRoot=resolve(environment.LEMON_BOT_WEB_ROOT??defaultWebRoot());
  const choice=await readControllerChoice(dataDir,createPrivateCodec(key));
  const controllerSource:ControllerSource=environment.LEMON_BOT_CONTROL_URL||environment.LEMON_BOT_OPERATOR_TOKEN?'environment':choice?'saved':'default';
  const controller=await controllerSettings(environment,choice);
  return {config:{publicUrl:publicUrl.origin,host,port,dataDir,trustedOverlay,operator,webRoot,...controller},key,controllerSource};
}
export interface PrivateCodec {encrypt(value:unknown):string;decrypt<T=unknown>(value:string):T}
export function createPrivateCodec(key:Uint8Array):PrivateCodec {
  return {
    encrypt(value) {const iv=randomBytes(12);const cipher=createCipheriv('aes-256-gcm',key,iv);const ciphertext=Buffer.concat([cipher.update(JSON.stringify(value),'utf8'),cipher.final()]);return Buffer.concat([Buffer.from([1]),iv,cipher.getAuthTag(),ciphertext]).toString('base64url');},
    decrypt<T>(value:string):T {const bytes=Buffer.from(value,'base64url');if(bytes.length<30||bytes[0]!==1)throw new Error('Private record envelope is invalid.');const decipher=createDecipheriv('aes-256-gcm',key,bytes.subarray(1,13));decipher.setAuthTag(bytes.subarray(13,29));const plaintext=Buffer.concat([decipher.update(bytes.subarray(29)),decipher.final()]).toString('utf8');const decoded:unknown=JSON.parse(plaintext);return decoded as T;}
  };
}
