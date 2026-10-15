import { dirname, basename } from 'node:path';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Route } from './services';
import type { ConnectedLemonService } from '../runtime/lemon';
import { isLoopback } from './config';
import { fail } from './errors';
import { z, parse, mutation } from './validation';
import { productVersion } from './version';

const number=z.number().finite().nonnegative();
const lastError=z.object({message:z.string(),atMs:number.int()}).nullable();
const buildSchema=z.object({runtimeMode:z.string(),channel:z.string().nullable(),commit:z.string().nullable()});
const channelsSchema=z.object({configured:z.array(z.string()),connected:z.array(z.string()),details:z.array(z.object({id:z.string(),state:z.enum(['connected','configured','error']),lastError}))});
const providersSchema=z.array(z.object({id:z.string(),configured:z.boolean(),credential:z.enum(['present','missing','not_required']),default:z.boolean(),lastError}));
const lifecycleSchema=z.object({restart:z.boolean(),stop:z.boolean(),reason:z.string().nullable()});
const statusSchema=z.object({
  server:z.object({version:z.string().nullable().optional(),uptime_ms:number.nullable().optional(),memory_mb:number.nullable().optional(),build:buildSchema.nullish().catch(null)}).nullish().catch(null),
  connections:z.object({active:number,operators:number,nodes:number}).nullish().catch(null),
  runs:z.object({active:number,queued:number,completed_today:number}).nullish().catch(null),
  channels:channelsSchema.nullish().catch(null),providers:providersSchema.nullish().catch(null),lifecycle:lifecycleSchema.nullish().catch(null),
  skills:z.object({installed:number,enabled:number}).nullish().catch(null)
});
const healthSchema=z.object({uptime_ms:number.optional(),memory_mb:number.optional()});
const sessionsSchema=z.object({summary:z.object({count:number})});
const nodesSchema=z.object({summary:z.object({count:number,online:number,presenceAvailable:z.boolean(),truncated:z.boolean()})});
const actionSchema=z.enum(['start','stop','restart']);
const actionRequest=mutation.extend({confirm:z.boolean().optional()});

export function createInstanceRoutes(services:BackendServices,startedAtMs:number):Route[] {
  let operation:P.RuntimeOperation|null=null;
  function runtime(lifecycle:z.infer<typeof lifecycleSchema>|null|undefined):Omit<P.InstanceRuntime,'operation'> {
    if(isLoopback(new URL(services.config.controlUrl).hostname)&&services.config.runtimeLauncher)return {actions:['start','stop','restart'],via:'launcher',reason:null};
    const actions:P.RuntimeAction[]=[];
    if(services.lemon.connected&&lifecycle) {
      if(lifecycle.restart&&services.lemon.methods.includes('system.restart'))actions.push('restart');
      if(lifecycle.stop&&services.lemon.methods.includes('system.stop'))actions.push('stop');
    }
    return {actions,via:actions.length?'controller':null,reason:actions.length?lifecycle?.reason??'Start requires a launcher on the controller host.':lifecycle?.reason??'Runtime control is unavailable. Configure a local LEMON_BOT_RUNTIME_LAUNCHER or connect to a controller with lifecycle support.'};
  }
  async function read<T>(method:string,schema:z.ZodType<T>):Promise<T|null> {
    if(!services.lemon.connected||!services.lemon.methods.includes(method))return null;
    let timer:NodeJS.Timeout|undefined;
    try {
      const deadline=Promise.withResolvers<never>();timer=setTimeout(()=>deadline.reject(new Error('timeout')),5000);
      const value=await Promise.race([services.lemon.call(method,{}, {timeoutMs:5000}),deadline.promise]);
      const result=schema.safeParse(value);return result.success?result.data:null;
    }catch{return null;}finally{clearTimeout(timer);}
  }
  async function status():Promise<P.InstanceStatus> {
    const [upstream,health,sessions,nodes]=await Promise.all([read('status',statusSchema),read('health',healthSchema),read('sessions.active.list',sessionsSchema),read('nodes.list',nodesSchema)]);
    const available=services.lemon.connected&&(upstream!==null||health!==null||sessions!==null||nodes!==null);
    const lemon:P.InstanceLemonStatus|null=available?{
      version:upstream?.server?.version??null,build:upstream?.server?.build??null,uptimeMs:upstream?.server?.uptime_ms??health?.uptime_ms??null,memoryMb:upstream?.server?.memory_mb??health?.memory_mb??null,
      connections:upstream?.connections??null,runs:upstream?.runs?{active:upstream.runs.active,queued:upstream.runs.queued,completedToday:upstream.runs.completed_today}:null,
      activeSessions:sessions?.summary.count??null,channels:upstream?.channels??null,providers:upstream?.providers?.map(({default:isDefault,...provider})=>({...provider,isDefault}))??null,skills:upstream?.skills??null,
      nodes:nodes&&!nodes.summary.truncated&&nodes.summary.presenceAvailable?{total:nodes.summary.count,online:nodes.summary.online}:null
    }:null;
    return {measuredAtMs:services.now(),backend:{version:productVersion,apiVersion:1,startedAtMs,publicUrl:services.config.publicUrl},controller:{...services.lemon.controller,methodCount:services.lemon.methods.length},lemon,lemonUnavailableReason:lemon?null:services.lemon.connected?'The controller did not provide instance status.':services.lemon.controller.lastError?.message??'The controller is not connected.',runtime:{...runtime(upstream?.lifecycle),operation:operation?{...operation}:null}};
  }
  async function launch(current:P.RuntimeOperation):Promise<void> {
    let output=Buffer.alloc(0);
    let timeout:NodeJS.Timeout|undefined;
    try {
      const launcher=services.config.runtimeLauncher!;
      const env=Object.fromEntries(Object.entries(process.env).filter(([key])=>!key.startsWith('LEMON_BOT_')));
      const child=Bun.spawn([launcher,current.action==='start'?'daemon':current.action],{cwd:basename(dirname(launcher))==='bin'?dirname(dirname(launcher)):env.HOME??dirname(launcher),env,stdin:'ignore',stdout:'pipe',stderr:'pipe'});
      let timedOut=false;
      const readers=[child.stdout.getReader(),child.stderr.getReader()];
      timeout=setTimeout(()=>{timedOut=true;child.kill('SIGKILL');for(const reader of readers)void reader.cancel().catch(()=>{});},300000);
      async function drain(reader:ReadableStreamDefaultReader<Uint8Array>){try{while(true){const chunk=await reader.read();if(chunk.done)break;output=Buffer.concat([output,chunk.value]).subarray(-4096);current.output=new TextDecoder('utf-8',{fatal:false}).decode(output);while(Buffer.byteLength(current.output)>4096)current.output=current.output.slice(1);}}finally{reader.releaseLock();}}
      const [exitCode]=await Promise.all([child.exited,...readers.map(drain)]);
      current.exitCode=exitCode;current.state=!timedOut&&exitCode===0?'succeeded':'failed';
    }catch{current.state='failed';current.output='The runtime launcher could not be executed.';}
    finally{clearTimeout(timeout);current.completedAtMs=services.now();}
    if(current.state==='succeeded'&&current.action!=='stop')services.lemon.reconnect();
  }
  async function control(current:P.RuntimeOperation):Promise<void> {
    const initialConnectedAt=services.lemon.controller.connectedAtMs;
    let accepted=false,observed=false;
    let timeout:NodeJS.Timeout|undefined;
    let unconnected=()=>{},unlost=()=>{};
    function finish(state:'succeeded'|'failed',output:string) {
      if(current.state!=='running')return;
      current.state=state;current.output=output;current.completedAtMs=services.now();
      clearTimeout(timeout);unconnected();unlost();
    }
    function observe() {
      if(current.action==='stop'?!services.lemon.connected:services.lemon.connected&&services.lemon.controller.connectedAtMs!==null&&services.lemon.controller.connectedAtMs!==initialConnectedAt)observed=true;
      if(accepted&&observed)finish('succeeded',current.action==='stop'?'The controller disconnected after accepting Stop.':'The controller reconnected after accepting Restart.');
    }
    unconnected=services.lemon.onConnected(observe);
    unlost=(services.lemon as Partial<ConnectedLemonService>).onDisconnected?.(observe)??(()=>{});
    try {
      const reply=await services.lemon.call(`system.${current.action}`,{},{mutation:true,timeoutMs:5000,resourceIds:[current.id]});
      const result=z.object({accepted:z.literal(true),action:z.literal(current.action),acceptedAtMs:number.int()}).safeParse(reply);
      if(!result.success)fail('outcome_unknown','The controller returned an unrecognized lifecycle receipt; check instance status before another action.',false,{resourceIds:[current.id]});
      accepted=true;current.output='The controller accepted the operation; waiting for its link to change.';
      timeout=setTimeout(()=>finish('failed','The controller did not complete the operation within 300 seconds.'),300000);timeout.unref?.();
      observe();
    }catch(error) {
      finish('failed','The controller lifecycle request could not be confirmed.');
      throw error;
    }
  }
  return [
    {method:'GET',path:'/v1/instance',auth:'admin',status:200,handler:status},
    {method:'POST',path:'/v1/instance/reconnect',auth:'admin',status:200,handler:context=>{parse(mutation,context.body);services.lemon.reconnect();return status();}},
    {method:'POST',path:'/v1/instance/runtime/:action',auth:'owner',status:202,handler:async context=>{
      const action=parse(actionSchema,context.params.action);const body=parse(actionRequest,context.body);
      if(action!=='start'&&body.confirm!==true)fail('confirmation_required','Confirm this runtime operation before continuing.');
      const capability=runtime((await read('status',statusSchema))?.lifecycle);
      if(operation?.state==='running')fail('conflict','A runtime operation is already running.');
      if(!capability.actions.includes(action))fail('capability_unavailable',capability.reason??'This runtime action is unavailable.');
      operation={id:services.id('runtime_operation'),action,state:'running',startedAtMs:services.now(),completedAtMs:null,exitCode:null,output:''};
      if(capability.via==='controller')await control(operation);else void launch(operation);
      return {...operation};
    }}
  ];
}
