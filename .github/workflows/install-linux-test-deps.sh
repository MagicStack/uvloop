#!/usr/bin/env bash
set -euo pipefail

# cryptography has no CPython 3.15t wheels yet. These dependencies are only
# needed to build test dependencies inside the cibuildwheel container.
if command -v apk >/dev/null 2>&1; then
    apk add --no-cache openssl-dev libffi-dev pkgconf
else
    # manylinux_2_28 ships OpenSSL 1.1.1; cryptography needs OpenSSL 3.
    yum install -y openssl3-devel libffi-devel pkgconfig
    # EPEL names its pkg-config file openssl3.pc; the build looks for openssl.
    mkdir -p /usr/local/lib/pkgconfig
    ln -s /usr/lib64/pkgconfig/openssl3.pc /usr/local/lib/pkgconfig/openssl.pc
fi
