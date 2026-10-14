# nfqws2-rtk

nfqws2 for Realtek-based ONTs, following [nfqws2-keenetic](https://github.com/nfqws/nfqws2-keenetic). **rtk** stands for both Realtek and Rostelecom.

## Requirements

- **Physical access to the device.**
- **Superadmin credentials.** RotekConfigTool may help obtain them. Log in to the web UI with these credentials and enable Telnet access, then connect to the ONT’s root shell.
- **`xt_NFQUEUE.ko` and `nfnetlink_queue.ko` built for your firmware.** These are supplied by the user, not distributed here.

Vendor patches and kernel configuration change internal structure layouts, so modules for another firmware can be incompatible even when the kernel version matches. An LLM can help adapt Realtek SDK patches and compare the stock modules and kernel image against a candidate build. Give it the original kernel config and binaries, and verify its conclusions against the actual layouts and exports. See [building the modules](docs/modules.md).

Runtime selection supports AArch64 and 32-bit MIPS in either byte order. **MIPS support, including RTL9607C, has never been tested on hardware and is probably broken.** It assumes the same FleetConntrack `MARK2` mechanism and boot hook as the tested RTL9607F firmware.

Tested on SP-GE3001 / RTL9607F, Linux 5.10.226: TCP/TLS and QUIC. Hardware acceleration is retained after the initial packets.

## Install

Place your modules in `modules/`, copy the checkout to the ONT, and run:

```sh
sh install.sh
```

The included `cacert.pem` supplies public CA certificates missing from the firmware.

The installer fetches the latest upstream nfqws2 and matching Lua files, installs the service, and configures firewall rules and boot startup.

## Configure

Follow the [nfqws2-keenetic configuration guide](https://github.com/nfqws/nfqws2-keenetic#настройка). Our files are under `/var/config/nfqws2/`:

- `settings`: `ISP_INTERFACE`, queue number, ports and Realtek packet windows.
- `https.args`, `quic.args`: native nfqws2 strategy arguments.
- `lists/`: `user.list`, `auto.list`, `exclude.list`.

Defaults: `ISP_INTERFACE="ppp0"`, queue 300, TCP/443 and UDP/443. Traffic is selected by provider interface, without a fixed LAN subnet. This is a TLS/QUIC adaptation, not the full Entware/NDM package.

```sh
sh /var/config/nfqws2/service.sh restart  # also: start, stop, status, save
```

Logs and the active auto-list live in `/tmp/nfqws2/`. Changed domains are saved to flash every ten minutes. Stopping the service does not disable boot startup; rename our `/var/config/run_test.sh` to disable it.

[Installation details](docs/install.md).
