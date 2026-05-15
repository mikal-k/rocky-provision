#!/usr/bin/env bash

# Ingen set -e her. Eksplisitt feilhåndtering i run().

VM_NAME="${VM_NAME:-rocky-10-test}"
VM_HOSTNAME="${VM_HOSTNAME:-rocky-vm}"
VM_USER="${VM_USER:-rocky}"

ROCKY_ISO="${ROCKY_ISO:-$HOME/Downloads/Rocky-10.1-x86_64-minimal.iso}"

RAM_MB="${RAM_MB:-4096}"
CPUS="${CPUS:-2}"
DISK_MB="${DISK_MB:-40960}"
SSH_PORT="${SSH_PORT:-2222}"

VM_BASEFOLDER="${VM_BASEFOLDER:-$HOME/VirtualBox VMs}"
ROCKY_PASSWORD="${ROCKY_PASSWORD:-rocky}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
OEM_DIR="$BUILD_DIR/oemdrv"
OEM_ISO="$BUILD_DIR/oemdrv.iso"
KS_TEMPLATE="$SCRIPT_DIR/ks.cfg.template"
KS_FILE="$OEM_DIR/ks.cfg"

DISK_PATH="$VM_BASEFOLDER/$VM_NAME/$VM_NAME.vdi"

run() {
    echo "+ $*"
    "$@"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FEIL: Kommando feilet med exitkode $rc"
        exit "$rc"
    fi
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Mangler kommando: $1"
        exit 1
    fi
}

need_cmd VBoxManage
need_cmd python3
need_cmd openssl

if command -v genisoimage >/dev/null 2>&1; then
    ISO_CMD="genisoimage"
elif command -v mkisofs >/dev/null 2>&1; then
    ISO_CMD="mkisofs"
else
    echo "Mangler genisoimage/mkisofs."
    echo "På Mint/Ubuntu: sudo apt install genisoimage"
    exit 1
fi

if [ ! -f "$ROCKY_ISO" ]; then
    echo "Finner ikke Rocky ISO:"
    echo "  $ROCKY_ISO"
    echo
    echo "Sett path slik:"
    echo "  ROCKY_ISO=/path/to/Rocky-10.1-x86_64-minimal.iso $0"
    exit 1
fi

if [ ! -f "$KS_TEMPLATE" ]; then
    echo "Finner ikke:"
    echo "  $KS_TEMPLATE"
    exit 1
fi

if VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; then
    if [ "$RECREATE" = "1" ]; then
        run VBoxManage unregistervm "$VM_NAME" --delete
    else
        echo "VM finnes allerede: $VM_NAME"
        echo "Kjør med RECREATE=1 hvis den skal slettes:"
        echo "  RECREATE=1 $0"
        exit 1
    fi
fi

SSH_PUBKEY=""
if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    SSH_PUBKEY="$(cat "$HOME/.ssh/id_ed25519.pub")"
elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    SSH_PUBKEY="$(cat "$HOME/.ssh/id_rsa.pub")"
else
    echo "Fant ingen SSH public key i ~/.ssh/id_ed25519.pub eller ~/.ssh/id_rsa.pub"
    echo "Lag en først:"
    echo "  ssh-keygen -t ed25519"
    exit 1
fi

PASSWORD_HASH="$(printf '%s' "$ROCKY_PASSWORD" | openssl passwd -6 -stdin)"

rm -rf "$BUILD_DIR"
mkdir -p "$OEM_DIR"

export VM_HOSTNAME VM_USER PASSWORD_HASH SSH_PUBKEY KS_TEMPLATE KS_FILE

python3 <<'PY'
import os
from pathlib import Path

template = Path(os.environ["KS_TEMPLATE"]).read_text()

replacements = {
    "__VM_HOSTNAME__": os.environ["VM_HOSTNAME"],
    "__VM_USER__": os.environ["VM_USER"],
    "__PASSWORD_HASH__": os.environ["PASSWORD_HASH"],
    "__SSH_PUBKEY__": os.environ["SSH_PUBKEY"],
}

for key, value in replacements.items():
    template = template.replace(key, value)

Path(os.environ["KS_FILE"]).write_text(template)
PY

run "$ISO_CMD" -output "$OEM_ISO" -volid OEMDRV -joliet -rock "$OEM_DIR"

run VBoxManage createvm \
    --name "$VM_NAME" \
    --ostype RedHat_64 \
    --register \
    --basefolder "$VM_BASEFOLDER"

run VBoxManage modifyvm "$VM_NAME" \
    --memory "$RAM_MB" \
    --cpus "$CPUS" \
    --ioapic on \
    --vram 16 \
    --graphicscontroller vmsvga \
    --nic1 nat \
    --natpf1 "ssh,tcp,127.0.0.1,$SSH_PORT,,22" \
    --paravirtprovider kvm \
    --firmware bios \
    --clipboard bidirectional \
    --boot1 disk \
    --boot2 dvd \
    --boot3 none \
    --boot4 none

run VBoxManage storagectl "$VM_NAME" \
    --name "SATA Controller" \
    --add sata \
    --controller IntelAhci

run VBoxManage createmedium disk \
    --filename "$DISK_PATH" \
    --size "$DISK_MB" \
    --format VDI

run VBoxManage storageattach "$VM_NAME" \
    --storagectl "SATA Controller" \
    --port 0 \
    --device 0 \
    --type hdd \
    --medium "$DISK_PATH"

run VBoxManage storageattach "$VM_NAME" \
    --storagectl "SATA Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium "$ROCKY_ISO"

run VBoxManage storageattach "$VM_NAME" \
    --storagectl "SATA Controller" \
    --port 2 \
    --device 0 \
    --type dvddrive \
    --medium "$OEM_ISO"

run VBoxManage startvm "$VM_NAME" --type gui

echo
echo "Startet VM: $VM_NAME"
echo
echo "Når installasjonen er ferdig:"
echo "  ssh -p $SSH_PORT $VM_USER@127.0.0.1"
echo
echo "Default lab-passord:"
echo "  $ROCKY_PASSWORD"
echo
echo "Du kan overstyre f.eks:"
echo "  VM_NAME=rocky-zabbix RAM_MB=4096 CPUS=2 DISK_MB=40960 SSH_PORT=2223 $0"
