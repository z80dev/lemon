import { AsyncLocalStorage } from 'node:async_hooks';
import { resolve, sep } from 'node:path';
import { z } from 'zod';
import type { BackendServices, InternalInvocationOptions, Principal, RequestContext, Route } from './services';
import { ApiError, errorEnvelope, fail, statusFor } from './errors';
import { Store } from './store';
interface Registered {route:Route;pattern:RegExp;names:string[]}
export class Router {
  private registered:Registered[]=[];
  private contexts=new AsyncLocalStorage<RequestContext>();
  constructor(private services:BackendServices,private webRoot=resolve(import.meta.dir,'../../../web/dist')) {
    if(services.store instanceof Store)services.store.onWrite((collection,id,value)=>{
      const context=this.contexts.getStore();
      if(!context||collection==='auditRecords'||!value||typeof value!=='object'||!('revision' in value)||!('createdAtMs' in value)||!('updatedAtMs' in value))return;
      if(!context.nonceResourceIds.includes(id))context.nonceResourceIds.push(id);
    });
    services.invoke=async<T>(principal:Principal,method:string,path:string,body?:unknown,options?:InternalInvocationOptions):Promise<T>=>{
      const request=new Request(new URL(path,services.config.publicUrl),{method,headers:{'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})});
      const match=this.match(method,new URL(request.url).pathname);if(!match)fail('not_found','Product endpoint was not found.');
      this.authorizeInternal(principal,match.route);
      const parent=this.contexts.getStore();
      const context:RequestContext={request,params:match.params,query:new URL(request.url).searchParams,body,user:principal,services,requestId:parent?.requestId??services.id('req'),route:match.route,nonceResourceIds:parent?.nonceResourceIds??[],internalBotLifecycle:options?.botLifecycle??parent?.internalBotLifecycle};
      // Internal resource calls share the enclosing durable nonce and authority, never dispatch a second reservation.
      const value=await this.contexts.run(context,()=>match.route.handler(context));return value as T;
    };
  }
  register(routes:Route[]):void {
    for(const route of routes){if(this.registered.some(item=>item.route.method===route.method&&item.route.path===route.path))throw new Error(`Duplicate product route ${route.method} ${route.path}`);const names:string[]=[];const pattern=route.path.split('/').map(part=>{if(part.startsWith(':')){names.push(part.slice(1));return '([^/]+)';}return part.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');}).join('/');this.registered.push({route,pattern:new RegExp(`^${pattern}$`),names});}
    this.registered.sort((a,b)=>a.names.length-b.names.length);
  }
  private match(method:string,path:string):{route:Route;params:Record<string,string>}|null {
    for(const item of this.registered){if(item.route.method!==method)continue;const matches=item.pattern.exec(path);if(!matches)continue;const params:Record<string,string>={};for(let index=0;index<item.names.length;index++){let value:string;try{value=decodeURIComponent(matches[index+1]!);}catch{fail('invalid_request','Path encoding is invalid.');}if(!value||value.includes('/')||/[\u0000-\u001f]/.test(value))fail('invalid_request','Resource ID is invalid.');params[item.names[index]!]=value;}return {route:item.route,params};}return null;
  }
  private authorizeInternal(principal:Principal,route:Route):void {
    if(route.auth==='owner'||route.auth==='admin')this.services.auth.requireRole(principal,route.auth);
    if(route.auth==='bot'&&principal.kind!=='bot')fail('forbidden','Bot authentication is required.');
    if(route.auth==='hook'&&principal.kind!=='hook')fail('forbidden','Webhook authentication is required.');
    if(route.auth==='integration'&&principal.kind!=='integration')fail('forbidden','Integration authentication is required.');
    if(route.auth==='member'&&principal.kind==='bot')fail('forbidden','Product sessions and bot tokens are separate authorities.');
  }
  originAllowed(request:Request):boolean {const origin=request.headers.get('Origin');return !origin||origin===this.services.config.publicUrl||this.services.config.operator.trustedFrontendOrigins.includes(origin);}
  private responseHeaders(request:Request,requestId:string):Headers {
    const headers=new Headers({'X-Request-Id':requestId,'Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'});const origin=request.headers.get('Origin');if(origin&&this.originAllowed(request)){headers.set('Access-Control-Allow-Origin',origin);headers.set('Vary','Origin');headers.set('Access-Control-Expose-Headers','X-Request-Id,Retry-After');}return headers;
  }
  private async body(request:Request,route:Route):Promise<unknown> {
    if(route.body==='none'||request.method==='GET'||request.method==='HEAD')return undefined;
    if(route.body==='multipart'){if(!request.headers.get('Content-Type')?.startsWith('multipart/form-data'))fail('unsupported_media','Multipart upload is required.');return await request.formData();}
    const contentType=request.headers.get('Content-Type')?.toLowerCase().split(';')[0]?.trim();
    if(contentType!=='application/json'&&!(route.path.startsWith('/v1/scim/v2')&&contentType==='application/scim+json'))fail('unsupported_media','JSON content type is required.');
    const max=route.path.includes('/files')?2*1024*1024:1024*1024;
    const chunks:Uint8Array[]=[];let size=0;const reader=request.body?.getReader();if(!reader)fail('invalid_request','A JSON body is required.');
    while(true){const value=await reader.read();if(value.done)break;size+=value.value.byteLength;if(size>max){await reader.cancel();fail('too_large','Request body exceeds its maximum size.');}chunks.push(value.value);}
    try{return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown;}catch{fail('invalid_request','The JSON body is malformed.');}
  }
  async fetch(request:Request):Promise<Response> {
    const requestId=this.services.id('req');const headers=this.responseHeaders(request,requestId);
    try {
      if(!this.originAllowed(request))fail('forbidden','This browser origin is not trusted.');
      const url=new URL(request.url);
      if(request.method==='OPTIONS'){headers.set('Access-Control-Allow-Methods','GET,POST,PUT,PATCH,DELETE,OPTIONS');headers.set('Access-Control-Allow-Headers','Authorization,Content-Type,X-Request-Id,Mcp-Session-Id,Mcp-Protocol-Version');return new Response(null,{status:204,headers});}
      const match=this.match(request.method,url.pathname);
      if(!match){if(url.pathname.startsWith('/v1')||url.pathname.startsWith('/hooks')||url.pathname.startsWith('/mcp'))fail('not_found','Product endpoint was not found.');return await this.staticFile(request,headers);}
      const user=await this.services.auth.authenticate(request,match.route.auth);
      const body=await this.body(request,match.route);
      const resourceIds=Object.entries(match.params).filter(([name])=>name==='id'||name.endsWith('Id')).map(([,id])=>id);
      const context:RequestContext={request,params:match.params,query:url.searchParams,body,user,services:this.services,requestId,route:match.route,nonceResourceIds:resourceIds};
      const mutating=match.route.mutation??(!['GET','HEAD','OPTIONS'].includes(request.method)&&match.route.path!=='/v1/auth/reauth');
      const value=await this.contexts.run(context,()=>mutating?this.services.mutations.execute(context,()=>match.route.handler(context)):match.route.handler(context));
      if(value instanceof Response){for(const [name,item] of headers)value.headers.set(name,item);return value;}
      if(value===undefined)fail('internal_error','The operation did not return its required resource receipt.',false);
      const redirect=z.object({status:z.literal(302),location:z.string().min(1)}).strict().safeParse(value);
      if(redirect.success){headers.set('Location',redirect.data.location);return new Response(null,{status:302,headers});}
      const uncertainHook=url.pathname.startsWith('/hooks/')&&z.object({status:z.literal('outcome_unknown')}).passthrough().safeParse(value).success;
      const status=uncertainHook?202:match.route.status??200;
      headers.set('Content-Type','application/json; charset=utf-8');return new Response(JSON.stringify(value),{status,headers});
    } catch(error) {
      const known=error instanceof z.ZodError||error instanceof SyntaxError?new ApiError('invalid_request','Request has invalid or unsupported fields.'):error;
      const envelope=errorEnvelope(known,requestId);
      if(new URL(request.url).pathname.startsWith('/v1/scim/v2')){headers.set('Content-Type','application/scim+json');return new Response(JSON.stringify({schemas:['urn:ietf:params:scim:api:messages:2.0:Error'],status:String(statusFor[envelope.error.code]),detail:envelope.error.message}),{status:statusFor[envelope.error.code],headers});}
      headers.set('Content-Type','application/json; charset=utf-8');if(envelope.error.code==='rate_limited')headers.set('Retry-After','60');return new Response(JSON.stringify(envelope),{status:statusFor[envelope.error.code],headers});
    }
  }
  private async staticFile(request:Request,headers:Headers):Promise<Response> {
    if(request.method!=='GET'&&request.method!=='HEAD')fail('not_found','Resource was not found.');
    const url=new URL(request.url);let pathname:string;try{pathname=decodeURIComponent(url.pathname);}catch{fail('invalid_request','Invalid asset path.');}
    if(pathname.includes('\0')||pathname.includes('\\'))fail('not_found','Asset was not found.');
    const path=resolve(this.webRoot,'.'+pathname);if(path!==this.webRoot&&!path.startsWith(this.webRoot+sep))fail('not_found','Asset was not found.');
    let file=Bun.file(path);if(!await file.exists()){if(pathname.split('/').pop()?.includes('.'))fail('not_found','Asset was not found.');file=Bun.file(resolve(this.webRoot,'index.html'));}
    if(!await file.exists())return new Response('Lemon Bot web assets are not installed. Build products/lemon_bot/web with bun run build; the product API is available.',{status:503,headers});
    headers.set('Content-Type',file.type);headers.set('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data: https:; media-src 'self' blob:; connect-src 'self' ws: wss:; frame-src 'self' blob:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'");headers.set('Cache-Control',pathname.includes('/assets/')?'public,max-age=31536000,immutable':'no-cache');return new Response(request.method==='HEAD'?null:file,{headers});
  }
}
