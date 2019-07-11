#!/usr/bin/env bash
# Takes a list of architectures to build images for as the parameter

function download_br() {
    mkdir -p src
    curl https://buildroot.org/downloads/buildroot-"${BUILDROOT_VERSION}".tar.gz | tar -xzf - -C src --strip-components=1
}

# Make sure we don't have any unset variables
set -u

# Move into the folder that contains this script
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" || exit 1

# Generate list of configs to build
CONFIGS=()
while (( ${#} )); do
    case ${1} in
        all) for CONFIG in *.config; do CONFIGS+=( "../${CONFIG}" ); done ;;
        arm64|arm|ppc32|ppc64le|x86_64) CONFIGS+=( "../${1}.config" ) ;;
        *) echo "Unknown parameter '${1}', exiting!"; exit 1 ;;
    esac
    shift
done

# Download latest buildroot release
BUILDROOT_VERSION=2019.02.3
if [[ -d src ]]; then
    if [[ $(cd src && make print-version | cut -d - -f 1 >/dev/null) != "${BUILDROOT_VERSION}" ]]; then
        rm -rf src
        download_br
    fi
else
    download_br
fi
cd src || exit 1

# Build the images for the architectures requested
for CONFIG in "${CONFIGS[@]}"; do
    # Clean up artifacts from the last build
    make clean

    BR2_DEFCONFIG=${CONFIG} make defconfig
    if [[ -n ${EDITCONFIG:-} ]]; then
        make menuconfig
        make savedefconfig
    fi

    # Build images
    make -j"$(nproc)"

    # Make sure images folder exists
    IMAGES_FOLDER=../../images/$(basename "${CONFIG//.config}")
    [[ ! -d ${IMAGES_FOLDER} ]] && mkdir -p "${IMAGES_FOLDER}"

    # Copy new images
    # Make sure images exist before moving them
    IMAGES=( "output/images/rootfs.cpio" "output/images/rootfs.ext4" )
    for IMAGE in "${IMAGES[@]}"; do
        if [[ ! -f ${IMAGE} ]]; then
            echo "${IMAGE} could not be found! Did the build error?"
            exit 1
        fi
        cp -v "${IMAGE}" "${IMAGES_FOLDER}"
    done
done
