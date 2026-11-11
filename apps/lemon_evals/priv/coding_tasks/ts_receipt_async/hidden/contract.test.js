import test from 'node:test';
import assert from 'node:assert/strict';
import * as service from '../src/receipts.js';
import { MemoryStore } from '../src/memory-store.js';
import { printReceipt } from '../src/console.js';
import { collectReceipts } from '../src/batch.js';
const order={customerId:'c',lines:[{sku:'x',quantity:2},{sku:'x',quantity:0},{sku:'y',quantity:3}]};
function stub({faultAt,reason,closeReason,closeFails=false,missing=false,customer={name:'Ada'}}={}){
 const events=[]; let release; const closed=new Promise(resolve=>{release=resolve});
 let enteredClose; const closeEntered=new Promise(resolve=>{enteredClose=resolve});
 const read=(name,value)=>async(...args)=>{events.push([name,...args]);assert.equal(args.length,1);if(faultAt===name)throw reason;return value};
 const session={order:read('order',missing?null:order),customer:read('customer',customer),price:async(...args)=>{events.push(['price',...args]);assert.equal(args.length,1);if(faultAt==='price')throw reason;return args[0]==='x'?100:7},close:async(...args)=>{assert.equal(args.length,0);events.push(['close']);enteredClose();await closed;if(closeFails)throw closeReason}};
 return {events,release,closeEntered,async open(...args){assert.equal(args.length,0);events.push(['open']);if(faultAt==='open')throw reason;return session;}};
}
test('new API and ordered reads, repeated lines, awaited close',async()=>{
 assert.equal('loadReceipt' in service,false);
 const store=stub(); let done=false; const result=service.buildReceipt('o',store).then(x=>{done=true;return x});
 await store.closeEntered;
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(done,false);
 assert.deepEqual(store.events,[['open'],['order','o'],['customer','c'],['price','x'],['price','x'],['price','y'],['close']]);
 store.release(); assert.deepEqual(await result,{id:'o',customer:'Ada',totalCents:221});
 for(const customer of [null,{name:''}]) {const s=stub({customer});s.release();assert.equal((await service.buildReceipt('o',s)).customer,customer===null?'Guest':'');}
});
test('failure identity and close error precedence includes falsy reasons',async()=>{
 for(const faultAt of ['open','order','customer','price'])for(const reason of [new Error('read failed'),undefined,null,false]){
   const s=stub({faultAt,reason,closeFails:true,closeReason:new Error('close failed')});s.release();
   let caught=false;try{await service.buildReceipt('o',s)}catch(e){caught=true;assert.equal(e,reason)}assert.equal(caught,true);
   assert.equal(s.events.filter(e=>e[0]==='close').length,faultAt==='open'?0:1);
   assert.equal(s.events.at(-1)[0],faultAt==='open'?'open':'close');
   if(faultAt==='order')assert.equal(s.events.some(e=>e[0]==='customer'),false);
   if(faultAt==='customer')assert.equal(s.events.some(e=>e[0]==='price'),false);
 }
 const reason={close:1}; const s=stub({closeFails:true,closeReason:reason});s.release();await assert.rejects(service.buildReceipt('o',s),e=>e===reason);
 const m=stub({missing:true,closeFails:true,closeReason:reason});m.release();await assert.rejects(service.buildReceipt('absent',m),e=>e instanceof service.OrderNotFoundError&&e.name==='OrderNotFoundError'&&e.id==='absent'&&e.message==='order not found: absent');
 assert.deepEqual(m.events,[['open'],['order','absent'],['close']]);
});
test('memory store async APIs, session isolation and batch fail-fast',async()=>{
 const data={orders:new Map([['o',structuredClone(order)],['empty',{customerId:'n',lines:[]}]]),customers:new Map(),prices:new Map([['x',100],['y',7]])};
 const before=structuredClone(data);const s=new MemoryStore(data);
 assert.equal(await printReceipt('empty',s),'empty | Guest | 0');
 assert.deepEqual(await collectReceipts(['o','o'],s),['o | Guest | 221','o | Guest | 221']);
 const prior=s.events.length;await assert.rejects(collectReceipts(['missing','o'],s),service.OrderNotFoundError);
 assert.deepEqual(s.events.slice(prior),['open','order:missing','close']);
 const a=await s.open(),b=await s.open();await a.close();await a.close();
 for(const method of ['order','customer','price'])await assert.rejects(a[method]('x'),{message:'session closed'});
 assert.deepEqual(await b.order('o'),order);assert.equal(await b.order('absent'),null);assert.equal(await b.customer('absent'),null);
 await assert.rejects(b.price('absent'),{message:'unknown sku: absent'});await b.close();
 assert.deepEqual(data,before);
});
