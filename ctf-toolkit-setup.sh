#!/usr/bin/env bash
#
# ctf-toolkit-setup.sh
# Installs a broad CTF toolset on Ubuntu (apt + pip + gem + GitHub releases).
# Architecture-aware: works on x86_64 and ARM64 (e.g. Apple-silicon VMs).
# Works as a normal sudo user OR as root (e.g. inside a rootless container).
#
# Usage:
#   chmod +x ctf-toolkit-setup.sh
#   ./ctf-toolkit-setup.sh                  # full toolkit
#   ./ctf-toolkit-setup.sh --with-ghidra    # also download + unpack Ghidra
#   ./ctf-toolkit-setup.sh --no-heavy        # skip slow giants (sagemath, angr)
#   ./ctf-toolkit-setup.sh --no-extras       # apt + pip core only (no gem/git/Go tools)
#
# Env:
#   GITHUB_TOKEN   if set, used to authenticate GitHub API calls (avoids rate limits)
#
# Exit code is non-zero if any tool needs manual attention.

set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

APT_LOG="/tmp/ctf_apt_install.log"
PIP_LOG="/tmp/ctf_pip_install.log"

FAILED=()
TMPDIRS=()

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; }

# Clean up any temp dirs on exit/interrupt.
cleanup() { [[ ${#TMPDIRS[@]} -gt 0 ]] && rm -rf "${TMPDIRS[@]}" 2>/dev/null; }
trap cleanup EXIT INT TERM
mktempd() { local d; d=$(mktemp -d); TMPDIRS+=("$d"); echo "$d"; }

# ---------------------------------------------------------------------------
# Argument parsing (order-independent)
# ---------------------------------------------------------------------------
WITH_GHIDRA=false
NO_HEAVY=false
NO_EXTRAS=false
for arg in "$@"; do
    case "$arg" in
        --with-ghidra) WITH_GHIDRA=true ;;
        --no-heavy)    NO_HEAVY=true ;;
        --no-extras)   NO_EXTRAS=true ;;
        -h|--help)
            echo "Usage: $0 [--with-ghidra] [--no-heavy] [--no-extras]"
            echo "  --with-ghidra  also download + unpack Ghidra"
            echo "  --no-heavy     skip sagemath and angr (big/slow)"
            echo "  --no-extras    apt + pip core only (skip Go/gem/git tools)"
            exit 0
            ;;
        *) warn "Unknown argument: $arg (ignored)" ;;
    esac
done

# ---------------------------------------------------------------------------
# Privilege: use sudo only when not already root (works in rootless containers)
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    command -v sudo &>/dev/null || { err "Not root and sudo not found — cannot install."; exit 1; }
    sudo -v || { err "sudo authentication failed."; exit 1; }
    SUDO="sudo"
fi

# Non-interactive apt + pre-answer the Wireshark "allow non-root capture" prompt.
export DEBIAN_FRONTEND=noninteractive
echo "wireshark-common wireshark-common/install-setuid boolean true" \
    | $SUDO debconf-set-selections 2>/dev/null || true

# Detect Debian architecture (amd64 / arm64) for arch-specific downloads.
ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
log "Detected architecture: $ARCH"

# Prefer pip, fall back to pip3.
PIP=$(command -v pip || command -v pip3 || echo pip)

# curl with fail-on-error + retries; GitHub API auth if a token is present.
CURL=(curl -fsSL --retry 3 --retry-delay 2)
GH_AUTH=()
[[ -n "${GITHUB_TOKEN:-}" ]] && { GH_AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN"); log "Using GITHUB_TOKEN for API calls"; }
gh_api() { "${CURL[@]}" "${GH_AUTH[@]}" "$1"; }
dl()     { "${CURL[@]}" -o "$1" "$2"; }

: > "$APT_LOG"
: > "$PIP_LOG"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Batch-install missing apt packages in one call; fall back to per-package on error.
install_apt() {
    local todo=() pkg
    for pkg in "$@"; do
        if dpkg -s "$pkg" &>/dev/null; then
            log "$pkg already installed, skipping"
        else
            todo+=("$pkg")
        fi
    done
    [[ ${#todo[@]} -eq 0 ]] && return
    log "Installing ${#todo[@]} packages: ${todo[*]}"
    if $SUDO apt-get install -y "${todo[@]}" >>"$APT_LOG" 2>&1; then
        return
    fi
    warn "Batch install hit an error — retrying individually to isolate failures..."
    for pkg in "${todo[@]}"; do
        dpkg -s "$pkg" &>/dev/null && continue
        log "Installing $pkg..."
        if ! $SUDO apt-get install -y "$pkg" >>"$APT_LOG" 2>&1; then
            err "Failed to install $pkg (see $APT_LOG)"
            FAILED+=("apt:$pkg")
        fi
    done
}

# install_github_deb <owner/repo> <asset-pattern> <command-name>
install_github_deb() {
    local repo="$1" pattern="$2" name="$3"
    if command -v "$name" &>/dev/null; then
        log "$name already installed, skipping"
        return
    fi
    log "Installing $name from $repo (GitHub release)..."
    local url
    url=$(gh_api "https://api.github.com/repos/$repo/releases/latest" \
        | grep "browser_download_url.*$pattern" | cut -d '"' -f4 | head -1)
    if [[ -z "$url" ]]; then
        err "Couldn't resolve a download URL for $name (rate limited? set GITHUB_TOKEN)"
        FAILED+=("gh:$name")
        return
    fi
    local tmp="/tmp/${name}.deb"
    log "Downloading $url"
    if ! dl "$tmp" "$url"; then
        err "Download failed for $name"
        FAILED+=("gh:$name")
        rm -f "$tmp"
        return
    fi
    if ! $SUDO apt-get install -y "$tmp" >>"$APT_LOG" 2>&1; then
        err "Failed to install $name (see $APT_LOG)"
        FAILED+=("gh:$name")
    fi
    rm -f "$tmp"
}

# feroxbuster ships per-arch zips: amd64 → a zipped .deb, arm64 → a zipped raw binary.
install_feroxbuster() {
    if command -v feroxbuster &>/dev/null; then
        log "feroxbuster already installed, skipping"
        return
    fi
    local asset
    case "$ARCH" in
        amd64) asset="feroxbuster_amd64.deb.zip" ;;
        arm64) asset="aarch64-linux-feroxbuster.zip" ;;
        armhf) asset="armv7-linux-feroxbuster.zip" ;;
        *)     warn "No feroxbuster build for $ARCH — see https://github.com/epi052/feroxbuster/releases"
               FAILED+=("feroxbuster"); return ;;
    esac

    log "Installing feroxbuster ($asset) for $ARCH..."
    local url
    url=$(gh_api https://api.github.com/repos/epi052/feroxbuster/releases/latest \
        | grep "browser_download_url.*${asset}" | cut -d '"' -f4 | head -1)
    if [[ -z "$url" ]]; then
        err "Couldn't resolve feroxbuster download URL for $ARCH"
        FAILED+=("feroxbuster"); return
    fi

    local work; work=$(mktempd)
    if ! dl "$work/ferox.zip" "$url"; then
        err "feroxbuster download failed"; FAILED+=("feroxbuster"); return
    fi
    unzip -oq "$work/ferox.zip" -d "$work"

    if [[ "$ARCH" == "amd64" ]]; then
        if ! $SUDO apt-get install -y "$work"/*.deb >>"$APT_LOG" 2>&1; then
            err "feroxbuster .deb install failed (see $APT_LOG)"; FAILED+=("feroxbuster")
        fi
    else
        if [[ -f "$work/feroxbuster" ]]; then
            $SUDO install -m 0755 "$work/feroxbuster" /usr/local/bin/feroxbuster
            log "feroxbuster installed to /usr/local/bin"
        else
            err "feroxbuster binary not found in archive"; FAILED+=("feroxbuster")
        fi
    fi
}

# install_release_archive <repo> <asset-regex> <binary-name>
# Downloads a .tar.gz/.zip release asset, extracts <binary-name>, installs to /usr/local/bin.
# Used for Go tools (ffuf, nuclei, httpx) whose assets are named linux_<arch>.
install_release_archive() {
    local repo="$1" pattern="$2" name="$3"
    if command -v "$name" &>/dev/null; then
        log "$name already installed, skipping"; return
    fi
    log "Installing $name from $repo for $ARCH..."
    local url
    url=$(gh_api "https://api.github.com/repos/$repo/releases/latest" \
        | grep -E "browser_download_url.*${pattern}" | cut -d '"' -f4 | head -1)
    if [[ -z "$url" ]]; then
        err "Couldn't resolve $name download URL for $ARCH"; FAILED+=("gh:$name"); return
    fi
    local work; work=$(mktempd)
    local file="$work/${url##*/}"
    if ! dl "$file" "$url"; then
        err "$name download failed"; FAILED+=("gh:$name"); return
    fi
    case "$file" in
        *.tar.gz|*.tgz) tar -xzf "$file" -C "$work" ;;
        *.zip)          unzip -oq "$file" -d "$work" ;;
        *)              err "Unknown archive type for $name"; FAILED+=("gh:$name"); return ;;
    esac
    local bin
    bin=$(find "$work" -type f -name "$name" | head -1)
    if [[ -n "$bin" ]]; then
        $SUDO install -m 0755 "$bin" "/usr/local/bin/$name"
        log "$name installed to /usr/local/bin"
    else
        err "$name binary not found in archive"; FAILED+=("gh:$name")
    fi
}

# pwninit: single x86_64 binary on GitHub; on other arches fall back to cargo.
install_pwninit() {
    if command -v pwninit &>/dev/null; then log "pwninit already installed, skipping"; return; fi
    if [[ "$ARCH" == "amd64" ]]; then
        log "Installing pwninit (GitHub binary)..."
        local url
        url=$(gh_api https://api.github.com/repos/io12/pwninit/releases/latest \
            | grep 'browser_download_url.*pwninit"' | cut -d '"' -f4 | head -1)
        if [[ -z "$url" ]]; then err "Couldn't resolve pwninit URL"; FAILED+=("gh:pwninit"); return; fi
        local tmp; tmp=$(mktemp)
        if dl "$tmp" "$url"; then
            $SUDO install -m 0755 "$tmp" /usr/local/bin/pwninit
            log "pwninit installed to /usr/local/bin"
        else
            err "pwninit download failed"; FAILED+=("gh:pwninit")
        fi
        rm -f "$tmp"
    elif command -v cargo &>/dev/null; then
        log "Building pwninit via cargo for $ARCH (slow)..."
        cargo install pwninit >>"$APT_LOG" 2>&1 || { err "cargo install pwninit failed"; FAILED+=("cargo:pwninit"); }
    else
        warn "pwninit has no $ARCH prebuilt and cargo isn't installed."
        warn "  Install Rust (https://rustup.rs) then: cargo install pwninit"
        FAILED+=("pwninit")
    fi
}

# GEF: GDB exploitation UI (writes ~/.gdbinit). Arch-independent (pure Python).
install_gef() {
    if [[ -f "$HOME/.gdbinit-gef.py" ]] || grep -q gef "$HOME/.gdbinit" 2>/dev/null; then
        log "GEF already installed, skipping"; return
    fi
    log "Installing GEF (GDB enhancement)..."
    if ! bash -c "$("${CURL[@]}" https://gef.blah.cat/sh)" >>"$APT_LOG" 2>&1; then
        err "GEF install failed (see $APT_LOG)"; FAILED+=("gef")
    fi
}

# Ruby gems: zsteg (PNG/BMP stego), one_gadget (libc one-shot RCE), wpscan.
install_gems() {
    if ! command -v gem &>/dev/null; then
        warn "ruby/gem not available — skipping zsteg, one_gadget, wpscan"
        FAILED+=("gems:ruby-missing"); return
    fi
    local g
    for g in zsteg one_gadget wpscan; do
        if gem list -i "$g" &>/dev/null; then log "$g already installed, skipping"; continue; fi
        log "Installing $g (gem)..."
        if ! $SUDO gem install "$g" >>"$APT_LOG" 2>&1; then
            err "gem install $g failed (see $APT_LOG)"; FAILED+=("gem:$g")
        fi
    done
}

# RsaCtfTool: automated RSA attacks. Cloned to ~/tools, deps via pip.
install_rsactftool() {
    local dir="$HOME/tools/RsaCtfTool"
    if [[ -d "$dir" ]]; then
        log "RsaCtfTool already present — updating..."
        git -C "$dir" pull --ff-only >>"$APT_LOG" 2>&1 || warn "RsaCtfTool update skipped"
        return
    fi
    log "Cloning RsaCtfTool..."
    mkdir -p "$HOME/tools"
    if ! git clone --depth 1 https://github.com/RsaCtfTool/RsaCtfTool "$dir" >>"$APT_LOG" 2>&1; then
        err "RsaCtfTool clone failed"; FAILED+=("RsaCtfTool"); return
    fi
    if [[ -f "$dir/requirements.txt" ]]; then
        "$PIP" install -r "$dir/requirements.txt" --break-system-packages >>"$PIP_LOG" 2>&1 \
            || { warn "Some RsaCtfTool deps failed — see $PIP_LOG"; FAILED+=("RsaCtfTool-deps"); }
    fi
    log "RsaCtfTool ready: python3 $dir/RsaCtfTool.py"
}

# CMDR: command manager for CTF/pentest (https://github.com/SP1R4/CMDR).
# Cloned to ~/tools/CMDR; its own installer adds a 'cmdr' alias + tab completion.
install_cmdr() {
    local dir="$HOME/tools/CMDR"
    if [[ -d "$dir/.git" ]]; then
        log "CMDR already present — updating..."
        git -C "$dir" pull --ff-only >>"$APT_LOG" 2>&1 || warn "CMDR update skipped"
    else
        log "Cloning CMDR..."
        mkdir -p "$HOME/tools"
        if ! git clone --depth 1 https://github.com/SP1R4/CMDR "$dir" >>"$APT_LOG" 2>&1; then
            err "CMDR clone failed"; FAILED+=("CMDR"); return
        fi
    fi
    # Run its installer non-interactively (feed '1' = default shell-alias method).
    log "Running CMDR installer (adds 'cmdr' alias + completion to your shell rc)..."
    if printf '1\n' | bash "$dir/install.sh" >>"$APT_LOG" 2>&1; then
        log "CMDR installed — open a new shell (or source your rc), then run: cmdr -h"
    else
        warn "CMDR installer reported an issue (see $APT_LOG) — run manually: bash $dir/install.sh"
        FAILED+=("CMDR-install")
    fi
    # Seed the companion pack so CMDR's commands match this toolkit's binaries.
    if [[ -f "$dir/packs/ctf-toolkit.json" ]]; then
        log "Seeding CMDR with the ctf-toolkit command pack..."
        if bash "$dir/cmdr.sh" --pack load ctf-toolkit >>"$APT_LOG" 2>&1; then
            log "CMDR seeded — try: cmdr -s tk-"
        else
            warn "Could not load ctf-toolkit pack (see $APT_LOG) — run: cmdr --pack load ctf-toolkit"
        fi
    else
        warn "ctf-toolkit pack not found in this CMDR checkout — update CMDR, then: cmdr --pack load ctf-toolkit"
    fi
}

# hashcracker: hash ID + cracking toolkit (https://github.com/SP1R4/hashcracker).
# pyproject package with a 'hashcracker' console script — installed via pipx (isolated).
install_hashcracker() {
    if command -v hashcracker &>/dev/null; then log "hashcracker already installed, skipping"; return; fi
    local src="git+https://github.com/SP1R4/hashcracker"
    if command -v pipx &>/dev/null; then
        log "Installing hashcracker (pipx)..."
        if pipx install "$src" >>"$PIP_LOG" 2>&1; then
            pipx ensurepath >>"$PIP_LOG" 2>&1 || true
            log "hashcracker installed via pipx"
            return
        fi
        warn "pipx install failed — falling back to pip"
    fi
    log "Installing hashcracker (pip)..."
    if "$PIP" install "$src" --break-system-packages >>"$PIP_LOG" 2>&1; then
        log "hashcracker installed via pip"
    else
        err "hashcracker install failed (see $PIP_LOG)"; FAILED+=("hashcracker")
    fi
}

# Qsafe: post-quantum file encryption, Kyber1024 + AES-256-GCM (https://github.com/SP1R4/Qsafe).
# C tool built with make; needs OpenSSL 3 + liboqs. liboqs isn't in apt, so build it
# from source (library only) into /usr/local, then build+install qsafe on top.
install_qsafe() {
    if command -v qsafe &>/dev/null; then log "qsafe already installed, skipping"; return; fi

    # OpenSSL headers for the link step (build-essential/cmake/git come from the core apt set).
    install_apt libssl-dev

    # liboqs (ML-KEM-1024). Build + install once; skip if it's already on the system.
    if ldconfig -p 2>/dev/null | grep -q liboqs || [[ -f /usr/local/include/oqs/oqs.h ]]; then
        log "liboqs already present, skipping its build"
    else
        log "Building liboqs from source (required by qsafe)..."
        local oqs; oqs=$(mktempd)
        if ! git clone --depth 1 --branch 0.12.0 https://github.com/open-quantum-safe/liboqs "$oqs/src" >>"$APT_LOG" 2>&1; then
            err "liboqs clone failed"; FAILED+=("qsafe-liboqs"); return
        fi
        if ! cmake -S "$oqs/src" -B "$oqs/build" -DCMAKE_BUILD_TYPE=Release -DOQS_BUILD_ONLY_LIB=ON >>"$APT_LOG" 2>&1 \
            || ! cmake --build "$oqs/build" -j"$(nproc)" >>"$APT_LOG" 2>&1; then
            err "liboqs build failed (see $APT_LOG)"; FAILED+=("qsafe-liboqs"); return
        fi
        $SUDO cmake --install "$oqs/build" >>"$APT_LOG" 2>&1
        $SUDO ldconfig
    fi

    # Build + install Qsafe itself (binary + man page into /usr/local).
    local dir="$HOME/tools/Qsafe"
    if [[ -d "$dir/.git" ]]; then
        log "Qsafe already present — updating..."
        git -C "$dir" pull --ff-only >>"$APT_LOG" 2>&1 || warn "Qsafe update skipped"
    else
        log "Cloning Qsafe..."
        mkdir -p "$HOME/tools"
        if ! git clone --depth 1 https://github.com/SP1R4/Qsafe "$dir" >>"$APT_LOG" 2>&1; then
            err "Qsafe clone failed"; FAILED+=("qsafe"); return
        fi
    fi
    log "Building Qsafe..."
    if ! make -C "$dir" >>"$APT_LOG" 2>&1; then
        err "Qsafe build failed (see $APT_LOG)"; FAILED+=("qsafe"); return
    fi
    if $SUDO make -C "$dir" install >>"$APT_LOG" 2>&1; then
        $SUDO ldconfig 2>/dev/null || true
        log "qsafe installed to /usr/local/bin"
    else
        err "Qsafe install failed (see $APT_LOG)"; FAILED+=("qsafe")
    fi
}

# ---------------------------------------------------------------------------
# Update package lists (bail if this fails — stale lists break everything)
# ---------------------------------------------------------------------------
log "Updating package lists..."
if ! $SUDO apt-get update; then
    err "apt update failed — check your network/sources before continuing."
    exit 1
fi

# ---------------------------------------------------------------------------
# Core apt packages
# ---------------------------------------------------------------------------
APT_PACKAGES=(
    # web / recon
    nmap gobuster sqlmap nikto whatweb wfuzz dirb seclists
    enum4linux snmp dnsrecon
    # binary exploitation / reverse engineering
    gdb gdb-multiarch radare2 binwalk checksec ltrace strace
    build-essential cmake libffi-dev python3-dev
    qemu-user-static patchelf libc6-dbg
    # password cracking
    john hashcat hydra fcrackzip pdfcrack
    # forensics / steganography
    exiftool foremost steghide file binutils
    outguess pngcheck sleuthkit testdisk bulk-extractor
    # networking / packet analysis
    wireshark tshark netcat-openbsd socat tcpdump
    proxychains4 dnsutils whois masscan
    # misc essentials
    git python3-pip jq unzip p7zip-full
    ripgrep fd-find tmux pipx
    # ruby (for zsteg / one_gadget / wpscan gems)
    ruby ruby-dev libcurl4-openssl-dev
)

# sagemath is large (~1.5 GB); skip with --no-heavy
$NO_HEAVY || APT_PACKAGES+=(sagemath)

# xxd is a standalone package only on 24.04+; on older releases it lives in vim-common
. /etc/os-release 2>/dev/null || true
if [[ -n "${VERSION_ID:-}" ]] && (( ${VERSION_ID%%.*} >= 24 )); then
    APT_PACKAGES+=(xxd)
else
    APT_PACKAGES+=(vim-common)
fi

install_apt "${APT_PACKAGES[@]}"

# seclists ships rockyou gzipped; extract it to the canonical path so tools
# (john, hashcat, hydra, stegseek, ...) and the CMDR ctf-toolkit pack find it.
if [[ ! -f /usr/share/wordlists/rockyou.txt ]]; then
    ROCKYOU_GZ=$(ls /usr/share/seclists/Passwords/Leaked-Databases/rockyou.txt.tar.gz 2>/dev/null | head -1)
    if [[ -n "${ROCKYOU_GZ:-}" ]]; then
        log "Extracting rockyou.txt to /usr/share/wordlists/..."
        $SUDO mkdir -p /usr/share/wordlists
        if $SUDO tar -xzf "$ROCKYOU_GZ" -C /usr/share/wordlists/ >>"$APT_LOG" 2>&1; then
            log "rockyou.txt ready at /usr/share/wordlists/rockyou.txt"
        else
            warn "rockyou extraction failed (see $APT_LOG)"; FAILED+=("rockyou")
        fi
    else
        warn "rockyou.txt.tar.gz not found under seclists — skipping extraction"
    fi
fi

# ---------------------------------------------------------------------------
# Tools that aren't in apt — install from GitHub releases (arch-aware)
# ---------------------------------------------------------------------------
install_feroxbuster

# stegseek: only an amd64 .deb is published (name carries no arch); no ARM binary.
if [[ "$ARCH" == "amd64" ]]; then
    install_github_deb "RickdeJager/stegseek" "\.deb" "stegseek"
else
    warn "stegseek has no prebuilt $ARCH package — build from source:"
    warn "  https://github.com/RickdeJager/stegseek#building-from-source"
    FAILED+=("stegseek")
fi

if ! $NO_EXTRAS; then
    # Go-based web tools — per-arch tar.gz/zip (asset names use linux_amd64 / linux_arm64).
    install_release_archive "ffuf/ffuf"               "linux_${ARCH}\.tar\.gz" "ffuf"
    install_release_archive "projectdiscovery/nuclei" "linux_${ARCH}\.zip"     "nuclei"
    install_release_archive "projectdiscovery/httpx"  "linux_${ARCH}\.zip"     "httpx"

    # pwn / re / crypto helpers (GitHub binaries, GEF, Ruby gems, RsaCtfTool)
    install_pwninit
    install_gef
    install_gems
    install_rsactftool
    install_cmdr
    install_hashcracker
    install_qsafe
else
    warn "--no-extras: skipping ffuf, nuclei, httpx, pwninit, GEF, gems, RsaCtfTool, CMDR, hashcracker, qsafe"
fi

# ---------------------------------------------------------------------------
# Python packages
# ---------------------------------------------------------------------------
log "Installing Python packages..."
PIP_PACKAGES=(
    pwntools volatility3 pycryptodome sympy
    impacket ROPgadget ropper z3-solver gmpy2
)
$NO_HEAVY || PIP_PACKAGES+=(angr)
for pkg in "${PIP_PACKAGES[@]}"; do
    if ! "$PIP" install "$pkg" --break-system-packages >>"$PIP_LOG" 2>&1; then
        err "Failed to install $pkg via pip (see $PIP_LOG)"
        FAILED+=("pip:$pkg")
    fi
done

# ---------------------------------------------------------------------------
# Optional: Ghidra
# ---------------------------------------------------------------------------
if $WITH_GHIDRA; then
    log "Installing Ghidra (requires a JDK)..."
    if ! $SUDO apt-get install -y openjdk-21-jdk >>"$APT_LOG" 2>&1; then
        err "JDK install failed — Ghidra won't run. See $APT_LOG"
        FAILED+=("openjdk-21-jdk")
    fi

    GHIDRA_URL=$(gh_api https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest \
        | grep '"browser_download_url.*\.zip"' | cut -d '"' -f4 | head -1)

    if [[ -n "${GHIDRA_URL:-}" ]]; then
        if mkdir -p ~/tools && cd ~/tools; then
            rm -f ghidra_*.zip
            log "Downloading $GHIDRA_URL"
            if dl "${GHIDRA_URL##*/}" "$GHIDRA_URL" && unzip -oq ghidra_*.zip; then
                log "Ghidra unpacked into ~/tools/"
            else
                err "Ghidra download/unpack failed"
                FAILED+=("ghidra")
            fi
        else
            err "Could not enter ~/tools"
            FAILED+=("ghidra")
        fi
    else
        warn "Could not resolve latest Ghidra release URL — grab it manually from"
        warn "https://github.com/NationalSecurityAgency/ghidra/releases"
        FAILED+=("ghidra")
    fi
fi

# ---------------------------------------------------------------------------
# Reclaim disk
# ---------------------------------------------------------------------------
$SUDO apt-get clean >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Verification table
# ---------------------------------------------------------------------------
echo
log "Verifying installed tools (command availability):"
# Include pipx/user install dir so pipx-installed tools (hashcracker) are found.
export PATH="$HOME/.local/bin:$PATH"
VERIFY_CMDS=(
    nmap gobuster sqlmap nikto whatweb wfuzz feroxbuster ffuf nuclei httpx
    gdb gdb-multiarch radare2 checksec pwninit patchelf ROPgadget ropper
    john hashcat hydra fcrackzip pdfcrack hashcracker qsafe
    exiftool foremost steghide stegseek zsteg one_gadget outguess pngcheck
    wireshark tshark tcpdump masscan proxychains4 dig whois
    enum4linux snmpwalk dnsrecon
    rg fdfind tmux jq xxd sage wpscan
    python3 "$PIP"
)
for c in "${VERIFY_CMDS[@]}"; do
    if command -v "$c" &>/dev/null; then
        printf "  ${GREEN}✓${NC} %s\n" "$c"
    else
        printf "  ${RED}✗${NC} %s\n" "$c"
    fi
done
# Python importable modules (names differ from pip names)
for m in pwntools Crypto sympy z3 gmpy2 impacket angr volatility3; do
    if python3 -c "import $m" &>/dev/null; then
        printf "  ${GREEN}✓${NC} py:%s\n" "$m"
    else
        printf "  ${RED}✗${NC} py:%s\n" "$m"
    fi
done
# Cloned tools (alias/script-based, not on PATH in this non-interactive shell)
[[ -f "$HOME/tools/CMDR/cmdr.sh" ]] \
    && printf "  ${GREEN}✓${NC} %s\n" "cmdr (~/tools/CMDR, alias)" \
    || printf "  ${RED}✗${NC} %s\n" "cmdr"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if [[ ${#FAILED[@]} -eq 0 ]]; then
    log "All tools installed successfully."
else
    warn "The following need manual attention:"
    printf '  - %s\n' "${FAILED[@]}"
fi

echo
warn "Burp Suite Community isn't in apt — grab it from https://portswigger.net/burp/communitydownload"
warn "volatility3 installs as the command 'vol', not 'volatility3'"
warn "fd-find installs as 'fdfind'; ripgrep as 'rg'"
warn "On ARM64, qemu-user-static lets you run x86 challenge binaries (e.g. qemu-x86_64 ./chall)"
warn "RsaCtfTool lives in ~/tools/RsaCtfTool — run via 'python3 ~/tools/RsaCtfTool/RsaCtfTool.py'"
warn "Run 'nuclei -update-templates' once before first use"

exit $(( ${#FAILED[@]} > 0 ? 1 : 0 ))
