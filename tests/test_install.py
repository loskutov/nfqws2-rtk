#!/usr/bin/env python3
"""Installer transactions in temporary directories; no module/network actions."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import struct
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
        self.notes = self.root/'kernel.notes'
        self.notes.write_bytes(struct.pack('<III', 4, 20, 3)+b'GNU\0'+bytes(range(20)))
        self.kernel_version = self.root/'kernel.version'; self.kernel_version.write_text('Linux test build A\n')
        self.kernel_config = self.root/'kernel.config'; self.kernel_config.write_bytes(b'config A')
        self.source = self.root/'source'; self.source.mkdir()
        shutil.copytree(ROOT/'src', self.source/'src')
        for name in ['LICENSE', 'cacert.pem']: shutil.copyfile(ROOT/name, self.source/name)
        helper = self.source/'src/kernel-id.sh'
        helper.write_text(helper.read_text().replace('/sys/kernel/notes', str(self.notes)).replace('/proc/version', str(self.kernel_version)).replace('/proc/config.gz', str(self.kernel_config)))
        self.loaded = self.root/'proc-modules'; self.loaded.write_text('')
        self.receipts = self.root/'module-receipts'
        loader = self.source/'src/module-load.sh'
        loader.write_text(loader.read_text().replace('/proc/modules', str(self.loaded)).replace('/tmp/nfqws2-module-loads', str(self.receipts)).replace('insmod "$modules/$module.ko"', '\"$TEST_INSMOD\" "$modules/$module.ko"'))
        self.version = 'v9.8.7'
        prefix = 'zapret2-'+self.version
        binary = b'fixture runtime: never executed'
        with tarfile.open(self.fixture/'runtime.tar.gz', 'w:gz') as tar:
            for name, data in {
                'binaries/linux-arm64/nfqws2': binary,
                'binaries/linux-mips/nfqws2': b'big endian fixture',
                'binaries/linux-mipsel/nfqws2': b'little endian fixture',
                'lua/zapret-lib.lua': b'-- fixture',
                'lua/zapret-antidpi.lua': b'-- fixture',
                'lua/zapret-auto.lua': b'-- fixture',
                'docs/LICENSE.txt': b'fixture license',
            }.items():
                info = tarfile.TarInfo(prefix+'/'+name); info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        (self.fixture/'release.json').write_text(json.dumps({'tag_name': self.version}))
        (self.fixture/'upstream.sha256').write_text(hashlib.sha256(binary).hexdigest()+'  '+prefix+'/binaries/linux-arm64/nfqws2\n')
        with (self.fixture/'upstream.sha256').open('a') as f:
            for arch, data in [('linux-mips', b'big endian fixture'), ('linux-mipsel', b'little endian fixture')]:
                f.write(hashlib.sha256(data).hexdigest()+'  '+prefix+'/binaries/'+arch+'/nfqws2\n')
        mocks = {
            'df': 'printf "Filesystem Blocks Used Available Use%% Mounted\\nmock 99999 1 %s 1%% config\\n" "${FREE_KB:-65536}"',
            'modinfo': 'printf \"%s5.10.226 SMP mod_unload aarch64\\n\" \"${MODINFO_PREFIX:-}\"',
            'service': '''case "$2" in
start) [ "${FAIL_START:-0}" = 0 ] || exit 1; touch "$SERVICE_STATE";;
stop) rm -f "$SERVICE_STATE";;
*) exit 99;;
esac''',
        }
        for name, body in mocks.items():
            p = self.bin/name; p.write_text('#!/bin/sh\n'+body+'\n'); p.chmod(0o755)
        insmod = self.bin/'insmod-test'
        insmod.write_text("""#!/usr/bin/env python3
import os,pathlib,sys
name=pathlib.Path(sys.argv[1]).stem
with open(os.environ['LOAD_LOG'],'a') as f:f.write(name+'\\n')
if os.environ.get('FAIL_LOAD')==name:sys.exit(1)
p=pathlib.Path(os.environ['PROC_MODULES'])
with p.open('a') as f:f.write(name+' 16384 0 - Live 0xffffffc001234000 (O)\\n')
"""); insmod.chmod(0o755)
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
        text = text.replace('$(id -u)', '0').replace('$(uname -m)', '${TEST_ARCH:-aarch64}').replace('$(uname -r)', '5.10.226')
        text = text.replace('modinfo -F', '"$TEST_MODINFO" -F').replace('df -k', '"$TEST_DF" -k').replace('sh "$BASE/service.sh"', '"$TEST_SERVICE" "$BASE/service.sh"')
        text = text.replace("$(hexdump -v -n 6 -e '1/1 \"%02x\"' /bin/busybox)", '${TEST_ELF:-7f454c460102}')
        self.script = self.root/'install.sh'; self.script.write_text(text)
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'], SOURCE_DIR=str(self.source),
            MODULES_DIR=str(self.modules), FIXTURES=str(self.fixture), SERVICE_STATE=str(self.root/'running'),
            TEST_INSMOD=str(insmod), LOAD_LOG=str(self.root/'load.log'), PROC_MODULES=str(self.loaded), TEST_MODINFO=str(self.bin/'modinfo'), TEST_DF=str(self.bin/'df'), TEST_SERVICE=str(self.bin/'service'))

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

    def test_busybox_prefixed_vermagic(self):
        self.run_install(MODINFO_PREFIX='vermagic:       ')
        self.assertTrue(self.hook.exists())

    def test_mips_byte_order(self):
        self.run_install(TEST_ARCH='mips', TEST_ELF='7f454c460102')
        self.assertEqual((self.base/'nfqws2').read_bytes(), b'big endian fixture')
        self.run_install(TEST_ARCH='mips', TEST_ELF='7f454c460101')
        self.assertEqual((self.base/'nfqws2').read_bytes(), b'little endian fixture')

    def test_architecture_rejection(self):
        self.run_install(False, TEST_ARCH='x86_64')
        self.run_install(False, TEST_ARCH='mips', TEST_ELF='7f454c460202')
        self.assertFalse(self.base.exists())

    def test_kernel_change_blocks_update(self):
        self.run_install()
        approval = (self.base/'kernel.identity').read_bytes()
        self.kernel_version.write_text('Linux test build B\n')
        self.run_install(False)
        self.assertEqual((self.base/'kernel.identity').read_bytes(), approval)
        self.assertTrue((self.root/'running').exists())
        self.assertFalse(self.backup.exists())

    def test_explicit_rebuilt_module_approval(self):
        self.run_install()
        self.kernel_version.write_text('Linux test build B\n')
        self.loaded.write_text('')  # new kernel boot; old modules no longer loaded
        shutil.rmtree(self.receipts)
        for name in ('xt_NFQUEUE', 'nfnetlink_queue'):
            (self.modules/(name+'.ko')).write_bytes(b'rebuilt fixture module')
        approval = subprocess.check_output(['busybox', 'ash', str(self.source/'src/kernel-id.sh')])
        (self.modules/'kernel.identity').write_bytes(approval)
        self.run_install()
        self.assertEqual((self.base/'kernel.identity').read_bytes(), approval)
        self.assertEqual((self.base/'modules/xt_NFQUEUE.ko').read_bytes(), b'rebuilt fixture module')

    def test_invalid_explicit_approval_rejected(self):
        (self.modules/'kernel.identity').write_text('wrong approval\n')
        self.run_install(False)
        self.assertFalse(self.base.exists())

    def test_missing_build_id_blocks_install(self):
        self.notes.write_bytes(b'no build id')
        self.run_install(False)
        self.assertFalse(self.base.exists())

    def test_kernel_guard_blocks_service_start(self):
        self.run_install()
        service = self.root/'service-check.sh'
        text = (ROOT/'src/service.sh').read_text().replace('/tmp/nfqws2', str(self.root/'run')).replace('/var/config/nfqws2', str(self.base)).replace('$(id -u)', '0')
        service.write_text(text)
        # Identical release/version, changed kernel build ID: fail before modinfo,
        # insmod, daemon launch, accounting or firewall setup.
        self.notes.write_bytes(struct.pack('<III', 4, 20, 3)+b'GNU\0'+bytes(range(1,21)))
        p = subprocess.run(['busybox', 'ash', str(service), 'start'], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('kernel changed', p.stderr)
        self.assertFalse((self.root/'run').exists())
        (self.base/'kernel.identity').unlink()
        p = subprocess.run(['busybox', 'ash', str(service), 'start'], env=self.env, capture_output=True, text=True)
        self.assertIn('identity missing', p.stderr)

    def test_load_failure_precedes_persistence(self):
        self.run_install(False, FAIL_LOAD='nfnetlink_queue')
        self.assertFalse(self.base.exists())
        self.assertFalse(self.hook.exists())
        self.assertFalse((self.root/'running').exists())

    def test_changed_loaded_module_rejected_before_stop(self):
        self.run_install()
        (self.modules/'xt_NFQUEUE.ko').write_bytes(b'different module')
        self.run_install(False)
        self.assertTrue((self.root/'running').exists())
        self.assertFalse(self.backup.exists())
        self.assertEqual((self.base/'modules/xt_NFQUEUE.ko').read_bytes(), b'test module, never loaded')

    def test_untracked_loaded_module_rejected(self):
        self.loaded.write_text('xt_NFQUEUE 16384 0 - Live 0xffffffc001234000 (O)\n')
        self.run_install(False)
        self.assertFalse((self.root/'load.log').exists())
        self.assertFalse(self.hook.exists())

    def test_loaded_module_refcount_changes_allowed(self):
        self.run_install()
        self.loaded.write_text(self.loaded.read_text().replace('16384 0', '16384 4'))
        self.run_install()
        self.assertEqual((self.root/'load.log').read_text().splitlines(), ['xt_NFQUEUE', 'nfnetlink_queue'])

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
