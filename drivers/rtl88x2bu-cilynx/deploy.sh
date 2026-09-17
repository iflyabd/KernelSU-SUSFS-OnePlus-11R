#!/bin/bash

set -euo pipefail

TARGET_KERNEL=
VERBOSE=false

function main() {
    local VERSION
    VERSION="$(get_version)"
    parse-cli-args "$@"
    ensure_root_permissions
    put_sources_in_place "$VERSION"
    deploy_driver "$VERSION"
}

function get_version() {
    sed -En 's/PACKAGE_VERSION="(.*)"/\1/p' dkms.conf
}

function parse-cli-args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v | --verbose)
                VERBOSE=true
                shift
                ;;
            -h | --help)
                print-usage
                exit 0
                ;;
            *)
                if [[ -n "${TARGET_KERNEL}" ]]; then
                    echo "Only one target kernel can be specified!" >&2
                    exit 1
                fi
                TARGET_KERNEL="$1"
                shift
                ;;
        esac
    done
}

function print-usage() {
    cat <<EOF
Usage: $0 [-v|--verbose|TARGET_KERNEL]..

Deploy the rtl88x2bu driver to the system. If TARGET_KERNEL is not specified,
the driver will be deployed to all available kernels.

Options:
  -h, --help        Show this help message and exit
  -v, --verbose     Enable verbose output
  TARGET_KERNEL     Specify the target kernel version to deploy the driver to.
                    If not specified, the script will deploy to all available
                    kernels.

Examples:

$0
$0 -v \$(uname -r)
$0 6.12.17-amd64

This script will ask for root permissions to deploy the driver.
EOF
}

function ensure_root_permissions() {
    if ! sudo -v; then
        echo "Root permissions required to deploy the driver!" >&2
        exit 1
    fi
}

function put_sources_in_place() {
    local VERSION="$1"
    sudo rsync --delete --exclude=.git -rvhP ./ "/usr/src/rtl88x2bu-${VERSION}" >/dev/null
    log "Sources copied to /usr/src/rtl88x2bu-${VERSION}"
}

function deploy_driver() {
    local VERSION="$1"
    sudo dkms "add" -m rtl88x2bu -v "${VERSION}" || true
    list-kernels |
        while read -r kernel; do
            for action in build install; do
                sudo dkms "${action}" -m rtl88x2bu -v "${VERSION}" -k "${kernel}"
            done
        done
    sudo modprobe 88x2bu
}

function list-kernels() {
    if [[ -n "${TARGET_KERNEL}" ]]; then
        echo "${TARGET_KERNEL}"
    else
        find /boot -maxdepth 1 -iname "initrd.img*" |
            cut -d- -f2-
        echo "${TARGET_KERNEL}"
    fi
}

function log() {
    if [[ "$VERBOSE" = "true" ]]; then
        echo "$1"
    fi
}

main "$@"
