#!/usr/bin/env bash

set -euo pipefail

SECONDS=0

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="${1:-sanders}"
ARGUMENT="${2:-}"

if [[ "$DEVICE" == -* ]]; then
    ARGUMENT="$DEVICE"
    DEVICE="sanders"
fi

if [[ "$DEVICE" != "sanders" ]]; then
    printf 'Usage: %s [sanders] [-c|--clean|-r|--regen|-rf|--regen-full]\n' "$0" >&2
    exit 2
fi

DEFCONFIG="sanders_defconfig"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
TC_DIR="${TC_DIR:-$ROOT_DIR/tc/clang-r522817}"
AK3_DIR="${AK3_DIR:-$ROOT_DIR/android/AnyKernel3}"
AK3_REPO="https://github.com/Sanders-Revived/AnyKernel3"
AK3_BRANCH="sanders"
JOBS="${JOBS:-$(nproc --all)}"

CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"
if ! command -v "${CROSS_COMPILE_ARM32}ld" >/dev/null 2>&1 && [[ -x /usr/bin/ld ]]; then
    CROSS_COMPILE_ARM32="/usr/bin/"
fi

DTC_BIN="${DTC:-}"
if [[ -z "$DTC_BIN" ]] && command -v dtc >/dev/null 2>&1; then
    DTC_BIN="$(command -v dtc)"
fi

export PATH="$TC_DIR/bin:$PATH"

ZIPNAME="Aurora-Kernel-${DEVICE}-$(date '+%Y%m%d-%H%M')"
if head=$(git -C "$ROOT_DIR" rev-parse --verify HEAD 2>/dev/null); then
    ZIPNAME="${ZIPNAME}-$(printf '%s' "$head" | cut -c1-8)"
fi
ZIPNAME="${ZIPNAME}.zip"

if [[ "$ARGUMENT" == "-c" || "$ARGUMENT" == "--clean" ]]; then
    rm -rf -- "$OUT_DIR"
fi

if [[ "$ARGUMENT" == "-r" || "$ARGUMENT" == "--regen" ]]; then
    mkdir -p -- "$OUT_DIR"
    make -C "$ROOT_DIR" O="$OUT_DIR" ARCH=arm64 "$DEFCONFIG" savedefconfig
    cp -- "$OUT_DIR/defconfig" "$ROOT_DIR/arch/arm64/configs/$DEFCONFIG"
    printf '[+] Defconfig regenerated\n'
    exit 0
fi

if [[ "$ARGUMENT" == "-rf" || "$ARGUMENT" == "--regen-full" ]]; then
    mkdir -p -- "$OUT_DIR"
    make -C "$ROOT_DIR" O="$OUT_DIR" ARCH=arm64 "$DEFCONFIG"
    cp -- "$OUT_DIR/.config" "$ROOT_DIR/arch/arm64/configs/$DEFCONFIG"
    printf '[+] Full defconfig regenerated\n'
    exit 0
fi

if [[ ! -x "$TC_DIR/bin/clang" ]]; then
    printf '[*] AOSP Clang not found; cloning it to %s\n' "$TC_DIR"
    git clone --depth=1 -b 18 \
        https://gitlab.com/ThankYouMario/android_prebuilts_clang-standalone \
        "$TC_DIR"
fi

MAKE_ARGS=(
    -C "$ROOT_DIR"
    O="$OUT_DIR"
    ARCH=arm64
    CC=clang
    LD=ld.lld
    AS=llvm-as
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32"
    LLVM=1
    LLVM_IAS=1
)

if [[ -n "$DTC_BIN" ]]; then
    MAKE_ARGS+=(DTC="$DTC_BIN")
fi

mkdir -p -- "$OUT_DIR"
printf '[*] Configuring %s\n' "$DEFCONFIG"
make "${MAKE_ARGS[@]}" "$DEFCONFIG"

printf '[*] Building Image.gz and separate DTBs with %s job(s)\n' "$JOBS"
DTB_TARGETS=(
    arch/arm64/boot/dts/qcom/msm8953-sanders-p1.dtb
    arch/arm64/boot/dts/qcom/msm8953-sanders-p2.dtb
    arch/arm64/boot/dts/qcom/msm8953-sanders-p3.dtb
    arch/arm64/boot/dts/qcom/msm8953-sanders-p4.dtb
)

make -j"$JOBS" "${MAKE_ARGS[@]}" Image.gz dtbs

KERNEL_IMAGE="$OUT_DIR/arch/arm64/boot/Image.gz"
if [[ ! -s "$KERNEL_IMAGE" ]]; then
    printf '[!] Build failed: %s was not generated\n' "$KERNEL_IMAGE" >&2
    exit 1
fi

pack_u32() {
    local value="$1"
    printf -v bytes '\\x%02x\\x%02x\\x%02x\\x%02x' \
        "$((value & 255))" "$(((value >> 8) & 255))" \
        "$(((value >> 16) & 255))" "$(((value >> 24) & 255))"
    printf '%b' "$bytes"
}

pack_sanders_dt() {
    local dt_image="$OUT_DIR/arch/arm64/boot/dt.img"
    local slot_size=245760
    local page_size=2048
    local dtb size padding

    : > "$dt_image"
    printf 'QCDT' >> "$dt_image"
    pack_u32 2 >> "$dt_image"
    pack_u32 6 >> "$dt_image"
    pack_u32 293 >> "$dt_image"

    # Preserve the Sanders board/revision selection table from the stock QCDT.
    for entry in \
        '75 33024 0 2048 245760 293' \
        '75 33280 0 247808 245760 293' \
        '75 33536 0 493568 245760 293' \
        '75 33712 0 493568 245760 293' \
        '75 33792 0 739328 245760 293' \
        '76 33792 0 739328 245760 0'; do
        for value in $entry; do
            pack_u32 "$value" >> "$dt_image"
        done
    done
    truncate -s "$page_size" "$dt_image"

    for dtb in "${DTB_TARGETS[@]}"; do
        dtb="$OUT_DIR/$dtb"
        size=$(stat -c '%s' "$dtb")
        if (( size > slot_size )); then
            printf '[!] DTB is larger than its QCDT slot: %s\n' "$dtb" >&2
            exit 1
        fi
        cat "$dtb" >> "$dt_image"
        padding=$((slot_size - size))
        if (( padding > 0 )); then
            head -c "$padding" /dev/zero >> "$dt_image"
        fi
    done
}

pack_sanders_dt
DT_IMAGE="$OUT_DIR/arch/arm64/boot/dt.img"
if [[ ! -s "$DT_IMAGE" ]]; then
    printf '[!] Build failed: %s was not generated\n' "$DT_IMAGE" >&2
    exit 1
fi

printf '[+] Kernel and Sanders DTBs compiled successfully\n'

WORK_AK3="$ROOT_DIR/.anykernel3-sanders-build"
rm -rf -- "$WORK_AK3"
if [[ -d "$AK3_DIR/.git" ]]; then
    cp -a -- "$AK3_DIR" "$WORK_AK3"
else
    git clone -q --depth=1 -b "$AK3_BRANCH" "$AK3_REPO" "$WORK_AK3"
fi
rm -f -- "$WORK_AK3/Image.gz-dtb"
cp -- "$KERNEL_IMAGE" "$WORK_AK3/Image.gz"
cp -- "$DT_IMAGE" "$WORK_AK3/dt.img"

(cd "$WORK_AK3" && zip -r9 "$ROOT_DIR/$ZIPNAME" . -x './.git/*' './README.md' './*placeholder*')
rm -rf -- "$WORK_AK3"

printf '[+] Done in %s minute(s) and %s second(s)\n' "$((SECONDS / 60))" "$((SECONDS % 60))"
printf '[+] Zip: %s\n' "$ROOT_DIR/$ZIPNAME"
