SECONDS=0 # builtin bash timer
SUPPORTED_DEVICES=(aljeter aljeter_recovery sanders sanders_recovery)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ " ${SUPPORTED_DEVICES[@]} " =~ " $1 " ]]; then
    DEVICE=$1
    ARGUMENT=$2
else
    echo -e "\n${YELLOW}Select the device to compile:${NC}"
    select DEVICE in "${SUPPORTED_DEVICES[@]}"; do
        if [[ " ${SUPPORTED_DEVICES[@]} " =~ " ${DEVICE} " ]]; then
            ARGUMENT=$1
            break
        else
            echo -e "\n${RED}Invalid option. Please choose again.${NC}"
        fi
    done
fi

AK3_BRANCH=${DEVICE%_recovery}

ZIPNAME="Kernel-${DEVICE}-$(date '+%Y%m%d-%H%M').zip"
TC_DIR="$(pwd)/tc/clang-r522817"
AK3_DIR="$(pwd)/android/AnyKernel3"
DEFCONFIG="${DEVICE}_defconfig"

OUT_DIR="$(pwd)/out"
BOOT_DIR="$OUT_DIR/arch/arm64/boot"
DTS_DIR="$BOOT_DIR/dts"

if test -z "$(git rev-parse --show-cdup 2>/dev/null)" &&
   head=$(git rev-parse --verify HEAD 2>/dev/null); then
    ZIPNAME="${ZIPNAME::-4}-$(echo $head | cut -c1-8).zip"
fi

export PATH="$TC_DIR/bin:$PATH"

if ! [ -d "$TC_DIR" ]; then
    echo -e "${YELLOW}AOSP clang not found! Cloning to $TC_DIR...${NC}"
    if ! git clone --depth=1 -b 18 https://gitlab.com/ThankYouMario/android_prebuilts_clang-standalone "$TC_DIR"; then
        echo -e "${RED}Cloning failed! Aborting...${NC}"
        exit 1
    fi
fi

if [[ $ARGUMENT = "-r" || $ARGUMENT = "--regen" ]]; then
    mkdir -p out
    make O=out ARCH=arm64 $DEFCONFIG savedefconfig
    cp out/defconfig arch/arm64/configs/$DEFCONFIG
    echo -e "\n${GREEN}Defconfig successfully regenerated at $DEFCONFIG${NC}"
    exit 0
fi

if [[ $ARGUMENT = "-rf" || $ARGUMENT = "--regen-full" ]]; then
    mkdir -p out
    make O=out ARCH=arm64 $DEFCONFIG
    cp out/.config arch/arm64/configs/$DEFCONFIG
    echo -e "\n${GREEN}Full defconfig successfully regenerated at $DEFCONFIG${NC}"
    exit 0
fi

if [[ $ARGUMENT = "-c" || $ARGUMENT = "--clean" ]]; then
    echo -e "${YELLOW}Cleaning output directory...${NC}"
    rm -rf out
fi

if [[ $ARGUMENT = "-z" || $ARGUMENT = "--zip" ]]; then
    GEN_ZIP=true
else
    GEN_ZIP=false
fi

mkdir -p out
echo -e "${YELLOW}Building defconfig: $DEFCONFIG${NC}"
make O=out ARCH=arm64 $DEFCONFIG

echo -e "\n${YELLOW}Starting compilation...${NC}\n"

make -j$(nproc --all) O=out ARCH=arm64 \
    CC=clang LD=ld.lld AS=llvm-as AR=llvm-ar NM=llvm-nm \
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
    CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    LLVM=1 LLVM_IAS=1 Image.gz dtbs

if [ -f "$BOOT_DIR/Image.gz" ]; then
    echo -e "${GREEN}Kernel Image.gz found!${NC}"
    
    if [ -d "$DTS_DIR" ]; then
        echo -e "${BLUE}Generating dtb.img from $DTS_DIR...${NC}"
        cat $(find "$DTS_DIR" -type f -name "*.dtb" | sort) > "$BOOT_DIR/dtb.img"
        
        if [ -f "$BOOT_DIR/dtb.img" ]; then
            echo -e "${GREEN}dtb.img generated successfully!${NC}"
        else
            echo -e "${RED}Failed to generate dtb.img! Check if dtbs were compiled.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}DTS directory not found. Compilation might be incomplete.${NC}"
        exit 1
    fi
else
    echo -e "\n${RED}Compilation failed! Image.gz not found.${NC}"
    exit 1
fi

if [ "$GEN_ZIP" = true ]; then
    echo -e "Preparing zip...\n"
    
    rm -rf AnyKernel3

    if [ -d "$AK3_DIR" ]; then
        echo "Copying local AnyKernel3..."
        cp -r $AK3_DIR AnyKernel3
    else
        echo "Cloning AnyKernel3 (Branch: $AK3_BRANCH)..."
        if ! git clone -q https://github.com/Bomb-Projects/AnyKernel3 -b $AK3_BRANCH; then
            echo -e "\n${RED}Failed to clone branch '$AK3_BRANCH'! Trying default branch...${NC}"
            if ! git clone -q https://github.com/Bomb-Projects/AnyKernel3; then
                    echo -e "${RED}AnyKernel3 clone failed! Aborting...${NC}"
                    exit 1
            fi
        fi
    fi

    cp "$BOOT_DIR/Image.gz" AnyKernel3/Image.gz
    cp "$BOOT_DIR/dtb.img" AnyKernel3/dtb.img

    cd AnyKernel3
    if [ -d ".git" ]; then
        git checkout $AK3_BRANCH &> /dev/null
    fi

    zip -r9 "../$ZIPNAME" * -x .git README.md *placeholder
    cd ..
    rm -rf AnyKernel3
    
    echo -e "\n${GREEN}Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)!${NC}"
    echo -e "${GREEN}Zip: $ZIPNAME${NC}"
else

    echo -e "\n${YELLOW}Zip creation skipped (default). Use -z or --zip to generate.${NC}"
    echo -e "Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)!"
fi