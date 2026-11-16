// SPDX-License-Identifier: MIT
// What a model reads. Full records stay on the HTTP API; every character here is paid
// for by every agent that calls the tool, so defaults and empties are left out.
const clip=(s,n)=>typeof s==='string'&&s.length>n?s.slice(0,n-1)+'…':s;
const clean=o=>Object.fromEntries(Object.entries(o).filter(([,v])=>v!==undefined&&v!==null&&v!==''&&!(Array.isArray(v)&&!v.length)));
const rank={recent:0,unknown:1,offline:2};
export const participant=p=>clean({address:p.address,label:clip(p.label,60),activity:clip(p.activity,120),state:p.state==='working'?undefined:p.state,
  presence:p.presence==='recent'?undefined:p.presence,location:clip(p.location,80),capabilities:p.capabilities?.slice(0,5).map(c=>clip(c,40))});
const holder=h=>h&&clean({label:clip(h.label,60),address:h.address,deadline:h.deadline,state:h.state==='running'?undefined:h.state});
// The legacy artifact slot and idle pool slots only add noise; pools are summarised once.
export function resources(list=[],pools){
  const shown=list.filter(r=>r.holder||r.state!=='unclaimed'||(r.plugin!=='artifact'&&r.localId!=='artifact'&&!r.pool));
  const entries=shown.map(r=>clean({id:r.id,pool:r.pool,state:r.state,plugin:r.plugin,enforcement:clip(r.enforcement,160),hosts:r.hosts,queued:(r.queued??r.queue?.length)||undefined,holder:holder(r.holder)}));
  // Group once; a fleet can have a distinct pool on every host.
  const groups=new Map();
  if(!pools)for(const r of list)if(r.pool){
    const id=`${r.id.split('/')[0]}/${r.pool}`;
    const group=groups.get(id)??{id,capacity:0,free:0};
    group.capacity++;if(r.state==='unclaimed')group.free++;groups.set(id,group);
  }
  const grouped=pools??[...groups.values()];
  return clean({resources:entries,pools:grouped});
}
const hostLists=hosts=>{
  const known=new Map();for(const h of hosts)if(h.status==='unknown'||!known.has(h.authority))known.set(h.authority,h.status);
  return clean({hosts:[...known.keys()],unknownHosts:[...known].filter(([,s])=>s==='unknown').map(([a])=>a)});
};
export function bootstrap({address,announced,participants=[],resourceList,pools,hosts=[],recent,observed,inboxPending,deliveryProblems,learnings}){
  const peers=participants.slice(0,5).map(participant);
  return {participants:peers,...clean({address,announced:announced||undefined,moreParticipants:Math.max(0,(recent??peers.length)-peers.length)||undefined,
    ...resources(resourceList,pools),...hostLists(hosts),observed:observed||undefined,inboxPending:inboxPending||undefined,deliveryProblems,
    learnings:(learnings??[]).slice(0,5).map(l=>clean({name:l.name,type:l.type,description:clip(l.description,120),source:l.source,updated:l.updated}))})};
}
export function find(result,query=''){
  const ranked=[...(result.participants??[])].sort((a,b)=>(rank[a.presence]??0)-(rank[b.presence]??0)||(b.lastSeen??0)-(a.lastSeen??0));
  const matched=query?ranked:ranked.filter(p=>p.presence!=='offline'),hosts=result.hosts??[],limit=query?20:12;
  const hostMap=new Map();for(const h of hosts)if(h.status==='unknown'||!hostMap.has(h.authority))hostMap.set(h.authority,{authority:h.authority,status:h.status,...(h.reason?{reason:h.reason}:{})});
  const view={participants:[],...clean({participants:matched.slice(0,limit).map(participant),moreParticipants:(result.moreParticipants??0)+Math.max(0,matched.length-limit)||undefined,
    ...resources(result.resources??hosts.flatMap(h=>h.resources??[]),result.pools),hosts:[...hostMap.values()],
    observed:(result.observed??result.observations?.length)||undefined,inboxPending:result.inboxPending,deliveryProblems:result.deliveryProblems,
    moreResources:result.moreResources,moreHosts:result.moreHosts,
    next:'Observers are history, not extra peers. Search history with accord_sessions; use accord_resources for full resources.'})};
  // Count each removed entry once, including UTF-8 and JSON escaping. Repeatedly
  // serializing the shrinking fleet made this quadratic in the number of slots.
  bound(view,8192,[['participants','moreParticipants'],['resources','moreResources'],['pools','moreResources'],['hosts','moreHosts']]);
  return view;
}
export const reservation=r=>clean(r);

// Mutates only the supplied presentation arrays. Complete records remain in storage.
export function bound(view,maxBytes,fields){
  let bytes=Buffer.byteLength(JSON.stringify(view));
  for(const [field,count] of fields){
    const rows=view[field];
    while(bytes>maxBytes&&rows?.length){
      const removed=rows.pop();
      bytes-=Buffer.byteLength(JSON.stringify(removed))+(rows.length?1:0);
      const before=view[count];view[count]=(before??0)+1;
      bytes+=before===undefined?Buffer.byteLength(JSON.stringify(count))+2+String(view[count]).length:String(view[count]).length-String(before).length;
    }
  }
  return view;
}

export function board(result){
  const previousEvent=Math.max(0,(result.events[0]?.seq??result.cursor+1)-1);
  const view={...result,
    tasks:result.tasks.map(t=>clean({id:t.id,title:clip(t.title,120),state:t.state,resource:t.resource,dependency:t.dependency,blockedBy:t.blockedBy})),
    claims:result.claims.map(c=>clean({id:c.id,task:c.task_id,actor:c.actor,generation:c.generation,state:c.state,deadline:c.deadline,error:c.error})),
    next:'Use detail:true with the same before/limit for complete task records; nextBefore continues older tasks.'};
  bound(view,24*1024,[['events','moreEvents'],['sessions','moreSessions'],['claims','moreClaims'],['resources','moreResources']]);
  if(view.moreEvents){view.cursor=view.events.at(-1)?.seq??previousEvent;view.hasMore=true;}
  return view;
}

export function sessions(result){
  const view={...result,sessions:result.sessions.map(s=>clean({id:s.id,address:s.address,title:clip(s.givenTitle??s.title,120),titledBy:s.givenTitle?s.titledBy:undefined,state:s.state,
    summary:clip(s.summary,200),location:clip(s.location,80),private:s.private||undefined,presence:s.presence,source:s.source,progressAt:s.progressAt})),
    next:'Use session_read for activity (previous becomes before for older events), or sessions detail:true for full metadata.'};
  return bound(view,8192,[['sessions','moreSessions']]);
}

// Stable ID pages retain complete compact records and pool summaries. A cursor
// includes record kind: a legacy resource and a pool can share a displayed ID.
export function resourcePage(result,{cursor='',limit=20}={}){
  const after=cursor?`${cursor.slice(2)}\0${cursor[0]}`:'',compact=resources(result.resources,result.pools),rows=[...(compact.resources??[]).map(value=>({kind:'resources',value})),...(compact.pools??[]).map(value=>({kind:'pools',value}))]
    .map(r=>({...r,key:`${r.value.id}\0${r.kind[0]}`})).filter(r=>r.key>after).sort((a,b)=>a.key<b.key?-1:a.key>b.key?1:0);
  const page={resources:[],...(result.inboxPending?{inboxPending:result.inboxPending}:{}),...(result.deliveryProblems?{deliveryProblems:result.deliveryProblems}:{})};
  let bytes=Buffer.byteLength(JSON.stringify(page)),count=0,last;
  for(const {kind,value} of rows){const size=Buffer.byteLength(JSON.stringify(value))+16;if(count>=limit||(count&&bytes+size>8192-512))break;
    (page[kind]??=[]).push(value);bytes+=size;count++;last=`${kind[0]}:${value.id}`;}
  if(bytes>8192-512)page.oversized=true;
  if(count<rows.length){page.more=true;page.cursor=last;}
  return page;
}
