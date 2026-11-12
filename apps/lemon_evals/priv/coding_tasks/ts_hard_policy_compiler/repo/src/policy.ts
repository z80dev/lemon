export type Rule={id:string;effect:'allow'|'deny';resource:string;actions:string[];priority:number;conditions:Record<string,string|string[]|null>};
export type Layer={name:string;rules:Rule[];remove:string[]};
export type Request={resource:string;action:string;attributes:Record<string,string>};
export type Decision={allowed:boolean;ruleId:string|null};
export class Policy {
  private layers:Layer[];
  constructor(layers:Layer[]){this.layers=layers;}
  decide(request:Request):Decision {
    for(const layer of this.layers) for(const rule of layer.rules)
      if(rule.resource===request.resource && rule.actions.includes(request.action)) return {allowed:true,ruleId:rule.id};
    return {allowed:false,ruleId:null};
  }
}
