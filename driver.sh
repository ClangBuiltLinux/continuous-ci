#!/usr/bin/env bash

set -eu

setup_variables() {
  while [[ ${#} -ge 1 ]]; do
    case ${1} in
      "-c"|"--clean") cleanup=true ;;
      "-j"|"--jobs") shift; jobs=$1 ;;
      "-j"*) jobs=${1/-j} ;;
      "-h"|"--help")
        cat usage.txt
        exit 0 ;;
    esac

    shift
  done

  # Turn on debug mode after parameters in case -h was specified
  set -x

  # torvalds/linux is the default repo if nothing is specified
  case ${REPO:=linux} in
    "common-"*)
      branch=android-${REPO##*-}
      tree=common
      url=https://android.googlesource.com/kernel/${tree} ;;
    "linux")
      owner=torvalds
      tree=linux ;;
    "linux-next")
      owner=next
      tree=linux-next ;;
    "4.4"|"4.9"|"4.14"|"4.19")
      owner=stable
      branch=linux-${REPO}.y
      tree=linux ;;
  esac
  [[ -z "${url:-}" ]] && url=git://git.kernel.org/pub/scm/linux/kernel/git/${owner}/${tree}.git

  # arm64 is the current default if nothing is specified
  case ${ARCH:=arm64} in
    "arm32_v5")
      config=multi_v5_defconfig
      image_name=zImage
      qemu="qemu-system-arm"
      qemu_ram=512m
      qemu_cmdline=( -machine palmetto-bmc
                     -no-reboot
                     -dtb "${tree}/arch/arm/boot/dts/aspeed-bmc-opp-palmetto.dtb"
                     -initrd "images/arm/rootfs.cpio" )
      export ARCH=arm
      export CROSS_COMPILE=arm-linux-gnueabi- ;;

    "arm32_v6")
      config=aspeed_g5_defconfig
      image_name=zImage
      qemu="qemu-system-arm"
      qemu_ram=512m
      qemu_cmdline=( -machine romulus-bmc
                     -no-reboot
                     -dtb "${tree}/arch/arm/boot/dts/aspeed-bmc-opp-romulus.dtb"
                     -initrd "images/arm/rootfs.cpio" )
      export ARCH=arm
      export CROSS_COMPILE=arm-linux-gnueabi- ;;

    "arm32_v7")
      config=multi_v7_defconfig
      image_name=zImage
      qemu="qemu-system-arm"
      qemu_ram=512m
      qemu_cmdline=( -machine virt
                     -no-reboot
                     -drive "file=images/arm/rootfs.ext4,format=raw,id=rootfs,if=none"
                     -device "virtio-blk-device,drive=rootfs"
                     -append "console=ttyAMA0 root=/dev/vda" )
      export ARCH=arm
      export CROSS_COMPILE=arm-linux-gnueabi- ;;

    "arm64")
      case ${REPO} in
        common-*) config=cuttlefish_defconfig ;;
        *) config=defconfig ;;
      esac
      image_name=Image.gz
      qemu="qemu-system-aarch64"
      qemu_ram=512m
      qemu_cmdline=( -cpu cortex-a57
                     -drive "file=images/arm64/rootfs.ext4,format=raw"
                     -append "console=ttyAMA0 root=/dev/vda" )
      export CROSS_COMPILE=aarch64-linux-gnu- ;;

    "x86_64")
      case ${REPO} in
        common-*)
          config=x86_64_cuttlefish_defconfig
          qemu_cmdline=( -append "console=ttyS0"
                         -initrd "images/x86_64/rootfs.cpio" ) ;;
        *)
          config=defconfig
          qemu_cmdline=( -drive "file=images/x86_64/rootfs.ext4,format=raw,if=ide"
                         -append "console=ttyS0 root=/dev/sda" ) ;;
      esac
      image_name=bzImage
      qemu="qemu-system-x86_64"
      qemu_ram=512m ;;
    "ppc32")
      config=ppc44x_defconfig
      image_name=zImage
      qemu="qemu-system-ppc"
      qemu_ram=128m
      qemu_cmdline=( -machine bamboo
                     -append "console=ttyS0"
                     -no-reboot
                     -initrd "images/ppc32/rootfs.cpio" )
      export ARCH=powerpc
      export CROSS_COMPILE=powerpc-linux-gnu- ;;

    "ppc64le")
      config=powernv_defconfig
      image_name=zImage.epapr
      qemu="qemu-system-ppc64"
      qemu_ram=2G
      qemu_cmdline=( -machine powernv
                     -device "ipmi-bmc-sim,id=bmc0"
                     -device "isa-ipmi-bt,bmc=bmc0,irq=10"
                     -L /usr/share/skiboot -bios skiboot.lid
                     -initrd images/ppc64le/rootfs.cpio )
      export ARCH=powerpc
      export CROSS_COMPILE=powerpc64le-linux-gnu- ;;

    # Unknown arch, error out
    *)
      echo "Unknown ARCH specified!"
      exit 1 ;;
  esac
  export ARCH=${ARCH}
}

check_dependencies() {
  command -v nproc
  command -v "${CROSS_COMPILE:-}"as
  command -v ${qemu}
  command -v timeout
  command -v unbuffer
  command -v clang-9
  command -v llvm-ar-9
  command -v "${LD:="${CROSS_COMPILE:-}"ld}"
}

mako_reactor() {
  # https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/kbuild/kbuild.txt
  time \
  KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970" \
  KBUILD_BUILD_USER=driver \
  KBUILD_BUILD_HOST=clangbuiltlinux \
  make -j"${jobs:-$(nproc)}" CC="${CC}" HOSTCC="${CC}" LD="${LD}" HOSTLD="${HOSTLD:-ld}" AR="llvm-ar-9" "${@}"
}

build_linux() {
  CC="$(command -v ccache) $(command -v clang-9)"
  [[ ${LD} =~ lld ]] && HOSTLD=${LD}

  if [[ -d ${tree} ]]; then
    cd ${tree}
    git fetch --depth=1 ${url} ${branch:=master}
    git reset --hard FETCH_HEAD
  else
    git clone --depth=1 -b ${branch:=master} --single-branch ${url}
    cd ${tree}
  fi

  git show -s | cat

  patches_folder=../patches/${REPO}/${ARCH}
  [[ -d ${patches_folder} ]] && git apply -v -3 "${patches_folder}"/*.patch

  # Only clean up old artifacts if requested, the Linux build system
  # is good about figuring out what needs to be rebuilt
  [[ -n "${cleanup:-}" ]] && mako_reactor mrproper
  mako_reactor ${config}
  # If we're using a defconfig, enable some more common config options
  # like debugging, selftests, and common drivers
  if [[ ${config} =~ defconfig ]]; then
    cat ../configs/common.config >> .config
    # Some torture test configs cause issues on x86_64
    [[ $ARCH != "x86_64" ]] && cat ../configs/tt.config >> .config
    # Disable ftrace on arm32: https://github.com/ClangBuiltLinux/linux/issues/35
    [[ $ARCH == "arm" ]] && ./scripts/config -d CONFIG_FTRACE
  fi
  # Make sure we build with CONFIG_DEBUG_SECTION_MISMATCH so that the
  # full warning gets printed and we can file and fix it properly.
  ./scripts/config -e DEBUG_SECTION_MISMATCH
  mako_reactor olddefconfig &>/dev/null
  mako_reactor ${image_name}
  [[ $ARCH =~ arm ]] && mako_reactor dtbs

  cd "${OLDPWD}"
}

boot_qemu() {
  local kernel_image=${tree}/arch/${ARCH}/boot/${image_name}
  test -e ${kernel_image}
  qemu=( timeout 2m unbuffer "${qemu}"
                             -m "${qemu_ram}"
                             "${qemu_cmdline[@]}"
                             -nographic
                             -kernel "${kernel_image}" )
  # For arm64, we want to test booting at both EL1 and EL2
  if [[ ${ARCH} = "arm64" ]]; then
    "${qemu[@]}" -machine virt
    "${qemu[@]}" -machine "virt,virtualization=true"
  else
    "${qemu[@]}"
  fi
}

setup_variables "${@}"
check_dependencies
build_linux
boot_qemu
