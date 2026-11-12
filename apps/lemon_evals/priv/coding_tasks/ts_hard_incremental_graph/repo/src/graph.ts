export type NodeSpec = {id: string; deps: string[]; kind: 'input'|'sum'|'product'|'offset'; value?: number};
export class Graph {
  private nodes: NodeSpec[];
  constructor(nodes: NodeSpec[]) { this.nodes = nodes; }
  evaluate(targets: string[], inputs: Record<string,number>) {
    const values: Record<string,number> = {};
    const visit = (id:string):number => {
      const node = this.nodes.find(n => n.id === id)!;
      return node.kind === 'input' ? inputs[id] : node.deps.reduce((s,d)=>s+visit(d),0);
    };
    for (const target of targets) values[target] = visit(target);
    return {values, executed: targets};
  }
}
