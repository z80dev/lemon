export type NodeSpec = {id: string; deps: string[]; kind: 'input'|'sum'|'product'|'offset'; value?: number};
type Cache = {spec: string; args: number[]; result: number};
const own = (o:object,k:string) => Object.prototype.hasOwnProperty.call(o,k);
const object = (v:unknown):v is Record<string,unknown> => v !== null && typeof v === 'object' && !Array.isArray(v);
const text = (v:unknown):v is string => typeof v === 'string' && v.length > 0;
const finite = (v:unknown):v is number => typeof v === 'number' && Number.isFinite(v);
const signature = (n:NodeSpec) => JSON.stringify([n.kind,n.deps,n.value]);

function validate(raw:NodeSpec[]): Map<string,NodeSpec> {
  if (!Array.isArray(raw)) throw Error('nodes');
  const result = new Map<string,NodeSpec>();
  for (const node of raw) {
    if (!object(node) || !text(node.id) || result.has(node.id) || !Array.isArray(node.deps) || node.deps.some(d=>!text(d)) || new Set(node.deps).size !== node.deps.length) throw Error('node identity');
    if (Object.keys(node).some(k=>!['id','deps','kind','value'].includes(k))) throw Error('node schema');
    const hasValue = own(node,'value');
    switch(node.kind) {
      case 'input': if (node.deps.length || hasValue) throw Error('input shape'); break;
      case 'sum': case 'product': if (!node.deps.length || hasValue) throw Error('aggregate shape'); break;
      case 'offset': if (node.deps.length !== 1 || !hasValue || !finite(node.value)) throw Error('offset shape'); break;
      default: throw Error('kind');
    }
    result.set(node.id,{id:node.id, deps:[...node.deps], kind:node.kind, ...(hasValue?{value:node.value}: {})});
  }
  const visiting = new Set<string>(), done = new Set<string>();
  const visit = (id:string) => {
    if (done.has(id)) return;
    if (visiting.has(id)) throw Error('cycle');
    const node = result.get(id);
    if (!node) throw Error('missing dependency');
    visiting.add(id);
    for (const dep of node.deps) visit(dep);
    visiting.delete(id);done.add(id);
  };
  for (const id of result.keys()) visit(id);
  return result;
}

export class Graph {
  private nodes: Map<string,NodeSpec>;
  private cache = new Map<string,Cache>();
  constructor(nodes:NodeSpec[]) { this.nodes = validate(nodes); }
  snapshot():NodeSpec[] {
    return [...this.nodes.values()].sort((a,b)=>a.id<b.id?-1:a.id>b.id?1:0).map(n=>({...n,deps:[...n.deps]}));
  }
  replace(nodes:NodeSpec[]):void {
    const next=validate(nodes), invalid=new Set<string>();
    for (const [id,node] of this.nodes) if (!next.has(id) || signature(node)!==signature(next.get(id)!)) invalid.add(id);
    for (const id of next.keys()) if (!this.nodes.has(id)) invalid.add(id);
    let changed=true;
    while(changed) {
      changed=false;
      for (const [id,node] of next) if (!invalid.has(id) && node.deps.some(d=>invalid.has(d))) { invalid.add(id);changed=true; }
    }
    const cache=new Map(this.cache);
    for (const id of invalid) cache.delete(id);
    this.nodes=next;this.cache=cache;
  }
  evaluate(targets:string[], inputs:Record<string,number>):{values:Record<string,number>;executed:string[]} {
    if (!Array.isArray(targets) || !object(inputs) || targets.some(id=>!text(id)||!this.nodes.has(id))) throw Error('request');
    const cache=new Map(this.cache), visited=new Map<string,number>(), executed:string[]=[];
    const visit=(id:string):number=> {
      if (visited.has(id)) return visited.get(id)!;
      const node=this.nodes.get(id)!;
      let args:number[];
      if (node.kind==='input') {
        if (!own(inputs,id) || !finite(inputs[id])) throw Error('input');
        args=[inputs[id]];
      } else args=node.deps.map(visit);
      const spec=signature(node), previous=cache.get(id);
      let result:number;
      if (previous && previous.spec===spec && previous.args.length===args.length && previous.args.every((n,i)=>Object.is(n,args[i]))) result=previous.result;
      else {
        switch(node.kind) {
          case 'input': result=args[0];break;
          case 'sum': result=args.reduce((a,b)=>a+b,0);break;
          case 'product': result=args.reduce((a,b)=>a*b,1);break;
          case 'offset': result=args[0]+node.value!;break;
        }
        if (!finite(result!)) throw Error('nonfinite result');
        cache.set(id,{spec,args,result:result!});executed.push(id);
      }
      visited.set(id,result!);return result!;
    };
    const values:Record<string,number>={};
    for (const id of targets) Object.defineProperty(values,id,{value:visit(id),enumerable:true,writable:true,configurable:true});
    this.cache=cache;
    return {values,executed};
  }
}
