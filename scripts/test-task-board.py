#!/usr/bin/env python3
"""Verify grouping in an isolated native app; never restart the real board."""
import pathlib,subprocess,os,json,time,datetime,urllib.request,uuid,sys
home=pathlib.Path('/tmp/tessera-task-ui-'+str(uuid.uuid4()));home.mkdir();data=home/'board';data.mkdir();app=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else '/tmp/Tessera-task-proof.app');node=app/'Contents/Helpers/node';cli=app/'Contents/Resources/Accord/src/cli.mjs';hostdata=home/'accord';native='local_ui-proof';session='28cecd53-2ea2-486c-a20c-74d530ab5c5d';now=datetime.datetime.now(datetime.timezone.utc).isoformat();ms=int(time.time()*1000)
meta=home/'Library/Application Support/Claude/claude-code-sessions/proof';meta.mkdir(parents=True)
(meta/(native+'.json')).write_text(json.dumps({'sessionId':native,'cliSessionId':session,'lastActivityAt':ms,'title':'Evaluate the model','cwd':str(home)}))
logs=home/'.claude/projects/fixture';logs.mkdir(parents=True)
(logs/(session+'.jsonl')).write_text(json.dumps({'type':'assistant','timestamp':now,'sessionId':session,'cwd':str(home),'message':{'role':'assistant','content':[{'type':'text','text':'Evaluation is running. A review agent is checking the results.'},{'type':'tool_use','id':'fixture','name':'Bash','input':{'command':'evaluate'}}]}})+'\n')
(data/'workspace.json').write_text(json.dumps({'tiles':[{'id':'proof-terminal','title':'Local shell','kind':'terminal','command':'/bin/cat','cwd':str(home)}],'order':['proof-terminal'],'resumeOnLaunch':True}))
env=dict(os.environ,HOME=str(home),CFFIXED_USER_HOME=str(home),XDG_CONFIG_HOME=str(home/'.config'),TESSERA_DATA_DIR=str(data),TESSERA_NO_AUTO_SETUP='1',TESSERA_DEBUG_ACTIONS='size=1400x900;wait=12;dump='+str(home/'board.json')+';shot='+str(home/'board.png'))
for k in ['DSH_HOME','CODEX_HOME','TESSERA_TILE_ID','ACCORD_PROFILE','ACCORD_SESSION_FILE','ACCORD_DATA','ACCORD_URL','CODEX_THREAD_ID','CLAUDE_SESSION_ID']:env.pop(k,None)
subprocess.run([node,cli,'init','--data',hostdata],env=env,check=True,capture_output=True)
log=(home/'daemon.log').open('w');daemon=subprocess.Popen([node,cli,'up','--data',hostdata,'--port','0','--driver-port','0'],env=env,stdout=log,stderr=log)
def wait(fn,seconds=40):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  try:
   v=fn()
   if v:return v
  except (OSError,ValueError,AssertionError):pass
  time.sleep(.2)
 raise RuntimeError('Timed out')
proc=None
try:
 ep=wait(lambda:json.loads((hostdata/'endpoints.json').read_text()));authority=json.loads((hostdata/'config.json').read_text())['authority'];token=(hostdata/'admin.token').read_text().strip()
 (data/'accord-connection.json').write_text(json.dumps({'schema':1,'authority':authority,'endpointFile':str(hostdata/'endpoints.json')}))
 def op(operation,args):
  req=urllib.request.Request(ep['coordinator']+'/v1/collaboration',data=json.dumps({'operation':operation,'args':args}).encode(),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'});return json.load(urllib.request.urlopen(req,timeout=5))
 op('session-report',{'key':'root','source':'claude','externalId':session,'title':'Duplicate observation','state':'working','sourceProgressAt':ms})
 op('session-report',{'key':'child','source':'claude','externalId':session+'/agent-review','title':'Review evaluation results','state':'working','sourceProgressAt':ms,'parentSession':{'source':'claude','externalId':session},'detail':'Checking accuracy and regressions'})
 op('session-report',{'key':'independent','source':'fixture','externalId':'independent','title':'Independent task','state':'working','sourceProgressAt':ms,'detail':'A separate task remains visible'})
 applog=(home/'app.log').open('w');proc=subprocess.Popen([app/'Contents/MacOS/Tessera','-ApplePersistenceIgnoreState','YES','-tessera.agentAPI','YES','-tessera.remoteEnabled','NO','-tessera.privacy','NO'],env=env,stdout=applog,stderr=applog)
 board=wait(lambda:json.loads((home/'board.json').read_text()),50)
 assert 'Evaluate the model' in board['visible'],board['visible'];assert 'Duplicate observation' not in board['visible'];assert 'Review evaluation results' not in board['visible'];assert 'Independent task' in board['visible'];assert any(v==['Review evaluation results'] for v in board['related'].values()),board['related'];assert board['taskSort']=='recent';assert board['counts']['working']==2,board['counts'];wait(lambda:(home/'board.png').is_file(),10)
 print(json.dumps({'status':'passed','home':str(home),'visible':board['visible'],'related':board['related'],'screenshot':str(home/'board.png')}))
 pathlib.Path('/tmp/tessera-task-ui-proof.json').write_text(json.dumps({'status':'passed','home':str(home),'visible':board['visible'],'related':board['related'],'screenshot':str(home/'board.png')}))
finally:
 for p in [proc,daemon]:
  if p and p.poll() is None:
   p.terminate()
   try:p.wait(timeout=15)
   except subprocess.TimeoutExpired:p.kill();p.wait()
 log.close()
