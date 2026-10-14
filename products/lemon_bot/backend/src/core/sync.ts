import type { BackendServices, Route } from './services';
import type * as P from '../../../contracts/protocol';
import { principal } from './validation';
export function capabilities(services:BackendServices):P.Capabilities {
  const provider=services.integrations.providerCapabilities();
  return {controlConnected:services.lemon.connected,methods:[...services.lemon.methods],stt:provider.stt??false,tts:provider.tts??false,imageGeneration:provider.imageGeneration??false,apns:provider.apns??false,webPush:provider.webPush??false,vapidPublicKey:provider.vapidPublicKey??null,attachmentMaxBytes:25*1024*1024,videoMaxBytes:200*1024*1024,maxAttachments:6,minClientVersions:provider.minClientVersions??{web:'0.1.0',macos:'0.1.0',ios:'0.1.0'}};
}
export function createSyncRoutes(services:BackendServices):Route[] {
  return [
    {method:'GET',path:'/v1/capabilities',auth:'member',handler:()=>capabilities(services)},
    {method:'GET',path:'/v1/sync',auth:'member',handler:context=>services.store.transaction(()=>{
      const user=principal(context.user);const member=services.auth.member(user.userId);const workspace=services.store.require<P.Workspace>('workspaces',user.workspaceId);
      const bots=services.store.list<P.Bot>('bots',bot=>services.auth.canRead(user,'bots',bot)).map(bot=>services.auth.bot(user,bot.id));
      const machines=services.store.list<P.Machine>('machines',machine=>services.auth.canRead(user,'machines',machine));
      const conversations=services.store.list<P.Conversation>('conversations',room=>services.auth.canRead(user,'conversations',room)).map(room=>services.auth.conversation(user,room.id));
      const notifications=services.store.list<P.Notification>('notifications',item=>item.userId===user.userId);
      const sections=services.store.list<P.Section>('sections',section=>section.userId===user.userId);
      const activeRuns=services.store.list<P.Run>('runs',run=>['reserved','queued','running','awaiting_input','outcome_unknown'].includes(run.status)&&services.auth.canRead(user,'runs',run));
      const latest=<T extends {updatedAtMs:number;id:string}>(values:T[])=>values.sort((a,b)=>b.updatedAtMs-a.updatedAtMs||a.id.localeCompare(b.id)).slice(0,200);
      const snapshot:P.Snapshot={cursor:services.events.cursor(),user:services.auth.user(user.userId),workspace,member,capabilities:capabilities(services),bots:latest(bots),machines:latest(machines),conversations:latest(conversations),sections:sections.sort((a,b)=>a.rank-b.rank||a.id.localeCompare(b.id)),notifications:latest(notifications),activeRuns:latest(activeRuns),hasMore:{bots:bots.length>200,machines:machines.length>200,conversations:conversations.length>200,notifications:notifications.length>200}};
      return snapshot;
    })}
  ];
}
