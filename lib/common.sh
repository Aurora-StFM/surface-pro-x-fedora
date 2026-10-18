# shellcheck shell=bash disable=SC2034
# Shared helpers for the Surface Pro X Fedora kit.

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KIT_DIR

# shellcheck source=../config.env
. "$KIT_DIR/config.env"

# Windows drives under WSL (/mnt/c, ...) don't support Linux permissions,
# symlinks or loop devices, which git, the kernel build and rpmbuild need.
case "$OUT_DIR" in
    /mnt/[a-zA-Z]/*)
        echo "error: OUT_DIR is on a Windows drive ($OUT_DIR)." >&2
        echo "       Copy the kit into your Linux home first, for example:" >&2
        echo "       rsync -a --exclude out \"$KIT_DIR/\" ~/surface-pro-x-fedora/ && cd ~/surface-pro-x-fedora" >&2
        exit 1 ;;
esac

KERNEL_RELEASE_STRING="${KERNEL_VERSION}-${KERNEL_PKG_RELEASE}.spx.aarch64"
RPM_DIR="$OUT_DIR/rpms"
WORK_DIR="$OUT_DIR/work"
SIGN_DIR="$OUT_DIR/signing"
SIGN_KEY_NAME="Surface Pro X local builds"
SIGN_PUBKEY="$SIGN_DIR/RPM-GPG-KEY-surface-pro-x-local"
SPX_DTB="qcom/sc8180x-surface-pro-x.dtb"

msg()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
msg2() { printf '\033[1;34m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmds() {
    local missing=() c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [ ${#missing[@]} -eq 0 ] || die "missing commands: ${missing[*]} (run: ./build.sh deps)"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "this step needs root, run it with sudo"
}

require_fedora_host() {
    [ -r /etc/os-release ] || die "cannot read /etc/os-release"
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "fedora" ] || die "run this on Fedora (native or WSL); found ${ID:-unknown}"
}

# fetch URL DEST SHA256
fetch_verified() {
    local url="$1" dest="$2" sum="$3"
    if [ ! -f "$dest" ]; then
        msg2 "downloading $(basename "$dest")"
        curl -fL --retry 3 -o "$dest.part" "$url"
        mv "$dest.part" "$dest"
    fi
    echo "$sum  $dest" | sha256sum -c --quiet - || die "checksum mismatch for $dest"
}

# Create a passwordless local signing key on first use. Fedora 45 rejects
# unsigned packages, so every RPM in this kit is signed with it.
ensure_signing_key() {
    export GNUPGHOME="$SIGN_DIR/gnupg"
    if [ ! -d "$GNUPGHOME" ]; then
        msg2 "creating local RPM signing key"
        mkdir -p "$GNUPGHOME"
        chmod 700 "$GNUPGHOME"
        gpg --batch --passphrase '' --quick-gen-key \
            "$SIGN_KEY_NAME <spx@localhost>" rsa4096 sign never
    fi
    [ -f "$SIGN_PUBKEY" ] || gpg --armor --export "$SIGN_KEY_NAME" > "$SIGN_PUBKEY"
}

sign_rpms() {
    ensure_signing_key
    rpmsign --define "_gpg_name $SIGN_KEY_NAME" --define "_gpg_path $GNUPGHOME" \
        --addsign "$@" >/dev/null
}
