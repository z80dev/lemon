export type Rule={id:string;effect:'allow'|'deny';resource:string;actions:string[];priority:number;conditions:Record<string,string|string[]|null>};
export type Layer={name:string;rules:Rule[];remove:string[]};
export type Request={resource:string;action:string;attributes:Record<string,string>};
export type Decision={allowed:boolean;ruleId:string|null};
const own=(o:object,k:string)=>Object.prototype.hasOwnProperty.call(o,k);
const object=(v:unknown):v is Record<string,unknown>=>v!==null && typeof v==='object' && !Array.isArray(v);
const text=(v:unknown):v is string=>typeof v==='string' && v.length>0;
const exact=(v:Record<string,unknown>,keys:string[])=>Object.keys(v).length===keys.length && keys.every(k=>own(v,k));
const strings=(v:unknown):v is string[]=>Array.isArray(v) && v.every(text) && new Set(v).size===v.length;
const clone=<T>(value:T):T=>structuredClone(value);
function path(value:unknown,wild:boolean):string[] {
  if(!text(value)) throw Error('path');
  const parts=value.split('/');
  if(parts.some(p=>!p)) throw Error('empty segment');
  for(let i=0;i<parts.length;i++) {
    const part=parts[i];
    if(part.includes('*') && (!wild || (part!=='*' && part!=='**') || (part==='**' && i!==parts.length-1))) throw Error('wildcard');
  }
  return parts;
}
function validateRule(raw:unknown):Rule {
  if(!object(raw) || !exact(raw,['id','effect','resource','actions','priority','conditions'])) throw Error('rule shape');
  if(!text(raw.id) || !['allow','deny'].includes(raw.effect as string) || typeof raw.priority!=='number' || !Number.isFinite(raw.priority) || !Number.isInteger(raw.priority) || !strings(raw.actions) || !raw.actions.length || !object(raw.conditions)) throw Error('rule fields');
  path(raw.resource,true);
  for(const [key,value] of Object.entries(raw.conditions)) {
    if(!text(key) || !(value===null || typeof value==='string' || (Array.isArray(value) && value.length>0 && value.every(v=>typeof v==='string') && new Set(value).size===value.length))) throw Error('condition');
  }
  return clone(raw) as Rule;
}
function compile(raw:Layer[]):{layers:Layer[];rules:Rule[]} {
  if(!Array.isArray(raw)) throw Error('layers');
  const names=new Set<string>(), rules=new Map<string,Rule>(), layers:Layer[]=[];
  for(const layer of raw) {
    if(!object(layer) || !exact(layer,['name','rules','remove']) || !text(layer.name) || names.has(layer.name) || !Array.isArray(layer.rules) || !strings(layer.remove)) throw Error('layer');
    names.add(layer.name);
    const ids=new Set<string>(), valid=layer.rules.map(validateRule);
    for(const rule of valid) {if(ids.has(rule.id)) throw Error('duplicate id');ids.add(rule.id);}
    for(const id of layer.remove) rules.delete(id);
    for(const rule of valid) rules.set(rule.id,rule);
    layers.push({name:layer.name,rules:valid,remove:[...layer.remove]});
  }
  const literal=(r:Rule)=>r.resource.split('/').filter(p=>p!=='*'&&p!=='**').length;
  const sorted=[...rules.values()].sort((a,b)=>b.priority-a.priority || literal(b)-literal(a) || (a.effect===b.effect?0:a.effect==='deny'?-1:1) || (a.id<b.id?-1:a.id>b.id?1:0));
  return {layers,rules:sorted};
}
function validateRequest(raw:Request):string[] {
  if(!object(raw) || !exact(raw,['resource','action','attributes']) || !text(raw.action) || !object(raw.attributes) || Object.entries(raw.attributes).some(([k,v])=>!text(k)||typeof v!=='string')) throw Error('request');
  return path(raw.resource,false);
}
function matches(rule:Rule,request:Request,segments:string[]):boolean {
  const pattern=rule.resource.split('/');
  let i=0;
  for(const part of pattern) {
    if(part==='**') {i=segments.length;break;}
    if(i>=segments.length || (part!=='*' && part!==segments[i])) return false;
    i++;
  }
  if(i!==segments.length || (!rule.actions.includes('*') && !rule.actions.includes(request.action))) return false;
  for(const [key,expected] of Object.entries(rule.conditions)) {
    const exists=own(request.attributes,key);
    if(expected===null) {if(exists) return false;}
    else if(!exists || (Array.isArray(expected)?!expected.includes(request.attributes[key]):expected!==request.attributes[key])) return false;
  }
  return true;
}
export class Policy {
  private state:{layers:Layer[];rules:Rule[]};
  constructor(layers:Layer[]){this.state=compile(layers);}
  replace(layers:Layer[]):void {const next=compile(layers);this.state=next;}
  exportLayers():Layer[]{return clone(this.state.layers);}
  explain(request:Request):string[]{const segments=validateRequest(request);return this.state.rules.filter(r=>matches(r,request,segments)).map(r=>r.id);}
  decide(request:Request):Decision {
    const segments=validateRequest(request), rule=this.state.rules.find(r=>matches(r,request,segments));
    return rule?{allowed:rule.effect==='allow',ruleId:rule.id}:{allowed:false,ruleId:null};
  }
}
