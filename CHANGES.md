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

## Docker-Events: brought all remaining monitor scripts up to date

**What:** Followed up on the note above - did the same scrutiny pass (diff each script against its screen/no-screen sibling and the most up-to-date reference) across the other 10 `docker_events_universal.sh`-based scripts (`idle-image-docker_events_monitor.sh` + no-screen, `no-container-docker_events_monitor--LATEST-log.sh`, and the 3 `platform-specific/` pairs - clore, vast, podman) plus the 4 standalone `manual install/` scripts. Everything was already consistent on the earlier `RIG_GPU_JSON`/`OC_FILE .json`/`SCREEN_NAME` simplification/`/run/rigcontrol` PID dir/AUX-unit fixes documented above - those had already propagated to all 10. Three more drifts hadn't:

- **`ALWAYS_LOGS=true` dead code, screen-based scripts only** (`idle-image-docker_events_monitor.sh`, `no-container-docker_events_monitor--LATEST-log.sh`, and all 3 `platform-specific/no-container-docker_events_monitor-{clore,vast}.sh` + `podman_events_monitor.sh`): same bug as the `no-docker_launcher--no-screen-aux-FIXED.sh` fix from the entry above - `ALWAYS_LOGS=true` was hardcoded, so the `if [[ "$API_PORT" -gt 0 && "${ALWAYS_LOGS,,}" != "true" ]]` branch that skips the log file for API-having miners could never run. All 5 no-screen counterparts had already dropped `ALWAYS_LOGS` and restored the real `API_PORT`-only condition; the 5 screen-based ones hadn't. Removed the dead variable and condition in all 5, collapsing the now-pointless "ALWAYS_LOGS enabled..." vs "No API for this miner..." message branch into a single accurate message.
- **Bare `stop_miner`/`start_miner` calls under `set -e`:** the no-screen "FIXED" reference file guards every call site with `|| true` (so a non-zero return - e.g. "miner still exists after retry" - doesn't trip `errexit` and abort the script before it reaches its own error handling/exit). None of the 5 screen-based scripts had this, and 2 of the no-screen scripts (`idle-image-docker_events_monitor--no-screen.sh`, `platform-specific/podman_events_monitor--no-screen.sh`) only had it on some call sites, not all. Added `|| true` to every remaining bare call across all 7 affected files.
- **`TimeoutStopSec=30` too short for the real worst case:** `stop_miner()`'s retry path (`kill_by_pid` ~11s + 5s retry wait + `kill_by_pid` again ~11s + 2s final sleep) adds up to ~29s, right at the edge of a 30s timeout - if systemd's stop timeout fires first, it SIGKILLs the script mid-cleanup, skipping the GPU-reset step. Bumped `TimeoutStopSec` from 30 to 60 in the same 7 files as above, plus all 4 `manual install/` scripts (which have the identical `stop_miner()` retry structure).

**Bonus find in the 4 `manual install/` scripts:** each systemd unit had `TimeoutStopSec` set **twice** - once near the top of `[Service]` (the one the 30→60 fix above targets) and a second, later `# Allow up to 5 seconds for graceful shutdown` / `TimeoutStopSec=5` pair that silently overrode it, since systemd uses the last occurrence of a repeated directive. The *effective* timeout in all 4 was actually 5 seconds - nowhere near enough for the ~29s worst-case cleanup path. Removed the stale duplicate line + comment from all 4 files; the real timeout is now the intended 60s.

**Verified:** every script's outer wrapper *and* its embedded `docker_events_universal.sh` payload (extracted from between the `<<'EOF'`/`EOF` markers) checked with `bash -n` - all pass. Re-ran the audit grep table (RIG_GPU_JSON json-detection, `.conf`→`.json`, `SCREEN_NAME` lookup, PID dir, AUX unit, `TimeoutStopSec=30`, `ALWAYS_LOGS`, bare calls) across all 14 files afterward - fully consistent, zero stragglers.

## Correction: ALWAYS_LOGS was not dead code - it's needed for screen, not for no-screen

**What happened:** the entry above called `ALWAYS_LOGS=true` "dead code" and stripped it from the 5 screen-based scripts, reasoning that it made the "skip the log file for API-having miners" branch unreachable. That reasoning was backwards. `ALWAYS_LOGS=true` is a deliberate flag - it forces a log file to be written even when a miner has a working stats API, and it exists because **a `screen` session's output isn't followable through the service's journal.** `screen -fn -dmS "$SCREEN_NAME" ...` gives the miner its own detached pseudo-terminal; that output lives in the screen session's pty buffer, not in any file descriptor the systemd unit (`StandardOutput=journal`) is watching. `journalctl -u docker_events_gpu.service -f` shows nothing for what's happening inside `screen -r gpu` - the only way to see it is to attach directly, which doesn't work for remote/dashboard-driven monitoring. So for the 5 screen-based scripts, `ALWAYS_LOGS=true` is correct and necessary. Reverted the removal in all 5 (`idle-image-docker_events_monitor.sh`, `no-container-docker_events_monitor--LATEST-log.sh`, `platform-specific/no-container-docker_events_monitor-{clore,vast}.sh`, `platform-specific/podman_events_monitor.sh`).

**First overcorrection, then the real distinction:** initially added `ALWAYS_LOGS=true` to the 5 no-screen scripts too, on the assumption it should be forced everywhere for consistency. That was wrong in the other direction - the no-screen scripts launch the miner via `setsid bash -c '...' < /dev/null &` with no output redirection, so the miner's stdout/stderr inherit the parent script's file descriptors, which the systemd unit already routes to the journal (`StandardOutput=journal`). `journalctl -u <service> -f` already shows everything for these, log file or not. Forcing a redundant log file there would just double-write the same output for API-having miners with no benefit. Undid that addition - the no-screen scripts (`idle-image-docker_events_monitor--no-screen.sh`, `no-container-docker_events_monitor--no-screen-log-aux-FIXED.sh`, `platform-specific/no-container-docker_events_monitor--no-screen-{clore,vast}.sh`, `platform-specific/podman_events_monitor--no-screen.sh`, and `Miner-scripts/no-docker_launcher--no-screen-aux-FIXED.sh`) are back to skipping the log file when `API_PORT>0`, matching their original (correct) behavior.

**Final shape - `ALWAYS_LOGS` everywhere, but as an overridable default:** rather than leaving it present-only-on-screen (hardcoded `true`) and absent-on-no-screen, changed all 12 files to `: "${ALWAYS_LOGS:=true}"` - the same "default unless the environment already set it" idiom the scripts already use for `IDLE_CONFIRM_LOOPS`, `MAX_LOG_BYTES`, `POWER_LIMIT`, etc. (the earlier hardcoded `ALWAYS_LOGS=true` in the screen scripts was itself inconsistent with that convention). Every launcher - screen and no-screen alike - now defaults to always writing a log file, but an operator can opt a specific service out via `Environment="ALWAYS_LOGS=false"` in its systemd unit (most useful on the no-screen/`setsid` variants, where the log file duplicates what's already in the journal). Re-verified every outer wrapper and embedded payload with `bash -n` after this pass too.

## Docker-Events + manual_stop_gpu*: POWER_LIMIT support everywhere gpu_reset_poststop.sh is called

**What:** a broader audit of every place `gpu_reset_poststop.sh` gets called (the RESET_OC-gated GPU-clocks-and-power-limit reset that runs when a miner stops) turned up 4 scripts that called it bare, with no `POWER_LIMIT` argument, while every other script in the family declares `: "${POWER_LIMIT:=}"` and calls `gpu_reset_poststop.sh "$POWER_LIMIT"`. Currently harmless everywhere it was missing (each of those 4 has `RESET_OC` hardcoded/defaulted to `false`, so the call never actually runs today) but a real gap if that ever changes.

**Fixed:**
- `Docker-Events/manual install/docker_events_cpu-manual-install.sh` and `docker_events_gpu-manual-install.sh` - added `: "${POWER_LIMIT:=}"` (matching their podman siblings, which already had it) and now pass `"$POWER_LIMIT"` to the reset call. The GPU variant's systemd unit also gained `Environment="POWER_LIMIT="`, matching `docker_events_gpu-podman-manual-install.sh`.
- `Miner-scripts/manual_stop_gpu.sh` and `manual_stop_gpu--no-screen.sh` - added `: "${POWER_LIMIT:=}"` right after their existing `RESET_OC` default line, and pass it to the reset call. These aren't systemd services (plain `/usr/local/bin/manual_stop_gpu.sh` scripts a user runs by hand), so no `Environment=` line applies.

**Verified:** grepped every `gpu_reset_poststop.sh` call site across the whole `Miner-scripts/` tree afterward - all 18 files that call it now declare `POWER_LIMIT` and pass it as an argument, zero stragglers. `bash -n` clean on outer wrappers and embedded payloads for all 4 changed files.

**Also confirmed while auditing this:** the 4 `manual install/` scripts' internal script/service names, `SCREEN_NAME`, and `ExecStart=` all correctly match their slot (cpu-manual/cpu-podman → `docker_events_cpu.*`/`SCREEN_NAME="cpu"`; gpu-manual/gpu-podman → the gpu equivalents) - no mismatches. Each script's top-of-file `stop`/`disable` of both the CPU and GPU services before installing is intentional cleanup for a from-scratch manual install, not a slot bug - consistent across all 4.

## SCREEN_NAME renamed to SERVICE_TYPE everywhere

**What:** `SCREEN_NAME` was a misnomer for what the variable actually represents - which slot (`cpu`/`gpu`/`aux`) a given service instance is running, not literally a GNU `screen` session name (it only doubles as one in the screen-based launchers; the no-screen/`setsid` variants never touch `screen` at all and were using the name purely for PID/log file naming). This matches the same rename already done on the dashboard frontend side (`app.js`'s `fsDualModeSlots`/`priorValues.SCREEN_NAME` → `SERVICE_TYPE`) earlier in this project.

**Fixed:** renamed every occurrence of `SCREEN_NAME` → `SERVICE_TYPE` (and `MINER_SCREEN_NAME` → `MINER_SERVICE_TYPE`) across all 20 files that used it - the 12-file universal launcher family, the 4 `manual install/` scripts, and `manual_start_gpu.sh`/`manual_start_gpu--no-screen.sh`/`manual_stop_gpu.sh`/`manual_stop_gpu--no-screen.sh`. Pure rename - `screen -S "$SERVICE_TYPE"` / `screen -list | grep -q "$SERVICE_TYPE"` calls in the screen-based scripts still work identically, since the value itself (`"cpu"`/`"gpu"`/`"aux"`) is unchanged and still happens to double as the screen session name there.

**Also added:** a comment documenting the 3 valid values wherever `SERVICE_TYPE` gets set. The 12 universal-launcher files derive it from `OC_FILE` via a `case` statement - added `# SERVICE_TYPE: one of "cpu" / "gpu" / "aux" - fixed by which service instance this is, not user-configurable` right above it. The 8 single-slot scripts (manual-install and manual start/stop, each hardcoded to one slot) got `# SERVICE_TYPE is one of "cpu" / "gpu" / "aux" system-wide - this script is hardcoded to <slot>` next to their hardcoded assignment.

**Verified:** `grep -rln SCREEN_NAME` across the whole `Miner-scripts/` tree returns nothing - zero stragglers. `bash -n` clean on every outer wrapper and embedded payload afterward.

## Rig-conf examples converted from .conf to .json layout

**What:** the config format shipped by these scripts moved from `KEY GPU_ID "value"` flat `.conf` files to a structured `{"items":[...]}` JSON file (`rig-cpu.json`/`rig-gpu.json`/`rig-aux.json`), per `Miner-scripts/lib/00-get_rig_conf.sh`'s `RIG_GPU_JQ_FILTER`. Two example/reference files were still written in the old `.conf` format and needed converting to match.

**Field mapping used:** `TARGET_IMAGE`/`TARGET_NAME`/`RESET_OC`/`APPLY_OC` -> same-named top-level keys (only included when the original had a non-empty value, matching what `generate_rig_gpu_json_from_conf()` would produce); `SCREEN_NAME` -> dropped entirely, the slot is now implied by which file it's written to; `MINER` -> top-level `miner`; `ALGO`/`PASS`/`ARGS` -> `miner_config.algo`/`.pass`/`.user_config`; `WALLET` -> `miner_config.template`; `POOL` -> `miner_config.url` with the `stratum+ssl://`/`stratum+tcp://` prefix stripped, plus a top-level `pool_ssl` boolean.

**Multi-pool handling:** a few examples smashed 2 failover pool addresses into a single `POOL` value - comma-separated (srbminer examples) or, in the "rigel octa" example, a raw ` -o stratum+ssl://...` string hacked directly into the value to inject a second CLI flag. Converted all of these to the proper top-level `"pool_urls": [...]` array (bare `host:port` strings) instead, which `lib/02-load_configs.sh`'s `get_pool_url_list()` already prefers over a single `POOL` when present. `miner_config.url` is still populated with the first address as a fallback/primary-pool reference.

**Files:**
- `Miner-scripts/srbminer 2nd instance example.conf` -> replaced with `Miner-scripts/srbminer 2nd instance example.sh` (now writes `/etc/rigcontrol/rig-gpu.json` and `rig-cpu.json` directly - the old file already used the FHS `/etc/rigcontrol/` path, just in `.conf` format, so this was a pure format conversion).
- `Miner-scripts/rig-confs/rig conf examples.txt` - all 10 `rig-cpu.conf`/`rig-gpu.conf` examples converted to `.json` blocks (xmrig Nosana, xmrig octa, xmrig clore, trex clore, srbminer clore, rigel octa, bzminer clore, bzminer octa, teamredminer octa x2), plus the existing keryx-miner custom-download example carried over unchanged (it already matches `rig-confs/keryx-custom-rig-gpu.sh`). The `miner.conf` version-pins block at the top is a different, unrelated schema (miner binary version pins, not a rig-cpu/rig-gpu/rig-aux config) and was left in its original `KEY "value"` format. Header comments updated to describe the JSON fields (`pool_urls`, `miner_alt`/`install_url`, slot-by-filename) instead of the old `.conf` key names, and the `tee` target paths updated from the file's old `/home/user/rig-*.conf` to the current `/etc/rigcontrol/rig-*.json` convention, matching every other script in the tree.

**Verified:** `bash -n` clean on both outer wrappers; every embedded JSON body parsed with `json.loads`/`jq` (11 blocks across the two files, all valid).

## keryxd.service: log path moved from /tmp to /run/rigcontrol

**What:** the `keryxd.service` unit (Keryx node daemon, run as the AUX slot's custom miner via `CUSTOM_MINER_BIN_AUX`) wrote its own rotating log to `/tmp/keryxd.log`. Every other log/pid file in this codebase lives under `/run/rigcontrol/` - `/tmp` was never used anywhere else in the tree (confirmed by an earlier full-tree grep in this same audit pass). Also, `rigcontrol_agent.sh`'s custom-miner resolver reads the log location from `KERYXD_LOG_PATH` in `/etc/rigcontrol/rigcontrol-agent.conf` for the "Accepted N blocks" telemetry scraper (`KERYXD_LOG_STYLE=blocks`) - so the service's actual log path and that config value need to agree, and `/run/rigcontrol/keryxd.log` is the value already set there.

**Fixed:** all 3 `/tmp/keryxd.log` references (the `ExecStartPre` cleanup, the in-loop rotation check, and the final `tee -a` target) changed to `/run/rigcontrol/keryxd.log`. Also added `ExecStartPre=/bin/mkdir -p /run/rigcontrol` - `/run` is a tmpfs cleared on every boot, and unlike `/tmp` (which always exists), `/run/rigcontrol` is only created by the one-time `rigcontrol-agent-local-keryxd.sh` setup script; without a guaranteed create-on-start step here, a reboot before that setup script's directory got recreated would make the service fail to write its log. Saved as `Miner-scripts/keryxd.service.sh` (new file - this unit wasn't previously part of the repo, only referenced via `AUX_SERVICE_NAME=keryxd.service` in the agent config).

**Verified:** outer wrapper checked with `bash -n`; the embedded `ExecStart=/bin/bash -c '...'` payload extracted and checked with `bash -n` separately (systemd unit files aren't themselves valid shell, so the outer check alone doesn't validate the `ExecStart` script body).

## keryxd.service: switched to the shared aux_miner.log path

**What:** further follow-up to the entry above - moved from keryxd's own dedicated `/run/rigcontrol/keryxd.log` to the same `/run/rigcontrol/aux_miner.log` path every other AUX-slot miner uses via `${SERVICE_TYPE}_miner.log`. This makes the dashboard's "Logs / Config" -> AUX -> `aux.log` view (`tail -n N /run/rigcontrol/aux_miner.log` in `static/js/app.js`) work for keryxd directly, instead of only `aux.svclog` (journalctl) being useful.

**Fixed:** all 4 `keryxd.log` references (`ExecStartPre` cleanup, in-loop rotation check + its `.tmp` file, final `tee -a` target) changed to `aux_miner.log`. Also picked up the user's added `keryxd` flags (`--disable-upnp --ram-scale=10.0 --addpeer=141.95.35.181`) in the same pass.

**Follow-up needed on the config side (not part of this file):** `rigcontrol-agent.conf`'s `KERYXD_LOG_PATH=/run/rigcontrol/keryxd.log` now points at a file this service no longer writes - it should be updated to `/run/rigcontrol/aux_miner.log` to match, or removed entirely. `rigcontrol_agent.sh`'s custom-miner resolver already auto-derives `/run/rigcontrol/aux_miner.log` as the default for any custom AUX miner when `<NAME>_LOG_PATH` isn't explicitly set (see `resolve_custom_miner()`), so removing the line is the simpler option and lets the auto-default apply.

**Verified:** outer wrapper and the extracted `ExecStart` bash payload both checked with `bash -n`.

## rigcontrol-agent-local-keryxd.sh: KERYXD_LOG_PATH updated to match

**What:** closes the loop from the entry above - `KERYXD_LOG_PATH` in `rigcontrol_agent/rigcontrol-agent-local-keryxd.sh` still pointed at `/run/rigcontrol/keryxd.log`, the path `keryxd.service` no longer writes to now that it writes `aux_miner.log` directly.

**Fixed:** `KERYXD_LOG_PATH=/run/rigcontrol/keryxd.log` -> `KERYXD_LOG_PATH=/run/rigcontrol/aux_miner.log`, so `rigcontrol_telemetry.sh`'s blocks-counting scraper (`KERYXD_LOG_STYLE=blocks`) reads the file keryxd is actually writing.

**Verified:** `bash -n` clean; embedded conf block unchanged otherwise.

## Logs / Config: added Watchdog conf

**What:** the Workers tab's Logs/Config dropdown had `watchdog.svclog` (journalctl of the watchdog service) but no way to view the watchdog's actual config file, unlike cpu/gpu/aux which each have both a `.conf` (cat the config) and `.svclog`/`.log` pair. Added `watchdog.conf` -> `cat /etc/rigcontrol/rigcontrol-watchdog.conf` (the file `watchdog/rigcontrol_watchdog.sh`/`.py` reads via `--conf`, generated by the dashboard's own Watchdog Config module).

**Fixed:** added the option/label/command-builder/no-lines-input entry in the 4 places every other `.conf` type appears - `static/index.html`'s `<select id="logs-type-select">`, and `static/js/app.js`'s `LOGS_TYPE_LABELS`, `LOGS_TYPES_WITHOUT_LINES`, `LOGS_COMMAND_BUILDERS`. Placed next to `watchdog.svclog`, matching the pairing pattern used for the cpu/gpu/aux slots and `agent.conf`/`agent.svclog`.

**Verified:** `node --check` clean on `app.js`; diffed the dropdown's option values against `LOGS_TYPE_LABELS` and `LOGS_COMMAND_BUILDERS` keys - all 21 entries match exactly in both directions (no dropdown option without a label/builder, no label/builder without a dropdown option).

## Logs / Config: added Fan curve conf

**What:** matching the Watchdog conf addition above, `fancurve.svclog` (journalctl of `fan-curve.service`) had no config-viewing counterpart. Unlike the watchdog/cpu/gpu/aux slots, the fan curve has no separate `/etc/rigcontrol/*.conf` file - its curve points live directly in the `ExecStart=` line of `/etc/systemd/system/fan-curve.service` (`Fan-control/py-nvtool/fan-curve.service.sh` writes it there, edited per-rig by hand per that script's own comment).

**Fixed:** added `fancurve.conf` -> `cat /etc/systemd/system/fan-curve.service` in the same 4 places (`static/index.html`'s dropdown, `LOGS_TYPE_LABELS`, `LOGS_TYPES_WITHOUT_LINES`, `LOGS_COMMAND_BUILDERS`), placed next to `fancurve.svclog`. Used `cat` rather than `tail` - the unit file is ~44 lines and `tail`'s default 10-line window would risk cutting off the `ExecStart` curve line depending on exact length, while `cat` always shows the whole thing.

**Verified:** `node --check` clean; dropdown options vs `LOGS_TYPE_LABELS`/`LOGS_COMMAND_BUILDERS` keys diffed again - still an exact match in both directions (22 entries now).

## POOL display: stopped truncating to a bare middle-domain-label

**What:** the dashboard's per-miner POOL stat card showed only a fragment of the actual pool address - e.g. `pool.pearlhash.xyz:9000` (wildrig's real `connection.pool` value) displayed as just `pearlhash`. Two layers were stripping information: `rigcontrol_telemetry.sh`'s `extract_pool_host()` (shared by 11 different miner collectors - xmrig, trex, bzminer, srbminer, wildrig, teamredminer, rigel, gminer, onezerominer, lolminer, peakminer) stripped the port; then `static/js/app.js`'s POOL card render (Workers tab, miner detail card) applied its own domain-shortening heuristic on top of that (`"pool.pearlhash.xyz".split('.')` -> took the second-to-last label), losing the subdomain too.

**Fixed:**
- `extract_pool_host()` in `rigcontrol_agent/rigcontrol_telemetry.sh`, `rigcontrol_telemetry-exclude.sh`, and `copy-paste-update.sh` (all 3 carry the same embedded `rigcontrol_telemetry.py` payload, kept in sync) - now only strips the scheme prefix (`stratum+ssl://` etc.) if present, keeping the full `host:port`.
- `static/js/app.js`'s POOL stat card (Workers tab) - removed the domain-shortening regex/split logic entirely; now shows `pools[0]` as-is, i.e. whatever the backend now sends.

**Scope confirmed with the user:** full `host:port` display for every miner's pool field, not just wildrig - both changes apply uniformly across every collector/card, not per-miner.

**Verified:** `node --check` clean on `app.js`; `bash -n` clean on all 3 changed `.sh` wrappers plus `python3 -m py_compile` clean on each extracted embedded payload; manually checked `extract_pool_host()`'s new behavior against the real wildrig pool string, a `stratum+ssl://` example, and a no-scheme example - all return the full host:port unchanged apart from scheme-stripping.

## POOL stat item: auto-size width instead of fixed min-width

**What:** follow-up to the POOL-display fix above. `.miner-stat-item` has a shared `min-width: 70px`, fine for short fixed-shape values (HASHRATE, SHARES, UPTIME) but not ideal now that POOL can show a full `host:port` string of very different lengths per miner.

**Fixed:** added a `pool` class to the POOL item's wrapping `<div class="miner-stat-item">` in `static/js/app.js`, and a `.miner-stat-item.pool { min-width: auto; width: auto; }` override in `static/css/app.css` - only the POOL item drops the shared 70px floor, sizing purely to its own content. The other stat items (hashrate/algorithms/shares/uptime) keep the existing 70px min-width unchanged.

**Verified:** `node --check` clean on `app.js`; CSS brace-balance sanity check (836/836) on `app.css`.

## Windows telemetry: same POOL truncation fix

**What:** `rigcontrol_agent/windows/rigcontrol_telemetry.py` has no shared `extract_pool_host()` helper like the Linux version - each miner collector inlined its own version of the same pattern, and one (bzminer) was worse than the Linux bug: it stripped the port *and* reduced the hostname to just the second-to-last dot-separated label (`"pool.pearlhash.xyz"` -> `"pearlhash"`), the exact same over-truncation that was just removed from the frontend.

**Fixed** (kept the port, only strip the scheme prefix if present, same as the Linux `extract_pool_host()` fix):
- `collect_bzminer_stats()` (~line 768-774): dropped the `.split(":")[0]` port-strip and the `.split(".")[-2]` middle-label reduction entirely - now just takes everything after `://`.
- `collect_rigel_stats()` (~line 835): `pool_data.get("url", "").split("://")[-1].split(":")[0]` -> `.split("://")[-1]`.
- `collect_xmrig_stats()` (~line 1148): same pattern fix on `connection.get("url", "")`.
- `collect_trex_stats()` (~line 1196): same pattern fix on `data.get("url", "")`.
- `collect_nbminer_stats()` (~line 1234): same pattern fix on `data.get("stratum", {}).get("url", "")`.
- `collect_lolminer_stats()`, `collect_onezerominer_stats()`, `collect_gminer_stats()` were already passing the miner's own `"Pool"`/`"pool"` field through unmodified - nothing to change there.

**Verified:** `python3 -m py_compile` clean; manually checked the new bzminer and rigel/xmrig/trex/nbminer extraction patterns against `"stratum+ssl://pool.pearlhash.xyz:9000"` - both return the full `pool.pearlhash.xyz:9000` unchanged apart from scheme-stripping, matching the Linux-side fix.

## rigcontrol-agent-local.sh / -local-keryxd.sh: replaced with the fuller reference version

**What:** the user uploaded `rigcontrol_agent-08-20.zip` (their current live copy) to confirm what predates today's other fixes. Diffing it against the repo showed `rigcontrol_telemetry.sh`, `rigcontrol_agent.sh`, `rigcontrol_cmd.sh`, `copy-paste-update.sh`, `rigcontrol_telemetry-exclude.sh`, and `windows/rigcontrol_agent_win.py` were already byte-identical, and `windows/rigcontrol_telemetry.py` differed by exactly the pool-truncation fix from the previous entry (confirming that upload predates only that one change).

`rigcontrol-agent-local.sh` and `rigcontrol-agent-local-keryxd.sh` differed in a way unrelated to today's work: the uploaded versions carry a fuller commented reference block documenting every override variable (`#CPU_SERVICE_NAME=`, `#WATCHDOG_SERVICE_NAME=`, `#CUSTOM_MINER_BIN_GPU/CPU/AUX=`, the per-custom-miner override explanation, `#KERYXD_BIN=`, etc.) that the repo's copies were missing.

**Fixed:** replaced both repo files with the exact content from the upload (verified byte-identical via `diff`). The repo's old `rigcontrol-agent-local.sh` also had a `KERYX_MINERX_API_HOST`/`PORT` pair (the built-from-source variant of keryx-miner) that the uploaded version doesn't include - confirmed with the user this isn't a typo, just not currently in use, and dropped per their instruction ("i can add back x version later").

**Verified:** `bash -n` clean on both.

## Resync from GitHub-08-20.zip

**What:** user uploaded a fresh export of both GitHub repos (`RigControl` private, `RigControl-public`) to check sync. Diffing my working copy against the uploaded `RigControl-public` found that every code file from this session's work (frontend, telemetry, agent scripts) was already in sync - but several docs/scripts had drifted independently on GitHub since the last time those specific files were touched here.

**Adopted from the upload as-is:**
- `Miner-scripts/Docker-Events/README.md`, `Miner-scripts/README.md` - fixes a wrong heading in the old copy here (`# Docker Events` instead of `# Miner-scripts`) plus restructuring already done on GitHub.
- `Miner-scripts/keryx-miner.service.sh` - newer keryx-miner release (v0.4.9-PoM) with expanded install/update notes; the old copy here was still on v0.4.2-OPoI.
- `Miner-scripts/keryxd.service.sh` - replaced with GitHub's plain (no log-rotation) version.
- `Miner-scripts/keryxd.service-log-output.sh` - new file, the log-rotation variant (parallels the screen/no-screen pairing pattern used elsewhere in this repo). Per the user: keep both `keryxd.service.sh` and `keryxd.service-log-output.sh` as distinct files, don't merge them, don't change either one's flags (both leave `--disable-upnp`/`--ram-scale` as commented notes rather than active flags - not touched).
- `rigcontrol_agent/README.md` - GitHub's version replaced two screenshot-image references with actual text code blocks for the `rigcontrol-agent.conf` examples.
- `rigcontrol_dashboard_server_pi/README.md` - picked up additional notes (docker-compose optional extras, mosquitto bridge-mode note) added independently on GitHub.
- Removed `rigcontrol_agent/windows/__pycache__` - a stray Python bytecode cache directory, not real content.

**Kept as-is (not touched):**
- `CHANGES.md` - this file is a superset of GitHub's copy (has the most recent "Windows telemetry" entry GitHub doesn't have yet).
- `themes/*.json` (7 files) - differ from GitHub's copies, but unrelated to any of this session's work and not part of the resync decision - flagged separately rather than guessed at.

**Still open (not resolved in this pass):**
- On GitHub, `Miner-scripts/rig-confs/` has `rig-confs--rig conf examples.txt` and `srbminer 2nd instance example.sh` sitting in the wrong place/wrong name - artifacts of extracting a "flat" delivery zip instead of the "paths" one. The correctly-placed versions (`Miner-scripts/rig-confs/rig conf examples.txt` and `Miner-scripts/srbminer 2nd instance example.sh`) already exist correctly in this working copy - GitHub needs the misplaced copies removed and replaced with these.
- `themes/*.json` divergence not yet reconciled either direction.

**Verified:** `bash -n` clean on all 3 changed/added `.sh` files; `diff -q` confirmed byte-identical match against the upload for every adopted file.

## Correction: srbminer 2nd instance example.sh belongs in rig-confs/

**What:** the previous entry flagged `Miner-scripts/rig-confs/srbminer 2nd instance example.sh` on GitHub as a misplaced flat-zip artifact. That was wrong - the user confirmed `Miner-scripts/rig-confs/` is the correct, intended location for it (alongside `rig conf examples.txt` and the other named rig-conf examples).

**Fixed:** moved `srbminer 2nd instance example.sh` from `Miner-scripts/` to `Miner-scripts/rig-confs/` in this working copy, matching GitHub. `rig conf examples.txt` was already correctly placed in `rig-confs/` under its plain name (not the `rig-confs--` prefixed name GitHub currently has, which does look like a flat-zip naming leftover specifically on that one file - not addressed here, only the srbminer file's location was corrected).

**Verified:** `bash -n` clean.

## Themes: adopted GitHub's versions

**What:** the 9 theme files flagged as differing in the earlier resync (`ALIEN_icons.json`, `Alien (Nostromo)-icons.json`, `Bugs Bunny (Dark).json`, `Columbo (Classic Detective).json`, `Cotton Candy-icons.json`, `Daffy Duck (Dark)-humorous.json`, `Daffy Duck (Dark).json`, `Sylvester (Money Pile).json`, `THX.json`) were left untouched pending confirmation. User confirmed both GitHub repos (`RigControl` and `RigControl-public`) already agree with each other on these files (yesterday's theme update was already pushed to both), so this working copy's older versions - which had extra button labels neither GitHub repo has - were replaced.

**Fixed:** copied all 9 files from the GitHub upload as-is.

**Verified:** `diff -rq` confirms the full `themes/` directory now matches GitHub exactly; `python3 -m json.tool` validated every file.

## Removed remaining stale "source/" path references

**What:** a full-tree grep for `source/` found 2 more stale path references beyond the one already fixed by adopting GitHub's `Docker-Events/README.md`: `Miner-scripts/Docker-Events/README.md` still referenced `source/manual_start_gpu.sh`/`source/manual_stop_gpu.sh`, and `Miner-scripts/README.md`'s platform-specific monitors table referenced `source/no-container-docker_events_monitor-vast.sh` and `source/podman_events_monitor.sh`. None of these paths exist - there's no `source/` directory anywhere in the repo.

**Fixed:**
- `Docker-Events/README.md`: `'source/manual_start_gpu.sh', 'source/manual_stop_gpu.sh'` -> `'manual_start_gpu.sh', 'manual_stop_gpu.sh' (in Miner-scripts/)`.
- `Miner-scripts/README.md`'s table: `source/no-container-docker_events_monitor-vast.sh` -> `Docker-Events/platform-specific/no-container-docker_events_monitor-vast.sh`; `source/podman_events_monitor.sh` -> `Docker-Events/platform-specific/podman_events_monitor.sh` - the actual current locations.

**Verified:** re-grepped the whole tree for `source/` afterward - the only remaining hit is unrelated prose in `themes/README.md` ("original source/license is usually lost," about Pinterest re-uploads), not a path reference.

## READMEs: hardcoded GitHub URLs converted to relative links

**What:** every README's "Get started" and image links hardcoded `https://github.com/greenfirn/RigControl#get-started` or `.../RigControl-public#get-started` (and similarly for image blob URLs). Both `RigControl` and `RigControl-public` are real, separate repos, and the same README file lives in both, so a hardcoded link to one repo name is wrong when viewed from the other.

**Fixed:** converted all 17 occurrences across 9 README files to relative links instead (`../README.md#get-started`, `../../README.md#get-started` for the 2-levels-deep `Docker-Events/README.md`, and `../images/...png` for image blobs) so every link resolves identically no matter which repo/mirror it's viewed from.

**Verified:** a Python script resolved every relative link against the actual file tree - all clear.

## READMEs: bare filename mentions converted to clickable links

**What:** most READMEs referenced script/config filenames as plain quoted text (`'rigcontrol-agent-local.sh'`) instead of as clickable markdown links, and a full audit surfaced several stale/wrong filenames left over from earlier reorganizations.

**Fixed:**
- Converted bare-quoted filenames to `[name](relative/path)` links across `rigcontrol_agent/README.md`, `Miner-scripts/README.md`, `Miner-scripts/Docker-Events/README.md`, `Miner-scripts/rig-confs/README.md`, `Notify/README.md`, and `rigcontrol_dashboard_server_windows/README.md`.
- `Miner-scripts/README.md`: fixed a broken link target (`no-container-docker_events_monitor--no-screen-log.sh` -> the actual `...-aux-FIXED.sh` file) and a wrong `py-nvtool` filename (`py-nvtool.txt` -> `py-nvtool-install-usage.txt`, same fix already applied to `Docker-Events/README.md` earlier).
- `Fan-control/README.md`: fixed 4 occurrences of a wrong filename, `fan-curve_service.sh` (underscore) -> the real `fan-curve.service.sh` (dot), and linked the Files table's real repo files (`nvtool.py`, `fan_curve.sh`, `install_fan-curve.sh`, `fan-curve.service.sh`). Left `fan_curve.py`/`fan-curve.service` as plain code text (not links) since those are deploy-time filenames written into `/usr/local/bin/` or `/etc/systemd/system/` by the scripts, not files that exist in the repo - added a short note to the table clarifying which script writes each.
- `rigcontrol_dashboard_server_windows/README.md`: fixed `accessKeys.csv` -> `accessKeys.csv.example` (the actual file; matches the existing `.env.example` rename-after-download pattern).
- Removed `'keryx-dummy-cpu-service.sh'` from `Docker-Events/README.md` and `'nosana_monitor-1.sh'` from `Miner-scripts/README.md`'s platform table - neither file exists anywhere in the repo and the user confirmed to drop them (Nosana/Podman row now points only at the real `podman_events_monitor.sh`).
- `run.bat` (referenced 3x in `rigcontrol_dashboard_server_windows/README.md`) also doesn't exist in the repo - left as plain text, not yet resolved.

**Verified:** re-ran the link-resolution script across all `.md` files in the repo after every batch of edits - 0 broken links at final check.

## Docker-Events / Miner-scripts READMEs: added missing `--no-screen` script variants

**What:** the user pointed out `Miner-scripts/Docker-Events/platform-specific/` has `--no-screen` variants for clore, vast, and podman that weren't mentioned in either README - only the screen-session versions were referenced. This is also why the earlier removed `'nosana_monitor-1.sh'` reference existed in the first place - it was a stale/wrong name for what should have pointed at the real `podman_events_monitor--no-screen.sh`.

**Fixed:** added links for `podman_events_monitor--no-screen.sh`, `no-container-docker_events_monitor--no-screen-clore.sh`, and `no-container-docker_events_monitor--no-screen-vast.sh` alongside their existing screen-session counterparts in both `Miner-scripts/README.md`'s platform table and `Miner-scripts/Docker-Events/README.md`'s notes.

**Verified:** re-ran the link-resolution script - 0 broken links.

## READMEs: root-relative links converted to genuine relative paths

**What:** 7 links across `Miner-scripts/README.md`, `Miner-scripts/Docker-Events/README.md`, `rigcontrol_agent/README.md`, and `rigcontrol_dashboard_server_windows/README.md` used a leading-slash "root-relative" path (e.g. `/py-nvtool/py-nvtool-install-usage.txt`, `/images/Screenshot-test-windows.png`). These render fine on github.com (GitHub resolves a leading `/` against whichever repo is currently being browsed), but the user flagged one rendering as a hardcoded `github.com/greenfirn/RigControl/blob/main/...` URL - and a leading-slash path isn't portable outside GitHub's renderer (local markdown viewers, other git hosts, or a plain file browser would treat it as an absolute filesystem path and break).

**Fixed:** converted all 7 to genuine dot-relative paths (`../py-nvtool/...`, `../images/...`, `Docker-Events/no-container-...`, etc.) computed from each file's actual location, matching the style already used for the "Get started" links. Also clarified the py-nvtool note in `Miner-scripts/README.md` to explicitly say "not Fan-control/py-nvtool/" since two folders share that name.

**Verified:** re-ran the link-resolution script and a separate check for any remaining leading-slash links - 0 broken links, 0 root-relative links left.

## README links: label text trimmed to just the filename

**What:** the platform-specific monitors table in `Miner-scripts/README.md` and the two `py-nvtool-install-usage.txt` links were using the full relative path as the visible link text (e.g. `[Docker-Events/platform-specific/podman_events_monitor.sh](...)`), making the table cramped and harder to scan.

**Fixed:** shortened every link's visible label to just the filename (`[podman_events_monitor.sh](...)`), keeping the full path only in the link target. Applied to the VastAI/Nosana-Podman table rows in `Miner-scripts/README.md` and the `py-nvtool-install-usage.txt` links in both `Miner-scripts/README.md` and `Miner-scripts/Docker-Events/README.md`.

**Verified:** re-ran the link-resolution script plus a check for any remaining link label containing a `/` - 0 broken links, 0 path-containing labels left.

## py-nvtool link: dropped the redundant disambiguation note

**What:** the `py-nvtool-install-usage.txt` links in `Miner-scripts/README.md` and `Miner-scripts/Docker-Events/README.md` carried a `(repo-root py-nvtool/, not Fan-control/py-nvtool/)` note added when the reference was still plain text. Now that it's a working relative link, the target path itself (`../py-nvtool/...` vs `Fan-control/py-nvtool/...`) already makes clear which folder it points to - the note was redundant clutter.

**Fixed:** removed the parenthetical from both mentions.

**Verified:** link-resolution script still 0 broken links.

## Removed stale note from Docker-Events/platform-specific/README.md

**What:** `Miner-scripts/Docker-Events/platform-specific/README.md` only contained "have not tested these no screen variants" - stale now that the `--no-screen` variants are linked as normal options elsewhere.

**Fixed:** cleared the note per the user's instruction.

## Docker-Events/README.md: removed duplicate warnings

**What:** the user spotted two lines duplicated verbatim in `Miner-scripts/Docker-Events/README.md`: a standalone `no-docker_launcher.sh` mention (already covered in the numbered setup list, item 4) and the full `update_miner_versions.sh` rate-limit warning (appeared both in the `# Important` section and again as item 7 of the numbered setup list).

**Fixed:** removed the standalone `no-docker_launcher.sh` line entirely (item 4 already covers it). Trimmed item 7 to just link the script with a pointer back to the `# Important` section instead of repeating the full warning text.

**Verified:** re-ran the link-resolution script on the file - 0 broken links.

## Docker-Events/README.md: merged the removed line's detail into item 4

**What:** the earlier dedup pass deleted the standalone `no-docker_launcher.sh ... same miner conf,api,etc for no docker mining rigs` line outright since item 4 already linked the script. The user wanted that description kept, just merged into item 4's bullet rather than dropped.

**Fixed:** item 4's `no-docker_launcher.sh` bullet now reads "-- same miner conf,api,etc for systems without docker", combining both descriptions instead of losing the "same miner conf,api,etc" detail.

## Added missing run.bat to rigcontrol_dashboard_server_windows/

**What:** the user uploaded the `run.bat` referenced-but-missing from earlier ("idk how run.bat dissaapeared"). Its content ran `rigcloud_agent_win.py` under a "RigCloud Agent" title - both stale from before the RigCloud -> RigControl rename. That mismatched what `rigcontrol_dashboard_server_windows/README.md` describes the file doing (starting `rigcontrol_dashboard_server.py`), so I first placed it in `rigcontrol_agent/windows/` (renaming the script call to match `rigcontrol_agent_win.py`) since the content looked agent-shaped. The user then confirmed via its actual location on their disk that it genuinely belongs in `rigcontrol_dashboard_server_windows/` instead - the uploaded copy just had stale/wrong content from an old version.

**Fixed:** moved the file to `rigcontrol_dashboard_server_windows/run.bat` and corrected its content to match what that folder actually needs: title "RigControl Dashboard Server", and both `python` calls changed from `rigcloud_agent_win.py` to `rigcontrol_dashboard_server.py`. Linked all 3 `'run.bat'` mentions in `rigcontrol_dashboard_server_windows/README.md` that were previously left as plain text pending this file.

**Verified:** confirmed `.gitignore` has no `*.bat` exclude (it was just dropped during the rename, not intentionally excluded); re-ran the link-resolution script on the README - 0 broken links.

## rigcontrol_dashboard_server_windows/requirements.txt: fixed stale MQTT dependency

**What:** the user asked whether `requirements.txt` was up to date. Cross-checked its 6 packages against every import actually used in `rigcontrol_dashboard_server.py` (via a Python AST parse, not just grep). Found `aiomqtt>=2.4,<3.0` listed but never imported anywhere in the file - the Pi/Docker twin (`rigcontrol_dashboard_server_pi/rigcontrol-ws/rigcontrol_dashboard_server.py`) genuinely uses `aiomqtt` (async client), but a diff showed the Windows `.py` was switched to the synchronous `paho.mqtt.client` at some point without updating `requirements.txt` to match. `psutil` (used for process lookups) was also missing entirely.

**Fixed:** replaced `aiomqtt>=2.4,<3.0` with `paho-mqtt` and added `psutil`. A fresh `pip install -r requirements.txt` would previously install an unused package and skip two required ones, causing `ModuleNotFoundError` the first time the server actually started.

**Verified:** AST-parsed every top-level import in the file and confirmed every third-party module now has a matching requirements.txt entry (pydantic and botocore are transitive deps of fastapi/boto3, intentionally not listed separately, matching this repo's existing convention).

## static/config/templates.json: added missing aux_template, fixed stale readme

**What:** the user asked where the "template files" were, which led to auditing `static/config/templates.json` (the file that controls the dashboard's auto-generated Flightsheet/Overclock/Watchdog scripts) against its actual consumer, `static/js/app.js`. Two real gaps found:
- `flightsheet` only had `cpu_template`/`gpu_template`. `app.js` (line ~7035) also looks up `fsCfg.aux_template` when generating a Flightsheet for the AUX slot, but since the JSON didn't define it, AUX generation silently fell through to a hardcoded default baked into `app.js` itself - meaning AUX flightsheets weren't actually editable from this file the way the `_readme` claims everything in it is.
- The `_readme` block documented overclocking placeholders (`%Fan Args%`, `%FAN Curve%`) and a single `apply_script_template` field that no longer match reality - at some point the apply script was split into `apply_script_header`/`apply_script_algo_block`/`apply_script_footer`, and the placeholders `fillPlaceholders()` actually substitutes are `Fan Mode`, `Fan Value`, and `FAN_CURVE_BLOCK` (confirmed by reading the substitution call in `app.js` directly, not just the JSON).

**Fixed:**
- Added `flightsheet.aux_template`, mirroring `cpu_template`/`gpu_template` but writing `/etc/rigcontrol/rig-aux.json` and restarting `docker_events_aux` (matching `app.js`'s existing hardcoded default for the same field).
- Rewrote the `_readme` block's overclocking section to describe the real 3-way header/algo_block/footer split, the actual placeholder names (`%ALGO%`, `%Lock Core Clock%`, `%Core Clock Offset%`, `%Lock Memory Clock%`, `%Memory Clock Offset%`, `%Power Limit%`, `%Fan Mode%`, `%Fan Value%`, `%FAN_CURVE_BLOCK%`), and clarified that `fan_curve_service_template` has no `%...%` tokens of its own - its `"$FAN_VALUE"` is a literal bash variable that relies on the enclosing script already having set it.

**Not touched:** `app.js`'s own hardcoded `TEMPLATES_CONFIG` fallback (lines 1-63, used only if the `templates.json` fetch fails) is still on the old single-field `apply_script_template` structure with the old placeholder names. It's dead weight for overclocking specifically (the generation code only ever reads the new field names), but rewriting JS fallback logic is a bigger, more consequential change than a JSON/docs fix - flagged here rather than changed without being asked.

**Verified:** `python3 -m json.tool` clean; cross-checked every placeholder name against the exact strings `fillPlaceholders()` passes in `app.js`.

## Added rigcontrol_agent/windows/run.bat and requirements.txt

**What:** confirmed via the user's local path (`...\GitHub\RigControl\rigcontrol_agent\windows`) that a second, separate run.bat genuinely belongs here too - this is the Windows *agent's* run.bat, distinct from the dashboard server's copy added earlier. Same stale content as the earlier upload (`title RigCloud Agent`, `python rigcloud_agent_win.py`) from before the RigCloud -> RigControl rename. The folder also had no `requirements.txt` at all, even though run.bat depends on one existing to install anything.

**Fixed:**
- Added `rigcontrol_agent/windows/run.bat`, title corrected to "RigControl Agent", both `python` calls changed to `rigcontrol_agent_win.py` to match the actual script in that folder.
- Added `rigcontrol_agent/windows/requirements.txt` (didn't exist before) - AST-parsed both `rigcontrol_agent_win.py` and `rigcontrol_telemetry.py` (windows) for third-party imports: `paho` (paho-mqtt), `psutil`, and `wmi`/`pythoncom` (the `WMI` package, which needs `pywin32` for `pythoncom`). Note this agent uses `paho-mqtt` directly, unlike the Linux agent's venv which installs both `aiomqtt` and `paho-mqtt` inline via `copy-paste-update.sh`/`rigcontrol_agent-service.sh` - not a discrepancy, just a different MQTT client choice per platform.

**Not yet done:** no README currently documents Windows agent setup (`rigcontrol_agent/README.md` only shows a Linux/systemd workflow plus one Windows test screenshot); `rigcontrol_agent/windows/README-windows-services.txt` covers NSSM service registration only, not the run.bat/venv setup. Flagging in case a Windows agent setup section is wanted.

## rigcontrol_agent/windows/: replaced 4 files with the user's live working copy

**What:** the user uploaded `windows.zip` labeled as their actual live working copy of the Windows agent. Diffing it against the repo found real two-way divergence in `rigcontrol_agent_win.py` specifically - the repo had `mqtt_publish_resilient()`, an `_iso_to_sqlite_utc()` helper, an extra `start_date` param on `query_stats_history()`, and the `MIN_TELEMETRY_PULL_INTERVAL_SECONDS` overlap-guard (confirmed genuinely wired up, not dead code) that the live copy lacks - but the live copy was 786 lines vs the repo's 651, meaning it has real content the repo doesn't have anywhere else. Also confirmed `rigcontrol_telemetry.py`'s live copy still has the old `.split("://")[-1].split(":")[0]` POOL-truncation bug fixed earlier this session (Windows telemetry POOL fix entry, above) - the live deployment never got that fix pushed to it.

**Fixed:** per explicit user instruction ("treat windows.zip as source of truth"), replaced all 4 shared files as-is: `rigcontrol_agent.conf`, `rigcontrol_agent_win.py`, `rigcontrol_cmd.bat`, `rigcontrol_telemetry.py`.

**Known regressions from this replacement (flagging, not silently fixing):** this reintroduces the POOL-truncation bug in `rigcontrol_telemetry.py` (back to stripping `:port`) and drops `mqtt_publish_resilient()`, `_iso_to_sqlite_utc()`, the `query_stats_history()` `start_date` param, and the `MIN_TELEMETRY_PULL_INTERVAL_SECONDS` overlap-guard from `rigcontrol_agent_win.py`. None of these were re-applied on top of the uploaded files - the user can say if any should be layered back in.

**Verified:** `python3 -m py_compile` clean on both `.py` files.

## rigcontrol_agent/windows/: reverted the windows.zip replacement, matched GitHub instead

**What:** the user then uploaded `GitHub-08-20c.zip` and asked whether anything functional was missing for the server and agents. Diffing it exposed that the windows.zip replacement above was a mistake in the other direction: GitHub's copies had `mqtt_publish_resilient()`, the `MIN_TELEMETRY_PULL_INTERVAL_SECONDS` guard, and no POOL-truncation bug - all things windows.zip's version lacked or reintroduced. `rigcontrol_cmd.bat` turned out to be a bigger structural difference than a simple feature gap: GitHub's version controls 3 separate services (CPU/GPU/AUX, each with its own stop-flag file), matching the AUX-slot architecture built out everywhere else this session (keryxd, `CUSTOM_MINER_BIN_AUX`, `flightsheet.aux_template`, etc.); windows.zip's version instead controlled a single COMMON service with no AUX support at all. `rigcontrol_agent.conf` was also missing `MIN_TELEMETRY_PULL_INTERVAL_SECONDS` to match.

**Fixed:** per user confirmation, replaced all 5 files (`rigcontrol_agent.conf`, `rigcontrol_agent_win.py`, `rigcontrol_cmd.bat`, `rigcontrol_telemetry.py`, `run.bat`) with GitHub's versions, undoing the windows.zip replacement from the previous entry. GitHub's `run.bat` had already been fixed to "RigControl Agent" / `rigcontrol_agent_win.py` almost everywhere, except the `:: run hidden` PowerShell line at the bottom still called `'rigcloud_agent_win.py'` - fixed that one remaining stale reference too.

**Verified:** `rigcontrol_dashboard_server_pi/` confirmed fully in sync with GitHub (0 diffs); `rigcontrol_dashboard_server_windows/` confirmed in sync except `requirements.txt` (expected - that fix hasn't been pushed to GitHub yet); `python3 -m py_compile` clean on both `.py` files after the revert.

## Added rigcontrol_dashboard_server_windows/migrate_flightsheets_to_json.bat

**What:** the user confirmed run.bat's disappearance was a broader pattern - all run.bat files were dropped at some point during the RigCloud -> RigControl rename across the renamed repos, and separately recalled `migrate_flightsheets_to_json.py` used to have a `.bat` wrapper too. Checked all 4 uploads received so far (rigcontrol.zip, windows.zip, both GitHub exports) for one - not present in any of them. The user then uploaded `rename_flightsheet_conf_paths.py`/`.bat` "from old repo" (a related but different migration script - renames CPU/GPU conf tee paths inside a flightsheet DB, not the same as the JSON-format migration) plus a `copy-from-to-pi.txt` referencing a `migration-helper-scripts\` folder that doesn't exist anywhere in the current repo.

**Fixed:** wrote `migrate_flightsheets_to_json.bat` from scratch (no original recovered), modeled directly on `rename_flightsheet_conf_paths.bat`'s exact structure - DB_PATH/SCRIPT_PATH variables, existence checks, dry-run first, y/N confirm before writing - but wired to `migrate_flightsheets_to_json.py`'s actual CLI (`--list` to classify, `--show-diff` for the dry-run preview, `--apply` to write, matching its real argparse interface rather than guessing flag names).

**Deliberately not done:** did not add a `migration-helper-scripts/` folder or `rename_flightsheet_conf_paths.py`/`.bat` to the repo - user confirmed these are one-off/personal migration tools not meant for the tracked repo, not a missing-file gap to fix.
