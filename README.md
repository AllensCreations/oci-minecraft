# OCI Minecraft Bedrock - fully automated

Gets an Oracle Cloud Always Free ARM VM (even when it says "Out of capacity"), then installs and
configures a Minecraft server on it: **Bedrock**, **Java (Paper)**, or **Java + Geyser** (Java and Bedrock players together). Everything runs on GitHub Actions.

## Quick start (Termux, Linux, macOS, WSL)
```
bash <(curl -fsSL https://raw.githubusercontent.com/AllensCreations/oci-minecraft/main/install.sh)
```
The installer asks for everything once (GitHub login, Oracle values - you can paste your whole `[DEFAULT]` config block - SSH key, edition, server settings,
optional world/packs/plugins), creates your own repo, stores secrets, and starts the workflow. Then it never asks again.

## Before you run it
- Create an Oracle Resource Manager stack that launches your VM (VM.Standard.A1.Flex) with your SSH **public** key.
- Have ready: user OCID, tenancy OCID, fingerprint, region, stack OCID, the OCI API private key (.pem),
  and the SSH private key that matches the public key in the stack.

## What happens automatically
1. `retry.yml` applies your stack every 10 minutes until capacity is available.
2. It finds the VM, opens UDP 19132 in the VCN security list, and SSHes in.
3. `scripts/server_setup.sh` installs the Bedrock server (box64 on ARM), applies your config/packs/world,
   sets up a systemd service, firewall, daily backups and the keepalive.
4. The retry workflow disables itself.
5. Later changes: edit `minecraft/` and push; `sync.yml` updates the server.

## Notes
- Bedrock only ships x86 binaries, so on the free ARM VM it runs through box64 emulation. It works but is
  slower than native; keep view-distance low. If it is too slow, set `EDITION=java-geyser` in `minecraft/settings.env`
  (native ARM Paper; Bedrock players join through Geyser) and push. Check logs: `sudo journalctl -u minecraft -f`.
- Java editions need `EULA=true` (you accept https://aka.ms/MinecraftEULA).
- Packs go in `minecraft/resource_packs` and `minecraft/behavior_packs`; world in `minecraft/world.zip`.
- Never commit keys. Secrets live only in GitHub Secrets.
- Scheduled workflows pause after 60 days without repo activity.

## Status page (Vercel)
`web/index.html` is a static status page: online/offline lamp, join addresses, players, version and setup progress.
Vercel: Add New > Project > import this repo > set **Root Directory** to `web` > Deploy.
Edit the `CONFIG` block at the top of the file (host = your VM's public IP once it exists),
or open the page with `?host=1.2.3.4&edition=java-geyser`.

## Precise retries with cron-job.org (optional)
GitHub's own schedule can be delayed. For exact timing, create a cron job at cron-job.org:
- URL: `https://api.github.com/repos/<you>/<repo>/actions/workflows/retry.yml/dispatches`
- Method POST, body `{"ref":"main"}`
- Headers: `Authorization: Bearer <fine-grained token>`, `Accept: application/vnd.github+json`, `Content-Type: application/json`
- Token: fine-grained, only this repo, permission "Actions: Read and write", short expiry.
- Every 5 minutes. A 204 response means it started. Pause the job once the VM exists.

## Status page (Vercel)
`web/index.html` shows Online/Offline, join addresses, players, version and setup progress.
The workflow writes the VM's IP to `web/config.json`, so the page needs no manual edits.
1. vercel.com > Sign up with **GitHub** > Add New > Project > Import your repo.
2. Set **Root Directory** to `web`, then Deploy. Every push (including the IP update) redeploys it.
Note: in a public repo the server IP is visible in `web/config.json` (it is shown on the page anyway).

## Optional: more precise scheduling (cron-job.org)
POST `https://api.github.com/repos/<you>/<repo>/actions/workflows/retry.yml/dispatches`
with body `{"ref":"main"}` and headers `Authorization: Bearer <fine-grained token, Actions: read/write>`,
`Accept: application/vnd.github+json`. Delete the cron job once the VM exists.

## Re-running the installer
If the repo already exists, the installer replaces its files and overwrites the secrets.
