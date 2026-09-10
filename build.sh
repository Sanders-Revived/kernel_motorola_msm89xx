#!/usr/bin/env bash
#
# Aurora Kernel build - sanders (Moto G5s Plus)
# KSU OFF by default; use --ksu to build with ReSukiSU.
#

SECONDS=0

# ===== Device / Kernel =====
DEVICE="sanders"
DEVICE_NAME="Moto G5s Plus"
DEFCONFIG="sanders_defconfig"

# ===== ReSukiSU (default: OFF, enable with --ksu) =====
KSU_REPO="https://github.com/ReSukiSU/ReSukiSU"
KSU_DIR="$(pwd)/KernelSU"
WITH_KSU="${WITH_KSU:-0}"
KSU_REF="${KSU_REF:-main}"

# ===== Toolchain =====
TC_DIR="$(pwd)/tc/clang-r522817"
export PATH="$TC_DIR/bin:$PATH"

# ===== AnyKernel3 =====
AK3_REPO="https://github.com/Sanders-Revived/AnyKernel3"
AK3_BRANCH="sanders"
AK3_DIR="$(pwd)/android/AnyKernel3"

# ===== Output =====
OUT_DIR="$(pwd)/out"
BOOT_DIR="$OUT_DIR/arch/arm64/boot"
KERNEL_IMG="$BOOT_DIR/Image.gz"

usage() {
    awk '/^SECONDS=0/{exit} NR>=3' "$0" | sed 's/^# \{0,1\}//'
}

# ===== Arguments =====
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --ksu)    WITH_KSU=1 ;;
        --no-ksu) WITH_KSU=0 ;;
        -c|--clean) CLEAN=1 ;;
        -r|--regen)
            mkdir -p out
            make O=out ARCH=arm64 $DEFCONFIG savedefconfig
            cp out/defconfig arch/arm64/configs/$DEFCONFIG
            echo "[+] Defconfig regenerated"
            exit 0
            ;;
        -rf|--regen-full)
            mkdir -p out
            make O=out ARCH=arm64 $DEFCONFIG
            cp out/.config arch/arm64/configs/$DEFCONFIG
            echo "[+] Full defconfig regenerated"
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) echo "[*] Ignoring legacy positional argument: $arg" ;;
    esac
done

if [ "$CLEAN" -eq 1 ]; then
    echo "[*] Cleaning output directory"
    rm -rf out
fi

# ===== ReSukiSU: driver fetch (KSU builds only) =====
setup_ksu() {
    echo "[*] ReSukiSU ref: $KSU_REF"
    if [ ! -d "$KSU_DIR" ]; then
        echo "[*] Cloning ReSukiSU..."
        git clone "$KSU_REPO" "$KSU_DIR" || return 1
    fi
    (
        cd "$KSU_DIR" || exit 1
        git fetch origin --tags 2>/dev/null || true
        if ! git checkout "$KSU_REF" 2>/dev/null; then
            echo "[!] Ref '$KSU_REF' not found, falling back to 'main'"
            git checkout main || return 1
        fi
    ) || return 1

    if [ ! -L "drivers/kernelsu" ]; then
        echo "[*] Linking drivers/kernelsu..."
        ln -sfn ../KernelSU/kernel drivers/kernelsu || return 1
    fi
    grep -q "kernelsu" drivers/Makefile \
        || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
    grep -q 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig \
        || sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    echo "[+] ReSukiSU driver ready"
}

# ===== Zip suffix =====
if [ "$WITH_KSU" = "1" ]; then
    KSU_TAG="$(echo "$KSU_REF" | tr '/ ' '__')"
    VARIANT="KSU-${KSU_TAG}"
else
    VARIANT="NoKSU"
fi

# ===== Zip =====
ZIPNAME="Aurora-Kernel-${DEVICE}-$(date '+%Y%m%d-%H%M')"
if test -z "$(git rev-parse --show-cdup 2>/dev/null)" &&
   head=$(git rev-parse --verify HEAD 2>/dev/null); then
    ZIPNAME="${ZIPNAME}-$(echo "$head" | cut -c1-8)"
fi
ZIPNAME="${ZIPNAME}-${VARIANT}.zip"

# ===== Toolchain check =====
if ! [ -d "$TC_DIR" ]; then
    echo "[*] Cloning AOSP clang..."
    git clone --depth=1 -b 18 \
        https://gitlab.com/ThankYouMario/android_prebuilts_clang-standalone \
        "$TC_DIR" || exit 1
fi

# ===== Build =====
mkdir -p out
echo "[*] Building $DEFCONFIG for $DEVICE_NAME (WITH_KSU=$WITH_KSU)"

if [ "$WITH_KSU" = "1" ]; then
    setup_ksu || exit 1
fi

make O=out ARCH=arm64 $DEFCONFIG

# Toggle KSU in the generated .config (the defconfig carries no CONFIG_KSU
# on purpose, so the choice is made here at build time).
if [ "$WITH_KSU" = "1" ]; then
    ./scripts/config --file out/.config \
        --enable CONFIG_KSU \
        --enable CONFIG_KSU_MANUAL_HOOK
else
    ./scripts/config --file out/.config \
        --disable CONFIG_KSU
fi
make O=out ARCH=arm64 olddefconfig

echo "[*] Effective KSU config:"
grep -E "^CONFIG_KSU" out/.config || echo "    (CONFIG_KSU absent = disabled)"

echo "[*] Starting compilation..."
make -j$(nproc --all) O=out ARCH=arm64 \
    CC=clang LD=ld.lld AS=llvm-as AR=llvm-ar NM=llvm-nm \
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    LLVM=1 LLVM_IAS=1 Image.gz

# ===== Check compilation =====
if ! [ -f "$KERNEL_IMG" ]; then
    echo "[!] Compilation failed – Image.gz not found"
    exit 1
fi

echo "[+] Kernel compiled successfully (VARIANT=$VARIANT)"

# ===== Prepare AnyKernel3 =====
rm -rf AnyKernel3
echo "[*] Cloning AnyKernel3 for $DEVICE"
git clone -q -b "$AK3_BRANCH" "$AK3_REPO" AnyKernel3 || exit 1

# Copy the kernel image to AnyKernel3
cp "$KERNEL_IMG" AnyKernel3

# Remove boot output folder (Supra style)
rm -rf out/arch/arm64/boot

# ===== Zip =====
cd AnyKernel3 || exit 1
zip -r9 "../$ZIPNAME" * -x .git README.md "*placeholder*"
cd ..
rm -rf AnyKernel3

echo
echo "[✓] Done in $((SECONDS / 60))m $((SECONDS % 60))s"
echo "[✓] Zip: $ZIPNAME"
