import { expect, test } from 'bun:test';
import { LemonBotClient } from '../src/client';
import fixture from './fixtures/instance-status.json';
import { fetchBoundary } from './fixtures';

test('instance helpers use the product backend and nonce-bearing lifecycle requests',async()=>{
  const boundary=fetchBoundary(()=>Response.json(fixture));
  const requests=boundary.requests;
  const client=new LemonBotClient({baseUrl:'https://lemon.example',token:'product-session',fetch:boundary.clientFetch});
  expect(await client.instance() as unknown).toEqual(fixture);await client.reconnectController();await client.runtimeAction('restart',true);
  expect(requests.map(request=>[request.method,request.url])).toEqual([['GET','https://lemon.example/v1/instance'],['POST','https://lemon.example/v1/instance/reconnect'],['POST','https://lemon.example/v1/instance/runtime/restart']]);
  expect(requests[0]!.headers.get('Authorization')).toBe('Bearer product-session');
  const reconnect=await requests[1]!.json();const action=await requests[2]!.json();expect(reconnect.clientNonce).toBeString();expect(action.clientNonce).toBeString();expect(action.clientNonce).not.toBe(reconnect.clientNonce);expect(action.confirm).toBe(true);
});

test('runtime confirmation is not silently granted by the client',async()=>{
  let body:unknown;
  const boundary=fetchBoundary(async request=>{body=await request.json();return Response.json({id:'operation',state:'running'});});
  const client=new LemonBotClient({baseUrl:'https://lemon.example',fetch:boundary.clientFetch});
  await client.runtimeAction('stop');expect(body).toMatchObject({confirm:false});
});
