# CTF Toolkit Setup

[![ShellCheck](https://github.com/SP1R4/ctf-toolkit-setup/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/SP1R4/ctf-toolkit-setup/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A single, idempotent Bash script that provisions a broad Capture-The-Flag toolset on
Ubuntu/Debian — across **web, pwn/reverse-engineering, crypto, forensics/stego, and
networking**. It pulls from `apt`, `pip`, `gem`, and GitHub releases, and is
**architecture-aware**, so it works on both `x86_64` and `arm64` (e.g. an
Apple-silicon VM).

## Quick start

```bash
chmod +x ctf-toolkit-setup.sh
./ctf-toolkit-setup.sh                 # full toolkit
./ctf-toolkit-setup.sh --with-ghidra   # also download + unpack Ghidra
./ctf-toolkit-setup.sh --no-heavy      # skip the big/slow giants
```

> **Heads up:** a full run downloads a lot (sagemath alone is ~1.5 GB, plus angr and
> optionally Ghidra). On a fresh VM it can take 15–30+ minutes. Use `--no-heavy` for a
> fast core install while testing.

## Requirements

- Ubuntu/Debian with `apt` (tested target: Ubuntu 22.04 / 24.04).
- `sudo` access **or** running as root (works in rootless containers — `sudo` is
  used only when not already root).
- Network access to apt mirrors, PyPI, RubyGems, and GitHub.
- `curl`, `git` (git is installed by the script if missing on first apt pass).

The script **cannot run on macOS** directly (no `apt`/`dpkg`) — run it inside a Linux VM
or container.

## Options

| Flag | Effect |
|------|--------|
| `--with-ghidra` | Also install a JDK and download + unpack the latest Ghidra into `~/tools/`. |
| `--no-heavy` | Skip the large/slow packages: `sagemath` and `angr`. |
| `--no-extras` | Install only the apt + pip core; skip the Go/gem/git tools (ffuf, nuclei, httpx, pwninit, GEF, gems, RsaCtfTool). |
| `-h`, `--help` | Print usage and exit. |

Flags can be combined and given in any order, e.g.:

```bash
./ctf-toolkit-setup.sh --no-heavy --no-extras
```

## Environment variables

| Variable | Purpose |
|----------|---------|
| `GITHUB_TOKEN` | If set, authenticates GitHub API calls so you don't hit the 60 req/hr anonymous rate limit when re-running. |

```bash
GITHUB_TOKEN=ghp_xxx ./ctf-toolkit-setup.sh
```

## What gets installed

### Web / recon
`nmap` · `gobuster` · `sqlmap` · `nikto` · `whatweb` · `wfuzz` · `dirb` ·
`feroxbuster` · `ffuf` · `nuclei` · `httpx` · `seclists` (wordlists)

### Binary exploitation / reverse engineering
`gdb` · `gdb-multiarch` · `GEF` (GDB UI) · `radare2` · `binwalk` · `checksec` ·
`ltrace` · `strace` · `patchelf` · `pwninit` · `libc6-dbg` · `ROPgadget` · `ropper` ·
`qemu-user-static` (run x86 binaries on ARM) · build toolchain
(`build-essential`, `cmake`, `libffi-dev`, `python3-dev`) ·
`pwntools` · `angr` *(heavy)* · Ghidra *(opt-in via `--with-ghidra`)*

### Cryptography
`sagemath` *(heavy)* · `pycryptodome` · `sympy` · `z3-solver` · `gmpy2` ·
`RsaCtfTool` (cloned to `~/tools/RsaCtfTool`)

### Password cracking
`john` · `hashcat` · `hydra` · `fcrackzip` · `pdfcrack`

### Forensics / steganography
`exiftool` · `foremost` · `steghide` · `stegseek` *(amd64 only — ARM needs a source
build)* · `zsteg` · `outguess` · `pngcheck` · `sleuthkit` · `testdisk` ·
`bulk-extractor` · `binutils` · `volatility3` (the `vol` command) · `one_gadget`

### Networking / packet analysis
`wireshark` · `tshark` · `tcpdump` · `netcat-openbsd` · `socat` · `masscan` ·
`proxychains4` · `dnsutils` (`dig`) · `whois` · `impacket` · `wpscan`

### Misc / quality-of-life
`git` · `python3-pip` · `pipx` · `jq` · `xxd` · `unzip` · `p7zip-full` ·
`ripgrep` (`rg`) · `fd-find` (`fdfind`) · `tmux`

### Custom tools
- [`CMDR`](https://github.com/SP1R4/CMDR) — command manager for CTF players/pentesters.
  Cloned to `~/tools/CMDR`; its installer adds a `cmdr` shell alias and tab completion
  (open a new shell, then `cmdr -h`).
- [`hashcracker`](https://github.com/SP1R4/hashcracker) — hash identification +
  cracking toolkit (hashcat/John wrapper). Installed via `pipx` as the `hashcracker`
  command (falls back to `pip` if pipx is unavailable).
- [`Qsafe`](https://github.com/SP1R4/Qsafe) — post-quantum file encryption
  (Kyber1024 + AES-256-GCM). Built from source (cloned to `~/tools/Qsafe`); `liboqs`
  is built first since it isn't in apt. Installs the `qsafe` command into `/usr/local/bin`.

## How it works

- **Idempotent** — re-running skips anything already present (apt/pip/gem/binaries),
  and `git pull`s RsaCtfTool instead of re-cloning.
- **Architecture-aware** — `dpkg --print-architecture` drives per-arch downloads. On
  `arm64`, tools without ARM builds (stegseek, pwninit) degrade to a clear
  source-build/cargo message rather than failing silently.
- **Robust downloads** — all fetches use `curl -fsSL --retry 3` so HTTP errors fail
  loudly instead of writing error pages to disk.
- **Non-interactive** — the Wireshark "allow non-root capture" prompt is pre-answered;
  apt runs with `DEBIAN_FRONTEND=noninteractive`.
- **Graceful failure tracking** — a failed tool is recorded, not fatal. At the end you
  get a ✓/✗ **verification table** plus a list of anything needing manual attention.
  The script exits non-zero if any tool failed (CI-friendly).

## Logs

| File | Contents |
|------|----------|
| `/tmp/ctf_apt_install.log` | apt / gem / GitHub install output |
| `/tmp/ctf_pip_install.log` | pip install output |

Both are truncated at the start of each run.

## Post-install notes

- **Burp Suite Community** isn't in apt — grab it from
  <https://portswigger.net/burp/communitydownload>.
- **volatility3** installs as the command `vol`, not `volatility3`.
- **fd-find** is invoked as `fdfind`; **ripgrep** as `rg`.
- **nuclei** — run `nuclei -update-templates` once before first use.
- **RsaCtfTool** — run via `python3 ~/tools/RsaCtfTool/RsaCtfTool.py`.
- **CMDR** — adds a `cmdr` alias to your shell rc; open a new shell or `source` it first.
- **hashcracker** — installed via pipx into `~/.local/bin`; if `hashcracker` isn't found,
  run `pipx ensurepath` and restart your shell.
- **Qsafe** — needs `liboqs`, which the script builds from source into `/usr/local`.
  Skipped by `--no-extras`. If `qsafe` errors with a missing `liboqs.so`, run `sudo ldconfig`.
- **ARM64** — use `qemu-x86_64 ./challenge` to run x86 challenge binaries.

## Verifying the install

The script prints a ✓/✗ table at the end. To re-check at any time:

```bash
for c in nmap ffuf feroxbuster gdb radare2 john hashcat exiftool wireshark rg; do
  command -v "$c" >/dev/null && echo "✓ $c" || echo "✗ $c"
done
```

## License

[MIT](LICENSE) © 2026 SP1R4
