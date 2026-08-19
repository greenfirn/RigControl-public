Change log with the reasoning behind each change. Code comments stay minimal (just what's needed to follow the logic in place) - the "why" lives here instead, so it doesn't rot inline and doesn't bloat the scripts.

## Miner install: overwrite in place, never delete

**What:** `install_miner()` / `install_custom_miner()` in `Miner-scripts/Docker-Events/lib/01-miner_install.sh` (and the embedded copy in `write - script files-LATEST.sh`, which is what actually deploys it to `/usr/local/bin/lib/01-miner_install.sh` - see the deploy note below).

**Why:** previously `current` was a symlink (`ln -sfn`) pointing at a version-numbered directory, and old version directories got `rm -rf`'d by `cleanup_old_versions()` after a successful install. Requested change, in the user's own words: "current be kept as a constant, new versions just copy over top" - i.e. never delete anything, ever.

**How it works now:**
- `current` is a permanent real directory (`$BASE_DIR/<name>/current`), not a symlink to a version-numbered directory.
- A plain-text marker file `.installed_version` inside `current` tracks what's actually installed there.
- On install: if the binary is missing or `.installed_version` doesn't match the requested version, `mkdir -p` the (already-existing) `current` dir and extract the new archive directly on top of it - no `rm -rf` first. Anything already sitting in `current` that isn't overwritten by the new archive (e.g. `escrow.cert` for keryx-miner) survives untouched.
- `cleanup_old_versions()` and both its call sites were removed entirely - there are no more version-numbered directories to clean up.
- Same treatment for `install_custom_miner()`.

**First-run behavior:** on a brand new rig with no `current` dir yet, this still works the same way - `mkdir -p` creates it, the archive extracts into it, and `.installed_version` gets written for the first time. No special-casing needed.

**Verified:** confirmed live via `journalctl` on rig `5950x-4-4070tis` - a `keryx-miner` version bump overwrote in place successfully with `escrow.cert` surviving the update.

## Workers tab: Logs module

**What:** A "Logs" button next to the worker-search box on the Workers tab. Requires exactly one selected worker. Opens a floating, corner-resizable panel (position/size saved to `localStorage`) with a dropdown, a Lines field, Refresh, and an Auto-refresh checkbox + interval spinner (default 10s).

**Dropdown options and how each one is fetched:**

| Option | Command sent | Notes |
|---|---|---|
| CPU / GPU / AUX log | `tail -n <lines> /run/rigcontrol/{cpu,gpu,aux}_miner.log` | Raw shell, sent through the existing Send-Cmd raw-exec path. |
| CPU / GPU / AUX service log | `journalctl -u "$CPU_SERVICE_NAME" -n <lines> --no-pager` (and GPU/AUX) | Same raw-exec path. Uses the service-name env vars the agent already exports (respects per-rig custom service names, not hardcoded `docker_events_*.service`). |
| CPU / GPU / AUX screen snapshot | `screen -S cpu -X hardcopy /tmp/... && cat /tmp/...` | Dumps the current visible terminal buffer of the `cpu`/`gpu`/`aux` screen session - catches in-place progress-bar redraws that a scrollback log won't show cleanly. Lines field doesn't apply here (disabled in the UI). |
| CPU / GPU / AUX API call | Structured command `cpu.api` / `gpu.api` / `aux.api` | See below - this one needed real backend work, not just a shell one-liner. |

All of the above ride on the **existing** `/command` → MQTT → `rigcontrol_cmd.sh` pipeline (same one the Send Cmd box uses). The log/service-log/snapshot options needed **zero backend changes** - they're just shell text built client-side in `app.js` (`LOGS_COMMAND_BUILDERS`).

**Why the API call option is different:** a miner's local stats API (port, path, JSON shape) is different per miner (xmrig, lolMiner, teamredminer, srbminer, keryx-miner/custom, etc.) and depends on which miner is actually configured for that specific CPU/GPU/AUX slot on that specific rig. That can't be a fixed one-line shell command the way `tail` or `journalctl` can.

**How it works:**
1. `resolve_active_miner_api(slot)` in `rigcontrol_telemetry.sh` finds the real miner process for that slot by walking the process tree under the `screen -S <slot>` session (not a system-wide `ps` grep - a system-wide grep can't tell which of several simultaneously-running miners belongs to which slot). It then maps the matched binary to a URL using the *same* default-port env-var conventions the existing `collect_xmrig_stats()`-style functions already use, so there's one source of truth for "what port does miner X's API live on." Unrecognized/custom binaries fall back to the `<NAME>_API_HOST`/`<NAME>_API_PORT` convention already used by `collect_named_custom_miner_stats()`. TeamRedMiner is flagged as raw-TCP (cgminer text protocol on :4028) instead of HTTP, since it doesn't speak JSON.
2. `rigcontrol_agent.sh`'s `handle_command()` intercepts the `cpu.api`/`gpu.api`/`aux.api` command, calls the resolver, and passes the result to `rigcontrol_cmd.sh` via `<SLOT>_API_*` env vars (`_METHOD`, `_URL`, `_URL_FALLBACK`, `_TCP_HOST`, `_TCP_PORT`, `_TCP_PAYLOAD`, `_MINER`, `_REASON`).
3. `rigcontrol_cmd.sh`'s `rc_miner_api_fetch()` just fetches whatever it was handed and pretty-prints it: `jq` first, falling back to `python3 -m json.tool`, falling back to raw text (covers both "neither is installed" and "the response isn't JSON," e.g. TeamRedMiner).

This keeps miner-port knowledge in exactly one place (Python, next to the existing collectors) instead of duplicating a second copy of the same port table in bash.

**Files touched:** `static/index.html`, `static/js/app.js`, `static/css/app.css`, `rigcontrol_agent/rigcontrol_cmd.sh`, `rigcontrol_agent/rigcontrol_agent.sh`, `rigcontrol_agent/rigcontrol_telemetry.sh`, `rigcontrol_agent/copy-paste-update.sh` (kept byte-identical to the three standalone files above, verified by diff after every change).

**Deploying this:** the log/service-log/snapshot options need nothing extra - they land the moment `static/` is updated. The API-call option needs an actual agent redeploy + restart, since `rigcontrol_cmd.sh`/`rigcontrol_agent.py`/`rigcontrol_telemetry.py` changed:
```
sudo bash copy-paste-update.sh
sudo systemctl restart rigcontrol-agent.service
```
Overwriting the files alone does nothing - the running Python process doesn't hot-reload. Confirm a real restart happened by checking the PID changes in `sudo journalctl -u rigcontrol-agent.service -f` (this bit anyone tonight more than once - a "redeploy" that only touches the launcher script and never re-runs the agent's own deploy script leaves the old code running).

## Miner-scripts: no-docker_launcher parity fixes + non-docker scripts moved out of Docker-Events

**What:** Audited `no-docker_launcher.sh` and `no-docker_launcher--no-screen-aux-FIXED.sh` against their docker-events-monitor counterparts (`no-container-docker_events_monitor--LATEST-log.sh` and `no-container-docker_events_monitor--no-screen-log-aux-FIXED.sh`) to confirm they're the same launch logic minus the Docker event-watch loop. Found and fixed 3 real drifts, then moved every script/folder in `Miner-scripts/Docker-Events/` that has no actual Docker/Podman/container involvement up to `Miner-scripts/` directly, leaving `Docker-Events/` containing only the genuine container-event-watching scripts.

**Drifts found and fixed:**
- `no-docker_launcher.sh`: the AUX systemd unit's `Description=` said "CPU Miner Launcher" (copy-paste leftover from the CPU unit above it) instead of "AUX Miner Launcher". The no-screen sibling already had this right - only the base file was wrong.
- `no-docker_launcher--no-screen-aux-FIXED.sh`: `start_miner()` unconditionally wrote a log file and piped through `tee`, even for miners with a working stats API. Its monitor sibling had already been refined to skip the log file entirely when `API_PORT>0` (nothing reads it) and only write+rotate the log for API-less miners. Brought the launcher in line - spliced in the monitor's exact log-writing block rather than hand-editing, then verified both the outer wrapper and the embedded `docker_events_universal.sh` payload with `bash -n`.
- `no-docker_launcher--no-screen-aux-FIXED.sh`: `handle_signal()` called `stop_miner` bare; the monitor sibling uses `stop_miner || true` so a non-zero return from a stuck cleanup doesn't trip `set -e` and skip the final `exit 0`. Matched it. Also bumped `TimeoutStopSec` from 30 to 60 in its three systemd units to match the monitor sibling - `stop_miner`'s worst case (10s SIGINT wait + 5s retry wait + another 10s wait) can get close to 30s on its own.

**Files moved out of `Docker-Events/` to `Miner-scripts/` root** (classified by grepping every file for real `docker`/`podman`/`container` usage - hits that were just the `docker_events_*.service`/`docker_events_universal.sh` naming convention, kept identical on purpose so rig-conf scripts don't need to know which launcher mode is deployed, didn't count):
`no-docker_launcher.sh`, `no-docker_launcher--no-screen-aux-FIXED.sh`, `manual_start_gpu.sh`, `manual_start_gpu--no-screen.sh`, `manual_stop_gpu.sh`, `manual_stop_gpu--no-screen.sh`, `keryx-miner.service.sh`, `keryx-miner-update.txt`, `amd driver install.txt`, `convert-conf-to-rig-gpu-json.sh`, `strip_flightsheet_zero.bat`/`.py`, `update_miner_versions.sh`, `write - api.conf`, `write - miner_conf.sh`, `write - script files-LATEST.sh`, `srbminer 2nd instance example.conf`, and the whole `lib/` and `rig-confs/` folders (shared by every launcher variant, docker and no-docker alike - not docker-specific).

**Stayed in `Docker-Events/`:** `README.md`, `idle-image-docker_events_monitor.sh` (+ no-screen), `no-container-docker_events_monitor--LATEST-log.sh`, `no-container-docker_events_monitor--no-screen-log-aux-FIXED.sh`, `manual install/` (4 files), `platform-specific/` (6 scripts + README) - all of these call `docker`/`podman` directly or exist specifically to install something that does.

**Note:** the reorg used the `Miner-scripts-08-19.zip` the user uploaded, which had already picked up unrelated in-progress edits to several `Docker-Events/` monitor scripts (`idle-image-*`, `no-container-docker_events_monitor-*`, `platform-specific/*`) - those came along as part of the copy since they weren't in scope for this specific review.
