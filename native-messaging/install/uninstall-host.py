#!/usr/bin/env python3
import json
from pathlib import Path
base=Path.home()/'Library/Application Support'
for browser in ['Google/Chrome','Google/Chrome for Testing','Chromium']:
 p=base/browser/'NativeMessagingHosts/com.k3v88.mailfocus.host.json'
 if p.exists() and not p.is_symlink():
  data=json.loads(p.read_text())
  if data.get('name')=='com.k3v88.mailfocus.host' and data.get('description')=='MailFocus local Mac bridge':p.unlink();print('Removed',p)
print('Microsoft credentials and sync state are removed separately using Disconnect in the Mac app. No other host or browser profile was changed.')
