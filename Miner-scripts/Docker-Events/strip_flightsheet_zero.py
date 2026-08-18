#!/usr/bin/env python3
"""
strip_flightsheet_zero.py

Strips the "0" GPU-index placeholder column out of rig-gpu.conf/rig-cpu.conf
heredocs stored in the RigCloud dashboard's flightsheets.db, converting
lines like:

    CUSTOM_MINER 0 "keryx-miner-supr"

into the 2-column form:

    CUSTOM_MINER "keryx-miner-supr"

Both rigcloud_agent.py's config auto-detection and the real get_rig_conf()
bash function (00-get_rig_conf.sh) already tolerate BOTH the 3-column and
2-column formats, so this is a cleanup, not a compatibility requirement -
existing 3-column rows keep working fine even if you never run this.

WHAT THIS TOUCHES (and does NOT touch):
  - Only rows in the `flightsheets` table whose Value starts with
    `tee /etc/rigcontrol/rig-gpu.conf` or `tee /etc/rigcontrol/rig-cpu.conf`
    (the flightsheets that write that specific 3-column conf format).
  - Within those, only lines that are EXACTLY "KEY 0 VALUE" (a bare "0"
    token as the whole 2nd whitespace-separated field) - a line like
    ALGO "rx/0" is untouched, because "0" there isn't a standalone
    token, it's part of the algorithm name string. Likewise "ALL" rows
    (e.g. in a miner-version-update flightsheet) are left alone - "0"
    means "leave it alone" was never the ask, only literal "0".
  - Everything else (api-conf, override-list, rename-host, docker-image
    flightsheets with raw miner args like "--gpu-id 0", etc.) is left
    completely untouched, including any literal "0" appearing inside
    those - they don't match the KEY-0-VALUE line shape at all.

USAGE:
    python3 strip_flightsheet_zero.py /path/to/rigcloud_flightsheets.db          # dry run (default)
    python3 strip_flightsheet_zero.py /path/to/rigcloud_flightsheets.db --write  # actually writes changes

Always run without --write first and review the diff before committing.
Back up the .db file before running with --write, just in case.
"""
import sqlite3
import sys
import shutil
import datetime
TARGET_PREFIXES = (
    "tee /etc/rigcontrol/rig-gpu.conf",
    "tee /etc/rigcontrol/rig-cpu.conf",
)
def strip_zero_column(text):
    """Rewrite every 'KEY 0 VALUE' line to 'KEY VALUE'. Any other line
    (including lines where the 2nd token is "ALL", or isn't a bare "0"
    at all, e.g. it's embedded in a longer value) is left untouched."""
    out_lines = []
    changed = False
    for line in text.split("\n"):
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1] == "0":
            out_lines.append(f"{parts[0]} {parts[2]}")
            changed = True
        else:
            out_lines.append(line)
    return "\n".join(out_lines), changed
def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    db_path = sys.argv[1]
    write = "--write" in sys.argv[2:]
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute(
        "SELECT FlightsheetId, GpuId, Key, Value FROM flightsheets WHERE Key='RAW_COMMAND'"
    )
    rows = cur.fetchall()
    any_changed = False
    for flightsheet_id, gpu_id, key, value in rows:
        if not value or not value.startswith(TARGET_PREFIXES):
            continue
        new_value, changed = strip_zero_column(value)
        if not changed:
            continue
        any_changed = True
        print(f"===== {flightsheet_id} (GpuId={gpu_id}) =====")
        old_lines = value.split("\n")
        new_lines = new_value.split("\n")
        for old_line, new_line in zip(old_lines, new_lines):
            if old_line != new_line:
                print(f"  - {old_line}")
                print(f"  + {new_line}")
        print()
        if write:
            cur.execute(
                "UPDATE flightsheets SET Value = ? WHERE FlightsheetId = ? AND GpuId = ? AND Key = ?",
                (new_value, flightsheet_id, gpu_id, key),
            )
    if not any_changed:
        print("No matching '0'-column lines found - nothing to change.")
        conn.close()
        return
    if write:
        conn.commit()
        print(f"Wrote changes to {db_path}.")
    else:
        print("Dry run only - no changes written. Re-run with --write to apply.")
    conn.close()
if __name__ == "__main__":
    main()
