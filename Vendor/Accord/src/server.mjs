// SPDX-License-Identifier: MIT
import { singleFlight } from './async-work.mjs';
import { ResourceManagers } from './resource-managers.mjs';
import { awarenessRuntime } from './awareness-runtime.mjs';
import { SessionAwareness } from './session-awareness.mjs';
import { Overseer } from './overseer.mjs';
import { Schedules } from './schedules.mjs';
import { dirname,join } from 'node:path';
import { homedir } from 'node:os';
import { readdirSync } from 'node:fs';
import { createWorkloads, workloadView } from './workloads.mjs';
import { createTelemetry } from './telemetry.mjs';
import { createCollectors } from './telemetry-collectors.mjs';
import { sensorPath } from './native-sensors.mjs';
import { createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { plugins,validateResource } from './resource-plugins.mjs';
import { Collaboration } from './collaboration.mjs';
import { MemoryPanorama, memoryConfig, peerEntries } from './memory-panorama.mjs';
import { Attention } from './attention.mjs';
import { Store } from './store.mjs';
import { bootstrapView } from './bootstrap-view.mjs';
import { find as compactFind } from './compact.mjs';
import { createHttp, bearer, readBody, hash, request, integer, requireThat, loopbackUrl, text } from './common.mjs';
import { orphanGraceDefaultMs, cooperativeAgeOutDefaultMs } from './lifecycle.mjs';

export function coordinator({ db, claimSecret, driverUrl, driverToken, driverInstance, leaderMs = 5000, tickMs = 100, hostName = 'local', telemetryCollectors, driverRequest=request, hostWorkloads=createWorkloads(), linksDir=join(homedir(),'.config','accord','links') }) {
  integer(leaderMs, 'leaderMs', 500, 30000); integer(tickMs, 'tickMs', 10, 1000);
  const parsed = new URL(driverUrl);
  requireThat(parsed.protocol === 'http:' && ['127.0.0.1', 'localhost'].includes(parsed.hostname) && !parsed.username && !parsed.password,
    'BAD_DRIVER_URL', 'This release supports a loopback HTTP driver only', 400);
  const store = new Store(db, { leaderMs });
  let collaboration,memory,managers,awareness,overseer,attention,telemetry,schedules;
  try {
    // Synchronous mailbox migrations and config reads can outlast a lease. Finish
    // them before taking leadership; no timer can renew while they block startup.
    collaboration=new Collaboration(store,db);
    memory=new MemoryPanorama(store,memoryConfig());
    managers=new ResourceManagers(store,dirname(db));
    awareness=new SessionAwareness(store,{hostName});
    attention=new Attention(store,collaboration,join(dirname(db),'attention'),{perHour:Number(process.env.ACCORD_WAKE_PER_HOUR||6)});
    telemetry=createTelemetry({authority:store.authority,hostName,collectors:telemetryCollectors??createCollectors({nativeHelper:sensorPath(dirname(db))}),workloads:()=>hostWorkloads.read()});
    store.takeLeadership();
    overseer=new Overseer(store,awareness,collaboration);
    collaboration.agentRecord=actorId=>awareness.agentRecord(actorId);
    schedules=new Schedules(store,collaboration,{resourceExists:localId=>!!store.db.prepare('SELECT 1 FROM resources WHERE id=?').get(localId)||!!store.binding(localId)||managers.owns(localId)});
  } catch (error) {
    attention?.close();
    try { collaboration?.close(); } finally {
      try { if(store.leaderToken)store.releaseLeadership(); } finally { store.close(); }
    }
    throw error;
  }
  managers.onRunning=row=>{try{collaboration.granted(overseer.actor,{key:`grant:${row.id}`,reservation:row.id,actor:row.actor,resource:row.resource,queuedAt:row.created_at});}catch{/* A notice is a hint. */}};
  const observationRuntime=awarenessRuntime(dirname(db),awareness);
  awareness.lifecycleConfig=()=>observationRuntime.lifecycle();
  const secretFor = claim => createHmac('sha256', claimSecret).update(claim.id).digest('base64url');
  const sessionSecret = sessionId => createHmac('sha256', claimSecret).update(`session:${sessionId}`).digest('base64url');
  const instanceFor=resource=>resource==='artifact'?driverInstance:store.binding(resource)?.instance;
  const driverPath=(path,resource='artifact')=>resource==='artifact'?path:`${path}?resource=${encodeURIComponent(resource)}`;
  const grant = claim => ({ instance: instanceFor(claim.resource), authority: store.authority, epoch: store.epoch, generation: claim.generation, claimId: claim.id });
  // Providers may use the holder to attribute work; they may ignore it.
  const holderOf = claim => {
    const row = store.db.prepare('SELECT coalesce(p.label,s.label,c.actor) label,o.authority oa,o.session_id os FROM claims c LEFT JOIN participants p ON p.actor=c.actor LEFT JOIN sessions s ON s.id=c.actor LEFT JOIN remote_routes o ON o.actor=c.actor WHERE c.id=?').get(claim.id);
    return { label: row?.label ?? claim.actor, address: row?.oa ? `${row.oa}/${row.os}` : `${store.authority}/${claim.actor}` };
  };
  let closed = false, busy = false, unhealthy = false,timer,reconcileAgain=false;
  const queueReconcile=delay=>{clearTimeout(timer);if(!closed&&!unhealthy)timer=setTimeout(reconcile,delay);};
  // Schedule after the emitting transaction commits; no work runs inside it.
  store.onEvent=()=>{if(busy)reconcileAgain=true;else queueReconcile(0);};
  let reportFailure;
  const failed = new Promise(resolve => { reportFailure = resolve; });
  function fail(error) {
    if (closed || unhealthy) return;
    unhealthy = true;
    reportFailure(error);
  }

  // Lifecycle notices run on the reconcile tick: both are deduplicated by send
  // keys, so a crash before or after the mark never duplicates or loses one.
  function lifecycleNotices(){
    // Orphaned holds tell the successor (which inherits nothing) and each
    // configured address once; when the hold ends, a second notice confirms.
    const orphans=store.db.prepare(`SELECT r.id reservation,r.orphaned_at,r.orphan_reason,r.task_id,c.id claim,c.generation,c.actor,c.resource,c.state,c.outcome,
        COALESCE(b.orphan_grace_ms,?) grace,s.successor local_successor,rr.successor remote_successor FROM reservations r JOIN claims c ON c.task_id=r.task_id
        LEFT JOIN resource_bindings b ON b.id=c.resource LEFT JOIN sessions s ON s.id=c.actor LEFT JOIN remote_routes rr ON rr.actor=c.actor WHERE r.orphaned_at IS NOT NULL`).all(orphanGraceDefaultMs);
    const notify=observationRuntime.lifecycle().notify??[];
    // A remote actor whose origin reported 'silent' is a stale holder: this
    // host's notify list hears once per claim generation (send-key deduped,
    // retried each tick until delivered).
    for(const h of store.db.prepare(`SELECT rr.authority,rr.session_id,c.id claim,c.generation,c.deadline,c.resource
        FROM remote_routes rr JOIN claims c ON c.actor=rr.actor
        WHERE rr.retired_reason='silent' AND c.state IN ('preparing','running','releasing','revoking')`).all())
      for(const to of notify)try{
        collaboration.send(overseer.actor,{key:`lifecycle.stale:${h.claim}:${h.generation}:${hash(to).slice(0,12)}`,to,kind:'notification',
          text:`Accord reports ${h.authority}/${h.session_id} still holds ${h.resource} with no live session; claim ${h.claim} is held until ${new Date(h.deadline).toISOString()}.`});
      }catch{/* A notice is a hint. */}
    for(const o of orphans){
      const ended=['releasing','revoking','closed'].includes(o.state);
      // A remote route already stores its successor as a full address.
      const successor=o.local_successor?`${store.authority}/${o.local_successor}`:o.remote_successor;
      for(const to of [...(successor?[successor]:[]),...notify])try{
        collaboration.send(overseer.actor,{key:`lifecycle.orphan:${o.reservation}:${ended?'ended':o.orphaned_at}:${hash(to).slice(0,12)}`,to,kind:'notification',
          text:ended?`Accord reports orphaned reservation ${o.reservation} on ${o.resource} ended (${o.state==='closed'?o.outcome:o.state}). Successors never inherit holds: reserve again if you still need it.`
            :`Accord reports reservation ${o.reservation} on ${o.resource} is orphaned (${o.orphan_reason}); it releases at ${new Date(o.orphaned_at+o.grace).toISOString()} unless its holder revives. Successors never inherit holds: reserve again if you need the resource.`});
      }catch{/* A notice is a hint. */}
    }
    // One warning per window deadline, at a lead scaled to the window; an
    // extension changes the deadline and so re-arms the warning.
    for(const w of store.db.prepare(`SELECT c.id claim,c.generation,c.deadline,c.resource,r.id reservation,r.actor,r.duration_ms,r.warned_deadline
        FROM reservations r JOIN claims c ON c.task_id=r.task_id
        LEFT JOIN sessions s ON s.id=c.actor LEFT JOIN remote_routes rr ON rr.actor=c.actor
        WHERE r.duration_ms IS NOT NULL AND c.state='running'
        AND (s.id IS NULL OR (s.retired_at IS NULL AND s.closed_at IS NULL AND s.expires_at>?))
        AND (rr.actor IS NULL OR rr.retired_at IS NULL)
        AND (r.warned_deadline IS NULL OR r.warned_deadline!=c.deadline)`).all(store.now())){
      const lead=Math.min(Math.max(Math.floor(w.duration_ms*0.1),60000),900000);
      if(store.now()<w.deadline-lead)continue;
      const to=collaboration.holder(w.actor);if(!to)continue;
      try{
        collaboration.send(overseer.actor,{key:`expiring:${w.claim}:${w.generation}:${w.deadline}`,to,kind:'message',
          text:`Accord reports reservation ${w.reservation} on ${w.resource} ends at ${new Date(w.deadline).toISOString()}. Extend with accord_extend if you still need it; otherwise release it.`});
      }catch{continue;}
      store.mutate(()=>store.db.prepare('UPDATE reservations SET warned_deadline=? WHERE id=? AND (warned_deadline IS NULL OR warned_deadline!=?)').run(w.deadline,w.reservation,w.deadline));
    }
  }
  const claimFlights=new Map(),retryAfter=new Map();
  // Pending claim states are a durable outbox. One flight per resource preserves
  // ordering; independent arrivals can use an empty slot without waiting for a
  // slow batch. Failed destinations yield their slot before retrying.
  async function reconcile() {
    if (busy || closed || unhealthy) return;
    busy = true;clearTimeout(timer);
    try {
      store.sweep();
      collaboration.schedule();
      try{lifecycleNotices();}catch{/* Notices retry on the next tick. */}
      try{if(schedules.tick())void collaboration.flush().catch(()=>{});}catch{/* Schedule work retries on the next tick. */}
      void managers.reconcile().catch(()=>{});
      const pending=store.pending(),ids=new Set(pending.map(c=>c.id));
      for(const id of retryAfter.keys())if(!ids.has(id))retryAfter.delete(id);
      for(const claim of pending){
        if(claimFlights.size>=4)break;
        if(claimFlights.has(claim.resource)||(retryAfter.get(claim.id)??0)>store.now())continue;
        const flight=Promise.resolve().then(async()=>{
          if(closed||unhealthy)return;
          try {
            store.assertLeader();
            const activating = claim.state === 'preparing';
            const response = await driverRequest(driverUrl, driverToken, driverPath(activating ? '/control/activate' : '/control/revoke',claim.resource), {
              ...grant(claim), ...(activating ? { credentialHash: hash(secretFor(claim)), holder: holderOf(claim) } : {})
            }, 600);
            requireThat(response.instance === instanceFor(claim.resource) && response.claimId === claim.id && response.generation === claim.generation && (activating ? response.active === true : response.released === true),
              'BAD_DRIVER_RECEIPT', 'Driver did not confirm this generation', 503);
            if (activating) {
              store.activated(claim.id);
              // Activation is a no-op if the claim changed meanwhile; never report a grant that didn't happen.
              try { if(store.claim(claim.id).state==='running')collaboration.grantedClaim(overseer.actor,claim); } catch { /* A notice is a hint. */ }
            } else {
              store.released(claim.id);
              try { collaboration.endedClaim(overseer.actor,claim); } catch { /* A notice is a hint. */ }
            }
            retryAfter.delete(claim.id);
          } catch (error) {
            retryAfter.set(claim.id,store.now()+tickMs);
            // This generation can never activate there, so waiting for its deadline only idles the resource.
            if (claim.state === 'preparing' && ['REVOKED','RECOVERING'].includes(error.code)) store.refused(claim.id, error.code);
            else store.driverError(claim.id, ['DRIVER_REPLACED','STALE_FENCE','WRONG_AUTHORITY','REVOKED'].includes(error.code) ? error.code : 'DRIVER_UNAVAILABLE');
          }
        }).catch(fail).finally(()=>{claimFlights.delete(claim.resource);queueReconcile(0);});
        claimFlights.set(claim.resource,flight);
      }
    } catch (error) { fail(error); } finally {
      busy=false;
      if(!closed&&!unhealthy)try{const delay=reconcileAgain?0:store.pending().length?tickMs:Math.max(0,Math.min(1000,store.nextDeadline()-store.now()));reconcileAgain=false;queueReconcile(delay);}catch(error){fail(error);}
    }
  }
  const heartbeat = setInterval(() => {
    if (!closed && !unhealthy) { try { store.beat(); } catch (error) { fail(error); } }
  }, Math.min(500, leaderMs / 3));
  queueReconcile(tickMs);
  let monitoring=false;
  const overseerTimer=setInterval(async()=>{if(closed||unhealthy||monitoring)return;monitoring=true;try{
    overseer.quiet();
    const rules=overseer.rules().filter(r=>r.enabled&&r.kind==='idle-resource');
    if(rules.length){
      const resources=[...(await host()).resources,...await managers.resources()];
      await Promise.all(rules.map(async rule=>{
        let resource=resources.find(r=>r.id===rule.resource||r.localId===rule.resource);
        const authority=rule.resource.includes('/')?rule.resource.split('/')[0]:store.authority;
        if(!resource&&authority!==store.authority)try{resource=(await collaboration.forward(authority,'resources',{},overseer.actor)).resources.find(r=>r.id===rule.resource);}catch{}
        const holder=resource?.holder;
        const localHolder=holder?.originActor?{...holder,actor:holder.originActor}:holder;
        let samples=[];try{samples=await Promise.all((rule.telemetryHosts??[store.authority]).map(h=>h===store.authority?telemetry.telemetry():collaboration.forward(h,'telemetry',{},overseer.actor)));}catch{}
        const known=samples.length===(rule.telemetryHosts?.length??1)&&samples.every(s=>!s.stale&&Number.isFinite(s.host?.gpu?.utilization)&&Number.isSafeInteger(s.sampledAt));
        overseer.resource(rule,{resource:rule.resource,holder:localHolder,utilization:known?Math.max(...samples.map(s=>s.host.gpu.utilization)):null,observedAt:known?Math.min(...samples.map(s=>s.sampledAt)):null,stale:!known});
      }));
    }
    overseer.dispatch();
  }catch{/* Keep ownership reconciliation independent of observation failures. */}finally{monitoring=false;}},10000);
  // A provider that no longer offers a resource says so; the resource leaves once idle.
  // The coordinator forgets it first, so no new claim can reach a driver being removed.
  let pruning=false;
  async function prune(){
    if(closed||unhealthy||pruning)return;pruning=true;
    try{awareness.expireStale();}catch{/* The next pass retries. */}
    try{
      const config=observationRuntime.lifecycle(),result=awareness.retirePass(config);
      // One notice per stale-holder episode per configured address; the send key
      // carries the claim generation so a crash between marking and sending is safe.
      for(const holder of result.stale)for(const to of config.notify??[])try{
        collaboration.send(overseer.actor,{key:`lifecycle.stale:${holder.claim}:${holder.generation}:${to}`,to,kind:'notification',
          text:`Accord lifecycle: session ${holder.session} is silent but still holds ${holder.resource} (claim ${holder.claim}, generation ${holder.generation}, deadline ${holder.deadline}). It is stale, not retired. Reserve only if needed.`});
      }catch{/* A notice is a hint. */}
    }catch{/* The next pass retries. */}
    try{store.ageOutCooperative();}catch{/* The next pass retries. */}
    try{
      const managed=store.db.prepare("SELECT id FROM resource_bindings WHERE plugin='managed-http'").all().map(r=>r.id);
      const installed=(await request(driverUrl,driverToken,'/control/resources')).resources.filter(r=>r.plugin==='managed-http').map(r=>r.id);
      for(const id of new Set([...managed,...installed])){
        if(closed)break;
        try{
          const status=await request(driverUrl,driverToken,driverPath('/control/status',id),undefined,2000);
          if(!status.withdrawn||status.claim_id||(store.binding(id)&&!store.removeResource(id)))continue;
          await request(driverUrl,driverToken,'/control/resources/withdraw',{id},5000);
        }catch{/* The next pass retries. */}
      }
    }catch{/* The next pass retries. */}finally{pruning=false;}
  }
  const pruneStart=setTimeout(prune,1000),pruneTimer=setInterval(prune,600000);
  const mailTimer=setInterval(()=>{if(!closed&&!unhealthy)void collaboration.flush().catch(()=>{});},1000);
  memory.start();
  function describe(actor, claimId) {
    const claim = store.owned(actor, claimId);
    return { ...claim, task: store.task(claim.task_id), driverUrl,
      ...(claim.state === 'running' && claim.deadline > store.now() ? { resourceToken: secretFor(claim) } : {}) };
  }
  async function readHost() {
    // Host discovery needs current ownership, not the entire retained journal.
    store.assertLeader();
    const board={paused:store.db.prepare("SELECT value FROM meta WHERE key='paused'").get().value==='true',
      claims:store.db.prepare("SELECT c.*,coalesce(p.label,s.label,c.actor) label,o.authority origin_authority,o.session_id origin_session FROM claims c LEFT JOIN participants p ON p.actor=c.actor LEFT JOIN sessions s ON s.id=c.actor LEFT JOIN remote_routes o ON o.actor=c.actor WHERE c.state!='closed'").all(),
      resources:store.db.prepare('SELECT r.id,b.instance,b.plugin,b.asset,b.enforcement,b.max_ownership_ms,b.allow_indefinite,p.pool FROM resources r LEFT JOIN resource_bindings b ON b.id=r.id LEFT JOIN resource_pools p ON p.resource=r.id ORDER BY r.id').all()};
    const held=new Map(board.claims.map(c=>[c.resource,c])),queues=new Map();
    const queued=store.db.prepare(`SELECT * FROM (SELECT r.id,r.actor,r.queued_until queuedUntil,t.title purpose,t.created_at queuedAt,t.resource,
      row_number() OVER(PARTITION BY t.resource ORDER BY t.created_at,t.rowid) position FROM tasks t JOIN reservations r ON r.task_id=t.id
      WHERE t.state='queued' AND r.pool IS NULL) WHERE position<=100 ORDER BY resource,position`).all();
    for(const {resource,position,...row} of queued){if(!queues.has(resource))queues.set(resource,[]);queues.get(resource).push(row);}
    const resources=await Promise.all(board.resources.map(async resource=>{
      let status,driverError;
      try {
        status=await request(driverUrl,driverToken,driverPath('/control/status',resource.id),undefined,600);
        requireThat(status.instance===(resource.id==='artifact'?driverInstance:resource.instance)&&(!status.authority||status.authority===store.authority),'DRIVER_REPLACED','Driver identity mismatch');
      }catch(error){driverError=error.code==='DRIVER_REPLACED'?error.code:'DRIVER_UNAVAILABLE';}
      const holder=held.get(resource.id),queue=queues.get(resource.id)??[];
      const orphan=holder&&store.db.prepare('SELECT orphaned_at,orphan_reason FROM reservations WHERE task_id=?').get(holder.task_id);
      return {id:`${store.authority}/${resource.id}`,localId:resource.id,...(resource.pool?{pool:resource.pool}:{}),plugin:resource.plugin??'artifact',asset:resource.asset??'builtin:artifact',
        label:status?.label??resource.id,maxOwnershipMs:resource.allow_indefinite?null:resource.max_ownership_ms??28800000,orphanGraceMs:resource.orphan_grace_ms??orphanGraceDefaultMs,...(resource.plugin==='cooperative'?{ageOutMs:resource.age_out_ms??cooperativeAgeOutDefaultMs}:{}),externalWorkloads:status?.externalWorkloads??null,hosts:status?.hosts??[],queue,state:!driverError&&!status?.blocked&&!holder&&!status.claim_id?(queue.length?'queued':'unclaimed'):holder?'held':'unknown',enforcement:resource.enforcement??'artifact-API',driver:driverError||'reachable',
        holder:holder?{claim:holder.id,actor:holder.actor,address:holder.origin_authority?`${holder.origin_authority}/${holder.origin_session}`:`${store.authority}/${holder.actor}`,label:holder.label,generation:holder.generation,state:holder.state,deadline:holder.deadline,task:holder.task_id,...(orphan?.orphaned_at!==null&&orphan?{orphaned:{since:orphan.orphaned_at,reason:orphan.orphan_reason,releaseAt:orphan.orphaned_at+(resource.orphan_grace_ms??orphanGraceDefaultMs)}}:{})}:null};
    }));
    store.assertLeader();
    return {protocol:'accord/1',authority:store.authority,name:hostName,epoch:store.epoch,observedAt:store.now(),paused:board.paused,pools:collaboration.pools(resources),
      resource:resources.find(r=>r.localId==='artifact'),resources,capabilities:['sessions','checkpoints','fenced-artifacts','peer-discovery','registered-processes','collaboration','messaging','reservations','host-telemetry','host-metadata','session-search','session-summaries','overseer','jobs','questions','resource-managers'],
      admission:'Availability is an observation. Only a successful claim grants ownership.'};
  }
  const host=singleFlight(readHost);
  const catalog=singleFlight(async()=>{
    const resources=[...(await host()).resources,...await managers.resources()],pools=collaboration.pools(resources);
    return {resources,capabilities:['reservation-windows-v1'],...(pools.length?{pools}:{})};
  });
  // Workload observations attach to the page a local client asked for — never
  // to /v1/federation, so a forwarded request cannot recurse the enrichment.
  const workloadTelemetry=new Map();
  let linkFileCache={at:0,rows:[]};
  function linkFiles(){
    if(store.now()-linkFileCache.at<10000)return linkFileCache.rows;
    let rows=[];
    try{rows=readdirSync(linksDir).filter(f=>f.endsWith('.json')).flatMap(f=>{try{const j=JSON.parse(readFileSync(join(linksDir,f),'utf8'));return typeof j.host==='string'&&typeof j.authority==='string'?[{host:j.host,authority:j.authority}]:[];}catch{return[];}});}catch{/* No link directory. */}
    linkFileCache={at:store.now(),rows};return rows;
  }
  const telemetryFlights=new Map();
  async function hostTelemetry(authority,actor){
    const hit=workloadTelemetry.get(authority);
    if(hit&&store.now()-hit.at<10000)return hit.value;
    let flight=telemetryFlights.get(authority);
    if(!flight){
      flight=(authority===store.authority?telemetry.telemetry():collaboration.forward(authority,'telemetry',{},actor))
        .then(value=>{workloadTelemetry.set(authority,{at:store.now(),value});return value;})
        .finally(()=>{if(telemetryFlights.get(authority)===flight)telemetryFlights.delete(authority);});
      telemetryFlights.set(authority,flight);
    }
    return flight;
  }
  async function observeWorkloads(resource,actor){
    const names=(resource.hosts??[]).map(String).filter(Boolean).slice(0,32),links=linkFiles();
    const resolve=name=>name===hostName?store.authority:links.find(l=>l.host===name)?.authority??null;
    // Resolve names first; descriptor-name matches are learned from telemetry.
    const wanted=new Map(names.map(n=>[n,resolve(n)]));
    const candidates=new Set([...wanted.values()].filter(Boolean));
    if([...wanted.values()].includes(null))for(const l of links)candidates.add(l.authority);
    const samples=new Map();
    await Promise.all([...candidates].map(async authority=>{
      try{samples.set(authority,await hostTelemetry(authority,actor));}catch{samples.set(authority,null);}
    }));
    // Reports may live on any fetched host; a node names the resource's host.
    const reports=[...samples.values()].filter(Boolean).flatMap(t=>(t.workloads?.reports??[]).map(r=>({...r,authority:t.authority})));
    // The reservation prefix derives from the authority that owns the claim,
    // which for a forwarded resource is the reporting host, not the caller.
    const resourceAuthority=String(resource.id??'').split('/')[0]||store.authority;
    return workloadView({wanted,samples,reports,holder:resource.holder,authority:resourceAuthority,now:store.now()});
  }
  async function attachWorkloads(payload,actor,operation){
    // Only the two read answers pay the telemetry cost; mutations stay cheap.
    if(operation!=='resources'&&operation!=='reservation')return payload;
    try{
      if(payload&&Array.isArray(payload.resources)){
        await Promise.all(payload.resources.map(async r=>{if(Array.isArray(r.hosts)&&r.hosts.length)r.workloads=await observeWorkloads(r,actor);}));
      }else if(payload&&typeof payload.resource==='string'&&!payload.workloads){
        const remote=payload.authority&&payload.authority!==store.authority;
        const list=remote?(await collaboration.forward(payload.authority,'resources',{},actor)).resources??[]:(await catalog()).resources;
        const match=list.find(r=>r.id===`${payload.authority??store.authority}/${payload.resource}`||r.localId===payload.resource);
        if(match&&Array.isArray(match.hosts)&&match.hosts.length)payload.workloads=await observeWorkloads(match,actor);
      }
    }catch{/* Observation failure never blocks the answer. */}
    return payload;
  }
  async function network() {
    const peers = store.db.prepare('SELECT * FROM peers ORDER BY authority').all();
    return Promise.all(peers.map(async peer => {
      const checkedAt = Date.now();
      try {
        const remote = await request(peer.url, peer.credential, '/v1/host', undefined, 1000);
        requireThat(remote.protocol === 'accord/1' && remote.authority === peer.authority && remote.resource?.id === `${peer.authority}/artifact`,
          'PEER_IDENTITY_CHANGED', 'Pinned host identity does not match');
        return {authority:peer.authority, endpoint:peer.url, status:'observed', checkedAt, host:remote};
      } catch (error) {
        return {authority:peer.authority, endpoint:peer.url, status:'unknown', checkedAt,
          reason:error.code === 'PEER_IDENTITY_CHANGED' ? error.code : 'PEER_UNAVAILABLE'};
      }
    }));
  }
  async function sessionsAcrossHosts(actor,args={}) {
    const local=awareness.list(args), hosts=[];
    const remote=await Promise.all(store.db.prepare('SELECT authority FROM links ORDER BY authority LIMIT 32').all().map(async peer=>{
      try { const result=await collaboration.forward(peer.authority,'sessions',args,actor);hosts.push({authority:peer.authority,status:'observed'});return result.sessions; }
      catch { hosts.push({authority:peer.authority,status:'unknown'});return []; }
    }));
    return {sessions:[...local.sessions,...remote.flat()].sort((a,b)=>b.progressAt-a.progressAt).slice(0,200),hosts};
  }
  async function memoriesAcrossHosts(actor,args={}) {
    const local=memory.list(args), hosts=[];
    const remote=await Promise.all(store.db.prepare('SELECT authority FROM links ORDER BY authority LIMIT 32').all().map(async peer=>{
      try { const result=await collaboration.forward(peer.authority,'memories',args,actor);hosts.push({authority:peer.authority,status:'observed'});
        return peerEntries(result,peer.authority); }
      catch { hosts.push({authority:peer.authority,status:'unknown'});return []; }
    }));
    return {entries:[...local.entries,...remote.flat()].sort((a,b)=>b.updated.localeCompare(a.updated)).slice(0,args.limit??10),hosts,sources:local.sources,lastScan:local.lastScan};
  }
  function nativeActor(view) {
    const binding=store.db.prepare('SELECT b.actor FROM session_bindings b JOIN sessions s ON s.id=b.actor WHERE b.source=? AND b.external_id=? AND s.closed_at IS NULL AND s.expires_at>?').get(view.source,view.external_id,store.now());
    return {id:binding?.actor??view.id,role:'worker'};
  }
  async function collaborate(actor,operation,args={},signal) {
    if(['telemetry','metadata','memory'].includes(operation))return telemetry[operation]();
    if(operation==='hosts')return {authority:store.authority,hosts:[{authority:store.authority,local:true},...store.db.prepare('SELECT authority FROM links ORDER BY authority').all().map(h=>({...h,local:false}))]};
    if(operation==='bridge-inbox'){requireThat(actor.role==='admin','FORBIDDEN','Host adapter required',403);text(args.source,'source',64);return {deliveries:store.db.prepare('SELECT id,source,external_id FROM session_views WHERE source=? AND private=0 AND hidden=0 ORDER BY observed_at DESC LIMIT 200').all(args.source).flatMap(s=>collaboration.inbox(nativeActor(s)).messages.slice(0,10).map(m=>({...m,session:s.id,externalId:s.external_id}))).slice(0,100)};}
    if(operation==='bridge-renames'){requireThat(actor.role==='admin','FORBIDDEN','Host adapter required',403);text(args.source,'source',64);const now=store.now();store.mutate(()=>store.db.prepare("UPDATE rename_requests SET state='failed',reason='expired',updated_at=? WHERE state='pending' AND created_at<?").run(now,now-86400000));return {renames:store.db.prepare('SELECT id,session,tile,title,by,created_at FROM rename_requests WHERE state=\'pending\' AND source=? ORDER BY created_at DESC LIMIT 50').all(args.source)};}
    if(operation==='bridge-rename-result'){requireThat(actor.role==='admin','FORBIDDEN','Host adapter required',403);text(args.id,'id',128);requireThat(['accepted','failed'].includes(args.outcome),'INVALID_INPUT','outcome must be accepted or failed',400);return store.mutate(()=>{const row=store.db.prepare('SELECT * FROM rename_requests WHERE id=?').get(args.id);requireThat(row&&row.state==='pending','NOT_FOUND','Unknown pending rename request',404);store.db.prepare('UPDATE rename_requests SET state=?,reason=?,updated_at=? WHERE id=?').run(args.outcome,args.reason??null,store.now(),row.id);store.emit(`session.rename-${args.outcome}`,{request:row.id,session:row.session,tile:row.tile,title:row.title,reason:args.reason??null});return {id:row.id,state:args.outcome};});}
    if(operation==='manager-configure')return managers.configure(actor,args);
    if(operation==='manager-schedules'){requireThat(actor.role==='admin','FORBIDDEN','Operator required',403);return managers.schedules();}
    if(operation==='summary-configure')return observationRuntime.configureSummary(actor,args);
    if(operation==='session-bind')return awareness.bind(actor,args);
    if(operation==='session-link-tile')return awareness.linkTile(actor,args);
    if(operation==='overseer-designate')return awareness.designate(actor,args);
    if(operation==='lifecycle-retire')return awareness.retire(actor,args);
    if(operation==='lifecycle-sweep')return awareness.sweep(actor,args);
    if(['context-inbox','context-wait'].includes(operation)) {
      requireThat(actor.role==='admin','FORBIDDEN','Trusted local hook required',403);attention.key(args);
      if(operation==='context-wait')return attention.wake(args,signal);
      if(args.actor)awareness.bind(actor,{key:'hook-bind:'+hash(JSON.stringify([args.source,args.externalId,args.actor])),source:args.source,externalId:args.externalId,actor:args.actor});
      return attention.present(args);
    }

    if(operation==='source-privacy')return awareness.privacy(actor,args);
    if(operation==='question-dismiss')return awareness.dismiss(actor,args);
    if(operation==='session-report')return awareness.report(actor,args);
    if(operation==='workload-report')return hostWorkloads.report(actor,args);
    if(operation==='heartbeat')return awareness.heartbeat(actor);
    if(operation==='sessions')return awareness.list(args);
    if(operation==='session-read')return awareness.read(args.id,args);
    if(operation==='memories')return memory.list(args);
    if(operation==='memory-read')return memory.read(args.id);
    if(operation==='session-snooze')return awareness.snooze(actor,args);
    if(operation==='session-title')return awareness.title(actor,args);
    if(operation==='jobs')return awareness.jobs();
    if(operation==='job')return awareness.job(actor,args);
    if(operation==='ask')return awareness.ask(actor,args);
    if(operation==='answer')return awareness.answer(actor,args);
    if(operation==='question')return awareness.question(actor,args.id);
    if(operation==='overseer')return {rules:overseer.rules(),overseer:awareness.overseerAddress(),...overseer.incidents()};
    if(operation==='overseer-rule')return overseer.configure(actor,args);
    if(operation==='overseer-signal')return overseer.signal(actor,args);
    if(operation==='announce'){const result=collaboration.announce(actor,args);awareness.announce(actor,args);return result;}
    if(operation==='find'){
      const [result,local]=await Promise.all([collaboration.find(args.query??'',args.local!==true,collaboration.address(actor),{includeRetired:args.includeRetired===true}),catalog()]);
      result.hosts[0].resources=local.resources;
      return args.detail===true?result:compactFind(result,args.query??'');
    }
    if(operation==='schedule')return schedules.create(actor,args);
    if(operation==='schedules')return schedules.list(actor,{all:args.all===true});
    if(operation==='schedule-cancel')return schedules.cancel(actor,args);
    if(operation==='topic-publish')return schedules.publish(actor,args);
    if(operation==='send'){const r=collaboration.send(actor,args);void collaboration.flush().catch(()=>{});return collaboration.sent(actor,r.id);}
    if(operation==='inbox'){
      integer(args.waitMs??0,'waitMs',0,3600000);
      if(args.waitMs)await attention.wait(()=>collaboration.pendingCount(actor)>0||null,args.waitMs,signal,actor.id);
      return args.limit!==undefined||args.cursor!==undefined?collaboration.inboxPage(actor,args):collaboration.inbox(actor,{all:args.all===true});
    }
    if(operation==='notify')return collaboration.notify(actor,args);
    if(operation==='read')return collaboration.read(actor,args);
    if(operation==='sent')return collaboration.sent(actor,args.id);
    if(operation==='capabilities')return {capabilities:['reservation-windows-v1']};
    if(operation==='resources')return catalog();
    if(operation==='reserve'&&!store.db.prepare('SELECT 1 FROM session_views WHERE id=?').get(actor.id))awareness.report(actor,{key:'reservation-session-view',title:actor.session?.label??'Resource holder',state:'working'});
    if(operation==='reserve'&&managers.owns(args.resource))return managers.reserve(actor,args);
    if(['reservation','release','renew'].includes(operation)&&store.db.prepare('SELECT 1 FROM manager_requests WHERE id=?').get(args.id)){if(operation==='reservation')return managers.status(actor,args.id);if(operation==='release')return managers.release(actor,args);return managers.renew(actor,args);}
    if(operation==='reserve'){const r=collaboration.reserve(actor,args);void reconcile();return collaboration.reservation(actor,r.id);}
    if(operation==='reservation')return collaboration.reservation(actor,args.id);
    if(operation==='release'){const r=collaboration.release(actor,args.id,args);void reconcile();return r;}
    if(['renew','start','process','workload-register','workload-launch','workload-list'].includes(operation)){
      const r=collaboration.reservation(actor,args.id);
      requireThat(r.claimId,'NOT_RUNNING','Reservation has not acquired the resource');
      if(operation==='renew')return store.renew(actor,r.claimId,args);
      const claim=store.owned(actor,r.claimId,true);
      requireThat(claim.resource!=='artifact','WRONG_DRIVER','This is not a process resource');
      if(operation.startsWith('workload-'))return request(driverUrl,secretFor(claim),driverPath(operation==='workload-launch'?'/v1/workloads/start':'/v1/workloads',claim.resource),operation==='workload-list'?undefined:{key:args.key,targets:args.targets,workload:args.workload},30000);
      return request(driverUrl,secretFor(claim),driverPath('/v1/processes',claim.resource),operation==='start'?{key:args.key}:undefined);
    }
    requireThat(false,'UNKNOWN_OPERATION','Unknown collaboration operation',400);
  }
  const html = readFileSync(new URL('./ui.html', import.meta.url));
  const server = createHttp(async (req, res, url) => {
    let responseActor;
    const handle=async()=>{
    if (url.pathname === '/' && req.method === 'GET') {
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'");
      res.end(html); return;
    }
    if (req.method === 'GET' && ['/ui.js','/ui.css'].includes(url.pathname)) {
      res.setHeader('Content-Type', url.pathname.endsWith('.js') ? 'text/javascript' : 'text/css');
      res.end(readFileSync(new URL(`.${url.pathname}`, import.meta.url))); return;
    }
    requireThat(!unhealthy && !closed, 'UNAVAILABLE', 'Coordinator cannot acknowledge durable work', 503);
    store.assertLeader();
    if (url.pathname === '/.well-known/accord' && req.method === 'GET') return {protocol:'accord/1', authority:store.authority, ...collaboration.linkProof(url.searchParams)};
    const credential = bearer(req);
    if (url.pathname === '/v1/sessions' && req.method === 'POST') {
      const enroller = store.purpose(credential, 'enroll');
      const body = await readBody(req);
      requireThat(body.authority === store.authority, 'AUTHORITY_MISMATCH', 'Session enrollment must name this authority', 409);
      const session = store.openSession(enroller, body, sessionSecret);
      const sessionToken = sessionSecret(session.sessionId);
      const current=store.authenticate(sessionToken).session; // Explicit closure is never undone by replay.
      return {...session, expiresAt:current.persistent?null:current.expires_at,persistent:Boolean(current.persistent),credential:sessionToken};
    }
    if (url.pathname === '/v1/host' && req.method === 'GET') {
      try { responseActor=store.authenticate(credential); } catch { store.purpose(credential, 'discover'); }
      return host();
    }
    const telemetryRoute=/^\/v1\/(?:host|hosts\/([^/]+))\/(telemetry|metadata|memory)$/.exec(url.pathname);
    if(telemetryRoute&&req.method==='GET'){
      let reader;try{reader=responseActor=store.authenticate(credential);}catch{store.purpose(credential,'discover');reader={id:'telemetry-reader'};}
      const [,target,kind]=telemetryRoute;
      return target&&target!==store.authority?collaboration.forward(target,kind,{},reader):telemetry[kind]();
    }
    if(url.pathname==='/v1/federation'&&req.method==='POST'){
      const peer=collaboration.peer(credential),body=await readBody(req);
      // Observations must not provision proxy actors or write coordination state.
      if(['telemetry','metadata','memory'].includes(body.operation))return {authority:store.authority,value:await telemetry[body.operation]()};
      if(['sessions','session-read','jobs','overseer','memories','memory-read'].includes(body.operation)){
        requireThat(peer.share_sessions,'NOT_SHARED','This host does not share session activity with this link',403);
        return {authority:store.authority,value:await collaborate(null,body.operation,body.args)};
      }
      if(body.operation==='lifecycle'){
        // Link-credential only, like deliver: the peer speaks for its own
        // sessions, mapped to this host's proxy actors through remote_routes.
        const result=collaboration.lifecycleNotice(peer,body.args);
        store.assertLeader();return {authority:store.authority,value:{applied:result.applied}};
      }
      const actor=collaboration.remoteActor(peer,body.actor,body.identity);
      let value;
      if(body.operation==='directory')value={participants:collaboration.directory(body.args?.query??''),resources:[...(await host()).resources,...await managers.resources()]};
      else if(body.operation==='deliver'){
        requireThat(body.args?.from===`${peer.authority}/${body.actor}`,'FORBIDDEN','Sender does not match linked host',403);
        requireThat(body.args?.scheduledBy===undefined||String(body.args.scheduledBy).split('/')[0]===peer.authority,'FORBIDDEN','scheduledBy does not match linked host',403);
        value=collaboration.deliver(body.args);
      }else{
        requireThat(['capabilities','resources','reserve','reservation','release','renew','start','process','workload-register','workload-launch','workload-list','telemetry','metadata','sessions','session-read','jobs','job','overseer','session-snooze','memories','memory-read','schedule','schedules','schedule-cancel'].includes(body.operation),'FORBIDDEN','Operation cannot be forwarded',403);
        value=await collaborate(actor,body.operation,body.args);
      }
      store.assertLeader();return {authority:store.authority,value};
    }
    const actor = store.authenticate(credential);
    responseActor=actor;
    if(url.pathname==='/v1/awareness'&&req.method==='GET')return {authority:store.authority,adapters:observationRuntime.status(),...await sessionsAcrossHosts(actor,{query:url.searchParams.get('query')??''}),...awareness.jobs(),...overseer.incidents(),questions:actor.role==='admin'?store.db.prepare("SELECT id,actor,question,options,created_at FROM human_questions WHERE state='pending'").all():[]};
    if(url.pathname==='/v1/links'&&req.method==='POST')return collaboration.addLink(actor,await readBody(req));
    if(url.pathname==='/v1/links/share'&&req.method==='POST')return collaboration.shareSessions(actor,await readBody(req));
    if(url.pathname==='/v1/links/remove'&&req.method==='POST'){
      requireThat(actor.role==='admin','FORBIDDEN','Administrator required',403);
      const body=await readBody(req);return store.command(actor,body,'link.remove',()=>{store.db.prepare('DELETE FROM links WHERE authority=?').run(body.authority);return {removed:body.authority};});
    }
    if(url.pathname==='/v1/collaboration'&&req.method==='POST'){
      const body=await readBody(req);
      if(body.host&&body.host!==store.authority){
        requireThat(['capabilities','resources','reserve','reservation','release','renew','start','process','workload-register','workload-launch','workload-list','telemetry','metadata','sessions','session-read','jobs','job','overseer','session-snooze','memories','memory-read','schedule','schedules','schedule-cancel'].includes(body.operation),'FORBIDDEN','Operation cannot be forwarded',403);
        return attachWorkloads(await collaboration.forward(body.host,body.operation,body.args,actor),actor,body.operation);
      }
      if(body.operation==='sessions'&&!body.host)return sessionsAcrossHosts(actor,body.args);
      if(body.operation==='memories'&&!body.host)return memoriesAcrossHosts(actor,body.args);
      const gone=new AbortController();res.once('close',()=>gone.abort());
      return attachWorkloads(await collaborate(actor,body.operation,body.args,gone.signal),actor,body.operation);
    }
    if (url.pathname === '/v1/bootstrap' && req.method === 'GET') {
      if(!store.db.prepare('SELECT actor FROM participants WHERE actor=?').get(actor.id))collaboration.announce(actor,{key:'bootstrap-registration',label:actor.session?.label??actor.id,capabilities:[],activity:'available'});
      const [local,peers,directory]=await Promise.all([host(),network(),collaboration.find('',true,collaboration.address(actor))]);
      store.authenticate(credential);
      return bootstrapView({actor,local,peers,directory,inbox:collaboration.inbox(actor),learnings:memory.learnings()});
    }
    if (url.pathname === '/v1/network' && req.method === 'GET') return {hosts:[{status:'observed',host:await host()},...await network()]};
    if(url.pathname==='/v1/plugins'&&req.method==='GET')return {plugins};
    if(url.pathname==='/v1/resources'&&req.method==='GET')return attachWorkloads(await catalog(),actor,'resources');
    if(url.pathname==='/v1/workloads/adopt'&&req.method==='POST'){
      requireThat(actor.role==='admin','FORBIDDEN','Operator adoption requires administrator authority',403);
      const body=await readBody(req),claim=store.db.prepare('SELECT * FROM claims WHERE id=?').get(body.claimId);
      requireThat(claim&&['running','revoking'].includes(claim.state)&&body.generation===claim.generation&&body.authority===store.authority,'STALE_GRANT','Name the exact held claim, generation and authority');
      const result=await request(driverUrl,driverToken,driverPath('/control/workloads',claim.resource),{...grant(claim),key:body.key,targets:body.targets},30000);
      store.assertLeader();return result;
    }
    if(url.pathname==='/v1/resources/remove'&&req.method==='POST'){
      requireThat(actor.role==='admin','FORBIDDEN','Administrator required',403);
      const {id}=await readBody(req);text(id,'id',64);requireThat(id!=='artifact','INVALID_INPUT','The artifact resource is built in',400);
      // As with a withdrawal, the coordinator forgets it first; a retry finishes the driver.
      if(store.binding(id))requireThat(store.removeResource(id),'RESOURCE_BUSY','Release or cancel every reservation on this resource first',409);
      else if(!(await request(driverUrl,driverToken,'/control/resources')).resources.some(r=>r.id===id))return {id,removed:false};
      return request(driverUrl,driverToken,'/control/resources/withdraw',{id,requested:true},5000);
    }
    if(url.pathname==='/v1/resources'&&req.method==='POST'){
      requireThat(actor.role==='admin','FORBIDDEN','Administrator required',403);
      const body=await readBody(req);text(body.key,'key',128);
      const register=async(manifest,key,pool)=>{
        validateResource(manifest);
        const entry={key,manifest,...(pool?{pool}:{})};
        if(store.db.prepare('SELECT 1 FROM commands WHERE actor=? AND key=?').get(actor.id,key))return store.registerResource(actor,entry,{});
        return store.registerResource(actor,entry,await request(driverUrl,driverToken,'/control/resources',manifest));
      };
      const {capacity,...manifest}=body.manifest??{};
      if(capacity===undefined)return register(manifest,body.key);
      // A pool is ordinary single-holder resources, so fencing and recovery stay per slot.
      // A provider has one workload per registration and no slot identity, so one holder's
      // release would stop and restore under another. It must offer distinct resources.
      requireThat(manifest.plugin!=='managed-http','INVALID_INPUT','Managed providers cannot be pooled',400);
      integer(capacity,'capacity',2,32);
      const existing=collaboration.slots(manifest.id),names=Array.from({length:capacity},(_,i)=>`${manifest.id}-${i}`);
      requireThat(!store.db.prepare('SELECT 1 FROM resources WHERE id=?').get(manifest.id),'RESOURCE_CONFLICT','A resource already uses this name');
      requireThat(existing.length<=capacity,'RESOURCE_CONFLICT','A pool cannot shrink');
      // Refuse before the first slot, so a bad request leaves nothing half registered.
      requireThat(!names.some(name=>!existing.includes(name)&&store.db.prepare('SELECT 1 FROM resources WHERE id=?').get(name)),'RESOURCE_CONFLICT','A slot name is already in use');
      requireThat(store.db.prepare('SELECT count(*) n FROM resources').get().n+capacity-existing.length<=64,'CAPACITY_LIMIT','At most 64 registered resources');
      const slots=[];// A retry after a failure completes the missing slots.
      for(const [i,id] of names.entries())slots.push(await register({...manifest,id,asset:`${manifest.asset}#${i}`},`pool:${id}`,manifest.id));
      return {pool:manifest.id,slots};
    }
    if (url.pathname === '/v1/peers' && req.method === 'POST') {
      requireThat(actor.role === 'admin', 'FORBIDDEN', 'Administrator required', 403);
      const body = await readBody(req); text(body.authority, 'authority', 100); text(body.credential, 'credential', 200);
      body.url = loopbackUrl(body.url);
      const remote = await request(body.url, body.credential, '/v1/host');
      requireThat(remote.protocol === 'accord/1' && remote.authority === body.authority, 'PEER_IDENTITY_CHANGED', 'Pinned authority does not match');
      return store.addPeer(actor, body);
    }
    if (url.pathname === '/v1/peers/remove' && req.method === 'POST') return store.removePeer(actor, await readBody(req));
    const sessionClose = /^\/v1\/sessions\/([a-f0-9-]+)\/close$/.exec(url.pathname);
    if (sessionClose && req.method === 'POST') {
      const result = store.endSession(actor, sessionClose[1], await readBody(req)); void reconcile(); return result;
    }
    if (url.pathname === '/v1/me' && req.method === 'GET') return actor;
    if (url.pathname === '/health' && req.method === 'GET') return { status: 'ready', epoch: store.epoch };
    if (url.pathname === '/v1/board' && req.method === 'GET') {
      const after = integer(Number(url.searchParams.get('after') || 0), 'after', 0, Number.MAX_SAFE_INTEGER);
      return store.board(after,{active:url.searchParams.get('active')==='true',...(url.searchParams.has('limit')?{limit:Number(url.searchParams.get('limit'))}:{}),...(url.searchParams.has('before')?{before:Number(url.searchParams.get('before'))}:{})});
    }
    if (url.pathname === '/v1/tasks' && req.method === 'POST') return store.submit(actor, await readBody(req));
    if (url.pathname === '/v1/claim' && req.method === 'POST') {
      const { claimId } = store.acquire(actor, await readBody(req));
      void reconcile(); return describe(actor, claimId);
    }
    if (url.pathname === '/v1/steer' && req.method === 'POST') return store.steer(actor, await readBody(req));
    const cancellation = /^\/v1\/tasks\/([a-f0-9-]+)\/cancel$/.exec(url.pathname);
    if (cancellation && req.method === 'POST') {
      const result = store.cancel(actor, cancellation[1], await readBody(req)); void reconcile(); return result;
    }
    const match = /^\/v1\/claims\/([a-f0-9-]+)(?:\/(checkpoint|finish|renew))?$/.exec(url.pathname);
    if (match && req.method === 'GET' && !match[2]) return describe(actor, match[1]);
    if (match && req.method === 'POST' && match[2] === 'checkpoint') return store.checkpoint(actor, match[1], await readBody(req));
    if (match && req.method === 'POST' && match[2] === 'renew') return store.renew(actor, match[1], await readBody(req));
    const write = /^\/v1\/claims\/([a-f0-9-]+)\/artifact$/.exec(url.pathname);
    if (write && req.method === 'POST') {
      const body = await readBody(req);
      store.authenticate(credential); const claim = store.owned(actor, write[1], true);
      requireThat(claim.resource==='artifact','WRONG_DRIVER','Use the process driver for this resource');
      return request(driverUrl, secretFor(claim), '/v1/artifacts', body);
    }
    const processRoute=/^\/v1\/claims\/([a-f0-9-]+)\/process$/.exec(url.pathname);
    if(processRoute&&['GET','POST'].includes(req.method)){
      const body=req.method==='POST'?await readBody(req):undefined;
      store.authenticate(credential);const claim=store.owned(actor,processRoute[1],true);
      requireThat(claim.resource!=='artifact','WRONG_DRIVER','Use the artifact operation for this resource');
      return request(driverUrl,secretFor(claim),driverPath('/v1/processes',claim.resource),body);
    }
    if (match && req.method === 'POST' && match[2] === 'finish') {
      const body = await readBody(req);
      // Validate ownership before accessing receipts, including on repeated requests.
      store.owned(actor, match[1]);
      const prior = store.db.prepare('SELECT * FROM commands WHERE actor=? AND key=?').get(actor.id, body.key || '');
      if (prior) return store.finish(actor, match[1], body, {}); // command dedup checks payload before invoking callback
      store.owned(actor, match[1], true);
      requireThat(typeof body.receiptId === 'string' && /^[a-f0-9-]+$/.test(body.receiptId), 'INVALID_INPUT', 'receiptId required', 400);
      const receipt = await request(driverUrl, driverToken, driverPath(`/control/receipts/${body.receiptId}`,store.claim(match[1]).resource));
      const result = store.finish(actor, match[1], body, receipt);
      void reconcile(); return result;
    }
    requireThat(false, 'NOT_FOUND', 'Unknown route', 404);
    };
    const pending=()=>{try{return collaboration.pendingCount(responseActor);}catch{return 'unknown';}};
    const deliveryProblems=()=>collaboration.deliveryProblems(responseActor);
    let result;
    try{result=await handle();}catch(error){if(responseActor?.role==='worker'){error.inboxPending=pending();error.deliveryProblems=deliveryProblems();}throw error;}
    // One indexed local count, no extra client request, no body duplication.
    // Discovery, federation and operator views never inherit another actor's mail.
    if(responseActor?.role==='worker'&&result&&typeof result==='object') {
      const inboxPending=pending();
      const problems=deliveryProblems();
      if(inboxPending||problems)return {...result,...(inboxPending?{inboxPending}:{}),...(problems?{deliveryProblems:problems}:{})};
    }
    return result;
  });
  return {
    server, store, reconcile, failed,
    async close() {
      closed = true; attention.close(); await observationRuntime.close();clearInterval(timer); clearInterval(heartbeat);clearInterval(mailTimer);clearInterval(overseerTimer);clearTimeout(pruneStart);clearInterval(pruneTimer);memory.close();
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      while (busy||claimFlights.size||collaboration.sending||monitoring||pruning||managers.busy) await new Promise(resolve => setTimeout(resolve, 10));
      collaboration.close();try { store.releaseLeadership(); } finally { store.close(); }
    }
  };
}
