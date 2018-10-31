#!/usr/bin/env bash

set -ux

check_dependencies() {
  set -e

  command -v nproc
  command -v gcc
  command -v aarch64-linux-gnu-as
  command -v aarch64-linux-gnu-ld
  command -v qemu-system-aarch64
  command -v timeout
  command -v unbuffer
  command -v clang-8

  set +e
}

parse_parameters() {
  while [[ $# -ge 1 ]]; do
    case $1 in
      "-c"|"--clean") cleanup=true ;;
    esac

    shift
  done
}

mako_reactor() {
  make -j"$(nproc)" CC="$clang" HOSTCC="$clang" "$@"
}

build_linux() {
  local clang
  clang=$(command -v clang-8)

  cd linux
  export ARCH=arm64
  export CROSS_COMPILE=aarch64-linux-gnu-
  # Only clean up old artifacts if requested, the Linux build system
  # is good about figuring out what needs to be rebuilt
  [[ -n "${cleanup:-}" ]] && mako_reactor mrproper
  mako_reactor defconfig
  mako_reactor Image.gz
  cd "$OLDPWD"
}

boot_qemu() {
  local kernel_image=linux/arch/${ARCH}/boot/Image.gz
  local rootfs=images/${ARCH}/rootfs.ext4
  # for the rest of the script, particularly qemu
  set -e
  test -e $kernel_image
  test -e $rootfs
  timeout 1m unbuffer qemu-system-aarch64 \
    -machine virt \
    -cpu cortex-a57 \
    -m 512 \
    -nographic \
    -kernel $kernel_image \
    -hda $rootfs \
    -append "console=ttyAMA0 root=/dev/vda"
}

check_dependencies
parse_parameters "$@"
build_linux
boot_qemu
