import { describe, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { BackendServices } from '../../src/core/services';
import { ApiError } from '../../src/core/errors';
import { Router } from '../../src/core/router';
import { createResourceRoutes, reserveImportedSkill, resumeImportedSkill, reserveImportedRoutine, resumeImportedRoutine, type ImportedSkillReservation, type ImportedRoutineReservation } from '../../src/core/resources';
import { authFixture } from './auth.test';

const skillSpec = { name:'Imported skill', description:'Reviewed copy', markdown:'Perform the reviewed task.' };
const routineSpec:P.RoutineSpec = { name:'Imported schedule', instruction:'Prepare the reviewed report.', trigger:{kind:'schedule',cron:'*/5 * * * *',timezone:'UTC'}, enabled:true };

function fixture() {
  const f=authFixture(),bot=f.addBot(f.alice.userId);
  f.store.put('machines',{...f.services.resource('machine',{nodeId:'node',nodeName:'Node',name:'Machine',ownerUserId:f.alice.userId,accessUserIds:[],status:'online',lastSeenAtMs:f.services.now(),labels:{},botIds:[bot.id],link:{kind:'direct'}}),id:bot.machineId});
  const calls:{method:string;params:Record<string,unknown>}[]=[],files=new Map<string,{bytes:Buffer;mtimeMs:number}>();
  const controls={failure:null as 'applied'|'absent'|null,readFailure:false,unstableRead:false};
  let revision=0;
  f.services.lemon={connected:true,methods:['node.profile.paths','node.fs.stat','node.fs.read','node.fs.write','cron.admission.set','cron.add'],async call<T>(method:string,params:Record<string,unknown>={}):Promise<T>{
    calls.push({method,params});
    let result:unknown;
    const file=files.get(String(params.path));
    if(method==='node.profile.paths'){
      const workspacePath=`/srv/profiles/${String(params.profileId)}/workspace`;
      result={nodeId:params.nodeId,profileId:params.profileId,workspacePath,skillsPath:`${workspacePath}/.lemon/skill`};
    }else if(method==='node.fs.stat'){
      if(!file)throw new ApiError('not_found','File absent.');
      result={path:params.path,type:'regular',size:file.bytes.length,mtimeMs:file.mtimeMs};
    }else if(method==='node.fs.read'){
      if(controls.readFailure)throw new ApiError('upstream_unavailable','Read unavailable.');
      if(!file)throw new ApiError('not_found','File absent.');
      result={path:params.path,offset:0,size:file.bytes.length,dataBase64:file.bytes.toString('base64'),eof:true};
      if(controls.unstableRead)file.mtimeMs++;
    }else if(method==='node.fs.write'){
      const reservation=f.store.metadata<ImportedSkillReservation>('test:skill')!;
      const operation=f.store.metadata<{writes:{nodeId:string;path:string;contentDigest:string;expectedModifiedAtMs:number;state:string}[]}>(`importedSkillOperation:${reservation.operationId}`)!;
      const bytes=Buffer.from(String(params.dataBase64),'base64');
      expect(operation.writes).toEqual([expect.objectContaining({nodeId:params.nodeId,path:params.path,contentDigest:createHash('sha256').update(bytes).digest('hex'),expectedModifiedAtMs:params.expectedModifiedAtMs,state:'pending'})]);
      if(params.expectedModifiedAtMs!==(file?.mtimeMs??0))throw new ApiError('revision_conflict','File changed.');
      if(controls.failure==='absent')throw new ApiError('outcome_unknown','Dispatch acknowledgment lost.',false);
      const mtimeMs=f.services.now()+(++revision);
      files.set(String(params.path),{bytes,mtimeMs});
      if(controls.failure==='applied')throw new ApiError('outcome_unknown','Write acknowledgment lost.',false);
      result={path:params.path,bytesWritten:bytes.length,size:bytes.length,mtimeMs};
    }else if(method==='cron.admission.set')result={secretName:`cron_admission_${createHash('sha256').update(String(params.routineId)).digest('hex')}`,set:true};
    else if(method==='cron.add')result={id:'cron_imported',profileId:params.profileId,admissionConfigured:true,nextRunAtMs:f.services.now()+300000};
    else throw new Error(`Unexpected RPC ${method}`);
    return result as T;
  }} as BackendServices['lemon'];
  f.services.runtime={sessionKey:(_conversation,selected)=>`agent:${selected.profileId}:task`} as BackendServices['runtime'];
  const router=new Router(f.services);router.register(createResourceRoutes(f.services));
  async function request<T>(method:string,path:string,body?:unknown):Promise<T>{
    const token=(await f.services.auth.session(f.alice.userId)).token;
    const response=await router.fetch(new Request(new URL(path,f.services.config.publicUrl),{method,headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)})}));
    const payload=await response.json();
    if(!response.ok){const {error}=payload as P.ErrorEnvelope;throw new ApiError(error.code,error.message,error.retrySafe,error.details);}
    return payload as T;
  }
  function reserve(enabled=true){
    const reservation=reserveImportedSkill(f.services,f.alice,bot,skillSpec,enabled);
    f.store.setMetadata('test:skill',reservation);
    return reservation;
  }
  return {...f,bot,calls,files,controls,request,reserve};
}

describe('imported resource owning receipts',()=>{
  test('pure reservation survives a lost write acknowledgment and adopts the same stable host file',async()=>{
    const f=fixture(),reservation=f.reserve();
    expect(f.calls).toHaveLength(0);expect(f.store.list('skills')).toHaveLength(0);
    f.controls.failure='applied';
    await expect(resumeImportedSkill(f.services,f.alice,reservation)).rejects.toMatchObject({code:'outcome_unknown'});
    expect(f.store.list<P.Skill>('skills').map(row=>row.id)).toEqual([reservation.skill.id]);
    const persisted=f.store.metadata<ImportedSkillReservation>('test:skill')!;
    f.controls.failure=null;
    // New service identity and JSON-loaded reservation model process-local state loss.
    const restarted={...f.services};new Router(restarted).register(createResourceRoutes(restarted));
    expect((await resumeImportedSkill(restarted,f.alice,persisted)).id).toBe(reservation.skill.id);
    expect(f.calls.filter(call=>call.method==='node.fs.write')).toHaveLength(1);
    expect(f.calls.slice(-3).map(call=>call.method)).toEqual(['node.fs.stat','node.fs.read','node.fs.stat']);
    expect(f.store.metadata(`resourceOperation:${reservation.skill.id}`)).toBeNull();
    expect(f.store.metadata(`skillHostPaths:${reservation.skill.id}`)).toEqual([expect.objectContaining({path:[...f.files.keys()][0],mtimeMs:[...f.files.values()][0]!.mtimeMs,nodeId:'node',profileId:f.bot.profileId})]);
    const page=await f.request<P.Page<P.Skill>>('GET','/v1/skills');expect(page.items.map(row=>row.id)).toEqual([reservation.skill.id]);
    await resumeImportedSkill(restarted,f.alice,persisted);expect(f.calls.filter(call=>call.method==='node.fs.write')).toHaveLength(1);
  });

  test('owning absence permits only the same reserved create to be dispatched again',async()=>{
    const f=fixture(),reservation=f.reserve();f.controls.failure='absent';
    await expect(resumeImportedSkill(f.services,f.alice,reservation)).rejects.toMatchObject({code:'outcome_unknown'});
    f.controls.failure=null;
    const result=await resumeImportedSkill(f.services,f.alice,f.store.metadata<ImportedSkillReservation>('test:skill')!);
    const writes=f.calls.filter(call=>call.method==='node.fs.write');
    expect(result.id).toBe(reservation.skill.id);expect(writes).toHaveLength(2);expect(writes[1]!.params).toEqual(writes[0]!.params);
    expect(f.store.list('skills')).toHaveLength(1);
  });

  test('unreadable, mismatched or unstable receipts stay blocked without another write',async()=>{
    const f=fixture(),reservation=f.reserve();f.controls.failure='applied';
    await expect(resumeImportedSkill(f.services,f.alice,reservation)).rejects.toMatchObject({code:'outcome_unknown'});
    f.controls.failure=null;f.controls.readFailure=true;
    await expect(resumeImportedSkill(f.services,f.alice,reservation)).rejects.toMatchObject({code:'outcome_unknown'});
    f.controls.readFailure=false;
    const file=[...f.files.values()][0]!,original=Buffer.from(file.bytes);file.bytes[0]=file.bytes[0]!^1;
    await expect(resumeImportedSkill(f.services,f.alice,reservation)).rejects.toMatchObject({code:'outcome_unknown'});
    file.bytes=original;f.controls.unstableRead=true;
    await expect(resumeImportedSkill(f.services,f.alice,reservation)).rejects.toMatchObject({code:'outcome_unknown'});
    expect(f.calls.filter(call=>call.method==='node.fs.write')).toHaveLength(1);expect(f.store.list('skills')).toHaveLength(1);
    f.controls.unstableRead=false;
    expect((await resumeImportedSkill(f.services,f.alice,reservation)).id).toBe(reservation.skill.id);
  });

  test('an operation cannot be rebound to changed content or another node',async()=>{
    const f=fixture(),reservation=f.reserve();f.controls.failure='absent';
    await expect(resumeImportedSkill(f.services,f.alice,reservation)).rejects.toMatchObject({code:'outcome_unknown'});
    await expect(resumeImportedSkill(f.services,f.alice,{...reservation,skill:{...reservation.skill,markdown:'Changed'}})).rejects.toMatchObject({code:'conflict'});
    const machine=f.store.require<P.Machine>('machines',f.bot.machineId);f.store.put('machines',{...machine,nodeId:'replacement'});
    f.controls.failure=null;
    await expect(resumeImportedSkill(f.services,f.alice,reservation)).rejects.toMatchObject({code:'machine_offline'});
    expect(f.calls.filter(call=>call.method==='node.fs.write')).toHaveLength(1);
  });

  test('legacy fenced skills adopt only an exact owning receipt and never dispatch a replacement',async()=>{
    const f=fixture(),reservation=f.reserve();
    f.store.put('skills',reservation.skill);
    f.store.setMetadata(`resourceOperation:${reservation.skill.id}`,{state:'outcome_unknown',revision:reservation.skill.revision,action:'skill.create'});
    await expect(resumeImportedSkill(f.services,f.alice,reservation)).rejects.toMatchObject({code:'outcome_unknown'});
    expect(f.calls.filter(call=>call.method==='node.fs.write')).toHaveLength(0);
    const path=`/srv/profiles/${f.bot.profileId}/workspace/.lemon/skill/${reservation.skill.id}/SKILL.md`;
    const bytes=Buffer.from(`---\nname: ${JSON.stringify(skillSpec.name)}\ndescription: ${JSON.stringify(skillSpec.description)}\n---\n\n${skillSpec.markdown}\n`);
    f.files.set(path,{bytes,mtimeMs:f.services.now()});
    f.services.lemon.methods=f.services.lemon.methods.filter(method=>method!=='node.fs.read');
    await expect(resumeImportedSkill(f.services,f.alice,reservation)).rejects.toMatchObject({code:'outcome_unknown'});
    expect(f.store.metadata(`resourceOperation:${reservation.skill.id}`)).not.toBeNull();
    f.services.lemon.methods.push('node.fs.read');
    expect((await resumeImportedSkill(f.services,f.alice,reservation)).id).toBe(reservation.skill.id);
    expect(f.calls.filter(call=>call.method==='node.fs.write')).toHaveLength(0);
    expect(f.store.list('skills')).toHaveLength(1);expect(f.store.metadata(`resourceOperation:${reservation.skill.id}`)).toBeNull();
  });

  test('disabled imported skills never install or remove a host file',async()=>{
    const f=fixture(),reservation=f.reserve(false);
    const result=await resumeImportedSkill(f.services,f.alice,reservation);
    expect(result.enabled).toBe(false);expect(f.calls).toHaveLength(0);
    expect((await f.request<P.Skill>('GET',`/v1/skills/${result.id}`)).id).toBe(result.id);
  });

  test('disabled routine recovery commits its reserved conversation once and activation uses the public route',async()=>{
    const f=fixture(),reservation=reserveImportedRoutine(f.services,f.alice,f.bot,routineSpec);
    f.store.setMetadata('test:routine',reservation);
    expect(f.calls).toHaveLength(0);expect(f.store.list('routines')).toHaveLength(0);expect(f.store.list('conversations')).toHaveLength(0);
    const persisted=f.store.metadata<ImportedRoutineReservation>('test:routine')!;
    const first=await resumeImportedRoutine(f.services,f.alice,persisted),second=await resumeImportedRoutine({...f.services},f.alice,persisted);
    expect(first.id).toBe(reservation.routine.id);expect(second).toEqual(first);expect(first.enabled).toBe(false);expect(first.cronJobId).toBeNull();
    expect(f.store.list<P.Conversation>('conversations').map(row=>row.id)).toEqual([reservation.conversation.id]);expect(f.store.list('routines')).toHaveLength(1);expect(f.calls).toHaveLength(0);
    expect(await f.request<P.Routine>('GET',`/v1/routines/${first.id}`)).not.toHaveProperty('conversationId');
    const enabled=await f.request<P.Routine>('PATCH',`/v1/routines/${first.id}`,{clientNonce:'enable_imported_routine_001',revision:first.revision,enabled:true});
    expect(enabled.enabled).toBe(true);expect(enabled.cronJobId).toBe('cron_imported');expect(f.calls.filter(call=>call.method==='cron.add')).toHaveLength(1);
    expect(f.store.list('conversations')).toHaveLength(1);
  });

  test('public disabled routine creation retains eager cron provisioning semantics',async()=>{
    const f=fixture();
    const created=await f.request<P.Routine>('POST','/v1/routines',{...routineSpec,botId:f.bot.id,enabled:false,clientNonce:'public_disabled_routine_001'});
    expect(created.enabled).toBe(false);expect(created.cronJobId).toBe('cron_imported');expect(f.calls.filter(call=>call.method==='cron.add')).toHaveLength(1);
    expect(created).not.toHaveProperty('conversationId');
  });
});
