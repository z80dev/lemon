import { join } from 'node:path';
import { chmod } from 'node:fs/promises';
import type { Server } from 'bun';
import type { BackendConfiguration, BackendServices } from './core/services';
import type { Policies } from '../../contracts/protocol';
import { loadConfiguration, createPrivateCodec } from './core/config';
import { Store } from './core/store';
import { installHelpers } from './core/helpers';
import { installSecretResolver } from './core/secrets';
import { createMutationService } from './core/mutations';
import { createEventService } from './core/events';
import { createAccessService, type RevocationHooks } from './core/auth';
import { createAccountRoutes, createAccountService } from './core/accounts';
import { Router } from './core/router';
import { createRealtime, type RealtimeData, type RealtimeService } from './core/realtime';
import { createSyncRoutes } from './core/sync';
import { createLemonService } from './runtime/lemon';
import { createRuntimeService } from './runtime/runs';
import { createRuntimeAdmissionRoutes } from './runtime/admission';
import { createMachineRoutes, refreshMachines } from './runtime/machines';
import { getTerminalService, type TerminalService } from './runtime/terminals';
import { createBotRoutes, createBotService, syncBotProfile } from './core/bots';
import { createConversationRoutes } from './core/conversations';
import { createMcpRoutes } from './core/mcp';
import { createGateRoutes, createGateService } from './core/gates';
import { createResourceRoutes } from './core/resources';
import { createAttachmentRoutes, createAttachmentService } from './core/attachments';
import { createVoiceRoutes, createVoiceService, type VoiceService } from './core/voice';
import { createExperienceRoutes, createExperienceService } from './core/experiences';
import { createIntegrationRoutes, createIntegrationServices } from './integrations/index';
import { ApiError, errorEnvelope, statusFor } from './core/errors';

export interface BackendInstance {
  services: BackendServices;
  router: Router;
  realtime: RealtimeService;
  start(): Server<RealtimeData>;
  stop(): Promise<void>;
}
export async function createBackend(config:BackendConfiguration,key:Uint8Array):Promise<BackendInstance> {
  const store=new Store(join(config.dataDir,'product.sqlite'));
  await chmod(join(config.dataDir,'product.sqlite'),0o600);
  const codec=createPrivateCodec(key);
  const sentinel=store.metadata<string>('encryptionKeyCheck');
  if(sentinel){if(codec.decrypt(sentinel)!=='lemon_bot_private_key_v1'){store.close();throw new Error('Product encryption key does not match existing private state.');}}
  else store.setMetadata('encryptionKeyCheck',codec.encrypt('lemon_bot_private_key_v1'));
  // Factories receive one shared object; all required services are installed before any listener accepts requests.
  const services={config,store,...codec} as unknown as BackendServices;
  installHelpers(services);installSecretResolver(services);
  services.mutations=createMutationService(services,key);
  const lemon=createLemonService(config);services.lemon=lemon;
  let realtime:RealtimeService;
  let terminals:TerminalService;
  let voice:VoiceService;
  const hooks:RevocationHooks={
    beforeRevokeUser(principal){voice.endUser(principal);},
    async onRevokeUser(userId){realtime.revokeUser(userId);await terminals.revokeUser(userId);},
    onRevokeSession(sessionId){realtime.revokeSession(sessionId);return terminals.revokeSession(sessionId);},
    async onLogoutUser(userId){await services.integrations.endProviderSessions?.(userId);}
  };
  services.auth=createAccessService(services,hooks);
  services.events=createEventService(services);
  const attachments=createAttachmentService(services);services.attachments=attachments;
  const gates=createGateService(services);services.gates=gates;
  const runtime=createRuntimeService(services);services.runtime=runtime;
  services.syncBotProfile=(principal,botId)=>syncBotProfile(services,principal,botId);
  services.integrations=createIntegrationServices(services);
  const router=new Router(services);
  terminals=getTerminalService(services);voice=createVoiceService(services);
  realtime=createRealtime(services,{
    terminalSubscribe:(principal,deviceId,terminalId,afterSeq,send)=>terminals.subscribe(principal,deviceId,terminalId,afterSeq??0,send),
    voiceConnect:(userId,deviceId)=>voice.connect(userId,deviceId),
    voiceDisconnect:(userId,deviceId)=>voice.disconnect(userId,deviceId)
  });
  const experiences=createExperienceService(services);
  const bots=createBotService(services);
  const accounts=createAccountService(services);
  router.register([
    ...createAccountRoutes(services,hooks),...createSyncRoutes(services),...createMachineRoutes(services),
    ...createBotRoutes(services),...createConversationRoutes(services),...createMcpRoutes(services),
    ...createGateRoutes(services),...createResourceRoutes(services),...createAttachmentRoutes(services),
    ...createVoiceRoutes(services),...createExperienceRoutes(services),...createIntegrationRoutes(services),
    ...createRuntimeAdmissionRoutes(services)
  ]);
  if(!store.metadata<string>('workspaceId')){
    let code:string;const encrypted=store.metadata<string>('setupCode');
    if(encrypted)code=codec.decrypt<string>(encrypted);else{code=services.id('setup');store.transaction(()=>{store.setMetadata('setupCode',codec.encrypt(code));store.setMetadata('setupCodeDigest',services.mutations.digest(code));});}
    process.stdout.write(`Lemon Bot one-use setup code: ${code}\n`);
  }
  experiences.start();
  let reconciling=false;
  const reconcile=async()=>{
    if(reconciling)return;reconciling=true;
    try{
      const tasks=[async()=>{if(lemon.connected){await refreshMachines(services);await runtime.reconcile();await bots.reconcile();}},async()=>{await accounts.reconcile();},async()=>{await services.integrations.reconcile?.();}];
      const results=await Promise.allSettled(tasks.map(task=>task()));
      for(const result of results)if(result.status==='rejected')services.audit(null,'runtime.reconcile','controller','failed');
      experiences.reconcile();
    }finally{reconciling=false;}
  };
  const removeConnected=lemon.onConnected(()=>{void reconcile();});
  const reconcileTimer=setInterval(()=>{void reconcile();},30000);
  const retentionTimer=setInterval(()=>store.transaction(()=>{
    const now=services.now();store.db.query('DELETE FROM events WHERE timestamp_ms<?').run(now-7*86400000);
    store.db.query('DELETE FROM nonces WHERE created_at_ms<? AND state IN (\'complete\',\'failed\')').run(now-30*86400000);
    store.db.query('DELETE FROM confirmations WHERE expires_at_ms<?').run(now);
    store.db.query('DELETE FROM entities WHERE collection=\'pageCursors\' AND json_extract(value,\'$.expiresAtMs\')<=?').run(now);
    const auditRetentionDays=store.metadata<Policies>('policies')?.auditRetentionDays??90;
    store.db.query('DELETE FROM entities WHERE collection=\'auditRecords\' AND json_extract(value,\'$.createdAtMs\')<?').run(now-auditRetentionDays*86400000);
  }),60000);
  reconcileTimer.unref();retentionTimer.unref();
  let server:Server<RealtimeData>|null=null;let stopped=false;
  return {
    services,router,realtime,
    start(){
      if(server)throw new Error('Product server is already listening.');
      server=Bun.serve<RealtimeData>({hostname:config.host,port:config.port,maxRequestBodySize:210*1024*1024,
        async fetch(request,listener){
          const url=new URL(request.url);
          if(url.pathname==='/v1/realtime'&&request.headers.get('Upgrade')?.toLowerCase()==='websocket'){
            const requestId=services.id('req');
            try{if(url.search)throw new ApiError('invalid_request','Realtime authentication belongs in the first frame, not the URL.');if(!router.originAllowed(request))throw new ApiError('forbidden','This browser origin is not trusted.');if(listener.upgrade(request,{data:realtime.data(),headers:{'X-Request-Id':requestId,'Cache-Control':'no-store'}}))return;throw new ApiError('invalid_request','WebSocket upgrade failed.');}
            catch(error){const value=errorEnvelope(error,requestId);return Response.json(value,{status:statusFor[value.error.code],headers:{'X-Request-Id':requestId,'Cache-Control':'no-store'}});}
          }
          return await router.fetch(request);
        },websocket:realtime.websocket});
      lemon.start();return server;
    },
    async stop(){if(stopped)return;stopped=true;clearInterval(reconcileTimer);clearInterval(retentionTimer);removeConnected();experiences.close();realtime.close();voice.close();gates.close();attachments.close();services.integrations.dispose?.();runtime.close();terminals.dispose();lemon.close();if(server)await server.stop(true);store.close();}
  };
}

if(import.meta.main){
  const {config,key}=await loadConfiguration();const backend=await createBackend(config,key);const server=backend.start();
  process.stdout.write(`Lemon Bot listening at ${config.publicUrl} (${server.hostname}:${server.port}).\n`);
  const shutdown=()=>{void backend.stop().then(()=>process.exit(0)).catch(()=>process.exit(1));};
  process.once('SIGINT',shutdown);process.once('SIGTERM',shutdown);
}
