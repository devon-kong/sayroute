#!/usr/bin/env python3
"""Run real installer transactions in temporary Library trees; OS services are simulated.
No real launchctl, signing, network, clipboard or Accessibility operations occur.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NEW = 'com.devonkong.sayroute.bridge'
OLD = 'com.doubao.murmur.mirror'

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sayroute-installer-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.library = self.base / 'Library'
        self.package = self.base / 'package'
        shutil.copytree(ROOT / 'packaging/sayroute-bridge', self.package)
        self.bin = self.base / 'bin'; self.bin.mkdir()
        self.state = self.base / 'services.json'
        self.state.write_text(json.dumps({OLD: 123}))
        self.helper = self.library / 'Application Support/SayRoute/sayroute-bridge'
        self.agents = self.library / 'LaunchAgents'; self.agents.mkdir(parents=True)
        (self.agents / (OLD + '.plist')).write_bytes(b'legacy plist')
        legacy = self.library / 'Application Support/Doubao Murmur/murmur-mirror'
        legacy.parent.mkdir(parents=True); legacy.write_text('old binary')
        (self.package / 'sayroute-bridge').write_text('new binary')
        (self.package / 'sayroute-bridge').chmod(0o755)
        digest = hashlib.sha256(b'new binary').hexdigest()
        (self.package / 'sayroute-bridge.sha256').write_text(digest + '  sayroute-bridge\n')
        (self.package / 'BUILD-INFO.txt').write_text('helper_build=1.4.0 (20)\n')
        stub = '''#!/usr/bin/env python3
import json, pathlib, sys
base=pathlib.Path(__file__).resolve().parents[1]
state=base/'services.json'
s=json.loads(state.read_text())
name=pathlib.Path(sys.argv[0]).name
a=sys.argv[1:]
if name=='launchctl':
    label=a[1].split('/')[-1] if len(a)>1 else ''
    if a[0]=='print':
        if label not in s: sys.exit(3)
        print('pid = '+str(s[label]))
    elif a[0]=='bootout': s.pop(label,None)
    elif a[0]=='bootstrap':
        label=pathlib.Path(a[2]).stem
        if (base/'fail-bootstrap').exists() and label=='com.devonkong.sayroute.bridge': sys.exit(5)
        s[label]=456 if label=='com.devonkong.sayroute.bridge' else 123
    state.write_text(json.dumps(s))
elif name=='curl':
    if (base/'wrong-health').exists(): print('{"ok":true,"protocolVersion":2,"service":"legacy","processID":123}')
    else: print(json.dumps(dict(ok=True,protocolVersion=2,service='com.devonkong.sayroute.bridge',processID=456,helperBuild='1.4.0 (20)',accessibilityTrusted=False)))
elif name=='lipo': print('arm64 x86_64')
elif name=='lsof': print('456')
elif name=='PlistBuddy': pass
'''
        for name in ['launchctl','curl','lipo','lsof','codesign','PlistBuddy','sleep']:
            p=self.bin/name; p.write_text(stub); p.chmod(0o755)
        for p in self.package.iterdir():
            if p.suffix not in ['.command','.sh']: continue
            source=p.read_text().replace('${HOME}/Library', str(self.library)).replace('$HOME/Library',str(self.library))
            import re
            source=re.sub(r'/(?:usr/(?:bin|sbin|libexec)|bin)/(launchctl|curl|lipo|lsof|codesign|PlistBuddy|sleep)\b', lambda m:str(self.bin/m[1]),source)
            p.write_text(source)

    def run_script(self, script='install.command', *args):
        return subprocess.run(['/bin/zsh',str(self.package/script),*args],stdin=subprocess.DEVNULL, capture_output=True,text=True,timeout=15)

    def test_success_retires_legacy_and_keeps_backup(self):
        r=self.run_script(); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertFalse((self.agents/(OLD+'.plist')).exists())
        self.assertEqual(self.helper.read_text(),'new binary')
        self.assertNotIn(OLD,json.loads(self.state.read_text()))
        backups=list(self.helper.parent.glob('backups/*/legacy.plist'))
        self.assertEqual(len(backups),1)
        self.assertEqual(backups[0].read_bytes(),b'legacy plist')

    def test_failed_start_restores_old_service_and_files(self):
        (self.base/'fail-bootstrap').touch()
        r=self.run_script(); self.assertNotEqual(r.returncode,0)
        self.assertEqual((self.agents/(OLD+'.plist')).read_bytes(),b'legacy plist')
        self.assertFalse(self.helper.exists())
        self.assertIn(OLD,json.loads(self.state.read_text()))

    def test_wrong_health_cannot_claim_success(self):
        (self.base/'wrong-health').touch()
        r=self.run_script(); self.assertNotEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertFalse(self.helper.exists())
        self.assertIn(OLD,json.loads(self.state.read_text()))

    def test_explicit_rollback_restores_prior_installation(self):
        r=self.run_script(); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        backups=list(self.helper.parent.glob('backups/*/transaction-ready'))
        self.assertEqual(len(backups),1)
        r=self.run_script('rollback.command',str(backups[0].parent))
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertFalse(self.helper.exists())
        self.assertTrue((self.agents/(OLD+'.plist')).exists())
        self.assertIn(OLD,json.loads(self.state.read_text()))

    def test_failed_install_backup_cannot_replace_later_success(self):
        (self.base/'fail-bootstrap').touch()
        r=self.run_script(); self.assertNotEqual(r.returncode,0)
        stale=list(self.helper.parent.glob('backups/*/transaction-ready'))[0].parent
        (self.base/'fail-bootstrap').unlink()
        r=self.run_script(); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        r=self.run_script('rollback.command',str(stale))
        self.assertNotEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(self.helper.read_text(),'new binary')
        self.assertIn(NEW,json.loads(self.state.read_text()))
        self.assertNotIn(OLD,json.loads(self.state.read_text()))

    def test_rollback_must_follow_install_generation_even_with_identical_files(self):
        r=self.run_script(); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        first=list(self.helper.parent.glob('backups/*/transaction-ready'))[0].parent
        r=self.run_script(); self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        second=next(p.parent for p in self.helper.parent.glob('backups/*/transaction-ready') if p.parent!=first)
        r=self.run_script('rollback.command',str(first))
        self.assertNotEqual(r.returncode,0)
        self.assertIn(NEW,json.loads(self.state.read_text()))
        r=self.run_script('rollback.command',str(second))
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual(self.helper.read_text(),'new binary')
        r=self.run_script('rollback.command',str(first))
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertFalse(self.helper.exists())
        self.assertIn(OLD,json.loads(self.state.read_text()))

if __name__=='__main__': unittest.main()
