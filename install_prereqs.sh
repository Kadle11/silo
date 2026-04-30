#!/usr/bin/env bash
set -e

echo "[1/6] Updating package lists..."
sudo apt update

echo "[2/6] Installing build toolchain..."
sudo apt install -y \
  build-essential \
  gcc \
  g++ \
  make

echo "[3/6] Installing autotools (Masstree requirement)..."
sudo apt install -y \
  autoconf \
  automake \
  libtool \
  pkg-config

echo "[4/6] Installing Silo/Masstree dependencies..."
sudo apt install -y \
  libdb++-dev \
  liblz4-dev \
  libaio-dev

echo "[5/6] Installing optional debugging tools..."
sudo apt install -y \
  gdb \
  strace

echo "[6/6] Done."

echo ""
echo "Verifying key tools:"
for cmd in g++ autoreconf pkg-config ldconfig; do
    command -v $cmd >/dev/null && echo "OK: $cmd" || echo "MISSING: $cmd"
done

echo ""
echo "Verifying key libraries:"
ldconfig -p | grep -E "aio|lz4|db_cxx" || true

echo ""
echo "Done. You can now rebuild Silo:"
echo "  cd apps/silo"
echo "  make clean"
echo "  MODE=perf make -j dbtest"
