#!/usr/bin/env python3
"""Register the actual unpacked extension ID; no invented IDs or wildcards."""
import argparse,json,os,re,stat
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--extension-id',required=True)
parser.add_argument('--app',type=Path,default=Path(__file__).resolve().parents[2]/'build/OutlookFocus.app')
parser.add_argument('--browser',choices=['chrome','chrome-testing','chromium'],default='chrome')
args=parser.parse_args()
if not re.fullmatch('[a-p]{32}',args.extension_id):parser.error('Copy the real 32-letter ID from chrome://extensions.')
app=args.app.expanduser().resolve();executable=app/'Contents/MacOS/OutlookFocusNativeHost'
if not executable.is_file() or not os.access(executable,os.X_OK):parser.error('Build OutlookFocus first or provide --app pointing to the installed app.')
base=Path.home()/'Library/Application Support'
support=base/'OutlookFocus'
if support.is_symlink():parser.error('Refusing a symlinked app data directory.')
support.mkdir(mode=0o700,parents=True,exist_ok=True)
if support.stat().st_uid!=os.getuid():parser.error('App data directory is owned by another user.')
support.chmod(0o700)
origins_file=support/'allowed-origins.json'
origins=[]
if origins_file.exists():
 if origins_file.is_symlink() or origins_file.stat().st_uid!=os.getuid():parser.error('Unsafe origin configuration.')
 origins=json.loads(origins_file.read_text())
 if not isinstance(origins,list) or any(not isinstance(o,str) or not re.fullmatch(r'chrome-extension://[a-p]{32}/',o) for o in origins):parser.error('Existing origin configuration is invalid; inspect it manually.')
origin='chrome-extension://'+args.extension_id+'/'
origins=sorted(set(origins+[origin]))
browser_path={'chrome':'Google/Chrome','chrome-testing':'Google/Chrome for Testing','chromium':'Chromium'}[args.browser]
directory=base/browser_path/'NativeMessagingHosts';directory.mkdir(parents=True,exist_ok=True)
manifest_file=directory/'com.k3v88.outlookfocus.host.json'
if manifest_file.exists():
 if manifest_file.is_symlink():parser.error('Refusing a symlinked native manifest.')
 old=json.loads(manifest_file.read_text())
 if old.get('name')!='com.k3v88.outlookfocus.host' or old.get('description')!='OutlookFocus local Mac bridge':parser.error('Existing native manifest is unrelated; refusing to overwrite it.')
manifest={'name':'com.k3v88.outlookfocus.host','description':'OutlookFocus local Mac bridge','path':str(executable),'type':'stdio','allowed_origins':origins}
# Atomic user-owned writes; never touch other hosts or Chrome profile contents.
for target,value,mode in [(origins_file,origins,0o600),(manifest_file,manifest,0o644)]:
 temporary=target.with_name(target.name+'.outlookfocus-tmp')
 fd=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL,mode)
 try:
  with os.fdopen(fd,'w') as stream:json.dump(value,stream,indent=2);stream.write('\n')
  os.replace(temporary,target);target.chmod(mode)
 finally:
  if temporary.exists():temporary.unlink()
print('Registered native host:',manifest_file)
print('Verified allowed extension origin:',origin)
print('Open OutlookFocus.app, then click Retry Connection in the extension.')
