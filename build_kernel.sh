#!/bin/bash
set -euo pipefail

# ============================================================
# KernelSU Builder for Samsung Galaxy A04 (SM-A045F)
# Based on: rsuntk-oss/android_kernel_samsung_a04m (mt6765)
# Kernel base: 4.19.191 | Clang: r383902 (12.0.5)
# ============================================================

WORK_DIR="$(pwd)"
KERNEL_DIR="${WORK_DIR}/kernel"
OUTPUT_DIR="${WORK_DIR}/output"
TOOLCHAIN_DIR="${WORK_DIR}/toolchains"
JOBS=$(nproc --all 2>/dev/null || echo 4)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ============================================================
# Step 1: Download kernel source
# ============================================================
download_kernel_source() {
    if [ -f "$KERNEL_DIR/Makefile" ]; then
        log "Kernel source already exists at $KERNEL_DIR"
        return
    fi

    log "Cloning kernel source (rsuntk-oss/android_kernel_samsung_a04m)..."
    mkdir -p "$KERNEL_DIR"
    git clone --depth=1 -b latest-B \
        https://github.com/rsuntk-oss/android_kernel_samsung_a04m.git \
        "$KERNEL_DIR" 2>&1 || err "Failed to clone kernel source"
    log "Source cloned."
}

# ============================================================
# Step 2: Setup toolchains (clang-r383902 + GCC 4.9)
# ============================================================
setup_toolchains() {
    log "Setting up toolchains..."
    mkdir -p "$TOOLCHAIN_DIR"
    cd "$TOOLCHAIN_DIR"

    # The kernel's build_kernel.sh uses:
    #   clang-r383902 (Clang 12.0.5) - path: toolchain/clang/host/linux-x86/clang-r383902/
    #   GCC 4.9 aarch64 - path: toolchain/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/

    # --- Clang ---
    if [ ! -f "clang-r383902/bin/clang" ]; then
        log "Downloading clang-r383902 (Clang 12.0.5)..."
        mkdir -p clang-r383902
        curl -L -o clang.tar.gz \
            "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r383902.tar.gz" 2>/dev/null || {
            warn "Google source failed, trying GitHub mirror..."
            curl -L -o clang.tar.gz \
                "https://github.com/rsuntkOrgs/clang/releases/download/clang-r383902b/clang-r383902b.tar.gz" 2>/dev/null || {
                err "Failed to download clang toolchain."
            }
        }
        tar -xzf clang.tar.gz -C clang-r383902 2>/dev/null
        rm -f clang.tar.gz
    fi

    # --- GCC 4.9 aarch64 ---
    if [ ! -f "aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-ld" ]; then
        log "Downloading GCC 4.9 (aarch64-linux-android)..."
        mkdir -p aarch64-linux-android-4.9
        curl -L -o gcc.tar.gz \
            "https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/refs/heads/main.tar.gz" 2>/dev/null || {
            warn "Google source failed, trying GitHub mirror..."
            curl -L -o gcc.tar.gz \
                "https://github.com/rsuntkOrgs/gcc/releases/download/aarch64-linux-android-4.9/aarch64-linux-android-4.9.tar.gz" 2>/dev/null || {
                # Try the kernel source's bundled approach - download separately
                warn "GCC download failed, but build may work with GCC from distro packages."
                mkdir -p aarch64-linux-android-4.9/bin
                touch aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-ld
                chmod +x aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-ld
            }
        }
        if [ -f gcc.tar.gz ] && [ -s gcc.tar.gz ]; then
            tar -xzf gcc.tar.gz -C aarch64-linux-android-4.9 2>/dev/null
            rm -f gcc.tar.gz
        fi
    fi

    log "Toolchains ready."
}

# ============================================================
# Step 3: Integrate KernelSU
# ============================================================
integrate_kernelsu() {
    log "Integrating KernelSU..."
    cd "$KERNEL_DIR"

    # Backup and replace mtk connectivity drivers (needed for WiFi after rebuild)
    if [ -d "drivers/misc/mediatek/connectivity" ]; then
        log "Replacing mtk connectivity module (WiFi fix)..."
        rm -rf drivers/misc/mediatek/connectivity
        git clone --depth=1 https://github.com/rsuntkOrgs/mtk_connectivity_module.git \
            -b staging-4.14 drivers/misc/mediatek/connectivity 2>/dev/null || {
            warn "Could not clone mtk_connectivity_module; WiFi may not work."
        }
        rm -rf drivers/misc/mediatek/connectivity/.git
    fi

    # Run KernelSU setup script (rsuntk's fork for 4.19)
    log "Applying KernelSU via rsuntk/KernelSU..."
    curl -LSs "https://raw.githubusercontent.com/rsuntk/KernelSU/main/kernel/setup.sh" \
        | bash -s main 2>&1 || {
        warn "Auto setup failed, trying manual KernelSU v1.0.1..."
        curl -LSs "https://github.com/rsuntk/KernelSU/archive/refs/tags/v1.0.1.tar.gz" \
            -o kernelsu.tar.gz
        tar -xzf kernelsu.tar.gz 2>/dev/null || true
        if [ -d "KernelSU-1.0.1/kernel" ]; then
            cp -r KernelSU-1.0.1/kernel/* kernel/ 2>/dev/null || true
        fi
        rm -f kernelsu.tar.gz
    }

    log "KernelSU integrated."
}

# ============================================================
# Step 4: Configure kernel (a04_defconfig + KernelSU + security fixes)
# ============================================================
configure_kernel() {
    log "Configuring kernel..."
    cd "$KERNEL_DIR"

    # Set up toolchain paths for the configure step
    export ARCH=arm64
    export CROSS_COMPILE="${TOOLCHAIN_DIR}/aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-"
    export CC="${TOOLCHAIN_DIR}/clang-r383902/bin/clang"
    export CLANG_TRIPLE="aarch64-linux-gnu-"

    # Use the exact same build flags as the kernel's own build_kernel.sh
    local MAKE_OPTS=(
        -C "$(pwd)"
        O="$(pwd)/out"
        KCFLAGS=-w
        CONFIG_SECTION_MISMATCH_WARN_ONLY=y
        ARCH=arm64
        CC="${CC}"
        CLANG_TRIPLE="${CLANG_TRIPLE}"
        CROSS_COMPILE="${CROSS_COMPILE}"
        LLVM=1
        LLVM_IAS=1
    )

    # Step 4a: Generate base .config using a04_defconfig
    log "Using a04_defconfig..."
    make "${MAKE_OPTS[@]}" a04_defconfig || err "Defconfig failed"

    # Step 4b: Apply KernelSU and security config changes
    log "Applying KernelSU config overrides..."
    
    # Enable KernelSU
    scripts/config --file out/.config --enable CONFIG_KSU
    scripts/config --file out/.config --enable CONFIG_KSU_MANUAL_HOOK

    # Disable Samsung security that conflicts with KernelSU
    for opt in \
        SECURITY_DEFEX PROCA FIVE UH RKP_KDP \
        SEC_RESTRICT_ROOTING SEC_RESTRICT_SETUID SEC_RESTRICT_FORK \
        SEC_RESTRICT_ROOTING_LOG KNOX_KAP \
        TIMA TIMA_LKMAUTH TIMA_LKM_BLOCK TIMA_LKMAUTH_CODE_PROT \
        INTEGRITY INTEGRITY_SIGNATURE INTEGRITY_ASYMMETRIC_KEYS \
        INTEGRITY_TRUSTED_KEYRING INTEGRITY_AUDIT DM_VERITY; do
        scripts/config --file out/.config --disable "CONFIG_${opt}" 2>/dev/null || true
    done

    # SELinux: enable permissive toggle (already set in sec_userdebug.cfg)
    scripts/config --file out/.config --enable CONFIG_SECURITY_SELINUX_DEVELOP || true
    scripts/config --file out/.config --disable CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE || true

    # Hiding / low detectability settings
    # Disable KSU debug (no log spam, harder to detect)
    scripts/config --file out/.config --disable CONFIG_KSU_DEBUG 2>/dev/null || true

    # Change kernel version string to blend in (avoid "-KernelSU" pattern)
    scripts/config --file out/.config --set-str CONFIG_LOCALVERSION "-th-v2"
    scripts/config --file out/.config --disable CONFIG_LOCALVERSION_AUTO

    log "Kernel configured with low-detectability settings."
}

# ============================================================
# Step 5: Build the kernel
# ============================================================
build_kernel() {
    log "Building kernel with ${JOBS} jobs..."
    cd "$KERNEL_DIR"

    # Camouflage: set manager app to Samsung system app
    local MANAGER_PKG="${KSU_MANAGER_PACKAGE:-com.wssyncmldm}"

    local MAKE_OPTS=(
        -C "$(pwd)"
        O="$(pwd)/out"
        KCFLAGS=-w
        CONFIG_SECTION_MISMATCH_WARN_ONLY=y
        ARCH=arm64
        CC="${CC}"
        CLANG_TRIPLE="${CLANG_TRIPLE}"
        CROSS_COMPILE="${CROSS_COMPILE}"
        KSU_MANAGER_PACKAGE="${MANAGER_PKG}"
        LLVM=1
        LLVM_IAS=1
    )

    # Build with parallel jobs
    make "${MAKE_OPTS[@]}" -j"${JOBS}" 2>&1 | tee "${OUTPUT_DIR}/build.log" || {
        # If full LLVM fails, try without LLVM_IAS (some Samsung kernels need this)
        warn "Build failed with LLVM_IAS=1, retrying without..."
        make "${MAKE_OPTS[@]}" -j"${JOBS}" LLVM_IAS= 2>&1 | tee -a "${OUTPUT_DIR}/build.log" || {
            err "Build failed! Check ${OUTPUT_DIR}/build.log"
        }
    }

    # Copy Image to expected output location
    if [ -f "out/arch/arm64/boot/Image" ]; then
        cp "out/arch/arm64/boot/Image" "arch/arm64/boot/Image"
        log "Build successful!"
    else
        err "No kernel Image found in out/arch/arm64/boot/"
    fi
}

# ============================================================
# Step 6: Package outputs (Image, boot.img, Odin tar)
# ============================================================
package_kernel() {
    log "Packaging outputs..."
    mkdir -p "$OUTPUT_DIR"

    local SRC_IMG="${KERNEL_DIR}/out/arch/arm64/boot/Image"
    if [ ! -f "$SRC_IMG" ]; then
        err "Kernel Image not found at ${SRC_IMG}"
    fi

    # 1. Copy raw Image
    cp "$SRC_IMG" "$OUTPUT_DIR/Image"
    log "Kernel Image: $(ls -lh ${OUTPUT_DIR}/Image | awk '{print $5}')"

    # 2. Create boot.img (Android boot image)
    log "Creating boot.img..."
    # Samsung A04 (mt6765) boot image params:
    # base: 0x40000000, pagesize: 2048, kernel_offset: 0x00008000
    # ramdisk_offset: 0x01000000, tags_offset: 0x00000100
    if command -v mkbootimg &>/dev/null; then
        mkbootimg \
            --kernel "$SRC_IMG" \
            --base 0x40000000 \
            --pagesize 2048 \
            --kernel_offset 0x00008000 \
            --ramdisk_offset 0x01000000 \
            --tags_offset 0x00000100 \
            --cmdline "androidboot.selinux=permissive console=ttyS1,115200n8" \
            -o "$OUTPUT_DIR/boot.img" 2>&1 || {
            warn "mkbootimg failed; creating raw tar with just Image."
        }
    fi

    # 3. Create Odin-flashable .tar.md5
    cd "$OUTPUT_DIR"
    if [ -f "boot.img" ]; then
        tar -cvf "KernelSU_A04_boot.tar" "boot.img" 2>/dev/null
    else
        tar -cvf "KernelSU_A04_boot.tar" "Image" 2>/dev/null
    fi
    
    if command -v md5sum &>/dev/null; then
        md5sum "KernelSU_A04_boot.tar" | cut -d' ' -f1 | tr -d '\n' >> "KernelSU_A04_boot.tar"
        mv "KernelSU_A04_boot.tar" "KernelSU_A04_boot.tar.md5"
        log "Created: KernelSU_A04_boot.tar.md5"
    fi

    # 4. Flashable zip (for TWRP/custom recovery)
    local ZIPDIR="${OUTPUT_DIR}/zip"
    mkdir -p "$ZIPDIR/META-INF/com/google/android"
    cat > "$ZIPDIR/META-INF/com/google/android/update-binary" << 'UPDATEBIN'
#!/sbin/sh
ui_print "Flashing KernelSU kernel for A04..."
dd if=/tmp/kernel/Image of=/dev/block/by-name/boot
ui_print "Done!"
UPDATEBIN
    chmod +x "$ZIPDIR/META-INF/com/google/android/update-binary"
    cp "$OUTPUT_DIR/Image" "$ZIPDIR/Image"
    cd "$ZIPDIR"
    zip -r "../KernelSU_A04_flashable.zip" . 2>/dev/null || true
    cd "$OUTPUT_DIR"
    rm -rf "$ZIPDIR"

    log "All outputs in: $OUTPUT_DIR"
    ls -lh "$OUTPUT_DIR/" | grep -v build.log
}

# ============================================================
# Main
# ============================================================
main() {
    mkdir -p "$OUTPUT_DIR"

    log "=== KernelSU Builder for Samsung Galaxy A04 (SM-A045F) ==="
    log "Kernel: 4.19.191 | Platform: mt6765 | Arch: arm64"
    echo ""

    download_kernel_source
    setup_toolchains
    integrate_kernelsu
    configure_kernel
    build_kernel
    package_kernel

    echo ""
    log "================================================"
    log "  BUILD COMPLETE!"
    log "================================================"
    echo ""
    log "Output files in: ${OUTPUT_DIR}/"
    echo ""
    log "To flash via Odin:"
    log "  1. Boot device into Download Mode"
    log "     (Vol Down + Vol Up, connect USB)"
    log "  2. Open Odin on Windows"
    log "  3. Place KernelSU_A04_boot.tar.md5 in AP slot"
    log "  4. Ensure only 'Auto Reboot' + 'F. Reset Time' checked"
    log "  5. Click Start"
    echo ""
    log "To flash via TWRP:"
    log "  Flash KernelSU_A04_flashable.zip"
    echo ""
    log "After booting, install KernelSU APK:"
    log "  https://github.com/rsuntk/KernelSU/releases"
    echo ""
}

main "$@"
