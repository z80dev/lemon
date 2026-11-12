export class MemoryStore {
  constructor(data) { this.data=data; this.events=[]; }
  open(callback) {
    this.events.push('open');
    const data=this.data, events=this.events; let closed=false;
    const read=(kind,key,done)=>{
      if(closed) return done(new Error('session closed'));
      events.push(`${kind}:${key}`);
      const map=data[kind==='order'?'orders':kind==='customer'?'customers':'prices'];
      if(kind==='price' && !map.has(key)) return done(new Error(`unknown sku: ${key}`));
      done(null,map.get(key) ?? null);
    };
    callback(null, {order:(id,done)=>read('order',id,done),customer:(id,done)=>read('customer',id,done),price:(id,done)=>read('price',id,done),
      close(done){ if(!closed){closed=true;events.push('close');} done(null); }});
  }
}
