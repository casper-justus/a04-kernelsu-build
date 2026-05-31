#!/bin/bash
set -euo pipefail

# ============================================================
# KernelSU + SUSFS Builder for Samsung Galaxy A04 (SM-A045F)
# Based on: rsuntk-oss/android_kernel_samsung_a04m (mt6765)
# Kernel base: 4.19.191 | Clang: r383902b (12.0.5)
# SUSFS: simonpunk/susfs4ksu (kernel-4.19 branch)
# ============================================================

WORK_DIR="$(pwd)"
KERNEL_DIR="${WORK_DIR}/kernel"
OUTPUT_DIR="${WORK_DIR}/output"
TOOLCHAIN_DIR="${WORK_DIR}/toolchains"
SUSFS_DIR="${WORK_DIR}/susfs"
JOBS=$(nproc --all 2>/dev/null || echo 4)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
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
# Step 2: Setup toolchains (clang + GCC 4.9)
# ============================================================
setup_toolchains() {
    log "Setting up toolchains..."
    mkdir -p "$TOOLCHAIN_DIR"
    cd "$TOOLCHAIN_DIR"

    # Use mirrors from ravindu644/Android-Kernel-Tutorials releases
    # These are exact AOSP clang-r383902b and aarch64-linux-android-4.9 tarballs
    local MIRROR_BASE="https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains"

    # --- Clang ---
    if [ ! -f "clang-r383902/bin/clang" ]; then
        log "Downloading clang-r383902b (Clang 12.0.5)..."
        mkdir -p clang-r383902
        curl -L -o clang.tar.gz --connect-timeout 30 --retry 3 \
            "${MIRROR_BASE}/clang-r383902b.tar.gz" || {
            warn "Mirror failed, trying ravi's alternative..."
            curl -L -o clang.tar.gz --connect-timeout 30 --retry 3 \
                "${MIRROR_BASE}/clang-r383902.tar.gz" || {
                err "Failed to download clang toolchain from all sources."
            }
        }
        tar -xzf clang.tar.gz -C clang-r383902 2>/dev/null || err "Failed to extract clang"
        rm -f clang.tar.gz
    fi

    # --- GCC 4.9 aarch64 ---
    if [ ! -f "aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-ld" ]; then
        local MIRROR_BASE="https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains"
        log "Downloading GCC 4.9 (aarch64-linux-android)..."
        curl -L -o gcc.tar.gz --connect-timeout 30 --retry 3 \
            "${MIRROR_BASE}/aarch64-linux-android-4.9.tar.gz" || {
            warn "Standard GCC tarball failed, trying Linux-5.4 variant..."
            curl -L -o gcc.tar.gz --connect-timeout 30 --retry 3 \
                "${MIRROR_BASE}/aarch64-linux-android-4.9-Linux-5.4.tar.gz" || {
                err "Failed to download GCC toolchain."
            }
        }

        # Tarball has internal path: gcc/linux-x86/aarch64/aarch64-linux-android-4.9/...
        mkdir -p gcc_temp
        tar -xzf gcc.tar.gz -C gcc_temp 2>/dev/null || err "Failed to extract GCC"
        rm -f gcc.tar.gz

        # Find actual bin dir and relocate
        local GCC_BIN_DIR=$(find gcc_temp -type d -name "bin" -path "*/aarch64-linux-android-4.9/bin" | head -1)
        if [ -z "$GCC_BIN_DIR" ]; then
            err "Could not find toolchain bin dir: $(find gcc_temp -type d -maxdepth 6 | head -10)"
        fi
        mkdir -p aarch64-linux-android-4.9
        cp -r "$(dirname "$GCC_BIN_DIR")"/* aarch64-linux-android-4.9/
        rm -rf gcc_temp

        # Create androidkernel- symlinks (kernel expects this prefix)
        cd aarch64-linux-android-4.9/bin
        for f in aarch64-linux-android-*; do
            if [ -f "$f" ] && [ ! -e "${f/android-/androidkernel-}" ]; then
                ln -sf "$f" "${f/android-/androidkernel-}"
            fi
        done
        cd ../..
        log "Created aarch64-linux-androidkernel-* symlinks"
    fi

    log "Toolchains ready."
    echo "  Clang: $(clang-r383902/bin/clang --version 2>&1 | head -1)"
    echo "  GCC prefix: $(ls aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-ld 2>/dev/null && echo 'found' || echo 'missing')"
}

# ============================================================
# Step 3: Integrate SUSFS + KernelSU (susfs-rksu-master)
# ============================================================
integrate_susfs() {
    log "=== Integrating SUSFS + KernelSU ==="
    cd "$KERNEL_DIR"

    # Step 3a: Download SUSFS patches from GitLab
    log "Downloading SUSFS 4.19 patches..."
    mkdir -p "$SUSFS_DIR"
    cd "$SUSFS_DIR"

    local GITLAB_API="https://gitlab.com/api/v4/projects/simonpunk%2Fsusfs4ksu/repository"
    local SUSFS_REF="kernel-4.19"

    # Download main patch file
    curl -L --connect-timeout 30 --retry 3 \
        "${GITLAB_API}/files/kernel_patches%2F50_add_susfs_in_kernel-4.19.patch/raw?ref=${SUSFS_REF}" \
        -o "50_add_susfs_in_kernel-4.19.patch" || warn "Failed to download main SUSFS patch"

    # Download individual source files (for direct placement if patch fails)
    local SUSFS_FILES=(
        "kernel_patches/fs/susfs.c:fs/susfs.c"
        "kernel_patches/fs/sus_su.c:fs/sus_su.c"
        "kernel_patches/include/linux/susfs.h:include/linux/susfs.h"
        "kernel_patches/include/linux/susfs_def.h:include/linux/susfs_def.h"
    )
    for entry in "${SUSFS_FILES[@]}"; do
        local src="${entry%%:*}"
        local dst="${entry##*:}"
        local dir=$(dirname "$dst")
        mkdir -p "$dir"
        curl -L --connect-timeout 30 --retry 3 \
            "${GITLAB_API}/files/${src}/raw?ref=${SUSFS_REF}" \
            -o "$dst" || warn "Failed to download $dst"
    done

    # Download KernelSU/ directory from SUSFS
    log "Downloading SUSFS KernelSU integration files..."
    curl -L --connect-timeout 30 --retry 3 \
        "${GITLAB_API}/files/kernel_patches%2FKernelSU%2Fsucompat.c/raw?ref=${SUSFS_REF}" \
        -o "KernelSU/sucompat.c" 2>/dev/null || true

    cd "$KERNEL_DIR"

    # Step 3b: Apply SUSFS kernel patch
    if [ -f "${SUSFS_DIR}/50_add_susfs_in_kernel-4.19.patch" ]; then
        log "Applying SUSFS kernel patch (fuzz=3, tolerant)..."
        cd "$KERNEL_DIR"
        
        # Try applying with patch. Use --forward to skip already-applied hunks.
        # --fuzz=3 tolerates up to 3 lines of context difference
        # --no-backup-if-mismatch avoids .orig files
        # Force exit code to 0; we track rejects separately
        patch -p1 --forward --fuzz=3 --no-backup-if-mismatch \
            < "${SUSFS_DIR}/50_add_susfs_in_kernel-4.19.patch" 2>&1 || true
        
        # Check for rejects
        local REJECTS=$(find . -name "*.rej" 2>/dev/null | wc -l)
        if [ "$REJECTS" -gt 0 ]; then
            warn "SUSFS patch had ${REJECTS} rejected hunk(s) in:"
            find . -name "*.rej" 2>/dev/null | while read rej; do
                warn "  ${rej#./}"
            done
            log "Will manually fix critical rejections..."
        else
            log "SUSFS patch applied cleanly!"
        fi
    fi

    # Step 3c: Copy SUSFS source files directly to kernel tree
    # These are the core SUSFS files needed regardless of patch success
    log "Copying SUSFS source files to kernel tree..."
    
    # Copy susfs.c and sus_su.c to fs/
    if [ -f "${SUSFS_DIR}/fs/susfs.c" ]; then
        cp "${SUSFS_DIR}/fs/susfs.c" "fs/susfs.c"
        chmod 644 "fs/susfs.c"
    fi
    if [ -f "${SUSFS_DIR}/fs/sus_su.c" ]; then
        cp "${SUSFS_DIR}/fs/sus_su.c" "fs/sus_su.c"
        chmod 644 "fs/sus_su.c"
    fi

    # Copy headers
    if [ -f "${SUSFS_DIR}/include/linux/susfs.h" ]; then
        cp "${SUSFS_DIR}/include/linux/susfs.h" "include/linux/susfs.h"
        chmod 644 "include/linux/susfs.h"
    fi
    if [ -f "${SUSFS_DIR}/include/linux/susfs_def.h" ]; then
        cp "${SUSFS_DIR}/include/linux/susfs_def.h" "include/linux/susfs_def.h"
        chmod 644 "include/linux/susfs_def.h"
    fi

    # Step 3d: Manually apply essential SUSFS changes to fs/Makefile
    # (This is the most critical one that's unlikely to conflict)
    log "Ensuring fs/Makefile has SUSFS entry..."
    if ! grep -q "susfs.o" "fs/Makefile"; then
        # Add after the main obj-y list, before the BLOCK check
        sed -i '/^obj-y :=.*nsfs.o/a obj-$(CONFIG_KSU_SUSFS) += susfs.o' "fs/Makefile" 2>/dev/null || {
            warn "Could not auto-add SUSFS to fs/Makefile; manual check needed."
        }
    fi

    # Step 3e: Integrate KernelSU using susfs-rksu-master branch
    log "Integrating KernelSU (susfs-rksu-master branch)..."
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

    # Use the SUSFS-aware KernelSU setup script
    log "Running KernelSU setup (susfs-rksu-master)..."
    curl -LSs "https://raw.githubusercontent.com/rsuntk/KernelSU/susfs-rksu-master/kernel/setup.sh" \
        | bash -s susfs-rksu-master 2>&1 || {
        warn "Auto setup failed, trying manual clone..."
        # Match setup.sh: place in KernelSU/ + symlink from drivers/kernelsu
        if [ ! -d "KernelSU" ]; then
            local KSU_TMP="${WORK_DIR}/ksu_tmp"
            mkdir -p "$KSU_TMP"
            git clone --depth=1 -b susfs-rksu-master \
                https://github.com/rsuntk/KernelSU.git "$KSU_TMP" 2>/dev/null || {
                err "Failed to clone KernelSU (susfs-rksu-master)!"
            }
            cp -r "$KSU_TMP" "$KERNEL_DIR/KernelSU"
            ln -sf "../../KernelSU/kernel" "$KERNEL_DIR/drivers/kernelsu" 2>/dev/null || true
            rm -rf "$KSU_TMP"
        fi
    }

    # Verify (setup.sh puts files in KernelSU/kernel/, not kernel/)
    if [ ! -f "KernelSU/kernel/ksu.h" ] && [ ! -L "drivers/kernelsu" ]; then
        err "KernelSU integration failed!"
    fi

    log "SUSFS + KernelSU integration complete."
}

# ============================================================
# Step 4: Configure kernel (a04_defconfig + SUSFS + KernelSU)
# ============================================================
configure_kernel() {
    log "Configuring kernel..."
    cd "$KERNEL_DIR"

    # Set up toolchain paths
    export ARCH=arm64
    export CROSS_COMPILE="${TOOLCHAIN_DIR}/aarch64-linux-android-4.9/bin/aarch64-linux-androidkernel-"
    export CC="${TOOLCHAIN_DIR}/clang-r383902/bin/clang"
    export CLANG_TRIPLE="aarch64-linux-gnu-"

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

    # Step 4b: Enable KernelSU
    log "Enabling KernelSU..."
    scripts/config --file out/.config --enable CONFIG_KSU
    scripts/config --file out/.config --enable CONFIG_KSU_MANUAL_HOOK

    # Step 4c: Enable SUSFS features
    log "Enabling SUSFS hiding features..."
    for opt in \
        KSU_SUSFS KSU_SUSFS_SUS_PATH \
        KSU_SUSFS_SUS_MOUNT KSU_SUSFS_SUS_KSTAT \
        KSU_SUSFS_OPEN_REDIRECT KSU_SUSFS_SUS_SU \
        SPOOF_UNAME KSU_SUSFS_ENFORCE_SUSFS \
        KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        KSU_SUSFS_SUS_OVERLAYFS; do
        scripts/config --file out/.config --enable "CONFIG_${opt}" 2>/dev/null || true
    done

    # Step 4d: Disable Samsung security that conflicts with KernelSU/SUSFS
    log "Disabling Samsung security modules..."
    for opt in \
        SECURITY_DEFEX PROCA FIVE UH RKP_KDP \
        SEC_RESTRICT_ROOTING SEC_RESTRICT_SETUID SEC_RESTRICT_FORK \
        SEC_RESTRICT_ROOTING_LOG KNOX_KAP \
        TIMA TIMA_LKMAUTH TIMA_LKM_BLOCK TIMA_LKMAUTH_CODE_PROT \
        INTEGRITY INTEGRITY_SIGNATURE INTEGRITY_ASYMMETRIC_KEYS \
        INTEGRITY_TRUSTED_KEYRING INTEGRITY_AUDIT DM_VERITY; do
        scripts/config --file out/.config --disable "CONFIG_${opt}" 2>/dev/null || true
    done

    # Step 4e: SELinux permissive toggle
    scripts/config --file out/.config --enable CONFIG_SECURITY_SELINUX_DEVELOP || true
    scripts/config --file out/.config --disable CONFIG_SECURITY_SELINUX_ALWAYS_ENFORCE || true

    # Step 4f: Low detectability settings
    scripts/config --file out/.config --disable CONFIG_KSU_DEBUG 2>/dev/null || true
    scripts/config --file out/.config --set-str CONFIG_LOCALVERSION "-th-v2"
    scripts/config --file out/.config --disable CONFIG_LOCALVERSION_AUTO

    # Step 4g: Olddefconfig to resolve any new dependencies
    make "${MAKE_OPTS[@]}" olddefconfig 2>/dev/null || true

    log "Kernel configured with SUSFS + low-detectability settings."
}

# ============================================================
# Step 5: Build the kernel
# ============================================================
build_kernel() {
    log "Building kernel with ${JOBS} jobs..."
    cd "$KERNEL_DIR"

    # Camouflage: set manager app to Samsung system app (e.g., firmware update)
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
# Step 6: Package outputs (Image, Odin tar)
# ============================================================
package_kernel() {
    log "Packaging outputs..."
    mkdir -p "$OUTPUT_DIR"

    local SRC_IMG="${KERNEL_DIR}/out/arch/arm64/boot/Image"
    if [ ! -f "$SRC_IMG" ]; then
        err "Kernel Image not found at ${SRC_IMG}"
    fi

    cp "$SRC_IMG" "$OUTPUT_DIR/Image"
    log "Kernel Image: $(ls -lh ${OUTPUT_DIR}/Image | awk '{print $5}')"

    # Create Odin-flashable .tar.md5
    cd "$OUTPUT_DIR"
    tar -cvf "KernelSU_A04_boot.tar" "Image" 2>/dev/null
    
    if command -v md5sum &>/dev/null; then
        md5sum "KernelSU_A04_boot.tar" | cut -d' ' -f1 | tr -d '\n' >> "KernelSU_A04_boot.tar"
        mv "KernelSU_A04_boot.tar" "KernelSU_A04_boot.tar.md5"
        log "Created: KernelSU_A04_boot.tar.md5 ($(ls -lh KernelSU_A04_boot.tar.md5 | awk '{print $5}'))"
    fi

    log "All outputs in: $OUTPUT_DIR"
    ls -lh "$OUTPUT_DIR/" | grep -v build.log
}

# ============================================================
# Main
# ============================================================
main() {
    mkdir -p "$OUTPUT_DIR"

    log "=== KernelSU + SUSFS Builder for SM-A045F ==="
    log "Kernel: 4.19.191 | SUSFS: enabled | Arch: arm64"
    echo ""

    download_kernel_source
    setup_toolchains
    integrate_susfs
    configure_kernel
    build_kernel
    package_kernel

    echo ""
    log "================================================"
    log "  BUILD COMPLETE"
    log "================================================"
    echo ""
    log "Output: ${OUTPUT_DIR}/KernelSU_A04_boot.tar.md5"
    echo ""
    log "To flash via Odin:"
    log "  1. Boot device into Download Mode"
    log "     (Vol Down + Vol Up, connect USB)"
    log "  2. Open Odin on Windows"
    log "  3. Place KernelSU_A04_boot.tar.md5 in AP slot"
    log "  4. Ensure only 'Auto Reboot' + 'F. Reset Time' checked"
    log "  5. Click Start"
    echo ""
    log "After boot:"
    log "  Install KernelSU APK → grant root → enable 'Hide' per app"
    log "  Optionally install Zygisk Assistant module"
    echo ""
}

main "$@"
