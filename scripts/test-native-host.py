#!/usr/bin/env python3
"""Exercise actual host framing and app IPC without Microsoft or user profile changes."""
import json,os,selectors,struct,subprocess,tempfile,time,uuid
from pathlib import Path
root=Path(__file__).resolve().parents[1]
binary=root/'.build/debug/MailFocusNativeHost';fixture=root/'.build/debug/BridgeFixture'
# This is a synthetic origin only for a non-browser protocol fixture, never an installed extension ID.
origin='chrome-extension://'+'a'*32+'/'
def send(process,message):
 data=json.dumps(message).encode();process.stdin.write(struct.pack('=I',len(data))+data);process.stdin.flush()
def receive(process):
 selector=selectors.DefaultSelector();selector.register(process.stdout,selectors.EVENT_READ)
 if not selector.select(5):raise AssertionError('Native host response timeout')
 prefix=process.stdout.read(4)
 if len(prefix)!=4:raise AssertionError('Missing native prefix')
 size=struct.unpack('=I',prefix)[0];assert 0<size<=65536
 data=process.stdout.read(size);assert len(data)==size
 return json.loads(data)
with tempfile.TemporaryDirectory(prefix='mailfocus-wire-',dir='/private/tmp') as temporary:
 support=Path(temporary);support.chmod(0o700)
 (support/'allowed-origins.json').write_text(json.dumps([origin]));(support/'allowed-origins.json').chmod(0o600)
 env={**os.environ,'MAILFOCUS_TEST_SUPPORT_DIR':str(support)}
 bridge=subprocess.Popen([str(fixture),str(support)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 try:
  assert bridge.stderr.readline().strip()==b'BRIDGE_READY'
  host=subprocess.Popen([str(binary),origin],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
  try:
   status=receive(host);assert status['type']=='connection.status' and status['payload']['connected']
   event={'v':1,'type':'ping','id':str(uuid.uuid4()),'timestamp':'2026-11-18T00:00:00Z','payload':{}}
   send(host,event);reply=receive(host);assert reply['type']=='pong' and reply['id']==event['id']
   forbidden={**event,'id':str(uuid.uuid4()),'payload':{'accessToken':'test-forbidden-field'}}
   send(host,forbidden);reply=receive(host);assert reply['payload']['connected'] is False
  finally:
   host.stdin.close();host.wait(timeout=5)
  bad=subprocess.Popen([str(binary),'chrome-extension://'+'b'*32+'/'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
  reply=receive(bad);assert reply['payload']['connected'] is False;bad.stdin.close();assert bad.wait(timeout=5)!=0
 finally:
  bridge.terminate();bridge.wait(timeout=5)
print('PASS: compiled host framing, handshake, app IPC, ping/pong, payload rejection, origin rejection.')
