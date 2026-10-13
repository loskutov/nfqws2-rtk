# Building the two modules

Prefer the **matching vendor kernel tree, configuration, compiler and Module.symvers**. Same Linux version and vermagic are insufficient: these modules use internal netdevice, skb, netns and netfilter layouts.

In a separate build directory, configure these options as modules:

```text
CONFIG_NETFILTER_NETLINK_QUEUE=m
CONFIG_NETFILTER_XT_TARGET_NFQUEUE=m
```

Then build from the matching configured vendor source/build tree:

```sh
make -C "$KERNEL_SRC" O="$KERNEL_BUILD" ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- olddefconfig modules_prepare
make -C "$KERNEL_SRC" O="$KERNEL_BUILD" ARCH=arm64 \
  CROSS_COMPILE=aarch64-linux-gnu- M=net/netfilter modules

aarch64-linux-gnu-strip --strip-debug \
  "$KERNEL_BUILD/net/netfilter/xt_NFQUEUE.ko" \
  "$KERNEL_BUILD/net/netfilter/nfnetlink_queue.ko"
```

Use the vendor toolchain prefix when available. `modules_prepare` does not generate a complete Module.symvers; use the matching vendor exports/build output, especially with MODVERSIONS. Keep unstripped artifacts offline. Do not use `strip --strip-all` or discard relocation/symbol tables required by the loader.

If vendor sources are unavailable, [BPI-RT2's Realtek SDK](https://github.com/jf-xf/BPI-RT2/tree/74fcf31586353515e1f41eaa1dadc6d0b6405af6/rtk_openwrt/target/linux/realtek_bb) is a useful **reference**, not a guaranteed matching tree. Its patches target older 5.10 revisions; applying all patches blindly is insufficient.

Our investigated SP-GE3001 required Realtek header reconstruction and restoring `CONFIG_WIRELESS_EXT`, which an upstream-only config normalization lost. Binary evidence included `nf_conn.ext` at 192 instead of upstream 184, and netdevice `header_ops` at 520 instead of 504. Not every discrepancy affects NFQUEUE; trace the actual accesses, callback signatures, and inline helpers. Realtek skb private tails also differed. We checked relevant boundaries against stock modules and the exact kernel image, not just imported symbol names.

## Using an LLM to reconstruct a build

Provide the model with the original kernel configuration, stock networking modules, and, if available, the exact kernel image and related Realtek SDK sources. Ask it to work in a separate tree and:

1. Compare the vendor configuration with the upstream-normalized configuration, including options lost because vendor drivers are missing.
2. Port the relevant SDK patches, then trace actual structure accesses and callbacks in the stock modules and kernel disassembly.
3. Check the candidate NFQUEUE modules against the layouts and exports used by the running firmware. Separate compiler code-generation differences from ABI differences.

This is useful assistance, not an automatic compatibility guarantee. Verify proposed offsets and patches using source, `objdump`, `readelf`, and DWARF/`pahole` where available. Missing data names in `/proc/kallsyms` with `KALLSYMS_ALL=n` do not prove missing exports. Successful module loading alone does not prove runtime safety. Have physical access to the device when testing modules.
