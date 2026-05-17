# TODO / Known Issues

## Makefile header comment out of date

The usage block at the top of `Makefile` (lines 10-17) lists only the original
targets.  The following newer targets are missing from it:

| Target | Description |
|--------|-------------|
| `crc-redeploy-dev` | Reinstall chart with dev overlay (skip infra) |
| `crc-deploy-arm64-dev` | Full deploy on arm64/Apple Silicon with dev overlay |
| `crc-deploy-amd64-dev` | Full deploy on amd64/x86_64 with dev overlay |
| `crc-clean` | Uninstall chart only (keep kafka/keycloak/s4, keep PVCs) |
| `crc-wipe` | Full namespace teardown — resets to post-`crc start` state |

Update the comment block to match and keep it in sync whenever new targets are added.
