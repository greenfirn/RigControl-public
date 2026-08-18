"""
Standalone migration script: converts existing RigControl flightsheet DB
entries from the old KEY "value" conf-line raw-text format over to the
current rig-gpu.json-embedded format, IN PLACE, in the local SQLite
flightsheets DB (rigcontrol_flightsheets.db).

This does NOT touch app.js, the running dashboard server, or DynamoDB -
it operates directly on the SQLite file. Stop the dashboard server (or at
least avoid saving flightsheets) while this runs, to avoid racing a save
against this script's own read-modify-write.

If USE_AWS_DB=true on your server, this script only updates the LOCAL
BACKUP copy of the DB (rigcontrol_flightsheets.db) - it does not write to
DynamoDB. Convert locally first, verify with --list, then either flip
USE_AWS_DB off temporarily to let the local copy be authoritative, or
re-save each converted flightsheet once through the normal app UI so it
gets pushed to DynamoDB too.

Every row is POSITIVELY confirmed as an actual legacy flightsheet before
it's touched - not just "doesn't look like JSON". It has to:
  1. Contain the `tee ... /etc/rigcontrol/rig-{cpu,gpu}.conf ... <<'EOF' ... EOF`
     wrapper shape.
  2. Have at least one real `KEY "value"` line for a field this script
     actually knows about (ALGO, POOL, WALLET, MINER, etc.)
  3. NOT already parse as the new {"items": [...]} JSON shape.

Anything that doesn't clear all three checks is left completely alone and
reported as skipped ("not a flightsheet") rather than guessed at.

Usage:
    python3 migrate_flightsheets_to_json.py --db /path/to/rigcontrol_flightsheets.db [options]

Options:
    --db PATH           Path to rigcontrol_flightsheets.db (required)
    --templates PATH    Path to config/templates.json to source the current
                         cpu/gpu wrapper text from (default: config/templates.json
                         next to --db's directory; falls back to a built-in
                         copy of the wrapper text if not found)
    --apply             Actually write changes. Without this flag, the
                         script only reports what it WOULD do (dry run,
                         default).
    --no-backup         Skip making a timestamped .bak copy of the DB file
                         before writing (a backup is made by default
                         whenever --apply changes anything)
    --id ID             Only process this one flightsheet id (repeatable:
                         --id "Rig 1" --id "Rig 2")
    --list              List every flightsheet id + its classification
                         (json / legacy / not-a-flightsheet) and exit -
                         no conversion, no writes.
    --show-diff         In dry-run mode, also print the new JSON body each
                         legacy flightsheet would be converted to.

Examples:
    # See what would happen, touch nothing:
    python3 migrate_flightsheets_to_json.py --db ./rigcontrol_flightsheets.db --list

    # Dry run with preview of the generated JSON:
    python3 migrate_flightsheets_to_json.py --db ./rigcontrol_flightsheets.db --show-diff

    # Actually convert everything (backup made automatically):
    python3 migrate_flightsheets_to_json.py --db ./rigcontrol_flightsheets.db --apply

    # Convert just one flightsheet:
    python3 migrate_flightsheets_to_json.py --db ./rigcontrol_flightsheets.db --apply --id "My Rig 1"
"""

import argparse
import json
import re
import shutil
import sqlite3
import sys
import time
from pathlib import Path

FS_RAW_KEYS = {
    "TARGET_IMAGE": "text",
    "TARGET_NAME": "text",
    "RESET_OC": "checkbox",
    "APPLY_OC": "checkbox",
    "SCREEN_NAME": "text",
    "CUSTOM_MINER_URL": "text",
    "CUSTOM_MINER": "text",
    "MINER": "text",
    "ALGO": "text",
    "POOL": "text",
    "WALLET": "text",
    "PASS": "text",
    "ARGS": "text",
}

DEFAULT_CPU_TEMPLATE = (
    "tee /etc/rigcontrol/rig-cpu.json > /dev/null <<'EOF'\n"
    "%RIG_GPU_JSON%\n"
    "EOF\n"
    "sudo systemctl restart docker_events_cpu"
)
DEFAULT_GPU_TEMPLATE = (
    "tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'\n"
    "%RIG_GPU_JSON%\n"
    "EOF\n"
    "sudo systemctl restart docker_events_gpu"
)

LEGACY_WRAPPER_RE = re.compile(
    r"tee\s+/etc/rigcontrol/rig-(cpu|gpu)\.conf\s*>\s*/dev/null\s*<<'EOF'"
)
EOF_BODY_RE = re.compile(r"<<'EOF'\n([\s\S]*?)\nEOF\n?")


def load_templates(templates_path):
    """Returns (cpu_template, gpu_template) from the given templates.json
    if present/valid, else the built-in defaults above."""
    if templates_path:
        p = Path(templates_path)
        if p.exists():
            try:
                data = json.loads(p.read_text())
                fs = data.get("flightsheet", {})
                cpu_t = fs.get("cpu_template") or DEFAULT_CPU_TEMPLATE
                gpu_t = fs.get("gpu_template") or DEFAULT_GPU_TEMPLATE
                return cpu_t, gpu_t
            except Exception as e:
                print(f"WARNING: couldn't read {templates_path} ({e}), using built-in template text", file=sys.stderr)
        else:
            print(f"NOTE: {templates_path} not found, using built-in template text", file=sys.stderr)
    return DEFAULT_CPU_TEMPLATE, DEFAULT_GPU_TEMPLATE


def extract_field(raw, key):
    m = re.search(rf'^{re.escape(key)}\s+(?:0\s+)?"([^"]*)"', raw, re.MULTILINE)
    return m.group(1) if m else None


def already_json(raw):
    """True if raw's EOF body already parses as the new {"items":[...]}
    shape - nothing to do."""
    m = EOF_BODY_RE.search(raw)
    body = (m.group(1) if m else raw).strip()
    if not body.startswith("{"):
        return False
    try:
        parsed = json.loads(body)
    except Exception:
        return False
    return isinstance(parsed, dict) and isinstance(parsed.get("items"), list) and len(parsed["items"]) > 0


def classify(raw):
    """Returns one of: 'json', 'legacy', 'not-a-flightsheet'."""
    if not raw or not raw.strip():
        return "not-a-flightsheet"

    if already_json(raw):
        return "json"

    if not LEGACY_WRAPPER_RE.search(raw):
        return "not-a-flightsheet"

    if not EOF_BODY_RE.search(raw):
        return "not-a-flightsheet"

    has_known_field = any(extract_field(raw, key) is not None for key in FS_RAW_KEYS)
    if not has_known_field:
        return "not-a-flightsheet"

    return "legacy"


def build_json_body(values):
    """Mirrors buildRigGpuJsonBody() in app.js / the jq filter in
    00-get_rig_conf.sh exactly - same key set, same conditional-inclusion
    rules for optional fields."""
    is_custom = bool(values.get("CUSTOM_MINER")) and values["CUSTOM_MINER"] != "0"

    pool = values.get("POOL") or ""
    pool_ssl = False
    pool_url = pool
    if pool.startswith("stratum+ssl://"):
        pool_ssl = True
        pool_url = pool[len("stratum+ssl://"):]
    elif pool.startswith("stratum+tcp://"):
        pool_ssl = False
        pool_url = pool[len("stratum+tcp://"):]

    miner_config = {
        "url": pool_url,
        "algo": values.get("ALGO") or "",
        "pass": values.get("PASS") or "",
        "template": values.get("WALLET") or "",
    }
    if is_custom:
        miner_config["miner"] = values["CUSTOM_MINER"]
        if values.get("CUSTOM_MINER_URL"):
            miner_config["install_url"] = values["CUSTOM_MINER_URL"]
    if values.get("ARGS"):
        miner_config["user_config"] = values["ARGS"]

    item = {
        "pool_ssl": pool_ssl,
        "miner": "custom" if is_custom else (values.get("MINER") or ""),
    }
    if is_custom:
        item["miner_alt"] = values["CUSTOM_MINER"]
    if values.get("TARGET_IMAGE"):
        item["target_image"] = values["TARGET_IMAGE"]
    if values.get("TARGET_NAME"):
        item["target_name"] = values["TARGET_NAME"]
    if values.get("RESET_OC"):
        item["reset_oc"] = values["RESET_OC"]
    if values.get("APPLY_OC"):
        item["apply_oc"] = values["APPLY_OC"]
    item["miner_config"] = miner_config

    return json.dumps({"items": [item]}, indent=2)


def convert_raw(raw, cpu_template, gpu_template):
    """Converts one confirmed-legacy raw flightsheet text to the new
    JSON-embedded format. Returns the new raw text."""
    values = {}
    for key, kind in FS_RAW_KEYS.items():
        v = extract_field(raw, key)
        if v is None:
            v = "false" if kind == "checkbox" else ""
        values[key] = v

    is_cpu = "rig-cpu.conf" in raw
    template = cpu_template if is_cpu else gpu_template
    json_body = build_json_body(values)
    return template.replace("%RIG_GPU_JSON%", json_body)


def main():
    ap = argparse.ArgumentParser(
        description="Migrate RigControl flightsheet DB rows from old conf-line format to rig-gpu.json format.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("--db", required=True, help="Path to rigcontrol_flightsheets.db")
    ap.add_argument("--templates", default=None, help="Path to config/templates.json (default: <db-dir>/config/templates.json)")
    ap.add_argument("--apply", action="store_true", help="Actually write changes (default is dry-run)")
    ap.add_argument("--no-backup", action="store_true", help="Skip DB backup before writing")
    ap.add_argument("--id", action="append", default=None, help="Only process this flightsheet id (repeatable)")
    ap.add_argument("--list", action="store_true", help="List classifications and exit, no conversion")
    ap.add_argument("--show-diff", action="store_true", help="In dry-run mode, print the generated JSON body for each candidate")
    args = ap.parse_args()

    db_path = Path(args.db)
    if not db_path.exists():
        print(f"ERROR: DB file not found: {db_path}", file=sys.stderr)
        sys.exit(1)

    templates_path = args.templates or (db_path.parent / "config" / "templates.json")
    cpu_template, gpu_template = load_templates(templates_path)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    cur.execute("SELECT DISTINCT FlightsheetId FROM flightsheets ORDER BY FlightsheetId")
    all_ids = [row[0] for row in cur.fetchall()]

    if args.id:
        wanted = set(args.id)
        missing = wanted - set(all_ids)
        for m in missing:
            print(f"WARNING: requested id not found in DB: {m}", file=sys.stderr)
        all_ids = [i for i in all_ids if i in wanted]

    results = {"converted": [], "skipped_already_json": [], "skipped_not_a_flightsheet": [], "failed": []}

    for fs_id in all_ids:
        cur.execute(
            "SELECT Value FROM flightsheets WHERE FlightsheetId = ? AND GpuId = 0 AND Key = 'RAW_COMMAND'",
            (fs_id,),
        )
        row = cur.fetchone()
        raw = row["Value"] if row else None

        kind = classify(raw or "")

        if args.list:
            print(f"{kind:20s} {fs_id}")
            continue

        if kind == "json":
            results["skipped_already_json"].append(fs_id)
            continue
        if kind == "not-a-flightsheet":
            results["skipped_not_a_flightsheet"].append(fs_id)
            continue

        try:
            new_raw = convert_raw(raw, cpu_template, gpu_template)
        except Exception as e:
            results["failed"].append((fs_id, str(e)))
            continue

        if args.show_diff and not args.apply:
            print(f"--- {fs_id} ---")
            print(new_raw)
            print()

        if args.apply:
            try:
                now = int(time.time())
                cur.execute(
                    "UPDATE flightsheets SET Value = ?, UpdatedAt = ? WHERE FlightsheetId = ? AND GpuId = 0 AND Key = 'RAW_COMMAND'",
                    (new_raw, now, fs_id),
                )
            except Exception as e:
                results["failed"].append((fs_id, str(e)))
                continue

        results["converted"].append(fs_id)

    if args.list:
        conn.close()
        return

    if args.apply and results["converted"]:
        if not args.no_backup:
            backup_path = db_path.with_suffix(db_path.suffix + f".bak.{int(time.time())}")
            shutil.copy2(db_path, backup_path)
            print(f"Backup written: {backup_path}")
        conn.commit()
        print(f"APPLIED changes to {len(results['converted'])} flightsheet(s).")
    else:
        conn.rollback()
        if results["converted"]:
            print(f"DRY RUN - would convert {len(results['converted'])} flightsheet(s). Re-run with --apply to write.")

    conn.close()

    print()
    print("=== Summary ===")
    print(f"Converted:                   {len(results['converted'])}  {results['converted']}")
    print(f"Already JSON (skipped):      {len(results['skipped_already_json'])}  {results['skipped_already_json']}")
    print(f"Not a flightsheet (skipped): {len(results['skipped_not_a_flightsheet'])}  {results['skipped_not_a_flightsheet']}")
    if results["failed"]:
        print(f"FAILED:                      {len(results['failed'])}  {results['failed']}")


if __name__ == "__main__":
    main()
