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
