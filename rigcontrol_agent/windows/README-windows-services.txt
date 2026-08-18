RigControl Windows Agent - Creating the CPU / GPU / AUX Services
==================================================================

rigcontrol_cmd.bat and rigcontrol_telemetry.py both now expect three
real Windows services to exist, with these EXACT names:

    docker_events_cpu
    docker_events_gpu
    docker_events_aux   (optional - only if this rig runs a 3rd miner slot)

Right now those services don't exist on a fresh Windows rig - "sc start
docker_events_cpu" (and the others) will fail with "service does not
exist" until you create them. cmd.bat's cpu.start/cpu.stop/cpu.restart,
gpu.*, and aux.* commands, plus the dashboard's telemetry state (running/
stopped, and now also which unit name it checked), all depend on these
three services actually being registered.

Windows can't turn an arbitrary .bat/.exe into a service on its own the
way systemd can on Linux (a systemd unit file is enough there) - you
need a small wrapper. The standard, free tool for this is NSSM
(the Non-Sucking Service Manager).


1. Download NSSM
-----------------
https://nssm.cc/download

Grab the win64 build, unzip it somewhere permanent, e.g.:
    C:\nssm\nssm.exe


2. Create each service
-----------------------
Open an elevated (Run as Administrator) Command Prompt and run one
"nssm install" per service. NSSM opens a small GUI the first time you
run "install" with just a name - point it at whatever actually starts
your CPU/GPU/AUX miner (a .bat launcher, docker.exe with the right
compose args, whatever this rig currently uses to start mining).

    C:\nssm\nssm.exe install docker_events_cpu

In the GUI:
    Path:             the .bat / .exe that starts the CPU miner
    Startup directory: the folder that script lives in
    Arguments:        any args that script needs

Repeat for GPU and (if used) AUX:

    C:\nssm\nssm.exe install docker_events_gpu
    C:\nssm\nssm.exe install docker_events_aux

If you'd rather skip the GUI, you can do it in one line per service
instead (same result):

    C:\nssm\nssm.exe install docker_events_cpu "C:\path\to\start-cpu-miner.bat"
    C:\nssm\nssm.exe install docker_events_gpu "C:\path\to\start-gpu-miner.bat"
    C:\nssm\nssm.exe install docker_events_aux "C:\path\to\start-aux-miner.bat"

The service name you give NSSM here (docker_events_cpu / _gpu / _aux)
MUST match exactly - that's the same string rigcontrol_cmd.bat and
rigcontrol_telemetry.py both use.


3. Set each service to start automatically (optional but recommended)
------------------------------------------------------------------------
    C:\nssm\nssm.exe set docker_events_cpu Start SERVICE_AUTO_START
    C:\nssm\nssm.exe set docker_events_gpu Start SERVICE_AUTO_START
    C:\nssm\nssm.exe set docker_events_aux Start SERVICE_AUTO_START

Leave a service on SERVICE_DEMAND_START instead if you don't want it
launching on every boot.


4. Verify
---------
    sc query docker_events_cpu
    sc query docker_events_gpu
    sc query docker_events_aux

Each should report STATE as either RUNNING or STOPPED (not "service
does not exist"). Once that's true, the dashboard's Command modal
(cpu.start / cpu.stop / cpu.restart / gpu.* / aux.*) and the
cpu_service / gpu_service / aux_service telemetry fields will reflect
real state instead of always showing "unknown" or "inactive".


5. Removing / renaming a service later
----------------------------------------
    C:\nssm\nssm.exe stop docker_events_cpu
    C:\nssm\nssm.exe remove docker_events_cpu confirm

Then re-run "nssm install" with the corrected target if you need to
point it at a different script.


Notes
-----
- All nssm commands above need an elevated Command Prompt (Run as
  Administrator) - "sc" commands to query status don't.
- If you use a different service name than the three above, update
  GPU_SERVICE / CPU_SERVICE / AUX_SERVICE at the top of
  rigcontrol_cmd.bat to match, and the matching "sc query ..." lines in
  rigcontrol_telemetry.py's collect_full_stats() (search for
  docker_events_cpu / docker_events_gpu / docker_events_aux) - all three
  places need to agree on the exact name.
- AUX is optional - if this rig only ever runs CPU or GPU mining, you
  can skip creating docker_events_aux. rigcontrol_telemetry.py will just
  report aux_service as inactive/unknown, which is harmless.


6. Stopping a miner cleanly WITHOUT skipping graceful shutdown
-------------------------------------------------------------------
IMPORTANT: if your miner needs to run its own cleanup on shutdown (e.g.
keryx-miner.exe resetting GPU overclocks before it exits), do NOT set
AppStopMethodSkip to skip the Console/Ctrl+C method - that jumps
straight to TerminateProcess, a hard kill that runs zero cleanup code.
An earlier version of this doc suggested that; it's wrong for any miner
that needs graceful shutdown to happen at all. Skipping Ctrl+C is only
appropriate for a miner you know does no cleanup work on exit.

The actual risk with the original start-logs.bat design wasn't Ctrl+C
failing to reach keryx-miner.exe (it does reach it - nothing in that
script opens a new console for it). The risk is the cmd.exe layer in
between: cmd.exe's own reaction to Ctrl+C while running a batch file is
to prompt "Terminate batch job (Y/N)?", which has no one to answer it
under a service, and a `goto loop`-style wrapper can also relaunch the
miner moments after a stop if the timing races NSSM's own teardown of
the tree.

The reliable fix is to remove cmd.exe (and PowerShell) from the picture
entirely and let NSSM run keryx-miner.exe directly, using NSSM's own
built-in equivalents for what the batch loop was hand-rolling:

  a) Point the service straight at the miner, no wrapper script:

         nssm edit docker_events_gpu

     Set Path to keryx-miner.exe itself, Arguments to the
     --mining-address/--keryxd-address flags, Startup directory to the
     miner's folder. (Or non-interactively: `nssm set docker_events_gpu
     Application "C:\path\to\keryx-miner.exe"` plus `AppParameters` and
     `AppDirectory`.)

  b) Auto-restart on crash - NSSM's native replacement for the
     `goto loop`. Critically, NSSM already knows the difference between
     "the app crashed, restart it" and "the service was told to stop,
     don't restart" - the exact race the STOP_FLAG file was working
     around. With this setup that file isn't needed for GPU anymore
     (rigcontrol_cmd.bat still writes/clears it - harmless, just unused
     here):

         nssm set docker_events_gpu AppExit Default Restart
         nssm set docker_events_gpu AppRestartDelay 5000

  c) Logging - NSSM's native replacement for the Tee-Object piping:

         nssm set docker_events_gpu AppStdout "C:\path\to\gpu_miner.log"
         nssm set docker_events_gpu AppStderr "C:\path\to\gpu_miner.log"

     Optional log rotation so the file doesn't grow forever:

         nssm set docker_events_gpu AppRotateFiles 1
         nssm set docker_events_gpu AppRotateOnline 1
         nssm set docker_events_gpu AppRotateBytes 10485760

  d) Give the graceful stop enough time to actually finish resetting
     overclocks before NSSM gives up and escalates further. Default is
     1500ms - almost certainly too short for an overclock reset. Watch
     the miner's own log for how long its cleanup actually takes after
     Ctrl+C and tune this accordingly (start around 8-10 seconds):

         nssm set docker_events_gpu AppStopMethodConsole 8000

     Do NOT touch AppStopMethodSkip for this service - leave Ctrl+C
     enabled, it's the only method that runs the miner's own cleanup
     code at all.

  Do the same for CPU/AUX only if those miners also need graceful
  cleanup on exit. If they don't, keeping their own batch loop +
  STOP_FLAG (or even skipping Ctrl+C for them specifically) is fine -
  this all applies per-service, not globally.
