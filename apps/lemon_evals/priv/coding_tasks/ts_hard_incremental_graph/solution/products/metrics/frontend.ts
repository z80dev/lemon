import {compile} from './compiler.ts';
import {Graph} from '../../src/graph.ts';
export function create(raw:unknown) {
  const graph=new Graph(compile(raw));
  return {
    run:(targets:string[],inputs:Record<string,number>)=>graph.evaluate(targets,inputs),
    update:(next:unknown)=>graph.replace(compile(next)),
    inspect:()=>graph.snapshot(),
  };
}
