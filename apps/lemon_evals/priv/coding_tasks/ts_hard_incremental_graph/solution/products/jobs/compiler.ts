import {schema} from './schema.ts';
import {Graph} from '../../src/graph.ts';
import type {NodeSpec} from '../../src/graph.ts';
export function compile(raw:unknown):NodeSpec[] {
  if(!Array.isArray(raw)) throw Error('wire nodes');
  const nodes=raw.map(n=>{
    if(n===null || typeof n!=='object' || Array.isArray(n)) throw Error('wire node');
    return {id:n[schema.id],deps:n[schema.deps],kind:n[schema.kind],
      ...(Object.prototype.hasOwnProperty.call(n,schema.amount)?{value:n[schema.amount]}:{})} as NodeSpec;
  });
  return new Graph(nodes).snapshot();
}
