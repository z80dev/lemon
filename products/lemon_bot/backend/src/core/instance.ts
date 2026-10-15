import { dirname, basename } from 'node:path';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Route } from './services';
import { isLoopback } from './config';
import { fail } from './errors';
import { z, parse, mutation } from './validation';
import { productVersion } from './version';

const number=z.number().finite().nonnegative();
const statusSchema=z.object({ server:z.object({version:z.string().nullable().optional(),uptime_ms:number.nullable().optional(),memory_mb:number.nullable().optional()}).optional(),connections:z.object({active:number,operators:number,nodes:number}).nullable().optional(),runs:z.object({active:number,queued:number,completed_today:number}).nullable().optional(),channels:z.object({configured:z.array(z.string()),connected:z.array(z.string())}).nullable().optional(),skills:z.object({installed:number,enabled:number}).nullable().optional() });
const healthSchema=z.object({uptime_ms:number.optional(),memory_mb:number.optional()});
const sessionsSchema=z.object({summary:z.object({count:number})});
const nodesSchema=z.object({summary:z.object({count:number,online:number,presenceAvailable:z.boolean(),truncated:z.boolean()})});
const actionSchema=z.enum(['start','stop','restart']);
const actionRequest=mutation.extend({confirm:z.boolean().optional()});

export function createInstanceRoutes(services:BackendServices,startedAtMs:number):Route[] {
  let operation:P.RuntimeOperation|null=null;
  const reason=!isLoopback(new URL(services.config.controlUrl).hostname)?'The controller is not on this host; restart it where it runs.':!services.config.runtimeLauncher?'Set LEMON_BOT_RUNTIME_LAUNCHER to the absolute path of the lemon launcher on this host to enable start/stop/restart.':null;
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
      version:upstream?.server?.version??null,uptimeMs:upstream?.server?.uptime_ms??health?.uptime_ms??null,memoryMb:upstream?.server?.memory_mb??health?.memory_mb??null,
      connections:upstream?.connections??null,runs:upstream?.runs?{active:upstream.runs.active,queued:upstream.runs.queued,completedToday:upstream.runs.completed_today}:null,
      activeSessions:sessions?.summary.count??null,channels:upstream?.channels??null,skills:upstream?.skills??null,
      nodes:nodes&&!nodes.summary.truncated&&nodes.summary.presenceAvailable?{total:nodes.summary.count,online:nodes.summary.online}:null
    }:null;
    return {measuredAtMs:services.now(),backend:{version:productVersion,apiVersion:1,startedAtMs,publicUrl:services.config.publicUrl},controller:{...services.lemon.controller,methodCount:services.lemon.methods.length},lemon,lemonUnavailableReason:lemon?null:services.lemon.connected?'The controller did not provide instance status.':services.lemon.controller.lastError?.message??'The controller is not connected.',runtime:{controllable:reason===null,reason,operation:operation?{...operation}:null}};
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
  return [
    {method:'GET',path:'/v1/instance',auth:'admin',status:200,handler:status},
    {method:'POST',path:'/v1/instance/reconnect',auth:'admin',status:200,handler:context=>{parse(mutation,context.body);services.lemon.reconnect();return status();}},
    {method:'POST',path:'/v1/instance/runtime/:action',auth:'owner',status:202,handler:context=>{
      const action=parse(actionSchema,context.params.action);const body=parse(actionRequest,context.body);
      if(reason)fail('capability_unavailable',reason);
      if(action!=='start'&&body.confirm!==true)fail('confirmation_required','Confirm this runtime operation before continuing.');
      if(operation?.state==='running')fail('conflict','A runtime operation is already running.');
      operation={id:services.id('runtime_operation'),action,state:'running',startedAtMs:services.now(),completedAtMs:null,exitCode:null,output:''};
      const response={...operation};void launch(operation);return response;
    }}
  ];
}
