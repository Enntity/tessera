// SPDX-License-Identifier: MIT
// Host workload observation: GPU processes, running containers and trusted
// provider reports, surfaced on resources as observations — never ownership.
// Linux only; elsewhere the collectors report unavailable instead of failing.
import fs from 'node:fs/promises';
import { posix } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { requireThat, text, integer, hash } from './common.mjs';

const execute=promisify(execFile);
async function probe(command,args,timeoutMs){
  return execute(command,args,{encoding:'utf8',timeout:timeoutMs,killSignal:'SIGKILL',maxBuffer:1024*1024,windowsHide:true});
}
const basename=p=>{const n=String(p??'').trim();return n.slice(n.lastIndexOf('/')+1).slice(0,200);};
function csv(line){const out=[];let part='',quoted=false;for(let i=0;i<line.length;i++){
  if(line[i]==='"'){if(quoted&&line[i+1]==='"'){part+='"';i++;}else quoted=!quoted;}
  else if(line[i]===','&&!quoted){out.push(part.trim());part='';}else part+=line[i];
}out.push(part.trim());return out;}
const mib=v=>{const t=String(v??'').trim();if(t==='[N/A]'||t==='')return null;const n=Number(t);return Number.isFinite(n)&&n>=0?n:null;};

export function parseComputeApps(output){
  return String(output).trim().split(/\r?\n/).filter(Boolean).slice(0,64).flatMap(line=>{
    const f=csv(line);if(f.length<3)return [];
    const pid=Number(f[0]);if(!Number.isInteger(pid)||pid<=0)return [];
    return [{pid,command:basename(f[1]),gpuMemoryMiB:mib(f[2]),gpu:f[3]?String(f[3]).slice(0,80):undefined}];
  });
}
const ownedLabel=/^(io\.lloom\.|io\.enntity\.)/;
export function parseDockerPs(output){
  return String(output).trim().split(/\r?\n/).filter(Boolean).slice(0,64).flatMap(line=>{
    let row;try{row=JSON.parse(line);}catch{return []}
    const id=String(row.ID??row.IDOrName??'').trim();if(!id)return [];
    const labels={};
    for(const pair of String(row.Labels??'').split(',')){
      const at=pair.indexOf('=');if(at<1)continue;
      const key=pair.slice(0,at).trim();if(ownedLabel.test(key))labels[key.slice(0,80)]=pair.slice(at+1).slice(0,200);
    }
    return [{id:id.slice(0,12),fullId:id,name:String(row.Names??'').slice(0,120),image:String(row.Image??'').slice(0,120),status:String(row.Status??'').slice(0,120),labels}];
  });
}
export function containerOf(cgroup){
  const m=/docker-([0-9a-f]{64})\.scope/.exec(cgroup)??/\/docker\/([0-9a-f]{64})/.exec(cgroup);
  return m?.[1]??null;
}

// Reports are trusted-provider input (LLooM), held in memory only: each report
// replaces the previous one from its source and expires with it, so no durable
// migration is needed. Senders re-report every minute; a restart just means a
// few seconds without observations.
const STATES=['running','starting','stopping','stopped','suspended','failed','unknown'];
export function createWorkloads({platform=process.platform,run=probe,files=fs,now=Date.now,cacheMs=10000}={}){
  const reports=new Map();
  function report(actor,args={}){
    requireThat(actor?.role==='admin','FORBIDDEN','Operator required',403);
    const source=text(args.source,'source',40);requireThat(/^[a-z0-9-]{1,40}$/.test(source),'INVALID_INPUT','Invalid report source',400);
    const ttlMs=integer(args.ttlMs??180000,'ttlMs',10000,3600000);
    requireThat(Array.isArray(args.items)&&args.items.length<=128,'INVALID_INPUT','Report up to 128 items',400);
    const items=args.items.map((item,i)=>{
      requireThat(item&&typeof item==='object','INVALID_INPUT',`Item ${i} must be an object`,400);
      return {id:text(item.id,'item id',120),kind:item.kind===undefined?'runtime':(text(item.kind,'item kind',20),requireThat(item.kind==='runtime','INVALID_INPUT','Item kind must be runtime',400),'runtime'),
        node:item.node===undefined?undefined:text(item.node,'item node',120),
        container:item.container===undefined?undefined:text(item.container,'item container',120),
        state:item.state===undefined?'unknown':(requireThat(STATES.includes(item.state),'INVALID_INPUT','Unknown item state',400),item.state),
        model:item.model===undefined?undefined:text(item.model,'item model',200),
        since:item.since===undefined?undefined:integer(item.since,'item since',0,Number.MAX_SAFE_INTEGER),
        by:item.by===undefined?undefined:text(item.by,'item by',200),
        operationId:item.operationId===undefined?undefined:text(item.operationId,'item operationId',80),
        note:item.note===undefined?undefined:text(item.note,'item note',200)};
    });
    const at=now();
    reports.set(source,{source,reportedAt:at,expiresAt:at+ttlMs,items});
    return {accepted:items.length,expiresAt:at+ttlMs};
  }
  function activeReports(){
    const at=now(),live=[];
    for(const r of reports.values()){if(r.expiresAt>at)live.push(r);else reports.delete(r.source);}
    return live;
  }
  async function collect(){
    if(platform!=='linux')return {sampledAt:now(),gpu:'unavailable',docker:'unavailable',reason:'platform',containers:[],processes:[]};
    const sample={sampledAt:now(),containers:[],processes:[]};
    let procs=[],containers=[];
    try{
      const {stdout}=await run('nvidia-smi',['--query-compute-apps=pid,process_name,used_memory,gpu_uuid','--format=csv,noheader,nounits'],3000);
      procs=parseComputeApps(stdout);sample.gpu='available';
    }catch{sample.gpu='unavailable';}
    try{
      const {stdout}=await run('docker',['ps','--no-trunc','--format','{{json .}}'],3000);
      containers=parseDockerPs(stdout);sample.docker='available';
    }catch{sample.docker='unavailable';}
    const byFullId=new Map(containers.map(c=>[c.fullId,c]));
    for(const p of procs){
      let name=null;
      if(containers.length){
        try{const match=containerOf(await files.readFile(`/proc/${p.pid}/cgroup`,'utf8'));name=match?byFullId.get(match)?.name??null:null;}catch{/* Process may have exited. */}
      }
      p.container=name;
      delete p.gpu;
    }
    for(const c of containers){
      const mine=procs.filter(p=>p.container===c.name);
      c.gpuMemoryMiB=mine.some(p=>p.gpuMemoryMiB!==null)?mine.reduce((s,p)=>s+(p.gpuMemoryMiB??0),0):null;
      c.gpuProcesses=mine.map(p=>p.pid);
      delete c.fullId;
    }
    sample.containers=containers.slice(0,64);
    sample.processes=procs.filter(p=>p.container===null).slice(0,64);
    return sample;
  }
  let cached=null,flight=null;
  async function sample(){
    if(cached&&now()-cached.at<cacheMs)return cached.value;
    if(!flight)flight=collect().then(value=>{cached={at:now(),value};return value;},()=>(cached??{value:{sampledAt:now(),gpu:'unavailable',docker:'unavailable',reason:'collect-failed',containers:[],processes:[]}}).value).finally(()=>{flight=null;});
    return flight;
  }
  async function read(){
    const s=await sample();
    return {...s,reports:activeReports().map(r=>({source:r.source,reportedAt:r.reportedAt,expiresAt:r.expiresAt,items:r.items}))};
  }
  return {collect,sample,read,report,activeReports};
}

// Assemble one resource's workload view from already-fetched host telemetries.
// `wanted` maps each resource host name to its authority or null — the caller
// resolves names by local host and link files first; names still null here fall
// back to a linked host's advertised descriptor name. Reports carry their source
// authority so a node-less item belongs to its reporter.
export function workloadView({wanted,samples,reports=[],holder=null,authority,now=Date.now()}){
  for(const [name,a] of wanted){
    if(a!==null)continue;
    for(const [auth,t] of samples){
      if(t&&(t.hostname===name||t.machine?.hostname===name)){wanted.set(name,auth);break;}
    }
  }
  const names=[...wanted.keys()];
  const items=[],prefix=holder?.claim&&holder.generation!=null?`accord-${hash(authority+'/'+holder.claim+'/'+holder.generation).slice(0,20)}-`:null;
  const flat=reports.flatMap(r=>r.items.map(item=>({...item,reportAuthority:r.authority})));
  const hosts=names.map(name=>{
    const a=wanted.get(name);
    if(!a)return {name,status:'unavailable',reason:'host not linked'};
    return samples.get(a)?{name,authority:a,status:'observed'}:{name,authority:a,status:'unavailable',reason:'telemetry unavailable'};
  });
  for(const h of hosts){
    if(h.status!=='observed')continue;
    const wl=samples.get(h.authority).workloads??{},containers=wl.containers??[],processes=wl.processes??[];
    const annotated=new Set();
    // One report item per runtime id on this host: a host's own gateway wins
    // over a head that also reports its worker runtimes.
    const mine=[];
    for(const item of flat){
      const belongs=item.node!==undefined?item.node===h.name:item.reportAuthority===h.authority;
      if(!belongs)continue;
      const existing=mine.find(other=>other.id===item.id);
      if(!existing){mine.push(item);continue;}
      if(item.reportAuthority===h.authority&&existing.reportAuthority!==h.authority)mine[mine.indexOf(existing)]=item;
    }
    for(const c of containers){
      const match=mine.find(item=>item.container===c.name);
      if(match)annotated.add(match);
      const item={host:h.name,kind:'container',name:c.name,image:c.image,state:'running',gpuMemoryMiB:c.gpuMemoryMiB??undefined};
      if(match){item.runtime=match.id;item.state=match.state;if(match.model!==undefined)item.model=match.model;if(match.since!==undefined)item.since=match.since;if(match.by!==undefined)item.by=match.by;}
      if(prefix&&c.name.startsWith(prefix)){item.owner=holder.label??holder.address;item.ownerSource='reservation';}
      else if(match){item.owner=`LLooM runtime ${match.id}`;item.ownerSource='lloom';}
      else if(c.labels?.['io.enntity.owner']){item.owner=c.labels['io.enntity.owner'];item.ownerSource='declared';}
      else if(c.labels?.['io.enntity.job']){item.owner=c.labels['io.enntity.job'];item.ownerSource='declared';}
      else item.ownerSource='unknown';
      items.push(item);
    }
    for(const p of processes)items.push({host:h.name,kind:'process',name:p.command,pid:p.pid,gpuMemoryMiB:p.gpuMemoryMiB??undefined,ownerSource:'unknown'});
    // Stopped runtimes are routine on-demand lanes; only states someone must
    // see are listed — suspended and failed.
    for(const item of mine.filter(i=>!annotated.has(i)&&['suspended','failed'].includes(i.state)))
      items.push({host:h.name,kind:'runtime',name:item.id,state:item.state,owner:`LLooM runtime ${item.id}`,ownerSource:'lloom',...(item.model!==undefined?{model:item.model}:{}),...(item.since!==undefined?{since:item.since}:{}),...(item.by!==undefined?{by:item.by}:{})});
  }
  return {observedAt:now,note:'Observed on the host; not ownership',hosts,items};
}
