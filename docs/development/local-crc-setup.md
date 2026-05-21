# Local CRC Development Setup

Two-machine setup for testing cost-onprem on both architectures.

## Machines

| Name | Arch | Address | CRC binary |
|------|------|---------|------------|
| local (MacBook) | ARM64 / Apple Silicon | — | `crc` (in PATH) |
| foobar | AMD64 / x86_64 | `martin@192.168.77.5` | `~/bin/crc` |

Both machines have:
- CRC installed and configured (see prerequisites below)
- The repo cloned at `~/Projects/koku/cost-onprem-chart`
- `~/.crc-secret.json` pull-secret

## Deploying

```bash
# ARM64 (local MacBook)
make crc-wipe
make crc-deploy-arm64-dev
make crc-test

# AMD64 (foobar)
./scripts/util/ssh_foobar run make crc-wipe
./scripts/util/ssh_foobar run make crc-deploy-amd64-dev
./scripts/util/ssh_foobar run make crc-test
```

## ssh_foobar helper

`scripts/util/ssh_foobar` wraps SSH and rsync for foobar:

```bash
# Run a command on foobar (from the repo root)
./scripts/util/ssh_foobar run make crc-test

# Interactive shell on foobar
./scripts/util/ssh_foobar run

# Push changed files without going through GitHub
./scripts/util/ssh_foobar push                          # whole repo (respects .gitignore)
./scripts/util/ssh_foobar push scripts/deploy-to-crc.sh # single file
```

The `push` subcommand is useful for iterating on scripts before committing — push the
file, test on foobar, then commit once it works.

## Git workflow

Normal flow (foobar can reach GitHub):

```bash
git push origin arm64_crc          # on local
ssh_foobar run git pull             # on foobar
```

If foobar has no GitHub SSH key, use push instead:

```bash
./scripts/util/ssh_foobar push
```

## CRC prerequisites (one-time per machine)

```bash
crc config set enable-cluster-monitoring true
crc config set memory 18000
crc config set cpus 8
crc config set disk-size 100
crc setup && crc start -p ~/.crc-secret.json
```

On foobar the binary is `~/bin/crc`, not in PATH for non-interactive SSH sessions —
the Makefile targets call it via `crc` which requires a login shell, so use
`ssh_foobar run make ...` (which opens a login shell) rather than bare `ssh`.
