// Development fixture: private host, dynamic loopback ports, no installed profile or hardware.
import { fork, spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const [data,profile]=process.argv.slice(2);
const candidates=[process.env.ACCORD_TEST_CLI,fileURLToPath(new URL('../Vendor/Accord/src/cli.mjs',import.meta.url)),fileURLToPath(new URL('../../accord/src/cli.mjs',import.meta.url))].filter(Boolean);
const cli=candidates.find(existsSync);
if(!cli)throw Error('Provide ACCORD_TEST_CLI or vendor Accord before running integration tests');
const initialized=spawnSync(process.execPath,[cli,'init','--data',data],{encoding:'utf8'});
if(initialized.status!==0)throw Error(initialized.stderr);
const proc=fork(cli,['up','--data',data,'--port','0','--driver-port','0'],{stdio:['ignore','ignore','inherit','ipc']});
let ending=false;
process.once('SIGTERM',()=>{ending=true;proc.kill('SIGTERM');});
proc.once('exit',code=>process.exit(ending?0:code??1));
const timer=setInterval(async()=>{
  const path=join(data,'endpoints.json');
  if(!existsSync(path))return;
  clearInterval(timer);
  const authority=JSON.parse(readFileSync(join(data,'config.json'),'utf8')).authority;
  const {AccordClient}=await import(pathToFileURL(resolve(cli,'../client.mjs')).href);
  const url=JSON.parse(readFileSync(path,'utf8')).coordinator;
  const agent=await AccordClient.enroll(url,readFileSync(join(data,'bootstrap.token'),'utf8').trim(),{authority,label:'Fixture agent'});
  await agent.announce({label:'Fixture agent',activity:'Native integration test'});
  writeFileSync(profile+'.agent',JSON.stringify({url,credential:agent.credential}),{mode:0o600});
  writeFileSync(profile,JSON.stringify({authority,endpointFile:path}),{mode:0o600});clearInterval(timer);
},50);
setTimeout(()=>{if(!existsSync(profile)){proc.kill();process.exitCode=1;}},10000).unref();
