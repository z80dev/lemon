import { Database } from 'bun:sqlite';
import { z } from 'zod';
import type { EntityStore } from './services';
import { fail } from './errors';
const storedObject = z.object({ id:z.string().min(1) }).passthrough();
export class Store implements EntityStore {
  readonly db: Database;
  private depth = 0;
  private callbacks: (() => void)[] = [];
  constructor(path: string) {
    this.db = new Database(path, { create:true, strict:true });
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS entities(collection TEXT NOT NULL,id TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(collection,id));
      CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,event TEXT NOT NULL,payload TEXT NOT NULL,audience TEXT NOT NULL,timestamp_ms INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS events_time ON events(timestamp_ms);
      CREATE TABLE IF NOT EXISTS nonces(scope TEXT NOT NULL,nonce TEXT NOT NULL,hash TEXT NOT NULL,state TEXT NOT NULL,receipt TEXT,resource_ids TEXT NOT NULL DEFAULT '[]',created_at_ms INTEGER NOT NULL,PRIMARY KEY(scope,nonce));
      CREATE TABLE IF NOT EXISTS confirmations(token_digest TEXT PRIMARY KEY,user_id TEXT NOT NULL,target_id TEXT NOT NULL,revision INTEGER NOT NULL,action TEXT NOT NULL,name TEXT NOT NULL,binding TEXT NOT NULL,expires_at_ms INTEGER NOT NULL,consumed INTEGER NOT NULL DEFAULT 0);`);
  }
  get<T>(collection: string, id: string): T | null {
    const row = this.db.query('SELECT value FROM entities WHERE collection=? AND id=?').get(collection,id) as { value:string } | null;
    if (!row) return null;
    const object = storedObject.parse(JSON.parse(row.value));
    // Entity writers own domain schemas; the storage boundary validates the universal identity envelope.
    const value = object as unknown as T;
    return value;
  }
  require<T>(collection: string, id: string): T { const value=this.get<T>(collection,id); if(value===null) fail('not_found','Resource was not found.'); return value; }
  list<T>(collection: string, predicate?: (value:T)=>boolean): T[] {
    const rows = this.db.query('SELECT value FROM entities WHERE collection=? ORDER BY id').all(collection) as {value:string}[];
    const values=rows.map(row=>{ const object=storedObject.parse(JSON.parse(row.value)); return object as unknown as T; });
    return predicate ? values.filter(predicate) : values;
  }
  put<T>(collection:string, value:T & {id:string}):T {
    storedObject.parse(value);
    this.db.query('INSERT INTO entities(collection,id,value) VALUES(?,?,?) ON CONFLICT(collection,id) DO UPDATE SET value=excluded.value').run(collection,value.id,JSON.stringify(value));
    return value;
  }
  remove(collection:string,id:string):void { this.db.query('DELETE FROM entities WHERE collection=? AND id=?').run(collection,id); }
  transaction<T>(operation:()=>T):T {
    if(this.depth>0) return operation();
    this.db.exec('BEGIN IMMEDIATE'); this.depth=1;
    try { const result=operation(); if(result instanceof Promise) throw new TypeError('SQLite transactions must remain synchronous.'); this.db.exec('COMMIT'); this.depth=0; const callbacks=this.callbacks; this.callbacks=[]; for(const callback of callbacks) callback(); return result; }
    catch(error) { if(this.depth>0) this.db.exec('ROLLBACK'); this.depth=0; this.callbacks=[]; throw error; }
  }
  afterCommit(callback:()=>void):void { if(this.depth>0) this.callbacks.push(callback); else callback(); }
  metadata<T>(key:string):T|null {
    const row=this.db.query('SELECT value FROM metadata WHERE key=?').get(key) as {value:string}|null;
    if(!row) return null;
    // Metadata schemas belong to each owning module; JSON decoding rejects non-JSON persisted data.
    const value:unknown=JSON.parse(row.value); return value as T;
  }
  setMetadata(key:string,value:unknown):void { this.db.query('INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(key,JSON.stringify(value)); }
  close():void { this.db.close(); }
}
