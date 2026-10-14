# Installation and runtime details

The user supplies modules compatible with the exact firmware. The Realtek integration assumes FleetConntrack FWDBYPS is mapped to **mark2 bit 0**, as on the inspected SP-GE3001. Other platforms may differ; the installer does not reassign global marks.

`install.sh` defaults to the latest stable release reported by the upstream GitHub API. Set `NFQWS2_VERSION=v1.0.5.2` to pin a release. The binary and all Lua files come from that same archive. The blobs and initial domain lists come from the latest nfqws2-keenetic release, resolved once per installation and recorded in `NFQWS2-KEENETIC-REF`. Set `NFQWS2_KEENETIC_REF` to pin a tag. TLS/QUIC profiles are maintained in this repository. Updates preserve the user's existing settings and profiles.

Downloads use verified HTTPS with the repository’s `cacert.pem` (Mozilla CA bundle distributed by curl). The firmware’s `/etc/cacert.pem` contains an ISP-specific root, so it is left untouched. Set `CURL_CA_BUNDLE` to use a different bundle. For installation without a checkout, place the repository’s bundle at `./cacert.pem` first. If `sha256sum` exists, the executable is compared with upstream's SHA256 manifest; otherwise verified HTTPS supplies transport authenticity and the expected SHA256 is recorded. `INSECURE=1` is explicit opt-in and requires a SHA256 tool; a checksum fetched through unverified TLS is not independent authentication. Installed MD5 checks detect local damage, not malicious replacement.

Local install uses `SOURCE_DIR=.` automatically from the checkout. Streamed installation defaults to `https://raw.githubusercontent.com/loskutov/nfqws2-rtk` and uses user-provided modules in `MODULES_DIR`. `PROJECT_REF` defaults to `master`; use a commit to pin project files.

Persistent layout:

```text
/var/config/nfqws2/{nfqws2,service.sh,settings,https.args,quic.args}
/var/config/nfqws2/{lua,blobs,modules,lists}/
/var/config/run_test.sh
```

Runtime logs, generated args, PIDs and active lists are under `/tmp/nfqws2`. Both TCP/443 TLS and UDP/443 QUIC are enabled. `ISP_INTERFACE="ppp0"` can contain space-separated provider interfaces. No client/subnet pinning is added. Multiple interfaces enable nfqws2's IPv4 bind fix, following nfqws2-keenetic.

Realtek-only early packet windows use connbytes and mark2 bit 0, in POSTROUTING before outbound queueing, and PREROUTING for replies. TCP defaults to 20 packets per direction; UDP to 15. nftables/Linux flowtable offload is not used. Generated packets carrying mark1 `0x40000000` are excluded from requeueing. Conntrack accounting is enabled for these windows; existing vendor checksum/liberal-TCP settings are left unchanged.

The supervisor repairs its dedicated `nfqws_pre` / `nfqws_post` chains and jumps every 30 seconds. A failed child is restarted after 30 seconds, with a three-failure limit per supervisor run. Stop removes only those chains/jumps, saves domains, and leaves modules loaded/accounting enabled. No global acceleration or watchdog controls are modified.

The active auto-list is saved only if changed, every 600 seconds and at clean stop, by staging and renaming a file on the config filesystem. The default persistent size limit is 256 KiB. Power failure may lose unsaved changes; rename is not a power-loss durability guarantee. Logs stay in RAM and are bounded by periodic rotation checks.

The boot hook is specific to the inspected firmware, whose rc35 executes `/var/config/run_test.sh`. Other firmware needs a suitable startup integration. Disable ours with `service.sh stop`, then rename our hook out of that exact path. The installer refuses to overwrite unrelated hooks. Updates retain `/var/config/nfqws2.previous`; archive it before another update. On failed new startup, old files are restored, with the service stopped.

Tested manually on SP-GE3001: module loading, TLS splitting/reassembly, sustained forwarded transfer, hardware-backed learned flows, supervisor recovery, firewall repair/cleanup, persistent installation and reboot startup. QUIC connectivity was also tested successfully.

The installer records the running kernel’s GNU build-ID notes, version and embedded config in `kernel.identity`. Startup checks it before module loading, and package updates preserve it and reject a changed kernel unless explicitly supplied with a new approval alongside rebuilt modules (see below). Missing build-ID notes/config also prevent startup; there is no version-only fallback. MD5 here detects accidental changes, not malicious firmware, and recording an identity does not prove the supplied modules are compatible.

After a firmware/kernel update, leave the service stopped until the two modules have been rebuilt and their ABI compatibility checked against that exact running kernel. Put those modules in `./modules/` on the ONT, then explicitly approve the new pairing and reinstall:

```sh
sh /var/config/nfqws2/service.sh stop
sh /var/config/nfqws2/kernel-id.sh > /tmp/kernel.identity &&
cp /tmp/kernel.identity ./modules/kernel.identity
sh install.sh
```

The installer accepts this explicit approval only when it matches the running kernel, installs the supplied modules and new approval together, and regenerates their checksums. It otherwise preserves the existing approval. Do not generate `modules/kernel.identity` just to bypass a mismatch: it records your compatibility decision, not an automatic ABI test. Archive any existing `nfqws2.previous` backup before another installation, as described above.

Before replacing the installation, stopping the existing service or creating the boot hook, the installer test-loads the candidate modules. A load-time panic therefore cannot activate the candidate for the next boot. Staged files may remain on flash, but are not referenced by the boot hook. Successfully loaded modules remain loaded if a later step fails.

Loads are recorded in RAM with module checksums, approved kernel identity and `/proc/modules` instance information. Already-loaded modules are reused only when that receipt matches; untracked or changed modules require a reboot before installation. No automatic unloading is attempted. Receipts assume modules are managed by this package; they are not an attestation against external module replacement. A successful test-load checks initialization only, not later packet processing.
