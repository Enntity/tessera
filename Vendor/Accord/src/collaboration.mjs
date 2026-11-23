// SPDX-License-Identifier: MIT
// Tessera's board/send/inbox conventions, with Messenger's durable delivery store.
import { splitDiscovery, discoveryGuidance } from './discovery-view.mjs';
import { dirname, join } from 'node:path';
import { redact } from './session-awareness.mjs';
import { MessengerStore } from '../vendor/messenger/store.js';
import { createHmac,randomBytes } from 'node:crypto';
import { hash, id, token, text, integer, requireThat, loopbackUrl, request } from './common.mjs';
import { windowDuration } from './reservation-policy.mjs';
import { orphanGraceDefaultMs, orphanClaims, orphaningReasons } from './lifecycle.mjs';

const linkProof=(key,authority,nonce)=>createHmac('sha256',key).update(`accord-link-v1\0${authority}\0${nonce}`).digest('hex');

const pendingDelivery=`d.recipient_id=? AND (d.available_at IS NULL OR d.available_at<=?)
  AND (d.state='pending' OR (d.state IN ('offered','read') AND d.lease_expires_at<=?))`;
export class Collaboration {
  constructor(store, file) {
    this.store=store; this.db=store.db;
    this.messages=new MessengerStore(join(dirname(file),'messages.sqlite'),{leaseMs:1000});
    this.sending=false;
  }
  close(){this.messages.close();}
  address(actor){return `${this.store.authority}/${actor.id}`;}
  principal(address) {
    const handle='a'+hash(address).slice(0,60);
    return this.messages.principalByHandle(handle) ?? this.messages.createPrincipal({handle,displayName:address.slice(0,120)}).principal;
  }
  announce(actor,body) {
    return this.store.command(actor,body,'announce',()=>{
      text(body.label,'label',120);text(body.activity??'available','activity',1000);
      requireThat(Array.isArray(body.capabilities??[])&&(body.capabilities??[]).length<=20,'INVALID_INPUT','Use at most 20 capabilities',400);
      for(const c of body.capabilities??[])text(c,'capability',80);
      requireThat(typeof (body.location??'')==='string'&&(body.location??'').length<=500,'INVALID_INPUT','location must be <=500 characters',400);
      this.db.prepare('INSERT INTO participants VALUES(?,?,?,?,?,?) ON CONFLICT(actor) DO UPDATE SET label=excluded.label,capabilities=excluded.capabilities,activity=excluded.activity,location=excluded.location,updated_at=excluded.updated_at')
        .run(actor.id,body.label,JSON.stringify(body.capabilities??[]),body.activity??'available',body.location??'',this.store.now());
      this.store.emit('participant.updated',{actor:actor.id});
      return {address:this.address(actor)};
    });
  }
  directory(query='',{includeRetired=false}={}) {
    requireThat(typeof query==='string'&&query.length<=200,'INVALID_INPUT','Search must be <=200 characters',400);
    const found=[];
    const needle=query.toLowerCase();
    const sql=`SELECT p.*,s.harness,s.client,s.expires_at,s.closed_at,v.source,v.external_id,v.private,v.state observed_state,v.progress_at,b.actor binding_actor FROM participants p
      LEFT JOIN sessions s ON s.id=p.actor LEFT JOIN session_views v ON v.id=p.actor
      LEFT JOIN session_bindings b ON b.source=v.source AND b.external_id=v.external_id AND v.private=0
      WHERE NOT EXISTS (SELECT 1 FROM remote_routes r WHERE r.actor=p.actor)
      AND NOT EXISTS (SELECT 1 FROM session_views hidden WHERE hidden.id=p.actor AND hidden.hidden=1)
      ${includeRetired?'':'AND v.retired_at IS NULL AND (s.id IS NULL OR s.retired_at IS NULL)'}`;
    // Preserve participant-before-observation ordering without sorting the entire
    // retained directory before yielding its first row.
    function* ordered(db){
      for(const predicate of ["(v.source IS NULL OR v.source='agent')","v.source IS NOT NULL AND v.source!='agent'"])
        yield* db.prepare(sql+' AND '+predicate+' ORDER BY p.updated_at DESC').iterate();
    }
    const rows=ordered(this.db);
    for(const p of rows){
      const native=['codex','claude','tessera'].includes(p.source),lastSeen=native?p.progress_at:p.updated_at;
      const ended=p.closed_at!==null||(p.expires_at!==null&&p.expires_at<=this.store.now())||native&&['done','failed','exited','cancelled'].includes(p.observed_state);
      const observed=p.source && p.source!=='agent';
      const binding=observed&&!p.private&&p.binding_actor?{actor:p.binding_actor}:null;
      const value={kind:observed?'observation':p.harness?'participant':'service',source:p.source??'agent',state:p.observed_state??'unknown',
        ...(observed?{externalId:p.private?null:p.external_id}:{}),...(binding?{participantAddress:this.store.authority+'/'+binding.actor}:{}),address:`${this.store.authority}/${p.actor}`,label:p.label,capabilities:JSON.parse(p.capabilities),activity:p.activity,location:p.location,harness:p.harness??'service',lastSeen,
        ...(observed?{}:{agent:this.agentRecord?.(p.actor)}),
        presence:ended?'offline':native&&p.observed_state==='unknown'||this.store.now()-lastSeen>120000?'unknown':'recent'};
      if(JSON.stringify(value).toLowerCase().includes(needle))found.push(value);
      if(found.length===200)break;
    }
    return found;
  }
  addLink(actor,body) {
    requireThat(actor.role==='admin','FORBIDDEN','Administrator required',403);
    return this.store.command(actor,body,'link',()=>{
      text(body.authority,'authority',100);text(body.outbound,'outbound',200);text(body.inbound,'inbound',200);
      requireThat(body.authority!==this.store.authority,'SELF_PEER','Cannot link to self');
      const url=loopbackUrl(body.url),old=this.db.prepare('SELECT * FROM links WHERE authority=?').get(body.authority);
      requireThat(old||this.db.prepare('SELECT count(*) n FROM links').get().n<32,'CAPACITY_LIMIT','At most 32 links');
      requireThat(!old||(old.url===url&&old.outbound===body.outbound&&old.inbound_hash===hash(body.inbound)),'LINK_CONFLICT','Remove an existing link before changing its identity or credentials');
      this.db.prepare('INSERT OR IGNORE INTO links(authority,url,outbound,inbound_hash) VALUES(?,?,?,?)').run(body.authority,url,body.outbound,hash(body.inbound));
      this.store.emit('host.linked',{authority:body.authority,url});return {authority:body.authority,url};
    });
  }
  shareSessions(actor,body) {
    requireThat(actor.role==='admin','FORBIDDEN','Administrator required',403);
    return this.store.command(actor,body,'link.share',()=>{
      requireThat(typeof body.share==='boolean','INVALID_INPUT','Choose whether to share',400);
      requireThat(this.db.prepare('UPDATE links SET share_sessions=? WHERE authority=?').run(body.share?1:0,String(body.authority)).changes,'HOST_UNKNOWN','Host is not linked',404);
      this.store.emit('host.sharing',{authority:body.authority,share:body.share});return {authority:body.authority,share:body.share};
    });
  }
  // Both ends hold the hash of this direction's token, so a reply proves the link without
  // revealing it. Whatever holds the tunnel port without that hash never sees the token.
  linkProof(params) {
    const nonce=params.get('nonce'),link=this.db.prepare('SELECT inbound_hash FROM links WHERE authority=?').get(params.get('from')??'');
    return link&&nonce?.length===64?{proof:linkProof(link.inbound_hash,this.store.authority,nonce)}:{};
  }
  peer(credential) {
    const peer=this.db.prepare('SELECT * FROM links WHERE inbound_hash=?').get(hash(credential));
    requireThat(peer,'FORBIDDEN','Unknown host link',403);return peer;
  }
  async forward(authority,operation,args,actor) {
    const link=this.db.prepare('SELECT * FROM links WHERE authority=?').get(authority);
    requireThat(link,'HOST_UNKNOWN','Host is not linked',404);
    const nonce=randomBytes(32).toString('hex');
    const descriptor=await request(link.url,'',`/.well-known/accord?from=${encodeURIComponent(this.store.authority)}&nonce=${nonce}`,undefined,700);
    requireThat(descriptor.authority===authority&&descriptor.proof===linkProof(hash(link.outbound),authority,nonce),'PEER_IDENTITY_CHANGED','Linked host identity changed');
    const result=await request(link.url,link.outbound,'/v1/federation',{operation,args,actor:actor.id,identity:this.db.prepare('SELECT label FROM participants WHERE actor=?').get(actor.id)??this.db.prepare('SELECT label FROM sessions WHERE id=?').get(actor.id)},operation.startsWith('workload-')?30000:['telemetry','metadata'].includes(operation)?3500:undefined);
    requireThat(result.authority===authority,'PEER_IDENTITY_CHANGED','Linked host identity changed');
    if(operation==='resources'&&Array.isArray(result.value?.resources))return {...result.value,resources:result.value.resources.map(r=>({...r,holder:this.localHolder(r.holder)}))};
    return result.value;
  }
  localHolder(holder) {
    if(!holder?.actor?.startsWith('remote-'))return holder;
    // Reverse only our own authenticated origin's deterministic proxy identity.
    // Works with older peers too; directory text alone never establishes ownership.
    for(const row of this.db.prepare('SELECT p.actor,p.label FROM participants p WHERE NOT EXISTS (SELECT 1 FROM remote_routes r WHERE r.actor=p.actor)').iterate()) {
      if(holder.actor===`remote-${hash(this.store.authority+'/'+row.actor)}`)
        return {...holder,originActor:row.actor,address:`${this.store.authority}/${row.actor}`,label:row.label};
    }
    return holder;
  }
  remoteActor(peer,actorId,identity) {
    requireThat(typeof actorId==='string'&&/^[a-zA-Z0-9_-]{1,100}$/.test(actorId),'INVALID_INPUT','Invalid remote session',400);
    const actor={id:`remote-${hash(peer.authority+'/'+actorId)}`,role:'worker'};
    if(identity!==undefined){requireThat(identity&&typeof identity==='object','INVALID_INPUT','Invalid remote identity',400);text(identity.label,'remote label',120);}
    this.store.mutate(()=>{
      if(!this.db.prepare('SELECT id FROM actors WHERE id=?').get(actor.id))this.store.provision(actor.id,token(),'worker');
      this.db.prepare('INSERT OR IGNORE INTO remote_routes(actor,authority,session_id) VALUES(?,?,?)').run(actor.id,peer.authority,actorId);
      // The authenticated origin supplies display metadata; it grants no authority.
      if(identity)this.db.prepare("INSERT INTO participants VALUES(?,?,'[]','','',?) ON CONFLICT(actor) DO UPDATE SET label=excluded.label").run(actor.id,redact(identity.label),this.store.now());
    });
    return actor;
  }
  async find(query='',network=true,selfAddress,args={}) {
    const hosts=[{authority:this.store.authority,status:'observed',participants:this.directory(query,{includeRetired:args.includeRetired===true})}];
    if(network)hosts.push(...await Promise.all(this.db.prepare('SELECT authority FROM links').all().map(async p=>{
      // A link speaks only for its own host, however it describes itself.
      try{const {participants,observations,resources}=await this.forward(p.authority,'directory',{query},{id:'directory'}),own=r=>String(r.address??r.id).startsWith(p.authority+'/');
        return {authority:p.authority,status:'observed',participants:(participants??[]).filter(own),observations:(observations??[]).filter(own),resources:(resources??[]).filter(own)};}
      catch(e){return {authority:p.authority,status:'unknown',reason:e.code??'HOST_UNAVAILABLE',participants:[]};}
    })));
    for(const host of hosts)Object.assign(host,splitDiscovery([...(host.participants??[]),...(host.observations??[])],selfAddress));
    return {hosts,participants:hosts.flatMap(h=>h.participants),observations:hosts.flatMap(h=>h.observations),guidance:discoveryGuidance};
  }
  // A retired recipient fails permanently. Successor chains resolve to the last
  // known actor, never more than 10 deep.
  retiredRecipient(session) {
    const row = this.db.prepare('SELECT successor FROM sessions WHERE id=? AND retired_at IS NOT NULL').get(session)
      ?? this.db.prepare('SELECT successor FROM session_views WHERE id=? AND retired_at IS NOT NULL').get(session);
    if (!row) return null;
    let successor = row.successor;
    const seen = new Set([session]);
    for (let depth = 0; successor && depth < 10; depth++) {
      if (seen.has(successor)) break;
      seen.add(successor);
      const next = this.db.prepare('SELECT successor FROM sessions WHERE id=?').get(successor)?.successor
        ?? this.db.prepare('SELECT successor FROM session_views WHERE id=?').get(successor)?.successor;
      if (!next) break;
      successor = next;
    }
    return { successor };
  }
  retiredError({ successor }) {
    return Object.assign(
      new Error(`Recipient is retired${successor ? `; use successor ${this.store.authority}/${successor}` : ''}`),
      { code: 'RECIPIENT_RETIRED', status: 410, ...(successor ? { successor: `${this.store.authority}/${successor}` } : {}) },
    );
  }
  // The live actor a retired session's successor chain ends at, or null when
  // the chain dies without one.
  liveSuccessor(session) {
    const retired = this.retiredRecipient(session);
    if (!retired?.successor) return null;
    return !this.retiredRecipient(retired.successor) && this.recipientExists(retired.successor) ? retired.successor : null;
  }
  recipientExists(recipient) {
    // Enrollment is enough to receive a reply, including legacy sessions that
    // sent after reconnect without announcing again. Directory presence is UI.
    return this.db.prepare('SELECT 1 FROM sessions WHERE id=? UNION SELECT 1 FROM participants WHERE actor=? LIMIT 1').get(recipient,recipient);
  }
  deliveryProblems(actor) {
    const rows=this.db.prepare("SELECT id,error FROM message_outbox WHERE actor=? AND state='queued' AND (error IS NOT NULL OR created_at<?) ORDER BY created_at LIMIT 4").all(actor.id,this.store.now()-30000);
    if(!rows.length)return;
    return {messages:rows.slice(0,3).map(r=>({id:r.id,reason:r.error??'DELIVERY_PENDING'})),...(rows.length>3?{more:true}:{}),next:'Delivery is pending; do not resend with a new key. Check accord_more: accord_sent with id.'};
  }
  send(actor,body) {
    return this.store.command(actor,body,'send',()=>{
      text(body.to,'to',220);text(body.text,'text',4000);
      requireThat(body.to.split('/').length===2,'INVALID_INPUT','Use the recipient address from find',400);
      requireThat(body.to!==this.address(actor),'SELF_MESSAGE','Send to another participant; self-messages are not supported',400);
      const [authority,recipient]=body.to.split('/');
      let to=body.to,redirectedTo;
      if(authority===this.store.authority){
        requireThat(this.recipientExists(recipient),'RECIPIENT_UNKNOWN','Recipient is not registered; use an address from find or a received message',404);
        if(this.retiredRecipient(recipient)){
          // A retired recipient with a live successor takes the mail there;
          // without one the send fails the way it always has.
          const successor=this.liveSuccessor(recipient);
          if(successor){to=`${authority}/${successor}`;redirectedTo=to;}
          else throw this.retiredError(this.retiredRecipient(recipient));
        }
      }
      requireThat(authority===this.store.authority||this.db.prepare('SELECT 1 FROM links WHERE authority=?').get(authority),'HOST_UNKNOWN','Recipient host is not linked',404);
      requireThat(this.db.prepare("SELECT count(*) n FROM message_outbox WHERE state='queued'").get().n<100000,'CAPACITY_LIMIT','Pending message limit reached');
      requireThat(body.delivery===undefined||['inbox','native-prompt'].includes(body.delivery),'INVALID_INPUT','Unknown delivery preference',400);
      const messageId=id(),envelope={id:messageId,from:this.address(actor),to,text:body.text,kind:body.kind==='notification'?'notification':'message',delivery:body.delivery??'inbox'};
      this.db.prepare("INSERT INTO message_outbox(id,actor,envelope,state,error,created_at) VALUES(?,?,?,'queued',NULL,?)").run(messageId,actor.id,JSON.stringify(envelope),this.store.now());
      this.store.emit('message.queued',{id:messageId,from:envelope.from,to:envelope.to});return {id:messageId,state:'queued',...(redirectedTo?{redirectedTo}:{})};
    });
  }
  deliver(envelope) {
    text(envelope.id,'id',128);text(envelope.from,'from',220);text(envelope.text,'text',4000);
    const [authority,recipient]=String(envelope.to).split('/');
    requireThat(authority===this.store.authority&&this.recipientExists(recipient),'RECIPIENT_UNKNOWN','Recipient is not registered',404);
    // The receiving host applies the same successor rule as the sending one, so
    // mail queued before a retirement still lands with the live successor.
    let deliveredTo=recipient;
    if(this.retiredRecipient(recipient)){
      const successor=this.liveSuccessor(recipient);
      if(successor)deliveredTo=successor;
      else throw this.retiredError(this.retiredRecipient(recipient));
    }
    const to=`${authority}/${deliveredTo}`;
    const from=this.principal(envelope.from),toPrincipal=this.principal(to);
    const conversation=this.messages.createConversation(from,{members:[toPrincipal.handle]});
    this.messages.sendMessage(from,{conversationId:conversation.id,clientMessageId:envelope.id,body:envelope.text,data:{id:envelope.id,from:envelope.from,to,kind:envelope.kind,delivery:envelope.delivery==='native-prompt'?'native-prompt':'inbox',...(envelope.scheduledBy?{scheduledBy:envelope.scheduledBy}:{}),...(envelope.scheduleId?{scheduleId:envelope.scheduleId}:{})}});
    try{this.onDeliver?.(deliveredTo);}catch{/* A delivered message stays delivered if its hint fails. */}
    return {id:envelope.id,state:'delivered'};
  }
  // A linked host reports that one of its own sessions retired or revived; the
  // route maps it to the proxy actor that holds this host's resources. The link
  // speaks only for its own authority, and a replayed notice changes nothing.
  lifecycleNotice(peer, payload) {
    requireThat(payload && typeof payload === 'object', 'INVALID_INPUT', 'Invalid lifecycle notice', 400);
    text(payload.session, 'session', 128);
    requireThat(payload.event === 'retired' || payload.event === 'revived', 'INVALID_INPUT', 'Invalid lifecycle event', 400);
    const stale = [];
    const applied = this.store.mutate(() => {
      const route = this.db.prepare('SELECT * FROM remote_routes WHERE authority=? AND session_id=?').get(peer.authority, payload.session);
      if (!route) return false;
      const now = this.store.now();
      if (payload.event === 'revived') {
        if (!this.db.prepare("UPDATE remote_routes SET retired_at=NULL,retired_reason=NULL,successor=NULL WHERE actor=? AND retired_at IS NOT NULL").run(route.actor).changes) return false;
        // Revival within grace reclaims the same claims and generations.
        for (const r of this.db.prepare(`SELECT r.id reservation, c.id claim FROM reservations r JOIN claims c ON c.task_id=r.task_id
            WHERE c.actor=? AND c.state IN ('preparing','running') AND r.orphaned_at IS NOT NULL`).all(route.actor)) {
          this.db.prepare("UPDATE reservations SET orphaned_at=NULL,orphan_reason=NULL WHERE id=?").run(r.reservation);
          this.store.emit('reservation.reclaimed', { reservation: r.reservation, claim: r.claim, actor: route.actor });
        }
        this.store.emit('session.revived', { session: route.actor });
        return true;
      }
      const reason = typeof payload.reason === 'string' ? payload.reason : '';
      requireThat(['closed', 'silent', ...orphaningReasons].includes(reason), 'INVALID_INPUT', 'Invalid lifecycle reason', 400);
      const successor = typeof payload.successor === 'string' && payload.successor ? `${peer.authority}/${payload.successor}` : null;
      if (reason === 'closed') {
        // A close fences immediately, even when an earlier retirement already
        // marked the route; an orphaned hold does not finish its grace.
        const fresh = route.retired_at === null;
        this.db.prepare("UPDATE remote_routes SET retired_at=COALESCE(retired_at,?),retired_reason=COALESCE(retired_reason,'closed'),successor=COALESCE(?,successor) WHERE actor=?").run(now, successor, route.actor);
        const claims = this.db.prepare("SELECT * FROM claims WHERE actor=? AND state IN ('preparing','running')").all(route.actor);
        for (const claim of claims) {
          this.store.fence(claim, 'session ended');
          this.store.emit('claim.session_ended', { claim: claim.id, session: route.actor });
        }
        if (fresh || claims.length) this.store.emit('session.retired', { session: route.actor, reason: 'closed' });
        return true;
      }
      // Positive end evidence upgrades an earlier silent retirement, as it
      // does locally; anything else on a retired route is a replayed notice.
      const cond = orphaningReasons.has(reason) ? "(retired_at IS NULL OR retired_reason='silent')" : "retired_at IS NULL";
      if (!this.db.prepare(`UPDATE remote_routes SET retired_at=COALESCE(retired_at,?),retired_reason=?,successor=COALESCE(?,successor) WHERE actor=? AND ${cond}`).run(now, reason, successor, route.actor).changes) return false;
      if (orphaningReasons.has(reason)) orphanClaims(this.db, (kind, data) => this.store.emit(kind, data), now, route.actor, reason);
      if (reason === 'silent')
        for (const claim of this.db.prepare("SELECT id,resource,generation,deadline FROM claims WHERE actor=? AND state IN ('preparing','running','releasing','revoking') ORDER BY created_at DESC LIMIT 1").all(route.actor)) {
          const key = `stale:${claim.id}:${claim.generation}`;
          if (this.db.prepare("SELECT 1 FROM commands WHERE actor=? AND key=?").get('accord-lifecycle', key)) continue;
          this.db.prepare("INSERT INTO commands VALUES(?,?,'','{}')").run('accord-lifecycle', key);
          this.store.emit('session.stale_holder', { session: route.actor, claim: claim.id, resource: claim.resource, generation: claim.generation });
          stale.push({ session: route.actor, claim: claim.id, resource: claim.resource, generation: claim.generation, deadline: claim.deadline });
        }
      this.store.emit('session.retired', { session: route.actor, reason });
      return true;
    });
    return { applied: !!applied, stale };
  }
  async flush() {
    if(this.sending){this.again=true;return;}this.sending=true;
    try{
      // Bounded batches, with independent destinations so one offline host cannot starve another.
      const pending=this.db.prepare("SELECT * FROM message_outbox WHERE state='queued' ORDER BY last_attempt,created_at LIMIT 32").all();
      await Promise.all(pending.map(async row=>{
        const envelope=JSON.parse(row.envelope);
        try{
          this.store.mutate(()=>this.db.prepare('UPDATE message_outbox SET last_attempt=? WHERE id=?').run(this.store.now(),row.id));
          const authority=envelope.to.split('/')[0];
          if(authority===this.store.authority)this.deliver(envelope);
          else await this.forward(authority,'deliver',envelope,{id:row.actor});
          this.store.mutate(()=>{this.db.prepare("UPDATE message_outbox SET state='delivered',error=NULL WHERE id=?").run(row.id);this.store.emit('message.delivered',{id:row.id});});
        }catch(e){
          // A retired recipient never revives for this envelope; mark it failed
          // permanently instead of retrying forever.
          const permanent=e.code==='RECIPIENT_RETIRED';
          this.store.mutate(()=>this.db.prepare(permanent?"UPDATE message_outbox SET state='failed',error=? WHERE id=?":"UPDATE message_outbox SET error=? WHERE id=?").run(e.code??'HOST_UNAVAILABLE',row.id));
        }
      }));
      // Lifecycle notices ride the same cadence as mail: retried while queued,
      // and dropped after a week so a permanently unreachable or old-version
      // link never accumulates them.
      for(const row of this.db.prepare("SELECT * FROM lifecycle_outbox WHERE state='queued' ORDER BY last_attempt,created_at LIMIT 32").all()){
        if(row.created_at<this.store.now()-7*86400000){
          this.store.mutate(()=>{this.db.prepare("UPDATE lifecycle_outbox SET state='dropped' WHERE id=?").run(row.id);this.store.emit('lifecycle.notice_dropped',{authority:row.authority,session:row.session_id,event:row.event});});
          continue;
        }
        try{
          this.store.mutate(()=>this.db.prepare('UPDATE lifecycle_outbox SET last_attempt=?,attempts=attempts+1 WHERE id=?').run(this.store.now(),row.id));
          await this.forward(row.authority,'lifecycle',JSON.parse(row.payload),{id:'accord-lifecycle'});
          this.store.mutate(()=>this.db.prepare("UPDATE lifecycle_outbox SET state='delivered' WHERE id=?").run(row.id));
        }catch(e){
          this.store.mutate(()=>this.db.prepare('UPDATE lifecycle_outbox SET attempts=attempts+1 WHERE id=?').run(row.id));
        }
      }
    }finally{this.sending=false;}
    if(this.again){this.again=false;return this.flush();}
  }
  inboxActors(actor){return [...new Set([actor.id,
    ...this.db.prepare('SELECT v.id FROM session_bindings b JOIN session_views v ON v.source=b.source AND v.external_id=b.external_id WHERE b.actor=? AND v.private=0').all(actor.id).map(r=>r.id),
    ...this.db.prepare(`SELECT a.actor id FROM session_bindings b JOIN session_mailbox_aliases a USING(source,external_id)
      LEFT JOIN session_views v ON v.id=a.actor LEFT JOIN source_privacy p ON p.source=a.source
      WHERE b.actor=? AND COALESCE(v.private,0)=0 AND COALESCE(p.private,0)=0`).all(actor.id).map(r=>r.id)
  ])];}
  pendingCount(actor) {
    // Count canonical Messenger deliveries without fetching bodies or claiming them.
    const at=new Date().toISOString();let count=0;
    for(const a of this.inboxActors(actor)) {
      const principal=this.messages.principalByHandle('a'+hash(this.address({id:a})).slice(0,60));if(!principal)continue;
      count+=this.messages.db.prepare(`SELECT count(*) n FROM deliveries d WHERE ${pendingDelivery}`).get(principal.id,at,at).n;
    }
    return count;
  }
  // Messenger pages oldest first, so a backlog would hide new mail from a wake.
  newest(actor,limit=200) {
    const at=new Date().toISOString();
    return this.inboxActors(actor).flatMap(a=>{
      const principal=this.messages.principalByHandle('a'+hash(this.address({id:a})).slice(0,60));if(!principal)return [];
      return this.messages.db.prepare(`SELECT d.id deliveryId,m.body text,m.data_json data,m.created_at at FROM deliveries d JOIN messages m ON m.id=d.message_id
        WHERE ${pendingDelivery} ORDER BY m.created_at DESC,m.seq DESC LIMIT ?`).all(principal.id,at,at,limit)
        .map(({data,...m})=>{const {from,kind}=JSON.parse(data??'{}');return {...m,from,kind};});
    }).sort((a,b)=>Date.parse(a.at)-Date.parse(b.at)||a.deliveryId.localeCompare(b.deliveryId));
  }
  // Read state lives in Messenger. UI adapters must not acknowledge on receipt or cache it
  // as another mailbox. History is a bounded view of the same canonical deliveries.
  inbox(actor,{all=false}={}) {
    const messages=this.inboxActors(actor).flatMap(id=>{
      const principal=this.principal(this.address({id}));
      if(!all)return this.messages.peekInbox(principal,{limit:100}).map(d=>({id:d.message.data.id,deliveryId:d.id,...d.message.data,text:d.message.body,at:d.message.createdAt,read:false}));
      return this.messages.listConversations(principal,{limit:100}).flatMap(c=>
        this.messages.listMessages(principal,c.id,{after:Math.max(0,c.latestSeq-100),limit:100})
          .filter(m=>m.delivery).map(m=>({...m.data,deliveryId:m.delivery.id,text:m.body,at:m.createdAt,read:m.delivery.state==='acknowledged'})));
    });
    const ordered=messages.sort((a,b)=>Date.parse(a.at)-Date.parse(b.at)||a.id.localeCompare(b.id));
    return {messages:all?ordered.slice(-100):ordered.slice(0,100)};
  }
  // Cursor paging is a view over canonical deliveries; it never claims or reads
  // a delivery. Acknowledging earlier pages cannot shift the remaining page.
  inboxPage(actor,{limit=20,cursor}={}) {
    integer(limit,'limit',1,100);
    const principals=this.inboxActors(actor).flatMap(id=>{
      const principal=this.messages.principalByHandle('a'+hash(this.address({id})).slice(0,60));return principal?[principal.id]:[];
    });
    let after;
    if(cursor!==undefined){
      text(cursor,'cursor',100);
      const row=this.messages.db.prepare(`SELECT d.recipient_id,m.created_at at,m.seq,d.id
        FROM deliveries d JOIN messages m ON m.id=d.message_id WHERE d.id=?`).get(cursor);
      requireThat(row&&principals.includes(row.recipient_id),'NOT_OWNER','Cursor does not belong to this inbox',403);
      after=[row.at,row.seq,row.id];
    }
    const at=new Date().toISOString(),rows=[];
    for(const principal of principals){
      rows.push(...this.messages.db.prepare(`SELECT d.id deliveryId,m.body text,m.data_json data,m.created_at at,m.seq
        FROM deliveries d JOIN messages m ON m.id=d.message_id WHERE ${pendingDelivery}
        ${after?'AND (m.created_at,m.seq,d.id)>(?,?,?)':''} ORDER BY m.created_at,m.seq,d.id LIMIT ?`)
        .all(principal,at,at,...(after??[]),limit+1));
    }
    rows.sort((a,b)=>(a.at<b.at?-1:a.at>b.at?1:0)||a.seq-b.seq||(a.deliveryId<b.deliveryId?-1:a.deliveryId>b.deliveryId?1:0));
    const messages=[];let bytes=0,last;
    for(const row of rows){
      const message={...JSON.parse(row.data),deliveryId:row.deliveryId,text:row.text,at:row.at,read:false},size=Buffer.byteLength(JSON.stringify(message))+1;
      // A legal message (at most 4000 UTF-16 code units) always fits whole.
      if(messages.length>=limit||(messages.length&&bytes+size>24*1024-1024))break;
      messages.push(message);bytes+=size;last=row;
    }
    const more=messages.length<rows.length;
    return {messages,...(bytes>24*1024-1024?{oversized:true}:{}),...(more?{more:true,cursor:last.deliveryId}:{})};
  }
  notify(actor,body) {
    // Operator notifications use the existing Messenger inbox, not another notice store.
    const operator={id:'admin',role:'admin'};
    if(!this.db.prepare('SELECT 1 FROM participants WHERE actor=?').get(operator.id))
      this.announce(operator,{key:'operator-inbox',label:'Operator',activity:'Human attention inbox',capabilities:[]});
    return this.send(actor,{key:body.key,to:this.address(operator),text:body.text,kind:'notification'});
  }
  read(actor,body) {
    text(body.deliveryId,'deliveryId',100);
    let principal,row;
    for(const id of this.inboxActors(actor)){
      const p=this.principal(this.address({id}));try{row=this.messages.ownedDelivery(p.id,body.deliveryId);principal=p;break;}catch{}
    }
    requireThat(row,'NOT_OWNER','Delivery does not belong to this session',403);
    if(row.state==='acknowledged')return {read:true};
    const delivery=this.messages.claimInbox(principal,{deliveryId:body.deliveryId})[0];
    requireThat(delivery,'RETRY','Read confirmation is recovering; retry shortly');
    this.messages.acknowledge(principal,delivery.id,{leaseToken:delivery.leaseToken});return {read:true};
  }
  sent(actor,id) {
    const row=this.db.prepare('SELECT id,state,error FROM message_outbox WHERE id=? AND actor=?').get(id,actor.id);
    requireThat(row,'NOT_FOUND','Unknown outgoing message',404);return row;
  }
  reserve(actor,body) {
    return this.store.command(actor,body,'reserve',()=>{
      text(body.resource,'resource',100);text(body.purpose??'reserved','purpose',200);
      const duration = windowDuration(body);
      integer(body.leaseMs??300000,'leaseMs',500,300000);integer(body.waitMs??3600000,'waitMs',1000,86400000);
      // A waiter holds a place in the pool; schedule() seats it on a free slot.
      const slot=this.slots(body.resource)[0],resource=slot??body.resource;
      requireThat(this.db.prepare('SELECT id FROM resources WHERE id=?').get(resource),'RESOURCE_UNKNOWN','Unknown resource',404);
      for (const candidate of slot ? this.slots(body.resource) : [resource]) {
        const limit = this.store.ownershipLimit(candidate);
        requireThat(duration === null || limit === null || duration <= limit, 'ATTEMPT_LIMIT', 'Reservation window exceeds the resource ownership limit');
      }
      requireThat(this.db.prepare("SELECT count(*) n FROM tasks WHERE kind='reservation' AND state IN ('queued','preparing','running','recovering','releasing','cancelling')").get().n<5000,'CAPACITY_LIMIT','Active reservation limit reached');
      const reservationId=id(),taskId=id(),now=this.store.now();
      this.db.prepare("INSERT INTO tasks(id,title,input,expected_hash,resource,state,created_at,max_attempts,kind) VALUES(?,?,?,'',?,'queued',?,1,'reservation')")
        .run(taskId,body.purpose??'reserved','',resource,now);
      this.db.prepare('INSERT INTO reservations(id,actor,task_id,lease_ms,queued_until,pool,duration_ms) VALUES(?,?,?,?,?,?,?)').run(reservationId,actor.id,taskId,body.leaseMs??300000,now+(body.waitMs??3600000),slot?body.resource:null,duration);
      this.store.emit('reservation.queued',{id:reservationId,actor:actor.id,resource:body.resource});return {id:reservationId};
    });
  }
  reservation(actor,reservationId) {
    const row=this.db.prepare('SELECT r.*,t.resource,t.state task_state FROM reservations r JOIN tasks t ON t.id=r.task_id WHERE r.id=?').get(reservationId);
    requireThat(row,'NOT_FOUND','Unknown reservation',404);requireThat(row.actor===actor.id,'NOT_OWNER','Reservation belongs to another session',403);
    const claim=this.db.prepare('SELECT * FROM claims WHERE task_id=? ORDER BY created_at DESC LIMIT 1').get(row.task_id);
    const grace=this.db.prepare('SELECT orphan_grace_ms FROM resource_bindings WHERE id=?').get(row.resource)?.orphan_grace_ms??orphanGraceDefaultMs;
    return {id:row.id,resource:row.pool&&!claim?row.pool:row.resource,state:claim?.state==='closed'?claim.outcome:claim?.state??row.task_state,
      ...(row.orphaned_at!==null?{orphaned:{since:row.orphaned_at,reason:row.orphan_reason,releaseAt:row.orphaned_at+grace}}:{}),
      mode:row.duration_ms===null?'heartbeat':'window',renewalRequired:row.duration_ms===null,durationMs:row.duration_ms,
      authority:this.store.authority,generation:claim?.generation??null,workloadUnitPrefix:claim?'accord-'+hash(this.store.authority+'/'+claim.id+'/'+claim.generation).slice(0,20)+'-':null,claimId:claim?.id??null,deadline:claim?.deadline??null,queuedUntil:row.queued_until,error:claim?.error??null};
  }
  release(actor,reservationId,body) {
    return this.store.command(actor,body,`release:${reservationId}`,()=>{
      const r=this.reservation(actor,reservationId),row=this.db.prepare('SELECT task_id FROM reservations WHERE id=?').get(reservationId);
      if(r.claimId){
        const claim=this.store.claim(r.claimId);
        if(['preparing','running'].includes(claim.state)){
          this.db.prepare("UPDATE claims SET state='releasing',outcome='released' WHERE id=?").run(claim.id);
          this.db.prepare("UPDATE tasks SET state='releasing' WHERE id=?").run(row.task_id);
        }
      }else this.db.prepare("UPDATE tasks SET state='cancelled' WHERE id=?").run(row.task_id);
      this.store.emit('reservation.release_requested',{id:reservationId});return this.reservation(actor,reservationId);
    });
  }
  holder(actor) {
    const route=this.db.prepare('SELECT * FROM remote_routes WHERE actor=?').get(actor);
    if(!route&&!this.db.prepare('SELECT 1 FROM participants WHERE actor=?').get(actor))return null;
    return route?`${route.authority}/${route.session_id}`:this.address({id:actor});
  }
  // A queued holder can sit idle at no cost: its grant arrives as ordinary mail.
  // An immediate grant already answered the caller, so it adds nothing to the inbox.
  granted(sender,{key,reservation,actor,resource,queuedAt}) {
    if(this.store.now()-queuedAt<5000)return;
    const to=this.holder(actor);if(!to)return;
    const window = this.db.prepare('SELECT duration_ms FROM reservations WHERE id=?').get(reservation)?.duration_ms;
    this.send(sender,{key,to,kind:'message',text:`Accord reports reservation ${reservation} is running on ${resource}. Confirm with accord_reservation before use. ${window?'Its bounded window needs no heartbeat; extend only if you need more time.':'Renew before its deadline.'} Release when finished.`});
    void this.flush().catch(()=>{});
  }
  grantedClaim(sender,claim) {
    // A window resumed after a coordinator restart was granted before; its holder was never told otherwise.
    if(claim.error==='coordinator restarted')return;
    const row=this.db.prepare('SELECT r.id,r.actor,t.created_at FROM reservations r JOIN tasks t ON t.id=r.task_id WHERE r.task_id=?').get(claim.task_id);
    if(row)this.granted(sender,{key:`grant:${claim.id}:${claim.generation}`,reservation:row.id,actor:row.actor,resource:claim.resource,queuedAt:row.created_at});
  }
  // A holder that did not release must not find out by surprise that its hold is gone.
  endedClaim(sender,claim) {
    const row=this.db.prepare('SELECT id,actor FROM reservations WHERE task_id=?').get(claim.task_id);
    const session=row&&this.db.prepare('SELECT closed_at,expires_at,retired_at,successor FROM sessions WHERE id=?').get(row.actor);
    if(!row||claim.outcome==='released'||session&&(session.closed_at!==null||session.expires_at<=this.store.now()))return;
    // A retired holder's successor hears that the hold ended; a successor
    // inherits nothing, so it must reserve again for the same resource.
    let actor=row.actor,route;
    if(session&&session.retired_at!==null){
      const next=session.successor&&this.db.prepare('SELECT closed_at,expires_at,retired_at FROM sessions WHERE id=?').get(session.successor);
      if(!next||next.closed_at!==null||next.retired_at!==null||next.expires_at<=this.store.now())return;
      actor=session.successor;
    }else route=this.db.prepare('SELECT retired_at,successor FROM remote_routes WHERE actor=?').get(row.actor);
    // A retired remote holder's notice goes to the successor address the origin
    // host named; without one there is nobody left to tell.
    if(route&&route.retired_at!==null&&!route.successor)return;
    const to=route&&route.retired_at!==null?route.successor:this.holder(actor);if(!to)return;
    const how=claim.deadline<=this.store.now()?'reached its deadline and ended':`ended as ${claim.outcome}: Accord revoked it before its deadline`;
    this.send(sender,{key:`ended:${claim.id}:${claim.generation}`,to,kind:'message',text:`Accord reports reservation ${row.id} on ${claim.resource} ${how}. Confirm with accord_reservation; the resource is no longer held for you, so reserve again if you still need it.`});
    void this.flush().catch(()=>{});
  }
  slots(pool){return this.db.prepare('SELECT resource FROM resource_pools WHERE pool=? ORDER BY length(resource),resource').all(pool).map(r=>r.resource);}
  pools(resources){
    const groups=new Map(this.db.prepare('SELECT DISTINCT pool FROM resource_pools ORDER BY pool').all().map(r=>[r.pool,{id:`${this.store.authority}/${r.pool}`,capacity:0,free:0,queued:0}]));
    for(const r of resources){const group=groups.get(r.pool);if(group){group.capacity++;if(r.state==='unclaimed')group.free++;}}
    for(const row of this.db.prepare("SELECT r.pool,count(*) n FROM tasks t JOIN reservations r ON r.task_id=t.id WHERE t.state='queued' AND r.pool IS NOT NULL GROUP BY r.pool").all())if(groups.has(row.pool))groups.get(row.pool).queued=row.n;
    return [...groups.values()];
  }

  schedule() {
    const waiting=this.db.prepare("SELECT r.*,t.resource FROM reservations r JOIN tasks t ON t.id=r.task_id WHERE t.state='queued' ORDER BY t.created_at,t.rowid").all();
    const seen=new Set(),full=new Set();
    for(const row of waiting){
      const session=this.db.prepare('SELECT * FROM sessions WHERE id=?').get(row.actor);
      const remote=this.db.prepare('SELECT retired_at FROM remote_routes WHERE actor=?').get(row.actor);
      if(row.queued_until<=this.store.now()||session&&(session.closed_at!==null||session.expires_at<=this.store.now()||session.retired_at!==null)||remote&&remote.retired_at!==null){
        this.store.mutate(()=>this.db.prepare("UPDATE tasks SET state='cancelled' WHERE id=?").run(row.task_id));continue;
      }
      if(row.pool){
        if(full.has(row.pool))continue;
        const slot=this.slots(row.pool).find(s=>!seen.has(s)&&!this.db.prepare("SELECT 1 FROM claims WHERE resource=? AND state IN ('preparing','running','releasing','revoking')").get(s));
        if(!slot){full.add(row.pool);continue;}
        this.store.mutate(()=>this.db.prepare('UPDATE tasks SET resource=? WHERE id=?').run(slot,row.task_id));row.resource=slot;
      }
      if(seen.has(row.resource))continue;seen.add(row.resource);
      try{this.store.acquire({id:row.actor,role:'worker'},{key:`reservation:${row.id}`,taskId:row.task_id,leaseMs:row.lease_ms});}
      catch(e){
        if(e.code==='ATTEMPT_LIMIT')this.store.mutate(()=>{
          this.db.prepare("UPDATE tasks SET state='failed' WHERE id=?").run(row.task_id);
          this.store.emit('reservation.rejected',{id:row.id,reason:e.message});
        });
        else if(!['RESOURCE_BUSY','PAUSED'].includes(e.code))throw e;
      }
    }
  }
}
