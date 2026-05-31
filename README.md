# KernelSU Builder for Samsung Galaxy A04 (SM-A045F)

Build a custom Linux kernel with KernelSU root for the Samsung Galaxy A04.

**Device:** SM-A045F (mt6765 / Helio P35, arm64)  
**Base kernel:** Linux 4.19.191  
**Toolchain:** Clang r383902 (12.0.5) + GCC 4.9 aarch64  
**Kernel source:** [rsuntk-oss/android_kernel_samsung_a04m](https://github.com/rsuntk-oss/android_kernel_samsung_a04m/tree/latest-B) (branch `latest-B`)

## Quick Start

1. **Open in Codespace**  
   Click "Code" → "Open with Codespaces" → "New codespace"

2. **Run the build**  
   ```bash
   chmod +x build_kernel.sh
   ./build_kernel.sh
   ```
   This will download the kernel source, toolchains, integrate KernelSU, configure, and build.

3. **Get the outputs**  
   After the build completes, check the `output/` directory:
   - `Image` — raw kernel image
   - `boot.img` — Android boot image (if `mkbootimg` available)
   - `KernelSU_A04_boot.tar.md5` — Odin-flashable tar
   - `KernelSU_A04_flashable.zip` — TWRP-flashable zip

## Flashing

### Via Odin (recommended)
1. Boot into Download Mode (**Vol Down + Vol Up**, connect USB)
2. Open Odin on Windows
3. Place `KernelSU_A04_boot.tar.md5` in the **AP** slot
4. Ensure only **Auto Reboot** and **F. Reset Time** are checked
5. Click **Start**

### Via TWRP
1. Flash `KernelSU_A04_flashable.zip`

## After Flashing
1. Download the KernelSU APK from [rsuntk/KernelSU releases](https://github.com/rsuntk/KernelSU/releases)
2. Install and grant root permissions via the app

## 🔒 Low Detectability

This build includes several hiding features baked into the kernel:

| Setting | Value | Why |
|---|---|---|
| Module name | Built-in (`CONFIG_KSU=y`) | Nothing appears in `/proc/modules` |
| Kernel version | `-th-v2` | Blends with stock `TragicHorizon` style |
| Manager package | `com.wssyncmldm` | Masquerades as Samsung FW update app |
| KSU debug | OFF | No suspicious kernel log spam |

### After flashing, also do:
1. **Open KernelSU Manager** → **Settings** → enable **"Hide"** for all user apps
2. **Enable Allowlist mode** — only authorized apps get root
3. Install **Zygisk Assistant** or **Zygisk Next** module for process-level hiding
4. Rename the KernelSU APK to something innocuous (e.g. `Settings.apk`)
5. For banking apps: use KernelSU's per-app "Hide" toggle

## ⚠️ Warnings
- Flashing a custom kernel **voids your warranty** and may trip Knox
- Ensure your device is **SM-A045F** (Galaxy A04) before flashing
- Backup your data before proceeding
- You accept all risk

## How It Works
- Uses the `rsuntk-oss/android_kernel_samsung_a04m` tree (mt6765 platform, same as A04)
- Integrates KernelSU via `rsuntk/KernelSU` with 4.19-compatibility
- Replaces the mtk connectivity module for WiFi support
- Disables Samsung security knobs (DEFEX, PROCA, FIVE, RKP, TIMA, etc.)
- Sets SELinux permissive for KernelSU compatibility
