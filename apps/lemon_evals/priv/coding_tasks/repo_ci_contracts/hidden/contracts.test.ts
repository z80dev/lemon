import test from 'node:test';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
const root=process.cwd();
const api=await import(pathToFileURL(join(root,'src/index.ts')).href);
const {routes}=await import(pathToFileURL(join(root,'src/http/manifest.ts')).href);
const hashes=JSON.parse(readFileSync(new URL('./checker-sha256.json',import.meta.url),'utf8'));
function setup() { const app=api.createApp(); const ctx=api.createContext('staff',()=>1234); return {app,ctx,post:(path,body)=>app.handle({method:'POST',path,body},ctx),get:path=>app.handle({method:'GET',path},ctx)}; }
function error(response,status,code,message) { assert.deepEqual(response,{status,body:{error:code,message}}); }
test('preserved checker, CI command and exact eight route descriptors',()=>{
  for(const [file,hash] of Object.entries(hashes)) assert.equal(createHash('sha256').update(readFileSync(join(root,file))).digest('hex'),hash,file);
  assert.equal(JSON.parse(readFileSync(join(root,'package.json'),'utf8')).scripts.ci,'node scripts/ci.ts');
  const run=spawnSync(process.execPath,['scripts/ci.ts'],{cwd:root,encoding:'utf8'});
  assert.equal(run.status,0,run.stderr);assert.equal(run.stdout,'contracts: ok\n');
  assert.deepEqual(routes.map(({name,method,path,requiresActor})=>({name,method,path,requiresActor})),[
    {name:'health',method:'GET',path:'/v1/health',requiresActor:false},
    {name:'stock-list',method:'GET',path:'/v1/stock',requiresActor:false},
    {name:'stock-add',method:'POST',path:'/v1/stock',requiresActor:true},
    {name:'stock-get',method:'GET',path:'/v1/stock/:sku',requiresActor:false},
    {name:'reservation-create',method:'POST',path:'/v1/reservations',requiresActor:true},
    {name:'reservation-cancel',method:'POST',path:'/v1/reservations/:reservationId/cancel',requiresActor:true},
    {name:'reservation-fulfill',method:'POST',path:'/v1/reservations/:reservationId/fulfill',requiresActor:true},
    {name:'report',method:'GET',path:'/v1/report',requiresActor:false}
  ]);
});
test('authorization and validation precede mutation; errors keep documented shapes',()=>{
  const {app,post,get}=setup();
  for(const actorId of [null,' ']) for(const path of ['/v1/stock','/v1/reservations','/v1/reservations/r/cancel','/v1/reservations/r/fulfill'])
    error(app.handle({method:'POST',path,body:{}},api.createContext(actorId)),401,'unauthorized','actor required');
  assert.deepEqual(get('/v1/health'),{status:200,body:{ok:true}});
  error(get('/absent'),404,'missing','route not found');
  error(get('/v1/stock/unknown'),404,'missing','sku not found');
  for(const quantity of [0,-1,1.5,NaN,Infinity,'2',null]) error(post('/v1/stock',{sku:'x',quantity}),400,'invalid','quantity must be a positive integer');
  error(post('/v1/stock',{sku:' ',quantity:1}),400,'invalid','sku must be nonempty');
  assert.deepEqual(get('/v1/stock'),{status:200,body:{items:[]}});assert.equal(app.services.audit.snapshot().length,0);
  post('/v1/stock',{sku:' x ',quantity:5});
  error(post('/v1/reservations',{reservationId:' ',sku:'x',quantity:1}),400,'invalid','reservationId must be nonempty');
  error(post('/v1/reservations',{reservationId:'r',sku:'x',quantity:6}),409,'conflict','insufficient stock');
  error(post('/v1/reservations',{reservationId:'r',sku:'none',quantity:1}),404,'missing','sku not found');
  for(const quantity of [1.5,0,'1']) error(post('/v1/reservations',{reservationId:'r',sku:'x',quantity}),400,'invalid','quantity must be a positive integer');
  assert.deepEqual(get('/v1/stock/x').body,{sku:'X',onHand:5,reserved:0,available:5});
  assert.equal(app.services.audit.snapshot().length,1);
  error(post('/v1/reservations/missing/cancel'),404,'missing','reservation not found');
});
test('stock lifecycle, idempotent cancellation, snapshots and deterministic audit',()=>{
  const {app,post,get}=setup();
  assert.equal(post('/v1/stock',{sku:'z',quantity:5}).status,200);
  post('/v1/stock',{sku:'a',quantity:10});post('/v1/stock',{sku:' A ',quantity:2});
  const created=post('/v1/reservations',{reservationId:' one ',sku:'a',quantity:4});
  assert.deepEqual(created,{status:201,body:{reservationId:'one',sku:'A',quantity:4,status:'active'}});
  created.body.quantity=999;
  error(post('/v1/reservations',{reservationId:'one',sku:'a',quantity:1}),409,'conflict','reservationId already exists');
  error(post('/v1/reservations',{reservationId:'oversell',sku:'a',quantity:9}),409,'conflict','insufficient stock');
  assert.deepEqual(post('/v1/reservations/one/fulfill'),{status:200,body:{reservationId:'one',sku:'A',quantity:4,status:'fulfilled'}});
  error(post('/v1/reservations/one/fulfill'),409,'conflict','reservation is not active');
  error(post('/v1/reservations/one/cancel'),409,'conflict','reservation already fulfilled');
  post('/v1/reservations',{reservationId:'two',sku:'a',quantity:3});
  const cancel=post('/v1/reservations/two/cancel');assert.equal(cancel.body.status,'cancelled');
  assert.deepEqual(post('/v1/reservations/two/cancel'),cancel);
  error(post('/v1/reservations/two/fulfill'),409,'conflict','reservation is not active');
  post('/v1/reservations',{reservationId:'three',sku:'z',quantity:2});
  assert.deepEqual(get('/v1/stock'),{status:200,body:{items:[{sku:'A',onHand:8,reserved:0,available:8},{sku:'Z',onHand:5,reserved:2,available:3}]}});
  assert.deepEqual(get('/v1/report'),{status:200,body:{skus:2,onHand:13,reserved:2,available:11,activeReservations:1}});
  const expected=[['stock.added','Z'],['stock.added','A'],['stock.added','A'],['reservation.created','one'],['reservation.fulfilled','one'],['reservation.created','two'],['reservation.cancelled','two'],['reservation.created','three']].map(([action,subject])=>({action,subject,actorId:'staff',at:1234}));
  assert.deepEqual(app.services.audit.snapshot(),expected);
  const rows=app.services.audit.snapshot();rows[0].subject='changed';assert.deepEqual(app.services.audit.snapshot(),expected);
  assert.deepEqual(api.createApp().handle({method:'GET',path:'/v1/report'},api.createContext()),{status:200,body:{skus:0,onHand:0,reserved:0,available:0,activeReservations:0}});
});
test('unexpected failures use the stable internal-error response',()=>{
  const app=api.createApp();
  const ctx=api.createContext('staff',()=>{throw new Error('private detail');});
  error(app.handle({method:'POST',path:'/v1/stock',body:{sku:'x',quantity:1}},ctx),500,'internal','internal error');
});
