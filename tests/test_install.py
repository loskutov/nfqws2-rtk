#!/usr/bin/env python3
"""Installer transactions in temporary directories; no module/network actions."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nfqws2-rtk-test-')
        self.root = Path(self.tmp.name)
        self.config = self.root/'config'; self.config.mkdir()
        self.bin = self.root/'bin'; self.bin.mkdir()
        self.modules = self.root/'modules'; self.modules.mkdir()
        for name in ('xt_NFQUEUE', 'nfnetlink_queue'):
            (self.modules/(name+'.ko')).write_bytes(b'test module, never loaded')
        self.queue = self.root/'queue'; self.queue.write_text('')
        self.mark = self.root/'mark'; self.mark.touch()
        self.base = self.config/'nfqws2'
        self.hook = self.config/'run_test.sh'
        self.backup = self.config/'nfqws2.previous'
        self.fixture = self.root/'fixtures'; self.fixture.mkdir()
        self.version = 'v9.8.7'
        prefix = 'zapret2-'+self.version
        binary = b'fixture runtime: never executed'
        with tarfile.open(self.fixture/'runtime.tar.gz', 'w:gz') as tar:
            for name, data in {
                'binaries/linux-arm64/nfqws2': binary,
                'lua/zapret-lib.lua': b'-- fixture',
                'lua/zapret-antidpi.lua': b'-- fixture',
                'lua/zapret-auto.lua': b'-- fixture',
                'docs/LICENSE.txt': b'fixture license',
            }.items():
                info = tarfile.TarInfo(prefix+'/'+name); info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        (self.fixture/'release.json').write_text(json.dumps({'tag_name': self.version}))
        (self.fixture/'upstream.sha256').write_text(hashlib.sha256(binary).hexdigest()+'  '+prefix+'/binaries/linux-arm64/nfqws2\n')
        mocks = {
            'df': 'printf "Filesystem Blocks Used Available Use%% Mounted\\nmock 99999 1 %s 1%% config\\n" "${FREE_KB:-65536}"',
            'modinfo': 'echo "5.10.226 SMP mod_unload aarch64"',
            'service': '''case "$2" in
start) [ "${FAIL_START:-0}" = 0 ] || exit 1; touch "$SERVICE_STATE";;
stop) rm -f "$SERVICE_STATE";;
*) exit 99;;
esac''',
        }
        for name, body in mocks.items():
            p = self.bin/name; p.write_text('#!/bin/sh\n'+body+'\n'); p.chmod(0o755)
        fetch = self.bin/'curl'
        fetch.write_text('''#!/usr/bin/env python3
import os,pathlib,sys,shutil
a=sys.argv[1:];url=next(x for x in a if x.startswith('https://'));out=pathlib.Path(a[a.index('-o')+1]);r=pathlib.Path(os.environ['FIXTURES'])
if os.environ.get('FAIL_FETCH')=='1':sys.exit(22)
if url.endswith('/releases/latest'):shutil.copyfile(r/'release.json',out)
elif url.endswith('.tar.gz'):shutil.copyfile(r/'runtime.tar.gz',out)
elif url.endswith('/sha256sum.txt'):shutil.copyfile(r/'upstream.sha256',out)
elif url.endswith('.list'):out.write_text('example.com\\n')
elif url.endswith('.bin'):out.write_bytes(b'fixture blob')
else:raise Exception(url)
'''); fetch.chmod(0o755)
        text = (ROOT/'install.sh').read_text()
        text = text.replace('/var/config', str(self.config)).replace('/tmp/nfqws2-rtk-install.', str(self.root/'work.'))
        text = text.replace('/proc/fc/ctrl/skbmark_fwdByPs', str(self.mark)).replace('/proc/net/netfilter/nfnetlink_queue', str(self.queue))
        text = text.replace('$(id -u)', '0').replace('$(uname -m)', 'aarch64').replace('$(uname -r)', '5.10.226')
        text = text.replace('modinfo -F', '"$TEST_MODINFO" -F').replace('df -k', '"$TEST_DF" -k').replace('sh "$BASE/service.sh"', '"$TEST_SERVICE" "$BASE/service.sh"')
        self.script = self.root/'install.sh'; self.script.write_text(text)
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'], SOURCE_DIR=str(ROOT),
            MODULES_DIR=str(self.modules), FIXTURES=str(self.fixture), SERVICE_STATE=str(self.root/'running'),
            TEST_MODINFO=str(self.bin/'modinfo'), TEST_DF=str(self.bin/'df'), TEST_SERVICE=str(self.bin/'service'))

    def tearDown(self):
        self.tmp.cleanup()

    def run_install(self, success=True, **extra):
        p = subprocess.run(['busybox', 'sh', str(self.script)], env=dict(self.env, **extra), capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode == 0, success, p.stdout+p.stderr)
        return p

    def test_latest_install_and_update(self):
        self.run_install()
        self.assertEqual((self.base/'VERSION').read_text().strip(), self.version)
        self.assertTrue(self.hook.exists())
        (self.base/'lists/auto.list').write_text('learned.example\n')
        old = (self.base/'settings').read_text().replace('NFQUEUE_NUM=300', 'NFQUEUE_NUM=301')
        (self.base/'settings').write_text(old)
        self.run_install()
        self.assertEqual((self.base/'settings').read_text(), old)
        self.assertEqual((self.base/'lists/auto.list').read_text(), 'learned.example\n')
        self.assertTrue(self.backup.exists())
        self.run_install(False)

    def test_preconditions(self):
        self.queue.write_text('300 123 0 2 65535 0 0 0 1\n')
        self.run_install(False); self.assertFalse(self.base.exists())
        self.queue.write_text(''); self.hook.write_text('someone else\n')
        self.run_install(False); self.assertEqual(self.hook.read_text(), 'someone else\n')
        self.hook.unlink(); self.run_install(False, FREE_KB='1')
        self.assertFalse(self.base.exists())

    def test_fetch_failure_and_checksum_failure(self):
        self.run_install(False, FAIL_FETCH='1'); self.assertFalse(self.hook.exists())
        (self.fixture/'upstream.sha256').write_text('0'*64+'  zapret2-'+self.version+'/binaries/linux-arm64/nfqws2\n')
        self.run_install(False); self.assertFalse(self.base.exists())

    def test_startup_rollback(self):
        self.run_install(False, FAIL_START='1')
        self.assertFalse(self.base.exists()); self.assertFalse(self.hook.exists())
        self.run_install(); (self.base/'marker').write_text('previous version')
        self.run_install(False, FAIL_START='1')
        self.assertEqual((self.base/'marker').read_text(), 'previous version')
        self.assertFalse(self.backup.exists()); self.assertTrue(self.hook.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
