export class MemoryStore {
  constructor(data) { this.data=data; this.events=[]; }
  async open() {
    this.events.push('open');
    const data=this.data, events=this.events; let closed=false;
    const read=async(kind,key)=>{
      if(closed) throw new Error('session closed');
      events.push(`${kind}:${key}`);
      const map=data[kind==='order'?'orders':kind==='customer'?'customers':'prices'];
      if(kind==='price' && !map.has(key)) throw new Error(`unknown sku: ${key}`);
      return map.get(key) ?? null;
    };
    return {order:id=>read('order',id),customer:id=>read('customer',id),price:id=>read('price',id),
      async close(){if(!closed){closed=true;events.push('close');}}};
  }
}
