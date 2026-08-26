const TEMPLATES_CONFIG_URL = "./static/config/templates.json";
const TEMPLATES_CONFIG = {
    flightsheet: {
        cpu_template:
            "tee /etc/rigcontrol/rig-cpu.json > /dev/null <<'EOF'\n" +
            "%RIG_GPU_JSON%\n" +
            "EOF\n" +
            "sudo systemctl restart docker_events_cpu",
        gpu_template:
            "tee /etc/rigcontrol/rig-gpu.json > /dev/null <<'EOF'\n" +
            "%RIG_GPU_JSON%\n" +
            "EOF\n" +
            "sudo systemctl restart docker_events_gpu",
        aux_template:
            "tee /etc/rigcontrol/rig-aux.json > /dev/null <<'EOF'\n" +
            "%RIG_GPU_JSON%\n" +
            "EOF\n" +
            "sudo systemctl restart docker_events_aux",
    },
    overclocking: {
        // These 3 keys mirror static/config/templates.json's "overclocking" section exactly (kept
        // in sync by hand) - they're the fallback used only if that file's fetch fails below, so
        // buildOcScriptFromRows() never reads an undefined key and silently breaks OC raw generation.
        // fan-curve.service itself is intentionally NOT one of these keys - it's installed once,
        // separately, via Fan-control/py-nvtool/install_fan-curve.sh (see apply_script_footer below).
        apply_script_header:
            "tee /usr/local/bin/gpu_apply_ocs.sh > /dev/null <<'EOF'\n" +
            "#!/bin/bash\n" +
            "# gpu_apply_ocs.sh <algo_name> / <custom miner name>\n" +
            "# Generated from the dashboard's Overclock module - edit there, not by hand.\n" +
            "# Note: a row's Algorithm field can list multiple comma-separated algo names\n" +
            "# (e.g. keryxhash,keryx-miner,keryx-minerx) - they're combined into one case\n" +
            "# pattern below, joined by '|', so they all share this row's OC settings.\n" +
            "\n" +
            "ALGO=\"${1:-}\"\n" +
            "if [[ -z \"$ALGO\" ]]; then\n" +
            "    echo \"Usage: $0 <algo_name>\"\n" +
            "    exit 1\n" +
            "fi\n" +
            "\n" +
            "ALGO_LOWER=$(echo \"$ALGO\" | tr '[:upper:]' '[:lower:]')\n" +
            "\n" +
            "case \"$ALGO_LOWER\" in\n",
        apply_script_algo_block:
            "    %ALGO%)\n" +
            "        CORE=%Lock Core Clock%\n" +
            "        CORE_OFFSET=%Core Clock Offset%\n" +
            "        MEM=%Lock Memory Clock%\n" +
            "        MEM_OFFSET=%Memory Clock Offset%\n" +
            "        POWER_LIMIT=%Power Limit%\n" +
            "        FAN_MODE=\"%Fan Mode%\"\n" +
            "        FAN_VALUE=\"%Fan Value%\"\n" +
            "        ;;\n",
        apply_script_footer:
            "    *)\n" +
            "        echo \"No OC profile defined for algo '$ALGO' - add a row for it in the dashboard's Overclock module\"\n" +
            "        exit 1\n" +
            "        ;;\n" +
            "esac\n" +
            "\n" +
            "echo \"Setting GPU OC for algo '$ALGO': core=$CORE (+$CORE_OFFSET) mem=$MEM (+$MEM_OFFSET) power_limit=$POWER_LIMIT fan=$FAN_MODE:$FAN_VALUE\"\n" +
            "CMD=(py-nvtool --setcore \"$CORE\" --setcoreoffset \"$CORE_OFFSET\" --setmem \"$MEM\" --setmemoffset \"$MEM_OFFSET\")\n" +
            "if [[ -n \"$POWER_LIMIT\" && \"$POWER_LIMIT\" != \"0\" ]]; then\n" +
            "    CMD+=(--setpl \"$POWER_LIMIT\")\n" +
            "fi\n" +
            "if [[ \"$FAN_MODE\" == \"percent\" ]]; then\n" +
            "    CMD+=(--setfan \"$FAN_VALUE\")\n" +
            "fi\n" +
            "\"${CMD[@]}\"\n" +
            "\n" +
            "\n" +
            // fan-curve.service is installed ONCE, separately (Fan-control/py-nvtool/install_fan-curve.sh) -
            // this only ever updates its --curve value in place, and only restarts the already-running
            // daemon when that value actually changed, instead of rewriting/bouncing the whole service on
            // every single miner (re)start regardless of whether the curve differs from before.
            "if [[ \"$FAN_MODE\" == \"curve\" ]]; then\n" +
            "    FAN_SVC=/etc/systemd/system/fan-curve.service\n" +
            "    if [[ -f \"$FAN_SVC\" ]]; then\n" +
            "        CURRENT_CURVE=$(sed -n 's/.*--curve \"\\([^\"]*\\)\".*/\\1/p' \"$FAN_SVC\")\n" +
            "        if [[ \"$CURRENT_CURVE\" != \"$FAN_VALUE\" ]]; then\n" +
            "            echo \"Fan curve changed - updating fan-curve.service and restarting it...\"\n" +
            "            sed -i \"s|--curve \\\"[^\\\"]*\\\"|--curve \\\"$FAN_VALUE\\\"|\" \"$FAN_SVC\"\n" +
            "            systemctl daemon-reload\n" +
            "            systemctl restart fan-curve.service\n" +
            "        fi\n" +
            "    else\n" +
            "        echo \"WARNING: fan-curve.service is not installed - run Fan-control/py-nvtool/install_fan-curve.sh once to set it up, then re-apply OC\"\n" +
            "    fi\n" +
            "fi\n" +
            "EOF\n" +
            "sudo chmod +x /usr/local/bin/gpu_apply_ocs.sh",
    },
    watchdog: {
        conf_dir: "/etc/rigcontrol",
        conf_path: "/etc/rigcontrol/rigcontrol-watchdog.conf",
    },
    agentconf: {
        conf_dir: "/etc/rigcontrol",
        conf_path: "/etc/rigcontrol/rigcontrol-agent.conf",
        restart_command: "sudo systemctl restart rigcontrol-agent.service",
    },
    // Lookup tables used by the Flightsheets auto-fill (pool short-name / coin ticker) - see
    // deriveCoinForClipboard()/derivePoolSlugForClipboard() below. Editing these in templates.json
    // (instead of here) lets new algo->coin mappings, pool hints, etc. be added without an app.js
    // redeploy. Each key here is a FULL replacement if present in templates.json, not a per-entry
    // merge - so an edit there should include the whole map, not just the new entries.
    flightsheet_derivation: {
        algo_to_coin: {
            autolykos2: "ERG",
            btx: "BTX",
            dynex: "DNX",
            keryxhash: "KRX",
            pearlhash: "PRL",
            qhash: "QTC",
            qubic: "QUBIC",
            verushash: "VRSC",
            warthog: "WART",
            xelishashv3: "XEL",
        },
        pool_coin_hints: [
            ["xmr", "XMR"],
            ["zephyr", "ZEPH"],
            ["tari", "XTM"],
            ["xtm", "XTM"],
            ["quai", "QUAI"],
            ["ergo", "ERG"],
            ["warthog", "WART"],
            ["xelis", "XEL"],
            ["qtc", "QTC"],
            ["pearl", "PRL"],
            ["etica", "ETI"],
        ],
        // Algos deliberately mapped to null - shared by multiple coins, so guessing one would be
        // more misleading than leaving "coin" blank for the user to fill in themselves.
        ambiguous_algo_defaults: {
            "rx/0": null,
            kawpow: null,
        },
        pool_slug_overrides: {
            luckypool: "luckypoolio",
            vipor: "vipornet",
            pearlhash: "pearlhash.xyz",
        },
    },
};
// Fetches static/config/templates.json and merges it over the hardcoded defaults above (section by
// section, key by key - see the TEMPLATES_CONFIG comment). Named (not an IIFE) so the Settings
// modal's Templates tab can re-run this after a successful save, refreshing TEMPLATES_CONFIG in
// this page immediately instead of only taking effect on the next page load.
async function loadTemplatesConfig() {
    try {
        const res = await fetch(`${TEMPLATES_CONFIG_URL}?_=${Date.now()}`);
        if (!res.ok) return;
        const data = await res.json();
        for (const section of Object.keys(TEMPLATES_CONFIG)) {
            if (data[section] && typeof data[section] === "object") {
                Object.assign(TEMPLATES_CONFIG[section], data[section]);
            }
        }
    } catch (err) {
        console.error("Failed to load templates.json, using built-in defaults", err);
    }
}
loadTemplatesConfig();
let rigsState = {};
let popoverState = {};
let lastUpdateTs = 0;
let resetInProgress = false;
let selectedRigs = new Set();
let rigSearchQuery = "";
let currentActionMode = localStorage.getItem("actionMode") || "all";
let wdEnabled = false;
let isSavingFlightsheet = false;
let flightsheets = [];
let selectedFlightsheetId = null;
let selectedFlightsheetIds = new Set();
let overclocks = [];
let selectedOverclockId = null;
let selectedOverclockIds = new Set();
let ocApplyInvokeAlgo = "";
let wallets = [];
let selectedWalletId = null;
let hiddenColumns = new Set();
let API = "";
let renderScheduled = false;
let ws = null;
let wsReconnectTimer = null;
let renderQueue = [];
let isProcessingQueue = false;
let wsInitialized = false;
let currentInterval = 10;
let originalIntervalValue = currentInterval;
let viewOnlyMode = false;
let isLocalConnection = true;
const VIEW_ONLY_DISABLED_IDS = [
    "btn-cmd-send", "btn-cmd-clear-send",
    "btn-open-logs", "btn-logs-refresh",
    "btn-action-start", "btn-action-stop", "btn-action-restart",
    "btn-quick-a", "btn-quick-b", "btn-quick-c",
    "btn-reset",
    "btn-send-it-fs", "btn-save-fs", "btn-delete-fs", "btn-clear-fs",
    "btn-send-it-oc", "btn-save-oc", "btn-delete-oc", "btn-clear-oc",
    "btn-save-wallet", "btn-delete-wallet", "btn-clear-wallet",
    "btn-wdconfig-add-row", "btn-send-it-wd",
    "btn-save-wdconfig", "btn-delete-wdconfig", "btn-clear-wdconfig",
    "btn-save-saved-cmd", "btn-delete-saved-cmd",
    "btn-statuslog-clear", "btn-statuslog-delete-selected",
    "btn-backups-backup", "btn-backups-restore", "btn-backups-delete", "btn-backups-import-keys",
    "btn-qa-apply",
    "btn-refresh-now", "btn-offline-ping-now", "btn-test-notification", "btn-refresh-save",
    "btn-save-advanced-server-settings",
    "btn-apply-stats-settings",
    "btn-save-color-scheme", "btn-open-color-scheme-json", "btn-import-color-scheme-json",
    "btn-export-color-scheme-json",
];
const COLOR_SCHEME_STORAGE_KEY = "rigcontrol_color_scheme";
const COLOR_SCHEME_MAP = {
    "color-surface-app": ["--surface-app"],
    "color-surface-header": ["--surface-header"],
    "color-surface-tabs": ["--surface-tabs"],
    "color-wallpaper-backdrop": ["--wallpaper-backdrop-color"],
    "color-action-output-bg": ["--action-output-bg", "--action-output-expanded-bg"],
    "color-surface-panel": ["--surface-panel"],
    "color-surface-row": ["--surface-row"],
    "color-surface-row-header": ["--surface-row-header"],
    "color-surface-modal": ["--surface-modal", "--surface-modal-panel", "--surface-refresh-modal-panel"],
    "color-surface-popup": ["--surface-popover"],
    "color-border-modal": ["--border-modal", "--border-divider", "--border-divider-soft"],
    "color-border-panel": ["--border-panel", "--chart-border"],
    "color-border-list": ["--border-list", "--border-list-item", "--border-table-header", "--border-table-row", "--border-watchdog-table-header", "--border-watchdog-table-row"],
    "color-text-primary": ["--text-primary"],
    "color-text-secondary": ["--text-secondary"],
    "color-text-muted": ["--text-muted"],
    "color-text-accent": ["--text-accent"],
    "color-text-header": ["--list-header-text"],
    "color-text-worker-name": ["--text-accent-soft"],
    "color-text-list": ["--list-text"],
    "color-docker-header-text": ["--text-docker-header"],
    "color-text-white": ["--text-white"],
    "color-button-bg": ["--button-bg"],
    "color-button-border": ["--button-border"],
    "color-button-text": ["--button-text", "--tab-text"],
    "color-button-hover-bg": ["--button-hover-bg", "--button-active-bg"],
    "color-tab-bg": ["--tab-bg"],
    "color-tab-border": ["--tab-border"],
    "color-tab-hover-bg": ["--tab-hover-bg"],
    "color-tab-active-bg": ["--tab-active-bg"],
    "color-tab-active-border": ["--tab-active-border"],
    "color-tab-active-text": ["--tab-active-text"],
    "color-tab-active-hover-bg": ["--tab-active-hover-bg"],
    "color-button-send-bg": ["--button-send-bg"],
    "color-button-send-border": ["--button-send-border"],
    "color-button-send-text": ["--button-send-text"],
    "color-button-send-hover-bg": ["--button-send-hover-bg"],
    "color-button-unlock-request-bg": ["--button-unlock-request-bg"],
    "color-button-unlock-request-border": ["--button-unlock-request-border"],
    "color-button-unlock-request-text": ["--button-unlock-request-text"],
    "color-button-unlock-request-hover-bg": ["--button-unlock-request-hover-bg"],
    "color-button-unlock-submit-bg": ["--button-unlock-submit-bg"],
    "color-button-unlock-submit-border": ["--button-unlock-submit-border"],
    "color-button-unlock-submit-text": ["--button-unlock-submit-text"],
    "color-button-unlock-submit-hover-bg": ["--button-unlock-submit-hover-bg"],
    "color-button-apply-fs-bg": ["--button-apply-fs-bg"],
    "color-button-apply-fs-border": ["--button-apply-fs-border"],
    "color-button-apply-fs-text": ["--button-apply-fs-text"],
    "color-button-apply-fs-hover-bg": ["--button-apply-fs-hover-bg"],
    "color-button-apply-oc-bg": ["--button-apply-oc-bg"],
    "color-button-apply-oc-border": ["--button-apply-oc-border"],
    "color-button-apply-oc-text": ["--button-apply-oc-text"],
    "color-button-apply-oc-hover-bg": ["--button-apply-oc-hover-bg"],
    "color-button-stats-load-bg": ["--button-stats-load-bg"],
    "color-button-stats-load-border": ["--button-stats-load-border"],
    "color-button-stats-load-text": ["--button-stats-load-text"],
    "color-button-stats-load-hover-bg": ["--button-stats-load-hover-bg"],
    "color-button-apply-wd-bg": ["--button-apply-wd-bg"],
    "color-button-apply-wd-border": ["--button-apply-wd-border"],
    "color-button-apply-wd-text": ["--button-apply-wd-text"],
    "color-button-apply-wd-hover-bg": ["--button-apply-wd-hover-bg"],
    "color-button-apply-qa-bg": ["--button-apply-qa-bg"],
    "color-button-apply-qa-border": ["--button-apply-qa-border"],
    "color-button-apply-qa-text": ["--button-apply-qa-text"],
    "color-button-apply-qa-hover-bg": ["--button-apply-qa-hover-bg"],
    "color-button-save-bg": ["--button-save-bg"],
    "color-button-save-text": ["--button-save-text"],
    "color-button-save-hover-bg": ["--button-save-hover-bg"],
    "color-button-save-border": ["--button-save-border"],
    "color-button-apply-stats-bg": ["--button-apply-stats-bg"],
    "color-button-apply-stats-border": ["--button-apply-stats-border"],
    "color-button-apply-stats-text": ["--button-apply-stats-text"],
    "color-button-apply-stats-hover-bg": ["--button-apply-stats-hover-bg"],
    "color-button-apply-stats-hover-border": ["--button-apply-stats-hover-border"],
    "color-button-refresh-now-bg": ["--button-refresh-now-bg"],
    "color-button-refresh-now-border": ["--button-refresh-now-border"],
    "color-button-refresh-now-text": ["--button-refresh-now-text"],
    "color-button-refresh-now-hover-bg": ["--button-refresh-now-hover-bg"],
    "color-button-ping-now-bg": ["--button-ping-now-bg"],
    "color-button-ping-now-border": ["--button-ping-now-border"],
    "color-button-ping-now-text": ["--button-ping-now-text"],
    "color-button-ping-now-hover-bg": ["--button-ping-now-hover-bg"],
    "color-button-test-alert-bg": ["--button-test-alert-bg"],
    "color-button-test-alert-border": ["--button-test-alert-border"],
    "color-button-test-alert-text": ["--button-test-alert-text"],
    "color-button-test-alert-hover-bg": ["--button-test-alert-hover-bg"],
    "color-button-clear-bg": ["--button-clear-bg"],
    "color-button-clear-border": ["--button-clear-border"],
    "color-button-clear-text": ["--button-clear-text"],
    "color-button-clear-hover-bg": ["--button-clear-hover-bg"],
    "color-button-clear-hover-border": ["--button-clear-hover-border"],
    "color-button-close-unlock-bg": ["--button-close-unlock-bg"],
    "color-button-close-unlock-border": ["--button-close-unlock-border"],
    "color-button-close-unlock-text": ["--button-close-unlock-text"],
    "color-button-close-unlock-hover-bg": ["--button-close-unlock-hover-bg"],
    "color-button-saved-cmd-save-bg": ["--button-saved-cmd-save-bg"],
    "color-button-saved-cmd-save-border": ["--button-saved-cmd-save-border"],
    "color-button-saved-cmd-save-text": ["--button-saved-cmd-save-text"],
    "color-button-saved-cmd-save-hover-bg": ["--button-saved-cmd-save-hover-bg"],
    "color-button-saved-cmd-delete-bg": ["--button-saved-cmd-delete-bg"],
    "color-button-saved-cmd-delete-border": ["--button-saved-cmd-delete-border"],
    "color-button-saved-cmd-delete-text": ["--button-saved-cmd-delete-text"],
    "color-button-saved-cmd-delete-hover-bg": ["--button-saved-cmd-delete-hover-bg"],
    "color-button-cmd-clear-bg": ["--button-cmd-clear-bg"],
    "color-button-cmd-clear-border": ["--button-cmd-clear-border"],
    "color-button-cmd-clear-text": ["--button-cmd-clear-text"],
    "color-button-cmd-clear-hover-bg": ["--button-cmd-clear-hover-bg"],
    "color-button-close-cmd-bg": ["--button-close-cmd-bg"],
    "color-button-close-cmd-border": ["--button-close-cmd-border"],
    "color-button-close-cmd-text": ["--button-close-cmd-text"],
    "color-button-close-cmd-hover-bg": ["--button-close-cmd-hover-bg"],
    "color-button-close-refresh-bg": ["--button-close-refresh-bg"],
    "color-button-close-refresh-border": ["--button-close-refresh-border"],
    "color-button-close-refresh-text": ["--button-close-refresh-text"],
    "color-button-close-refresh-hover-bg": ["--button-close-refresh-hover-bg"],
    "color-button-close-qa-bg": ["--button-close-qa-bg"],
    "color-button-close-qa-border": ["--button-close-qa-border"],
    "color-button-close-qa-text": ["--button-close-qa-text"],
    "color-button-close-qa-hover-bg": ["--button-close-qa-hover-bg"],
    "color-button-close-themes-bg": ["--button-close-themes-bg"],
    "color-button-close-themes-border": ["--button-close-themes-border"],
    "color-button-close-themes-text": ["--button-close-themes-text"],
    "color-button-close-themes-hover-bg": ["--button-close-themes-hover-bg"],
    "color-button-close-themes-json-bg": ["--button-close-themes-json-bg"],
    "color-button-close-themes-json-border": ["--button-close-themes-json-border"],
    "color-button-close-themes-json-text": ["--button-close-themes-json-text"],
    "color-button-close-themes-json-hover-bg": ["--button-close-themes-json-hover-bg"],
    "color-button-danger-bg": ["--button-danger-bg", "--button-reset-bg"],
    "color-button-danger-border": ["--button-danger-border"],
    "color-button-danger-text": ["--button-danger-text"],
    "color-button-danger-hover-bg": ["--button-danger-hover-bg", "--button-reset-hover-bg", "--surface-remove-row-hover"],
    "color-button-danger-hover-border": ["--button-danger-hover-border"],
    "color-button-notify-bg": ["--button-notify-bg"],
    "color-button-notify-border": ["--button-notify-border"],
    "color-button-notify-text": ["--button-notify-text"],
    "color-button-notify-hover-bg": ["--button-notify-hover-bg"],
    "color-button-new-bg": ["--button-new-bg"],
    "color-button-new-border": ["--button-new-border"],
    "color-button-new-text": ["--button-new-text"],
    "color-button-new-hover-bg": ["--button-new-hover-bg"],
    "color-button-send-it": ["--text-send-it"],
    "color-button-send-it-bg": ["--button-send-it-bg"],
    "color-button-send-it-border": ["--button-send-it-border"],
    "color-button-send-it-hover-bg": ["--button-send-it-hover-bg"],
    // No separate "color-wd-toggle-text" entry - --wd-toggle-text is aliased in app.css to
    // --rig-name-watchdog-active-text (var() reference), so editing "WD Active Text" below
    // keeps the toggle button's active-state text color in sync automatically.
    "color-wd-toggle-bg": ["--wd-toggle-bg"],
    "color-wd-toggle-border": ["--wd-toggle-border"],
    "color-wd-toggle-hover-bg": ["--wd-toggle-hover-bg"],
    "color-wd-active-text": ["--rig-name-watchdog-active-text"],
    "color-wd-paused-text": ["--rig-name-watchdog-standby-text"],
    "color-list-item-hover": ["--list-item-hover", "--surface-docker-detail", "--table-row-hover"],
    "color-list-item-selected": ["--list-item-selected"],
    "color-docker-popover-bg": ["--surface-docker-popover"],
    "color-status-uptime": ["--status-uptime-text"],
    "color-status-shares-good": ["--status-shares-good-text", "--status-shares-perfect-text"],
    "color-status-warning": ["--status-warning-text"],
    "color-status-error": ["--status-error-text"],
    "color-status-muted": ["--status-muted-text"],
    "color-input-bg": ["--input-bg"],
    "color-input-border": ["--input-border"],
    "color-search-bg": ["--search-bg"],
    "color-search-border": ["--search-border"],
    "color-editor-bg": ["--editor-bg"],
    "color-editor-border": ["--editor-border"],
};
const SIZE_SCHEME_MAP = {
    "size-toolbar-btn": ["--font-size-toolbar-btn"],
    "size-status-value": ["--font-size-status-value-lg"],
    "size-status-label": ["--font-size-status-label"],
    "size-action-output": ["--font-size-action-output"],
    "size-worker-header": ["--font-size-worker-header"],
    "size-main-list": ["--font-size-main-list"],
    "size-label": ["--font-size-label", "--font-size-checkbox-label"],
    "size-section-header": ["--font-size-section-header"],
    "size-input": ["--font-size-input", "--font-size-input-lg"],
    "size-hint": ["--font-size-hint", "--font-size-hint-sm"],
    "size-popover": ["--font-size-popover", "--font-size-popover-label", "--font-size-popover-value"],
    "size-gpu-table": ["--font-size-main-list-table", "--font-size-main-list-table-header"],
};
function loadColorSchemeOverrides() {
    try {
        const raw = localStorage.getItem(COLOR_SCHEME_STORAGE_KEY);
        return raw ? JSON.parse(raw) : {};
    } catch (err) {
        console.error("Failed to parse saved theme, ignoring it", err);
        return {};
    }
}
function saveColorSchemeOverrides(overrides) {
    localStorage.setItem(COLOR_SCHEME_STORAGE_KEY, JSON.stringify(overrides));
}
function applyColorSchemeOverrides(overrides) {
    const root = document.documentElement;
    for (const [controlId, value] of Object.entries(overrides)) {
        const isSize = controlId in SIZE_SCHEME_MAP;
        const cssVars = isSize ? SIZE_SCHEME_MAP[controlId] : COLOR_SCHEME_MAP[controlId];
        if (!cssVars) continue;
        const cssValue = isSize ? `${value}px` : value;
        cssVars.forEach(varName => root.style.setProperty(varName, cssValue));
    }
}
function clearColorSchemeOverride(controlId) {
    const overrides = loadColorSchemeOverrides();
    if (!(controlId in overrides)) return;
    delete overrides[controlId];
    saveColorSchemeOverrides(overrides);
    const cssVars = COLOR_SCHEME_MAP[controlId] || SIZE_SCHEME_MAP[controlId];
    if (cssVars) {
        const root = document.documentElement;
        cssVars.forEach(varName => root.style.removeProperty(varName));
    }
    const el = document.getElementById(controlId);
    if (el && cssVars && cssVars.length > 0) {
        const computed = getComputedStyle(document.documentElement);
        const current = computed.getPropertyValue(cssVars[0]).trim();
        if (controlId in SIZE_SCHEME_MAP) {
            const parsed = parseInt(current, 10);
            if (!isNaN(parsed)) el.value = parsed;
        } else if (current) {
            el.value = normalizeHexColor(current);
        }
    }
}
function setColorSchemeOverrideTransparent(controlId) {
    const overrides = loadColorSchemeOverrides();
    overrides[controlId] = "transparent";
    saveColorSchemeOverrides(overrides);
    applyColorSchemeOverrides({ [controlId]: "transparent" });
    const el = document.getElementById(controlId);
    if (el) el.value = normalizeHexColor("transparent");
}
applyColorSchemeOverrides(loadColorSchemeOverrides());
const WALLPAPER_STORAGE_KEY = "rigcontrol_wallpaper";
const WALLPAPER_OPACITY_STEP = 0.05;
const WALLPAPER_OPACITY_MIN = 0;
const WALLPAPER_OPACITY_MAX = 1;
const WALLPAPER_OPACITY_DEFAULT = 0.45;
function loadWallpaperSettings() {
    try {
        const raw = localStorage.getItem(WALLPAPER_STORAGE_KEY);
        return raw ? JSON.parse(raw) : null;
    } catch (err) {
        console.error("Failed to parse saved wallpaper settings, ignoring it", err);
        return null;
    }
}
function saveWallpaperSettings(settings) {
    try {
        localStorage.setItem(WALLPAPER_STORAGE_KEY, JSON.stringify(settings));
        return true;
    } catch (err) {
        console.error("Failed to save wallpaper settings", err);
        return false;
    }
}
function applyWallpaperSettings(settings) {
    const root = document.documentElement;
    const image = settings?.image;
    const opacity = typeof settings?.opacity === "number" ? settings.opacity : WALLPAPER_OPACITY_DEFAULT;
    const fit = !!settings?.fit;
    const tile = !!settings?.tile;
    root.style.setProperty("--wallpaper-image", image ? `url("${image}")` : "none");
    root.style.setProperty("--wallpaper-opacity", String(opacity));
    root.style.setProperty("--wallpaper-size", fit ? "contain" : (tile ? "auto" : "cover"));
    root.style.setProperty("--wallpaper-repeat", tile ? "repeat" : "no-repeat");
    root.style.setProperty("--wallpaper-row-fade", image ? String(opacity) : "0");
    const fitCheckbox = document.getElementById("wallpaper-fit-checkbox");
    if (fitCheckbox) fitCheckbox.checked = fit;
    const tileCheckbox = document.getElementById("wallpaper-tile-checkbox");
    if (tileCheckbox) tileCheckbox.checked = tile;
}
function isHttpUrl(value) {
    return typeof value === "string" && /^https?:\/\//i.test(value.trim());
}
function applyThemeDataWallpaper(data) {
    const url = data?.wallpaperUrl;
    if (!isHttpUrl(url)) return;
    const existing = loadWallpaperSettings();
    const opacity = typeof data.wallpaperOpacity === "number" ? data.wallpaperOpacity : (existing?.opacity ?? WALLPAPER_OPACITY_DEFAULT);
    const fit = typeof data.wallpaperFit === "boolean" ? data.wallpaperFit : !!existing?.fit;
    const tile = typeof data.wallpaperTile === "boolean" ? data.wallpaperTile : !!existing?.tile;
    const settings = { image: url.trim(), opacity, fit, tile };
    applyWallpaperSettings(settings);
    saveWallpaperSettings(settings);
}
const STAT_PANEL_IMAGE_STORAGE_KEY = "rigcontrol_stat_panel_image";
const STAT_PANEL_IMAGE_OPACITY_STEP = 0.05;
const STAT_PANEL_IMAGE_OPACITY_MIN = 0;
const STAT_PANEL_IMAGE_OPACITY_MAX = 1;
const STAT_PANEL_IMAGE_OPACITY_DEFAULT = 0.3;
function loadStatPanelImageSettings() {
    try {
        const raw = localStorage.getItem(STAT_PANEL_IMAGE_STORAGE_KEY);
        return raw ? JSON.parse(raw) : null;
    } catch (err) {
        console.error("Failed to parse saved info tiles background settings, ignoring it", err);
        return null;
    }
}
function saveStatPanelImageSettings(settings) {
    try {
        localStorage.setItem(STAT_PANEL_IMAGE_STORAGE_KEY, JSON.stringify(settings));
        return true;
    } catch (err) {
        console.error("Failed to save info tiles background settings", err);
        return false;
    }
}
const STAT_PANEL_IMAGE_FIT_DEFAULT = "cover";
const STAT_PANEL_IMAGE_FIT_MAP = {
    cover: { size: "cover", repeat: "no-repeat" },          
    contain: { size: "contain", repeat: "no-repeat" },      
    stretch: { size: "100% 100%", repeat: "no-repeat" },    
    center: { size: "auto", repeat: "no-repeat" },          
    tile: { size: "auto", repeat: "repeat" },                
    "tile-contain": { size: "contain", repeat: "repeat" },  
};
function applyStatPanelImageSettings(settings) {
    const root = document.documentElement;
    const image = settings?.image;
    const opacity = typeof settings?.opacity === "number" ? settings.opacity : STAT_PANEL_IMAGE_OPACITY_DEFAULT;
    const fit = STAT_PANEL_IMAGE_FIT_MAP[settings?.fit] ? settings.fit : STAT_PANEL_IMAGE_FIT_DEFAULT;
    const fitCss = STAT_PANEL_IMAGE_FIT_MAP[fit];
    root.style.setProperty("--stat-panel-image", image ? `url("${image}")` : "none");
    root.style.setProperty("--stat-panel-image-opacity", String(opacity));
    root.style.setProperty("--stat-panel-image-size", fitCss.size);
    root.style.setProperty("--stat-panel-image-repeat", fitCss.repeat);
    const fitSelect = document.getElementById("stat-panel-image-fit-select");
    if (fitSelect) fitSelect.value = fit;
}
function applyThemeDataStatPanelImage(data) {
    const url = data?.statPanelImageUrl;
    if (!isHttpUrl(url)) return;
    const existing = loadStatPanelImageSettings();
    const opacity = typeof data.statPanelImageOpacity === "number" ? data.statPanelImageOpacity : (existing?.opacity ?? STAT_PANEL_IMAGE_OPACITY_DEFAULT);
    const fit = typeof data.statPanelImageFit === "string" ? data.statPanelImageFit : (existing?.fit ?? STAT_PANEL_IMAGE_FIT_DEFAULT);
    const settings = { image: url.trim(), opacity, fit };
    applyStatPanelImageSettings(settings);
    saveStatPanelImageSettings(settings);
}
const STAT_PANEL_STYLE_STORAGE_KEY = "rigcontrol_stat_panel_style";
const STAT_PANEL_STYLE_DEFAULT = { shape: "rounded", size: "compact", layout: "stacked" };
const STAT_PANEL_SHAPE_RADIUS = { square: "4px", rounded: "10px", pill: "999px" };
const STAT_PANEL_SIZE_METRICS = {
    compact: { paddingY: "6px", paddingX: "10px", minWidth: "70px", gap: "2px" },
    normal: { paddingY: "10px", paddingX: "16px", minWidth: "90px", gap: "4px" },
    large: { paddingY: "14px", paddingX: "22px", minWidth: "110px", gap: "6px" },
};
function loadStatPanelStyle() {
    try {
        const raw = localStorage.getItem(STAT_PANEL_STYLE_STORAGE_KEY);
        const saved = raw ? JSON.parse(raw) : null;
        return { ...STAT_PANEL_STYLE_DEFAULT, ...(saved || {}) };
    } catch (err) {
        console.error("Failed to parse saved panel style, ignoring it", err);
        return { ...STAT_PANEL_STYLE_DEFAULT };
    }
}
function saveStatPanelStyle(settings) {
    localStorage.setItem(STAT_PANEL_STYLE_STORAGE_KEY, JSON.stringify(settings));
}
function applyStatPanelStyle(settings) {
    const root = document.documentElement;
    const shape = STAT_PANEL_SHAPE_RADIUS[settings?.shape] ? settings.shape : STAT_PANEL_STYLE_DEFAULT.shape;
    const size = STAT_PANEL_SIZE_METRICS[settings?.size] ? settings.size : STAT_PANEL_STYLE_DEFAULT.size;
    const layout = settings?.layout === "horizontal" ? "horizontal" : "stacked";
    root.style.setProperty("--stat-panel-radius", STAT_PANEL_SHAPE_RADIUS[shape]);
    const metrics = STAT_PANEL_SIZE_METRICS[size];
    root.style.setProperty("--stat-panel-padding-y", metrics.paddingY);
    root.style.setProperty("--stat-panel-padding-x", metrics.paddingX);
    root.style.setProperty("--stat-panel-min-width", metrics.minWidth);
    root.style.setProperty("--stat-panel-gap", metrics.gap);
    document.getElementById("action-stats-bar")?.classList.toggle("stat-panels-horizontal", layout === "horizontal");
    const shapeSelect = document.getElementById("stat-panel-shape-select");
    if (shapeSelect) shapeSelect.value = shape;
    const sizeSelect = document.getElementById("stat-panel-size-select");
    if (sizeSelect) sizeSelect.value = size;
    const layoutSelect = document.getElementById("stat-panel-layout-select");
    if (layoutSelect) layoutSelect.value = layout;
}
function applyThemeDataStatPanelStyle(data) {
    if (!data || (data.statPanelShape === undefined && data.statPanelSize === undefined && data.statPanelLayout === undefined)) return;
    const existing = loadStatPanelStyle();
    const settings = {
        shape: typeof data.statPanelShape === "string" ? data.statPanelShape : existing.shape,
        size: typeof data.statPanelSize === "string" ? data.statPanelSize : existing.size,
        layout: typeof data.statPanelLayout === "string" ? data.statPanelLayout : existing.layout,
    };
    applyStatPanelStyle(settings);
    saveStatPanelStyle(settings);
}
const TOOLBAR_BTN_STYLE_STORAGE_KEY = "rigcontrol_toolbar_btn_style";
const TOOLBAR_BTN_STYLE_DEFAULT = { shape: "rounded", size: "normal" };
const TOOLBAR_BTN_LOCK_STORAGE_KEY = "rigcontrol_toolbar_btn_lock";
function loadToolbarBtnLock() {
    return localStorage.getItem(TOOLBAR_BTN_LOCK_STORAGE_KEY) === "1";
}
function saveToolbarBtnLock(locked) {
    if (locked) {
        localStorage.setItem(TOOLBAR_BTN_LOCK_STORAGE_KEY, "1");
    } else {
        localStorage.removeItem(TOOLBAR_BTN_LOCK_STORAGE_KEY);
    }
}
const TOOLBAR_BTN_SHAPE_RADIUS = { square: "4px", rounded: "6px", pill: "999px", circle: "50%" };
const TOOLBAR_BTN_SIZE_METRICS = {
    compact: { height: "22px", paddingX: "6px", minWidth: "30px", fontSize: "10px" },
    normal: { height: "28px", paddingX: "8px", minWidth: "40px", fontSize: "12px" },
    large: { height: "36px", paddingX: "12px", minWidth: "52px", fontSize: "14px" },
};
function loadToolbarBtnStyle() {
    try {
        const raw = localStorage.getItem(TOOLBAR_BTN_STYLE_STORAGE_KEY);
        const saved = raw ? JSON.parse(raw) : null;
        return { ...TOOLBAR_BTN_STYLE_DEFAULT, ...(saved || {}) };
    } catch (err) {
        console.error("Failed to parse saved toolbar button style, ignoring it", err);
        return { ...TOOLBAR_BTN_STYLE_DEFAULT };
    }
}
function saveToolbarBtnStyle(settings) {
    localStorage.setItem(TOOLBAR_BTN_STYLE_STORAGE_KEY, JSON.stringify(settings));
}
function applyToolbarBtnStyle(settings) {
    const root = document.documentElement;
    const shape = TOOLBAR_BTN_SHAPE_RADIUS[settings?.shape] ? settings.shape : TOOLBAR_BTN_STYLE_DEFAULT.shape;
    const size = TOOLBAR_BTN_SIZE_METRICS[settings?.size] ? settings.size : TOOLBAR_BTN_STYLE_DEFAULT.size;
    root.style.setProperty("--toolbar-btn-radius", TOOLBAR_BTN_SHAPE_RADIUS[shape]);
    const metrics = TOOLBAR_BTN_SIZE_METRICS[size];
    root.style.setProperty("--toolbar-btn-height", metrics.height);
    root.style.setProperty("--toolbar-btn-padding-x", metrics.paddingX);
    root.style.setProperty("--toolbar-btn-min-width", metrics.minWidth);
    root.style.setProperty("--toolbar-btn-font-size", metrics.fontSize);
    const shapeSelect = document.getElementById("toolbar-btn-shape-select");
    if (shapeSelect) shapeSelect.value = shape;
    const sizeSelect = document.getElementById("toolbar-btn-size-select");
    if (sizeSelect) sizeSelect.value = size;
}
function applyThemeDataToolbarBtnStyle(data) {
    if (!data || (data.toolbarBtnShape === undefined && data.toolbarBtnSize === undefined)) return;
    const existing = loadToolbarBtnStyle();
    const settings = {
        shape: typeof data.toolbarBtnShape === "string" ? data.toolbarBtnShape : existing.shape,
        size: typeof data.toolbarBtnSize === "string" ? data.toolbarBtnSize : existing.size,
    };
    applyToolbarBtnStyle(settings);
    saveToolbarBtnStyle(settings);
}
const TOOLBAR_BTN_ICON_STORAGE_KEY = "rigcontrol_toolbar_btn_icons";
const TOOLBAR_BTN_ICON_DEFAULTS = {
    "btn-mode-all": "ALL",
    "btn-mode-cpu": "CPU",
    "btn-mode-gpu": "GPU",
    "btn-mode-aux": "AUX",
    "btn-wd-enable": "WD",
    "btn-action-start": "\u25B6",
    "btn-action-stop": "\u25A0",
    "btn-action-restart": "\u21BB",
    "btn-quick-a": "A",
    "btn-quick-b": "B",
    "btn-quick-c": "C",
};
const TAB_ICON_STORAGE_KEY = "rigcontrol_tab_icons";
const TAB_ICON_DEFAULTS = {
    "workers": "\uD83D\uDDA5\uFE0F",
    "stats": "\uD83D\uDCCA",
    "wallets": "\uD83D\uDCB0",
    "flightsheets": "\uD83D\uDCCB",
    "overclocking": "\u26A1",
    "watchdog": "\uD83D\uDC15",
    "statuslog": "\uD83D\uDCDC",
    "backups": "\uD83D\uDDC4\uFE0F",
    "settings": "\u2699\uFE0F",
};
const TOOLBAR_CUSTOM_ICONS_STORAGE_KEY = "rigcontrol_toolbar_custom_icons";
function loadToolbarCustomIcons() {
    try {
        const raw = localStorage.getItem(TOOLBAR_CUSTOM_ICONS_STORAGE_KEY);
        const saved = raw ? JSON.parse(raw) : null;
        return Array.isArray(saved) ? saved : [];
    } catch (err) {
        console.error("Failed to parse saved custom toolbar icons, ignoring them", err);
        return [];
    }
}
function saveToolbarCustomIcons(list) {
    localStorage.setItem(TOOLBAR_CUSTOM_ICONS_STORAGE_KEY, JSON.stringify(list || []));
}
function addToolbarCustomIconOption(src, label) {
    const picker = document.getElementById("toolbar-icon-picker-select");
    if (!picker) return;
    const pickerLabel = document.getElementById("toolbar-icon-picker-selected-label");
    const existingOption = Array.from(picker.options).find(o => o.value === src);
    if (existingOption) {
        picker.value = src;
        if (pickerLabel) pickerLabel.textContent = existingOption.textContent;
        return;
    }
    const option = document.createElement("option");
    option.value = src;
    option.textContent = label;
    picker.appendChild(option);
    picker.value = src;
    if (pickerLabel) pickerLabel.textContent = label;
    const list = loadToolbarCustomIcons();
    if (!list.some(entry => entry.src === src)) {
        list.push({ src, label });
        saveToolbarCustomIcons(list);
    }
}
function loadToolbarBtnIcons() {
    try {
        const raw = localStorage.getItem(TOOLBAR_BTN_ICON_STORAGE_KEY);
        const saved = raw ? JSON.parse(raw) : null;
        return (saved && typeof saved === "object") ? saved : {};
    } catch (err) {
        console.error("Failed to parse saved toolbar button icons, ignoring them", err);
        return {};
    }
}
function saveToolbarBtnIcons(overrides) {
    localStorage.setItem(TOOLBAR_BTN_ICON_STORAGE_KEY, JSON.stringify(overrides || {}));
}
function loadTabIcons() {
    try {
        const raw = localStorage.getItem(TAB_ICON_STORAGE_KEY);
        const saved = raw ? JSON.parse(raw) : null;
        return (saved && typeof saved === "object") ? saved : {};
    } catch (err) {
        console.error("Failed to parse saved tab icons, ignoring them", err);
        return {};
    }
}
function saveTabIcons(overrides) {
    localStorage.setItem(TAB_ICON_STORAGE_KEY, JSON.stringify(overrides || {}));
}
function applyTabIcons(overrides) {
    const map = overrides || {};
    const customIcons = loadToolbarCustomIcons();
    for (const key of Object.keys(TAB_ICON_DEFAULTS)) {
        const el = document.getElementById(`view-tab-icon-${key}`);
        const label = typeof map[key] === "string" && map[key].trim() !== "" ? map[key] : TAB_ICON_DEFAULTS[key];
        if (el) {
            if (isImageIconValue(label)) {
                el.textContent = "";
                const img = document.createElement("img");
                img.className = "toolbar-btn-icon-img";
                img.src = label;
                img.alt = "";
                el.appendChild(img);
            } else {
                el.textContent = label;
            }
        }
        const input = document.getElementById(`tab-icon-input-${key}`);
        if (input) {
            const rawVal = typeof map[key] === "string" ? map[key] : TAB_ICON_DEFAULTS[key];
            if (isImageIconValue(rawVal)) {
                const known = customIcons.find(entry => entry.src === rawVal);
                input.value = known ? known.label : (rawVal.length > 28 ? `${rawVal.slice(0, 25)}...` : rawVal);
                input.dataset.srcValue = rawVal;
            } else {
                input.value = rawVal;
                delete input.dataset.srcValue;
            }
        }
        const preview = document.getElementById(`tab-icon-preview-${key}`);
        if (preview) {
            if (isImageIconValue(label)) {
                preview.src = label;
                preview.style.display = "inline-block";
            } else {
                preview.removeAttribute("src");
                preview.style.display = "none";
            }
        }
    }
}
function isImageIconValue(val) {
    return typeof val === "string" && (val.startsWith("http://") || val.startsWith("https://") || val.startsWith("data:image/"));
}
function applyToolbarBtnIcons(overrides) {
    const map = overrides || {};
    const customIcons = loadToolbarCustomIcons();
    for (const id of Object.keys(TOOLBAR_BTN_ICON_DEFAULTS)) {
        const el = document.getElementById(id);
        const label = typeof map[id] === "string" && map[id].trim() !== "" ? map[id] : TOOLBAR_BTN_ICON_DEFAULTS[id];
        if (el) {
            if (isImageIconValue(label)) {
                el.textContent = "";
                const img = document.createElement("img");
                img.className = "toolbar-btn-icon-img";
                img.src = label;
                img.alt = "";
                el.appendChild(img);
            } else {
                el.textContent = label;
            }
        }
        const input = document.getElementById(`toolbar-icon-input-${id}`);
        if (input) {
            const rawVal = typeof map[id] === "string" ? map[id] : TOOLBAR_BTN_ICON_DEFAULTS[id];
            if (isImageIconValue(rawVal)) {
                const known = customIcons.find(entry => entry.src === rawVal);
                input.value = known ? known.label : (rawVal.length > 28 ? `${rawVal.slice(0, 25)}...` : rawVal);
                input.dataset.srcValue = rawVal;
            } else {
                input.value = rawVal;
                delete input.dataset.srcValue;
            }
        }
        const preview = document.getElementById(`toolbar-icon-preview-${id}`);
        if (preview) {
            if (isImageIconValue(label)) {
                preview.src = label;
                preview.style.display = "inline-block";
            } else {
                preview.removeAttribute("src");
                preview.style.display = "none";
            }
        }
    }
}
function applyThemeDataToolbarBtnIcons(data) {
    if (loadToolbarBtnLock()) return;
    if (!data || data.toolbarBtnIcons === undefined) return;
    const overrides = (data.toolbarBtnIcons && typeof data.toolbarBtnIcons === "object") ? data.toolbarBtnIcons : {};
    applyToolbarBtnIcons(overrides);
    saveToolbarBtnIcons(overrides);
}
applyWallpaperSettings(loadWallpaperSettings());
applyStatPanelImageSettings(loadStatPanelImageSettings());
applyStatPanelStyle(loadStatPanelStyle());
applyToolbarBtnStyle(loadToolbarBtnStyle());
const BASE_PATH = location.pathname.replace(/\/$/, "");
const v = id => document.querySelector(id)?.value ?? "";
const c = id => document.querySelector(id)?.checked ?? false;
const FS_FIELD_DEFAULTS = {
    "fs-field-coin": "",
    "fs-field-target-image": "",
    "fs-field-target-name": "",
    "fs-field-service-type": "gpu",
    "fs-field-custom-miner-url": "",
    "fs-field-custom-miner": "",
    "fs-field-miner": "",
    "fs-field-algo": "",
    "fs-field-pool": "",
    "fs-field-wallet": "",
    "fs-field-template": "",
    "fs-field-pass": "x",
    "fs-field-args": "",
    "fs-field-miner-version": ""
};
const FS_CHECKBOX_FIELD_DEFAULTS = {
    "fs-field-reset-oc": true,
    "fs-field-apply-oc": false,
    "fs-field-ssl": false,
    "fs-field-tls": false,
    "fs-field-restart": false
};
const FS_RAW_KEY_MAP = {
    "COIN": { id: "fs-field-coin", type: "text" },
    "TARGET_IMAGE": { id: "fs-field-target-image", type: "text" },
    "TARGET_NAME": { id: "fs-field-target-name", type: "text" },
    "RESET_OC": { id: "fs-field-reset-oc", type: "checkbox" },
    "APPLY_OC": { id: "fs-field-apply-oc", type: "checkbox" },
    "RESTART": { id: "fs-field-restart", type: "checkbox" },
    "VERSION": { id: "fs-field-miner-version", type: "text" },
    "SERVICE_TYPE": { id: "fs-field-service-type", type: "text" },
    "CUSTOM_MINER_URL": { id: "fs-field-custom-miner-url", type: "text" },
    "CUSTOM_MINER": { id: "fs-field-custom-miner", type: "text" },
    "MINER": { id: "fs-field-miner", type: "text" },
    "ALGO": { id: "fs-field-algo", type: "text" },
    "POOL": { id: "fs-field-pool", type: "text" },
    "WALLET": { id: "fs-field-wallet", type: "text" },
    "TEMPLATE": { id: "fs-field-template", type: "text" },
    "PASS": { id: "fs-field-pass", type: "text" },
    "ARGS": { id: "fs-field-args", type: "text" }
};
const FS_FIELD_ID_TO_KEY = {};
const FS_KEY_ORDER = [
    "SERVICE_TYPE", "TARGET_IMAGE", "TARGET_NAME", "APPLY_OC", "RESET_OC", "RESTART", "VERSION",
    "MINER", "ALGO", "PASS", "POOL", "WALLET", "TEMPLATE", "ARGS",
    "CUSTOM_MINER", "CUSTOM_MINER_URL"
];
const MAX_ACTION_OUTPUT_ROWS = 50;
const NOTES_URL_REGEX = /(https?:\/\/[^\s<]+)/g;
const FS_WALLET_SUGGESTIONS_MAX = 8;
const FS_MINER_LIST = [
    "custom",
    "xmrig", "wildrig-multi", "bzminer", "SRBMiner-MULTI", "SRBMiner-MULTI-cpu", "rigel",
    "lolMiner", "onezerominer", "gminer", "teamredminer", "t-rex"
];
const FS_PASS_LIST = ["x", "%WORKER_NAME%"];
let pendingStatsRequests = {};
let statsCharts = {};
const STATS_CHART_COLORS = ["#4fc3f7", "#ff8a65", "#aed581", "#ba68c8", "#ffd54f", "#4db6ac", "#f06292", "#90a4ae"];
let wdAlgoSuggestionsList = [];
let wdRowSettings = new Map();
let selectedWdRowId = null;
let wdRowIdCounter = 0;
const WD_HASHRATE_UNITS = ["H/s", "KH/s", "MH/s", "GH/s", "TH/s"];
const HASHRATE_UNIT_MULTIPLIERS = {
    "H/s": 1,
    "KH/s": 1e3,
    "MH/s": 1e6,
    "GH/s": 1e9,
    "TH/s": 1e12,
    "PH/s": 1e15,
};
let _lastStatsResp = null;
let wdHashrateUnit = "MH/s";
const WD_GLOBAL_STOP_FAILS_DEFAULT = 5;
const WD_LOG_WATCHER_SLOT_IDS = ["cpu", "gpu", "aux"];
const WD_LOG_WATCHER_INTERVAL_DEFAULT = 10;
const WD_MINING_INTERVAL_DEFAULT = 30;
const WD_LOG_WATCHER_SEVERITIES = ["good", "warn", "important", "critical"];
const WD_LOG_WATCHER_SEVERITY_LABELS = { good: "Good", warn: "Warn", important: "Important", critical: "Critical" };
const WD_LOG_TERM_ACTION_DEFS = [
    ["cpu", "ACTION_RESTART_CPU", "CPU"],
    ["gpu", "ACTION_RESTART_GPU", "GPU"],
    ["fan", "ACTION_RESTART_FAN", "Fan"],
    ["aux", "ACTION_RESTART_AUX", "AUX"],
    ["email", "ACTION_EMAIL_NOTIFY", "Email"],
    ["sms", "ACTION_SMS_NOTIFY", "SMS"],
    ["reboot", "ACTION_REBOOT_RIG", "Reboot"],
    ["script", "ACTION_CUSTOM_SCRIPT", "Script"],
];
let wdLogTermRowIdCounter = 0;
let selectedWdLogTermRowId = null;
let wdLogTermScripts = new Map();
let selectedStatusLogIds = new Set();
let watchdogProfiles = [];
let selectedWatchdogProfileId = null;
let savedCommands = [];
let selectedSavedCommandId = null;
const WD_ACTION_CHECKBOX_DEFAULTS = {
    "wdconfig-action-restart-cpu": false,
    "wdconfig-action-restart-gpu": false,
    "wdconfig-action-reboot-rig": false,
    "wdconfig-action-email-notify": true,
    "wdconfig-action-sms-notify": false,
    "wdconfig-action-restart-fan": false,
    "wdconfig-action-restart-aux": false,
    "wdconfig-action-custom-script": false
};
const WD_ACTION_RAW_KEYS = [
    ["wdconfig-action-restart-cpu", "ACTION_RESTART_CPU"],
    ["wdconfig-action-restart-gpu", "ACTION_RESTART_GPU"],
    ["wdconfig-action-reboot-rig", "ACTION_REBOOT_RIG"],
    ["wdconfig-action-email-notify", "ACTION_EMAIL_NOTIFY"],
    ["wdconfig-action-sms-notify", "ACTION_SMS_NOTIFY"],
    ["wdconfig-action-restart-fan", "ACTION_RESTART_FAN"],
    ["wdconfig-action-restart-aux", "ACTION_RESTART_AUX"],
    ["wdconfig-action-custom-script", "ACTION_CUSTOM_SCRIPT"],
];
let pendingWdConfigFetchRig = null;
let pendingAgentConfFetchRig = null;
// Which *.conf the Settings modal's Conf tab dropdown currently has selected - see CONF_EDIT_TYPES
// below for the full list. Defaults to agent.conf, matching this tab's original single-purpose behavior.
let selectedConfEditType = "agent.conf";
// Real-world example starting point for a rig that doesn't have a rigcontrol-agent.conf yet -
// loaded by the "Clear" button on the Conf tab (only offered when agent.conf is selected - the
// other conf types don't have an equivalent bundled blank example). Mirrors an actual production conf, with
// BROKER_PASS left blank (never ship a real password in a template) and broker host/miner slots
// as illustrative examples to edit before sending.
const AGENT_CONF_DEFAULT_TEMPLATE =
    "BROKER_HOST=10.10.0.10\n" +
    "BROKER_PORT=1883\n" +
    "BROKER_USER=admin\n" +
    "BROKER_PASS=\n" +
    "# comma separated list of gpu stats safe images\n" +
    "OVERRIDE_LIST=\"miner/miner:latest\"\n" +
    "STATS_DB_ENABLED=true\n" +
    "# How many days of local telemetry history to keep before old rows are pruned\n" +
    "STATS_DB_MAX_HISTORY_DAYS=7\n" +
    "STATS_DB_INTERVAL_SECONDS=90\n" +
    "# Minimum seconds between telemetry pulls, prevents overlapping collection calls\n" +
    "MIN_TELEMETRY_PULL_INTERVAL_SECONDS=5\n" +
    "#CPU_SERVICE_NAME=docker_events_cpu.service\n" +
    "#GPU_SERVICE_NAME=docker_events_gpu.service\n" +
    "#AUX_SERVICE_NAME=keryxd.service\n" +
    "#WATCHDOG_SERVICE_NAME=rigcontrol_watchdog.service\n" +
    "#CUSTOM_MINER_BIN_GPU=/opt/miners/my-custom-miner/current/my-custom-miner\n" +
    "#CUSTOM_MINER_BIN_CPU=/opt/miners/my-custom-miner/current/my-custom-miner\n" +
    "#CUSTOM_MINER_BIN_AUX=/opt/miners/my-custom-miner/current/my-custom-miner\n" +
    "# Per-custom-miner overrides, keyed by the miner's own name (from CUSTOM_MINER\n" +
    "# in rig-gpu/cpu/aux.conf or .json, sanitized to A-Z0-9_) - <NAME>_BIN for the\n" +
    "# binary, <NAME>_API_HOST/<NAME>_API_PORT for a keryx-style JSON stats API,\n" +
    "# or <NAME>_LOG_PATH for log scraping (<NAME>_LOG_STYLE=blocks for\n" +
    "# keryxd-style \"Accepted N blocks\" counting instead of generic hashrate scraping)\n" +
    "#KERYX_MINER_BIN=/opt/miners/keryx-miner/current/keryx-miner\n" +
    "KERYX_MINER_API_HOST=127.0.0.1\n" +
    "KERYX_MINER_API_PORT=3338\n" +
    "#KERYX_MINER_SUPR_BIN=/opt/miners/custom/keryx-miner-supr/current/keryx-miner-supr\n" +
    "KERYX_MINER_SUPR_API_HOST=127.0.0.1\n" +
    "KERYX_MINER_SUPR_API_PORT=3338\n" +
    "#KERYXD_BIN=/opt/miners/keryx-node/keryxd\n" +
    "#KERYXD_LOG_PATH=/run/rigcontrol/aux_miner.log\n" +
    "#KERYXD_LOG_STYLE=blocks\n";
let pendingLogsFetchRig = null;
let lastSyncedLogsRig = null;
let logsAutoRefreshTimer = null;
let logsRawText = "";
const LOGS_TYPE_LABELS = {
    "cpu.log": "CPU log",
    "gpu.log": "GPU log",
    "aux.log": "AUX log",
    "cpu.svclog": "CPU service log",
    "gpu.svclog": "GPU service log",
    "aux.svclog": "AUX service log",
    "cpu.api": "CPU API call",
    "gpu.api": "GPU API call",
    "aux.api": "AUX API call",
    "cpu.conf": "CPU rig conf",
    "gpu.conf": "GPU rig conf",
    "aux.conf": "AUX rig conf",
    "agent.conf": "Agent conf",
    "agent.svclog": "Agent log",
    "watchdog.conf": "Watchdog conf",
    "watchdog.svclog": "Watchdog log",
    "fancurve.conf": "Fan curve conf",
    "fancurve.svclog": "Fan curve log",
    "sys.nvidiasmi": "nvidia-smi",
    "sys.rocmsmi": "rocm-smi",
    "sys.df": "Disk usage (df -h)",
    "sys.top": "Processes (ps, by CPU)",
};
const LOGS_TYPES_WITHOUT_LINES = new Set(["cpu.api", "gpu.api", "aux.api", "cpu.conf", "gpu.conf", "aux.conf", "agent.conf", "watchdog.conf", "fancurve.conf", "sys.nvidiasmi", "sys.rocmsmi", "sys.df"]);
const LOGS_TYPES_PRESERVE_SCROLL = new Set(["sys.top"]);
const LOGS_COMMAND_BUILDERS = {
    "cpu.log": (n) => `tail -n ${n} /run/rigcontrol/cpu_miner.log`,
    "gpu.log": (n) => `tail -n ${n} /run/rigcontrol/gpu_miner.log`,
    "aux.log": (n) => `tail -n ${n} /run/rigcontrol/aux_miner.log`,
    "cpu.svclog": (n) => `journalctl -u "$CPU_SERVICE_NAME" -n ${n} --no-pager`,
    "gpu.svclog": (n) => `journalctl -u "$GPU_SERVICE_NAME" -n ${n} --no-pager`,
    "aux.svclog": (n) => `journalctl -u "$AUX_SERVICE_NAME" -n ${n} --no-pager`,
    "cpu.api": () => "cpu.api",
    "gpu.api": () => "gpu.api",
    "aux.api": () => "aux.api",
    "cpu.conf": () => "cat /etc/rigcontrol/rig-cpu.json",
    "gpu.conf": () => "cat /etc/rigcontrol/rig-gpu.json",
    "aux.conf": () => "cat /etc/rigcontrol/rig-aux.json",
    "agent.conf": () => "cat /etc/rigcontrol/rigcontrol-agent.conf",
    "agent.svclog": (n) => `journalctl -u rigcontrol-agent.service -n ${n} --no-pager`,
    "watchdog.conf": () => "cat /etc/rigcontrol/rigcontrol-watchdog.conf",
    "watchdog.svclog": (n) => `journalctl -u "$WATCHDOG_SERVICE_NAME" -n ${n} --no-pager`,
    "fancurve.conf": () => "cat /etc/systemd/system/fan-curve.service",
    "fancurve.svclog": (n) => `journalctl -u fan-curve.service -n ${n} --no-pager`,
    "sys.nvidiasmi": () => "nvidia-smi",
    "sys.rocmsmi": () => "rocm-smi",
    "sys.df": () => "df -h",
    "sys.top": (n) => `ps -eo pid,user,pri,ni,vsz,rss,stat,pcpu,pmem,time,args --sort=-pcpu | head -n ${n}`,
};
// Backs the Settings modal's Conf tab (formerly "Agent Conf" - now a dropdown-selectable editor
// for any of the *.conf files below, not just rigcontrol-agent.conf). Read uses the matching
// LOGS_COMMAND_BUILDERS[type]() cat command above (same file, same command, kept in one place);
// this table only adds what reading alone doesn't need: where to write it back to, and what to
// restart afterward so the change actually takes effect.
const CONF_EDIT_TYPES = {
    "agent.conf": {
        dir: () => TEMPLATES_CONFIG.agentconf.conf_dir,
        path: () => TEMPLATES_CONFIG.agentconf.conf_path,
        restartCmd: () => TEMPLATES_CONFIG.agentconf.restart_command,
        isAgent: true,
    },
    "cpu.conf": {
        dir: () => "/etc/rigcontrol",
        path: () => "/etc/rigcontrol/rig-cpu.json",
        restartCmd: () => "sudo systemctl restart docker_events_cpu",
    },
    "gpu.conf": {
        dir: () => "/etc/rigcontrol",
        path: () => "/etc/rigcontrol/rig-gpu.json",
        restartCmd: () => "sudo systemctl restart docker_events_gpu",
    },
    "aux.conf": {
        dir: () => "/etc/rigcontrol",
        path: () => "/etc/rigcontrol/rig-aux.json",
        restartCmd: () => "sudo systemctl restart docker_events_aux",
    },
    "watchdog.conf": {
        dir: () => TEMPLATES_CONFIG.watchdog.conf_dir,
        path: () => TEMPLATES_CONFIG.watchdog.conf_path,
        // The dedicated Watchdog Config modal restarts via the "watchdog.restart" pseudo-command
        // (rigcontrol_cmd.sh's own case statement, matched on the whole command being exactly that
        // literal string) - that only works standalone, not as a second line tacked onto a raw shell
        // blob, so this uses the equivalent literal systemctl call instead (same default service
        // name rigcontrol_cmd.sh itself falls back to: WATCHDOG_SERVICE_NAME unset -> rigcontrol_watchdog.service).
        restartCmd: () => "sudo systemctl restart rigcontrol_watchdog.service",
    },
    "fancurve.conf": {
        // fan-curve.service is a systemd UNIT file, not a /etc/rigcontrol app conf - editing it here
        // is a deliberate escape hatch for a one-off manual tweak; the normal way to manage it is
        // still install_fan-curve.sh once, then Overclock's per-algo curve value (see templates.json's
        // apply_script_footer, which only touches the --curve line, not the rest of the unit).
        dir: () => "/etc/systemd/system",
        path: () => "/etc/systemd/system/fan-curve.service",
        restartCmd: () => "sudo systemctl daemon-reload\nsudo systemctl restart fan-curve.service",
    },
};
const DEFAULT_QUICK_ACTIONS = { a: "", b: "", c: "" };
let quickActionsConfig = { ...DEFAULT_QUICK_ACTIONS };
const DataHelper = {
    getCpuTemp: (data) => {
        return data.cpu_temp !== null ? Number(data.cpu_temp) : null;
    },
    getCpuUsage: (data) => {
        return data.cpu_usage !== undefined ? data.cpu_usage : "--";
    },
    getLoad: (data, interval = "1m") => {
        return data.load?.[interval] ?? "--";
    },
    getMemory: (data) => {
        if (data.memory?.total_mb && data.memory.used_mb !== undefined) {
            return {
                used_gb: (data.memory.used_mb / 1024).toFixed(1),
                total_gb: (data.memory.total_mb / 1024).toFixed(1),
                string: `${(data.memory.used_mb / 1024).toFixed(1)} / ${(data.memory.total_mb / 1024).toFixed(1)}`,
                percent: data.memory.percent || 0
            };
        }
        return { used_gb: "--", total_gb: "--", string: "--", percent: 0 };
    },
    getSystemUptime: (data) => {
        return data.system_uptime_seconds || 0;
    },
    getFormattedSystemUptime: (seconds) => {
        if (!seconds || seconds < 60) {
            return {
                value: "0m",
                class: "uptime-unknown",
                seconds: seconds || 0
            };
        }
        const days = Math.floor(seconds / 86400);
        const hours = Math.floor((seconds % 86400) / 3600);
        const minutes = Math.floor((seconds % 3600) / 60);
        let value;
        if (days > 0) {
            if (hours > 0) {
                value = `${days}d ${hours}h`;
            } else {
                value = `${days}d`;
            }
        } else if (hours > 0) {
            if (minutes > 0) {
                value = `${hours}h ${minutes}m`;
            } else {
                value = `${hours}h`;
            }
        } else {
            value = `${minutes}m`;
        }
        let className = "uptime-unknown";
        if (seconds > 0) {
            const hoursValue = seconds / 3600;
            const daysValue = seconds / 86400;
            if (hoursValue < 4) className = "uptime-fresh";
            else if (hoursValue < 24) className = "uptime-good";
            else if (daysValue < 7) className = "uptime-stable";
            else if (daysValue < 30) className = "uptime-long";
            else className = "uptime-legacy";
        }
        return {
            value,
            class: className,
            seconds: seconds
        };
    },
    getGpus: (data) => {
        return Array.isArray(data.gpus) ? data.gpus : [];
    },
    getGpuCount: (data) => {
        return typeof data.gpu_count === "number" ? data.gpu_count : DataHelper.getGpus(data).length;
    },
    getAllGpus: (data) => {
        const systemGpus = DataHelper.getGpus(data);
        const minerGpus = [];
        DataHelper.getActiveMiners(data).forEach(miner => {
            if (miner.data.gpus && Array.isArray(miner.data.gpus)) {
                miner.data.gpus.forEach(gpu => {
                    minerGpus.push({
                        ...gpu,
                        source: miner.name,
                        minerKey: miner.key
                    });
                });
            }
        });
        return [...systemGpus, ...minerGpus];
    },
    getGpuHashrateMap: (data) => {
        const map = {};
        DataHelper.getActiveMiners(data).forEach(miner => {
            const minerGpus = miner.data && miner.data.gpus;
            if (Array.isArray(minerGpus)) {
                minerGpus.forEach((gpu, i) => {
                    const idx = gpu.index ?? gpu.id ?? gpu.gpu_id ?? i;
                    const hr = gpu.hashrate_hs;
                    if (typeof hr === "number" && hr > 0) {
                        map[idx] = (map[idx] || 0) + hr;
                    }
                });
            }
        });
        return map;
    },
    getGpuPowerMap: (data) => {
        const map = {};
        DataHelper.getActiveMiners(data).forEach(miner => {
            const minerGpus = miner.data && miner.data.gpus;
            if (Array.isArray(minerGpus)) {
                minerGpus.forEach((gpu, i) => {
                    const idx = gpu.index ?? gpu.id ?? gpu.gpu_id ?? i;
                    const p = DataHelper.getGpuPowerNumber(gpu);
                    if (p > 0) {
                        map[idx] = (map[idx] || 0) + p;
                    }
                });
            }
        });
        return map;
    },
    getGpuAcceptedSharesMap: (data) => {
        const map = {};
        DataHelper.getActiveMiners(data).forEach(miner => {
            const minerGpus = miner.data && miner.data.gpus;
            if (Array.isArray(minerGpus)) {
                minerGpus.forEach((gpu, i) => {
                    const idx = gpu.index ?? gpu.id ?? gpu.gpu_id ?? i;
                    const shares = gpu.accepted_shares;
                    if (typeof shares === "number") {
                        map[idx] = (map[idx] || 0) + shares;
                    }
                });
            }
        });
        return map;
    },
    getGpuRejectedSharesMap: (data) => {
        const map = {};
        DataHelper.getActiveMiners(data).forEach(miner => {
            const minerGpus = miner.data && miner.data.gpus;
            if (Array.isArray(minerGpus)) {
                minerGpus.forEach((gpu, i) => {
                    const idx = gpu.index ?? gpu.id ?? gpu.gpu_id ?? i;
                    const shares = gpu.rejected_shares;
                    if (typeof shares === "number") {
                        map[idx] = (map[idx] || 0) + shares;
                    }
                });
            }
        });
        return map;
    },
    getPrimaryGpu: (data) => {
        const gpus = DataHelper.getAllGpus(data);
        return gpus[0] || {};
    },
    getGpuTemp: (gpu) => {
        return gpu.temp !== undefined ? Number(gpu.temp) : gpu.temperature || null;
    },
    getGpuMemTemp: (gpu) => {
        if (gpu.mem_temp !== undefined && gpu.mem_temp !== null) return Number(gpu.mem_temp);
        return gpu.memory_temperature ?? null;
    },
    getGpuUtil: (gpu) => {
        return gpu.util ?? gpu.utilization ?? "--";
    },
    getGpuMemUtil: (gpu) => {
        return gpu.mem_util ?? gpu.memory_utilization ?? "--";
    },
    getGpuFan: (gpu) => {
        return gpu.fan_percent ?? gpu.fan_speed ?? "--";
    },
    getGpuCoreClock: (gpu) => {
        return gpu.sm_clock ?? gpu.core_clock ?? "--";
    },
    getGpuMemClock: (gpu) => {
        return gpu.mem_clock ?? gpu.memory_clock ?? "--";
    },
    getGpuVram: (gpu) => {
        if (gpu.vram_used !== undefined && gpu.vram_total !== undefined) {
            return {
                used_gb: (gpu.vram_used / 1024).toFixed(1),
                total_gb: (gpu.vram_total / 1024).toFixed(1),
                percent: (gpu.vram_used / gpu.vram_total * 100).toFixed(1),
                string: `${(gpu.vram_used / 1024).toFixed(1)} / ${(gpu.vram_total / 1024).toFixed(1)}`
            };
        }
        return { used_gb: "--", total_gb: "--", percent: 0, string: "--" };
    },
    getGpuDriverVersion: (gpu) => {
        return gpu.driver_version || "--";
    },
    getNvidiaDriverVersion: (data) => {
        const gpus = DataHelper.getAllGpus(data);
        if (gpus.length > 0 && gpus[0].driver_version) {
            return gpus[0].driver_version;
        }
        return "--";
    },
    getGpuInfoTooltip: (gpus) => {
        if (!gpus || gpus.length === 0) return "";
        const fmtWatts = (v) => (typeof v === "number" ? `${v.toFixed(0)}W` : "--");
        const lines = gpus.map((gpu, i) => {
            const label = gpus.length > 1 ? `GPU ${gpu.index ?? i}: ` : "";
            const name = DataHelper.getGpuName(gpu) || "Unknown GPU";
            const arch = gpu.architecture || "Unknown";
            const vbios = gpu.vbios_version || "--";
            const pmin = gpu.power_limit_min;
            const pdef = gpu.power_limit_default;
            const pmax = gpu.power_limit_max;
            const pwrStr = (pmin != null || pdef != null || pmax != null)
                ? `${fmtWatts(pmin)} - ${fmtWatts(pmax)} (default ${fmtWatts(pdef)})`
                : "--";
            return `${label}${name} (${arch})\n  VBIOS: ${vbios}\n  Power Limit: ${pwrStr}`;
        });
        return lines.join("\n\n");
    },
    getGpuName: (gpu) => {
        return gpu.name || "Unknown GPU";
    },
    getGpuVendor: (gpu) => {
        return gpu.board_partner || gpu.vendor || "--";
    },
    getGpuPower: (gpu) => {
        const power =
            gpu.power_watts !== undefined ? gpu.power_watts :
            gpu.power_usage !== undefined ? gpu.power_usage :
            gpu.power !== undefined ? gpu.power :
            gpu.Power !== undefined ? gpu.Power :
            (gpu.power_consumption && gpu.power_consumption.watt !== undefined) ? gpu.power_consumption.watt :
            null;
        if (power !== null && typeof power === 'number' && !isNaN(power)) {
            return power.toFixed(1);
        }
        return "--";
    },
    getGpuPowerNumber: (gpu) => {
        const power =
            gpu.power_watts !== undefined ? gpu.power_watts :
            gpu.power_usage !== undefined ? gpu.power_usage :
            gpu.power !== undefined ? gpu.power :
            gpu.Power !== undefined ? gpu.Power :
            (gpu.power_consumption && gpu.power_consumption.watt !== undefined) ? gpu.power_consumption.watt :
            0;
        return typeof power === 'number' && !isNaN(power) ? power : 0;
    },
    getTotalGpuPower: (data) => {
        const systemGpus = DataHelper.getGpus(data);
        const minerPowerMap = DataHelper.getGpuPowerMap(data);
        const usedIndices = new Set();
        let total = 0;
        systemGpus.forEach((gpu, i) => {
            const idx = gpu.index ?? i;
            usedIndices.add(idx);
            const sysPower = DataHelper.getGpuPowerNumber(gpu);
            total += sysPower > 0 ? sysPower : (minerPowerMap[idx] || 0);
        });
        Object.keys(minerPowerMap).forEach(idxKey => {
            const idx = Number.isNaN(Number(idxKey)) ? idxKey : Number(idxKey);
            if (!usedIndices.has(idx)) {
                total += minerPowerMap[idx];
            }
        });
        return total;
    },
    getGpuAggregate: (data) => {
        const gpus = DataHelper.getGpus(data);
        const totalPower = DataHelper.getTotalGpuPower(data);
        if (gpus.length === 0) {
            return {
                count: 0, temp: null, memTemp: null, util: "--", power: totalPower, fan: "--",
                coreClock: "--", memClock: "--",
                vram: { used_gb: "--", total_gb: "--", percent: 0, string: "--" }
            };
        }
        const numOrNull = (v) => {
            if (v === null || v === undefined) return null;
            const n = Number(v);
            return Number.isFinite(n) ? n : null;
        };
        const maxOf = (values) => {
            const nums = values.map(numOrNull).filter(v => v !== null);
            return nums.length ? Math.max(...nums) : null;
        };
        const temp = maxOf(gpus.map(gpu => DataHelper.getGpuTemp(gpu)));
        const memTemp = maxOf(gpus.map(gpu => DataHelper.getGpuMemTemp(gpu)));
        const util = maxOf(gpus.map(gpu => DataHelper.getGpuUtil(gpu)));
        const fan = maxOf(gpus.map(gpu => DataHelper.getGpuFan(gpu)));
        const coreClock = maxOf(gpus.map(gpu => DataHelper.getGpuCoreClock(gpu)));
        const memClock = maxOf(gpus.map(gpu => DataHelper.getGpuMemClock(gpu)));
        let vram = DataHelper.getGpuVram(gpus[0]);
        let bestUsed = numOrNull(vram.used_gb);
        for (let i = 1; i < gpus.length; i++) {
            const v = DataHelper.getGpuVram(gpus[i]);
            const used = numOrNull(v.used_gb);
            if (used !== null && (bestUsed === null || used > bestUsed)) {
                vram = v;
                bestUsed = used;
            }
        }
        return {
            count: gpus.length,
            temp,
            memTemp,
            util: util !== null ? util : "--",
            power: totalPower,
            fan: fan !== null ? fan : "--",
            coreClock: coreClock !== null ? coreClock : "--",
            memClock: memClock !== null ? memClock : "--",
            vram
        };
    },
    getServiceStatus: (data, service) => {
        const serviceData = data[service];
        return {
            state: serviceData?.state || "unknown",
            isActive: serviceData?.state === "active",
            uptime: serviceData?.uptime || 0,
            name: serviceData?.service || ""
        };
    },
    getDockerContainers: (data) => {
        return Array.isArray(data.docker) ? data.docker : [];
    },
    MINER_NAMES: {
        "miner_bzminer": "BzMiner",
        "miner_xmrig": "XMRig",
        "miner_rigel": "Rigel",
        "miner_lolminer": "lolMiner",
        "miner_srbminer": "SRBMiner",
        "miner_wildrig": "WildRig",
        "miner_onezerominer": "OneZeroMiner",
        "miner_gminer": "GMiner",
        "miner_teamredminer": "TeamRedMiner",
        "miner_trex": "T-Rex",
        // "miner_keryx" deliberately NOT in this table (unlike every other entry here) - the
        // "keryx" collector key covers TWO distinct binaries (plain keryx-miner and
        // keryx-miner-supr) that can each be running under it depending on the rig/time, so there's
        // no single correct static label the way there is for e.g. xmrig. Falling through to the
        // live minerData.miner value below (which both the Linux and Windows agents resolve to
        // whichever binary is actually running) is what shows the correct one instead of always
        // showing a generic "Keryx" regardless of which variant is live.
		"miner_peakminer": "PeakMiner"
    },
    getMinerDisplayName: (minerKey, minerData) => {
        if (DataHelper.MINER_NAMES[minerKey]) {
            return DataHelper.MINER_NAMES[minerKey];
        }
        if (minerData && typeof minerData.miner === "string" && minerData.miner.trim()) {
            return minerData.miner;
        }
        return minerKey.replace('miner_', '');
    },
    getMiner: (data, minerKey) => {
        return data[minerKey] || null;
    },
    isMinerActive: (data, minerKey) => {
        const miner = DataHelper.getMiner(data, minerKey);
        return miner && miner.status === "ok" && miner.algorithms && miner.algorithms.length > 0;
    },
    getActiveMiners: (data) => {
        if (!data || typeof data !== "object") return [];
        return Object.keys(data)
            .filter(key => key.startsWith("miner_") && DataHelper.isMinerActive(data, key))
            .map(key => {
                const minerData = DataHelper.getMiner(data, key);
                return {
                    key: key,
                    name: DataHelper.getMinerDisplayName(key, minerData),
                    data: minerData
                };
            });
    },
    getMinerAlgorithms: (data, minerKey) => {
        const miner = DataHelper.getMiner(data, minerKey);
        if (!miner || miner.status !== "ok") return [];
        return miner.algorithms || [];
    },
    getAllAlgorithms: (data) => {
        const algorithms = [];
        const activeMiners = DataHelper.getActiveMiners(data);
        activeMiners.forEach(miner => {
            if (miner.data.algorithms) {
                miner.data.algorithms.forEach(algo => {
                    algorithms.push({
                        ...algo,
                        minerKey: miner.key,
                        minerName: miner.name,
                        minerUptime: miner.data.uptime_s,
                        minerVersion: miner.data.miner_version,
                        cudaDriver: miner.data.cuda_driver || miner.data.cuda_driver_version,
                        rigName: miner.data.rig_name || miner.data.worker_id || data.rig,
                        gpuCount: miner.data.gpus ? miner.data.gpus.length : 0
                    });
                });
            }
        });
        return algorithms;
    },
    getAlgorithmName: (algo) => {
        return algo.algorithm || "--";
    },
    getHashrateHS: (algo) => {
        return algo.hashrate_hs || 0;
    },
    getCpuHashrateHS: (algo) => {
        return algo.cpu_hashrate_hs || 0;
    },
    getGpuHashrateHS: (algo) => {
        return algo.gpu_hashrate_hs || 0;
    },
    getTotalHashrateHS: (algo) => {
        const baseHashrate = DataHelper.getHashrateHS(algo);
        if (baseHashrate > 0) return baseHashrate;
        const cpuHashrate = DataHelper.getCpuHashrateHS(algo);
        const gpuHashrate = DataHelper.getGpuHashrateHS(algo);
        return cpuHashrate + gpuHashrate;
    },
    getAcceptedShares: (algo) => {
        return algo.accepted_shares || 0;
    },
    getRejectedShares: (algo) => {
        return algo.rejected_shares || 0;
    },
    getInvalidShares: (algo) => {
        return algo.invalid_shares || algo.error_shares || 0;
    },
    getStaleShares: (algo) => {
        return algo.stale_shares || 0;
    },
    getHardwareErrors: (algo) => {
        return algo.hardware_errors || 0;
    },
    getUtility: (algo) => {
        return algo.utility || null;
    },
    getPool: (algo) => {
        return algo.pool || "";
    },
    getPoolUrl: (algo) => {
        return algo.pool_url || algo.server || "";
    },
    getPoolStatus: (algo) => {
        return algo.pool_status || "unknown";
    },
    getPoolLatency: (algo) => {
        return algo.pool_latency_ms || null;
    },
    getWorkers: (algo) => {
        return algo.workers;
    },
    getCpuWorkers: (algo) => {
        return algo.cpu_workers;
    },
    getGpuWorkers: (algo) => {
        return algo.gpu_workers;
    },
    getPoolHashrateHS: (algo) => {
        return algo.pool_hashrate_hs || 0;
    },
    getCpuThreads: (algo) => {
        return algo.cpu_threads || 0;
    },
    getThreadHashrates: (algo) => {
        return algo.thread_hashrates || {};
    },
    getDifficulty: (algo) => {
        return algo.difficulty || 0;
    },
    getMiningType: (algo) => {
        return algo.mining_type || (algo.cpu_hashrate_hs > 0 ? "CPU" : "GPU");
    },
    getMinerVersion: (minerData) => {
        return minerData?.miner_version || "--";
    },
    getMinerVersionByKey: (data, minerKey) => {
        const miner = DataHelper.getMiner(data, minerKey);
        return DataHelper.getMinerVersion(miner);
    },
    getCudaDriverVersion: (minerData) => {
        return minerData?.cuda_driver_version || minerData?.cuda_driver || "--";
    },
    getMinerRigName: (minerData) => {
        return minerData?.rig_name || "--";
    },
    getMinerTotalDevices: (minerData) => {
        return minerData?.total_devices || 0;
    },
    getMinerUptime: (minerData) => {
        return minerData?.uptime_s || 0;
    },
    getTotalHashrateAllMiners: (data) => {
        return DataHelper.getAllAlgorithms(data).reduce((total, algo) => {
            return total + DataHelper.getTotalHashrateHS(algo);
        }, 0);
    },
    getHashrateByAlgorithm: (data) => {
        const algoMap = {};
        DataHelper.getAllAlgorithms(data).forEach(algo => {
            const algoName = DataHelper.getAlgorithmName(algo);
            const hashrate = DataHelper.getTotalHashrateHS(algo);
            if (!algoMap[algoName]) {
                algoMap[algoName] = {
                    totalHashrate: 0,
                    miners: [],
                    pools: new Set(),
                    perThreadData: [],
                    totalAccepted: 0,
                    totalRejected: 0
                };
            }
            algoMap[algoName].totalHashrate += hashrate;
            algoMap[algoName].totalAccepted += DataHelper.getAcceptedShares(algo);
            algoMap[algoName].totalRejected += DataHelper.getRejectedShares(algo);
            if (algo.pool) {
                algoMap[algoName].pools.add(algo.pool);
            }
            const minerName = algo.minerName;
            const minerVersion = algo.minerVersion || "--";
            const poolName = algo.pool || "Unknown Pool";
            if (algo.minerKey === "miner_srbminer") {
                const cpuHashrate = DataHelper.getCpuHashrateHS(algo);
                const gpuHashrate = DataHelper.getGpuHashrateHS(algo);
                if (cpuHashrate > 0) {
                    algoMap[algoName].miners.push(`CPU ${fmtRateHs(cpuHashrate, "")} ${minerName} v${minerVersion} (${poolName})`);
                    const threadHashrates = DataHelper.getThreadHashrates(algo);
                    Object.entries(threadHashrates).forEach(([threadName, threadRate]) => {
                        algoMap[algoName].perThreadData.push({
                            thread: threadName,
                            hashrate: threadRate,
                            type: "CPU",
                            miner: minerName,
                            pool: poolName
                        });
                    });
                }
                if (gpuHashrate > 0) {
                    algoMap[algoName].miners.push(`GPU ${fmtRateHs(gpuHashrate, "")} ${minerName} v${minerVersion} (${poolName})`);
                }
            } else {
                const displayText = `${fmtRateHs(hashrate, "")} ${minerName} v${minerVersion} (${poolName})`;
                algoMap[algoName].miners.push(displayText);
                const threadHashrates = DataHelper.getThreadHashrates(algo);
                Object.entries(threadHashrates).forEach(([threadName, threadRate]) => {
                    algoMap[algoName].perThreadData.push({
                        thread: threadName,
                        hashrate: threadRate,
                        type: algo.minerKey === "miner_xmrig" ? "CPU" : "GPU",
                        miner: minerName,
                        pool: poolName
                    });
                });
            }
        });
        Object.keys(algoMap).forEach(algoName => {
            algoMap[algoName].pools = Array.from(algoMap[algoName].pools);
        });
        return algoMap;
    },
    getMinerSummary: (data) => {
        const summary = [];
        DataHelper.getActiveMiners(data).forEach(miner => {
            const minerData = miner.data;
            const algorithms = DataHelper.getMinerAlgorithms(data, miner.key);
            algorithms.forEach(algo => {
                const totalHashrate = DataHelper.getTotalHashrateHS(algo);
                const pool = DataHelper.getPool(algo);
                const accepted = DataHelper.getAcceptedShares(algo) || 0;
                const rejected = DataHelper.getRejectedShares(algo) || 0;
                const invalid = DataHelper.getInvalidShares(algo) || 0;
                const stale = DataHelper.getStaleShares(algo) || 0;
                const difficulty = DataHelper.getDifficulty(algo) || 0;
                const miningType = DataHelper.getMiningType(algo);
                summary.push({
                    miner: miner.name,
                    version: DataHelper.getMinerVersion(minerData),
                    algorithm: DataHelper.getAlgorithmName(algo),
                    hashrate: totalHashrate,
                    formattedHashrate: fmtRateHs(totalHashrate, ""),
                    pool: pool,
                    accepted: accepted,
                    rejected: rejected,
                    invalid: invalid,
                    stale: stale,
                    totalShares: accepted + rejected + invalid + stale,
                    uptime: minerData.uptime_s || 0,
                    threadCount: DataHelper.getCpuThreads(algo) || Object.keys(DataHelper.getThreadHashrates(algo)).length,
                    cudaDriver: DataHelper.getCudaDriverVersion(minerData),
                    rigName: minerData.rig_name || data.rig,
                    miningType: miningType,
                    difficulty: difficulty,
                    poolStatus: DataHelper.getPoolStatus(algo),
                    poolLatency: DataHelper.getPoolLatency(algo)
                });
            });
        });
        return summary;
    },
    getMiningStats: (data) => {
        const algorithms = DataHelper.getAllAlgorithms(data);
        const stats = {
            totalHashrate: 0,
            totalAccepted: 0,
            totalRejected: 0,
            totalInvalid: 0,
            totalStale: 0,
            activeMiners: 0,
            activeAlgorithms: new Set(),
            activePools: new Set(),
            totalPower: 0,
            minerCounts: {}
        };
        algorithms.forEach(algo => {
            stats.totalHashrate += DataHelper.getTotalHashrateHS(algo);
            stats.totalAccepted += DataHelper.getAcceptedShares(algo);
            stats.totalRejected += DataHelper.getRejectedShares(algo);
            stats.totalInvalid += DataHelper.getInvalidShares(algo);
            stats.totalStale += DataHelper.getStaleShares(algo);
            stats.activeAlgorithms.add(DataHelper.getAlgorithmName(algo));
            if (algo.pool) stats.activePools.add(algo.pool);
            const minerName = algo.minerName;
            stats.minerCounts[minerName] = (stats.minerCounts[mininerName] || 0) + 1;
        });
        stats.activeMiners = DataHelper.getActiveMiners(data).length;
        stats.activeAlgorithms = Array.from(stats.activeAlgorithms);
        stats.activePools = Array.from(stats.activePools);
        stats.totalPower = DataHelper.getTotalGpuPower(data);
        const totalShares = stats.totalAccepted + stats.totalRejected + stats.totalInvalid;
        stats.rejectionRate = totalShares > 0 ? ((stats.totalRejected + stats.totalInvalid) / totalShares) * 100 : 0;
        return stats;
    },
    getCpuThreadAnalysis: (data) => {
        const analysis = [];
        const algorithms = DataHelper.getAllAlgorithms(data);
        algorithms.forEach(algo => {
            const threadHashrates = DataHelper.getThreadHashrates(algo);
            if (Object.keys(threadHashrates).length > 0) {
                Object.entries(threadHashrates).forEach(([threadName, threadRate]) => {
                    analysis.push({
                        algorithm: DataHelper.getAlgorithmName(algo),
                        miner: algo.minerName,
                        thread: threadName,
                        hashrate: threadRate,
                        formatted: fmtRateHs(threadRate, ""),
                        pool: algo.pool || "",
                        miningType: DataHelper.getMiningType(algo)
                    });
                });
            } else if (DataHelper.getCpuThreads(algo) > 0) {
                analysis.push({
                    algorithm: DataHelper.getAlgorithmName(algo),
                    miner: algo.minerName,
                    thread: `${DataHelper.getCpuThreads(algo)} threads`,
                    hashrate: DataHelper.getTotalHashrateHS(algo),
                    formatted: fmtRateHs(DataHelper.getTotalHashrateHS(algo), ""),
                    pool: algo.pool || "",
                    miningType: DataHelper.getMiningType(algo)
                });
            }
        });
        return analysis;
    },
    getThreadStatistics: (data) => {
        const threadData = DataHelper.getCpuThreadAnalysis(data);
        if (threadData.length === 0) return null;
        const rates = threadData.map(t => t.hashrate);
        const total = rates.reduce((sum, rate) => sum + rate, 0);
        const avg = total / rates.length;
        return {
            totalThreads: threadData.length,
            totalHashrate: total,
            avgPerThread: avg,
            minPerThread: Math.min(...rates),
            maxPerThread: Math.max(...rates),
            algorithms: [...new Set(threadData.map(t => t.algorithm))]
        };
    },
    getFormattedTemp: (temp, type = "cpu") => {
        if (temp === null || temp === undefined) return { value: "--", class: "status-good" };
        const value = temp.toFixed(0);
        let className = "status-good";
        if (type === "cpu" || type === "gpu") {
            if (temp >= 75) className = "status-hot";
            else if (temp >= 60) className = "status-warm";
        } else if (type === "gpu_mem") {
            if (temp >= 105) className = "status-hot";
            else if (temp >= 95) className = "status-warm";
        }
        return { value, class: className };
    },
    getFormattedFan: (fanPercent) => {
        if (fanPercent === "--" || fanPercent === undefined) {
            return { value: "--", class: "status-good" };
        }
        let className = "status-good";
        if (fanPercent >= 80) className = "status-hot";
        else if (fanPercent >= 50) className = "status-warm";
        return { value: fanPercent, class: className };
    },
    getFormattedService: (serviceStatus, serviceType = "cpu") => {
        const label = serviceType.toUpperCase();
        return {
            text: label,
            class: serviceStatus.isActive ? "service-ok" : "service-bad",
            tooltip: serviceStatus.name
                ? `${label} service: ${serviceStatus.name} (${serviceStatus.state})`
                : `${label} service (${serviceStatus.state})`
        };
    },
    getFormattedVersion: (version) => {
        if (!version || version === "--") return "Unknown";
        const match = version.match(/(\d+\.\d+(\.\d+)*)/);
        if (match) {
            return `v${match[1]}`;
        }
        return version;
    },
    getFormattedDriver: (driverVersion) => {
        if (!driverVersion || driverVersion === "--") return "Unknown";
        const driverStr = String(driverVersion);
        let clean = driverStr.replace(/\.0$/, '');
        if (/^\d+\.\d+$/.test(clean)) {
            return `CUDA ${clean}`;
        }
        return clean;
    },
    getFormattedShares: (accepted, rejected, invalid = 0, stale = 0) => {
        const total = accepted + rejected + invalid + stale;
        if (total === 0) return { value: "0/0/0/0", class: "status-unknown" };
        const rejectionRate = (rejected + invalid) / total;
        let className = "shares-perfect";
        if (rejectionRate === 0) className = "shares-perfect";
        else if (rejectionRate < 0.01) className = "shares-good";
        else if (rejectionRate < 0.03) className = "shares-warning";
        else className = "shares-bad";
        return {
            value: `${fmtShareCount(accepted)}/${fmtShareCount(rejected)}/${fmtShareCount(invalid)}/${fmtShareCount(stale)}`,
            class: className,
            rejectionRate: (rejectionRate * 100).toFixed(2) + '%'
        };
    }
};
DataHelper.getCpuShares = (data) => {
    let accepted = 0;
    let rejected = 0;
    let invalid = 0;
    let stale = 0;
    const algorithms = DataHelper.getAllAlgorithms(data);
    algorithms.forEach(algo => {
        const isCpuTyped =
            (algo.minerKey === "miner_srbminer" || algo.minerKey === "miner_bzminer") &&
            algo.mining_type === "CPU";
        const isCpu =
            algo.minerKey === "miner_xmrig" ||
            isCpuTyped;
        if (isCpu) {
            accepted += DataHelper.getAcceptedShares(algo) || 0;
            rejected += DataHelper.getRejectedShares(algo) || 0;
            invalid += DataHelper.getInvalidShares(algo) || 0;
            stale += DataHelper.getStaleShares(algo) || 0;
        }
    });
    return {
        accepted: accepted,
        rejected: rejected,
        invalid: invalid,
        stale: stale,
        ratio: (rejected + invalid) > 0 ? ((rejected + invalid) / (accepted + rejected + invalid)).toFixed(4) : 0,
        string: `${accepted}/${rejected}/${invalid}/${stale}`
    };
};
DataHelper.getGpuShares = (data) => {
    let accepted = 0;
    let rejected = 0;
    let invalid = 0;
    let stale = 0;
    const algorithms = DataHelper.getAllAlgorithms(data);
    algorithms.forEach(algo => {
        if (algo.minerKey === "miner_xmrig") return;
        if (algo.minerKey === "miner_srbminer" && algo.mining_type !== "GPU") return;
        if (algo.minerKey === "miner_bzminer" && algo.mining_type !== "GPU") return;
        // Only the GPU slot (or legacy slot-less key) counts here.
        if (algo.minerKey.startsWith("miner_custom_log_") && algo.minerKey !== "miner_custom_log_gpu") return;
        accepted += DataHelper.getAcceptedShares(algo) || 0;
        rejected += DataHelper.getRejectedShares(algo) || 0;
        invalid += DataHelper.getInvalidShares(algo) || 0;
        stale += DataHelper.getStaleShares(algo) || 0;
    });
    return {
        accepted: accepted,
        rejected: rejected,
        invalid: invalid,
        stale: stale,
        ratio: (rejected + invalid) > 0 ? ((rejected + invalid) / (accepted + rejected + invalid)).toFixed(4) : 0,
        string: `${accepted}/${rejected}/${invalid}/${stale}`
    };
};
DataHelper.getAuxShares = (data) => {
    let accepted = 0;
    let rejected = 0;
    let invalid = 0;
    let stale = 0;
    const algorithms = DataHelper.getAllAlgorithms(data);
    algorithms.forEach(algo => {
        if (algo.minerKey !== "miner_custom_log_aux") return;
        accepted += DataHelper.getAcceptedShares(algo) || 0;
        rejected += DataHelper.getRejectedShares(algo) || 0;
        invalid += DataHelper.getInvalidShares(algo) || 0;
        stale += DataHelper.getStaleShares(algo) || 0;
    });
    return {
        accepted: accepted,
        rejected: rejected,
        invalid: invalid,
        stale: stale,
        ratio: (rejected + invalid) > 0 ? ((rejected + invalid) / (accepted + rejected + invalid)).toFixed(4) : 0,
        string: `${accepted}/${rejected}/${invalid}/${stale}`
    };
};
DataHelper.getSharesClass = (sharesData) => {
    if (!sharesData || (sharesData.accepted === 0 && sharesData.rejected === 0)) {
        return "status-unknown";
    }
    const rejectionRate = sharesData.rejected > 0 ?
        (sharesData.rejected / (sharesData.accepted + sharesData.rejected)) : 0;
    if (rejectionRate === 0) return "shares-perfect";
    if (rejectionRate < 0.01) return "shares-good";
    if (rejectionRate < 0.03) return "shares-warning";
    return "shares-bad";
};
DataHelper.getFormattedSharesDisplay = (sharesData, type = "cpu") => {
    if (!sharesData || (sharesData.accepted === 0 && sharesData.rejected === 0 && sharesData.invalid === 0)) {
        return {
            value: "0/0/0/0",
            class: "status-unknown",
            tooltip: `${type.toUpperCase()} Shares (Accepted/Rejected/Invalid/Stale)`
        };
    }
    const sharesClass = DataHelper.getSharesClass(sharesData);
    return {
        value: `${sharesData.accepted}/${sharesData.rejected}/${sharesData.invalid}/${sharesData.stale}`,
        class: sharesClass,
        tooltip: `${type.toUpperCase()} Shares (Accepted/Rejected/Invalid/Stale) - ${(sharesData.ratio * 100).toFixed(2)}% rejection`
    };
};
DataHelper.getCpuColumnContent = (data) => {
    const cpuShares = DataHelper.getCpuShares(data);
    if (cpuShares.accepted > 0 || cpuShares.rejected > 0) {
        const sharesClass = DataHelper.getSharesClass(cpuShares);
        return {
            html: `<span class="shares ${sharesClass}" title="CPU Shares: ${cpuShares.accepted} accepted, ${cpuShares.rejected} rejected">${fmtShareCount(cpuShares.accepted)}/${fmtShareCount(cpuShares.rejected)}</span>`,
            class: sharesClass
        };
    }
    const cpuService = DataHelper.getServiceStatus(data, "cpu_service");
    const formattedService = DataHelper.getFormattedService(cpuService, "cpu");
    return {
        html: `<span class="${formattedService.class}" title="${formattedService.tooltip}">CPU</span>`,
        class: formattedService.class
    };
};
DataHelper.getGpuColumnContent = (data) => {
    const gpuShares = DataHelper.getGpuShares(data);
    if (gpuShares.accepted > 0 || gpuShares.rejected > 0) {
        const sharesClass = DataHelper.getSharesClass(gpuShares);
        return {
            html: `<span class="shares ${sharesClass}" title="GPU Shares: ${gpuShares.accepted} accepted, ${gpuShares.rejected} rejected">${fmtShareCount(gpuShares.accepted)}/${fmtShareCount(gpuShares.rejected)}</span>`,
            class: sharesClass
        };
    }
    const gpuService = DataHelper.getServiceStatus(data, "gpu_service");
    const formattedService = DataHelper.getFormattedService(gpuService, "gpu");
    return {
        html: `<span class="${formattedService.class}" title="${formattedService.tooltip}">GPU</span>`,
        class: formattedService.class
    };
};
DataHelper.getAuxColumnContent = (data) => {
    const auxShares = DataHelper.getAuxShares(data);
    if (auxShares.accepted > 0 || auxShares.rejected > 0) {
        const sharesClass = DataHelper.getSharesClass(auxShares);
        return {
            html: `<span class="shares ${sharesClass}" title="AUX Shares: ${auxShares.accepted} accepted, ${auxShares.rejected} rejected">${fmtShareCount(auxShares.accepted)}/${fmtShareCount(auxShares.rejected)}</span>`,
            class: sharesClass
        };
    }
    const auxService = DataHelper.getServiceStatus(data, "aux_service");
    const formattedService = DataHelper.getFormattedService(auxService, "aux");
    return {
        html: `<span class="${formattedService.class}" title="${formattedService.tooltip}">AUX</span>`,
        class: formattedService.class
    };
};
if (typeof module !== 'undefined' && module.exports) {
    module.exports = DataHelper;
}
function applyViewOnlyMode() {
    const banner = document.getElementById("view-only-banner");
    if (banner) banner.style.display = viewOnlyMode ? "flex" : "none";
    VIEW_ONLY_DISABLED_IDS.forEach(id => {
        const el = document.getElementById(id);
        if (!el) return;
        el.classList.toggle("view-only-disabled", viewOnlyMode);
        if ("disabled" in el) el.disabled = viewOnlyMode;
        if (viewOnlyMode) {
            el.dataset.viewOnlyTitle = el.title || "";
            el.title = "View-only mode - remote connection, this control is disabled";
        } else if (el.dataset.viewOnlyTitle !== undefined) {
            el.title = el.dataset.viewOnlyTitle;
            delete el.dataset.viewOnlyTitle;
        }
    });
    updateRemoteLogoutVisibility();
}
function updateRemoteLogoutVisibility() {
    const btn = document.getElementById("btn-remote-logout");
    if (!btn) return;
    const remoteUnlocked = !isLocalConnection && !viewOnlyMode;
    btn.style.display = remoteUnlocked ? "" : "none";
}
function syncHeaderBarHeightVar() {
    const wrap = document.getElementById("sticky-top-wrap");
    if (wrap) {
        document.documentElement.style.setProperty("--header-bar-height", `${wrap.offsetHeight}px`);
    }
    const actionBar = document.getElementById("action-bar");
    document.documentElement.style.setProperty("--action-bar-height", `${actionBar ? actionBar.offsetHeight : 0}px`);
}
function setupHeaderBarHeightSync() {
    const wrap = document.getElementById("sticky-top-wrap");
    if (!wrap) return;
    syncHeaderBarHeightVar();
    if (window.ResizeObserver) {
        const observer = new ResizeObserver(syncHeaderBarHeightVar);
        observer.observe(wrap);
        const actionBar = document.getElementById("action-bar");
        if (actionBar) observer.observe(actionBar);
    } else {
        window.addEventListener("resize", syncHeaderBarHeightVar);
    }
}
function syncActionOutputWidthVar() {
    const tabs = document.getElementById("view-tabs");
    const items = tabs ? tabs.querySelectorAll(".view-tab") : [];
    if (!tabs || !items.length) {
        document.documentElement.style.setProperty("--action-output-width", "100%");
        return;
    }
    const first = items[0].getBoundingClientRect();
    const last = items[items.length - 1].getBoundingClientRect();
    const width = Math.max(0, last.right - first.left);
    document.documentElement.style.setProperty("--action-output-width", `${width}px`);
}
function setupActionOutputWidthSync() {
    const tabs = document.getElementById("view-tabs");
    if (!tabs) return;
    syncActionOutputWidthVar();
    if (window.ResizeObserver) {
        const observer = new ResizeObserver(syncActionOutputWidthVar);
        observer.observe(tabs);
    } else {
        window.addEventListener("resize", syncActionOutputWidthVar);
    }
}
function syncWorkerListWidthVar() {
    const grid = document.querySelector(".rig-header-grid");
    const items = grid ? grid.querySelectorAll(".header-item") : [];
    if (!grid || !items.length) {
        document.documentElement.style.setProperty("--worker-list-width", "100%");
        return;
    }
    const first = items[0].getBoundingClientRect();
    const last = items[items.length - 1].getBoundingClientRect();
    const width = Math.max(0, last.right - first.left);
    document.documentElement.style.setProperty("--worker-list-width", `${width}px`);
}
function setupWorkerListWidthSync() {
    const grid = document.querySelector(".rig-header-grid");
    if (!grid) return;
    syncWorkerListWidthVar();
    if (window.ResizeObserver) {
        const observer = new ResizeObserver(syncWorkerListWidthVar);
        observer.observe(grid);
    } else {
        window.addEventListener("resize", syncWorkerListWidthVar);
    }
}
const CMD_INPUT_HEIGHT_KEY = "rigcontrol_cmd_input_height";
function restoreCmdAreaHeights() {
    const input = document.getElementById("cmd-input");
    if (!input) return;
    const saved = localStorage.getItem(CMD_INPUT_HEIGHT_KEY);
    if (saved) input.style.height = saved;
}
function setupCmdAreaResizeSaving() {
    const divider = document.getElementById("cmd-resize-divider");
    const input = document.getElementById("cmd-input");
    if (!divider || !input) return;
    let dragging = false;
    let startY = 0;
    let startHeight = 0;
    divider.addEventListener("mousedown", (e) => {
        dragging = true;
        startY = e.clientY;
        startHeight = input.offsetHeight;
        divider.classList.add("dragging");
        document.body.style.cursor = "row-resize";
        document.body.style.userSelect = "none";
        e.preventDefault();
    });
    document.addEventListener("mousemove", (e) => {
        if (!dragging) return;
        const delta = e.clientY - startY;
        const minHeight = 40;
        const maxHeight = Math.round(window.innerHeight * 0.7);
        const newHeight = Math.min(maxHeight, Math.max(minHeight, startHeight + delta));
        input.style.height = `${newHeight}px`;
    });
    document.addEventListener("mouseup", () => {
        if (!dragging) return;
        dragging = false;
        divider.classList.remove("dragging");
        document.body.style.cursor = "";
        document.body.style.userSelect = "";
        localStorage.setItem(CMD_INPUT_HEIGHT_KEY, input.style.height);
    });
}
const CMD_OUTPUT_HEIGHT_KEY = "rigcontrol_cmd_output_height";
function restoreCmdOutputHeight() {
    const output = document.getElementById("cmd-output");
    if (!output) return;
    const saved = localStorage.getItem(CMD_OUTPUT_HEIGHT_KEY);
    if (saved) output.style.height = saved;
}
function setupCmdOutputResizeSaving() {
    const divider = document.getElementById("cmd-output-resize-divider");
    const output = document.getElementById("cmd-output");
    if (!divider || !output) return;
    let dragging = false;
    let startY = 0;
    let startHeight = 0;
    divider.addEventListener("mousedown", (e) => {
        dragging = true;
        startY = e.clientY;
        startHeight = output.offsetHeight;
        divider.classList.add("dragging");
        document.body.style.cursor = "row-resize";
        document.body.style.userSelect = "none";
        e.preventDefault();
    });
    document.addEventListener("mousemove", (e) => {
        if (!dragging) return;
        const delta = e.clientY - startY;
        const minHeight = 60;
        const maxHeight = Math.round(window.innerHeight * 0.8);
        const newHeight = Math.min(maxHeight, Math.max(minHeight, startHeight + delta));
        output.style.height = `${newHeight}px`;
    });
    document.addEventListener("mouseup", () => {
        if (!dragging) return;
        dragging = false;
        divider.classList.remove("dragging");
        document.body.style.cursor = "";
        document.body.style.userSelect = "";
        localStorage.setItem(CMD_OUTPUT_HEIGHT_KEY, output.style.height);
    });
}
const CMD_MODAL_SIZE_KEY = "rigcontrol_cmd_modal_size";
function restoreCmdModalSize() {
    const modal = document.getElementById("cmd-modal");
    if (!modal) return;
    try {
        const raw = localStorage.getItem(CMD_MODAL_SIZE_KEY);
        const saved = raw ? JSON.parse(raw) : null;
        if (saved && saved.width) modal.style.width = saved.width;
        if (saved && saved.height) modal.style.height = saved.height;
    } catch (err) {
        console.error("Failed to parse saved Send Cmd panel size, ignoring it", err);
    }
}
function setupCmdModalSizeSaving() {
    const modal = document.getElementById("cmd-modal");
    if (!modal || typeof ResizeObserver === "undefined") return;
    let saveTimer = null;
    const observer = new ResizeObserver(() => {
        if (modal.classList.contains("hidden")) return;
        clearTimeout(saveTimer);
        saveTimer = setTimeout(() => {
            localStorage.setItem(CMD_MODAL_SIZE_KEY, JSON.stringify({
                width: modal.style.width || `${modal.offsetWidth}px`,
                height: modal.style.height || `${modal.offsetHeight}px`,
            }));
        }, 300);
    });
    observer.observe(modal);
}
const LOGS_MODAL_SIZE_KEY = "rigcontrol_logs_modal_size";
function restoreLogsModalSize() {
    const modal = document.getElementById("logs-modal");
    if (!modal) return;
    try {
        const raw = localStorage.getItem(LOGS_MODAL_SIZE_KEY);
        const saved = raw ? JSON.parse(raw) : null;
        if (saved && saved.width) modal.style.width = saved.width;
        if (saved && saved.height) modal.style.height = saved.height;
    } catch (err) {
        console.error("Failed to parse saved Logs panel size, ignoring it", err);
    }
}
function setupLogsModalSizeSaving() {
    const modal = document.getElementById("logs-modal");
    if (!modal || typeof ResizeObserver === "undefined") return;
    let saveTimer = null;
    const observer = new ResizeObserver(() => {
        if (modal.classList.contains("hidden")) return;
        clearTimeout(saveTimer);
        saveTimer = setTimeout(() => {
            localStorage.setItem(LOGS_MODAL_SIZE_KEY, JSON.stringify({
                width: modal.style.width || `${modal.offsetWidth}px`,
                height: modal.style.height || `${modal.offsetHeight}px`,
            }));
        }, 300);
    });
    observer.observe(modal);
}
function restoreResizableDialogWidth(containerId, storageKey) {
    const dialog = document.querySelector(`#${containerId} .cmd-dialog`);
    if (!dialog) return;
    try {
        const saved = localStorage.getItem(storageKey);
        if (saved) dialog.style.width = saved;
    } catch (err) {
        console.error(`Failed to restore saved width for #${containerId}, ignoring it`, err);
    }
}
function setupResizableDialogWidthSaving(containerId, storageKey) {
    const container = document.getElementById(containerId);
    const dialog = document.querySelector(`#${containerId} .cmd-dialog`);
    if (!container || !dialog || typeof ResizeObserver === "undefined") return;
    let saveTimer = null;
    const observer = new ResizeObserver(() => {
        if (container.classList.contains("hidden")) return;
        clearTimeout(saveTimer);
        saveTimer = setTimeout(() => {
            localStorage.setItem(storageKey, dialog.style.width || `${dialog.offsetWidth}px`);
        }, 300);
    });
    observer.observe(dialog);
}
// Like restoreResizableDialogWidth/setupResizableDialogWidthSaving above, but for dialogs
// resized via a .dialog-resize-handle-corner (both width and height), e.g. #raw-content-modal.
function restoreResizableDialogSize(containerId, storageKey) {
    const dialog = document.querySelector(`#${containerId} .cmd-dialog`);
    if (!dialog) return;
    try {
        const saved = JSON.parse(localStorage.getItem(storageKey) || "null");
        if (saved && saved.width) dialog.style.width = saved.width;
        if (saved && saved.height) dialog.style.height = saved.height;
    } catch (err) {
        console.error(`Failed to restore saved size for #${containerId}, ignoring it`, err);
    }
}
function setupResizableDialogSizeSaving(containerId, storageKey) {
    const container = document.getElementById(containerId);
    const dialog = document.querySelector(`#${containerId} .cmd-dialog`);
    if (!container || !dialog || typeof ResizeObserver === "undefined") return;
    let saveTimer = null;
    const observer = new ResizeObserver(() => {
        if (container.classList.contains("hidden")) return;
        clearTimeout(saveTimer);
        saveTimer = setTimeout(() => {
            localStorage.setItem(storageKey, JSON.stringify({
                width: dialog.style.width || `${dialog.offsetWidth}px`,
                height: dialog.style.height || `${dialog.offsetHeight}px`,
            }));
        }, 300);
    });
    observer.observe(dialog);
}
function initDialogResizeHandles() {
    document.querySelectorAll(".dialog-resize-handle-right").forEach(handle => {
        handle.addEventListener("mousedown", (e) => {
            e.preventDefault();
            const dialog = handle.parentElement;
            if (!dialog) return;
            const startX = e.clientX;
            const startWidth = dialog.getBoundingClientRect().width;
            handle.classList.add("dragging");
            document.body.style.userSelect = "none";
            function onMouseMove(moveEvent) {
                const delta = moveEvent.clientX - startX;
                dialog.style.width = `${startWidth + delta}px`;
            }
            function onMouseUp() {
                handle.classList.remove("dragging");
                document.body.style.userSelect = "";
                document.removeEventListener("mousemove", onMouseMove);
                document.removeEventListener("mouseup", onMouseUp);
            }
            document.addEventListener("mousemove", onMouseMove);
            document.addEventListener("mouseup", onMouseUp);
        });
    });
    document.querySelectorAll(".dialog-resize-handle-corner").forEach(handle => {
        handle.addEventListener("mousedown", (e) => {
            e.preventDefault();
            // closest(), not parentElement - #raw-content-modal's handle sits inside
            // .raw-content-slot (overlaying the textarea's own corner) rather than being a
            // direct child of .cmd-dialog like the other modals' corner handles, but it still
            // needs to resize the whole dialog, not just the slot it visually sits in.
            const dialog = handle.closest(".cmd-dialog");
            if (!dialog) return;
            const startX = e.clientX;
            const startY = e.clientY;
            const rect = dialog.getBoundingClientRect();
            const startWidth = rect.width;
            const startHeight = rect.height;
            handle.classList.add("dragging");
            document.body.style.userSelect = "none";
            function onMouseMove(moveEvent) {
                const deltaX = moveEvent.clientX - startX;
                const deltaY = moveEvent.clientY - startY;
                dialog.style.width = `${startWidth + deltaX}px`;
                dialog.style.height = `${startHeight + deltaY}px`;
            }
            function onMouseUp() {
                handle.classList.remove("dragging");
                document.body.style.userSelect = "";
                document.removeEventListener("mousemove", onMouseMove);
                document.removeEventListener("mouseup", onMouseUp);
            }
            document.addEventListener("mousemove", onMouseMove);
            document.addEventListener("mouseup", onMouseUp);
        });
    });
}
const STATUSLOG_LIST_WIDTH_KEY = "rigcontrol_statuslog_list_width";
// Draggable divider between the Status Log entry list and its details pane (#statuslog-col-resizer)
// - separate from initDialogResizeHandles() above, which only resizes the whole dialog. Same
// mousedown/mousemove/mouseup drag mechanics, but clamps against the list panel's own min/max-width
// (see app.css) and persists the chosen width to localStorage, same pattern as
// AGENTCONF_RAW_HEIGHT_KEY/CMD_INPUT_HEIGHT_KEY use for other manually-resized elements.
function initStatuslogColResizer() {
    const handle = document.getElementById("statuslog-col-resizer");
    const listPanel = document.querySelector("#statuslog-modal .fs-list-panel");
    if (!handle || !listPanel) return;
    handle.addEventListener("mousedown", (e) => {
        e.preventDefault();
        const startX = e.clientX;
        const startWidth = listPanel.getBoundingClientRect().width;
        handle.classList.add("dragging");
        document.body.style.userSelect = "none";
        function onMouseMove(moveEvent) {
            const delta = moveEvent.clientX - startX;
            listPanel.style.width = `${startWidth + delta}px`;
        }
        function onMouseUp() {
            handle.classList.remove("dragging");
            document.body.style.userSelect = "";
            document.removeEventListener("mousemove", onMouseMove);
            document.removeEventListener("mouseup", onMouseUp);
            if (listPanel.style.width) localStorage.setItem(STATUSLOG_LIST_WIDTH_KEY, listPanel.style.width);
        }
        document.addEventListener("mousemove", onMouseMove);
        document.addEventListener("mouseup", onMouseUp);
    });
}
function restoreStatuslogListWidth() {
    const listPanel = document.querySelector("#statuslog-modal .fs-list-panel");
    const saved = localStorage.getItem(STATUSLOG_LIST_WIDTH_KEY);
    if (listPanel && saved) listPanel.style.width = saved;
}
// Shared "Raw Content" popup used by Flightsheets/Overclocking/Watchdog - each module's raw
// textarea lives at rest inside a hidden .raw-content-home wrapper in its own modal; clicking
// the "> Raw Content <" trigger portals that exact textarea element (same id, same listeners,
// same value) into #raw-content-slot and shows the popup. Closing portals it right back to
// where it came from. Only one can be open at a time.
let rawContentPortalRecord = null;
function openRawContentModal(textareaId, title) {
    const textarea = document.getElementById(textareaId);
    const slot = document.getElementById("raw-content-slot");
    const modal = document.getElementById("raw-content-modal");
    if (!textarea || !slot || !modal) return;
    rawContentPortalRecord = { el: textarea, parent: textarea.parentNode, nextSibling: textarea.nextSibling };
    slot.appendChild(textarea);
    const titleEl = document.getElementById("raw-content-title");
    if (titleEl) titleEl.textContent = title || "Raw Content";
    modal.classList.remove("hidden");
    textarea.focus();
}
function closeRawContentModal() {
    const modal = document.getElementById("raw-content-modal");
    if (!modal) return;
    if (rawContentPortalRecord && rawContentPortalRecord.parent) {
        rawContentPortalRecord.parent.insertBefore(rawContentPortalRecord.el, rawContentPortalRecord.nextSibling);
    }
    rawContentPortalRecord = null;
    modal.classList.add("hidden");
}
function initRawContentTriggers() {
    document.querySelectorAll(".fs-raw-label-clickable").forEach((btn) => {
        btn.addEventListener("click", () => {
            openRawContentModal(btn.dataset.rawTarget, btn.dataset.rawTitle);
        });
    });
    document.getElementById("btn-raw-content-close-x")?.addEventListener("click", closeRawContentModal);
    document.getElementById("btn-raw-content-close")?.addEventListener("click", closeRawContentModal);
}
function normalizeHexColor(value) {
    const v = (value || "").trim();
    if (/^#[0-9a-fA-F]{6}$/.test(v)) return v.toLowerCase();
    const probe = document.createElement("span");
    probe.style.color = "";
    probe.style.color = v;
    if (!probe.style.color) return "#000000";
    document.body.appendChild(probe);
    const resolved = getComputedStyle(probe).color;
    document.body.removeChild(probe);
    const m = /^rgba?\(\s*(\d+),\s*(\d+),\s*(\d+)/.exec(resolved);
    if (!m) return "#000000";
    const toHex = n => Math.max(0, Math.min(255, Number(n))).toString(16).padStart(2, "0");
    return `#${toHex(m[1])}${toHex(m[2])}${toHex(m[3])}`;
}
function refreshColorSchemeInputsFromOverrides() {
    const overrides = loadColorSchemeOverrides();
    const computed = getComputedStyle(document.documentElement);
    Object.entries(COLOR_SCHEME_MAP).forEach(([id, cssVars]) => {
        const el = document.getElementById(id);
        if (!el) return;
        if (Object.prototype.hasOwnProperty.call(overrides, id)) {
            el.value = normalizeHexColor(overrides[id]);
        } else {
            const current = computed.getPropertyValue(cssVars[0]).trim();
            if (current) el.value = normalizeHexColor(current);
        }
    });
    Object.entries(SIZE_SCHEME_MAP).forEach(([id, cssVars]) => {
        const el = document.getElementById(id);
        if (!el) return;
        if (Object.prototype.hasOwnProperty.call(overrides, id)) {
            el.value = overrides[id];
        } else {
            const current = parseInt(computed.getPropertyValue(cssVars[0]), 10);
            if (!isNaN(current)) el.value = current;
        }
    });
}
function initColorSchemeControls() {
    refreshColorSchemeInputsFromOverrides();
    initColorSchemeTabs();
    initColorSchemeCollapseToggle();
    if (selectedServerSchemeName) {
        const label = document.getElementById("color-scheme-selected-label");
        if (label) label.textContent = selectedServerSchemeName;
    }
    Object.entries(COLOR_SCHEME_MAP).forEach(([id, cssVars]) => {
        const el = document.getElementById(id);
        if (!el) return;
        el.addEventListener("input", () => {
            const current = loadColorSchemeOverrides();
            current[id] = el.value;
            saveColorSchemeOverrides(current);
            applyColorSchemeOverrides({ [id]: el.value });
        });
    });
    Object.entries(SIZE_SCHEME_MAP).forEach(([id, cssVars]) => {
        const el = document.getElementById(id);
        if (!el) return;
        el.addEventListener("input", () => {
            const val = parseInt(el.value, 10);
            if (isNaN(val)) return;
            const current = loadColorSchemeOverrides();
            current[id] = val;
            saveColorSchemeOverrides(current);
            applyColorSchemeOverrides({ [id]: val });
        });
    });
    document.getElementById("btn-reset-color-scheme")?.addEventListener("click", () => {
        if (!confirm("Reset all theme settings back to the defaults?")) return;
        localStorage.removeItem(COLOR_SCHEME_STORAGE_KEY);
        localStorage.removeItem(WALLPAPER_STORAGE_KEY);
        localStorage.removeItem(STAT_PANEL_IMAGE_STORAGE_KEY);
        localStorage.removeItem(STAT_PANEL_STYLE_STORAGE_KEY);
        localStorage.removeItem(TOOLBAR_BTN_STYLE_STORAGE_KEY);
        localStorage.removeItem(TOOLBAR_BTN_ICON_STORAGE_KEY);
        localStorage.removeItem(TOOLBAR_BTN_LOCK_STORAGE_KEY);
        localStorage.removeItem(TAB_ICON_STORAGE_KEY);
        localStorage.removeItem(TOOLBAR_CUSTOM_ICONS_STORAGE_KEY);
        localStorage.removeItem(ACTIVE_THEME_NAME_KEY);
        localStorage.removeItem("rigcloud_color_scheme");
        localStorage.removeItem("rigcloud_wallpaper");
        localStorage.removeItem("rigcloud_stat_panel_image");
        localStorage.removeItem("rigcloud_stat_panel_style");
        localStorage.removeItem("rigcloud_toolbar_btn_style");
        localStorage.removeItem("rigcloud_toolbar_btn_icons");
        localStorage.removeItem("rigcloud_toolbar_btn_lock");
        localStorage.removeItem("rigcloud_toolbar_custom_icons");
        localStorage.removeItem("rigcloud_active_theme_name");
        location.reload();
    });
    document.getElementById("btn-color-scheme-list-toggle")?.addEventListener("click", (evt) => {
        evt.stopPropagation();
        toggleColorSchemeListDropdown();
    });
    document.getElementById("btn-clear-color-surface-header")?.addEventListener("click", () => {
        clearColorSchemeOverride("color-surface-header");
    });
    document.getElementById("btn-clear-color-surface-tabs")?.addEventListener("click", () => {
        clearColorSchemeOverride("color-surface-tabs");
    });
    document.getElementById("btn-clear-color-surface-app")?.addEventListener("click", () => {
        setColorSchemeOverrideTransparent("color-surface-app");
    });
    document.getElementById("btn-clear-color-action-output-bg")?.addEventListener("click", () => {
        setColorSchemeOverrideTransparent("color-action-output-bg");
    });
    document.getElementById("btn-clear-color-surface-panel")?.addEventListener("click", () => {
        setColorSchemeOverrideTransparent("color-surface-panel");
    });
    document.getElementById("btn-save-color-scheme")?.addEventListener("click", saveCurrentColorSchemeToServer);
    document.getElementById("btn-load-color-scheme")?.addEventListener("click", loadSelectedColorSchemeFromServer);
    document.getElementById("btn-open-color-scheme-json")?.addEventListener("click", () => {
        document.getElementById("color-scheme-json-modal")?.classList.remove("hidden");
        document.getElementById("color-scheme-json-paste")?.focus();
    });
    document.getElementById("btn-close-color-scheme-json")?.addEventListener("click", () => {
        document.getElementById("color-scheme-json-modal")?.classList.add("hidden");
    });
    document.getElementById("btn-color-scheme-json-close-x")?.addEventListener("click", () => {
        document.getElementById("color-scheme-json-modal")?.classList.add("hidden");
    });
    document.getElementById("btn-import-color-scheme-json")?.addEventListener("click", () => {
        if (applyPastedColorSchemeJson()) {
            document.getElementById("color-scheme-json-modal")?.classList.add("hidden");
        }
    });
    document.getElementById("btn-export-color-scheme-json")?.addEventListener("click", exportCurrentColorSchemeToFile);
    const colorSchemeJsonFileInput = document.getElementById("color-scheme-json-file-input");
    document.getElementById("btn-browse-color-scheme-json")?.addEventListener("click", () => {
        colorSchemeJsonFileInput?.click();
    });
    colorSchemeJsonFileInput?.addEventListener("change", () => {
        const file = colorSchemeJsonFileInput.files?.[0];
        colorSchemeJsonFileInput.value = ""; 
        if (!file) return;
        if (!/\.json$/i.test(file.name)) {
            alert("Please choose a .json file.");
            return;
        }
        const reader = new FileReader();
        reader.onload = () => {
            const textarea = document.getElementById("color-scheme-json-paste");
            if (textarea) {
                textarea.value = String(reader.result || "");
                textarea.focus();
            }
        };
        reader.onerror = () => {
            alert("Couldn't read that file.");
        };
        reader.readAsText(file);
    });
    document.addEventListener("click", (evt) => {
        const wrap = document.getElementById("color-scheme-list-wrap");
        if (wrap && !wrap.contains(evt.target)) {
            closeColorSchemeListDropdown();
        }
    });
}
function initWallpaperControls() {
    const fileInput = document.getElementById("wallpaper-file-input");
    const targetChoiceText =
        "Click OK to set the Main Page wallpaper (behind the worker list).\n" +
        "Click Cancel to set the Info Tiles background (the stat panel row) instead.";
    const applyPickedImage = (image, target) => {
        if (target === "tiles") {
            const existing = loadStatPanelImageSettings();
            const settings = {
                image,
                opacity: typeof existing?.opacity === "number" ? existing.opacity : STAT_PANEL_IMAGE_OPACITY_DEFAULT,
                fit: STAT_PANEL_IMAGE_FIT_MAP[existing?.fit] ? existing.fit : STAT_PANEL_IMAGE_FIT_DEFAULT,
            };
            applyStatPanelImageSettings(settings);
            if (!saveStatPanelImageSettings(settings)) {
                alert("Info tiles background applied, but couldn't be saved for next time.");
            }
            return;
        }
        const existing = loadWallpaperSettings();
        const settings = {
            image,
            opacity: typeof existing?.opacity === "number" ? existing.opacity : WALLPAPER_OPACITY_DEFAULT,
            fit: !!existing?.fit,
            tile: !!existing?.tile,
        };
        applyWallpaperSettings(settings);
        if (!saveWallpaperSettings(settings)) {
            alert("Wallpaper applied, but couldn't be saved for next time.");
        }
        clearColorSchemeOverride("color-wallpaper-backdrop");
    };
    document.getElementById("btn-wallpaper")?.addEventListener("click", () => {
        const useUrl = confirm(
            "Click OK to paste an image URL.\n" +
            "Click Cancel to browse for a local image file instead."
        );
        if (!useUrl) {
            fileInput?.click();
            return;
        }
        const url = (prompt("Paste an image URL:") || "").trim();
        if (!url) return;
        if (!isHttpUrl(url)) {
            alert("That doesn't look like a valid http(s) URL.");
            return;
        }
        const target = confirm(targetChoiceText) ? "main" : "tiles";
        applyPickedImage(url, target);
    });
    fileInput?.addEventListener("change", () => {
        const file = fileInput.files?.[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onload = () => {
            const target = confirm(targetChoiceText) ? "main" : "tiles";
            applyPickedImage(reader.result, target);
        };
        reader.onerror = () => {
            console.error("Failed to read wallpaper file", reader.error);
            alert("Failed to read that image file.");
        };
        reader.readAsDataURL(file);
        fileInput.value = ""; 
    });
    const nudgeOpacity = (delta) => {
        const current = loadWallpaperSettings();
        if (!current?.image) {
            alert("Browse for a wallpaper image first (WP button).");
            return;
        }
        const nextOpacity = Math.min(
            WALLPAPER_OPACITY_MAX,
            Math.max(WALLPAPER_OPACITY_MIN, Math.round((current.opacity + delta) * 100) / 100)
        );
        const settings = { ...current, opacity: nextOpacity };
        applyWallpaperSettings(settings);
        saveWallpaperSettings(settings);
    };
    document.getElementById("btn-wallpaper-opacity-up")?.addEventListener("click", () => {
        nudgeOpacity(WALLPAPER_OPACITY_STEP);
    });
    document.getElementById("btn-wallpaper-opacity-down")?.addEventListener("click", () => {
        nudgeOpacity(-WALLPAPER_OPACITY_STEP);
    });
    document.getElementById("btn-wallpaper-clear-themes")?.addEventListener("click", () => {
        applyWallpaperSettings(null);
        localStorage.removeItem(WALLPAPER_STORAGE_KEY);
        clearColorSchemeOverride("color-wallpaper-backdrop");
    });
    const fitCheckbox = document.getElementById("wallpaper-fit-checkbox");
    const tileCheckbox = document.getElementById("wallpaper-tile-checkbox");
    fitCheckbox?.addEventListener("change", () => {
        const current = loadWallpaperSettings();
        if (!current?.image) {
            fitCheckbox.checked = false;
            alert("Browse for a wallpaper image first (WP button).");
            return;
        }
        const settings = { ...current, fit: fitCheckbox.checked };
        applyWallpaperSettings(settings);
        saveWallpaperSettings(settings);
    });
    tileCheckbox?.addEventListener("change", () => {
        const current = loadWallpaperSettings();
        if (!current?.image) {
            tileCheckbox.checked = false;
            alert("Browse for a wallpaper image first (WP button).");
            return;
        }
        const settings = { ...current, tile: tileCheckbox.checked };
        applyWallpaperSettings(settings);
        saveWallpaperSettings(settings);
    });
    const savedWallpaper = loadWallpaperSettings();
    if (fitCheckbox) fitCheckbox.checked = !!savedWallpaper?.fit;
    if (tileCheckbox) tileCheckbox.checked = !!savedWallpaper?.tile;
    const nudgeStatPanelImageOpacity = (delta) => {
        const current = loadStatPanelImageSettings();
        if (!current?.image) {
            alert("Set an info tiles background image first (WP button, then choose Info Tiles).");
            return;
        }
        const nextOpacity = Math.min(
            STAT_PANEL_IMAGE_OPACITY_MAX,
            Math.max(STAT_PANEL_IMAGE_OPACITY_MIN, Math.round((current.opacity + delta) * 100) / 100)
        );
        const settings = { ...current, opacity: nextOpacity };
        applyStatPanelImageSettings(settings);
        saveStatPanelImageSettings(settings);
    };
    document.getElementById("btn-stat-panel-image-opacity-up")?.addEventListener("click", () => {
        nudgeStatPanelImageOpacity(STAT_PANEL_IMAGE_OPACITY_STEP);
    });
    document.getElementById("btn-stat-panel-image-opacity-down")?.addEventListener("click", () => {
        nudgeStatPanelImageOpacity(-STAT_PANEL_IMAGE_OPACITY_STEP);
    });
    document.getElementById("btn-stat-panel-image-clear")?.addEventListener("click", () => {
        applyStatPanelImageSettings(null);
        localStorage.removeItem(STAT_PANEL_IMAGE_STORAGE_KEY);
    });
    const statPanelImageFitSelect = document.getElementById("stat-panel-image-fit-select");
    statPanelImageFitSelect?.addEventListener("change", () => {
        const current = loadStatPanelImageSettings();
        if (!current?.image) {
            statPanelImageFitSelect.value = STAT_PANEL_IMAGE_FIT_DEFAULT;
            alert("Set an info tiles background image first (WP button, then choose Info Tiles).");
            return;
        }
        const settings = { ...current, fit: statPanelImageFitSelect.value };
        applyStatPanelImageSettings(settings);
        saveStatPanelImageSettings(settings);
    });
    if (statPanelImageFitSelect) {
        const savedStatPanelImage = loadStatPanelImageSettings();
        statPanelImageFitSelect.value = STAT_PANEL_IMAGE_FIT_MAP[savedStatPanelImage?.fit] ? savedStatPanelImage.fit : STAT_PANEL_IMAGE_FIT_DEFAULT;
    }
}
function initStatPanelStyleControls() {
    const readAndApply = () => {
        const settings = {
            shape: document.getElementById("stat-panel-shape-select")?.value || STAT_PANEL_STYLE_DEFAULT.shape,
            size: document.getElementById("stat-panel-size-select")?.value || STAT_PANEL_STYLE_DEFAULT.size,
            layout: document.getElementById("stat-panel-layout-select")?.value || STAT_PANEL_STYLE_DEFAULT.layout,
        };
        applyStatPanelStyle(settings);
        saveStatPanelStyle(settings);
    };
    document.getElementById("stat-panel-shape-select")?.addEventListener("change", readAndApply);
    document.getElementById("stat-panel-size-select")?.addEventListener("change", readAndApply);
    document.getElementById("stat-panel-layout-select")?.addEventListener("change", readAndApply);
    applyStatPanelStyle(loadStatPanelStyle());
}
const PAGE_ALIGN_STORAGE_KEY = "rigcontrol_page_align";
const PAGE_ALIGN_DEFAULT = "centered";
function loadPageAlign() {
    const saved = localStorage.getItem(PAGE_ALIGN_STORAGE_KEY);
    return saved === "left" ? "left" : PAGE_ALIGN_DEFAULT;
}
function savePageAlign(align) {
    localStorage.setItem(PAGE_ALIGN_STORAGE_KEY, align);
}
function applyPageAlign(align) {
    const value = align === "left" ? "left" : PAGE_ALIGN_DEFAULT;
    document.body.classList.toggle("layout-left", value === "left");
    const select = document.getElementById("page-align-select");
    if (select) select.value = value;
}
function initPageAlignControl() {
    const select = document.getElementById("page-align-select");
    select?.addEventListener("change", () => {
        const value = select.value === "left" ? "left" : PAGE_ALIGN_DEFAULT;
        applyPageAlign(value);
        savePageAlign(value);
    });
    applyPageAlign(loadPageAlign());
}
function initToolbarBtnStyleControls() {
    const readAndApplyStyle = () => {
        const settings = {
            shape: document.getElementById("toolbar-btn-shape-select")?.value || TOOLBAR_BTN_STYLE_DEFAULT.shape,
            size: document.getElementById("toolbar-btn-size-select")?.value || TOOLBAR_BTN_STYLE_DEFAULT.size,
        };
        applyToolbarBtnStyle(settings);
        saveToolbarBtnStyle(settings);
    };
    document.getElementById("toolbar-btn-shape-select")?.addEventListener("change", readAndApplyStyle);
    document.getElementById("toolbar-btn-size-select")?.addEventListener("change", readAndApplyStyle);
    applyToolbarBtnStyle(loadToolbarBtnStyle());
    const lockCheckbox = document.getElementById("toolbar-style-lock-checkbox");
    if (lockCheckbox) {
        lockCheckbox.checked = loadToolbarBtnLock();
        lockCheckbox.addEventListener("change", () => {
            saveToolbarBtnLock(lockCheckbox.checked);
        });
    }
    const savedIcons = loadToolbarBtnIcons();
    applyToolbarBtnIcons(savedIcons);
    let lastFocusedToolbarIconInput = null;
    for (const id of Object.keys(TOOLBAR_BTN_ICON_DEFAULTS)) {
        const input = document.getElementById(`toolbar-icon-input-${id}`);
        if (!input) continue;
        input.addEventListener("focus", () => { lastFocusedToolbarIconInput = input; });
        input.addEventListener("input", () => { delete input.dataset.srcValue; });
        input.addEventListener("change", () => {
            const current = loadToolbarBtnIcons();
            const val = input.dataset.srcValue || input.value;
            if (val.trim() === "" || val === TOOLBAR_BTN_ICON_DEFAULTS[id]) {
                delete current[id];
            } else {
                current[id] = val;
            }
            saveToolbarBtnIcons(current);
            applyToolbarBtnIcons(current);
        });
    }
    const savedTabIcons = loadTabIcons();
    applyTabIcons(savedTabIcons);
    for (const key of Object.keys(TAB_ICON_DEFAULTS)) {
        const input = document.getElementById(`tab-icon-input-${key}`);
        if (!input) continue;
        input.addEventListener("focus", () => { lastFocusedToolbarIconInput = input; });
        input.addEventListener("input", () => { delete input.dataset.srcValue; });
        input.addEventListener("change", () => {
            const current = loadTabIcons();
            const val = input.dataset.srcValue || input.value;
            if (val.trim() === "" || val === TAB_ICON_DEFAULTS[key]) {
                delete current[key];
            } else {
                current[key] = val;
            }
            saveTabIcons(current);
            applyTabIcons(current);
        });
    }
    document.getElementById("btn-tab-icons-reset-all")?.addEventListener("click", () => {
        if (!confirm("Restore every tab icon back to its default?")) return;
        localStorage.removeItem(TAB_ICON_STORAGE_KEY);
        applyTabIcons({});
    });
    document.getElementById("btn-toolbar-icon-picker-apply")?.addEventListener("click", () => {
        const picker = document.getElementById("toolbar-icon-picker-select");
        if (!picker) return;
        const target = lastFocusedToolbarIconInput
            || document.getElementById(`toolbar-icon-input-${Object.keys(TOOLBAR_BTN_ICON_DEFAULTS)[0]}`);
        if (!target) return;
        const rawVal = picker.value;
        if (isImageIconValue(rawVal)) {
            const selectedOption = picker.options[picker.selectedIndex];
            target.value = selectedOption ? selectedOption.textContent : rawVal;
            target.dataset.srcValue = rawVal;
        } else {
            target.value = rawVal;
            delete target.dataset.srcValue;
        }
        target.dispatchEvent(new Event("change"));
        target.focus();
    });
    for (const entry of loadToolbarCustomIcons()) {
        const option = document.createElement("option");
        option.value = entry.src;
        option.textContent = entry.label;
        document.getElementById("toolbar-icon-picker-select")?.appendChild(option);
    }
    initToolbarIconPickerList();
}
function renderToolbarIconPickerList() {
    const picker = document.getElementById("toolbar-icon-picker-select");
    const list = document.getElementById("toolbar-icon-picker-list");
    if (!picker || !list) return;
    list.innerHTML = "";
    const customSrcs = new Set(loadToolbarCustomIcons().map(entry => entry.src));
    Array.from(picker.options).forEach(option => {
        const item = document.createElement("div");
        item.className = "toolbar-icon-picker-list-item";
        const nameEl = document.createElement("span");
        nameEl.className = "toolbar-icon-picker-list-item-name";
        nameEl.textContent = option.textContent;
        item.appendChild(nameEl);
        nameEl.addEventListener("click", () => {
            picker.value = option.value;
            const label = document.getElementById("toolbar-icon-picker-selected-label");
            if (label) label.textContent = option.textContent;
            closeToolbarIconPickerDropdown();
        });
        if (customSrcs.has(option.value)) {
            const deleteBtn = document.createElement("button");
            deleteBtn.type = "button";
            deleteBtn.className = "toolbar-icon-picker-list-item-delete";
            deleteBtn.title = `Delete "${option.textContent}"`;
            deleteBtn.textContent = "✕";
            item.appendChild(deleteBtn);
            deleteBtn.addEventListener("click", (evt) => {
                evt.stopPropagation();
                if (!confirm(`Delete custom icon "${option.textContent}"?`)) return;
                const wasSelected = picker.value === option.value;
                const remaining = loadToolbarCustomIcons().filter(entry => entry.src !== option.value);
                saveToolbarCustomIcons(remaining);
                option.remove();
                if (wasSelected) {
                    picker.selectedIndex = 0;
                    const label = document.getElementById("toolbar-icon-picker-selected-label");
                    if (label) label.textContent = picker.options[0]?.textContent || "Pick icon...";
                }
                renderToolbarIconPickerList();
            });
        }
        list.appendChild(item);
    });
}
function openToolbarIconPickerDropdown() {
    document.getElementById("toolbar-icon-picker-list")?.classList.remove("hidden");
    renderToolbarIconPickerList();
}
function closeToolbarIconPickerDropdown() {
    document.getElementById("toolbar-icon-picker-list")?.classList.add("hidden");
}
function toggleToolbarIconPickerDropdown() {
    const list = document.getElementById("toolbar-icon-picker-list");
    if (!list) return;
    if (list.classList.contains("hidden")) {
        openToolbarIconPickerDropdown();
    } else {
        closeToolbarIconPickerDropdown();
    }
}
function initToolbarIconPickerList() {
    const picker = document.getElementById("toolbar-icon-picker-select");
    const label = document.getElementById("toolbar-icon-picker-selected-label");
    if (picker && label) label.textContent = picker.options[picker.selectedIndex]?.textContent || "Pick icon...";
    document.getElementById("btn-toolbar-icon-picker-toggle")?.addEventListener("click", (evt) => {
        evt.stopPropagation();
        toggleToolbarIconPickerDropdown();
    });
    document.addEventListener("click", (evt) => {
        const wrap = document.getElementById("toolbar-icon-picker-wrap");
        if (wrap && !wrap.contains(evt.target)) {
            closeToolbarIconPickerDropdown();
        }
    });
    const toolbarIconFileInput = document.getElementById("toolbar-icon-file-input");
    document.getElementById("btn-toolbar-icon-load")?.addEventListener("click", () => {
        const useUrl = confirm(
            "Click OK to paste an image URL.\n" +
            "Click Cancel to browse for a local image file instead."
        );
        if (!useUrl) {
            toolbarIconFileInput?.click();
            return;
        }
        const url = (prompt("Paste an icon image URL:") || "").trim();
        if (!url) return;
        if (!isHttpUrl(url)) {
            alert("That doesn't look like a valid http(s) URL.");
            return;
        }
        const urlFallbackName = (url.split("/").pop() || url).split("?")[0] || url;
        const urlLabel = (prompt("Name this icon (shown in the dropdown list):", urlFallbackName) || "").trim();
        if (!urlLabel) return;
        addToolbarCustomIconOption(url, urlLabel);
    });
    toolbarIconFileInput?.addEventListener("change", () => {
        const file = toolbarIconFileInput.files?.[0];
        if (!file) return;
        const reader = new FileReader();
        reader.onload = () => {
            const fileLabel = (prompt("Name this icon (shown in the dropdown list):", file.name) || "").trim();
            if (!fileLabel) return;
            addToolbarCustomIconOption(reader.result, fileLabel);
        };
        reader.onerror = () => {
            console.error("Failed to read icon file", reader.error);
            alert("Failed to read that image file.");
        };
        reader.readAsDataURL(file);
        toolbarIconFileInput.value = ""; 
    });
    document.getElementById("btn-toolbar-icons-reset-all")?.addEventListener("click", () => {
        if (!confirm("Reset all toolbar button icons/text back to the defaults?")) return;
        saveToolbarBtnIcons({});
        applyToolbarBtnIcons({});
    });
}
let serverColorSchemes = {};
const ACTIVE_THEME_NAME_KEY = "rigcontrol_active_theme_name";
function setActiveThemeName(name) {
    selectedServerSchemeName = name || null;
    if (name) localStorage.setItem(ACTIVE_THEME_NAME_KEY, name);
    else localStorage.removeItem(ACTIVE_THEME_NAME_KEY);
}
let selectedServerSchemeName = localStorage.getItem(ACTIVE_THEME_NAME_KEY) || null;
async function fetchServerColorSchemes() {
    try {
        const res = await fetch(`${BASE_PATH}/api/color-schemes`);
        if (!res.ok) throw new Error(`Failed to load themes (${res.status})`);
        serverColorSchemes = await res.json();
    } catch (err) {
        console.error("Failed to load saved themes from server", err);
        serverColorSchemes = {};
    }
    renderColorSchemeList();
}
function renderColorSchemeList() {
    const list = document.getElementById("color-scheme-list");
    if (!list) return;
    list.innerHTML = "";
    const names = Object.keys(serverColorSchemes).sort((a, b) => a.localeCompare(b));
    if (names.length === 0) {
        const empty = document.createElement("div");
        empty.className = "color-scheme-list-empty";
        empty.textContent = "No saved themes yet";
        list.appendChild(empty);
        return;
    }
    names.forEach(name => {
        const item = document.createElement("div");
        item.className = "color-scheme-list-item";
        if (name === selectedServerSchemeName) item.classList.add("selected");
        const nameEl = document.createElement("span");
        nameEl.className = "color-scheme-list-item-name";
        nameEl.textContent = name;
        nameEl.title = "Click to select, double-click to load";
        item.appendChild(nameEl);
        const deleteBtn = document.createElement("button");
        deleteBtn.type = "button";
        deleteBtn.className = "color-scheme-list-item-delete";
        deleteBtn.title = `Delete "${name}"`;
        deleteBtn.textContent = "\u2715";
        item.appendChild(deleteBtn);
        nameEl.addEventListener("click", () => {
            setActiveThemeName(name);
            const label = document.getElementById("color-scheme-selected-label");
            if (label) label.textContent = name;
            list.querySelectorAll(".color-scheme-list-item.selected")
                .forEach(el => el.classList.remove("selected"));
            item.classList.add("selected");
        });
        nameEl.addEventListener("dblclick", (evt) => {
            evt.stopPropagation();
            setActiveThemeName(name);
            const label = document.getElementById("color-scheme-selected-label");
            if (label) label.textContent = name;
            loadSelectedColorSchemeIntoCurrentSession();
            closeColorSchemeListDropdown();
        });
        deleteBtn.addEventListener("click", async (evt) => {
            evt.stopPropagation();
            if (!confirm(`Delete saved theme "${name}"?`)) return;
            try {
                const res = await fetch(`${BASE_PATH}/api/color-schemes/${encodeURIComponent(name)}`, {
                    method: "DELETE",
                });
                if (!res.ok) {
                    let detail = `HTTP ${res.status}`;
                    try {
                        const body = await res.json();
                        if (body?.detail) detail = body.detail;
                    } catch (_) { }
                    throw new Error(detail);
                }
                if (selectedServerSchemeName === name) {
                    setActiveThemeName(null);
                    const label = document.getElementById("color-scheme-selected-label");
                    if (label) label.textContent = "Select theme...";
                }
                await fetchServerColorSchemes();
            } catch (err) {
                console.error("Failed to delete theme", err);
                alert(`Failed to delete "${name}":\n${err.message || err}`);
            }
        });
        list.appendChild(item);
    });
}
function openColorSchemeListDropdown() {
    document.getElementById("color-scheme-list")?.classList.remove("hidden");
    fetchServerColorSchemes();
}
function closeColorSchemeListDropdown() {
    document.getElementById("color-scheme-list")?.classList.add("hidden");
}
function toggleColorSchemeListDropdown() {
    const list = document.getElementById("color-scheme-list");
    if (!list) return;
    if (list.classList.contains("hidden")) {
        openColorSchemeListDropdown();
    } else {
        closeColorSchemeListDropdown();
    }
}
async function saveColorSchemeToServerAndConfirm(name, data) {
    const res = await fetch(`${BASE_PATH}/api/color-schemes`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name, data }),
    });
    if (!res.ok) throw new Error(`Failed to save (${res.status})`);
    await fetchServerColorSchemes();
    const confirmedSaved = Object.prototype.hasOwnProperty.call(serverColorSchemes, name);
    if (!confirmedSaved) {
        alert(`Save request succeeded, but "${name}" was not found when re-checking the server. Please try again.`);
        return false;
    }
    setActiveThemeName(name);
    const label = document.getElementById("color-scheme-selected-label");
    if (label) label.textContent = name;
    return true;
}
const INVALID_FILENAME_CHARS_RE = /[\\/:*?"<>|\x00-\x1f]/;
function getInvalidFilenameChars(name) {
    const found = new Set();
    for (const ch of name) {
        if (INVALID_FILENAME_CHARS_RE.test(ch)) found.add(ch);
    }
    return Array.from(found);
}
async function saveCurrentColorSchemeToServer() {
    let name = prompt("Save current theme as:", selectedServerSchemeName || "");
    if (!name) return;
    while (true) {
        const trimmed = name.trim();
        const badChars = trimmed ? getInvalidFilenameChars(trimmed) : [];
        if (!trimmed) {
            name = prompt("Theme name can't be empty. Save current theme as:", "");
        } else if (badChars.length) {
            name = prompt(
                `That name can't contain ${badChars.map(c => `"${c}"`).join(", ")} (not allowed in filenames). Save current theme as:`,
                trimmed.split("").filter(c => !INVALID_FILENAME_CHARS_RE.test(c)).join("")
            );
        } else {
            name = trimmed;
            break;
        }
        if (!name) return;
    }
    try {
        const data = buildCurrentColorSchemeData();
        await saveColorSchemeToServerAndConfirm(name, data);
    } catch (err) {
        console.error("Failed to save theme to server", err);
        alert("Failed to save theme to the server.");
    }
}
function buildCurrentColorSchemeData() {
    const data = loadColorSchemeOverrides();
    const wallpaper = loadWallpaperSettings();
    if (isHttpUrl(wallpaper?.image)) {
        data.wallpaperUrl = wallpaper.image;
        if (typeof wallpaper.opacity === "number") data.wallpaperOpacity = wallpaper.opacity;
        if (typeof wallpaper.fit === "boolean") data.wallpaperFit = wallpaper.fit;
        if (typeof wallpaper.tile === "boolean") data.wallpaperTile = wallpaper.tile;
    }
    const statPanelImage = loadStatPanelImageSettings();
    if (isHttpUrl(statPanelImage?.image)) {
        data.statPanelImageUrl = statPanelImage.image;
        if (typeof statPanelImage.opacity === "number") data.statPanelImageOpacity = statPanelImage.opacity;
        if (typeof statPanelImage.fit === "string") data.statPanelImageFit = statPanelImage.fit;
    }
    const panelStyle = loadStatPanelStyle();
    data.statPanelShape = panelStyle.shape;
    data.statPanelSize = panelStyle.size;
    data.statPanelLayout = panelStyle.layout;
    const toolbarBtnStyle = loadToolbarBtnStyle();
    data.toolbarBtnShape = toolbarBtnStyle.shape;
    data.toolbarBtnSize = toolbarBtnStyle.size;
    const toolbarBtnIcons = loadToolbarBtnIcons();
    if (Object.keys(toolbarBtnIcons).length > 0) data.toolbarBtnIcons = toolbarBtnIcons;
    return data;
}
function exportCurrentColorSchemeToFile() {
    let name = prompt("Export current theme as:", selectedServerSchemeName || "");
    if (!name) return;
    while (true) {
        const trimmed = name.trim();
        const badChars = trimmed ? getInvalidFilenameChars(trimmed) : [];
        if (!trimmed) {
            name = prompt("Theme name can't be empty. Export current theme as:", "");
        } else if (badChars.length) {
            name = prompt(
                `That name can't contain ${badChars.map(c => `"${c}"`).join(", ")} (not allowed in filenames). Export current theme as:`,
                trimmed.split("").filter(c => !INVALID_FILENAME_CHARS_RE.test(c)).join("")
            );
        } else {
            name = trimmed;
            break;
        }
        if (!name) return;
    }
    try {
        const data = buildCurrentColorSchemeData();
        const json = JSON.stringify({ [name]: data }, null, 2);
        const blob = new Blob([json], { type: "application/json" });
        const url = URL.createObjectURL(blob);
        const link = document.createElement("a");
        link.href = url;
        link.download = `${name}.json`;
        document.body.appendChild(link);
        link.click();
        link.remove();
        URL.revokeObjectURL(url);
    } catch (err) {
        console.error("Failed to export theme to file", err);
        alert("Failed to export the theme to a file.");
    }
}
function parsePastedColorSchemeJson(raw) {
    let parsed;
    try {
        parsed = JSON.parse(raw);
    } catch (err) {
        throw new Error("That's not valid JSON - check for missing commas/quotes/braces.");
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error("Expected a JSON object.");
    }
    if (parsed.data && typeof parsed.data === "object" && !Array.isArray(parsed.data)) {
        return { name: typeof parsed.name === "string" ? parsed.name : null, data: parsed.data };
    }
    const topKeys = Object.keys(parsed);
    const looksBare = topKeys.some(k => k.startsWith("color-") || k.startsWith("size-"));
    if (looksBare) {
        return { name: null, data: parsed };
    }
    if (topKeys.length === 1 && parsed[topKeys[0]] && typeof parsed[topKeys[0]] === "object") {
        return { name: topKeys[0], data: parsed[topKeys[0]] };
    }
    throw new Error("Unrecognized JSON shape - expected a theme name mapped to color/size keys.");
}
function resetThemeCustomizationsForLoad() {
    localStorage.removeItem(WALLPAPER_STORAGE_KEY);
    localStorage.removeItem(STAT_PANEL_IMAGE_STORAGE_KEY);
    localStorage.removeItem(STAT_PANEL_STYLE_STORAGE_KEY);
    applyWallpaperSettings(null);
    applyStatPanelImageSettings(null);
    applyStatPanelStyle(STAT_PANEL_STYLE_DEFAULT);
    localStorage.removeItem(TOOLBAR_BTN_STYLE_STORAGE_KEY);
    applyToolbarBtnStyle(TOOLBAR_BTN_STYLE_DEFAULT);
    if (!loadToolbarBtnLock()) {
        localStorage.removeItem(TOOLBAR_BTN_ICON_STORAGE_KEY);
        applyToolbarBtnIcons({});
    }
    const root = document.documentElement;
    Object.values(COLOR_SCHEME_MAP).flat().forEach(varName => root.style.removeProperty(varName));
    Object.values(SIZE_SCHEME_MAP).flat().forEach(varName => root.style.removeProperty(varName));
}
function applyPastedColorSchemeJson() {
    const textarea = document.getElementById("color-scheme-json-paste");
    const raw = (textarea?.value || "").trim();
    if (!raw) {
        alert("Paste a theme JSON blob first.");
        return false;
    }
    let parsedResult;
    try {
        parsedResult = parsePastedColorSchemeJson(raw);
    } catch (err) {
        alert(err.message || "Could not parse that JSON.");
        return false;
    }
    const { name, data } = parsedResult;
    if (!data || typeof data !== "object" || Array.isArray(data) || Object.keys(data).length === 0) {
        alert("That theme has no color/size entries to apply.");
        return false;
    }
    resetThemeCustomizationsForLoad();
    saveColorSchemeOverrides(data);
    applyThemeDataWallpaper(data);
    applyThemeDataStatPanelImage(data);
    applyThemeDataStatPanelStyle(data);
    applyThemeDataToolbarBtnStyle(data);
    applyThemeDataToolbarBtnIcons(data);
    setActiveThemeName(name);
    if (textarea) textarea.value = "";
    location.reload();
    return true;
}
async function loadSelectedColorSchemeFromServer() {
    if (!selectedServerSchemeName) {
        alert("Select a saved theme first.");
        return;
    }
    try {
        const data = serverColorSchemes[selectedServerSchemeName];
        if (!data) throw new Error("Selected theme not found");
        resetThemeCustomizationsForLoad();
        saveColorSchemeOverrides(data);
        applyThemeDataWallpaper(data);
        applyThemeDataStatPanelImage(data);
        applyThemeDataStatPanelStyle(data);
        applyThemeDataToolbarBtnStyle(data);
        applyThemeDataToolbarBtnIcons(data);
        location.reload();
    } catch (err) {
        console.error("Failed to load color scheme", err);
        alert("Failed to load theme.");
    }
}
function loadSelectedColorSchemeIntoCurrentSession() {
    if (!selectedServerSchemeName) {
        alert("Select a saved theme first.");
        return;
    }
    try {
        const data = serverColorSchemes[selectedServerSchemeName];
        if (!data) throw new Error("Selected theme not found");
        resetThemeCustomizationsForLoad();
        saveColorSchemeOverrides(data);
        applyColorSchemeOverrides(data);
        applyThemeDataWallpaper(data);
        applyThemeDataStatPanelImage(data);
        applyThemeDataStatPanelStyle(data);
        applyThemeDataToolbarBtnStyle(data);
        applyThemeDataToolbarBtnIcons(data);
        refreshColorSchemeInputsFromOverrides();
    } catch (err) {
        console.error("Failed to load color scheme", err);
        alert("Failed to load theme.");
    }
}
async function loadConfig() {
    console.log("Trying to fetch from:", `${BASE_PATH}/api/config`);
    const res = await fetch(`${BASE_PATH}/api/config`);
    if (!res.ok) {
        throw new Error("Failed to load app config");
    }
    const cfg = await res.json();
    API = cfg.basePath || "";
    viewOnlyMode = !!cfg.view_only;
    isLocalConnection = cfg.is_local !== false;
    if (viewOnlyMode) {
        console.log("[Config] view_only = true (remote connection detected)");
    }
    if (cfg.broadcast_interval) {
        const parsedInterval = parseInt(cfg.broadcast_interval, 10);
        if (!isNaN(parsedInterval) && parsedInterval >= 1 && parsedInterval <= 3600) {
            currentInterval = parsedInterval;
            localStorage.setItem("refreshInterval", currentInterval.toString());
			console.log(`Loaded broadcast interval from server: ${currentInterval}s`);
        } else {
            console.warn(`Invalid broadcast interval from server: ${cfg.broadcast_interval}`);
        }
    }
    if (cfg.offline_ping_interval) {
        const offlinePingInterval = parseFloat(cfg.offline_ping_interval);
        if (!isNaN(offlinePingInterval) && offlinePingInterval >= 10 && offlinePingInterval <= 86400) {
            localStorage.setItem("offlinePingInterval", offlinePingInterval.toString());
            console.log(`Loaded offline ping interval from server: ${offlinePingInterval}s`);
        } else {
            console.warn(`Invalid offline ping interval from server: ${cfg.offline_ping_interval}`);
        }
    }
    if (cfg.offline_threshold) {
        const offlineThreshold = parseFloat(cfg.offline_threshold);
        if (!isNaN(offlineThreshold) && offlineThreshold >= 30 && offlineThreshold <= 86400) {
            localStorage.setItem("offlineThreshold", offlineThreshold.toString());
            console.log(`Loaded offline threshold from server: ${offlineThreshold}s`);
        } else {
            console.warn(`Invalid offline threshold from server: ${cfg.offline_threshold}`);
        }
    }
    if (cfg.ws_push_min_interval !== undefined && cfg.ws_push_min_interval !== null) {
        const wsPushInput = document.getElementById("ws-push-min-interval");
        if (wsPushInput) wsPushInput.value = cfg.ws_push_min_interval;
    }
    if (cfg.missed_refresh_threshold !== undefined && cfg.missed_refresh_threshold !== null) {
        const missedRefreshInput = document.getElementById("missed-refresh-threshold");
        if (missedRefreshInput) missedRefreshInput.value = cfg.missed_refresh_threshold;
    }
    if (cfg.notification_settings) {
        localStorage.setItem("notificationSettings", JSON.stringify(cfg.notification_settings));
        console.log("Loaded notification settings from server:", cfg.notification_settings);
    }
    return cfg;
}
function initAfterConfig() {
    console.log('Initializing WebSocket connection...');
    if (wsInitialized) {
        console.log('WebSocket already initialized');
        return;
    }
    wsInitialized = true;
    fetchStatusLogCounts();
    fetchStatusLogSeverity();
    setTimeout(function() {
        initWebSocket();
    }, 500);
}
function hasPositiveRate(hs) {
    return typeof hs === "number" && hs > 0;
}
function pickHashrateUnitForChart(maxHs) {
    if (!maxHs || maxHs <= 0) return { unit: "H/s", divisor: 1 };
    if (maxHs >= HASHRATE_UNIT_MULTIPLIERS["TH/s"]) return { unit: "TH/s", divisor: HASHRATE_UNIT_MULTIPLIERS["TH/s"] };
    if (maxHs >= HASHRATE_UNIT_MULTIPLIERS["GH/s"]) return { unit: "GH/s", divisor: HASHRATE_UNIT_MULTIPLIERS["GH/s"] };
    if (maxHs >= HASHRATE_UNIT_MULTIPLIERS["MH/s"]) return { unit: "MH/s", divisor: HASHRATE_UNIT_MULTIPLIERS["MH/s"] };
    if (maxHs >= HASHRATE_UNIT_MULTIPLIERS["KH/s"]) return { unit: "kH/s", divisor: HASHRATE_UNIT_MULTIPLIERS["KH/s"] };
    return { unit: "H/s", divisor: 1 };
}
function fmtRateHs(totalHs, label) {
    if (!totalHs || totalHs <= 0) {
        return null;
    }
    if (totalHs >= HASHRATE_UNIT_MULTIPLIERS["PH/s"]) {
        return `${(totalHs / HASHRATE_UNIT_MULTIPLIERS["PH/s"]).toFixed(2)} PH/s ${label}`;
    }
    if (totalHs >= HASHRATE_UNIT_MULTIPLIERS["TH/s"]) {
        return `${(totalHs / HASHRATE_UNIT_MULTIPLIERS["TH/s"]).toFixed(2)} TH/s ${label}`;
    }
    if (totalHs >= HASHRATE_UNIT_MULTIPLIERS["GH/s"]) {
        return `${(totalHs / HASHRATE_UNIT_MULTIPLIERS["GH/s"]).toFixed(2)} GH/s ${label}`;
    }
    if (totalHs >= HASHRATE_UNIT_MULTIPLIERS["MH/s"]) {
        return `${(totalHs / HASHRATE_UNIT_MULTIPLIERS["MH/s"]).toFixed(2)} MH/s ${label}`;
    }
    if (totalHs >= HASHRATE_UNIT_MULTIPLIERS["KH/s"]) {
        return `${(totalHs / HASHRATE_UNIT_MULTIPLIERS["KH/s"]).toFixed(2)} kH/s ${label}`;
    }
    return `${totalHs.toFixed(0)} H/s ${label}`;
}
function stripAnsi(str) {
    if (!str) return str;
    return str.replace(
        /[\u001b\u009b][[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]/g,
        ""
    );
}
function stripBlankLines(text) {
    if (!text) return text;
    return text
        .split("\n")
        .filter((line) => line.trim() !== "")
        .join("\n");
}
function fmtShareCount(n) {
    // Share/block counts can climb well past 1M on long-uptime rigs (keryx-style block
    // counting especially) - past 6 digits, switch to a K/M/B/T short form (same convention
    // as the hashrate formatters below) so the stat tile stays a fixed, glanceable width
    // instead of pushing other panel content around. Exact counts are still available in the
    // surrounding tooltip/title text wherever one exists.
    if (typeof n !== "number" || !isFinite(n)) return n;
    const abs = Math.abs(n);
    if (abs < 1e6) return String(n);
    const units = [[1e12, "T"], [1e9, "B"], [1e6, "M"]];
    for (const [unitValue, suffix] of units) {
        if (abs >= unitValue) return (n / unitValue).toFixed(2) + suffix;
    }
    return String(n);
}
function fmtShares(accepted, rejected) {
    if (accepted === undefined && rejected === undefined) return "--";
    if (accepted !== undefined && rejected !== undefined) {
        return `${fmtShareCount(accepted)}/${fmtShareCount(rejected)}`;
    }
    if (accepted !== undefined) {
        return fmtShareCount(accepted);
    }
    return "--";
}
function fmtXmrig(hs) {
    return hs > 0
        ? `${(hs / HASHRATE_UNIT_MULTIPLIERS["KH/s"]).toFixed(1)} kH/s`
        : null;
}
function fmtUptime(sec) {
    if (!sec || sec <= 0) return "--";
    sec = Math.floor(sec);
    const d = Math.floor(sec / 86400);
    const h = Math.floor((sec % 86400) / 3600);
    const m = Math.floor((sec % 3600) / 60);
    if (d > 0) return `${d}d ${h}h`;
    if (h > 0) return `${h}h ${m}m`;
    return `${m}m`;
}
function escapeHtml(str) {
    return String(str)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;");
}
function naturalCompare(a, b) {
    const ax = [], bx = [];
    a.replace(/(\d+)|(\D+)/g, (_, $1, $2) => {
        ax.push([$1 || Infinity, $2 || ""]);
    });
    b.replace(/(\d+)|(\D+)/g, (_, $1, $2) => {
        bx.push([$1 || Infinity, $2 || ""]);
    });
    while (ax.length && bx.length) {
        const an = ax.shift();
        const bn = bx.shift();
        const nn = (an[0] - bn[0]) || an[1].localeCompare(bn[1]);
        if (nn) return nn;
    }
    return ax.length - bx.length;
}
function formatLocalDateForInput(date) {
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, "0");
    const d = String(date.getDate()).padStart(2, "0");
    return `${y}-${m}-${d}`;
}
function stableColorForName(name) {
    let hash = 0;
    for (let i = 0; i < name.length; i++) {
        hash = (hash * 31 + name.charCodeAt(i)) | 0;
    }
    return STATS_CHART_COLORS[Math.abs(hash) % STATS_CHART_COLORS.length];
}
function statsTimestampToLocalLabel(ts) {
    if (!ts) return ts;
    const iso = ts.replace(" ", "T") + "Z";
    const d = new Date(iso);
    if (isNaN(d.getTime())) return ts;
    const pad = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} `
         + `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
}
function startDateInputToIso(startDateStr) {
    const now = new Date();
    const hh = String(now.getHours()).padStart(2, "0");
    const mm = String(now.getMinutes()).padStart(2, "0");
    const ss = String(now.getSeconds()).padStart(2, "0");
    return new Date(`${startDateStr}T${hh}:${mm}:${ss}`).toISOString();
}
function formatStatsRangeLabel(startDateStr, days) {
    const start = new Date(`${startDateStr}T00:00:00`);
    const lastDayIncluded = new Date(start);
    lastDayIncluded.setDate(lastDayIncluded.getDate() + days - 1);
    const fmt = (d) => d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
    return days === 1 ? fmt(start) : `${fmt(start)} - ${fmt(lastDayIncluded)}`;
}
function scheduleRender() {
    if (renderScheduled) return;
    renderScheduled = true;
    requestAnimationFrame(() => {
        render();
        renderScheduled = false;
    });
}
function getWebSocketUrl() {
    const proto = location.protocol === "https:" ? "wss://" : "ws://";
    return proto + location.host + `${API}/ws`;
}
function initWebSocket() {
    if (ws && ws.readyState === WebSocket.OPEN) {
        console.log('WebSocket already connected, skipping reconnection');
        return;
    }
    if (ws && (ws.readyState === WebSocket.CLOSING || ws.readyState === WebSocket.CLOSED)) {
        console.log('Closing stale WebSocket connection');
        ws.close();
        ws = null;
    }
    if (wsReconnectTimer) {
        clearTimeout(wsReconnectTimer);
        wsReconnectTimer = null;
    }
    const wsUrl = getWebSocketUrl();
    console.log(`WebSocket: Connecting to ${wsUrl}`);
    try {
        ws = new WebSocket(wsUrl);
        ws.onopen = function() {
            console.log('WebSocket: Connected');
            if (wsReconnectTimer) {
                clearTimeout(wsReconnectTimer);
                wsReconnectTimer = null;
            }
        };
        ws.onmessage = function(event) {
            try {
                const msg = JSON.parse(event.data);
                if (msg.cmd_response) {
                    handleCommandResponse(msg.cmd_response);
                    return;
                }
                if (msg.stats_response) {
                    handleStatsResponse(msg.stats_response);
                    return;
                }
                if (msg.stats_response_progress) {
                    handleStatsResponseProgress(msg.stats_response_progress);
                    return;
                }
                if (msg.status_log_event) {
                    showStatusLogLink(msg.status_log_event);
                    const evtRig = msg.status_log_event?.rig;
                    if (evtRig) {
                        statusLogCounts[evtRig] = (statusLogCounts[evtRig] || 0) + 1;
                        // Same [CRITICAL]/[WARN] title tag regex as renderStatusLogList() - updates
                        // the badge instantly instead of waiting on the next fetchStatusLogSeverity()
                        // poll. Only ever flips flags on (matches the DB being append-only here);
                        // a full refetch after delete/clear is what can turn them back off.
                        const evtSevMatch = /\[(WARN|CRITICAL)\]/.exec(msg.status_log_event?.title || "");
                        if (evtSevMatch) {
                            const sev = statusLogSeverityByRig[evtRig] || (statusLogSeverityByRig[evtRig] = {});
                            if (evtSevMatch[1] === "CRITICAL") sev.critical = true;
                            else sev.warn = true;
                        }
                        queueRender();
                        refreshStatusLogRigSelectIfOpen();
                    }
                    if (!document.getElementById("statuslog-modal")?.classList.contains("hidden")) {
                        loadStatusLogList();
                    }
                    return;
                }
                if (msg.rigs) {
                    processRigsSnapshot(msg.rigs);
                    return;
                }
				if (msg.interval_changed) {
                    handleIntervalChangeNotification(msg);
                    return;
                }
                if (msg.offline_threshold_changed) {
                    handleOfflineThresholdChangeNotification(msg);
                    return;
                }
                if (msg.offline_ping_interval_changed) {
                    handleOfflinePingIntervalChangeNotification(msg);
                    return;
                }
                console.warn('WebSocket: Unexpected message format:', Object.keys(msg));
            } catch (e) {
                console.error('WebSocket: Parse error:', e);
            }
        };
        ws.onclose = function(event) {
            console.log(`WebSocket: Disconnected (code: ${event.code})`);
            if (event.code !== 1000 && event.code !== 1001 && event.code !== 1005) {
                wsReconnectTimer = setTimeout(function() {
                    console.log('WebSocket: Attempting to reconnect...');
                    initWebSocket();
                }, 3000);
            }
        };
        ws.onerror = function(error) {
            console.error('WebSocket: Error:', error);
        };
    } catch (error) {
        console.error('WebSocket: Failed to create connection:', error);
        wsReconnectTimer = setTimeout(function() {
            console.log('WebSocket: Retrying after error...');
            initWebSocket();
        }, 3000);
    }
}
function processRigsSnapshot(newRigsData) {
    rigsState = newRigsData;
    lastUpdateTs = Date.now() / 1000;
    renderLastUpdateTs();
    queueRender();
}
function renderLastUpdateTs() {
    const el = document.getElementById("last-update-ts");
    if (!el || !lastUpdateTs) return;
    const d = new Date(lastUpdateTs * 1000);
    el.textContent = `Updated ${d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })}`;
}
function queueRender() {
    renderQueue.push(Date.now());
    if (!isProcessingQueue) {
        processRenderQueue();
    }
}
function processRenderQueue() {
    isProcessingQueue = true;
    const latestTimestamp = Math.max(...renderQueue);
    const now = Date.now();
    renderQueue = [];
    setTimeout(function() {
        if (Date.now() - latestTimestamp < 150) {
            render();
        }
        isProcessingQueue = false;
        if (renderQueue.length > 0) {
            processRenderQueue();
        }
    }, 100);
}
function isCmdModuleVisible() {
    const modal = document.getElementById("cmd-modal");
    if (!modal) return false;
    const style = window.getComputedStyle(modal);
    const isDisplayVisible = style.display !== "none";
    const hasVisibleClass = modal.classList.contains("visible");
    return isDisplayVisible || hasVisibleClass;
}
function handleCommandResponse(response) {
    const r = response;
    if (pendingLogsFetchRig && r.rig === pendingLogsFetchRig) {
        pendingLogsFetchRig = null;
        const out = document.getElementById("logs-output");
        const statusEl = document.getElementById("logs-status");
        if (out) {
            let text = "";
            if (r.stdout) text += stripAnsi(r.stdout).replace(/^\[RAW EXECUTION\]\r?\n/, "");
            if (r.stderr) text += (text ? "\n" : "") + stripAnsi(r.stderr);
            logsRawText = stripBlankLines(text) || "";
            const typeSelect = document.getElementById("logs-type-select");
            const currentType = typeSelect ? typeSelect.value : "";
            const preserveScroll = LOGS_TYPES_PRESERVE_SCROLL.has(currentType);
            applyLogsFilter(preserveScroll);
        }
        if (statusEl) {
            statusEl.textContent = `returncode=${r.returncode} · last refreshed ${new Date().toLocaleTimeString()}`;
        }
        return;
    }
    if (pendingWdConfigFetchRig && r.rig === pendingWdConfigFetchRig) {
        pendingWdConfigFetchRig = null;
        const statusEl = document.getElementById("wdconfig-status");
        if (r.returncode === 0 && r.stdout && r.stdout.trim()) {
            // r.stdout here is the literal `cat` output of the conf file on the rig - i.e. the bare
            // body, no wrapper - so wrap it the same way rebuildWdRawFromSettings() does before
            // displaying it, to keep "loaded from rig" and "rebuilt from fields" showing the same
            // full-command shape instead of one being wrapped and the other not.
            const raw = stripAnsi(r.stdout).replace(/^\[RAW EXECUTION\]\r?\n/, "");
            const rawEl = document.getElementById("wdconfig-raw");
            if (rawEl) rawEl.value = wrapWdConfigCommand(raw);
            populateWdSettingsFromRaw(raw);
            autoResizeWdRaw();
            if (statusEl) statusEl.textContent = `Loaded current config from ${r.rig}`;
        } else {
            if (statusEl) statusEl.textContent = `No existing config found on ${r.rig} (using defaults)`;
        }
        return;
    }
    if (pendingAgentConfFetchRig && r.rig === pendingAgentConfFetchRig) {
        pendingAgentConfFetchRig = null;
        const statusEl = document.getElementById("agentconf-status");
        const confType = selectedConfEditType;
        const confLabel = LOGS_TYPE_LABELS[confType] || confType;
        if (r.returncode === 0 && r.stdout && r.stdout.trim()) {
            // raw here is the literal `cat` output - the bare file body, no wrapper - so wrap it
            // for display the same way loadDefaultConfEditTemplate()/the checkbox handler do, but
            // keep saving the BARE raw to the DB Backups snapshot below (agent.conf only - that
            // wants the file's actual contents, not the send-command shape).
            const raw = stripAnsi(r.stdout).replace(/^\[RAW EXECUTION\]\r?\n/, "");
            const rawEl = document.getElementById("agentconf-raw");
            const includeRestart = document.getElementById("agentconf-restart-after-apply")?.checked ?? false;
            if (rawEl) rawEl.value = wrapConfEditCommand(confType, raw, includeRestart);
            resizeAgentConfRaw();
            if (statusEl) statusEl.textContent = `Loaded current ${confLabel} from ${r.rig}`;
            if (CONF_EDIT_TYPES[confType]?.isAgent) saveAgentConfSnapshot(r.rig, raw);
        } else {
            // Clear the box instead of leaving whatever was previously loaded sitting there - with
            // the type dropdown now able to switch between six different files, stale content left
            // over from the last successful load would otherwise look like it belongs to this
            // rig/type when it doesn't exist here at all.
            const rawEl = document.getElementById("agentconf-raw");
            if (rawEl) rawEl.value = "";
            resizeAgentConfRaw();
            if (statusEl) statusEl.textContent = `No existing ${confLabel} found on ${r.rig}${CONF_EDIT_TYPES[confType]?.isAgent ? " (click Clear for a blank example)" : ""}`;
        }
        return;
    }
    let responseText = `\n[${r.rig}] returncode=${r.returncode}\n`;
    if (r.stdout) responseText += stripAnsi(r.stdout) + "\n";
    if (r.stderr) responseText += stripAnsi(r.stderr) + "\n";
    responseText = stripBlankLines(responseText);
    if (isCmdModuleVisible()) {
        const cmdOutput = document.getElementById("cmd-output");
        if (cmdOutput) {
            cmdOutput.textContent += responseText;
        }
    } else {
        const row = document.createElement("div");
        row.className = "action-output-row cmd-response-row";
        row.textContent = responseText;
        prependActionOutputRow(row);
    }
}
function cleanupWebSocket() {
    console.log('Cleaning up WebSocket...');
    wsInitialized = false;
    if (ws) {
        ws.onopen = null;
        ws.onmessage = null;
        ws.onclose = null;
        ws.onerror = null;
        if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
            ws.close();
        }
        ws = null;
    }
    if (wsReconnectTimer) {
        clearTimeout(wsReconnectTimer);
        wsReconnectTimer = null;
    }
}
const COLUMN_TELEMETRY_GROUPS = {
    1: "cpu_temp",   
    2: "cpu_usage",  
    3: "load",       
    4: "memory",     
    5: "uptime",     
    6: "gpu",        
    7: "gpu",        
    8: "gpu",        
    9: "gpu",        
    10: "gpu",       
    11: "gpu",       
    12: "gpu",       
    13: "gpu",       
    14: "miner",     
    15: "docker",    
};
const ALWAYS_VISIBLE_TELEMETRY_GROUPS = ["cpu_service", "gpu_service", "aux_service", "watchdog_service"];
function getVisibleTelemetryGroups() {
    const allGroups = new Set(Object.values(COLUMN_TELEMETRY_GROUPS));
    const hiddenGroups = new Set();
    Object.entries(COLUMN_TELEMETRY_GROUPS).forEach(([indexStr, group]) => {
        if (!hiddenColumns.has(Number(indexStr))) {
            hiddenGroups.delete(group);
        }
    });
    allGroups.forEach((group) => {
        const columnsForGroup = Object.entries(COLUMN_TELEMETRY_GROUPS)
            .filter(([, g]) => g === group)
            .map(([indexStr]) => Number(indexStr));
        const allHidden = columnsForGroup.every((idx) => hiddenColumns.has(idx));
        if (allHidden) hiddenGroups.add(group);
    });
    const visible = Array.from(allGroups).filter((g) => !hiddenGroups.has(g));
    ALWAYS_VISIBLE_TELEMETRY_GROUPS.forEach((g) => {
        if (!visible.includes(g)) visible.push(g);
    });
    return visible;
}
async function syncTelemetryColumnsToServer() {
    try {
        const visibleGroups = getVisibleTelemetryGroups();
        await fetch(`${API}/api/telemetry-columns`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ visible_groups: visibleGroups })
        });
    } catch (e) {
        console.error("Failed to sync visible telemetry columns to server", e);
    }
}
function setupHeaderClickHandlers() {
    const headerGrid = document.querySelector('.rig-header-grid');
    if (!headerGrid) return;
    const nameHeader = headerGrid.children[0];
    if (nameHeader) {
        const nameText = nameHeader.textContent.replace('⟳', '').trim();
        nameHeader.innerHTML = `
            <span class="reset-btn" id="btn-reset" title="Hard reset workers">⟳</span>
            <span class="name-header-text">${nameText}</span>
        `;
        const nameTextSpan = nameHeader.querySelector('.name-header-text');
        if (nameTextSpan) {
            nameTextSpan.style.cursor = 'pointer';
            nameTextSpan.title = 'Click to show all hidden columns';
            nameTextSpan.addEventListener('click', (e) => {
                e.stopPropagation();
                resetAllHiddenColumns();
            });
        }
    }
    Array.from(headerGrid.children).forEach((cell, index) => {
        if (index > 0 && index < headerGrid.children.length - 1) {
            cell.style.cursor = 'pointer';
            cell.title = 'Click to hide/show column';
            cell.addEventListener('click', () => toggleColumnVisibility(index));
            if (hiddenColumns.has(index)) {
                cell.classList.add('column-hidden');
                cell.style.opacity = '0.5';
            }
        }
    });
}
function resetAllHiddenColumns() {
    if (hiddenColumns.size === 0) return;
    hiddenColumns.clear();
    const headerGrid = document.querySelector('.rig-header-grid');
    const rigRows = document.querySelectorAll('.rig-row .rig-main');
    if (headerGrid) {
        Array.from(headerGrid.children).forEach((cell, index) => {
            cell.classList.remove('column-hidden');
            cell.style.opacity = '1';
        });
    }
    rigRows.forEach(row => {
        Array.from(row.children).forEach(cell => {
            cell.classList.remove('column-hidden');
        });
    });
    localStorage.removeItem('hiddenColumns');
    syncTelemetryColumnsToServer();
    triggerManualRefresh();
    console.log('All columns reset');
}
function toggleColumnVisibility(columnIndex) {
    const headerGrid = document.querySelector('.rig-header-grid');
    if (!headerGrid) return;
    if (hiddenColumns.has(columnIndex)) {
        hiddenColumns.delete(columnIndex);
        showColumn(columnIndex);
    } else {
        hiddenColumns.add(columnIndex);
        hideColumn(columnIndex);
    }
    saveColumnState();
}
function saveColumnState() {
    localStorage.setItem('hiddenColumns', JSON.stringify(Array.from(hiddenColumns)));
    syncTelemetryColumnsToServer();
}
function loadColumnState() {
    const saved = localStorage.getItem('hiddenColumns');
    if (saved) {
        try {
            const state = JSON.parse(saved);
            hiddenColumns.clear();
            state.forEach(col => {
                if (col >= 1 && col <= 16) {
                    hiddenColumns.add(col);
                }
            });
            console.log('Loaded hidden columns:', Array.from(hiddenColumns));
        } catch(e) {
            console.error('Failed to load column state:', e);
            localStorage.removeItem('hiddenColumns');
        }
    }
}
function applyHiddenColumnsToDOM() {
    const headerGrid = document.querySelector('.rig-header-grid');
    const rigRows = document.querySelectorAll('.rig-row .rig-main');
    if (!headerGrid) return;
    Array.from(headerGrid.children).forEach((cell, index) => {
        if (hiddenColumns.has(index)) {
            cell.classList.add('column-hidden');
            cell.style.opacity = '0.5';
        } else {
            cell.classList.remove('column-hidden');
            cell.style.opacity = '1';
        }
    });
    rigRows.forEach(row => {
        Array.from(row.children).forEach((cell, index) => {
            if (hiddenColumns.has(index)) {
                cell.classList.add('column-hidden');
            } else {
                cell.classList.remove('column-hidden');
            }
        });
    });
    console.log('Hidden columns applied:', Array.from(hiddenColumns));
}
function applyHeaderVisibility() {
    const headerGrid = document.querySelector('.rig-header-grid');
    if (!headerGrid) return;
    Array.from(headerGrid.children).forEach((cell, index) => {
        if (hiddenColumns.has(index)) {
            cell.classList.add('column-hidden');
            cell.style.opacity = '0.5';
        } else {
            cell.classList.remove('column-hidden');
            cell.style.opacity = '1';
        }
    });
}
function showColumn(columnIndex) {
    const headerGrid = document.querySelector('.rig-header-grid');
    if (headerGrid && headerGrid.children[columnIndex]) {
        headerGrid.children[columnIndex].classList.remove('column-hidden');
        headerGrid.children[columnIndex].style.opacity = '1';
    }
    document.querySelectorAll('.rig-row .rig-main').forEach(row => {
        if (row.children[columnIndex]) {
            row.children[columnIndex].classList.remove('column-hidden');
        }
    });
}
function hideColumn(columnIndex) {
    const headerGrid = document.querySelector('.rig-header-grid');
    if (headerGrid && headerGrid.children[columnIndex]) {
        headerGrid.children[columnIndex].classList.add('column-hidden');
        headerGrid.children[columnIndex].style.opacity = '0.5';
    }
    document.querySelectorAll('.rig-row .rig-main').forEach(row => {
        if (row.children[columnIndex]) {
            row.children[columnIndex].classList.add('column-hidden');
        }
    });
}
function rigMatchesSearch(rigName) {
    if (!rigSearchQuery) return true;
    const terms = rigSearchQuery.split(",").map(t => t.trim()).filter(Boolean);
    if (terms.length === 0) return true;
    const lowerName = rigName.toLowerCase();
    return terms.some(term => lowerName.includes(term));
}
function getVisibleRigNames() {
    return Object.keys(rigsState)
        .filter(name => name !== "rigs")
        .filter(rigMatchesSearch);
}
function render() {
    if (resetInProgress) return;
    const container = document.getElementById("rig-container");
    container.innerHTML = "";
    const rigNames = getVisibleRigNames().sort();
    const shouldLog = rigNames.length > 0;
    rigNames.forEach(rigName => {
        const entry = rigsState[rigName];
        const d = entry.data ?? {};
        const safeId = rigName.replace(/[^a-zA-Z0-9_-]/g, "_");
        const open = popoverState[safeId] === true;
        const activeMiners = DataHelper.getActiveMiners(d);
        const cpuTemp = DataHelper.getCpuTemp(d);
        const cpuTempFormatted = DataHelper.getFormattedTemp(cpuTemp, "cpu");
        const cpuTempStr = cpuTempFormatted.value;
        const cpuTempClass = cpuTempFormatted.class;
        const cpuUtil = DataHelper.getCpuUsage(d);
        const load1 = DataHelper.getLoad(d, "1m");
        const load5 = DataHelper.getLoad(d, "5m");
        const load15 = DataHelper.getLoad(d, "15m");
        const memory = DataHelper.getMemory(d);
        const ramStr = memory.string;
        const systemUptime = DataHelper.getSystemUptime(d);
        const uptimeFormatted = DataHelper.getFormattedSystemUptime(systemUptime);
        const uptimeStr = uptimeFormatted?.value || "--";
        const uptimeClass = uptimeFormatted?.class || "uptime-unknown";
        const gpuAgg = DataHelper.getGpuAggregate(d);
        const gpuTempFormatted = DataHelper.getFormattedTemp(gpuAgg.temp, "gpu");
        const gpuTempStr = gpuTempFormatted.value;
        const gpuTempClass = gpuTempFormatted.class;
        const gpuMemTempFormatted = DataHelper.getFormattedTemp(gpuAgg.memTemp, "gpu_mem");
        const gpuMemTempStr = gpuMemTempFormatted.value;
        const gpuMemTempClass = gpuMemTempFormatted.class;
        const gpuUtil = gpuAgg.util;
        const gpuPower = gpuAgg.power > 0 ? gpuAgg.power.toFixed(0) : "--"; 
        const gpuFan = gpuAgg.fan;
        const fanFormatted = DataHelper.getFormattedFan(gpuFan);
        const fanClass = fanFormatted.class;
        const coreMHz = gpuAgg.coreClock;
        const memMHz = gpuAgg.memClock;
        const vram = gpuAgg.vram;
        const vramGB = vram.string;
        const cpuService = DataHelper.getServiceStatus(d, "cpu_service");
        const cpuServiceFormatted = DataHelper.getFormattedService(cpuService);
        const cpuServiceClass = cpuServiceFormatted.class;
        const gpuService = DataHelper.getServiceStatus(d, "gpu_service");
        const gpuServiceFormatted = DataHelper.getFormattedService(gpuService);
        const gpuServiceClass = gpuServiceFormatted.class;
        const auxService = DataHelper.getServiceStatus(d, "aux_service");
        const watchdogActive = DataHelper.getServiceStatus(d, "watchdog_service").isActive;
        const dockerList = DataHelper.getDockerContainers(d);
        const watchdogStandingDown = watchdogActive &&
            (dockerList.length > 0 || (!cpuService.isActive && !gpuService.isActive && !auxService.isActive));
        let dockerLeft = `<div class="docker-header">Docker Containers (${dockerList.length})</div>`;
        if (dockerList.length === 0) {
            dockerLeft += "<div style='padding: 10px; color: var(--text-muted); font-style: italic;'>No containers</div>";
        } else {
            dockerList.forEach(container => {
                dockerLeft += `
                    <div class="docker-container">
                        <div class="docker-name-row">${container.name}</div>
                        <div class="docker-details-grid">
                            <div class="docker-detail-item">
                                <div class="docker-detail-label">Image</div>
                                <div class="docker-detail-value image">${container.image}</div>
                            </div>
                            <div class="docker-detail-item">
                                <div class="docker-detail-label">Uptime</div>
                                <div class="docker-detail-value uptime">${fmtUptime(container.uptime_seconds)}</div>
                            </div>
                        </div>
                    </div>`;
            });
        }
        let minerRight = "";
        const minerSummary = DataHelper.getMinerSummary(d);
        const minersByType = {};
        minerSummary.forEach(miner => {
            const key = `${miner.miner}|${miner.version}|${miner.cudaDriver}`;
            if (!minersByType[key]) {
                minersByType[key] = {
                    name: miner.miner,
                    version: miner.version,
                    cudaDriver: miner.cudaDriver,
                    rigName: miner.rigName,
                    uptime: miner.uptime,
                    algorithms: [],
                    totalHashrate: 0,
                    totalAccepted: 0,
                    totalRejected: 0,
                    totalInvalid: 0,
                    totalStale: 0
                };
            }
            minersByType[key].algorithms.push({
                name: miner.algorithm,
                hashrate: miner.hashrate,
                formattedHashrate: miner.formattedHashrate,
                pool: miner.pool,
                accepted: miner.accepted,
                rejected: miner.rejected,
                invalid: miner.invalid,
                stale: miner.stale,
                miningType: miner.miningType,
                threadCount: miner.threadCount,
                difficulty: miner.difficulty,
                poolStatus: miner.poolStatus,
                poolLatency: miner.poolLatency
            });
            minersByType[key].totalHashrate += miner.hashrate;
            minersByType[key].totalAccepted += miner.accepted;
            minersByType[key].totalRejected += miner.rejected;
            minersByType[key].totalInvalid += miner.invalid;
            minersByType[key].totalStale += miner.stale;
        });
        const isCpuAlgo = (alg) => alg.miningType === "CPU";
        const sortedMinersByType = Object.values(minersByType).sort((a, b) => {
            const aCpu = a.algorithms.some(isCpuAlgo) ? 0 : 1;
            const bCpu = b.algorithms.some(isCpuAlgo) ? 0 : 1;
            return aCpu - bCpu;
        });
        sortedMinersByType.forEach(minerInfo => {
            const minerDisplayName = `${minerInfo.name} ${DataHelper.getFormattedVersion(minerInfo.version)}`;
            const totalShares = minerInfo.totalAccepted + minerInfo.totalRejected + minerInfo.totalInvalid + minerInfo.totalStale;
            const sharesFormatted = DataHelper.getFormattedShares(
                minerInfo.totalAccepted,
                minerInfo.totalRejected,
                minerInfo.totalInvalid,
                minerInfo.totalStale
            );
            let specialSections = "";
            if (minerInfo.name === "BzMiner") {
                const minerData = DataHelper.getMiner(d, "miner_bzminer");
                const totalDevices = DataHelper.getMinerTotalDevices(minerData);
                const bzCudaDriver = DataHelper.getCudaDriverVersion(minerData);
                if (totalDevices > 0) {
                    specialSections += `<div class="miner-stat-item">
                        <div class="stat-label">DEVICES</div>
                        <div class="stat-value">${totalDevices}</div>
                    </div>`;
                }
                if (bzCudaDriver && bzCudaDriver !== "--") {
                    specialSections += `<div class="miner-stat-item">
                        <div class="stat-label">CUDA</div>
                        <div class="stat-value">${DataHelper.getFormattedDriver(bzCudaDriver)}</div>
                    </div>`;
                }
            }
            else if (minerInfo.name === "TeamRedMiner") {
                const minerData = DataHelper.getMiner(d, "miner_teamredminer");
                const algorithms = DataHelper.getMinerAlgorithms(d, "miner_teamredminer");
                let totalHardwareErrors = 0;
                let avgUtility = 0;
                if (algorithms.length > 0) {
                    totalHardwareErrors = algorithms.reduce((sum, algo) =>
                        sum + DataHelper.getHardwareErrors(algo), 0);
                    const utilities = algorithms.map(algo => DataHelper.getUtility(algo)).filter(u => u !== null);
                    avgUtility = utilities.length > 0 ?
                        utilities.reduce((sum, u) => sum + u, 0) / utilities.length : 0;
                }
                if (totalHardwareErrors > 0) {
                    specialSections += `<div class="miner-stat-item">
                        <div class="stat-label">HARDWARE ERRORS</div>
                        <div class="stat-value error">${totalHardwareErrors}</div>
                    </div>`;
                }
                if (avgUtility > 0) {
                    specialSections += `<div class="miner-stat-item">
                        <div class="stat-label">AVG UTILITY</div>
                        <div class="stat-value">${avgUtility.toFixed(2)}</div>
                    </div>`;
                }
            }
            else if (minerInfo.name === "SRBMiner") {
                let cpuHashrateTotal = 0;
                let gpuHashrateTotal = 0;
                let totalThreads = 0;
                minerInfo.algorithms.forEach(algo => {
                    const minerData = DataHelper.getMiner(d, "miner_srbminer");
                    const algorithms = DataHelper.getMinerAlgorithms(d, "miner_srbminer");
                    algorithms.forEach(srbAlgo => {
                        cpuHashrateTotal += DataHelper.getCpuHashrateHS(srbAlgo);
                        gpuHashrateTotal += DataHelper.getGpuHashrateHS(srbAlgo);
                        const threadHashrates = DataHelper.getThreadHashrates(srbAlgo);
                        totalThreads += Object.keys(threadHashrates).length;
                    });
                });
                if (cpuHashrateTotal > 0) {
                    specialSections += `<div class="miner-stat-item">
                        <div class="stat-label">CPU HASHRATE</div>
                        <div class="stat-value">${fmtRateHs(cpuHashrateTotal, "")}</div>
                    </div>`;
                }
                if (gpuHashrateTotal > 0) {
                    specialSections += `<div class="miner-stat-item">
                        <div class="stat-label">GPU HASHRATE</div>
                        <div class="stat-value">${fmtRateHs(gpuHashrateTotal, "")}</div>
                    </div>`;
                }
                if (totalThreads > 0) {
                    specialSections += `<div class="miner-stat-item">
                        <div class="stat-label">CPU THREADS</div>
                        <div class="stat-value">${totalThreads} threads</div>
                    </div>`;
                }
            }
            else if (minerInfo.name === "XMRig") {
                let totalThreads = 0;
                minerInfo.algorithms.forEach(algo => {
                    totalThreads += algo.threadCount || 0;
                });
                if (totalThreads > 0) {
                    specialSections += `<div class="miner-stat-item">
                        <div class="stat-label">CPU THREADS</div>
                        <div class="stat-value">${totalThreads} threads</div>
                    </div>`;
                }
            }
            let algorithmDisplay = "";
            minerInfo.algorithms.forEach((algo, index) => {
                const difficultyInfo = algo.difficulty > 0 ?
                    `<span class="difficulty" title="Current Difficulty">Diff: ${algo.difficulty.toLocaleString()}</span>` : "";
                const latencyInfo = algo.poolLatency ?
                    `<span class="latency" title="Pool Latency">${algo.poolLatency}ms</span>` : "";
                algorithmDisplay += `
                    <div class="algorithm-row">
                        <div class="algorithm-name">${algo.name}</div>
                        <div class="algorithm-stats">
                            <span class="hashrate">${algo.formattedHashrate}</span>
                            ${difficultyInfo}
                            ${latencyInfo}
                        </div>
                    </div>`;
            });
            const uniquePools = [...new Set(minerInfo.algorithms.map(a => a.pool).filter(p => p))];
            const poolsDisplay = uniquePools.length > 0 ?
                `<div class="miner-stat-item">
                    <div class="stat-label">POOLS</div>
                    <div class="stat-value pools">${uniquePools.map(p =>
                        `<span class="pool-tag" title="${p}">${p.split('.')[0]}</span>`
                    ).join('')}</div>
                </div>` : "";
            minerRight += `
               <div class="miner-row-horizontal">
                    <div class="miner-name-row">${minerDisplayName}</div>
                    <div class="miner-details-compact">
                         <div class="miner-stat-item">
                              <div class="stat-label">TOTAL HASHRATE</div>
                              <div class="stat-value">${fmtRateHs(minerInfo.totalHashrate, "")}</div>
                         </div>
                         ${specialSections}
                         <div class="miner-stat-item">
                              <div class="stat-label">ALGORITHMS</div>
                              <div class="stat-value algorithms">
                                   <div class="algorithms-list">
                                        ${algorithmDisplay}
                                   </div>
                              </div>
                         </div>
                         <div class="miner-stat-item">
                              <div class="stat-label">SHARES</div>
                              <div class="stat-value shares ${sharesFormatted.class}"
                                   title="Accepted: ${minerInfo.totalAccepted} | Rejected: ${minerInfo.totalRejected} | Invalid: ${minerInfo.totalInvalid} | Stale: ${minerInfo.totalStale} (${sharesFormatted.rejectionRate} rejection)">
                                   ${fmtShareCount(minerInfo.totalAccepted)}/${fmtShareCount(minerInfo.totalRejected)}
                              </div>
                         </div>
                         <div class="miner-stat-item pool">
                              <div class="stat-label">POOL</div>
                              <div class="stat-value" title="${minerInfo.algorithms.map(a => a.pool).filter(p => p).join(', ') || 'No pool connected'}">
                                   ${(() => {
                                        const pools = minerInfo.algorithms.map(a => a.pool).filter(p => p && p !== "unknown");
                                        return pools.length === 0 ? '--' : pools[0];
                                   })()}
                              </div>
                         </div>
                         <div class="miner-stat-item">
                              <div class="stat-label">UPTIME</div>
                              <div class="stat-value">${fmtUptime(minerInfo.uptime)}</div>
                         </div>
                    </div>
               </div>`;
        });
        const rowMinerSummary = [];
        sortedMinersByType.forEach(minerInfo => {
            if (minerInfo.totalHashrate > 0) {
                if (minerInfo.name === "SRBMiner") {
                    let cpuHashrateTotal = 0;
                    let gpuHashrateTotal = 0;
                    const srbAlgorithms = DataHelper.getMinerAlgorithms(d, "miner_srbminer");
                    srbAlgorithms.forEach(algo => {
                        cpuHashrateTotal += DataHelper.getCpuHashrateHS(algo);
                        gpuHashrateTotal += DataHelper.getGpuHashrateHS(algo);
                    });
                    const parts = [];
                    if (cpuHashrateTotal > 0) {
                        parts.push(`CPU ${fmtRateHs(cpuHashrateTotal, "")}`);
                    }
                    if (gpuHashrateTotal > 0) {
                        parts.push(`GPU ${fmtRateHs(gpuHashrateTotal, "")}`);
                    }
                    if (parts.length > 0) {
                        rowMinerSummary.push(`SRBMiner ${parts.join(" | ")}`);
                    }
                } else if (minerInfo.name === "XMRig") {
                    rowMinerSummary.push(`${fmtXmrig(minerInfo.totalHashrate)} XMRig`);
                } else {
                    rowMinerSummary.push(`${fmtRateHs(minerInfo.totalHashrate, "")} ${minerInfo.name}`);
                }
            }
        });
        const finalMinerSummary = rowMinerSummary.filter(Boolean).join(" | ");
        const nvidiaDriver = DataHelper.getNvidiaDriverVersion(d);
        if (nvidiaDriver && nvidiaDriver !== "--") {
            if (minerRight !== "") {
                minerRight =
                    `<div class="docker-header">Miners - NVIDIA DRIVER ${DataHelper.getFormattedDriver(nvidiaDriver)}</div>` +
                    minerRight;
            }
        } else {
            if (minerRight !== "") {
                minerRight =
                    `<div class="docker-header">Miners</div>` +
                    minerRight;
            }
        }
        const row = document.createElement("div");
        row.className = "rig-row";
        if (selectedRigs.has(rigName)) {
            row.classList.add("selected");
        }
        const mainWrap = document.createElement("div");
        mainWrap.className = "rig-main-wrap";
        const selectCb = document.createElement("input");
        selectCb.type = "checkbox";
        selectCb.className = "rig-select-checkbox";
        selectCb.title = "Select worker";
        selectCb.dataset.rigName = rigName;
        selectCb.checked = selectedRigs.has(rigName);
        mainWrap.appendChild(selectCb);
        const main = document.createElement("div");
        main.className = "rig-main";
        const nameEl = document.createElement("div");
        nameEl.className = "rig-name";
        const gpus = DataHelper.getGpus(d);
        let boardPartner = gpus.length === 1 ? (gpus[0]?.board_partner || "") : "";
        if (boardPartner.includes("NVIDIA") && boardPartner.includes("(")) {
            boardPartner = boardPartner.split("(")[1]?.replace(")", "") || "";
        }
        const rigStatusLogCount = statusLogCounts[rigName] || 0;
        if (rigStatusLogCount > 0) {
            const statusLogBadge = document.createElement("span");
            statusLogBadge.className = "rig-status-log-badge";
            statusLogBadge.textContent = rigStatusLogCount > 99 ? "99+" : String(rigStatusLogCount);
            statusLogBadge.title = `${rigStatusLogCount} status log ${rigStatusLogCount === 1 ? "entry" : "entries"} - click to view`;
            statusLogBadge.addEventListener("click", (ev) => {
                ev.stopPropagation();
                openStatusLogForRig(rigName);
            });
            updateStatusLogBadgeClass(statusLogBadge, rigName);
            nameEl.appendChild(statusLogBadge);
        }
        const nameTextEl = document.createElement("span");
        nameTextEl.textContent = rigName + (boardPartner ? " " + boardPartner : "");
        nameEl.appendChild(nameTextEl);
        nameEl.dataset.rigName = rigName;
        nameEl.classList.toggle("rig-name-watchdog-active", watchdogActive && !watchdogStandingDown);
        nameEl.classList.toggle("rig-name-watchdog-standby", watchdogStandingDown);
        let nameTitle = "";
        const gpuInfoTooltip = DataHelper.getGpuInfoTooltip(gpus);
        if (gpuInfoTooltip) {
            nameTitle = gpuInfoTooltip;
        }
        if (nameTitle) {
            nameEl.title = nameTitle;
        }
        main.appendChild(nameEl);
        mainWrap.appendChild(main);
        row.appendChild(mainWrap);
        const cpuColumn = DataHelper.getCpuColumnContent(d);
        const gpuColumn = DataHelper.getGpuColumnContent(d);
        const auxColumn = DataHelper.getAuxColumnContent(d);
        const columnHTMLs = [
            `<div class="metric"><span class="${cpuTempClass}">${cpuTempStr}</span></div>`,
            `<div class="metric">${cpuUtil}</div>`,
            `<div class="metric">${load1} / ${load5} / ${load15}</div>`,
            `<div class="metric">${ramStr}</div>`,
            `<div class="metric"><span class="${uptimeClass}">${uptimeStr}</span></div>`,
            `<div class="metric"><span class="${gpuTempClass}">${gpuTempStr}</span></div>`,
            `<div class="metric"><span class="${gpuMemTempClass}">${gpuMemTempStr}</span></div>`,
            `<div class="metric">${gpuUtil}</div>`,
            `<div class="metric">${gpuPower}</div>`,
            `<div class="metric"><span class="${fanClass}">${gpuFan}</span></div>`,
            `<div class="metric">${vramGB}</div>`,
            `<div class="metric">${coreMHz}</div>`,
            `<div class="metric">${memMHz}</div>`,
            `<div class="metric">${cpuColumn.html}<span class="cpu-gpu-col-sep">|</span>${gpuColumn.html}<span class="cpu-gpu-col-sep">|</span>${auxColumn.html}</div>`,
            `<div class="metric">${dockerList.length}</div>`,
            `<div class="metric metric-left">${finalMinerSummary}</div>`
        ];
        main.insertAdjacentHTML("beforeend", columnHTMLs.join(''));
        for (let colIndex = 1; colIndex <= 16; colIndex++) {
            const cell = main.children[colIndex];
            if (cell && hiddenColumns.has(colIndex)) {
                cell.classList.add('column-hidden');
            }
        }
        let gpuPaneHtml = "";
        if (gpus.length === 0) {
            gpuPaneHtml = `<div class="docker-header">GPUs (${gpus.length})</div>`;
            gpuPaneHtml += "<div style='padding: 10px; color: var(--text-muted); font-style: italic;'>No GPU data</div>";
        } else if (gpus.length > 1) {
            gpuPaneHtml = `<div class="docker-header">GPUs (${gpus.length})</div>`;
            const gpuHashrateMap = DataHelper.getGpuHashrateMap(d);
            const gpuAcceptedMap = DataHelper.getGpuAcceptedSharesMap(d);
            const gpuRejectedMap = DataHelper.getGpuRejectedSharesMap(d);
            gpuPaneHtml += `<table class="gpu-table"><thead><tr>
                <th>#</th><th>Name</th><th>Vendor</th><th>Hashrate</th><th>Temp</th><th>Mem°</th><th>Util</th><th>Power</th><th>Fan</th><th>VRAM</th><th>Core</th><th>Mem</th><th>Shares</th>
            </tr></thead><tbody>`;
            gpus.forEach((gpu, idx) => {
                const gpuIndex = gpu.index ?? idx;
                const gpuTempFmt = DataHelper.getFormattedTemp(DataHelper.getGpuTemp(gpu), "gpu");
                const gpuMemTempFmt = DataHelper.getFormattedTemp(DataHelper.getGpuMemTemp(gpu), "gpu_mem");
                const gpuFanFmt = DataHelper.getFormattedFan(DataHelper.getGpuFan(gpu));
                const gpuVram = DataHelper.getGpuVram(gpu);
                const gpuHr = gpuHashrateMap[gpuIndex];
                const gpuHrStr = (typeof gpuHr === "number" && gpuHr > 0)
                    ? fmtRateHs(gpuHr, "").trim()
                    : "--";
                const gpuAccepted = gpuAcceptedMap[gpuIndex];
                const gpuRejected = gpuRejectedMap[gpuIndex];
                const gpuSharesStr = fmtShares(gpuAccepted, gpuRejected);
                const gpuSharesClass = (typeof gpuAccepted === "number" || typeof gpuRejected === "number")
                    ? DataHelper.getFormattedShares(gpuAccepted || 0, gpuRejected || 0).class
                    : "status-unknown";
                gpuPaneHtml += `
                    <tr>
                        <td>${gpuIndex}</td>
                        <td class="gpu-name-cell">${DataHelper.getGpuName(gpu)}</td>
                        <td class="gpu-vendor-cell">${DataHelper.getGpuVendor(gpu)}</td>
                        <td class="gpu-hashrate-cell">${gpuHrStr}</td>
                        <td class="${gpuTempFmt.class}">${gpuTempFmt.value}</td>
                        <td class="${gpuMemTempFmt.class}">${gpuMemTempFmt.value}</td>
                        <td>${DataHelper.getGpuUtil(gpu)}</td>
                        <td>${DataHelper.getGpuPower(gpu)}</td>
                        <td class="${gpuFanFmt.class}">${gpuFanFmt.value}</td>
                        <td>${gpuVram.string || "--"}</td>
                        <td>${DataHelper.getGpuCoreClock(gpu)}</td>
                        <td>${DataHelper.getGpuMemClock(gpu)}</td>
                        <td class="${gpuSharesClass}">${gpuSharesStr}</td>
                    </tr>`;
            });
            gpuPaneHtml += `</tbody></table>`;
            // Some miners (e.g. keryx-miner-supr) only ever report accepted/rejected shares in
            // AGGREGATE, never broken out per device - on a multi-GPU rig every row above then has
            // no per-GPU number to show (gpuAcceptedMap/gpuRejectedMap stay empty), which used to
            // just look like "shares reporting is broken" for that miner rather than "this miner's
            // API doesn't support per-GPU attribution". If NO GPU got a per-device number but the
            // miner-level total is non-zero, show that total once instead of leaving every row blank.
            if (Object.keys(gpuAcceptedMap).length === 0 && Object.keys(gpuRejectedMap).length === 0) {
                let totalAccepted = 0, totalRejected = 0, haveTotal = false;
                DataHelper.getAllAlgorithms(d).forEach(algo => {
                    totalAccepted += DataHelper.getAcceptedShares(algo);
                    totalRejected += DataHelper.getRejectedShares(algo);
                    haveTotal = true;
                });
                if (haveTotal && (totalAccepted > 0 || totalRejected > 0)) {
                    const totalStr = fmtShares(totalAccepted, totalRejected);
                    const totalClass = DataHelper.getFormattedShares(totalAccepted, totalRejected).class;
                    gpuPaneHtml += `<div class="gpu-shares-aggregate-note">Shares (aggregate, not reported per-GPU by this miner): <span class="${totalClass}">${totalStr}</span></div>`;
                }
            }
        }
        const gpuPaneSection = gpuPaneHtml
            ? `<div class="pop-gpus">${gpuPaneHtml}</div>`
            : "";
        const pop = document.createElement("div");
        pop.id = `docker-${safeId}`;
        pop.className = "docker-popover";
        pop.style.display = open ? "flex" : "none";
        pop.addEventListener("click", ev => ev.stopPropagation());
        pop.innerHTML = `
            <div class="pop-content">
                <div class="pop-docker">
                    ${dockerLeft}
                </div>
                <div class="pop-miners">
                    ${minerRight ? `<div class="pop-miners-inner">${minerRight}</div>` : ""}
                </div>
            </div>
            ${gpuPaneSection}
        `;
        row.appendChild(pop);
        container.appendChild(row);
    });
    updateSelectButton();
    updateActionStats();
    applyHeaderVisibility();
    autoSizeRigColumns();
    const ts = new Date().toISOString().replace('T', ' ').substring(0, 19);
    if (shouldLog) {
        console.log('✅ Render complete ' + ts + ' - ' + rigNames.length + ' rigs');
    } else {
        console.log('🔄 No rigs to render ' + ts);
    }
    syncOpenModulesToSelection();
}
const RIG_AUTOSIZE_COL_START = 1;
const RIG_AUTOSIZE_COL_END = 16;
const RIG_AUTOSIZE_PADDING_PX = 6; 
function autoSizeRigColumns() {
    const headerGrid = document.querySelector('.rig-header-grid');
    if (!headerGrid) return;
    if (headerGrid.offsetParent === null) return;
    const rows = document.querySelectorAll('.rig-main');
    for (let i = RIG_AUTOSIZE_COL_START; i <= RIG_AUTOSIZE_COL_END; i++) {
        const headerCell = headerGrid.children[i];
        if (headerCell) {
            headerCell.style.flex = "0 1 auto";
            headerCell.style.width = "auto";
            headerCell.style.minWidth = "0";
        }
        rows.forEach(row => {
            const cell = row.children[i];
            if (cell) {
                cell.style.flex = "0 1 auto";
                cell.style.width = "auto";
                cell.style.minWidth = "0";
            }
        });
    }
    for (let i = RIG_AUTOSIZE_COL_START; i <= RIG_AUTOSIZE_COL_END; i++) {
        const headerCell = headerGrid.children[i];
        if (!headerCell || hiddenColumns.has(i)) continue;
        let maxWidth = headerCell.scrollWidth;
        rows.forEach(row => {
            const cell = row.children[i];
            if (cell && !cell.classList.contains('column-hidden')) {
                maxWidth = Math.max(maxWidth, cell.scrollWidth);
            }
        });
        const finalWidth = maxWidth + RIG_AUTOSIZE_PADDING_PX;
        const flexValue = `0 0 ${finalWidth}px`;
        headerCell.style.flex = flexValue;
        headerCell.style.width = `${finalWidth}px`;
        headerCell.style.minWidth = `${finalWidth}px`;
        rows.forEach(row => {
            const cell = row.children[i];
            if (!cell) return;
            cell.style.flex = flexValue;
            cell.style.width = `${finalWidth}px`;
            cell.style.minWidth = `${finalWidth}px`;
        });
    }
}
function expandAllOpenModules() {
    const pairs = [
        ["fs-modal", null],
        ["oc-modal", null],
        ["stats-modal", null],
        ["wdconfig-modal", null],
        ["statuslog-modal", null],
        ["color-scheme-modal", "btn-color-scheme-collapse"],
    ];
    let anyOpen = false;
    pairs.forEach(([modalId, btnId]) => {
        const modal = document.getElementById(modalId);
        if (!modal || modal.classList.contains("hidden")) return;
        anyOpen = true;
        const btn = document.getElementById(btnId);
        if (modal.classList.contains("row-collapsed")) {
            modal.classList.remove("row-collapsed");
            btn?.classList.remove("active");
            if (btn) btn.textContent = "Collapse";
        }
    });
    return anyOpen;
}
function setupRigEventDelegation() {
    const container = document.getElementById("rig-container");
    if (!container) return;
    const newContainer = container.cloneNode(false);
    if (container.parentNode) {
        container.parentNode.replaceChild(newContainer, container);
    }
    let lastRigNameClick = { name: null, time: 0 };
    newContainer.addEventListener("click", (ev) => {
        const cbEl = ev.target.closest(".rig-select-checkbox");
        if (cbEl) {
            ev.stopPropagation();
            const rigNameForCb = cbEl.dataset.rigName;
            if (!rigNameForCb) return;
            if (selectedRigs.has(rigNameForCb)) {
                selectedRigs.delete(rigNameForCb);
            } else {
                selectedRigs.add(rigNameForCb);
            }
            render();
            return;
        }
        const nameEl = ev.target.closest(".rig-name");
        if (nameEl) {
            const rigNameForDblCheck = nameEl.dataset.rigName;
            const now = Date.now();
            const isDoubleClick =
                rigNameForDblCheck &&
                rigNameForDblCheck === lastRigNameClick.name &&
                now - lastRigNameClick.time < 400;
            lastRigNameClick = { name: rigNameForDblCheck, time: now };
            if (isDoubleClick) {
                ev.stopPropagation();
                ev.preventDefault();
                lastRigNameClick = { name: null, time: 0 };
                const anyModuleOpen = expandAllOpenModules();
                if (!anyModuleOpen) {
                    openStatsModal();
                }
                return;
            }
            const rigName = nameEl.dataset.rigName;
            if (!rigName) return;
            ev.stopPropagation();
            ev.preventDefault();
            if (ev.shiftKey || ev.ctrlKey || ev.metaKey) {
                if (selectedRigs.has(rigName)) {
                    selectedRigs.delete(rigName);
                } else {
                    selectedRigs.add(rigName);
                }
            } else {
                if (selectedRigs.has(rigName)) {
                    selectedRigs.delete(rigName);
                } else {
                    selectedRigs.clear();
                    selectedRigs.add(rigName);
                }
            }
            render();
            return;
        }
        const mainEl = ev.target.closest(".rig-main");
        if (mainEl) {
            const isNameClick = ev.target.closest(".rig-name");
            if (isNameClick) return;
            const nameElInside = mainEl.querySelector(".rig-name");
            const rigName = nameElInside?.dataset.rigName;
            if (!rigName) return;
            const safeId = rigName.replace(/[^a-zA-Z0-9_-]/g, "_");
            popoverState[safeId] = !popoverState[safeId];
            render();
        }
    });
}
function updateActionStats() {
    const statsBar = document.getElementById("action-stats-bar");
    if (!statsBar) return;
    let totalWatts = 0;
    let totalGpuCount = 0;
    let activeDockerCount = 0;
    const runningDockerEntries = new Map();
    let miningCpuRigs = 0;
    let miningGpuRigs = 0;
    let activeCpuServiceRigs = 0;
    let activeGpuServiceRigs = 0;
    let activeAuxServiceRigs = 0;
    const auxActiveEntries = [];
    const algoTotals = {};
    const algoIsCpu = {};
    const algoShares = {};
    const rigNames = (selectedRigs.size > 0
        ? Array.from(selectedRigs)
        : Object.keys(rigsState).filter(n => n !== "rigs")
    ).filter(name => !rigsState[name]?.data?.exclude_from_totals);
    rigNames.forEach(name => {
        const d = rigsState[name]?.data;
        if (!d) return;
        totalGpuCount += DataHelper.getGpuCount(d);
        const dockerContainers = DataHelper.getDockerContainers(d);
        if (dockerContainers.length > 0) activeDockerCount++;
        dockerContainers.forEach(c => {
            if (c && c.name && c.image) {
                const key = `${c.name}: ${c.image}`;
                runningDockerEntries.set(key, (runningDockerEntries.get(key) || 0) + 1);
            }
        });
        totalWatts += DataHelper.getTotalGpuPower(d);
        const algorithms = DataHelper.getAllAlgorithms(d);
        let rigHasActiveCpuMiner = false;
        let rigHasActiveGpuMiner = false;
        algorithms.forEach(algo => {
            const algoName = DataHelper.getAlgorithmName(algo);
            const hashrate = DataHelper.getTotalHashrateHS(algo);
            if (hashrate > 0) {
                if (!algoTotals[algoName]) {
                    algoTotals[algoName] = 0;
                }
                algoTotals[algoName] += hashrate;
                if (!algoShares[algoName]) {
                    algoShares[algoName] = { accepted: 0, rejected: 0 };
                }
                algoShares[algoName].accepted += DataHelper.getAcceptedShares(algo) || 0;
                algoShares[algoName].rejected += DataHelper.getRejectedShares(algo) || 0;
                const mtype = DataHelper.getMiningType(algo);
                if (mtype === "CPU") {
                    algoIsCpu[algoName] = true;
                    rigHasActiveCpuMiner = true;
                } else if (mtype === "GPU") {
                    rigHasActiveGpuMiner = true;
                }
            }
        });
        if (rigHasActiveCpuMiner) miningCpuRigs++;
        if (rigHasActiveGpuMiner) miningGpuRigs++;
        if (DataHelper.getServiceStatus(d, "cpu_service").isActive) activeCpuServiceRigs++;
        if (DataHelper.getServiceStatus(d, "gpu_service").isActive) activeGpuServiceRigs++;
        const auxService = DataHelper.getServiceStatus(d, "aux_service");
        if (auxService.isActive) {
            activeAuxServiceRigs++;
            auxActiveEntries.push(`${name} (${auxService.name || "unknown service"})`);
        }
    });
    const sortedAlgos = Object.keys(algoTotals).sort((a, b) => {
        const aCpu = algoIsCpu[a] ? 0 : 1;
        const bCpu = algoIsCpu[b] ? 0 : 1;
        if (aCpu !== bCpu) return aCpu - bCpu;
        return algoTotals[b] - algoTotals[a];
    });
    const panels = [];
    panels.push(`
        <div class="stat-panel" id="stat-workers-panel">
            <div class="stat-panel-value" id="stat-workers">${rigNames.length}</div>
            <div class="stat-panel-label">Workers</div>
        </div>
    `);
    panels.push(`
        <div class="stat-panel" id="stat-gpu-count-panel">
            <div class="stat-panel-value" id="stat-gpu-count">${totalGpuCount}</div>
            <div class="stat-panel-label">GPU</div>
        </div>
    `);
    const dockerTooltip = runningDockerEntries.size > 0
        ? `Running containers:\n${Array.from(runningDockerEntries.entries())
            .sort((a, b) => a[0].localeCompare(b[0]))
            .map(([entry, count]) => `${entry} (${count})`)
            .join("\n")}`
        : "No containers running";
    panels.push(`
        <div class="stat-panel" id="stat-docker-count-panel" title="${escapeHtml(dockerTooltip)}">
            <div class="stat-panel-value" id="stat-docker-count">${activeDockerCount}</div>
            <div class="stat-panel-label">Docker</div>
        </div>
    `);
    panels.push(`
        <div class="stat-panel" id="stat-cpu-services-panel" title="Mining / Active Service">
            <div class="stat-panel-value" id="stat-cpu-services">${miningCpuRigs} / ${activeCpuServiceRigs}</div>
            <div class="stat-panel-label">CPU Services</div>
        </div>
    `);
    panels.push(`
        <div class="stat-panel" id="stat-gpu-services-panel" title="Mining / Active Service">
            <div class="stat-panel-value" id="stat-gpu-services">${miningGpuRigs} / ${activeGpuServiceRigs}</div>
            <div class="stat-panel-label">GPU Services</div>
        </div>
    `);
    const auxTooltip = auxActiveEntries.length > 0
        ? `Active AUX Service:\n${auxActiveEntries.sort().join("\n")}`
        : "No AUX service active";
    panels.push(`
        <div class="stat-panel" id="stat-aux-services-panel" title="${escapeHtml(auxTooltip)}">
            <div class="stat-panel-value" id="stat-aux-services">${activeAuxServiceRigs}</div>
            <div class="stat-panel-label">AUX Services</div>
        </div>
    `);
    panels.push(`
        <div class="stat-panel" id="stat-gpu-watts-panel">
            <div class="stat-panel-value" id="stat-gpu-watts">${totalWatts > 0 ? totalWatts.toFixed(1) : "--"}</div>
            <div class="stat-panel-label">GPU Watts</div>
        </div>
    `);
    sortedAlgos.forEach(algoName => {
        const totalHashrate = algoTotals[algoName];
        if (totalHashrate <= 0) return;
        const shares = algoShares[algoName] || { accepted: 0, rejected: 0 };
        panels.push(`
            <div class="stat-panel" title="Accepted/Rejected: ${shares.accepted}/${shares.rejected}">
                <div class="stat-panel-value">${fmtRateHs(totalHashrate, "")}</div>
                <div class="stat-panel-label">${escapeHtml(algoName)}</div>
            </div>
        `);
    });
    statsBar.innerHTML = panels.join("");
}
function getSelectAllEligibleRigNames() {
    return getVisibleRigNames().filter(name => !rigsState[name]?.data?.exclude_from_totals);
}
function updateSelectButton() {
    const btn = document.getElementById("btn-toggle-select");
    const eligible = getSelectAllEligibleRigNames();
    const allSelected = eligible.length > 0 && eligible.every(name => selectedRigs.has(name));
    if (btn) {
        btn.textContent = allSelected ? "☑" : "☐";
    }
    const headerCb = document.getElementById("rig-select-all-checkbox");
    if (headerCb) {
        headerCb.checked = allSelected;
        headerCb.indeterminate = !allSelected && eligible.some(name => selectedRigs.has(name));
    }
}
function setActionMode(mode) {
    if (!["all", "cpu", "gpu", "aux"].includes(mode)) return;
    currentActionMode = mode;
    localStorage.setItem("actionMode", mode);
    document.querySelectorAll(".action-tab").forEach(btn => {
        btn.classList.toggle("active", btn.dataset.mode === mode);
    });
    document.getElementById("btn-wd-enable")?.classList.toggle("active", wdEnabled);
    setActionOutput(`Mode: ${mode.toUpperCase()}`);
}
function toggleWdEnabled() {
    wdEnabled = !wdEnabled;
    document.getElementById("btn-wd-enable")?.classList.toggle("active", wdEnabled);
    setActionOutput(
        wdEnabled
            ? "Watchdog control ON - Start/Stop/Restart now control the watchdog service"
            : "Watchdog control OFF - Start/Stop/Restart back to controlling miners"
    );
}
function prependActionOutputRow(rowEl) {
    const el = document.getElementById("action-output");
    if (!el || !rowEl) return;
    const stamp = document.createElement("span");
    stamp.className = "action-output-timestamp";
    stamp.textContent = new Date().toLocaleTimeString();
    rowEl.insertBefore(stamp, rowEl.firstChild);
    el.insertBefore(rowEl, el.firstChild);
    const rows = el.querySelectorAll(".action-output-row");
    if (rows.length > MAX_ACTION_OUTPUT_ROWS) {
        for (let i = MAX_ACTION_OUTPUT_ROWS; i < rows.length; i++) {
            rows[i].remove();
        }
    }
}
function setActionOutput(text) {
    const row = document.createElement("div");
    row.className = "action-output-row single-line";
    row.textContent = text;
    prependActionOutputRow(row);
}
function showStatusLogLink(evt) {
    if (!evt) return;
    const row = document.createElement("div");
    row.className = "action-output-row single-line status-log-link-row";
    const link = document.createElement("a");
    link.href = "#";
    link.className = "status-log-link";
    link.textContent = evt.title || `${evt.rig || "unknown"}: watchdog status changed`;
    link.title = "Open Status Log";
    link.addEventListener("click", (e) => {
        e.preventDefault();
        openStatusLogModal(evt.id);
    });
    row.appendChild(link);
    prependActionOutputRow(row);
}
function setCmdOutput(text) {
    const cmd = document.getElementById("cmd-output");
    if (!cmd) return;
    cmd.textContent = text;
}
function getActionsForMode() {
    switch (currentActionMode) {
        case "cpu":
            return ["cpu"];
        case "gpu":
            return ["gpu"];
        case "aux":
            return ["aux"];
        case "all":
            return ["cpu", "gpu"];
        default:
            return [];
    }
}
function toggleSelectAll() {
    const rigNames = getSelectAllEligibleRigNames();
    if (rigNames.length === 0) return;
    const eligible = rigNames.filter(name => {
        const d = rigsState[name]?.data ?? {};
        const cpuActive = d.cpu_service?.state === "active";
        const gpuActive = d.gpu_service?.state === "active";
        const auxActive = d.aux_service?.state === "active";
        if (currentActionMode === "all") return true;
        if (currentActionMode === "cpu") {
            return cpuActive;
        }
        if (currentActionMode === "gpu") {
            return gpuActive;
        }
        if (currentActionMode === "aux") {
            return auxActive;
        }
    });
    if (eligible.length === 0) return;
    const allSelected = eligible.every(name => selectedRigs.has(name));
    if (allSelected) {
        eligible.forEach(name => selectedRigs.delete(name));
    } else {
        eligible.forEach(name => selectedRigs.add(name));
    }
    scheduleRender();
}
function toggleSelectAllRows() {
    const eligible = getSelectAllEligibleRigNames();
    if (eligible.length === 0) return;
    const allSelected = eligible.every(name => selectedRigs.has(name));
    if (allSelected) {
        eligible.forEach(name => selectedRigs.delete(name));
    } else {
        eligible.forEach(name => selectedRigs.add(name));
    }
    scheduleRender();
}
function getSendConfirmPref(key) {
    const v = localStorage.getItem(`sendConfirm_${key}`);
    return v === null ? true : v === "1";
}
function setSendConfirmPref(key, checked) {
    localStorage.setItem(`sendConfirm_${key}`, checked ? "1" : "0");
}
function initSendConfirmCheckbox(id, key) {
    const cb = document.getElementById(id);
    if (!cb) return;
    cb.checked = getSendConfirmPref(key);
    cb.addEventListener("change", () => setSendConfirmPref(key, cb.checked));
}
function confirmAction(actionLabel) {
    const count = selectedRigs.size;
    if (count === 0) {
        alert("No workers selected");
        return false;
    }
    return window.confirm(
        `${actionLabel} on ${count} selected worker${count !== 1 ? "s" : ""}?`
    );
}
function setResetButtonDisabled(disabled) {
    const btn = document.querySelector(".reset-btn");
    if (!btn) return;
    btn.classList.toggle("disabled", disabled);
    btn.style.pointerEvents = disabled ? "none" : "auto";
}
function toggleDocker(id) {
    popoverState[id] = !popoverState[id];
    scheduleRender();
}
function stopClick(ev) { ev.stopPropagation(); }
let cmdModalRigOverride = null;
function openCmdModal() {
    document.getElementById("cmd-target-count").textContent =
        (cmdModalRigOverride && cmdModalRigOverride.length) ? cmdModalRigOverride.length : selectedRigs.size;
    const input = document.getElementById("cmd-input");
    const out = document.getElementById("cmd-output");
    if (out) out.textContent = "";
    document.getElementById("cmd-modal")?.classList.remove("hidden");
    loadSavedCommands();
    input.focus();
}
function closeCmdModal() {
    document.getElementById("cmd-modal").classList.add("hidden");
    cmdModalRigOverride = null;
}
function isLogsModuleVisible() {
    const modal = document.getElementById("logs-modal");
    return !!modal && !modal.classList.contains("hidden");
}
function getLogsTargetRig() {
    const sel = document.getElementById("logs-rig-select");
    return sel && sel.value ? sel.value : null;
}
function populateLogsRigSelect() {
    const sel = document.getElementById("logs-rig-select");
    if (!sel) return;
    const prevValue = sel.value;
    const rigNames = Object.keys(rigsState || {})
        .filter(name => name !== "rigs")
        .sort();
    sel.innerHTML = "";
    rigNames.forEach((name) => {
        const opt = document.createElement("option");
        opt.value = name;
        opt.textContent = name;
        sel.appendChild(opt);
    });
    if (selectedRigs && selectedRigs.size === 1) {
        const [only] = selectedRigs;
        if (rigNames.includes(only)) {
            sel.value = only;
            return;
        }
    }
    if (rigNames.includes(prevValue)) {
        sel.value = prevValue;
    }
}
function openLogsModal() {
    populateLogsRigSelect();
    const rig = getLogsTargetRig();
    if (!rig) {
        alert("No workers available to view logs for");
        return;
    }
    lastSyncedLogsRig = rig;
    document.getElementById("logs-modal")?.classList.remove("hidden");
    requestAnimationFrame(syncLogsFilterWidth);
    fetchLogs();
    if (document.getElementById("logs-auto-refresh-checkbox")?.checked) {
        startLogsAutoRefresh();
    }
}
function closeLogsModal() {
    document.getElementById("logs-modal")?.classList.add("hidden");
    stopLogsAutoRefresh();
    pendingLogsFetchRig = null;
}
function applyLogsFilter(preserveScroll) {
    const out = document.getElementById("logs-output");
    if (!out) return;
    const term = document.getElementById("logs-filter-input")?.value.trim() || "";
    let text = logsRawText;
    if (term) {
        const needle = term.toLowerCase();
        text = logsRawText
            .split("\n")
            .filter(line => line.toLowerCase().includes(needle))
            .join("\n");
    }
    const prevScrollTop = out.scrollTop;
    out.value = text || (term ? "(no matching lines)" : "(empty)");
    out.scrollTop = preserveScroll ? prevScrollTop : out.scrollHeight;
}
function syncLogsFilterWidth() {
    const input = document.getElementById("logs-filter-input");
    const toolbar = document.querySelector("#logs-modal .logs-toolbar");
    const upArrow = document.getElementById("btn-logs-interval-up");
    if (!input || !toolbar || !upArrow) return;
    const toolbarRect = toolbar.getBoundingClientRect();
    const upArrowRect = upArrow.getBoundingClientRect();
    if (!toolbarRect.width || !upArrowRect.width) return;
    const width = Math.round(upArrowRect.right - toolbarRect.left);
    if (width > 0) input.style.width = `${width}px`;
}
function fetchLogs() {
    const rig = getLogsTargetRig();
    const statusEl = document.getElementById("logs-status");
    if (!rig) {
        if (statusEl) statusEl.textContent = "Select a worker";
        return;
    }
    const type = document.getElementById("logs-type-select")?.value || "gpu.log";
    let lines = parseInt(document.getElementById("logs-lines-input")?.value, 10);
    if (!Number.isFinite(lines) || lines < 10) lines = 200;
    lines = Math.min(Math.max(lines, 10), 5000);
    const linesInput = document.getElementById("logs-lines-input");
    if (linesInput) linesInput.value = lines;
    pendingLogsFetchRig = rig;
    if (statusEl) statusEl.textContent = `Loading ${LOGS_TYPE_LABELS[type] || type}...`;
    const builder = LOGS_COMMAND_BUILDERS[type] || LOGS_COMMAND_BUILDERS["gpu.log"];
    fetch(`${API}/command`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ rigs: [rig], command: builder(lines) })
    }).catch(err => {
        console.error("Log fetch failed", err);
        if (statusEl) statusEl.textContent = "Failed to send request";
        pendingLogsFetchRig = null;
    });
}
function startLogsAutoRefresh() {
    stopLogsAutoRefresh();
    let secs = parseInt(document.getElementById("logs-interval-input")?.value, 10);
    if (!Number.isFinite(secs) || secs < 2) secs = 10;
    logsAutoRefreshTimer = setInterval(() => {
        if (!isLogsModuleVisible()) {
            stopLogsAutoRefresh();
            return;
        }
        fetchLogs();
    }, secs * 1000);
}
function stopLogsAutoRefresh() {
    if (logsAutoRefreshTimer) {
        clearInterval(logsAutoRefreshTimer);
        logsAutoRefreshTimer = null;
    }
}
function handleLogsAutoRefreshToggle() {
    const cb = document.getElementById("logs-auto-refresh-checkbox");
    if (cb?.checked) {
        startLogsAutoRefresh();
    } else {
        stopLogsAutoRefresh();
    }
}
function adjustLogsInterval(delta) {
    const input = document.getElementById("logs-interval-input");
    if (!input) return;
    const cur = parseInt(input.value, 10) || 10;
    const next = Math.max(2, Math.min(300, cur + delta));
    input.value = next;
    localStorage.setItem("rigcontrol_logs_interval", String(next));
    if (document.getElementById("logs-auto-refresh-checkbox")?.checked) {
        startLogsAutoRefresh();
    }
}
function updateLogsLinesFieldVisibility() {
    const type = document.getElementById("logs-type-select")?.value;
    const linesInput = document.getElementById("logs-lines-input");
    const linesField = linesInput?.closest(".logs-lines-field");
    const disable = LOGS_TYPES_WITHOUT_LINES.has(type);
    if (linesInput) linesInput.disabled = disable;
    if (linesField) linesField.classList.toggle("logs-lines-field-disabled", disable);
}
function restoreLogsPrefs() {
    const typeSel = document.getElementById("logs-type-select");
    const linesInput = document.getElementById("logs-lines-input");
    const intervalInput = document.getElementById("logs-interval-input");
    const autoCb = document.getElementById("logs-auto-refresh-checkbox");
    const savedType = localStorage.getItem("rigcontrol_logs_type");
    if (savedType && typeSel && Array.from(typeSel.options).some(o => o.value === savedType)) {
        typeSel.value = savedType;
    }
    const savedLines = localStorage.getItem("rigcontrol_logs_lines");
    if (savedLines && linesInput) linesInput.value = savedLines;
    const savedInterval = localStorage.getItem("rigcontrol_logs_interval");
    if (savedInterval && intervalInput) intervalInput.value = savedInterval;
    if (localStorage.getItem("rigcontrol_logs_auto") === "1" && autoCb) {
        autoCb.checked = true;
    }
    const filterInput = document.getElementById("logs-filter-input");
    const savedFilter = localStorage.getItem("rigcontrol_logs_filter");
    if (savedFilter && filterInput) filterInput.value = savedFilter;
    updateLogsLinesFieldVisibility();
}
function getSavedCommandName() {
    const el = document.getElementById("saved-cmd-name");
    if (!el) return "";
    return el.value
        .trim()
        .toLowerCase()
        .replace(/\s+/g, "-")
        .replace(/[^a-z0-9\-]/g, "");
}
async function loadSavedCommands() {
    try {
        const res = await fetch(`${API}/api/saved-commands`);
        if (!res.ok) {
            console.error("Failed to load saved commands");
            return;
        }
        savedCommands = await res.json();
        renderSavedCommandsList();
    } catch (e) {
        console.error("Error loading saved commands:", e);
    }
}
function renderSavedCommandsList() {
    const list = document.getElementById("saved-cmd-list");
    if (!list) return;
    list.innerHTML = "";
    const sorted = [...savedCommands].sort((a, b) =>
        naturalCompare(a.CommandId, b.CommandId)
    );
    for (const c of sorted) {
        const row = document.createElement("div");
        row.className = "fs-item";
        row.textContent = c.CommandId;
        row.dataset.id = c.CommandId;
        row.dataset.value = c.Value || "";
        row.addEventListener("click", () => {
            document
                .querySelectorAll("#saved-cmd-list .fs-item.selected")
                .forEach(e => e.classList.remove("selected"));
            row.classList.add("selected");
            selectedSavedCommandId = c.CommandId;
            document.getElementById("saved-cmd-name").value = c.CommandId;
            document.getElementById("cmd-input").value = c.Value || "";
        });
        list.appendChild(row);
    }
    filterSavedCommandsList();
}
function filterSavedCommandsList() {
    const query = (document.getElementById("saved-cmd-search")?.value || "").trim().toLowerCase();
    document.querySelectorAll("#saved-cmd-list .fs-item").forEach(item => {
        const match = !query || item.textContent.toLowerCase().includes(query);
        item.style.display = match ? "" : "none";
    });
}
function collectSavedCommandEntries() {
    const raw = document.getElementById("cmd-input").value.trim();
    if (!raw) {
        alert("Cannot save an empty command! Enter a command above first.");
        throw new Error("Empty saved command");
    }
    return [
        { key: "RAW_COMMAND", gpu: 0, value: raw }
    ];
}
async function saveSavedCommand(commandId, entries) {
    if (!commandId) {
        throw new Error("Command name is required");
    }
    if (!Array.isArray(entries) || entries.length === 0) {
        throw new Error("Saved command has no entries to save");
    }
    const res = await fetch(
        `${API}/api/saved-commands/${encodeURIComponent(commandId)}`,
        {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ entries })
        }
    );
    if (!res.ok) {
        const errorData = await res.json().catch(() => ({}));
        const errorMsg = errorData.detail || errorData.message || "Failed to save command";
        throw new Error(errorMsg);
    }
    return await res.json();
}
async function saveSavedCommandFromDialog() {
    const commandId = getSavedCommandName();
    try {
        const entries = collectSavedCommandEntries();
        await saveSavedCommand(commandId, entries);
        loadSavedCommands();
        const status = document.getElementById("saved-cmd-status");
        if (status) status.textContent = `Saved "${commandId}"`;
    } catch (err) {
        alert(`Error saving command: ${err.message}`);
    }
}
async function deleteSavedCommandSelected() {
    if (!selectedSavedCommandId) {
        alert("No saved command selected");
        return;
    }
    if (!confirm(`Delete saved command "${selectedSavedCommandId}"?`)) {
        return;
    }
    try {
        const res = await fetch(
            `${API}/api/saved-commands/${encodeURIComponent(selectedSavedCommandId)}`,
            { method: "DELETE" }
        );
        if (!res.ok) throw new Error("Delete failed");
        loadSavedCommands();
        const status = document.getElementById("saved-cmd-status");
        if (status) status.textContent = "Saved command deleted";
    } catch (err) {
        alert(`Error deleting command: ${err.message}`);
    } finally {
        selectedSavedCommandId = null;
    }
}
function initRefreshTimer() {
    setupRefreshTimerEventListeners();
    updateRefreshTimerUI();
    console.log(`Refresh timer initialized with interval: ${currentInterval}s`);
}
function setupRefreshTimerEventListeners() {
    document.getElementById("btn-color-scheme")?.addEventListener("click", openColorSchemeModal);
    document.getElementById("btn-close-color-scheme")?.addEventListener("click", closeColorSchemeModal);
    document.getElementById("btn-color-scheme-close-x")?.addEventListener("click", closeColorSchemeModal);
    document.getElementById("btn-refresh-now")?.addEventListener("click", triggerManualRefresh);
    document.getElementById("btn-refresh-save")?.addEventListener("click", saveRefreshSettings);
    document.getElementById("btn-save-advanced-server-settings")?.addEventListener("click", saveAdvancedServerSettings);
    document.getElementById("btn-apply-stats-settings")?.addEventListener("click", applyStatsSettingsToSelectedRigs);
    document.getElementById("refresh-interval")?.addEventListener("input", validateRefreshInterval);
    document.getElementById("offline-ping-interval")?.addEventListener("input", validateOfflineInterval);
    document.getElementById("offline-threshold")?.addEventListener("input", validateOfflineThreshold);
    document.getElementById("email-enabled")?.addEventListener("change", toggleEmailNotifications);
    document.getElementById("sms-primary-enabled")?.addEventListener("change", togglePrimarySMS);
    document.getElementById("sms-secondary-enabled")?.addEventListener("change", toggleSecondarySMS);
    document.getElementById("docker-email-enabled")?.addEventListener("change", () => {
        console.log(`Docker state change email ${document.getElementById("docker-email-enabled").checked ? "enabled" : "disabled"}`);
    });
    document.getElementById("docker-sms-primary-enabled")?.addEventListener("change", () => {
        console.log(`Docker state change primary SMS ${document.getElementById("docker-sms-primary-enabled").checked ? "enabled" : "disabled"}`);
    });
    document.getElementById("docker-sms-secondary-enabled")?.addEventListener("change", () => {
        console.log(`Docker state change secondary SMS ${document.getElementById("docker-sms-secondary-enabled").checked ? "enabled" : "disabled"}`);
    });
    document.getElementById("sms-primary-number")?.addEventListener("input", validatePhoneNumber);
    document.getElementById("sms-secondary-number")?.addEventListener("input", validatePhoneNumber);
    document.getElementById("btn-offline-ping-now")?.addEventListener("click", triggerOfflinePing);
    document.getElementById("btn-test-notification")?.addEventListener("click", sendTestNotification);
    document.getElementById("refresh-interval")?.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
            saveRefreshSettings();
        }
    });
}
function loadSettingsFromServer() {
    fetch(`${API}/api/notification-settings`)
        .then(response => {
            if (!response.ok) {
                throw new Error('Failed to load settings');
            }
            return response.json();
        })
        .then(settings => {
            console.log("Settings loaded from server:", settings);
            updateUIFromServerSettings(settings);
            console.log("Notification settings loaded from server successfully");
        })
        .catch(error => {
            console.error("Failed to load settings from server:", error);
            console.log("Will use default UI state");
        });
}
function validateRefreshInterval() {
    const input = document.getElementById("refresh-interval");
    if (!input) return;
    const seconds = parseInt(input.value, 10);
    if (isNaN(seconds)) {
        input.style.borderColor = "var(--text-error)";
    } else if (seconds < 1 || seconds > 3600) {
        input.style.borderColor = "var(--text-warn)";
    } else {
        input.style.borderColor = "#333";
    }
}
function validateOfflineInterval() {
    const input = document.getElementById("offline-ping-interval");
    if (!input) return;
    const seconds = parseInt(input.value, 10);
    if (isNaN(seconds)) {
        input.style.borderColor = "var(--text-error)";
    } else if (seconds < 10 || seconds > 86400) {
        input.style.borderColor = "var(--text-warn)";
    } else {
        input.style.borderColor = "#333";
    }
}
function validateOfflineThreshold() {
    const input = document.getElementById("offline-threshold");
    if (!input) return;
    const seconds = parseInt(input.value, 10);
    if (isNaN(seconds)) {
        input.style.borderColor = "var(--text-error)";
    } else if (seconds < 30 || seconds > 86400) {
        input.style.borderColor = "var(--text-warn)";
    } else {
        input.style.borderColor = "#333";
    }
}
function validatePhoneNumber(event) {
    const input = event.target;
    const phoneNumber = input.value.trim();
    const phoneRegex = /^\+?[1-9]\d{1,14}$/;
    if (phoneNumber === "") {
        input.style.borderColor = "#333";
    } else if (!phoneRegex.test(phoneNumber)) {
        input.style.borderColor = "var(--text-error)";
    } else {
        input.style.borderColor = "var(--text-ok)";
    }
}
function initColorSchemeCollapseToggle() {
    const btn = document.getElementById("btn-color-scheme-collapse");
    const modal = document.getElementById("color-scheme-modal");
    if (!btn || !modal || btn.dataset.wired) return;
    btn.dataset.wired = "1";
    btn.addEventListener("click", () => {
        const collapsed = modal.classList.toggle("row-collapsed");
        btn.classList.toggle("active", collapsed);
        btn.textContent = collapsed ? "Expand" : "Collapse";
    });
}
function initViewTabs() {
    const tabBar = document.getElementById("view-tabs");
    if (!tabBar || tabBar.dataset.wired) return;
    tabBar.dataset.wired = "1";
    tabBar.querySelectorAll(".view-tab").forEach((tab) => {
        tab.addEventListener("click", () => {
            if (tab.dataset.tabPanel === "stats") {
                openStatsModal();
            } else if (tab.dataset.tabPanel === "settings") {
                openRefreshModal();
            } else if (tab.dataset.tabPanel === "statuslog") {
                openStatusLogModal();
            } else if (tab.dataset.tabPanel === "wallets") {
                openWalletsModal();
            } else if (tab.dataset.tabPanel === "flightsheets") {
                openFlightsheetsModal();
            } else if (tab.dataset.tabPanel === "overclocking") {
                openOverclocksModal();
            } else if (tab.dataset.tabPanel === "watchdog") {
                openWdConfigModal();
            } else if (tab.dataset.tabPanel === "backups") {
                openBackupsModal();
            } else {
                switchViewTab(tab.dataset.tabPanel);
            }
        });
    });
}
function switchViewTab(tabName) {
    document.querySelectorAll(".view-tab").forEach((tab) => {
        tab.classList.toggle("active", tab.dataset.tabPanel === tabName);
    });
    document.querySelectorAll(".view-tab-panel").forEach((panel) => {
        panel.classList.toggle("hidden", panel.dataset.tabPanel !== tabName);
    });
    if (tabName === "workers") {
        autoSizeRigColumns();
    }
}
function initWdconfigMainTabs() {
    const tabBar = document.getElementById("wdconfig-main-tabs");
    if (!tabBar || tabBar.dataset.wired) return;
    tabBar.dataset.wired = "1";
    tabBar.querySelectorAll(".wdconfig-main-tab-btn").forEach((btn) => {
        btn.addEventListener("click", () => {
            switchWdconfigMainTab(btn.dataset.tabPanel);
        });
    });
}
function switchWdconfigMainTab(tabName) {
    document.querySelectorAll("#wdconfig-main-tabs .wdconfig-main-tab-btn").forEach((btn) => {
        btn.classList.toggle("active", btn.dataset.tabPanel === tabName);
    });
    document.querySelectorAll("#wdconfig-modal .wdconfig-main-tab-panel").forEach((panel) => {
        panel.classList.toggle("hidden", panel.dataset.tabPanel !== tabName);
    });
}
function initSettingsMainTabs() {
    const tabBar = document.getElementById("settings-main-tabs");
    if (!tabBar || tabBar.dataset.wired) return;
    tabBar.dataset.wired = "1";
    tabBar.querySelectorAll(".settings-main-tab-btn").forEach((btn) => {
        btn.addEventListener("click", () => {
            switchSettingsMainTab(btn.dataset.tabPanel);
        });
    });
}
function switchSettingsMainTab(tabName) {
    document.querySelectorAll("#settings-main-tabs .settings-main-tab-btn").forEach((btn) => {
        btn.classList.toggle("active", btn.dataset.tabPanel === tabName);
    });
    document.querySelectorAll("#refresh-modal .settings-main-tab-panel").forEach((panel) => {
        panel.classList.toggle("hidden", panel.dataset.tabPanel !== tabName);
    });
    if (tabName === "agentconf") {
        // Opening the tab no longer auto-reloads from the worker - the note above the dropdown
        // says Reload/edit/Send is a manual sequence, and silently overwriting an in-progress
        // edit just from switching tabs away and back (e.g. to check Templates, then back here)
        // was surprising. lastSyncedAgentConfRig is still updated here so a genuine rig-selection
        // change made WHILE this tab is open still auto-reloads via syncOpenModulesToSelection()
        // below - that's a different, expected case (you picked a different rig to edit).
        lastSyncedAgentConfRig = selectedRigs.size === 1 ? Array.from(selectedRigs)[0] : null;
        updateConfEditTypeUi();
        const statusEl = document.getElementById("agentconf-status");
        const rawEl = document.getElementById("agentconf-raw");
        if (statusEl && !rawEl?.value) {
            const confLabel = LOGS_TYPE_LABELS[selectedConfEditType] || selectedConfEditType;
            statusEl.textContent = selectedRigs.size === 1
                ? `Click Reload to load current ${confLabel} from ${Array.from(selectedRigs)[0]}`
                : `Select exactly one worker, then click Reload to load its ${confLabel}`;
        }
    }
    if (tabName === "templates") {
        const rawEl = document.getElementById("templates-config-raw");
        // Only auto-load the first time this tab is opened in a page session - once loaded,
        // switching away and back shouldn't silently discard an in-progress unsaved edit.
        if (rawEl && !rawEl.dataset.loaded) {
            rawEl.dataset.loaded = "1";
            loadTemplatesConfigTab();
        }
    }
}
function initColorSchemeTabs() {
    const tabBar = document.getElementById("color-scheme-tabs");
    if (!tabBar || tabBar.dataset.wired) return;
    tabBar.dataset.wired = "1";
    tabBar.querySelectorAll(".color-scheme-tab-btn").forEach((btn) => {
        btn.addEventListener("click", () => {
            switchColorSchemeTab(btn.dataset.tabPanel);
        });
    });
}
function switchColorSchemeTab(tabName) {
    document.querySelectorAll(".color-scheme-tab-btn").forEach((btn) => {
        btn.classList.toggle("active", btn.dataset.tabPanel === tabName);
    });
    document.querySelectorAll(".color-scheme-tab-panel").forEach((panel) => {
        panel.classList.toggle("hidden", panel.dataset.tabPanel !== tabName);
    });
}
function openColorSchemeModal() {
    const modal = document.getElementById("color-scheme-modal");
    modal.classList.remove("hidden");
    modal.classList.add("row-collapsed");
    const collapseBtn = document.getElementById("btn-color-scheme-collapse");
    collapseBtn?.classList.add("active");
    if (collapseBtn) collapseBtn.textContent = "Expand";
    switchColorSchemeTab("style");
}
function closeColorSchemeModal() {
    const modal = document.getElementById("color-scheme-modal");
    modal.classList.add("hidden");
    modal.classList.remove("row-collapsed");
    const collapseBtn = document.getElementById("btn-color-scheme-collapse");
    collapseBtn?.classList.remove("active");
    if (collapseBtn) collapseBtn.textContent = "Collapse";
}
function openRefreshModal() {
    const input = document.getElementById("refresh-interval");
    const offlinePingInput = document.getElementById("offline-ping-interval");
    const offlineThresholdInput = document.getElementById("offline-threshold");
    if (input) {
        originalIntervalValue = currentInterval;
        input.value = currentInterval;
        input.style.borderColor = "#333";
        input.focus();
        input.select();
    }
    if (offlinePingInput) {
        const savedOfflinePing = localStorage.getItem("offlinePingInterval") || "3600";
        offlinePingInput.value = parseInt(savedOfflinePing, 10);
        offlinePingInput.style.borderColor = "#333";
    }
    if (offlineThresholdInput) {
        const savedOfflineThreshold = localStorage.getItem("offlineThreshold") || "3600";
        offlineThresholdInput.value = parseInt(savedOfflineThreshold, 10);
        offlineThresholdInput.style.borderColor = "#333";
    }
    loadSettingsFromServer();
    updateStatusDisplay();
    updateStatsSettingsTargetCount();
    switchViewTab("settings");
    switchSettingsMainTab("general");
}
function updateStatsSettingsTargetCount() {
    const count = selectedRigs.size;
    const countEl = document.getElementById("stats-settings-target-count");
    const labelEl = document.getElementById("stats-settings-target-label");
    if (countEl) countEl.textContent = count;
    if (labelEl) labelEl.textContent = count === 1 ? "worker" : "workers";
}
async function applyStatsSettingsToSelectedRigs() {
    const rigs = Array.from(selectedRigs);
    updateStatsSettingsTargetCount();
    if (rigs.length === 0) {
        alert("No workers selected");
        return;
    }
    const enabledEl = document.getElementById("stats-settings-enabled");
    const intervalInput = document.getElementById("stats-settings-interval");
    const intervalSeconds = intervalInput ? parseInt(intervalInput.value, 10) : NaN;
    const maxDaysInput = document.getElementById("stats-settings-max-days");
    const maxDays = maxDaysInput ? parseInt(maxDaysInput.value, 10) : NaN;
    const body = { rigs };
    if (enabledEl) body.enabled = enabledEl.checked;
    if (!isNaN(intervalSeconds) && intervalSeconds >= 5) {
        body.interval_seconds = intervalSeconds;
    }
    if (!isNaN(maxDays) && maxDays >= 1) {
        body.max_history_days = maxDays;
    }
    try {
        const res = await fetch(`${API}/api/stats/control`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body)
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
    } catch (err) {
        console.error("Failed to apply stats settings", err);
        alert(`Failed to apply stats settings: ${err.message}\n\nModal will remain open.`);
    }
}
function saveAdvancedServerSettings() {
    const wsPushInput = document.getElementById("ws-push-min-interval");
    const missedRefreshInput = document.getElementById("missed-refresh-threshold");
    const statusEl = document.getElementById("advanced-settings-status");
    const wsPushMinInterval = parseFloat(wsPushInput?.value);
    const missedRefreshThreshold = parseInt(missedRefreshInput?.value, 10);
    if (isNaN(wsPushMinInterval) || wsPushMinInterval < 0.1 || wsPushMinInterval > 10) {
        alert("WS Push Min Interval must be between 0.1 and 10 seconds.");
        wsPushInput?.focus();
        return;
    }
    if (isNaN(missedRefreshThreshold) || missedRefreshThreshold < 1 || missedRefreshThreshold > 10) {
        alert("Missed Refresh Threshold must be between 1 and 10.");
        missedRefreshInput?.focus();
        return;
    }
    if (statusEl) statusEl.textContent = "Saving...";
    fetch(`${API}/api/set-advanced-server-settings`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            ws_push_min_interval: wsPushMinInterval,
            missed_refresh_threshold: missedRefreshThreshold
        })
    })
        .then(response => {
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }
            return response.json();
        })
        .then(data => {
            console.log("Advanced server settings saved:", data.message);
            if (statusEl) statusEl.textContent = "Saved.";
        })
        .catch(error => {
            console.error("Failed to save advanced server settings:", error);
            if (statusEl) statusEl.textContent = "Failed to save: " + error.message;
        });
}
function saveRefreshSettings() {
    console.log("saveRefreshSettings called - sending all updates to server");
    const input = document.getElementById("refresh-interval");
    const offlinePingInput = document.getElementById("offline-ping-interval");
    const offlineThresholdInput = document.getElementById("offline-threshold");
    if (!input || !offlinePingInput || !offlineThresholdInput) {
        console.error("Missing input elements");
        return;
    }
    const seconds = parseInt(input.value, 10);
    const offlineSeconds = parseInt(offlinePingInput.value, 10);
    const thresholdSeconds = parseInt(offlineThresholdInput.value, 10);
    console.log(`Values to save: interval=${seconds}s, offlinePing=${offlineSeconds}s, threshold=${thresholdSeconds}s`);
    if (isNaN(seconds) || seconds < 1 || seconds > 3600) {
        input.style.borderColor = "var(--text-error)";
        input.focus();
        console.error("Invalid interval:", seconds);
        return;
    } else {
        input.style.borderColor = "#333";
    }
    if (isNaN(offlineSeconds) || offlineSeconds < 10 || offlineSeconds > 86400) {
        offlinePingInput.style.borderColor = "var(--text-error)";
        offlinePingInput.focus();
        console.error("Invalid offline ping interval:", offlineSeconds);
        return;
    } else {
        offlinePingInput.style.borderColor = "#333";
    }
    if (isNaN(thresholdSeconds) || thresholdSeconds < 30 || thresholdSeconds > 86400) {
        offlineThresholdInput.style.borderColor = "var(--text-error)";
        offlineThresholdInput.focus();
        console.error("Invalid offline threshold:", thresholdSeconds);
        return;
    } else {
        offlineThresholdInput.style.borderColor = "#333";
    }
    const smsPrimaryEnabled = document.getElementById("sms-primary-enabled")?.checked || false;
    const smsSecondaryEnabled = document.getElementById("sms-secondary-enabled")?.checked || false;
    const smsPrimaryNumber = document.getElementById("sms-primary-number")?.value?.trim() || "";
    const smsSecondaryNumber = document.getElementById("sms-secondary-number")?.value?.trim() || "";
    const dockerSmsPrimaryEnabled = document.getElementById("docker-sms-primary-enabled")?.checked || false;
    const dockerSmsSecondaryEnabled = document.getElementById("docker-sms-secondary-enabled")?.checked || false;
    const needsPrimaryNumber = smsPrimaryEnabled || dockerSmsPrimaryEnabled;
    const needsSecondaryNumber = smsSecondaryEnabled || dockerSmsSecondaryEnabled;
    const phoneRegex = /^\+?[1-9]\d{1,14}$/;
    if (needsPrimaryNumber) {
        if (!smsPrimaryNumber) {
            alert("Primary SMS is enabled (directly or via Docker State Change) but no phone number is entered. Please enter a phone number or disable it.");
            document.getElementById("sms-primary-number").focus();
            return;
        }
        if (!phoneRegex.test(smsPrimaryNumber)) {
            alert("Primary SMS phone number is invalid. Please enter a valid phone number (e.g., +1234567890).");
            document.getElementById("sms-primary-number").focus();
            document.getElementById("sms-primary-number").style.borderColor = "var(--text-error)";
            return;
        } else {
            document.getElementById("sms-primary-number").style.borderColor = "#333";
        }
    }
    if (needsSecondaryNumber) {
        if (!smsSecondaryNumber) {
            alert("Secondary SMS is enabled (directly or via Docker State Change) but no phone number is entered. Please enter a phone number or disable it.");
            document.getElementById("sms-secondary-number").focus();
            return;
        }
        if (!phoneRegex.test(smsSecondaryNumber)) {
            alert("Secondary SMS phone number is invalid. Please enter a valid phone number (e.g., +1234567890).");
            document.getElementById("sms-secondary-number").focus();
            document.getElementById("sms-secondary-number").style.borderColor = "var(--text-error)";
            return;
        } else {
            document.getElementById("sms-secondary-number").style.borderColor = "#333";
        }
    }
    localStorage.setItem("offlinePingInterval", offlineSeconds.toString());
    localStorage.setItem("offlineThreshold", thresholdSeconds.toString());
    console.log(`Offline ping interval saved to localStorage: ${offlineSeconds}s`);
    console.log(`Offline threshold saved to localStorage: ${thresholdSeconds}s`);
    const promises = [];
    promises.push(
        saveNotificationSettingsToServer()
            .then(data => {
                console.log("Notification settings saved successfully");
                return data;
            })
            .catch(error => {
                console.error("Failed to save notification settings:", error);
                throw new Error(`Notification settings: ${error.message}`);
            })
    );
    promises.push(
        fetch(`${API}/api/set-offline-ping-interval`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ interval_seconds: offlineSeconds })
        })
        .then(response => {
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }
            return response.json();
        })
        .then(data => {
            console.log(`Offline ping interval set to ${offlineSeconds}s:`, data.message);
            return data;
        })
        .catch(error => {
            console.error("Failed to set offline ping interval:", error);
            throw new Error(`Offline ping interval: ${error.message}`);
        })
    );
    promises.push(
        fetch(`${API}/api/set-offline-threshold`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ threshold_seconds: thresholdSeconds })
        })
        .then(response => {
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}`);
            }
            return response.json();
        })
        .then(data => {
            console.log(`Offline threshold set to ${thresholdSeconds}s:`, data.message);
            return data;
        })
        .catch(error => {
            console.error("Failed to set offline threshold:", error);
            throw new Error(`Offline threshold: ${error.message}`);
        })
    );
    if (seconds !== currentInterval) {
        promises.push(
            updateServerInterval(seconds)
                .then(data => {
                    console.log(`Main interval set to ${seconds}s:`, data.message);
                    return data;
                })
                .catch(error => {
                    console.error("Failed to set main interval:", error);
                    throw new Error(`Main interval: ${error.message}`);
                })
        );
    } else {
        console.log("Main interval unchanged - skipping update");
    }
    Promise.all(promises)
        .then(results => {
            console.log("All server updates completed successfully");
            updateRefreshTimerUI();
        })
        .catch(error => {
            console.error("One or more server updates failed:", error);
            alert(`Failed to save some settings: ${error.message}\n\nModal will remain open.`);
        });
}
async function saveNotificationSettingsToServer() {
    console.log("Saving notification settings to server...");
    const emailEnabled = document.getElementById("email-enabled")?.checked || false;
    const smsPrimaryEnabled = document.getElementById("sms-primary-enabled")?.checked || false;
    const smsSecondaryEnabled = document.getElementById("sms-secondary-enabled")?.checked || false;
    const smsPrimaryNumber = document.getElementById("sms-primary-number")?.value?.trim() || "";
    const smsSecondaryNumber = document.getElementById("sms-secondary-number")?.value?.trim() || "";
    const dockerEmailEnabled = document.getElementById("docker-email-enabled")?.checked || false;
    const dockerSmsPrimaryEnabled = document.getElementById("docker-sms-primary-enabled")?.checked || false;
    const dockerSmsSecondaryEnabled = document.getElementById("docker-sms-secondary-enabled")?.checked || false;
    const notificationSettings = {
        email_enabled: emailEnabled,
        sms_primary_enabled: smsPrimaryEnabled,
        sms_secondary_enabled: smsSecondaryEnabled,
        sms_primary_number: smsPrimaryNumber,
        sms_secondary_number: smsSecondaryNumber,
        docker_email_enabled: dockerEmailEnabled,
        docker_sms_primary_enabled: dockerSmsPrimaryEnabled,
        docker_sms_secondary_enabled: dockerSmsSecondaryEnabled
    };
    console.log("Sending to server (snake_case):", notificationSettings);
    try {
        const response = await fetch(`${API}/api/notification-settings`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(notificationSettings)
        });
        if (!response.ok) {
            const errorText = await response.text();
            console.error("Server response error:", errorText);
            throw new Error(`Server responded with ${response.status}: ${errorText}`);
        }
        const data = await response.json();
        console.log("Server response:", data);
        if (data.settings) {
            updateUIFromServerSettings(data.settings);
        }
        return data;
    } catch (error) {
        console.error("Error saving notification settings to server:", error);
        throw error;
    }
}
function updateUIFromServerSettings(serverSettings) {
    console.log("Updating UI from server settings:", serverSettings);
    const emailCheckbox = document.getElementById("email-enabled");
    const primarySmsCheckbox = document.getElementById("sms-primary-enabled");
    const secondarySmsCheckbox = document.getElementById("sms-secondary-enabled");
    const primaryInput = document.getElementById("sms-primary-number");
    const secondaryInput = document.getElementById("sms-secondary-number");
    if (emailCheckbox && serverSettings.email_enabled !== undefined) {
        emailCheckbox.checked = serverSettings.email_enabled;
    }
    if (primarySmsCheckbox && serverSettings.sms_primary_enabled !== undefined) {
        primarySmsCheckbox.checked = serverSettings.sms_primary_enabled;
    }
    if (secondarySmsCheckbox && serverSettings.sms_secondary_enabled !== undefined) {
        secondarySmsCheckbox.checked = serverSettings.sms_secondary_enabled;
    }
    if (primaryInput && serverSettings.sms_primary_number !== undefined) {
        primaryInput.value = serverSettings.sms_primary_number || "";
    }
    if (secondaryInput && serverSettings.sms_secondary_number !== undefined) {
        secondaryInput.value = serverSettings.sms_secondary_number || "";
    }
    const dockerEmailCheckbox = document.getElementById("docker-email-enabled");
    const dockerPrimarySmsCheckbox = document.getElementById("docker-sms-primary-enabled");
    const dockerSecondarySmsCheckbox = document.getElementById("docker-sms-secondary-enabled");
    if (dockerEmailCheckbox && serverSettings.docker_email_enabled !== undefined) {
        dockerEmailCheckbox.checked = serverSettings.docker_email_enabled;
    }
    if (dockerPrimarySmsCheckbox && serverSettings.docker_sms_primary_enabled !== undefined) {
        dockerPrimarySmsCheckbox.checked = serverSettings.docker_sms_primary_enabled;
    }
    if (dockerSecondarySmsCheckbox && serverSettings.docker_sms_secondary_enabled !== undefined) {
        dockerSecondarySmsCheckbox.checked = serverSettings.docker_sms_secondary_enabled;
    }
    console.log("UI updated from server settings");
}
function toggleEmailNotifications() {
    const emailCheckbox = document.getElementById("email-enabled");
    const enabled = emailCheckbox.checked;
    console.log(`Email notifications ${enabled ? 'enabled' : 'disabled'}`);
}
function togglePrimarySMS() {
    const smsCheckbox = document.getElementById("sms-primary-enabled");
    const phoneInput = document.getElementById("sms-primary-number");
    const enabled = smsCheckbox.checked;
    console.log(`Primary SMS ${enabled ? 'enabled' : 'disabled'}`);
    if (phoneInput && enabled) {
        setTimeout(() => {
            phoneInput.focus();
            phoneInput.select();
        }, 100);
    }
}
function toggleSecondarySMS() {
    const smsCheckbox = document.getElementById("sms-secondary-enabled");
    const phoneInput = document.getElementById("sms-secondary-number");
    const enabled = smsCheckbox.checked;
    console.log(`Secondary SMS ${enabled ? 'enabled' : 'disabled'}`);
    if (phoneInput && enabled) {
        setTimeout(() => {
            phoneInput.focus();
            phoneInput.select();
        }, 100);
    }
}
function updateStatusDisplay() {
    const connections = Object.keys(rigsState).length;
    const currentConnectionsEl = document.getElementById("current-connections");
    if (currentConnectionsEl) {
        currentConnectionsEl.textContent = connections;
    }
    const rigsMonitored = connections;
    const rigsMonitoredEl = document.getElementById("rigs-monitored");
    if (rigsMonitoredEl) {
        rigsMonitoredEl.textContent = rigsMonitored;
    }
    let rigsOffline = 0;
    const now = Date.now() / 1000;
    for (const rigName in rigsState) {
        if (rigName === "rigs") continue;
        const rig = rigsState[rigName];
        const lastUpdate = rig.timestamp || 0;
        const timeDiff = now - lastUpdate;
        if (timeDiff > 300) {
            rigsOffline++;
        }
    }
    const rigsOfflineEl = document.getElementById("rigs-offline");
    if (rigsOfflineEl) {
        rigsOfflineEl.textContent = rigsOffline;
    }
    const lastNotificationEl = document.getElementById("last-notification");
    if (lastNotificationEl) {
        lastNotificationEl.textContent = "Check server logs";
    }
}
function triggerOfflinePing() {
    console.log("Manually triggering offline ping...");
    fetch(`${API}/api/trigger-offline-ping`, {
        method: "POST"
    }).then(response => {
        if (response.ok) {
            console.log("Offline ping triggered successfully");
            alert("Offline ping triggered successfully");
        } else {
            console.error("Failed to trigger offline ping");
            alert("Failed to trigger offline ping");
        }
    }).catch(error => {
        console.error("Error triggering offline ping:", error);
        alert("Error triggering offline ping");
    });
}
function sendTestNotification() {
    console.log("Sending test notification...");
    fetch(`${API}/api/test-notification`, {
        method: "POST"
    }).then(response => {
        if (response.ok) {
            console.log("Test notification sent successfully");
            alert("Test notification sent successfully");
            const lastNotificationEl = document.getElementById("last-notification");
            if (lastNotificationEl) {
                lastNotificationEl.textContent = new Date().toLocaleString();
            }
        } else {
            console.error("Failed to send test notification");
            alert("Failed to send test notification");
        }
    }).catch(error => {
        console.error("Error sending test notification:", error);
        alert("Error sending test notification");
    });
}
function triggerManualRefresh() {
    fetch(`${API}/refresh`, {
        method: "POST"
    }).then(response => {
        if (response.ok) {
            console.log("Manual refresh requested from server");
        }
    }).catch(error => {
        console.error("Failed to request refresh:", error);
    });
}
async function setServerRefreshInterval(seconds) {
    try {
        const response = await fetch(`${API}/api/set-interval`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ interval_seconds: seconds })
        });
        if (!response.ok) {
            const error = await response.json();
            throw new Error(error.detail || "Failed to set interval");
        }
        const data = await response.json();
        console.log(`Server interval set to ${seconds}s:`, data.message);
        currentInterval = seconds;
        localStorage.setItem("refreshInterval", seconds.toString());
        updateRefreshTimerUI();
        return data;
    } catch (error) {
        console.error("Failed to set server interval:", error);
        throw error;
    }
}
function updateServerInterval(seconds) {
    const oldInterval = currentInterval;
    console.log(`Updating interval from ${oldInterval}s to ${seconds}s`);
    return setServerRefreshInterval(seconds).then(result => {
        console.log(`Server interval updated to ${seconds}s`);
        currentInterval = seconds;
        localStorage.setItem("refreshInterval", seconds.toString());
        updateRefreshTimerUI();
        return result;
    }).catch(err => {
        console.warn("Could not update server interval:", err.message);
        currentInterval = oldInterval;
        if (document.getElementById("refresh-interval")) {
            document.getElementById("refresh-interval").value = oldInterval;
        }
        throw err;
    });
}
function updateRefreshTimerUI() {
    const btn = document.getElementById("btn-refresh-timer");
    if (!btn) return;
    const offlinePing = localStorage.getItem("offlinePingInterval") || "3600";
    const offlineThreshold = localStorage.getItem("offlineThreshold") || "3600";
    btn.title = "Settings: notification - stats";
    btn.style.opacity = "1";
}
function handleIntervalChangeNotification(msg) {
    if (msg.interval_changed) {
        const modal = document.getElementById("refresh-modal");
        const userIsEditing = modal && !modal.classList.contains("hidden");
        console.log(`Server interval changed from ${msg.old_interval}s to ${msg.new_interval}s`);
        currentInterval = msg.new_interval;
        const refreshIntervalInput = document.getElementById("refresh-interval");
        if (!userIsEditing && refreshIntervalInput) {
            refreshIntervalInput.value = msg.new_interval;
        }
        localStorage.setItem("refreshInterval", currentInterval.toString());
        updateRefreshTimerUI();
    }
}
function handleOfflineThresholdChangeNotification(msg) {
    if (msg.offline_threshold_changed) {
        const modal = document.getElementById("refresh-modal");
        const userIsEditing = modal && !modal.classList.contains("hidden");
        console.log(`Server offline threshold changed from ${msg.old_threshold}s to ${msg.new_threshold}s`);
        localStorage.setItem("offlineThreshold", msg.new_threshold.toString());
        const offlineThresholdInput = document.getElementById("offline-threshold");
        if (!userIsEditing && offlineThresholdInput) {
            offlineThresholdInput.value = msg.new_threshold;
        }
    }
}
function handleOfflinePingIntervalChangeNotification(msg) {
    if (msg.offline_ping_interval_changed) {
        const modal = document.getElementById("refresh-modal");
        const userIsEditing = modal && !modal.classList.contains("hidden");
        console.log(`Server offline ping interval changed from ${msg.old_interval}s to ${msg.new_interval}s`);
        localStorage.setItem("offlinePingInterval", msg.new_interval.toString());
        const offlinePingInput = document.getElementById("offline-ping-interval");
        if (!userIsEditing && offlinePingInput) {
            offlinePingInput.value = msg.new_interval;
        }
    }
}
async function sendCommandToSelectedRigs(command) {
    const targets = (cmdModalRigOverride && cmdModalRigOverride.length)
        ? cmdModalRigOverride
        : Array.from(selectedRigs);
    cmdModalRigOverride = null;
    if (targets.length === 0) {
        alert("No workers selected");
        return;
    }
    return fetch(`${API}/command`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            rigs: targets,
            command
        })
    });
}
function submitCmd() {
    const cmd = document.getElementById("cmd-input").value.trim();
    if (!cmd) return;
    sendCommandToSelectedRigs(cmd).catch(err => {
        console.error("Command send failed", err);
        alert("Failed to send command");
    });
}
function clearOutputAndSend() {
    const output = document.getElementById("cmd-output");
    if (output) output.textContent = "";
    submitCmd();
}
async function loadQuickActionsConfig() {
    try {
        const res = await fetch(`${API}/api/quick-actions`);
        if (!res.ok) throw new Error("Failed to load quick actions");
        const data = await res.json();
        quickActionsConfig = {
            a: typeof data.a === "string" ? data.a : "",
            b: typeof data.b === "string" ? data.b : "",
            c: typeof data.c === "string" ? data.c : ""
        };
    } catch (e) {
        console.error("Failed to load quick actions config from server", e);
        quickActionsConfig = { ...DEFAULT_QUICK_ACTIONS };
    }
    return quickActionsConfig;
}
async function saveQuickActionsConfig() {
    try {
        const res = await fetch(`${API}/api/quick-actions`, {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(quickActionsConfig)
        });
        if (!res.ok) throw new Error("Failed to save quick actions");
    } catch (e) {
        console.error("Failed to save quick actions config to server", e);
        alert(`Failed to save quick actions to server: ${e.message}`);
    }
}
function handleQuickActionClick(key, event) {
    if (event && event.ctrlKey) {
        openQuickActionsModal();
        return;
    }
    runQuickAction(key);
}
function runQuickAction(key) {
    const command = (quickActionsConfig[key] || "").trim();
    if (!command) {
        alert(`Quick action ${key.toUpperCase()} isn't set up yet. Ctrl+click the button to configure it.`);
        return;
    }
    openCmdModal();
    document.getElementById("cmd-input").value = command;
    submitCmd();
}
async function openQuickActionsModal() {
    await loadQuickActionsConfig();
    updateQuickActionTooltips();
    document.getElementById("qa-command-a").value = quickActionsConfig.a || "";
    document.getElementById("qa-command-b").value = quickActionsConfig.b || "";
    document.getElementById("qa-command-c").value = quickActionsConfig.c || "";
    document.getElementById("quick-actions-modal")?.classList.remove("hidden");
}
function closeQuickActionsModal() {
    document.getElementById("quick-actions-modal")?.classList.add("hidden");
}
async function applyQuickActionsModal() {
    quickActionsConfig = {
        a: document.getElementById("qa-command-a").value.trim(),
        b: document.getElementById("qa-command-b").value.trim(),
        c: document.getElementById("qa-command-c").value.trim()
    };
    await saveQuickActionsConfig();
    updateQuickActionTooltips();
    closeQuickActionsModal();
}
function updateQuickActionTooltips() {
    ["a", "b", "c"].forEach(key => {
        const btn = document.getElementById(`btn-quick-${key}`);
        if (!btn) return;
        const command = (quickActionsConfig[key] || "").trim();
        btn.title = command
            ? `${command} (Ctrl+click to edit)`
            : `Quick action ${key.toUpperCase()} isn't set up - Ctrl+click to configure`;
    });
}
function actionStart() {
    if (wdEnabled) {
        const label = "Start watchdog";
        if (!confirmAction(label)) return;
        setActionOutput(label + "…");
        watchdogStart();
        return;
    }
    const label =
        currentActionMode === "cpu" ? "Start CPU miners" :
            currentActionMode === "gpu" ? "Start GPU miners" :
                currentActionMode === "aux" ? "Start AUX service" :
                    "Start ALL miners";
    if (!confirmAction(label)) return;
    setActionOutput(label + "…");
    if (currentActionMode === "cpu") {
        cpuStart();
    } else if (currentActionMode === "gpu") {
        gpuStart();
    } else if (currentActionMode === "aux") {
        auxStart();
    } else if (currentActionMode === "all") {
        cpuStart();
        gpuStart();
    }
}
function actionStop() {
    if (wdEnabled) {
        const label = "Stop watchdog";
        if (!confirmAction(label)) return;
        setActionOutput(label + "…");
        watchdogStop();
        return;
    }
    const label =
        currentActionMode === "cpu" ? "Stop CPU miners" :
            currentActionMode === "gpu" ? "Stop GPU miners" :
                currentActionMode === "aux" ? "Stop AUX service" :
                    "Stop ALL miners";
    if (!confirmAction(label)) return;
    setActionOutput(label + "…");
    if (currentActionMode === "cpu") {
        cpuStop();
    } else if (currentActionMode === "gpu") {
        gpuStop();
    } else if (currentActionMode === "aux") {
        auxStop();
    } else if (currentActionMode === "all") {
        cpuStop();
        gpuStop();
    }
}
function actionRestart() {
    if (wdEnabled) {
        const label = "Restart watchdog";
        if (!confirmAction(label)) return;
        setActionOutput(label + "…");
        watchdogRestart();
        return;
    }
    const label =
        currentActionMode === "cpu" ? "Restart CPU miners" :
            currentActionMode === "gpu" ? "Restart GPU miners" :
                currentActionMode === "aux" ? "Restart AUX service" :
                    "Restart ALL miners";
    if (!confirmAction(label)) return;
    setActionOutput(label + "…");
    if (currentActionMode === "cpu") {
        cpuRestart();
    } else if (currentActionMode === "gpu") {
        gpuRestart();
    } else if (currentActionMode === "aux") {
        auxRestart();
    } else if (currentActionMode === "all") {
        cpuRestart();
        gpuRestart();
    }
}
async function gpuStart() {
    setActionOutput("Starting GPU miners…");
    await sendCommandToSelectedRigs("gpu.start");
}
async function gpuStop() {
    setActionOutput("Stopping GPU miners…");
	await sendCommandToSelectedRigs("gpu.stop");
}
async function gpuRestart() {
    setActionOutput("Restarting GPU miners…");
    await sendCommandToSelectedRigs("gpu.restart");
}
async function cpuStart() {
    setActionOutput("Starting CPU miners…");
    await sendCommandToSelectedRigs("cpu.start");
}
async function cpuStop() {
    setActionOutput("Stopping CPU miners…");
    await sendCommandToSelectedRigs("cpu.stop");
}
async function cpuRestart() {
    setActionOutput("Restarting CPU miners…");
    await sendCommandToSelectedRigs("cpu.restart");
}
async function auxStart() {
    setActionOutput("Starting AUX service…");
    await sendCommandToSelectedRigs("aux.start");
}
async function auxStop() {
    setActionOutput("Stopping AUX service…");
    await sendCommandToSelectedRigs("aux.stop");
}
async function auxRestart() {
    setActionOutput("Restarting AUX service…");
    await sendCommandToSelectedRigs("aux.restart");
}
async function watchdogStart() {
    setActionOutput("Starting watchdog…");
    await sendCommandToSelectedRigs("watchdog.start");
}
async function watchdogStop() {
    setActionOutput("Stopping watchdog…");
    await sendCommandToSelectedRigs("watchdog.stop");
}
async function watchdogRestart() {
    setActionOutput("Restarting watchdog…");
    await sendCommandToSelectedRigs("watchdog.restart");
}
function runRawShell(commandText) {
    if (!commandText || !commandText.trim()) return;
    sendCommandToSelectedRigs(commandText);
}
async function hardReset(ev) {
    ev.preventDefault();
    ev.stopPropagation();
    resetInProgress = true;
    setResetButtonDisabled(true);
    if (!window.confirm("Clear all known workers and reload fresh data?")) {
        resetInProgress = false;
        setResetButtonDisabled(false);
        return;
    }
    try {
        await fetch(`${API}/reset`, { method: "POST" });
    } finally {
        resetInProgress = false;
        setResetButtonDisabled(false);
    }
}
function getFlightsheetName() {
    const el = document.getElementById("fs-name");
    if (!el) return "";
    return el.value
        .trim()
        .toLowerCase()
        .replace(/\s+/g, "-")
        .replace(/[^a-z0-9\-]/g, "");
}
function collectFlightsheetEntries() {
    const cmd = fsFinalizeRawForAction().trim();
    if (!cmd) {
        alert("Cannot save empty flightsheet! Please enter a command in the flightsheet editor.");
        throw new Error("Empty command");
    }
    console.log("Saving flightsheet with command length:", cmd.length);
    return [
        { key: "RAW_COMMAND", gpu: 0, value: cmd }
    ];
}
let fsApplyToRigs = new Set();
function isFsApplyToDropdownOpen() {
    const list = document.getElementById("fs-apply-to-list");
    return !!list && !list.classList.contains("hidden");
}
function openFsApplyToDropdown() {
    populateFsApplyToWorkerList();
    document.getElementById("fs-apply-to-list")?.classList.remove("hidden");
}
function closeFsApplyToDropdown() {
    document.getElementById("fs-apply-to-list")?.classList.add("hidden");
}
function toggleFsApplyToDropdown() {
    if (isFsApplyToDropdownOpen()) {
        closeFsApplyToDropdown();
    } else {
        openFsApplyToDropdown();
    }
}
function updateFsApplyToToggleLabel() {
    const btn = document.getElementById("btn-fs-apply-to-toggle");
    if (!btn) return;
    if (fsApplyToRigs.size === 0) {
        btn.textContent = "Workers";
    } else if (fsApplyToRigs.size === 1) {
        btn.textContent = Array.from(fsApplyToRigs)[0];
    } else {
        btn.textContent = `${fsApplyToRigs.size} workers`;
    }
}
function updateFsApplyToWorkersOptionCheckedState() {
    const opt = document.getElementById("fs-apply-to-workers-option");
    if (opt) opt.classList.toggle("fs-apply-to-active", fsApplyToRigs.size === 0);
}
function populateFsApplyToWorkerList() {
    const container = document.getElementById("fs-apply-to-workers");
    if (!container) return;
    container.innerHTML = "";
    const rigNames = Object.keys(rigsState || {})
        .filter(name => name !== "rigs")
        .sort();
    rigNames.forEach((name) => {
        const row = document.createElement("label");
        row.className = "fs-apply-to-worker-row";
        const cb = document.createElement("input");
        cb.type = "checkbox";
        cb.checked = fsApplyToRigs.has(name);
        cb.addEventListener("change", () => {
            if (cb.checked) {
                fsApplyToRigs.add(name);
            } else {
                fsApplyToRigs.delete(name);
            }
            updateFsApplyToToggleLabel();
            updateFsApplyToWorkersOptionCheckedState();
            syncFsRawAfterApplyToChange();
        });
        const span = document.createElement("span");
        span.textContent = name;
        row.appendChild(cb);
        row.appendChild(span);
        container.appendChild(row);
    });
    updateFsApplyToWorkersOptionCheckedState();
}
function setFsApplyToRigs(names) {
    const rigNames = new Set(Object.keys(rigsState || {}).filter(name => name !== "rigs"));
    fsApplyToRigs = new Set((Array.isArray(names) ? names : []).filter(name => rigNames.has(name)));
    updateFsApplyToToggleLabel();
    if (isFsApplyToDropdownOpen()) populateFsApplyToWorkerList();
}
function clearFsApplyToSelection() {
    fsApplyToRigs.clear();
    updateFsApplyToToggleLabel();
    populateFsApplyToWorkerList();
    syncFsRawAfterApplyToChange();
}
function syncFsRawAfterApplyToChange() {
    const rawEl = document.getElementById("fs-raw");
    if (!rawEl || rawEl.value.trim() === "") return;
    if (fsDualModeActive) {
        rawEl.value = buildFsActivePreview();
        autoResizeFsRaw();
        return;
    }
    const jsonItem = parseRigGpuJsonFromRaw(rawEl.value);
    if (!jsonItem) return;
    const values = collectFsFieldValues();
    const newBody = buildRigGpuJsonBody(values);
    if (/<<'EOF'\n[\s\S]*?\n[ \t]*EOF[ \t]*(?=\n|$)/.test(rawEl.value)) {
        rawEl.value = rawEl.value.replace(
            /(<<'EOF'\n)[\s\S]*?(\n[ \t]*EOF[ \t]*)(?=\n|$)/,
            (_full, pre, post) => `${pre}${newBody}${post}`
        );
    } else {
        rawEl.value = newBody;
    }
    autoResizeFsRaw();
}
async function loadFlightsheets() {
    const res = await fetch(`${API}/api/flightsheets`);
    if (!res.ok) {
        alert("Failed to load flightsheets");
        return;
    }
    flightsheets = await res.json();
    renderFlightsheets();
}
function extractFsRawValue(rawText, key) {
    if (!rawText) return "";
    const jsonItem = parseRigGpuJsonFromRaw(rawText);
    if (jsonItem) {
        const values = fsFieldsFromRigGpuJsonItem(jsonItem);
        return values[key] || "";
    }
    const match = rawText.match(new RegExp(`^${key}\\s+(?:0\\s+)?"([^"]*)"`, "m"));
    return match ? match[1] : "";
}
function extractFsPoolListDisplay(rawText) {
    if (!rawText) return "";
    const jsonItem = parseRigGpuJsonFromRaw(rawText);
    if (jsonItem) {
        const isCustom = jsonItem.miner === "custom";
        const sslOn = !isCustom && jsonItem.pool_ssl === true;
        if (Array.isArray(jsonItem.pool_urls) && jsonItem.pool_urls.length > 0) {
            return jsonItem.pool_urls
                .map((u) => bareFsPoolUrl(u || ""))
                .filter((u) => u !== "")
                .map((u) => styledFsPoolUrl(u, sslOn))
                .join(" ");
        }
        const values = fsFieldsFromRigGpuJsonItem(jsonItem);
        return values.POOL || "";
    }
    return extractFsRawValue(rawText, "POOL");
}
function extractFsApplyToFromRaw(rawText) {
    if (!rawText) return [];
    const parsed = parseRigGpuItemsFromRaw(rawText);
    return (parsed && Array.isArray(parsed.apply_to_workers)) ? parsed.apply_to_workers : [];
}
const FS_RESTART_SERVICE_LABELS = { gpu: "GPU", cpu: "CPU", aux: "AUX" };
function extractFsRestartDisplay(rawText) {
    if (!rawText) return "";
    const parsed = parseRigGpuItemsFromRaw(rawText);
    if (!parsed || !Array.isArray(parsed.items) || parsed.items.length === 0) return "";
    const restarting = new Set();
    for (const item of parsed.items) {
        if (!item || typeof item !== "object") continue;
        const isOn = item.restart === true || item.restart === "true" || item.restart === 1 || item.restart === "1";
        if (!isOn) continue;
        const svc = classifyFsItemService(item, rawText);
        restarting.add(FS_RESTART_SERVICE_LABELS[svc] || "GPU");
    }
    return ["GPU", "CPU", "AUX"].filter((label) => restarting.has(label)).join(" ");
}
function renderFlightsheets() {
    const list = document.getElementById("fs-list");
    list.innerHTML = "";
    const sortedFlightsheets = [...flightsheets].sort((a, b) => {
        return naturalCompare(a.FlightsheetId, b.FlightsheetId);
    });
    for (const fs of sortedFlightsheets) {
        const row = document.createElement("div");
        row.className = "fs-item";
        const raw = fs.Value || "";
        const coin = extractFsRawValue(raw, "ALGO");
        const pool = extractFsPoolListDisplay(raw);
        const miner = extractFsRawValue(raw, "MINER") || extractFsRawValue(raw, "CUSTOM_MINER");
        const applyToWorkers = extractFsApplyToFromRaw(raw);
        const applyToDisplay = applyToWorkers.length > 0 ? applyToWorkers.join(", ") : "Workers";
        const restart = extractFsRestartDisplay(raw);
        row.innerHTML = `
            <input type="checkbox" class="rig-select-checkbox fs-select-checkbox" title="Select flightsheet">
            <div class="fs-item-grid">
                <span class="fs-item-col fs-item-col-name">${escapeHtml(fs.FlightsheetId)}</span>
                <span class="fs-item-col fs-item-col-applyto" title="${escapeHtml(applyToDisplay)}">${escapeHtml(applyToDisplay)}</span>
                <span class="fs-item-col fs-item-col-restart" title="${escapeHtml(restart)}">${escapeHtml(restart)}</span>
                <span class="fs-item-col fs-item-col-coin">${escapeHtml(coin)}</span>
                <span class="fs-item-col fs-item-col-miner">${escapeHtml(miner)}</span>
                <span class="fs-item-col fs-item-col-pool">${escapeHtml(pool)}</span>
            </div>
        `;
        row.dataset.id = fs.FlightsheetId;
        row.dataset.value = raw;
        row.dataset.algo = coin;
        row.dataset.miner = miner;
        row.dataset.pool = pool;
        row.dataset.restart = restart;
        if (fs.FlightsheetId === selectedFlightsheetId) {
            row.classList.add("selected");
        }
        const checkbox = row.querySelector(".fs-select-checkbox");
        checkbox.checked = selectedFlightsheetIds.has(fs.FlightsheetId);
        checkbox.addEventListener("click", (ev) => {
            ev.stopPropagation();
            if (checkbox.checked) {
                selectedFlightsheetIds.add(fs.FlightsheetId);
            } else {
                selectedFlightsheetIds.delete(fs.FlightsheetId);
            }
            syncFsSelectAllCheckbox();
        });
        row.addEventListener("click", () => {
            document
                .querySelectorAll("#fs-list .fs-item.selected")
                .forEach(e => e.classList.remove("selected"));
            row.classList.add("selected");
            selectedFlightsheetId = fs.FlightsheetId;
            document.getElementById("fs-name").value = fs.FlightsheetId;
            document.getElementById("fs-raw").value = fs.Value || "";
            populateFsFieldsFromRaw(fs.Value || "");
            autoResizeFsRaw();
        });
        list.appendChild(row);
    }
    populateFsAlgoFilter();
    populateFsMinerFilter();
    filterFlightsheetList();
    syncFsSelectAllCheckbox();
    autoSizeFsListColumns();
}
const FS_LIST_AUTOSIZE_PADDING_PX = 14;
let __fsListMeasureCanvas = null;
function measureFsListTextWidth(text, font) {
    if (!__fsListMeasureCanvas) {
        __fsListMeasureCanvas = document.createElement("canvas");
    }
    const ctx = __fsListMeasureCanvas.getContext && __fsListMeasureCanvas.getContext("2d");
    if (!ctx) return (text || "").length * 7; 
    ctx.font = font;
    return ctx.measureText(text || "").width;
}
function fsListColumnFont(el) {
    const cs = getComputedStyle(el);
    return `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
}
function fsListHeaderTextWidth(el, font) {
    if (!el || !font) return 0;
    const cs = getComputedStyle(el);
    let text = el.textContent || "";
    if (cs.textTransform === "uppercase") text = text.toUpperCase();
    else if (cs.textTransform === "lowercase") text = text.toLowerCase();
    else if (cs.textTransform === "capitalize") text = text.replace(/\b\w/g, (c) => c.toUpperCase());
    let width = measureFsListTextWidth(text, font);
    const ls = parseFloat(cs.letterSpacing);
    if (!isNaN(ls) && ls !== 0 && text.length > 0) {
        width += ls * text.length;
    }
    return width;
}
const FS_LIST_NAME_MIN_PX = 140;
const FS_LIST_APPLYTO_MAX_PX = 170;
function autoSizeFsListColumns() {
    const header = document.querySelector("#fs-modal .fs-list-header .fs-item-grid");
    if (!header) return;
    const rowGrids = document.querySelectorAll("#fs-list .fs-item .fs-item-grid");
    const headerNameEl = header.children[0];
    const headerApplyToEl = header.children[1];
    const headerRestartEl = header.children[2];
    const headerAlgoEl = header.children[3];
    const headerMinerEl = header.children[4];
    const headerFont = headerMinerEl ? fsListColumnFont(headerMinerEl) : null;
    const sampleRowMinerEl = rowGrids.length > 0 ? rowGrids[0].children[4] : null;
    const rowFont = sampleRowMinerEl ? fsListColumnFont(sampleRowMinerEl) : headerFont;
    let nameWidth = 0;
    let applyToWidth = 0;
    let minerWidth = 0;
    let algoWidth = 0;
    let restartWidth = 0;
    if (headerNameEl && headerFont) {
        nameWidth = Math.max(nameWidth, fsListHeaderTextWidth(headerNameEl, headerFont));
    }
    if (headerApplyToEl && headerFont) {
        applyToWidth = Math.max(applyToWidth, fsListHeaderTextWidth(headerApplyToEl, headerFont));
    }
    if (headerRestartEl && headerFont) {
        restartWidth = Math.max(restartWidth, fsListHeaderTextWidth(headerRestartEl, headerFont));
    }
    if (headerAlgoEl && headerFont) {
        algoWidth = Math.max(algoWidth, fsListHeaderTextWidth(headerAlgoEl, headerFont));
    }
    if (headerMinerEl && headerFont) {
        minerWidth = Math.max(minerWidth, fsListHeaderTextWidth(headerMinerEl, headerFont));
    }
    if (rowFont) {
        rowGrids.forEach((grid) => {
            if (grid.children[0]) nameWidth = Math.max(nameWidth, measureFsListTextWidth(grid.children[0].textContent, rowFont));
            if (grid.children[1]) applyToWidth = Math.max(applyToWidth, measureFsListTextWidth(grid.children[1].textContent, rowFont));
            if (grid.children[2]) restartWidth = Math.max(restartWidth, measureFsListTextWidth(grid.children[2].textContent, rowFont));
            if (grid.children[3]) algoWidth = Math.max(algoWidth, measureFsListTextWidth(grid.children[3].textContent, rowFont));
            if (grid.children[4]) minerWidth = Math.max(minerWidth, measureFsListTextWidth(grid.children[4].textContent, rowFont));
        });
    }
    const namePx = Math.max(FS_LIST_NAME_MIN_PX, Math.ceil(nameWidth) + FS_LIST_AUTOSIZE_PADDING_PX);
    const applyToPx = Math.min(FS_LIST_APPLYTO_MAX_PX, Math.ceil(applyToWidth) + FS_LIST_AUTOSIZE_PADDING_PX);
    const algoPx = Math.ceil(algoWidth) + FS_LIST_AUTOSIZE_PADDING_PX;
    const minerPx = Math.ceil(minerWidth) + FS_LIST_AUTOSIZE_PADDING_PX;
    const restartPx = Math.ceil(restartWidth) + FS_LIST_AUTOSIZE_PADDING_PX;
    const template = `${namePx}px ${applyToPx}px ${restartPx}px ${algoPx}px ${minerPx}px 1fr`;
    header.style.gridTemplateColumns = template;
    rowGrids.forEach((grid) => {
        grid.style.gridTemplateColumns = template;
    });
}
const FS_ALGO_FILTER_NONE = "__none__";
function populateFsAlgoFilter() {
    const select = document.getElementById("fs-algo-filter");
    if (!select) return;
    const previousValue = select.value;
    const algos = [...new Set(
        Array.from(document.querySelectorAll("#fs-list .fs-item"))
            .map((item) => item.dataset.algo || "")
            .filter((a) => a !== "")
    )].sort((a, b) => a.localeCompare(b));
    select.innerHTML = "";
    const allOption = document.createElement("option");
    allOption.value = "";
    allOption.textContent = "All algos";
    select.appendChild(allOption);
    const noneOption = document.createElement("option");
    noneOption.value = FS_ALGO_FILTER_NONE;
    noneOption.textContent = "(no algo)";
    select.appendChild(noneOption);
    for (const algo of algos) {
        const option = document.createElement("option");
        option.value = algo;
        option.textContent = algo;
        select.appendChild(option);
    }
    const validValues = new Set(["", FS_ALGO_FILTER_NONE, ...algos]);
    select.value = validValues.has(previousValue) ? previousValue : "";
}
function populateFsMinerFilter() {
    const select = document.getElementById("fs-miner-filter");
    if (!select) return;
    const previousValue = select.value;
    const miners = [...new Set(
        Array.from(document.querySelectorAll("#fs-list .fs-item"))
            .map((item) => item.dataset.miner || "")
            .filter((m) => m !== "")
    )].sort((a, b) => a.localeCompare(b));
    select.innerHTML = "";
    const allOption = document.createElement("option");
    allOption.value = "";
    allOption.textContent = "All miners";
    select.appendChild(allOption);
    for (const miner of miners) {
        const option = document.createElement("option");
        option.value = miner;
        option.textContent = miner;
        select.appendChild(option);
    }
    select.value = miners.includes(previousValue) ? previousValue : "";
}
function filterFlightsheetList() {
    const query = (document.getElementById("fs-search")?.value || "").trim().toLowerCase();
    const algoFilter = document.getElementById("fs-algo-filter")?.value || "";
    const minerFilter = document.getElementById("fs-miner-filter")?.value || "";
    document.querySelectorAll("#fs-list .fs-item").forEach(item => {
        const name = (item.dataset.id || "").toLowerCase();
        const pool = (item.dataset.pool || "").toLowerCase();
        const matchesQuery = !query || name.includes(query) || pool.includes(query);
        const matchesAlgo = !algoFilter
            || (algoFilter === FS_ALGO_FILTER_NONE ? (item.dataset.algo || "") === "" : item.dataset.algo === algoFilter);
        const matchesMiner = !minerFilter || item.dataset.miner === minerFilter;
        item.style.display = (matchesQuery && matchesAlgo && matchesMiner) ? "" : "none";
    });
    syncFsSelectAllCheckbox();
}
function syncFsSelectAllCheckbox() {
    const headerCb = document.getElementById("fs-select-all-checkbox");
    if (!headerCb) return;
    const visible = Array.from(document.querySelectorAll("#fs-list .fs-item"))
        .filter(item => item.style.display !== "none");
    const anySelected = visible.some(item => selectedFlightsheetIds.has(item.dataset.id));
    const allSelected = visible.length > 0 && visible.every(item => selectedFlightsheetIds.has(item.dataset.id));
    headerCb.checked = allSelected;
    headerCb.indeterminate = !allSelected && anySelected;
}
function toggleSelectAllFlightsheets() {
    const visible = Array.from(document.querySelectorAll("#fs-list .fs-item"))
        .filter(item => item.style.display !== "none");
    if (visible.length === 0) return;
    const allSelected = visible.every(item => selectedFlightsheetIds.has(item.dataset.id));
    visible.forEach(item => {
        if (allSelected) {
            selectedFlightsheetIds.delete(item.dataset.id);
        } else {
            selectedFlightsheetIds.add(item.dataset.id);
        }
        const cb = item.querySelector(".fs-select-checkbox");
        if (cb) cb.checked = !allSelected;
    });
    syncFsSelectAllCheckbox();
}
async function saveFlightsheet(flightsheetId, entries) {
    if (!flightsheetId) {
        throw new Error("Flightsheet name is required");
    }
    if (!Array.isArray(entries) || entries.length === 0) {
        throw new Error("Flightsheet has no entries to save");
    }
    const res = await fetch(
        `${API}/api/flightsheets/${encodeURIComponent(flightsheetId)}`,
        {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ entries })
        }
    );
    if (!res.ok) {
        const errorData = await res.json().catch(() => ({}));
        const errorMsg = errorData.detail || errorData.message || "Failed to save flightsheet";
        throw new Error(errorMsg);
    }
    return await res.json();
}
async function saveFlightsheetFromDialog() {
    const flightsheetId = getFlightsheetName();
    try {
        const entries = collectFlightsheetEntries();
        await saveFlightsheet(flightsheetId, entries);
		loadFlightsheets();
    } catch (err) {
        alert(`Error saving flightsheet: ${err.message}`);
    }
}
let fsExtraPoolUrls = [];
let fsPoolUrlsExplicitlySet = false;
let fsPrimaryPoolUrl = "";
let fsBzminerOcJsonUserConfig = "";
let fsSrbminerOriginalUserConfig = "";
let fsXmrigHugepages = "";
let fsMinerConfigFork = "";
let fsXmrigOcJsonUserConfig = "";
let fsXmrigCpuConfigJson = "";
let fsMinerConfigOriginal = null;
let fsPoolUrlToken = "%URL%";
let fsPoolUrlNeedsToken = true;
let fsRigGpuItemOriginal = null;
let fsMinerRawOriginal = "";
let fsDualModeActive = false;
let fsDualModeSlots = { gpu: null, cpu: null, aux: null };
// Tracks which service (gpu/cpu/aux) is "current" independently of the <select>'s live DOM value.
let fsCurrentServiceType = "gpu";
function bareFsPoolUrl(url) {
    return (url || "").trim()
        .replace(/^stratum\+ssl:\/\//, "")
        .replace(/^stratum\+tcp:\/\//, "");
}
function styledFsPoolUrl(bareUrl, sslOn) {
    if (!bareUrl) return "";
    return sslOn ? "stratum+ssl://" + bareUrl : bareUrl;
}
const FS_POOL_ADDRESS_RE = /(?:stratum\+ssl:\/\/|stratum\+tcp:\/\/|ssl:\/\/|tcp:\/\/)?((?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}|(?:\d{1,3}\.){3}\d{1,3}):(\d{2,5})\b/g;
function extractPoolAddressesFromText(text) {
    if (!text) return [];
    const seen = new Set();
    const found = [];
    let m;
    FS_POOL_ADDRESS_RE.lastIndex = 0;
    while ((m = FS_POOL_ADDRESS_RE.exec(text)) !== null) {
        const addr = `${m[1]}:${m[2]}`;
        if (!seen.has(addr)) {
            seen.add(addr);
            found.push(addr);
        }
    }
    return found;
}
function updateManagePoolsBtnLabel() {
    const btn = document.getElementById("btn-manage-pools");
    if (!btn) return;
    const count = fsExtraPoolUrls.length;
    btn.title = count > 0
        ? `Add/edit backup pools for failover (${count} backup pool${count === 1 ? "" : "s"} configured)`
        : "Add/edit backup pools for failover";
}
const FS_POOL_PREVIEW_BARE_ADDR = new Set([
    "xmrig", "wildrig-multi", "wildrig", "gminer",
    "srbminer", "srbminer-multi", "srbminer-cpu", "srbminer-gpu", "srbminer-multi-cpu",
]);
function buildFsPoolCmdPreview(minerName, bareUrls, sslOn) {
    const bare = bareUrls.length > 0 ? bareUrls : [""];
    const prefixed = bare.map((h) => styledFsPoolUrl(h, sslOn));
    const W = "%WALLET%";
    const P = "%PASS%";
    const miner = (minerName || "").trim().toLowerCase();
    switch (miner) {
        case "xmrig":
            return bare.map((h) => `-o ${h} -u ${W} -p ${P}`).join(" ");
        case "wildrig-multi":
        case "wildrig":
            return bare.map((h) => `--url ${h} --user ${W} --pass ${P}`).join(" ");
        case "trex":
        case "t-rex":
            return prefixed.map((u) => `-o ${u} -u ${W} -p ${P}`).join(" ");
        case "teamredminer":
            return prefixed.map((u) => `-o ${u} -u ${W} -p ${P}`).join(" ");
        case "lolminer":
            return prefixed.map((u) => `--pool ${u} --user ${W} --pass ${P}`).join(" ");
        case "gminer":
            return bare.map((h) => `--server ${h} --user ${W}`).join(" ");
        case "rigel":
            return prefixed.map((u) => `-o ${u} -u ${W}`).join(" ");
        case "srbminer":
        case "srbminer-multi":
        case "srbminer-cpu":
        case "srbminer-gpu":
        case "srbminer-multi-cpu":
            return bare.join(",");
        case "bzminer":
            return prefixed.join(" ");
        case "onezerominer":
            return prefixed.join(",");
        default:
            return prefixed.join(" ");
    }
}
function refreshFsPoolFieldDisplay() {
    const poolEl = document.getElementById("fs-field-pool");
    if (!poolEl) return;
    if (fsExtraPoolUrls.length === 0) {
        poolEl.classList.remove("fs-pool-multi-preview");
        if (fsPrimaryPoolUrl) poolEl.value = fsPrimaryPoolUrl;
        return;
    }
    const sslOn = !!document.getElementById("fs-field-ssl")?.checked;
    const miner = document.getElementById("fs-field-miner")?.value || "";
    const primaryBare = bareFsPoolUrl(fsPrimaryPoolUrl);
    poolEl.value = buildFsPoolCmdPreview(miner, [primaryBare, ...fsExtraPoolUrls], sslOn);
    poolEl.classList.add("fs-pool-multi-preview");
}
function snapshotFsLiveStash() {
    return {
        fsExtraPoolUrls: fsExtraPoolUrls.slice(),
        fsPrimaryPoolUrl,
        fsPoolUrlsExplicitlySet,
        fsBzminerOcJsonUserConfig,
        fsSrbminerOriginalUserConfig,
        fsXmrigHugepages,
        fsMinerConfigFork,
        fsXmrigOcJsonUserConfig,
        fsXmrigCpuConfigJson,
        fsMinerConfigOriginal: fsMinerConfigOriginal ? JSON.parse(JSON.stringify(fsMinerConfigOriginal)) : null,
        fsPoolUrlToken,
        fsPoolUrlNeedsToken,
        fsRigGpuItemOriginal: fsRigGpuItemOriginal ? JSON.parse(JSON.stringify(fsRigGpuItemOriginal)) : null,
        fsMinerRawOriginal,
    };
}
function restoreFsLiveStash(stash) {
    fsExtraPoolUrls = (stash.fsExtraPoolUrls || []).slice();
    fsPrimaryPoolUrl = stash.fsPrimaryPoolUrl || "";
    fsPoolUrlsExplicitlySet = !!stash.fsPoolUrlsExplicitlySet;
    fsBzminerOcJsonUserConfig = stash.fsBzminerOcJsonUserConfig || "";
    fsSrbminerOriginalUserConfig = stash.fsSrbminerOriginalUserConfig || "";
    fsXmrigHugepages = stash.fsXmrigHugepages || "";
    fsMinerConfigFork = stash.fsMinerConfigFork || "";
    fsXmrigOcJsonUserConfig = stash.fsXmrigOcJsonUserConfig || "";
    fsXmrigCpuConfigJson = stash.fsXmrigCpuConfigJson || "";
    fsMinerConfigOriginal = stash.fsMinerConfigOriginal ? JSON.parse(JSON.stringify(stash.fsMinerConfigOriginal)) : null;
    fsPoolUrlToken = stash.fsPoolUrlToken || "";
    fsPoolUrlNeedsToken = !!stash.fsPoolUrlNeedsToken;
    fsRigGpuItemOriginal = stash.fsRigGpuItemOriginal ? JSON.parse(JSON.stringify(stash.fsRigGpuItemOriginal)) : null;
    fsMinerRawOriginal = stash.fsMinerRawOriginal || "";
}
function collectFsFieldValuesWithExtras() {
    return {
        ...collectFsFieldValues(),
        SSL: document.getElementById("fs-field-ssl")?.checked ? "true" : "false",
    };
}
function applyFsFieldValuesToForm(values) {
    for (const [key, info] of Object.entries(FS_RAW_KEY_MAP)) {
        const el = document.getElementById(info.id);
        if (!el) continue;
        const v = values[key];
        if (v === undefined) continue;
        if (info.type === "checkbox") {
            el.checked = v === "true";
        } else {
            el.value = v;
        }
    }
    const sslEl = document.getElementById("fs-field-ssl");
    if (sslEl) sslEl.checked = values.SSL === "true";
    const tlsEl = document.getElementById("fs-field-tls");
    if (tlsEl) tlsEl.checked = values.TLS === "true";
    if ("SERVICE_TYPE" in values) setFsCurrentServiceType(values.SERVICE_TYPE);
    fsUpdateRestartCheckboxDisabled();
}
function isSrbminerFamily(minerName) {
    return (minerName || "").toLowerCase().startsWith("srbminer");
}
function classifyFsItemService(item, rawTextHint) {
    const mc = (item && item.miner_config) || {};
    const cpuFieldTruthy = mc.cpu === 1 || mc.cpu === true || mc.cpu === "1" || mc.cpu === "true";
    const cpuFieldFalsy = mc.cpu === 0 || mc.cpu === false || mc.cpu === "0" || mc.cpu === "false";
    const hasDisableGpuFlag = /(^|\s)--disable-gpu(\s|$)/.test(mc.user_config || "");
    if (cpuFieldTruthy) return "cpu";
    if (cpuFieldFalsy) return "gpu";
    if (hasDisableGpuFlag) return "cpu";
    if (rawTextHint && /rig-cpu\.json/.test(rawTextHint)) return "cpu";
    if (rawTextHint && /rig-aux\.json/.test(rawTextHint)) return "aux";
    return "gpu";
}
function clearFsFields() {
    fsExtraPoolUrls = [];
    fsPrimaryPoolUrl = "";
    fsPoolUrlsExplicitlySet = false;
    fsBzminerOcJsonUserConfig = "";
    fsSrbminerOriginalUserConfig = "";
    fsXmrigHugepages = "";
    fsMinerConfigFork = "";
    fsXmrigOcJsonUserConfig = "";
    fsXmrigCpuConfigJson = "";
    fsMinerConfigOriginal = null;
    fsPoolUrlToken = "%URL%";
    fsPoolUrlNeedsToken = true;
    fsRigGpuItemOriginal = null;
    fsMinerRawOriginal = "";
    fsDualModeActive = false;
    fsDualModeSlots = { gpu: null, cpu: null, aux: null };
    fsCurrentServiceType = "gpu";
    fsSyncServiceTabsUI();
    refreshFsPoolFieldDisplay();
    updateManagePoolsBtnLabel();
    for (const id of Object.keys(FS_FIELD_DEFAULTS)) {
        const el = document.getElementById(id);
        if (!el) continue;
        el.value = id === "fs-field-service-type" ? "gpu" : "";
    }
    for (const id of Object.keys(FS_CHECKBOX_FIELD_DEFAULTS)) {
        const el = document.getElementById(id);
        if (el) el.checked = false;
    }
    const poolTokenEl = document.getElementById("fs-mc-pool-token");
    if (poolTokenEl) poolTokenEl.value = "%URL%";
    fsUpdateRestartCheckboxDisabled();
}
let managePoolsDialogMode = "flightsheet";
const FS_POOLS_DIALOG_SIZE_KEY_FLIGHTSHEET = "rigcontrol_fs_pools_dialog_size_flightsheet";
const FS_POOLS_DIALOG_SIZE_KEY_WALLET = "rigcontrol_fs_pools_dialog_size_wallet";
function fsPoolsDialogSizeStorageKey(mode) {
    return mode === "wallet" ? FS_POOLS_DIALOG_SIZE_KEY_WALLET : FS_POOLS_DIALOG_SIZE_KEY_FLIGHTSHEET;
}
function restoreFsPoolsDialogSize(mode) {
    const dialog = document.querySelector("#fs-pools-modal .fs-pools-dialog");
    if (!dialog) return;
    try {
        const raw = localStorage.getItem(fsPoolsDialogSizeStorageKey(mode));
        if (raw) {
            const size = JSON.parse(raw);
            dialog.style.width = size.width || "";
            dialog.style.height = size.height || "";
        } else {
            dialog.style.width = "";
            dialog.style.height = "";
        }
    } catch (err) {
        console.error("Failed to restore saved Manage Pools dialog size, ignoring it", err);
    }
}
function setupFsPoolsDialogSizeSaving() {
    const dialog = document.querySelector("#fs-pools-modal .fs-pools-dialog");
    const modal = document.getElementById("fs-pools-modal");
    if (!dialog || !modal || typeof ResizeObserver === "undefined") return;
    let saveTimer = null;
    const observer = new ResizeObserver(() => {
        if (modal.classList.contains("hidden")) return;
        clearTimeout(saveTimer);
        saveTimer = setTimeout(() => {
            const key = fsPoolsDialogSizeStorageKey(managePoolsDialogMode);
            localStorage.setItem(key, JSON.stringify({
                width: dialog.style.width || `${dialog.offsetWidth}px`,
                height: dialog.style.height || `${dialog.offsetHeight}px`,
            }));
        }, 300);
    });
    observer.observe(dialog);
}
const FS_MC_DIALOG_SIZE_KEY = "rigcontrol_fs_mc_dialog_size";
function restoreFsMcDialogSize() {
    const dialog = document.querySelector("#fs-miner-config-modal .fs-miner-config-dialog");
    if (!dialog) return;
    try {
        const raw = localStorage.getItem(FS_MC_DIALOG_SIZE_KEY);
        if (raw) {
            const size = JSON.parse(raw);
            dialog.style.width = size.width || "";
        } else {
            dialog.style.width = "";
        }
    } catch (err) {
        console.error("Failed to restore saved Miner Config dialog size, ignoring it", err);
    }
}
function setupFsMcDialogSizeSaving() {
    const dialog = document.querySelector("#fs-miner-config-modal .fs-miner-config-dialog");
    const modal = document.getElementById("fs-miner-config-modal");
    if (!dialog || !modal || typeof ResizeObserver === "undefined") return;
    let saveTimer = null;
    const observer = new ResizeObserver(() => {
        if (modal.classList.contains("hidden")) return;
        clearTimeout(saveTimer);
        saveTimer = setTimeout(() => {
            localStorage.setItem(FS_MC_DIALOG_SIZE_KEY, JSON.stringify({
                width: dialog.style.width || `${dialog.offsetWidth}px`,
            }));
        }, 300);
    });
    observer.observe(dialog);
}
function setManagePoolsExplainer(mode) {
    const el = document.getElementById("fs-pools-explainer");
    if (!el) return;
    el.textContent = mode === "wallet"
        ? "Each line is a list of pools, in order - first is primary, second is secondary, third is tertiary, and so on. Paste a pools list to extract pools automatically."
        : "One pool per line - first line is primary, second is secondary, third is tertiary, and so on in that order. All pools share this flightsheet's single SSL setting - not every miner supports backup pools the same way (or at all), see the rig-side docs for your miner. Paste a pools list to extract pools automatically.";
}
function openManagePoolsDialog() {
    managePoolsDialogMode = "flightsheet";
    setManagePoolsExplainer("flightsheet");
    const poolEl = document.getElementById("fs-field-pool");
    const sslOn = !!document.getElementById("fs-field-ssl")?.checked;
    const primarySource = fsExtraPoolUrls.length > 0 ? fsPrimaryPoolUrl : (poolEl?.value || "");
    const primary = bareFsPoolUrl(primarySource);
    const combinedText = [primary, ...fsExtraPoolUrls].filter((v) => v !== "").join("\n");
    const addrs = extractPoolAddressesFromText(combinedText);
    const lines = addrs.map((bare) => styledFsPoolUrl(bare, sslOn));
    const textarea = document.getElementById("fs-pools-textarea");
    if (textarea) textarea.value = lines.join("\n");
    document.querySelector("#fs-pools-modal .fs-pools-dialog")?.classList.remove("fs-pools-dialog-wide");
    restoreFsPoolsDialogSize("flightsheet");
    document.getElementById("fs-pools-modal")?.classList.remove("hidden");
}
function openWalletManagePoolsDialog() {
    managePoolsDialogMode = "wallet";
    setManagePoolsExplainer("wallet");
    const pools = getWalletPoolsFromSelect();
    const textarea = document.getElementById("fs-pools-textarea");
    if (textarea) textarea.value = pools.join("\n");
    document.querySelector("#fs-pools-modal .fs-pools-dialog")?.classList.add("fs-pools-dialog-wide");
    restoreFsPoolsDialogSize("wallet");
    document.getElementById("fs-pools-modal")?.classList.remove("hidden");
}
function closeManagePoolsDialog() {
    document.getElementById("fs-pools-modal")?.classList.add("hidden");
}
function detectExplicitSslFromText(text) {
    if (!text) return null;
    const firstLine = (text.split("\n").find((l) => l.trim() !== "") || "");
    if (/stratum\+ssl:\/\//i.test(firstLine)) return true;
    if (/stratum\+tcp:\/\//i.test(firstLine)) return false;
    if (/stratum\+ssl:\/\//i.test(text)) return true;
    if (/stratum\+tcp:\/\//i.test(text)) return false;
    return null;
}
function saveManagePoolsDialog() {
    const textarea = document.getElementById("fs-pools-textarea");
    const rawText = textarea?.value || "";
    const addrs = extractPoolAddressesFromText(rawText);
    if (managePoolsDialogMode === "wallet") {
        setWalletPoolsSelect(addrs);
        closeManagePoolsDialog();
        return;
    }
    const sslEl = document.getElementById("fs-field-ssl");
    const explicitSsl = detectExplicitSslFromText(rawText);
    let sslOn = !!sslEl?.checked;
    if (explicitSsl !== null && explicitSsl !== sslOn) {
        sslOn = explicitSsl;
        if (sslEl) sslEl.checked = sslOn;
    }
    fsPrimaryPoolUrl = addrs.length > 0 ? styledFsPoolUrl(addrs[0], sslOn) : "";
    fsExtraPoolUrls = addrs.slice(1);
    fsPoolUrlsExplicitlySet = true;
    updateManagePoolsBtnLabel();
    refreshFsPoolFieldDisplay();
    const poolEl = document.getElementById("fs-field-pool");
    if (poolEl) updateRawFromFieldChange(poolEl);
    closeManagePoolsDialog();
}
function collectFsFieldValues() {
    const val = (id) => document.getElementById(id)?.value ?? "";
    const boolVal = (id) => (document.getElementById(id)?.checked ? "true" : "false");
    return {
        SERVICE_TYPE: val("fs-field-service-type"),
        COIN: val("fs-field-coin"),
        TARGET_IMAGE: val("fs-field-target-image"),
        TARGET_NAME: val("fs-field-target-name"),
        APPLY_OC: boolVal("fs-field-apply-oc"),
        RESET_OC: boolVal("fs-field-reset-oc"),
        RESTART: boolVal("fs-field-restart"),
        VERSION: val("fs-field-miner-version"),
        MINER: val("fs-field-miner"),
        ALGO: val("fs-field-algo"),
        PASS: val("fs-field-pass"),
        POOL: val("fs-field-pool"),
        WALLET: val("fs-field-wallet"),
        TEMPLATE: val("fs-field-template"),
        TLS: boolVal("fs-field-tls"),
        ARGS: val("fs-field-args"),
        CUSTOM_MINER: val("fs-field-custom-miner"),
        CUSTOM_MINER_URL: val("fs-field-custom-miner-url"),
    };
}
function buildRigGpuItemObject(values, stash) {
    const isCustom = !!values.CUSTOM_MINER && values.CUSTOM_MINER !== "0";
    // The Miner Configuration modal's own POOL field (fs-mc-pool-token) is a literal override -
    // it applies the same way for custom and non-custom miners alike, since for custom miners
    // it's the only POOL-labeled field visible while that modal is open.
    const poolUrlOverrideRaw = (stash.fsPoolUrlToken || "").trim();
    const hasLiteralPoolOverride = poolUrlOverrideRaw !== "" && poolUrlOverrideRaw !== "%URL%";
    let poolUrls;
    if (hasLiteralPoolOverride) {
        poolUrls = [poolUrlOverrideRaw];
    } else if (stash.fsPoolUrlsExplicitlySet) {
        poolUrls = [stash.fsPrimaryPoolUrl, ...stash.fsExtraPoolUrls];
    } else if (stash.fsExtraPoolUrls.length > 0) {
        poolUrls = [stash.fsPrimaryPoolUrl, ...stash.fsExtraPoolUrls];
    } else {
        const originalExtras = Array.isArray(stash.fsRigGpuItemOriginal && stash.fsRigGpuItemOriginal.pool_urls)
            ? stash.fsRigGpuItemOriginal.pool_urls.slice(1)
            : [];
        poolUrls = [values.POOL || "", ...originalExtras];
    }
    poolUrls = poolUrls.map((u) => (u || "").trim()).filter((u) => u !== "");
    let poolSsl = false;
    let poolUrl = poolUrls[0] || "";
    if (poolUrl.startsWith("stratum+ssl://")) {
        poolSsl = true;
        poolUrl = poolUrl.slice("stratum+ssl://".length);
    } else if (poolUrl.startsWith("stratum+tcp://")) {
        poolSsl = false;
        poolUrl = poolUrl.slice("stratum+tcp://".length);
    }
    if (poolUrls.length > 0) poolUrls[0] = poolUrl;
    let resolvedMinerUrl;
    if (hasLiteralPoolOverride) {
        // An explicit literal pool override was set via the Miner Configuration modal's POOL
        // field - skip the backup/failover pool_urls list entirely and use the real address
        // directly. Applies the same way for custom and non-custom miners.
        resolvedMinerUrl = poolUrl;
    } else {
        // Default token, resolved at deploy time from the full pool_urls list (with backups).
        // Custom miners also embed this same %URL% token inside user_config/ARGS and resolve
        // it rig-side the same way, so miner_config.url should stay "%URL%" here too instead
        // of being pinned to whatever the currently-resolved pool address happens to be.
        resolvedMinerUrl = "%URL%";
    }
    const minerConfig = {
        ...(stash.fsMinerConfigOriginal ? stash.fsMinerConfigOriginal : {}),
        url: resolvedMinerUrl,
        algo: values.ALGO || "",
        pass: values.PASS || "",
        template: values.TEMPLATE || "",
    };
    if (values.WALLET) {
        minerConfig.wallet_address = values.WALLET;
    } else {
        delete minerConfig.wallet_address;
    }
    if (isCustom) {
        minerConfig.miner = values.CUSTOM_MINER;
        if (values.CUSTOM_MINER_URL) minerConfig.install_url = values.CUSTOM_MINER_URL;
    }
    const minerLowerForStash = (values.MINER || "").toLowerCase();
    const userConfigForJson =
        (!isCustom && minerLowerForStash === "bzminer" && stash.fsBzminerOcJsonUserConfig) ? stash.fsBzminerOcJsonUserConfig
        : (!isCustom && minerLowerForStash === "xmrig" && stash.fsXmrigOcJsonUserConfig) ? stash.fsXmrigOcJsonUserConfig
        : (!isCustom && isSrbminerFamily(minerLowerForStash) && stash.fsSrbminerOriginalUserConfig) ? stash.fsSrbminerOriginalUserConfig
        : values.ARGS;
    if (userConfigForJson) {
        minerConfig.user_config = userConfigForJson;
    } else {
        delete minerConfig.user_config;
    }
    if (!isCustom && minerLowerForStash === "xmrig") {
        if (stash.fsXmrigCpuConfigJson) {
            minerConfig.cpu_config = stash.fsXmrigCpuConfigJson;
        } else if ("cpu_config" in minerConfig) {
            delete minerConfig.cpu_config;
        }
    }
    if (!isCustom && minerLowerForStash === "xmrig" && stash.fsXmrigHugepages) {
        minerConfig.hugepages = Number(stash.fsXmrigHugepages);
    }
    if (!isCustom && (minerLowerForStash === "xmrig" || isSrbminerFamily(minerLowerForStash))) {
        if (values.TLS === "true") {
            minerConfig.tls = 1;
        } else if ("tls" in minerConfig) {
            delete minerConfig.tls;
        }
    }
    if (!isCustom && stash.fsMinerConfigFork) {
        minerConfig.fork = stash.fsMinerConfigFork;
    }
    const coinValue = (values.COIN || "").trim();
    const item = {
        ...(coinValue ? { coin: coinValue } : {}),
        ...(stash.fsRigGpuItemOriginal || {}),
        pool_ssl: poolSsl,
        miner: isCustom ? "custom" : (stash.fsMinerRawOriginal || values.MINER || ""),
    };
    if (coinValue) {
        item.coin = coinValue;
    } else {
        delete item.coin;
    }
    if (isCustom) {
        item.miner_alt = values.CUSTOM_MINER;
    } else if (!stash.fsMinerRawOriginal && "miner_alt" in item) {
        delete item.miner_alt;
    }
    if (values.TARGET_IMAGE) item.target_image = values.TARGET_IMAGE;
    if (values.TARGET_NAME) item.target_name = values.TARGET_NAME;
    if (values.RESET_OC) item.reset_oc = values.RESET_OC;
    if (values.APPLY_OC) item.apply_oc = values.APPLY_OC;
    if (values.RESTART) item.restart = values.RESTART;
    if (values.VERSION && values.VERSION.trim()) item.version = values.VERSION.trim();
    item.pool_urls = poolUrls;
    item.miner_config = minerConfig;
    // Same pool short-name / coin ticker auto-fill "Copy JSON" already does (addPoolSlugForClipboard/
    // addCoinTickerForClipboard below) - applied here too so the LIVE raw content (what Send/Save
    // actually uses) carries them, instead of only the separate clipboard export. Both no-op if the
    // item already has a real pool/coin value, so nothing here overrides an explicit user value.
    const [withPoolSlug] = addPoolSlugForClipboard([item]);
    const [withCoinTicker] = addCoinTickerForClipboard([withPoolSlug]);
    return withCoinTicker;
}
function buildRigGpuJsonBody(values) {
    const item = buildRigGpuItemObject(values, snapshotFsLiveStash());
    const body = { items: [item] };
    if (fsApplyToRigs.size > 0) body.apply_to_workers = Array.from(fsApplyToRigs);
    return JSON.stringify(body, null, 2);
}
function parseNativeRigGpuItemsFromRaw(rawText) {
    if (!rawText) return null;
    // The EOF marker's line tolerates stray horizontal whitespace ([ \t]* on both sides) and the
    // trailing "\n" after it is a lookahead, not a required consumed character - a paste that ends
    // right at "EOF" with no final newline, or picks up a trailing space/indentation from being
    // copied out of a rendered box (both very common), must still be recognized as native format.
    // Missing this previously made native parsing silently fail and fall through to the lossy
    // any-format field-scraping importer, which mangled real flightsheets (dropped miner_alt/
    // install_url/user_config, corrupted pool_urls to "%URL%").
    const match = rawText.match(/<<'EOF'\n([\s\S]*?)\n[ \t]*EOF[ \t]*(?=\n|$)/);
    const body = (match ? match[1] : rawText).trim();
    if (!body.startsWith("{")) return null;
    try {
        const parsed = JSON.parse(body);
        if (parsed && Array.isArray(parsed.items)) {
            const items = parsed.items.filter((it) => it && typeof it === "object");
            if (items.length > 0) {
                return {
                    items,
                    name: parsed.name,
                    apply_to_workers: Array.isArray(parsed.apply_to_workers) ? parsed.apply_to_workers : [],
                };
            }
        }
    } catch (err) {
    }
    return null;
}
const FS_KNOWN_MINER_NAMES = [
    "xmrig", "wildrig-multi", "wildrig", "t-rex", "trex", "rigel", "bzminer", "gminer",
    "lolminer", "teamredminer", "onezerominer",
    "srbminer-multi-cpu", "srbminer-cpu", "srbminer-multi", "srbminer",
    "nbminer", "keryx",
];
const FS_MINER_NAME_CANONICAL = {
    "trex": "t-rex",
    "wildrig": "wildrig-multi",
    "srbminer": "SRBMiner-MULTI",
    "srbminer-multi": "SRBMiner-MULTI",
    "srbminer-cpu": "SRBMiner-MULTI-cpu",
    "srbminer-multi-cpu": "SRBMiner-MULTI-cpu",
    "lolminer": "lolMiner",
};
function guessMinerNameFromText(rawText) {
    const lower = rawText.toLowerCase();
    for (const name of FS_KNOWN_MINER_NAMES) {
        if (lower.includes(name)) return FS_MINER_NAME_CANONICAL[name] || name;
    }
    return "";
}
function parseMinerFlagsFromText(text) {
    const flags = {};
    const rawTokens = text.split(/\s+/).filter(Boolean);
    for (let i = 0; i < rawTokens.length; i++) {
        const tok = rawTokens[i];
        if (!/^-{1,2}[a-zA-Z]/.test(tok)) continue;
        let flagName;
        let value;
        const eqIdx = tok.indexOf("=");
        if (eqIdx !== -1) {
            flagName = tok.slice(0, eqIdx);
            value = tok.slice(eqIdx + 1);
        } else {
            flagName = tok;
            const next = rawTokens[i + 1];
            if (next !== undefined && !/^-{1,2}[a-zA-Z]/.test(next)) {
                value = next;
                i++;
            } else {
                value = "true";
            }
        }
        const key = flagName.replace(/^-+/, "").toLowerCase();
        if (!flags[key]) flags[key] = [];
        flags[key].push(value);
    }
    return flags;
}
const FS_IMPORT_FLAG_ALIASES = {
    pool: ["o", "url", "pool", "server", "stratum"],
    wallet: ["u", "user", "wallet", "wal", "w"],
    pass: ["pool_password", "password", "pass", "p"],
    algo: ["a", "algo", "algorithm", "algorithm-gpu", "coin"],
    threads: ["t", "threads", "cpu-threads", "cpu_threads"],
};
function looksLikePoolAddress(value) {
    if (!value) return false;
    return /^(?:stratum\+ssl:\/\/|stratum\+tcp:\/\/|ssl:\/\/|tcp:\/\/)?(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}:\d{2,5}$/.test(String(value).trim());
}
function findBarePoolAddressesInText(text) {
    if (!text) return [];
    const tokens = text.split(/[\s,]+/).filter(Boolean);
    const found = [];
    const seen = new Set();
    for (const tok of tokens) {
        const cleaned = tok.replace(/^["'(\[]+|["')\],;]+$/g, "");
        if (looksLikePoolAddress(cleaned) && !seen.has(cleaned)) {
            seen.add(cleaned);
            found.push(cleaned);
        }
    }
    return found;
}
function extractFlightsheetFieldsFromFlags(rawText) {
    const flags = parseMinerFlagsFromText(rawText);
    const fields = {};
    const consumedKeys = new Set();
    for (const [canonical, aliasKeys] of Object.entries(FS_IMPORT_FLAG_ALIASES)) {
        for (const aliasKey of aliasKeys) {
            if (flags[aliasKey] && flags[aliasKey].length > 0) {
                if (canonical === "pool") {
                    const allPools = flags[aliasKey]
                        .flatMap((v) => String(v).split(","))
                        .map((v) => v.trim())
                        .filter(Boolean);
                    if (allPools.length > 0) {
                        fields.pool = allPools[0];
                        if (allPools.length > 1) fields.extraPools = allPools.slice(1);
                    }
                } else {
                    fields[canonical] = flags[aliasKey][0];
                }
                consumedKeys.add(aliasKey);
                break;
            }
        }
    }
    const pFlagValue = flags.p && flags.p.length > 0 ? flags.p[0] : null;
    if (pFlagValue && looksLikePoolAddress(pFlagValue)) {
        if (fields.pass === pFlagValue) delete fields.pass;
        if (!fields.pool) fields.pool = pFlagValue;
        consumedKeys.add("p");
    }
    if (flags.tls || flags.ssl) {
        fields.tls = true;
        consumedKeys.add("tls");
        consumedKeys.add("ssl");
    }
    if (!fields.pool) {
        const barePools = findBarePoolAddressesInText(rawText);
        if (barePools.length > 0) {
            fields.pool = barePools[0];
            if (barePools.length > 1) fields.extraPools = barePools.slice(1);
        }
    }
    const minerGuess = guessMinerNameFromText(rawText);
    if (minerGuess) fields.miner = minerGuess;
    const extraArgParts = [];
    for (const [key, values] of Object.entries(flags)) {
        if (consumedKeys.has(key)) continue;
        const dashes = key.length === 1 ? "-" : "--";
        for (const value of values) {
            extraArgParts.push(value === "true" ? `${dashes}${key}` : `${dashes}${key} ${value}`);
        }
    }
    if (extraArgParts.length > 0) fields.extraArgs = extraArgParts.join(" ");
    return fields;
}
const FS_IMPORT_JSON_KEY_ALIASES = {
    pool: ["pool", "pool_url", "poolurl", "url", "server", "host", "stratum_url", "endpoint"],
    wallet: ["wallet", "wallet_address", "walletaddress", "address", "user", "username"],
    pass: ["pass", "password"],
    algo: ["algo", "algorithm", "coin_algo"],
    coin: ["coin", "ticker", "symbol"],
    worker: ["worker", "workername", "worker_name", "rig_name", "rig_id"],
    miner: ["miner", "miner_name", "software"],
    name: ["name", "flightsheet_name", "title"],
};
function walkJsonForFields(node, fields, depth) {
    if (depth > 6 || node === null || node === undefined) return;
    if (Array.isArray(node)) {
        node.forEach((child) => walkJsonForFields(child, fields, depth + 1));
        return;
    }
    if (typeof node !== "object") return;
    for (const [key, value] of Object.entries(node)) {
        const keyLower = key.toLowerCase();
        if (typeof value === "string" || typeof value === "number") {
            for (const [canonical, aliases] of Object.entries(FS_IMPORT_JSON_KEY_ALIASES)) {
                if (aliases.includes(keyLower) && !fields[canonical]) {
                    fields[canonical] = String(value);
                }
            }
        } else if (value && typeof value === "object") {
            walkJsonForFields(value, fields, depth + 1);
        }
    }
}
function extractFlightsheetFieldsFromJson(obj) {
    const fields = {};
    walkJsonForFields(obj, fields, 0);
    return fields;
}
function normalizePoolUrlForImport(rawPool) {
    if (!rawPool) return { url: "", ssl: false };
    let ssl = false;
    let url = String(rawPool).trim();
    if (url.startsWith("stratum+ssl://")) {
        ssl = true;
        url = url.slice(14);
    } else if (url.startsWith("stratum+tcp://")) {
        ssl = false;
        url = url.slice(14);
    }
    return { url, ssl };
}
function buildItemFromExtractedFields(fields) {
    const { url: pool, ssl } = normalizePoolUrlForImport(fields.pool || "");
    const algo = fields.algo || "";
    const coin = fields.coin || deriveCoinForClipboard(algo, pool) || undefined;
    const poolSlug = pool ? derivePoolSlugForClipboard(pool) : null;
    const item = {};
    if (coin) item.coin = coin;
    item.pool_ssl = ssl || !!fields.tls;
    item.miner = fields.miner || "";
    if (poolSlug) item.pool = poolSlug;
    item.miner_config = {
        url: pool,
        algo: algo,
        pass: fields.pass || "x",
        template: fields.wallet ? "%WAL%" : "",
    };
    if (fields.wallet) item.miner_config.wallet_address = fields.wallet;
    if (fields.threads) item.miner_config.user_config = `-t ${fields.threads}`;
    if (fields.extraArgs) {
        item.miner_config.user_config = item.miner_config.user_config
            ? `${item.miner_config.user_config} ${fields.extraArgs}`
            : fields.extraArgs;
    }
    if (pool) {
        const extras = (fields.extraPools || []).map((p) => normalizePoolUrlForImport(p).url);
        item.pool_urls = [pool, ...extras].filter(Boolean);
    }
    return item;
}
function looksLikeMmposConfig(parsed) {
    return !!(parsed && typeof parsed === "object" &&
        parsed.miner_profile && typeof parsed.miner_profile === "object" &&
        Array.isArray(parsed.pools));
}
function translateMmposLoginTemplate(tpl) {
    if (!tpl) return "";
    return String(tpl)
        .replace(/%wallet_address%/gi, "%WAL%")
        .replace(/%rig_name%%miner_id%/gi, "%WORKER_NAME%")
        .replace(/%rig_name%/gi, "%WORKER_NAME%")
        .replace(/%miner_id%/gi, "");
}
function extractMmposExtraArgs(commandline, algo) {
    if (typeof commandline !== "string" || !commandline.trim()) return "";
    let s = commandline.trim();
    s = s.replace(/^\S+\s*/, "");
    s = s.replace(/--address\s+\S+/gi, "");
    s = s.replace(/--worker\s+\S+/gi, "");
    if (algo) {
        s = s.replace(/--algo[= ]\S+/gi, "");
    }
    return s.replace(/\s+/g, " ").trim();
}
function buildItemFromMmposConfig(parsed) {
    const mp = parsed.miner_profile || {};
    const pools = Array.isArray(parsed.pools) ? parsed.pools : [];
    const pool0 = pools[0] || {};
    const isCustom = (mp.miner || "").toLowerCase() === "custom";
    let algo = "";
    const algoMatch = typeof mp.commandline === "string" ? mp.commandline.match(/--algo[= ]([^\s]+)/i) : null;
    if (algoMatch) algo = algoMatch[1];
    const item = {};
    if (mp.coin || pool0.coin) item.coin = mp.coin || pool0.coin;
    item.pool_ssl = false;
    item.miner = isCustom ? "custom" : (mp.miner || "");
    if (isCustom) {
        item.miner_alt = mp.name || "";
    }
    item.miner_config = {
        server: pool0.url || "",
        port: pool0.port !== undefined && pool0.port !== null ? String(pool0.port) : "",
        algo: algo,
        pass: pool0.password || "x",
        template: translateMmposLoginTemplate(pool0.username),
        user_config: extractMmposExtraArgs(mp.commandline, algo),
    };
    if (isCustom && mp.custom_url) item.miner_config.install_url = mp.custom_url;
    if (pools.length > 1) {
        item.pool_urls = pools
            .map((p) => (p && p.url) ? `${p.url}${p.port ? ":" + p.port : ""}` : "")
            .filter(Boolean);
    }
    return item;
}
function looksLikeRaveosConfig(parsed) {
    return !!(parsed && typeof parsed === "object" &&
        parsed.auth_config && typeof parsed.auth_config === "object" &&
        Array.isArray(parsed.coins));
}
function minerNameFromRaveosPath(path) {
    if (typeof path !== "string" || !path.trim()) return "";
    const parts = path.trim().replace(/\/+$/, "").split("/");
    return parts[parts.length - 1] || "";
}
function raveosPoolTypeIsSsl(poolType) {
    const v = Number(poolType);
    if (!Number.isFinite(v)) return false;
    return (v & 0x2) === 0x2 || (v & 0x8) === 0x8;
}
function buildItemFromRaveosConfig(parsed) {
    const auth = parsed.auth_config || {};
    const coins = Array.isArray(parsed.coins) ? parsed.coins : [];
    const coin0 = coins[0] || {};
    const pools = Array.isArray(coin0.pools) ? coin0.pools : [];
    const pool0 = pools[0] || {};
    const item = {};
    if (coin0.name) item.coin = coin0.name;
    item.pool_ssl = raveosPoolTypeIsSsl(pool0.pool_type);
    item.miner = minerNameFromRaveosPath(parsed.miner_dir) || minerNameFromRaveosPath(parsed.work_dir) || "";
    item.miner_config = {
        url: pool0.url || "",
        algo: coin0.algo || "",
        pass: auth.pass || pool0.password || "x",
        template: auth.ewal ? "%WAL%.%WORKER_NAME%" : "",
        user_config: (parsed.args || "").trim(),
    };
    if (auth.ewal) item.miner_config.wallet_address = auth.ewal;
    const platformLower = (parsed.platform || "").toLowerCase();
    if (platformLower.includes("cpu")) item.miner_config.cpu = true;
    if (pools.length > 1) {
        item.pool_urls = pools.map((p) => (p && p.url) ? p.url : "").filter(Boolean);
    }
    return item;
}
function parseFlightsheetItemsFromAnyFormat(rawText) {
    if (!rawText || !rawText.trim()) return null;
    const trimmed = rawText.trim();
    const jsonMatch = trimmed.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
        try {
            const parsed = JSON.parse(jsonMatch[0]);
            if (looksLikeMmposConfig(parsed)) {
                const item = buildItemFromMmposConfig(parsed);
                return { items: [item], name: (parsed.miner_profile && parsed.miner_profile.name) || undefined };
            }
            const fields = extractFlightsheetFieldsFromJson(parsed);
            if (fields.pool || fields.wallet || fields.algo) {
                const item = buildItemFromExtractedFields(fields);
                return { items: [item], name: fields.name };
            }
        } catch (err) {
        }
    }
    const flagFields = extractFlightsheetFieldsFromFlags(rawText);
    if (flagFields.pool || flagFields.wallet || flagFields.algo) {
        const item = buildItemFromExtractedFields(flagFields);
        return { items: [item], name: undefined };
    }
    return null;
}
function parseRigGpuItemsFromRaw(rawText) {
    const native = parseNativeRigGpuItemsFromRaw(rawText);
    if (native) return native;
    return parseFlightsheetItemsFromAnyFormat(rawText);
}
function parseRigGpuJsonFromRaw(rawText) {
    const parsedItems = parseRigGpuItemsFromRaw(rawText);
    if (parsedItems && parsedItems.items[0]) {
        const item = parsedItems.items[0];
        item.__hiveosRoot = { name: parsedItems.name };
        return item;
    }
    return null;
}
function resolveHiveosUrlToken(url, poolUrls) {
    if (url && url !== "%URL%") return url;
    if (Array.isArray(poolUrls) && poolUrls.length > 0 && typeof poolUrls[0] === "string") {
        return poolUrls[0];
    }
    return url || "";
}
function resolveHiveosServerPortTokens(server, port, poolUrls) {
    if (!server && !port) return "";
    let host = server || "";
    let p = port || "";
    if (host === "%URL_HOST%" || p === "%URL_PORT%") {
        const primary = Array.isArray(poolUrls) && poolUrls.length > 0 && typeof poolUrls[0] === "string"
            ? bareFsPoolUrl(poolUrls[0])
            : "";
        const idx = primary.lastIndexOf(":");
        const fallbackHost = idx === -1 ? primary : primary.slice(0, idx);
        const fallbackPort = idx === -1 ? "" : primary.slice(idx + 1);
        if (host === "%URL_HOST%") host = fallbackHost;
        if (p === "%URL_PORT%") p = fallbackPort;
    }
    if (!host || !p) return "";
    return `${host}:${p}`;
}
const BZMINER_OC_JSON_KEY_TO_FLAG = {
    cpu_threads: "--cpu_threads",
    oc_lock_core_clock: "--oc_lock_core_clock",
    oc_core_clock_offset: "--oc_core_clock_offset",
    oc_lock_memory_clock: "--oc_lock_memory_clock",
    oc_memory_clock_offset: "--oc_memory_clock_offset",
    oc_power_limit: "--oc_power_limit",
    oc_core_volt_offset: "--oc_core_volt_offset",
    oc_memory_volt_offset: "--oc_memory_volt_offset",
    oc_fan_speed: "--oc_fan_speed",
    oc_pstate: "--oc_pstate",
};
function convertBzminerOcJsonToArgs(userConfig) {
    const lines = (userConfig || "")
        .split(/\r\n|\r|\n/)
        .map((l) => l.trim())
        .filter((l) => l !== "");
    const flags = [];
    for (const line of lines) {
        const m = line.match(/^"([a-zA-Z0-9_]+)"\s*:\s*(.+?),?$/);
        if (!m) continue;
        const key = m[1];
        let rawValue = m[2].trim();
        rawValue = rawValue.replace(/^"(.*)"$/, "$1");
        rawValue = rawValue.replace(/^\[(.*)\]$/, "$1");
        const value = rawValue.split(",").map((v) => v.trim()).filter((v) => v !== "").join(" ");
        if (value === "") continue;
        const flag = BZMINER_OC_JSON_KEY_TO_FLAG[key];
        if (flag) flags.push(`${flag} ${value}`);
    }
    return flags.join(" ");
}
const XMRIG_USER_CONFIG_KEY_TO_FLAG = {
    "donate-level": "--donate-level",
};
function xmrigValueIsTruthy(rawValue) {
    return rawValue === "true" || rawValue === "1";
}
function xmrigValueIsFalsy(rawValue) {
    return rawValue === "false" || rawValue === "0";
}
function convertXmrigUserConfigToArgs(userConfig) {
    const text = userConfig || "";
    const flags = [];
    const randomxMatch = text.match(/"randomx"\s*:\s*\{\s*"1gb-pages"\s*:\s*(true|false|1|0)\s*\}/);
    if (randomxMatch && xmrigValueIsTruthy(randomxMatch[1])) {
        flags.push("--randomx-1gb-pages");
    }
    const lines = text
        .split(/\r\n|\r|\n/)
        .map((l) => l.trim())
        .filter((l) => l !== "");
    for (const line of lines) {
        const m = line.match(/^"([a-zA-Z0-9_-]+)"\s*:\s*(.+?),?$/);
        if (!m) continue;
        const key = m[1];
        const rawValue = m[2].trim().replace(/^"(.*)"$/, "$1");
        if (rawValue === "") continue;
        if (key === "keepalive") {
            if (xmrigValueIsTruthy(rawValue)) flags.push("--keepalive");
            continue;
        }
        if (key === "tls") {
            if (xmrigValueIsTruthy(rawValue)) flags.push("--tls");
            continue;
        }
        if (key === "cpu") {
            if (xmrigValueIsFalsy(rawValue)) flags.push("--no-cpu");
            continue;
        }
        const flag = XMRIG_USER_CONFIG_KEY_TO_FLAG[key];
        if (flag) flags.push(`${flag} ${rawValue}`);
    }
    return flags.join(" ");
}
function convertXmrigCpuConfigToArgs(cpuConfig) {
    const text = cpuConfig || "";
    const wrapped = text.match(/"cpu"\s*:\s*\{([\s\S]*)\}\s*$/);
    const body = wrapped ? wrapped[1] : text;
    const flags = [];
    const entryRe = /"([a-zA-Z0-9_-]+)"\s*:\s*(\[[^\]]*\]|"[^"]*"|null|true|false|-?\d+(?:\.\d+)?)/g;
    let m;
    while ((m = entryRe.exec(body)) !== null) {
        const key = m[1];
        const raw = m[2];
        switch (key) {
            case "huge-pages":
                if (xmrigValueIsFalsy(raw)) flags.push("--no-huge-pages");
                break;
            case "priority":
                if (raw !== "null") flags.push(`--cpu-priority=${raw}`);
                break;
            case "memory-pool":
                if (xmrigValueIsFalsy(raw)) flags.push("--cpu-memory-pool=0");
                break;
            case "asm":
                if (xmrigValueIsTruthy(raw)) flags.push("--asm=auto");
                else if (xmrigValueIsFalsy(raw)) flags.push("--asm=none");
                else if (raw.startsWith('"')) flags.push(`--asm=${raw.replace(/^"(.*)"$/, "$1")}`);
                break;
            case "rx": {
                const nums = raw
                    .replace(/^\[|\]$/g, "")
                    .split(",")
                    .map((s) => s.trim())
                    .filter((s) => s !== "")
                    .map(Number)
                    .filter((n) => Number.isInteger(n) && n >= 0);
                if (nums.length > 0) {
                    let mask = 0n;
                    for (const n of nums) mask |= (1n << BigInt(n));
                    flags.push(`--threads=${nums.length}`);
                    flags.push(`--cpu-affinity=0x${mask.toString(16).toUpperCase()}`);
                }
                break;
            }
            default:
                break;
        }
    }
    return flags.join(" ");
}
function buildXmrigArgsFromConfig(userConfig, cpuConfig) {
    const parts = [];
    const uc = userConfig || "";
    parts.push(/^\s*"/.test(uc) ? convertXmrigUserConfigToArgs(uc) : uc.replace(/\r\n|\r|\n/g, " ").replace(/\s+/g, " ").trim());
    const cc = cpuConfig || "";
    if (/^\s*"cpu"\s*:/.test(cc)) {
        const ccFlags = convertXmrigCpuConfigToArgs(cc);
        if (ccFlags) parts.push(ccFlags);
    }
    return parts.filter((p) => p !== "").join(" ");
}
function fsFieldsFromRigGpuJsonItem(item) {
    const mc = item.miner_config || {};
    const isCustom = item.miner === "custom";
    let pool = "";
    {
        let resolvedUrl = resolveHiveosUrlToken(mc.url || "", item.pool_urls);
        if (!resolvedUrl && (mc.server || mc.port)) {
            resolvedUrl = resolveHiveosServerPortTokens(mc.server || "", mc.port || "", item.pool_urls);
        }
        if (resolvedUrl) {
            pool = item.pool_ssl === true ? "stratum+ssl://" + resolvedUrl : resolvedUrl;
        }
    }
    return {
        COIN: item.coin || "",
        TARGET_IMAGE: item.target_image || "",
        TARGET_NAME: item.target_name || "",
        RESET_OC: item.reset_oc || "",
        APPLY_OC: item.apply_oc || "",
        RESTART: item.restart || "",
        VERSION: item.version || "",
        MINER: isCustom ? "custom" : (item.miner_alt || mc.fork || item.miner || ""),
        ALGO: mc.algo || "",
        POOL: pool,
        TEMPLATE: mc.template || "",
        WALLET: mc.wallet_address || "",
        PASS: mc.pass || "",
        ARGS: (() => {
            const resolvedMinerLower = (item.miner_alt || mc.fork || item.miner || "").toLowerCase();
            if (isCustom) {
                return (mc.user_config || "").replace(/\r\n|\r|\n/g, " ").replace(/\s+/g, " ").trim();
            }
            if (resolvedMinerLower === "bzminer" && /^\s*"/.test(mc.user_config || "")) {
                return convertBzminerOcJsonToArgs(mc.user_config || "");
            }
            if (resolvedMinerLower === "xmrig") {
                let args = buildXmrigArgsFromConfig(mc.user_config || "", mc.cpu_config || "");
                const tlsRequested = mc.tls === 1 || mc.tls === true || mc.tls === "1" || mc.tls === "true";
                if (tlsRequested && !/(^|\s)--tls(\s|$)/.test(args)) {
                    args = (args ? args + " " : "") + "--tls";
                }
                const cpuDisabled = mc.cpu === 0 || mc.cpu === false || mc.cpu === "0" || mc.cpu === "false";
                if (cpuDisabled && !/(^|\s)--no-cpu(\s|$)/.test(args)) {
                    args = (args ? args + " " : "") + "--no-cpu";
                }
                return args;
            }
            if (isSrbminerFamily(resolvedMinerLower)) {
                let args = (mc.user_config || "").replace(/\r\n|\r|\n/g, " ").replace(/\s+/g, " ").trim();
                const tlsRequested = mc.tls === 1 || mc.tls === true || mc.tls === "1" || mc.tls === "true";
                if (tlsRequested && !/(^|\s)--tls(\s|$)/.test(args)) {
                    args = (args ? args + " " : "") + "--tls true";
                }
                return args;
            }
            return (mc.user_config || "").replace(/\r\n|\r|\n/g, " ").replace(/\s+/g, " ").trim();
        })(),
        CUSTOM_MINER: isCustom ? (item.miner_alt || mc.miner || "") : "",
        CUSTOM_MINER_URL: isCustom ? (mc.install_url || "") : "",
    };
}
// RESTART controls whether the block restarts docker_events_<svc> after writing the config; default unchecked is write-only.
function fsApplyRestartLine(blockText, svc, restartOn) {
    const stripped = blockText.replace(new RegExp(`\\n?sudo systemctl restart docker_events_${svc}\\s*$`), "");
    return restartOn ? `${stripped}\nsudo systemctl restart docker_events_${svc}` : stripped;
}
function fsTemplateForService(svc) {
    const fsCfg = TEMPLATES_CONFIG.flightsheet;
    return svc === "cpu" ? fsCfg.cpu_template : svc === "aux" ? fsCfg.aux_template : fsCfg.gpu_template;
}
// Maps the app's internal miner name to its key in /etc/rigcontrol/miner.conf; unlisted miners fall back to an uppercased, alnum-only guess.
const FS_MINER_VERSION_KEY_MAP = {
    "xmrig": "XMRIG",
    "wildrig-multi": "WILDRIG",
    "wildrig": "WILDRIG",
    "t-rex": "TREXMINER",
    "trex": "TREXMINER",
    "rigel": "RIGEL",
    "bzminer": "BZMINER",
    "gminer": "GMINER",
    "lolminer": "LOLMINER",
    "teamredminer": "TEAMREDMINER",
    "onezerominer": "ONEZEROMINER",
    "srbminer": "SRBMINER",
    "srbminer-multi": "SRBMINER",
    "srbminer-gpu": "SRBMINER",
    "srbminer-cpu": "SRBMINER-CPU",
    "srbminer-multi-cpu": "SRBMINER-CPU",
    "nbminer": "NBMINER",
};
function fsMinerVersionKey(minerName) {
    const lower = (minerName || "").trim().toLowerCase();
    if (FS_MINER_VERSION_KEY_MAP[lower]) return FS_MINER_VERSION_KEY_MAP[lower];
    const fallback = lower.replace(/[^a-z0-9]+/g, "").toUpperCase();
    return fallback || "MINER";
}
// Pins a miner's version by writing MINERNAME_VERSION "x.y.z" to /etc/rigcontrol/miner.conf; no-op when version is blank.
function fsApplyVersionBlock(blockText, version, minerName) {
    const v = (version || "").trim().replace(/'/g, "");
    if (!v) return blockText;
    const key = `${fsMinerVersionKey(minerName)}_VERSION`;
    const line = `${key} "${v}"`;
    // Updates the line in place via sed if present, appends otherwise; other miners' lines are untouched.
    const sedReplacement = line.replace(/[\\/&]/g, "\\$&");
    const confBlock =
        "sudo mkdir -p /etc/rigcontrol\n" +
        "sudo touch /etc/rigcontrol/miner.conf\n" +
        `if sudo grep -q '^${key} ' /etc/rigcontrol/miner.conf; then\n` +
        `    sudo sed -i 's/^${key} .*/${sedReplacement}/' /etc/rigcontrol/miner.conf\n` +
        "else\n" +
        `    echo '${line}' | tee -a /etc/rigcontrol/miner.conf > /dev/null\n` +
        "fi";
    return `${confBlock}\n${blockText}`;
}
function buildFsBlock(mode) {
    const values = collectFsFieldValues();
    const block = fillPlaceholders(fsTemplateForService(mode), {
        RIG_GPU_JSON: buildRigGpuJsonBody(values),
    });
    const withRestart = fsApplyRestartLine(block, mode, values.RESTART === "true");
    return fsApplyVersionBlock(withRestart, values.VERSION, values.MINER);
}
// Builds the raw content sent on "Send it": one tee/systemctl block per configured service (gpu/cpu/aux).
function buildFsCombinedBlock() {
    const activeService = getCurrentFsServiceType();
    const blocks = [];
    for (const svc of ["gpu", "cpu", "aux"]) {
        if (svc === activeService) {
            const values = collectFsFieldValues();
            if (!fsSlotHasRealContent(values)) continue;
            const block = fillPlaceholders(fsTemplateForService(svc), {
                RIG_GPU_JSON: buildRigGpuJsonBody(values),
            });
            const withRestart = fsApplyRestartLine(block, svc, values.RESTART === "true");
            blocks.push(fsApplyVersionBlock(withRestart, values.VERSION, values.MINER));
            continue;
        }
        const slot = fsDualModeSlots[svc];
        if (!slot) continue;
        const item = buildRigGpuItemObject(slot.values, slot.stash);
        const body = { items: [item] };
        if (fsApplyToRigs.size > 0) body.apply_to_workers = Array.from(fsApplyToRigs);
        const block = fillPlaceholders(fsTemplateForService(svc), {
            RIG_GPU_JSON: JSON.stringify(body, null, 2),
        });
        const withRestart = fsApplyRestartLine(block, svc, slot.values.RESTART === "true");
        blocks.push(fsApplyVersionBlock(withRestart, slot.values.VERSION, slot.values.MINER));
    }
    return blocks.join("\n");
}
// Whether a service OTHER than the given one has real stashed content; decides if a full rebuild is needed.
function fsHasOtherRealSlot(activeService) {
    return ["gpu", "cpu", "aux"].some((svc) => svc !== activeService && !!fsDualModeSlots[svc]);
}
// Live-editing preview: shows only the currently active tab's block. Full multi-service combine happens at Save/Send.
function buildFsActivePreview() {
    const activeService = getCurrentFsServiceType();
    const values = collectFsFieldValues();
    if (!fsSlotHasRealContent(values)) return "";
    return buildFsBlock(activeService);
}
// Called right before Save/Send to recombine every populated service into the raw box.
function fsFinalizeRawForAction() {
    const rawEl = document.getElementById("fs-raw");
    if (!rawEl) return "";
    const combined = buildFsCombinedBlock();
    if (combined) {
        rawEl.value = combined;
        autoResizeFsRaw();
    }
    return rawEl.value;
}
function resolveUrlTokenForClipboard(items) {
    return items.map((item) => {
        if (!item || typeof item !== "object" || !item.miner_config) return item;
        const url = item.miner_config.url;
        if (typeof url !== "string" || !url.includes("%URL%")) return item;
        if (item.pool && String(item.pool).trim()) return item;
        const realUrl = Array.isArray(item.pool_urls) && item.pool_urls.length > 0
            ? (item.pool_urls[0] || "").trim()
            : "";
        if (!realUrl) return item;
        return {
            ...item,
            miner_config: { ...item.miner_config, url: url.split("%URL%").join(realUrl) },
        };
    });
}
function deriveHostLabelForClipboard(poolUrlValue) {
    if (!poolUrlValue) return null;
    const token = String(poolUrlValue).trim().split(/[\s,]+/)[0] || "";
    const host = token.replace(/^stratum\+(ssl|tcp):\/\//, "").split(":")[0].trim();
    if (!host) return null;
    // An IPv4 address (a local node, a private pool proxy, etc.) has no real hostname structure to
    // pull a label from - picking one octet (e.g. "0" out of "10.10.0.126") and calling it a pool/coin
    // name is actively misleading rather than merely unhelpful, so bail out instead of guessing.
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return null;
    const labels = host.split(".").filter(Boolean);
    if (labels.length === 0) return null;
    return labels.length >= 2 ? labels[labels.length - 2] : labels[0];
}
function derivePoolSlugForClipboard(poolUrlValue) {
    const derived = deriveHostLabelForClipboard(poolUrlValue);
    if (!derived) return null;
    return TEMPLATES_CONFIG.flightsheet_derivation.pool_slug_overrides[derived] || derived;
}
function addPoolSlugForClipboard(items) {
    return items.map((item) => {
        if (!item || typeof item !== "object") return item;
        if (item.pool && String(item.pool).trim()) return item;
        // Custom miners (miner: "custom", real identity in miner_alt) used to be skipped here on the
        // assumption they'd rarely need this label - in practice most real fleets run custom binaries
        // almost exclusively, so this left the "Copy JSON" pool slug blank for nearly every flightsheet.
        // pool_urls is populated the same way regardless of miner type, so derive it here too.
        const primary = Array.isArray(item.pool_urls) && item.pool_urls.length > 0
            ? (item.pool_urls[0] || "").trim()
            : "";
        if (!primary) return item;
        const poolSlug = derivePoolSlugForClipboard(primary);
        if (!poolSlug) return item;
        const newItem = {};
        let inserted = false;
        for (const [k, v] of Object.entries(item)) {
            newItem[k] = v;
            if (k === "miner" && !inserted) {
                newItem.pool = poolSlug;
                inserted = true;
            }
        }
        if (!inserted) newItem.pool = poolSlug;
        return newItem;
    });
}
function vowelStrippedFallback(text) {
    if (!text) return null;
    const stripped = String(text).replace(/[aeiou]/gi, "").toUpperCase();
    return stripped || null;
}
function deriveCoinForClipboard(algo, poolUrlValue) {
    // Unlike derivePoolSlugForClipboard() (pool-address-only, no algo needed), this used to bail out
    // entirely with an empty algo before ever looking at the pool address - so a flightsheet whose
    // ALGO field wasn't populated yet (or a custom miner with no dedicated algo field) got "pool"
    // filled but never "coin", even though the pool-hint/vowel-fallback checks below don't need algo.
    const deriv = TEMPLATES_CONFIG.flightsheet_derivation;
    const algoKey = algo ? String(algo).trim().toLowerCase() : "";
    if (algoKey && deriv.algo_to_coin[algoKey]) return deriv.algo_to_coin[algoKey];
    const token = (poolUrlValue || "").trim().split(/[\s,]+/)[0] || "";
    const host = token.replace(/^stratum\+(ssl|tcp):\/\//, "").split(":")[0].toLowerCase();
    for (const [hint, ticker] of deriv.pool_coin_hints) {
        if (host.includes(hint)) return ticker;
    }
    if (algoKey && algoKey in deriv.ambiguous_algo_defaults && deriv.ambiguous_algo_defaults[algoKey]) {
        return deriv.ambiguous_algo_defaults[algoKey];
    }
    return vowelStrippedFallback(deriveHostLabelForClipboard(poolUrlValue));
}
function addCoinTickerForClipboard(items) {
    return items.map((item) => {
        if (!item || typeof item !== "object") return item;
        if (item.coin && String(item.coin).trim()) return item;
        // See addPoolSlugForClipboard() above - same reasoning, custom miners shouldn't be excluded.
        const algo = item.miner_config && item.miner_config.algo;
        const primary = Array.isArray(item.pool_urls) && item.pool_urls.length > 0
            ? (item.pool_urls[0] || "").trim()
            : "";
        const coin = deriveCoinForClipboard(algo, primary);
        if (!coin) return item;
        return { coin, ...item };
    });
}
function buildFsCombinedJson() {
    const serviceType = (document.getElementById("fs-field-service-type")?.value || "").trim().toLowerCase();
    const activeService = serviceType === "cpu" ? "cpu" : serviceType === "aux" ? "aux" : "gpu";
    const activeItem = buildRigGpuItemObject(collectFsFieldValues(), snapshotFsLiveStash());
    if (activeService === "aux") {
        const withPoolSlugAux = addPoolSlugForClipboard([activeItem]);
        const clipboardItemsAux = resolveUrlTokenForClipboard(withPoolSlugAux);
        const bodyAux = { items: clipboardItemsAux };
        if (fsApplyToRigs.size > 0) bodyAux.apply_to_workers = Array.from(fsApplyToRigs);
        return JSON.stringify(bodyAux, null, 2);
    }
    const otherService = activeService === "cpu" ? "gpu" : "cpu";
    const otherSlot = fsDualModeSlots[otherService];
    const otherItem = otherSlot ? buildRigGpuItemObject(otherSlot.values, otherSlot.stash) : null;
    const items = otherItem
        ? (activeService === "cpu" ? [activeItem, otherItem] : [otherItem, activeItem])
        : [activeItem];
    const withPoolSlug = addPoolSlugForClipboard(items);
    const clipboardItems = resolveUrlTokenForClipboard(withPoolSlug);
    const body = { items: clipboardItems };
    if (fsApplyToRigs.size > 0) body.apply_to_workers = Array.from(fsApplyToRigs);
    return JSON.stringify(body, null, 2);
}
async function copyFsCombinedJsonToClipboard() {
    const btn = document.getElementById("btn-fs-copy-json");
    const json = buildFsCombinedJson();
    let copied = false;
    if (window.isSecureContext && navigator.clipboard?.writeText) {
        try {
            await navigator.clipboard.writeText(json);
            copied = true;
        } catch (e) {
            console.error("navigator.clipboard.writeText failed, falling back", e);
        }
    }
    if (!copied) {
        try {
            const ta = document.createElement("textarea");
            ta.value = json;
            ta.style.position = "fixed";
            ta.style.top = "0";
            ta.style.left = "0";
            ta.style.opacity = "0";
            document.body.appendChild(ta);
            ta.focus();
            ta.select();
            copied = document.execCommand("copy");
            document.body.removeChild(ta);
        } catch (e) {
            console.error("Fallback clipboard copy failed", e);
        }
    }
    if (btn) {
        const original = btn.innerHTML;
        btn.classList.add(copied ? "copied" : "copy-failed");
        btn.innerHTML = copied ? "&#10003; Copied!" : "&#10007; Copy failed";
        btn.title = copied
            ? "Copied!"
            : "Copy failed - your browser blocked clipboard access. Select the JSON manually instead.";
        setTimeout(() => {
            btn.classList.remove("copied", "copy-failed");
            btn.innerHTML = original;
            btn.title = "Copies current raw content to clipboard in HiveOS compatible flightsheet JSON";
        }, 1500);
    }
    if (!copied) {
        console.error("Unable to copy flightsheet JSON to clipboard - no clipboard API available and the execCommand fallback also failed");
    }
}
function getCurrentFsServiceType() {
    return fsCurrentServiceType;
}
function setFsCurrentServiceType(v) {
    const norm = (v || "").trim().toLowerCase();
    fsCurrentServiceType = (norm === "cpu" || norm === "aux") ? norm : "gpu";
    fsSyncServiceTabsUI();
}
function resetFsFieldInputsForNewSlot() {
    // Same reset as clearFsFields(), but leaves fsDualModeSlots/fsApplyToRigs untouched so other tabs' stash survives.
    fsExtraPoolUrls = [];
    fsPrimaryPoolUrl = "";
    fsPoolUrlsExplicitlySet = false;
    fsBzminerOcJsonUserConfig = "";
    fsSrbminerOriginalUserConfig = "";
    fsXmrigHugepages = "";
    fsMinerConfigFork = "";
    fsXmrigOcJsonUserConfig = "";
    fsXmrigCpuConfigJson = "";
    fsMinerConfigOriginal = null;
    fsPoolUrlToken = "%URL%";
    fsPoolUrlNeedsToken = true;
    fsRigGpuItemOriginal = null;
    fsMinerRawOriginal = "";
    refreshFsPoolFieldDisplay();
    updateManagePoolsBtnLabel();
    for (const id of Object.keys(FS_FIELD_DEFAULTS)) {
        const el = document.getElementById(id);
        if (!el) continue;
        el.value = id === "fs-field-service-type" ? "gpu" : "";
    }
    for (const id of Object.keys(FS_CHECKBOX_FIELD_DEFAULTS)) {
        const el = document.getElementById(id);
        if (el) el.checked = false;
    }
    syncFsMcPoolTokenField();
    fsUpdateRestartCheckboxDisabled();
}
function syncFsMcPoolTokenField() {
    const el = document.getElementById("fs-mc-pool-token");
    if (el) el.value = fsPoolUrlToken || "%URL%";
}
function fsSlotHasRealContent(values) {
    return !!((values.MINER && values.MINER.trim()) || (values.CUSTOM_MINER && values.CUSTOM_MINER.trim()));
}
// RESTART is disabled/cleared whenever the active tab has no miner configured.
function fsUpdateRestartCheckboxDisabled() {
    const el = document.getElementById("fs-field-restart");
    if (!el) return;
    const hasContent = fsSlotHasRealContent(collectFsFieldValues());
    el.disabled = !hasContent;
    if (!hasContent) el.checked = false;
    fsSyncServiceTabsUI();
    // VERSION shares the same gate, plus its own custom-miner check.
    updateFsMinerConfigCustomVisibility();
}
function handleFsServiceSwitch(newServiceRaw) {
    const rawNewService = (newServiceRaw || "").trim().toLowerCase();
    const newService = rawNewService === "cpu" ? "cpu" : rawNewService === "aux" ? "aux" : "gpu";
    const oldService = getCurrentFsServiceType();
    if (newService === oldService) return;
    // Stash whatever's live into its own slot, but only if a miner is actually configured.
    const oldValues = collectFsFieldValuesWithExtras();
    oldValues.SERVICE_TYPE = oldService;
    fsDualModeSlots[oldService] = fsSlotHasRealContent(oldValues)
        ? { stash: snapshotFsLiveStash(), values: oldValues }
        : null;
    const targetSlot = fsDualModeSlots[newService];
    if (targetSlot) {
        restoreFsLiveStash(targetSlot.stash);
        applyFsFieldValuesToForm(targetSlot.values);
        refreshFsPoolFieldDisplay();
        updateManagePoolsBtnLabel();
        syncFsMcPoolTokenField();
    } else {
        resetFsFieldInputsForNewSlot();
    }
    const serviceTypeEl = document.getElementById("fs-field-service-type");
    if (serviceTypeEl) serviceTypeEl.value = newService;
    fsCurrentServiceType = newService;
    fsSyncServiceTabsUI();
    // GPU/CPU/AUX combine into one multi-block raw output once more than one has real data.
    fsDualModeActive = fsHasOtherRealSlot(newService);
    const rawEl = document.getElementById("fs-raw");
    if (rawEl) {
        // Live preview only shows the active tab; full combine happens at Save/Send.
        rawEl.value = buildFsActivePreview();
        autoResizeFsRaw();
    }
}
let fsMcCancelSnapshot = null;
let fsMcPortalRecords = [];
function fsMcMoveIntoSlot(el, slotId) {
    if (!el) return;
    const slot = document.getElementById(slotId);
    if (!slot) return;
    fsMcPortalRecords.push({ el, parent: el.parentNode, nextSibling: el.nextSibling });
    slot.appendChild(el);
}
function fsMcRestoreAllPortals() {
    for (let i = fsMcPortalRecords.length - 1; i >= 0; i--) {
        const rec = fsMcPortalRecords[i];
        if (!rec.parent) continue;
        rec.parent.insertBefore(rec.el, rec.nextSibling);
    }
    fsMcPortalRecords = [];
}
function fsMcFieldGroup(inputId) {
    const el = document.getElementById(inputId);
    return el ? el.closest(".field-group") : null;
}
function updateFsMinerConfigTitle() {
    const titleEl = document.getElementById("fs-miner-config-title");
    if (!titleEl) return;
    const minerName = (document.getElementById("fs-field-miner")?.value || "").trim();
    if (!minerName) {
        titleEl.textContent = "Miner configuration";
    } else if (minerName.toLowerCase() === "custom") {
        titleEl.textContent = "Custom configuration";
    } else {
        titleEl.textContent = `${minerName} configuration`;
    }
}
function updateFsMinerConfigCustomVisibility() {
    const isCustom = (document.getElementById("fs-field-miner")?.value || "").trim().toLowerCase() === "custom";
    const slot = document.getElementById("fs-mc-slot-custom");
    if (slot) slot.classList.toggle("hidden", !isCustom);
    // VERSION doesn't apply to custom miners or when this tab has no miner defined yet.
    const versionEl = document.getElementById("fs-field-miner-version");
    if (versionEl) {
        const hasNoMiner = !fsSlotHasRealContent(collectFsFieldValues());
        const shouldDisable = isCustom || hasNoMiner;
        versionEl.disabled = shouldDisable;
        if (shouldDisable) versionEl.value = "";
    }
}
const FS_MC_CUSTOM_LABEL_OVERRIDES = {
    "fs-field-custom-miner": "Miner name",
    "fs-field-custom-miner-url": "Installation URL",
    "fs-field-template": "Wallet and worker template",
};
let fsMcLabelOriginals = {};
function fsMcApplyCustomLabels() {
    for (const [inputId, newText] of Object.entries(FS_MC_CUSTOM_LABEL_OVERRIDES)) {
        const label = document.querySelector(`label[for="${inputId}"]`);
        if (!label) continue;
        if (!(inputId in fsMcLabelOriginals)) fsMcLabelOriginals[inputId] = label.innerHTML;
        label.textContent = newText;
    }
}
function fsMcRestoreCustomLabels() {
    for (const [inputId, originalHtml] of Object.entries(fsMcLabelOriginals)) {
        const label = document.querySelector(`label[for="${inputId}"]`);
        if (label) label.innerHTML = originalHtml;
    }
    fsMcLabelOriginals = {};
}
// Whether a given service's RESTART checkbox is checked - the active tab's live checkbox, or its stashed value.
function fsTabHasRestart(svc) {
    if (svc === getCurrentFsServiceType()) {
        return !!document.getElementById("fs-field-restart")?.checked;
    }
    const slot = fsDualModeSlots[svc];
    return !!(slot && slot.values && slot.values.RESTART === "true");
}
function fsSyncServiceTabsUI() {
    const active = getCurrentFsServiceType();
    document.querySelectorAll("#fs-miner-config-tabs .fs-miner-config-tab").forEach((btn) => {
        btn.classList.toggle("active", btn.dataset.service === active);
        btn.classList.toggle("restart-on", fsTabHasRestart(btn.dataset.service));
    });
    document.querySelectorAll("#fs-service-tabs .fs-service-tab").forEach((btn) => {
        btn.classList.toggle("active", btn.dataset.service === active);
        btn.classList.toggle("restart-on", fsTabHasRestart(btn.dataset.service));
    });
}
// Click handler for the main-page GPU/CPU/AUX tabs.
function fsSwitchServiceTab(service) {
    handleFsServiceSwitch(service);
    fsSyncServiceTabsUI();
}
function openFsMinerConfigModal() {
    const modal = document.getElementById("fs-miner-config-modal");
    if (!modal) return;
    fsMcMoveIntoSlot(fsMcFieldGroup("fs-field-algo"), "fs-mc-slot-algo");
    fsMcMoveIntoSlot(fsMcFieldGroup("fs-field-template"), "fs-mc-slot-wallet");
    fsMcMoveIntoSlot(fsMcFieldGroup("fs-field-pass"), "fs-mc-slot-pass");
    fsMcMoveIntoSlot(fsMcFieldGroup("fs-field-args"), "fs-mc-slot-args");
    fsMcMoveIntoSlot(document.getElementById("fs-custom-miner-row"), "fs-mc-slot-custom");
    fsMcMoveIntoSlot(document.querySelector(".fs-click-to-fill-group"), "fs-mc-slot-tokens");
    for (const id of ["fs-field-ssl", "fs-field-tls", "fs-field-apply-oc", "fs-field-reset-oc"]) {
        const inputEl = document.getElementById(id);
        const label = inputEl ? inputEl.closest("label.checkbox-label") : null;
        fsMcMoveIntoSlot(label, "fs-mc-slot-checks");
    }
    {
        // RESTART lives in the footer, not with the other checkboxes in the body.
        const restartEl = document.getElementById("fs-field-restart");
        const restartLabel = restartEl ? restartEl.closest("label.checkbox-label") : null;
        fsMcMoveIntoSlot(restartLabel, "fs-mc-slot-restart");
    }
    fsMcCancelSnapshot = {
        slots: JSON.parse(JSON.stringify(fsDualModeSlots)),
        dualActive: fsDualModeActive,
        liveStash: snapshotFsLiveStash(),
        liveValues: collectFsFieldValuesWithExtras(),
        rawValue: document.getElementById("fs-raw")?.value ?? "",
    };
    fsMcApplyCustomLabels();
    updateFsMinerConfigTitle();
    updateFsMinerConfigCustomVisibility();
    fsSyncServiceTabsUI();
    syncFsMcPoolTokenField();
    restoreFsMcDialogSize();
    modal.classList.remove("hidden");
}
function closeFsMinerConfigModal() {
    const modal = document.getElementById("fs-miner-config-modal");
    if (!modal) return;
    fsMcRestoreCustomLabels();
    fsMcRestoreAllPortals();
    modal.classList.add("hidden");
    fsMcCancelSnapshot = null;
}
function fsMcCancel() {
    if (fsMcCancelSnapshot) {
        fsDualModeSlots = JSON.parse(JSON.stringify(fsMcCancelSnapshot.slots));
        fsDualModeActive = fsMcCancelSnapshot.dualActive;
        restoreFsLiveStash(fsMcCancelSnapshot.liveStash);
        applyFsFieldValuesToForm(fsMcCancelSnapshot.liveValues);
        const serviceTypeEl = document.getElementById("fs-field-service-type");
        if (serviceTypeEl) serviceTypeEl.value = fsMcCancelSnapshot.liveValues.SERVICE_TYPE || "gpu";
        refreshFsPoolFieldDisplay();
        updateManagePoolsBtnLabel();
        syncFsMcPoolTokenField();
        const rawEl = document.getElementById("fs-raw");
        if (rawEl) {
            rawEl.value = fsMcCancelSnapshot.rawValue;
            autoResizeFsRaw();
        }
    }
    closeFsMinerConfigModal();
}
function fsMcClearCurrentTab() {
    const service = getCurrentFsServiceType();
    resetFsFieldInputsForNewSlot();
    fsDualModeSlots[service] = null;
    fsDualModeActive = fsHasOtherRealSlot(service);
    const serviceTypeEl = document.getElementById("fs-field-service-type");
    if (serviceTypeEl) serviceTypeEl.value = service;
    fsSyncServiceTabsUI();
    const rawEl = document.getElementById("fs-raw");
    if (rawEl) {
        // Clearing a tab leaves the live preview blank; other services' stashed data is unaffected.
        rawEl.value = buildFsActivePreview();
        autoResizeFsRaw();
    }
}
function fsMcSwitchTab(service) {
    handleFsServiceSwitch(service);
    fsSyncServiceTabsUI();
    updateFsMinerConfigTitle();
    updateFsMinerConfigCustomVisibility();
}
function injectMinerTlsFlag(minerName, poolSsl, args) {
    const a = args || "";
    if (isSrbminerFamily(minerName)) {
        if (/--tls\s+(true|false)/.test(a)) return a;
        const val = poolSsl ? "true" : "false";
        return (a ? a + " " : "") + `--tls ${val}`;
    }
    switch (minerName) {
        case "xmrig":
            if (poolSsl && !/(^|\s)--tls(\s|$)/.test(a)) {
                return (a ? a + " " : "") + "--tls";
            }
            return a;
        case "gminer": {
            if (/--ssl\s+[01]/.test(a)) return a;
            const val = poolSsl ? "1" : "0";
            return (a ? a + " " : "") + `--ssl ${val}`;
        }
        default:
            return a;
    }
}
function applyFsItemToFields(jsonItem, hiveosName, rawTextHint) {
    const values = fsFieldsFromRigGpuJsonItem(jsonItem);
    values.SERVICE_TYPE = classifyFsItemService(jsonItem, rawTextHint);
    const tlsFromArgsPreview = /(^|\s)--tls(\s|$)/.test(values.ARGS || "");
    {
        const mcForStash = jsonItem.miner_config || {};
        const rawUserConfig = mcForStash.user_config || "";
        fsBzminerOcJsonUserConfig =
            (jsonItem.miner === "custom" || (jsonItem.miner || "").toLowerCase() !== "bzminer" || !/^\s*"/.test(rawUserConfig))
                ? ""
                : rawUserConfig;
    }
    {
        const mcForSrbStash = jsonItem.miner_config || {};
        fsSrbminerOriginalUserConfig =
            (jsonItem.miner === "custom" || !isSrbminerFamily(jsonItem.miner))
                ? ""
                : (mcForSrbStash.user_config || "");
    }
    {
        const mcForHugepages = jsonItem.miner_config || {};
        const resolvedMinerLowerForHp = (jsonItem.miner_alt || mcForHugepages.fork || jsonItem.miner || "").toLowerCase();
        const hp = mcForHugepages.hugepages;
        const hpStr = (typeof hp === "number" || typeof hp === "string") ? String(hp).trim() : "";
        fsXmrigHugepages =
            (jsonItem.miner === "custom" || resolvedMinerLowerForHp !== "xmrig" || hpStr === "" || !/^\d+$/.test(hpStr))
                ? ""
                : hpStr;
    }
    {
        const rawFork = (jsonItem.miner_config || {}).fork;
        fsMinerConfigFork =
            (jsonItem.miner === "custom" || typeof rawFork !== "string" || rawFork.trim() === "")
                ? ""
                : rawFork.trim();
    }
    {
        const mcForXmrigStash = jsonItem.miner_config || {};
        const resolvedMinerLowerForStash = (jsonItem.miner_alt || mcForXmrigStash.fork || jsonItem.miner || "").toLowerCase();
        const isXmrig = jsonItem.miner !== "custom" && resolvedMinerLowerForStash === "xmrig";
        const rawUc = mcForXmrigStash.user_config || "";
        fsXmrigOcJsonUserConfig = (isXmrig && /^\s*"/.test(rawUc)) ? rawUc : "";
        const rawCc = mcForXmrigStash.cpu_config || "";
        fsXmrigCpuConfigJson = (isXmrig && rawCc.trim() !== "") ? rawCc : "";
    }
    fsMinerConfigOriginal = (jsonItem.miner_config && typeof jsonItem.miner_config === "object")
        ? JSON.parse(JSON.stringify(jsonItem.miner_config))
        : null;
    {
        const origUrlRaw = (jsonItem.miner_config || {}).url;
        const origUrlTrimmed = typeof origUrlRaw === "string" ? origUrlRaw.trim() : "";
        // If the saved miner_config.url is just a mirror of the resolved pool address (bare
        // comparison, ignoring stratum+ssl/tcp prefixes) rather than a genuinely different
        // address, don't treat it as an explicit override - fall back to the "%URL%" token so
        // it resolves from the live pool_urls list again instead of staying pinned to whatever
        // address happened to be resolved when this was last saved (older saves, before the
        // %URL% resolution fix, always wrote the literal address here even with no real
        // override set).
        const looksLikeMirroredPool =
            origUrlTrimmed !== "" &&
            origUrlTrimmed !== "%URL%" &&
            bareFsPoolUrl(origUrlTrimmed) === bareFsPoolUrl(values.POOL);
        fsPoolUrlToken = (origUrlTrimmed !== "" && !looksLikeMirroredPool) ? origUrlTrimmed : "%URL%";
        fsPoolUrlNeedsToken = fsPoolUrlToken === "%URL%";
        const poolTokenEl = document.getElementById("fs-mc-pool-token");
        if (poolTokenEl) poolTokenEl.value = fsPoolUrlToken;
    }
    fsRigGpuItemOriginal = (() => {
        const clone = JSON.parse(JSON.stringify(jsonItem));
        delete clone.__hiveosRoot;
        return clone;
    })();
    fsMinerRawOriginal = typeof jsonItem.miner === "string" ? jsonItem.miner : "";
    fsExtraPoolUrls = (() => {
        if (!Array.isArray(jsonItem.pool_urls)) return [];
        const primaryBare = bareFsPoolUrl(values.POOL);
        const seen = new Set();
        const out = [];
        for (const u of jsonItem.pool_urls) {
            if (typeof u !== "string" || u.trim() === "") continue;
            const bare = bareFsPoolUrl(u);
            if (bare === primaryBare) continue;
            if (seen.has(bare)) continue;
            seen.add(bare);
            out.push(bare);
        }
        return out;
    })();
    fsPrimaryPoolUrl = fsExtraPoolUrls.length > 0 ? values.POOL : "";
    fsPoolUrlsExplicitlySet = false;
    updateManagePoolsBtnLabel();
    if (jsonItem.miner !== "custom") {
        values.ARGS = injectMinerTlsFlag(values.MINER, jsonItem.pool_ssl === true, values.ARGS);
    }
    const nameEl = document.getElementById("fs-name");
    if (hiveosName && nameEl && !nameEl.value.trim()) {
        nameEl.value = hiveosName;
    }
    for (const [key, info] of Object.entries(FS_RAW_KEY_MAP)) {
        if (!(key in values)) continue;
        const el = document.getElementById(info.id);
        if (!el) continue;
        if (info.type === "checkbox") {
            el.checked = values[key] === "true";
        } else {
            el.value = values[key];
        }
    }
    const sslEl = document.getElementById("fs-field-ssl");
    if (sslEl) sslEl.checked = jsonItem.pool_ssl === true;
    const tlsEl = document.getElementById("fs-field-tls");
    if (tlsEl) tlsEl.checked = tlsFromArgsPreview;
    refreshFsPoolFieldDisplay();
    if ("SERVICE_TYPE" in values) setFsCurrentServiceType(values.SERVICE_TYPE);
    fsUpdateRestartCheckboxDisabled();
    return values;
}
function populateFsFieldsFromRaw(rawText) {
    clearFsFields();
    setFsApplyToRigs([]);
    if (!rawText) return;
    const parsedItems = parseRigGpuItemsFromRaw(rawText);
    if (parsedItems) {
        // Fill in a missing pool short-name / coin ticker right away on load/paste too - previously
        // this only ran on the next field edit (buildRigGpuItemObject), so a pasted native flightsheet
        // that already had pool_urls/algo just sat there missing "pool"/"coin" until something else
        // triggered a rebuild. Reference-inequality here (addPoolSlugForClipboard/addCoinTickerForClipboard
        // return the SAME object back when there's nothing to add) is what "wasFsItemsEnriched" below
        // uses to decide whether the raw box text itself needs to be rewritten to match.
        const fsItemsWithPool = addPoolSlugForClipboard(parsedItems.items);
        const fsItemsEnriched = addCoinTickerForClipboard(fsItemsWithPool);
        const wasFsItemsEnriched = fsItemsEnriched.some((it, i) => it !== parsedItems.items[i]);
        parsedItems.items = fsItemsEnriched;
        setFsApplyToRigs(parsedItems.apply_to_workers || []);
        const classified = parsedItems.items.map((it) => ({
            item: it,
            service: classifyFsItemService(it, rawText),
        }));
        const gpuEntry = classified.find((c) => c.service === "gpu");
        const cpuEntry = classified.find((c) => c.service === "cpu");
        const isDual = !!(gpuEntry && cpuEntry && gpuEntry.item !== cpuEntry.item);
        const activeEntry = classified[0];
        const activeValues = applyFsItemToFields(activeEntry.item, parsedItems.name, rawText);
        if (isDual) {
            fsDualModeActive = true;
            fsDualModeSlots[activeEntry.service] = {
                stash: snapshotFsLiveStash(),
                values: collectFsFieldValuesWithExtras(),
            };
            const otherEntry = activeEntry.service === "cpu" ? gpuEntry : cpuEntry;
            const savedStash = snapshotFsLiveStash();
            const savedValues = collectFsFieldValuesWithExtras();
            applyFsItemToFields(otherEntry.item, parsedItems.name, rawText);
            fsDualModeSlots[otherEntry.service] = {
                stash: snapshotFsLiveStash(),
                values: collectFsFieldValuesWithExtras(),
            };
            restoreFsLiveStash(savedStash);
            applyFsFieldValuesToForm(savedValues);
            refreshFsPoolFieldDisplay();
            updateManagePoolsBtnLabel();
            syncFsMcPoolTokenField();
        }
        const rawEl = document.getElementById("fs-raw");
        if (rawEl) {
            if (isDual) {
                // Multiple services loaded - narrow the live preview to just the active tab.
                rawEl.value = buildFsActivePreview();
                autoResizeFsRaw();
            } else if (!/<<'EOF'\n[\s\S]*?\n[ \t]*EOF[ \t]*(?=\n|$)/.test(rawText)) {
                rawEl.value = buildFsBlock(activeValues.SERVICE_TYPE);
                autoResizeFsRaw();
            } else if (wasFsItemsEnriched) {
                // Native format, single service, but pool/coin got added above - splice the enriched
                // items back into the existing heredoc body so the box reflects it (everything else
                // in the pasted text - the tee line, any trailing restart line - stays untouched).
                const enrichedBody = { items: parsedItems.items };
                if (fsApplyToRigs.size > 0) enrichedBody.apply_to_workers = Array.from(fsApplyToRigs);
                rawEl.value = rawText.replace(
                    /(<<'EOF'\n)[\s\S]*?(\n[ \t]*EOF[ \t]*)(?=\n|$)/,
                    (_full, pre, post) => `${pre}${JSON.stringify(enrichedBody, null, 2)}${post}`
                );
                autoResizeFsRaw();
            }
        }
        return;
    }
    for (const [key, info] of Object.entries(FS_RAW_KEY_MAP)) {
        const match = rawText.match(new RegExp(`^${key}\\s+(?:0\\s+)?"([^"]*)"`, "m"));
        if (!match) continue;
        const el = document.getElementById(info.id);
        if (!el) continue;
        if (info.type === "checkbox") {
            el.checked = match[1] === "true";
        } else {
            el.value = match[1];
        }
    }
    const legacyPoolMatch = rawText.match(/^POOL\s+(?:0\s+)?"([^"]*)"/m);
    const legacySslEl = document.getElementById("fs-field-ssl");
    if (legacySslEl) {
        legacySslEl.checked = !!(legacyPoolMatch && legacyPoolMatch[1].startsWith("stratum+ssl://"));
    }
    const legacyTlsEl = document.getElementById("fs-field-tls");
    if (legacyTlsEl) legacyTlsEl.checked = false;
}
function insertFsRawLine(text, key, value) {
    const newLine = `${key} "${value}"`;
    const idx = FS_KEY_ORDER.indexOf(key);
    for (let i = idx - 1; i >= 0; i--) {
        const priorPattern = new RegExp(`^${FS_KEY_ORDER[i]}\\s+(?:0\\s+)?".*"$`, "m");
        const match = text.match(priorPattern);
        if (match) {
            const lineEnd = text.indexOf(match[0]) + match[0].length;
            return text.slice(0, lineEnd) + "\n" + newLine + text.slice(lineEnd);
        }
    }
    const eofMatch = text.match(/^EOF$/m);
    if (eofMatch) {
        const eofIdx = text.indexOf(eofMatch[0]);
        return text.slice(0, eofIdx) + newLine + "\n" + text.slice(eofIdx);
    }
    return text.replace(/\s+$/, "") + "\n" + newLine;
}
function updateRawFromFieldChange(target) {
    if (!target || !target.id) return;
    const mapping = FS_FIELD_ID_TO_KEY[target.id];
    if (!mapping) return;
    if (target.id === "fs-field-service-type") {
        // Always route through handleFsServiceSwitch so GPU/CPU/AUX behave as independent configs.
        handleFsServiceSwitch(target.value);
        return;
    }
    if (target.id === "fs-field-restart") {
        // Keep the tabs' green "will restart" indicator live as the checkbox is toggled.
        fsSyncServiceTabsUI();
        // The trailing "sudo systemctl restart docker_events_X" line is added/removed by
        // fsApplyRestartLine() operating on the WHOLE block, not a KEY "value" line the generic
        // regex-replace path below can patch in place - that path's JSON-body branch only touches
        // what's between <<'EOF' and EOF, so without this early return the restart line would never
        // change in the raw box until Send (same bug just fixed for Watchdog/Agent Conf). Always do
        // a full rebuild instead.
        const rawEl = document.getElementById("fs-raw");
        if (rawEl) {
            rawEl.value = buildFsActivePreview();
            autoResizeFsRaw();
        }
        return;
    }
    if (target.id === "fs-field-miner" || target.id === "fs-field-custom-miner") {
        fsUpdateRestartCheckboxDisabled();
    }
    if (target.id === "fs-field-miner-version") {
        // The miner.conf tee block sits before the JSON heredoc, outside the regex-replace path, so always do a full rebuild.
        const rawEl = document.getElementById("fs-raw");
        if (rawEl) {
            rawEl.value = buildFsActivePreview();
            autoResizeFsRaw();
        }
        return;
    }
    const rawEl = document.getElementById("fs-raw");
    if (!rawEl) return;
    if (rawEl.value.trim() === "") {
        syncFsRawFromFields();
        return;
    }
    if (fsDualModeActive) {
        rawEl.value = buildFsActivePreview();
        autoResizeFsRaw();
        return;
    }
    const jsonItem = parseRigGpuJsonFromRaw(rawEl.value);
    if (jsonItem) {
        const values = collectFsFieldValues();
        const newBody = buildRigGpuJsonBody(values);
        rawEl.value = rawEl.value.replace(
            /(<<'EOF'\n)[\s\S]*?(\n[ \t]*EOF[ \t]*)(?=\n|$)/,
            (_full, pre, post) => `${pre}${newBody}${post}`
        );
        autoResizeFsRaw();
        return;
    }
    const value = mapping.type === "checkbox" ? (target.checked ? "true" : "false") : target.value;
    const pattern = new RegExp(`^(${mapping.key}\\s+(?:0\\s+)?")([^"]*)(")`, "gm");
    if (!pattern.test(rawEl.value)) {
        rawEl.value = insertFsRawLine(rawEl.value, mapping.key, value);
        autoResizeFsRaw();
        return;
    }
    pattern.lastIndex = 0;
    rawEl.value = rawEl.value.replace(pattern, (_full, pre, _oldValue, post) => `${pre}${value}${post}`);
    autoResizeFsRaw();
}
function syncFsRawFromFields() {
    const serviceType = (document.getElementById("fs-field-service-type")?.value || "").trim().toLowerCase();
    const mode = serviceType === "cpu" ? "cpu" : serviceType === "aux" ? "aux" : "gpu";
    document.getElementById("fs-raw").value = buildFsBlock(mode);
    autoResizeFsRaw();
}
function autoResizeFsRaw() {
}
function wireUpFsTemplateToken(tokenId, tokenText) {
    const el = document.getElementById(tokenId);
    if (!el) return;
    el.addEventListener("mousedown", (e) => {
        e.preventDefault();
        const active = document.activeElement;
        const isFsField = active && active.classList && active.classList.contains("fs-field-input");
        const isFsRaw = active && active.id === "fs-raw";
        if (!isFsField && !isFsRaw) return;
        const start = active.selectionStart ?? active.value.length;
        const end = active.selectionEnd ?? active.value.length;
        active.value = active.value.slice(0, start) + tokenText + active.value.slice(end);
        const caretPos = start + tokenText.length;
        active.setSelectionRange(caretPos, caretPos);
        if (isFsRaw) {
            autoResizeFsRaw();
            populateFsFieldsFromRaw(active.value);
        } else {
            updateRawFromFieldChange(active);
        }
    });
    el.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
    });
}
function sendItFs() {
    const raw = fsFinalizeRawForAction().trim();
    if (!raw) {
        alert("Flightsheet is empty");
        return;
    }
    document.getElementById("cmd-input").value = raw;
    cmdModalRigOverride = fsApplyToRigs.size > 0 ? Array.from(fsApplyToRigs) : null;
    if (document.getElementById("confirm-fs")?.checked) {
        openCmdModal();
    } else {
        submitCmd();
    }
}
async function deleteFlightsheet() {
    if (selectedFlightsheetIds.size > 0) {
        const ids = [...selectedFlightsheetIds];
        if (!confirm(`Delete ${ids.length} flightsheet${ids.length !== 1 ? "s" : ""}?\n\n${ids.join(", ")}`)) {
            return;
        }
        const failed = [];
        for (const id of ids) {
            try {
                const res = await fetch(`${API}/api/flightsheets/${encodeURIComponent(id)}`, { method: "DELETE" });
                if (!res.ok) failed.push(id);
            } catch (err) {
                failed.push(id);
            }
        }
        selectedFlightsheetIds.clear();
        if (selectedFlightsheetId && ids.includes(selectedFlightsheetId)) {
            document.getElementById("fs-name").value = "";
            document.getElementById("fs-raw").value = "";
            selectedFlightsheetId = null;
        }
        loadFlightsheets();
        if (failed.length > 0) {
            alert(`Deleted ${ids.length - failed.length} of ${ids.length}. Failed: ${failed.join(", ")}`);
        }
        return;
    }
    if (!selectedFlightsheetId) {
        alert("No flightsheet selected");
        return;
    }
    if (!confirm(`Delete flightsheet "${selectedFlightsheetId}"?`)) {
        return;
    }
    try {
        const res = await fetch(
            `${API}/api/flightsheets/${encodeURIComponent(selectedFlightsheetId)}`,
            { method: "DELETE" }
        );
        if (!res.ok) throw new Error("Failed to delete");
		loadFlightsheets();
        document.getElementById("fs-name").value = "";
        document.getElementById("fs-raw").value = "";
        selectedFlightsheetId = null;
    } catch (err) {
        alert(err.message);
    }
}
function openFlightsheetsModal() {
    closeCmdModal();
    switchViewTab("flightsheets");
    loadFlightsheets();
    loadWallets();
    const fsCount = selectedRigs.size;
    const fsCountEl = document.getElementById("fs-target-count");
    const fsLabelEl = document.getElementById("fs-target-label");
    if (fsCountEl) fsCountEl.textContent = fsCount;
    if (fsLabelEl) fsLabelEl.textContent = fsCount === 1 ? "worker" : "workers";
}
let fsWalletSaveContext = null;
function openFsWalletSaveDialog() {
    const address = (document.getElementById("fs-field-wallet")?.value || "").trim();
    if (!address) {
        alert("WALLET field is empty - nothing to save.");
        return;
    }
    const coin = (document.getElementById("fs-field-algo")?.value || "").trim();
    const poolEl = document.getElementById("fs-field-pool");
    const primaryBare = bareFsPoolUrl(poolEl?.value || "");
    const pools = [primaryBare, ...fsExtraPoolUrls].filter((p) => (p || "").trim() !== "");
    fsWalletSaveContext = { address, coin, pools };
    const input = document.getElementById("fs-wallet-save-name-input");
    if (input) input.value = "";
    document.getElementById("fs-wallet-save-modal")?.classList.remove("hidden");
    input?.focus();
}
function closeFsWalletSaveDialog() {
    document.getElementById("fs-wallet-save-modal")?.classList.add("hidden");
    fsWalletSaveContext = null;
}
async function confirmFsWalletSave() {
    const context = fsWalletSaveContext;
    if (!context) {
        closeFsWalletSaveDialog();
        return;
    }
    const rawName = (document.getElementById("fs-wallet-save-name-input")?.value || "").trim();
    if (!rawName) {
        alert("Wallet name is required.");
        return;
    }
    const walletId = computeWalletIdForSave(rawName, context.coin);
    const existingWallet = wallets.find((w) => w.WalletId === walletId);
    let finalPools = context.pools;
    if (existingWallet) {
        const existingPools = Array.isArray(existingWallet.Pools) ? existingWallet.Pools : [];
        const existingBare = new Set(existingPools.map((p) => bareFsPoolUrl(p || "")).filter(Boolean));
        const hasNewPool = context.pools.some((p) => {
            const bare = bareFsPoolUrl(p || "");
            return bare && !existingBare.has(bare);
        });
        if (hasNewPool) {
            const merge = confirm(`A wallet named "${walletId}" already exists. Merge its saved pools with these and save?`);
            if (!merge) return;
        } else {
            const overwrite = confirm("Wallet and pool already exist in wallets. Overwrite? This will overwrite the existing pool list.");
            if (!overwrite) return;
        }
        const seen = new Set();
        finalPools = [...existingPools, ...context.pools].filter((p) => {
            const bare = bareFsPoolUrl(p || "");
            if (!bare || seen.has(bare)) return false;
            seen.add(bare);
            return true;
        });
    }
    const entries = [
        { key: "COIN", gpu: 0, value: context.coin },
        { key: "ADDRESS", gpu: 0, value: context.address },
        { key: "NOTES", gpu: 0, value: "" },
    ];
    finalPools.forEach((pool, idx) => {
        entries.push({ key: "POOL", gpu: idx, value: pool });
    });
    try {
        await saveWallet(walletId, entries);
        loadWallets();
        closeFsWalletSaveDialog();
    } catch (err) {
        alert(`Error saving wallet: ${err.message}`);
    }
}
function goToAddWalletForAlgo(algo, pools) {
    openWalletsModal();
    document
        .querySelectorAll("#wallet-list .fs-item.selected")
        .forEach(e => e.classList.remove("selected"));
    selectedWalletId = null;
    const nameEl = document.getElementById("wallet-name");
    if (nameEl) nameEl.value = "";
    const coinEl = document.getElementById("wallet-field-coin");
    if (coinEl) coinEl.value = algo || "";
    const addressEl = document.getElementById("wallet-field-address");
    if (addressEl) addressEl.value = "";
    const notesEl = document.getElementById("wallet-field-notes");
    if (notesEl) notesEl.value = "";
    linkifyWalletNotesOverlay();
    setWalletPoolsSelect(pools || []);
    nameEl?.focus();
}
function createClearSelectionItem(itemClass, box, onClear) {
    const item = document.createElement("div");
    item.className = `${itemClass} fs-suggestion-clear-item`;
    item.textContent = "-clear selection-";
    item.addEventListener("mousedown", (e) => {
        e.preventDefault();
        box.classList.add("hidden");
        box.innerHTML = "";
        onClear();
    });
    return item;
}
function renderFsWalletSuggestions(query) {
    const box = document.getElementById("fs-wallet-suggestions");
    if (!box) return;
    const algoRaw = (document.getElementById("fs-field-algo")?.value || "").trim();
    const algo = algoRaw.toLowerCase();
    const pool = algo ? wallets.filter(w => (w.Coin || "").trim().toLowerCase() === algo) : wallets;
    const q = (query || "").trim().toLowerCase();
    const matches = (algo && q)
        ? pool.filter(w =>
              w.WalletId.toLowerCase().includes(q) || (w.Coin || "").toLowerCase().includes(q)
          )
        : pool;
    box.innerHTML = "";
    box.appendChild(createClearSelectionItem("fs-wallet-suggestion-item", box, () => {
        const walletInput = document.getElementById("fs-field-wallet");
        if (walletInput) {
            walletInput.value = "";
            updateRawFromFieldChange(walletInput);
        }
    }));
    matches.slice(0, FS_WALLET_SUGGESTIONS_MAX).forEach(w => {
        const item = document.createElement("div");
        item.className = "fs-wallet-suggestion-item";
        item.textContent = w.WalletId; 
        item.addEventListener("mousedown", (e) => {
            e.preventDefault();
            const walletInput = document.getElementById("fs-field-wallet");
            walletInput.value = w.Address || "";
            box.classList.add("hidden");
            box.innerHTML = "";
            updateRawFromFieldChange(walletInput);
        });
        box.appendChild(item);
    });
    const addItem = document.createElement("div");
    addItem.className = "fs-wallet-suggestion-item fs-wallet-suggestion-add";
    addItem.textContent = algoRaw ? `+ Add wallet for ${algoRaw}` : "+ Add new wallet";
    addItem.addEventListener("mousedown", (e) => {
        e.preventDefault();
        box.classList.add("hidden");
        box.innerHTML = "";
        const poolEl = document.getElementById("fs-field-pool");
        const primaryBare = bareFsPoolUrl(poolEl?.value || "");
        const pools = [primaryBare, ...fsExtraPoolUrls].filter(p => (p || "").trim() !== "");
        goToAddWalletForAlgo(algoRaw, pools);
    });
    box.appendChild(addItem);
    box.classList.remove("hidden");
}
function renderFsSimpleSuggestions(list, boxId, itemClass, inputId, query) {
    const box = document.getElementById(boxId);
    if (!box) return;
    const q = (query || "").trim().toLowerCase();
    const matches = q ? list.filter(v => v.toLowerCase().includes(q)) : list;
    box.innerHTML = "";
    box.appendChild(createClearSelectionItem(itemClass, box, () => {
        const input = document.getElementById(inputId);
        if (input) {
            input.value = "";
            updateRawFromFieldChange(input);
        }
    }));
    matches.forEach(v => {
        const item = document.createElement("div");
        item.className = itemClass;
        item.textContent = v;
        item.addEventListener("mousedown", (e) => {
            e.preventDefault();
            const input = document.getElementById(inputId);
            input.value = v;
            box.classList.add("hidden");
            box.innerHTML = "";
            updateRawFromFieldChange(input);
        });
        box.appendChild(item);
    });
    box.classList.remove("hidden");
}
function renderFsMinerSuggestions(query) {
    renderFsSimpleSuggestions(FS_MINER_LIST, "fs-miner-suggestions", "fs-miner-suggestion-item", "fs-field-miner", query);
}
function renderFsAlgoSuggestions(query) {
    const coins = [...new Set(wallets.map(w => w.Coin).filter(Boolean))].sort((a, b) => a.localeCompare(b));
    renderFsSimpleSuggestions(coins, "fs-algo-suggestions", "fs-algo-suggestion-item", "fs-field-algo", query);
}
function renderFsPassSuggestions(query) {
    renderFsSimpleSuggestions(FS_PASS_LIST, "fs-pass-suggestions", "fs-pass-suggestion-item", "fs-field-pass", query);
}
function renderFsPoolSuggestions(query) {
    const box = document.getElementById("fs-pool-suggestions");
    if (!box) return;
    const algoRaw = (document.getElementById("fs-field-algo")?.value || "").trim();
    const algo = algoRaw.toLowerCase();
    const walletsForPools = algo
        ? wallets.filter(w => (w.Coin || "").trim().toLowerCase() === algo)
        : wallets;
    const pools = walletsForPools.flatMap(w => w.Pools || []);
    const uniquePools = [...new Set(pools)];
    if (uniquePools.length === 0) {
        showFsPoolHint(box, algo ? `No pools saved for "${algoRaw}" yet` : "No pools saved yet");
        return;
    }
    renderFsSimpleSuggestions(uniquePools, "fs-pool-suggestions", "fs-pool-suggestion-item", "fs-field-pool", query);
}
function showFsPoolHint(box, text) {
    box.innerHTML = "";
    box.appendChild(createClearSelectionItem("fs-pool-suggestion-item", box, () => {
        const input = document.getElementById("fs-field-pool");
        if (input) {
            input.value = "";
            updateRawFromFieldChange(input);
        }
    }));
    const hint = document.createElement("div");
    hint.className = "fs-pool-suggestion-hint";
    hint.textContent = text;
    box.appendChild(hint);
    box.classList.remove("hidden");
}
function getOverclockName() {
    const el = document.getElementById("oc-name");
    if (!el) return "";
    return el.value
        .trim()
        .toLowerCase()
        .replace(/\s+/g, "-")
        .replace(/[^a-z0-9\-]/g, "");
}
function collectOverclockEntries() {
    const cmd = document.getElementById("oc-raw").value.trim();
    if (!cmd) {
        alert("Cannot save empty overclock! Please enter a command in the overclock editor.");
        throw new Error("Empty command");
    }
    console.log("Saving overclock with command length:", cmd.length);
    return [
        { key: "RAW_COMMAND", gpu: 0, value: cmd }
    ];
}
let ocApplyToRigs = new Set();
function isOcApplyToDropdownOpen() {
    const list = document.getElementById("oc-apply-to-list");
    return !!list && !list.classList.contains("hidden");
}
function openOcApplyToDropdown() {
    populateOcApplyToWorkerList();
    document.getElementById("oc-apply-to-list")?.classList.remove("hidden");
}
function closeOcApplyToDropdown() {
    document.getElementById("oc-apply-to-list")?.classList.add("hidden");
}
function toggleOcApplyToDropdown() {
    if (isOcApplyToDropdownOpen()) {
        closeOcApplyToDropdown();
    } else {
        openOcApplyToDropdown();
    }
}
function updateOcApplyToToggleLabel() {
    const btn = document.getElementById("btn-oc-apply-to-toggle");
    if (!btn) return;
    if (ocApplyToRigs.size === 0) {
        btn.textContent = "Workers";
    } else if (ocApplyToRigs.size === 1) {
        btn.textContent = Array.from(ocApplyToRigs)[0];
    } else {
        btn.textContent = `${ocApplyToRigs.size} workers`;
    }
}
function updateOcApplyToWorkersOptionCheckedState() {
    const opt = document.getElementById("oc-apply-to-workers-option");
    if (opt) opt.classList.toggle("fs-apply-to-active", ocApplyToRigs.size === 0);
}
function populateOcApplyToWorkerList() {
    const container = document.getElementById("oc-apply-to-workers");
    if (!container) return;
    container.innerHTML = "";
    const rigNames = Object.keys(rigsState || {})
        .filter(name => name !== "rigs")
        .sort();
    rigNames.forEach((name) => {
        const row = document.createElement("label");
        row.className = "fs-apply-to-worker-row";
        const cb = document.createElement("input");
        cb.type = "checkbox";
        cb.checked = ocApplyToRigs.has(name);
        cb.addEventListener("change", () => {
            if (cb.checked) {
                ocApplyToRigs.add(name);
            } else {
                ocApplyToRigs.delete(name);
            }
            updateOcApplyToToggleLabel();
            updateOcApplyToWorkersOptionCheckedState();
            syncOcRawAfterApplyToChange();
        });
        const span = document.createElement("span");
        span.textContent = name;
        row.appendChild(cb);
        row.appendChild(span);
        container.appendChild(row);
    });
    updateOcApplyToWorkersOptionCheckedState();
}
function setOcApplyToRigs(names) {
    const rigNames = new Set(Object.keys(rigsState || {}).filter(name => name !== "rigs"));
    ocApplyToRigs = new Set((Array.isArray(names) ? names : []).filter(name => rigNames.has(name)));
    updateOcApplyToToggleLabel();
    if (isOcApplyToDropdownOpen()) populateOcApplyToWorkerList();
}
function clearOcApplyToSelection() {
    ocApplyToRigs.clear();
    updateOcApplyToToggleLabel();
    populateOcApplyToWorkerList();
    syncOcRawAfterApplyToChange();
}
// Overclock raw content is a plain shell script (heredoc), not JSON like flightsheets, so "apply to"
// has nowhere structured to live - it's persisted as a leading "# APPLY_TO=..." comment line placed
// BEFORE the "tee ... <<'EOF'" line, so it never ends up inside the installed gpu_apply_ocs.sh
// file on the rig and is a no-op if it's ever sent as-is (bash ignores comment lines).
function getOcApplyToFromScript(scriptText) {
    const m = (scriptText || "").match(/^# APPLY_TO=(.*)$/m);
    if (!m) return [];
    return m[1].split(",").map(s => s.trim()).filter(Boolean);
}
function syncOcRawAfterApplyToChange() {
    const rawEl = document.getElementById("oc-raw");
    if (!rawEl) return;
    let text = rawEl.value.replace(/^# APPLY_TO=.*\n?/m, "");
    if (ocApplyToRigs.size > 0) {
        text = `# APPLY_TO=${Array.from(ocApplyToRigs).join(",")}\n${text}`;
    }
    rawEl.value = text;
    autoResizeOcRaw();
}
async function loadOverclocks() {
    const res = await fetch(`${API}/api/overclocks`);
    if (!res.ok) {
        alert("Failed to load overclocks");
        return;
    }
    overclocks = await res.json();
    renderOverclocks();
}
function renderOverclocks() {
    const list = document.getElementById("oc-list");
    if (!list) return;
    list.innerHTML = "";
    const sortedOverclocks = [...overclocks].sort((a, b) => {
        return naturalCompare(a.OverclockId, b.OverclockId);
    });
    for (const oc of sortedOverclocks) {
        const row = document.createElement("div");
        row.className = "fs-item";
        const algoSummary = getOcScriptAlgoSummary(oc.Value || "");
        const applyAlgo = getOcApplyInvokeAlgoFromScript(oc.Value || "");
        const applyToWorkers = getOcApplyToFromScript(oc.Value || "");
        const applyToDisplay = applyToWorkers.length > 0 ? applyToWorkers.join(", ") : "Workers";
        row.innerHTML = `
            <input type="checkbox" class="rig-select-checkbox oc-select-checkbox" title="Select overclock profile">
            <div class="fs-item-grid">
                <span class="fs-item-col fs-item-col-name">${escapeHtml(oc.OverclockId)}</span>
                <span class="fs-item-col fs-item-col-applyto" title="${escapeHtml(applyToDisplay)}">${escapeHtml(applyToDisplay)}</span>
                <span class="fs-item-col">${escapeHtml(applyAlgo || "--")}</span>
                <span class="fs-item-col">${escapeHtml(algoSummary)}</span>
            </div>
        `;
        row.dataset.id = oc.OverclockId;
        row.dataset.value = oc.Value || "";
        row.dataset.applyAlgo = applyAlgo || "";
        if (oc.OverclockId === selectedOverclockId) {
            row.classList.add("selected");
        }
        const checkbox = row.querySelector(".oc-select-checkbox");
        checkbox.checked = selectedOverclockIds.has(oc.OverclockId);
        checkbox.addEventListener("click", (ev) => {
            ev.stopPropagation();
            if (checkbox.checked) {
                selectedOverclockIds.add(oc.OverclockId);
            } else {
                selectedOverclockIds.delete(oc.OverclockId);
            }
            syncOcSelectAllCheckbox();
        });
        row.addEventListener("click", () => {
            document
                .querySelectorAll("#oc-list .fs-item.selected")
                .forEach(e => e.classList.remove("selected"));
            row.classList.add("selected");
            selectedOverclockId = oc.OverclockId;
            setOcApplyToRigs(getOcApplyToFromScript(oc.Value || ""));
            document.getElementById("oc-name").value = oc.OverclockId;
            document.getElementById("oc-raw").value = oc.Value || "";
            loadOcRowsFromScript(oc.Value || "");
            autoResizeOcRaw();
        });
        list.appendChild(row);
    }
    populateOcApplyAlgoFilter();
    filterOverclockList();
    syncOcSelectAllCheckbox();
    autoSizeOcListColumns();
}
function autoSizeOcListColumns() {
    const header = document.querySelector("#oc-modal .oc-list-header .fs-item-grid");
    if (!header) return;
    const rowGrids = document.querySelectorAll("#oc-list .fs-item .fs-item-grid");
    const headerNameEl = header.children[0];
    const headerApplyToEl = header.children[1];
    const headerApplyAlgoEl = header.children[2];
    const headerAlgoEl = header.children[3];
    const headerFont = headerNameEl ? fsListColumnFont(headerNameEl) : null;
    const sampleRowNameEl = rowGrids.length > 0 ? rowGrids[0].children[0] : null;
    const rowFont = sampleRowNameEl ? fsListColumnFont(sampleRowNameEl) : headerFont;
    const titleNamePx = headerNameEl && headerFont ? Math.ceil(fsListHeaderTextWidth(headerNameEl, headerFont)) : 0;
    const titleApplyToPx = headerApplyToEl && headerFont ? Math.ceil(fsListHeaderTextWidth(headerApplyToEl, headerFont)) : 0;
    const titleApplyAlgoPx = headerApplyAlgoEl && headerFont ? Math.ceil(fsListHeaderTextWidth(headerApplyAlgoEl, headerFont)) : 0;
    const titleAlgoPx = headerAlgoEl && headerFont ? Math.ceil(fsListHeaderTextWidth(headerAlgoEl, headerFont)) : 0;
    let nameWidth = titleNamePx;
    let applyToWidth = titleApplyToPx;
    let applyAlgoWidth = titleApplyAlgoPx;
    if (rowFont) {
        rowGrids.forEach((grid) => {
            if (grid.children[0]) nameWidth = Math.max(nameWidth, measureFsListTextWidth(grid.children[0].textContent, rowFont));
            if (grid.children[1]) applyToWidth = Math.max(applyToWidth, measureFsListTextWidth(grid.children[1].textContent, rowFont));
            if (grid.children[2]) applyAlgoWidth = Math.max(applyAlgoWidth, measureFsListTextWidth(grid.children[2].textContent, rowFont));
        });
    }
    const namePx = Math.ceil(nameWidth) + FS_LIST_AUTOSIZE_PADDING_PX;
    const applyToPx = Math.min(FS_LIST_APPLYTO_MAX_PX, Math.ceil(applyToWidth) + FS_LIST_AUTOSIZE_PADDING_PX);
    const applyAlgoPx = Math.ceil(applyAlgoWidth) + FS_LIST_AUTOSIZE_PADDING_PX;
    const algoMinPx = titleAlgoPx + FS_LIST_AUTOSIZE_PADDING_PX;
    const template = `${namePx}px ${applyToPx}px ${applyAlgoPx}px minmax(${algoMinPx}px, 1fr)`;
    header.style.gridTemplateColumns = template;
    rowGrids.forEach((grid) => {
        grid.style.gridTemplateColumns = template;
    });
}
function syncOcSelectAllCheckbox() {
    const headerCb = document.getElementById("oc-select-all-checkbox");
    if (!headerCb) return;
    const visible = Array.from(document.querySelectorAll("#oc-list .fs-item"))
        .filter(item => item.style.display !== "none");
    const anySelected = visible.some(item => selectedOverclockIds.has(item.dataset.id));
    const allSelected = visible.length > 0 && visible.every(item => selectedOverclockIds.has(item.dataset.id));
    headerCb.checked = allSelected;
    headerCb.indeterminate = !allSelected && anySelected;
}
function toggleSelectAllOverclocks() {
    const visible = Array.from(document.querySelectorAll("#oc-list .fs-item"))
        .filter(item => item.style.display !== "none");
    if (visible.length === 0) return;
    const allSelected = visible.every(item => selectedOverclockIds.has(item.dataset.id));
    visible.forEach(item => {
        if (allSelected) {
            selectedOverclockIds.delete(item.dataset.id);
        } else {
            selectedOverclockIds.add(item.dataset.id);
        }
        const cb = item.querySelector(".oc-select-checkbox");
        if (cb) cb.checked = !allSelected;
    });
    syncOcSelectAllCheckbox();
}
function populateOcApplyAlgoFilter() {
    const select = document.getElementById("oc-algo-filter");
    if (!select) return;
    const previousValue = select.value;
    const algos = [...new Set(
        Array.from(document.querySelectorAll("#oc-list .fs-item"))
            .map((item) => item.dataset.applyAlgo || "")
            .filter((a) => a !== "")
    )].sort((a, b) => a.localeCompare(b));
    select.innerHTML = "";
    const allOption = document.createElement("option");
    allOption.value = "";
    allOption.textContent = "All algos";
    select.appendChild(allOption);
    for (const algo of algos) {
        const option = document.createElement("option");
        option.value = algo;
        option.textContent = algo;
        select.appendChild(option);
    }
    select.value = algos.includes(previousValue) ? previousValue : "";
}
function filterOverclockList() {
    const query = (document.getElementById("oc-search")?.value || "").trim().toLowerCase();
    const algoFilter = document.getElementById("oc-algo-filter")?.value || "";
    document.querySelectorAll("#oc-list .fs-item").forEach(item => {
        const matchesQuery = !query || item.textContent.toLowerCase().includes(query);
        const matchesAlgo = !algoFilter || item.dataset.applyAlgo === algoFilter;
        item.style.display = (matchesQuery && matchesAlgo) ? "" : "none";
    });
    syncOcSelectAllCheckbox();
}
async function saveOverclock(overclockId, entries) {
    if (!overclockId) {
        throw new Error("Overclock name is required");
    }
    if (!Array.isArray(entries) || entries.length === 0) {
        throw new Error("Overclock has no entries to save");
    }
    const res = await fetch(
        `${API}/api/overclocks/${encodeURIComponent(overclockId)}`,
        {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ entries })
        }
    );
    if (!res.ok) {
        const errorData = await res.json().catch(() => ({}));
        const errorMsg = errorData.detail || errorData.message || "Failed to save overclock";
        throw new Error(errorMsg);
    }
    return await res.json();
}
async function saveOverclockFromDialog() {
    const overclockId = getOverclockName();
    try {
        const entries = collectOverclockEntries();
        await saveOverclock(overclockId, entries);
        loadOverclocks();
    } catch (err) {
        alert(`Error saving overclock: ${err.message}`);
    }
}
function classifyOcFanValue(raw) {
    const v = (raw || "").trim();
    if (/^-?\d+(\.\d+)?$/.test(v)) return { type: "percent", value: v };
    if (/^\d+:\d+(\s*,\s*\d+:\d+)*$/.test(v)) return { type: "curve", value: v.replace(/\s+/g, "") };
    return { type: "none", value: "" };
}
function fillPlaceholders(template, values) {
    let result = template;
    for (const [key, value] of Object.entries(values)) {
        result = result.split(`%${key}%`).join(value === undefined || value === null ? "" : String(value));
    }
    return result;
}
function autoResizeOcRaw() {
}
let ocRowIdCounter = 0;
function renderOcAlgoSuggestions(inputEl) {
    const box = inputEl.parentElement.querySelector(".wdconfig-algo-suggestions");
    if (!box) return;
    const prevScrollTop = box.scrollTop;
    const rect = inputEl.getBoundingClientRect();
    box.style.left = `${rect.left}px`;
    box.style.top = `${rect.bottom + 4}px`;
    box.style.width = `${rect.width}px`;
    const parts = inputEl.value.split(",");
    const selected = new Set(parts.map(p => p.trim().toLowerCase()).filter(Boolean));
    const current = inputEl.dataset.clearAlgoFilter
        ? ""
        : (parts[parts.length - 1] || "").trim().toLowerCase();
    const matches = current
        ? wdAlgoSuggestionsList.filter(name => name.toLowerCase().includes(current))
        : wdAlgoSuggestionsList;
    box.innerHTML = "";
    box.appendChild(createClearSelectionItem("wdconfig-algo-suggestion-item", box, () => {
        inputEl.value = "";
        inputEl.dataset.suppressSuggestions = "1";
        inputEl.dispatchEvent(new Event("input", { bubbles: true }));
        delete inputEl.dataset.suppressSuggestions;
    }));
    matches.forEach(name => {
        const lower = name.toLowerCase();
        const item = document.createElement("label");
        item.className = "wdconfig-algo-suggestion-item wdconfig-algo-suggestion-checkbox-item";
        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.className = "wdconfig-algo-suggestion-checkbox";
        checkbox.checked = selected.has(lower);
        checkbox.addEventListener("change", () => {
            const allParts = inputEl.value.split(",").map(p => p.trim()).filter(Boolean);
            const idx = allParts.findIndex(p => p.toLowerCase() === lower);
            if (checkbox.checked) {
                if (idx === -1) allParts.push(name);
            } else if (idx !== -1) {
                allParts.splice(idx, 1);
            }
            inputEl.value = allParts.join(", ");
            inputEl.dataset.clearAlgoFilter = "1";
            inputEl.dispatchEvent(new Event("input", { bubbles: true }));
            delete inputEl.dataset.clearAlgoFilter;
        });
        const text = document.createElement("span");
        text.textContent = name;
        item.appendChild(checkbox);
        item.appendChild(text);
        box.appendChild(item);
    });
    box.classList.remove("hidden");
    box.scrollTop = prevScrollTop;
}
function addOcRow(row, opts) {
    const r = row || { algo: "", lockCore: 0, coreOffset: 0, powerLimit: 0, lockMem: 0, memOffset: 0, fan: "" };
    const tbody = document.getElementById("oc-rows");
    if (!tbody) return;
    const rowId = String(++ocRowIdCounter);
    const tr = document.createElement("tr");
    tr.className = "oc-row";
    tr.dataset.ocRowId = rowId;
    tr.innerHTML = `
        <td>
            <span class="wdconfig-algo-autocomplete">
                <input type="text" class="wdconfig-input oc-input oc-algo" value="${escapeHtml(r.algo)}" placeholder="e.g. kheavyhash, kawpow" autocomplete="off" />
                <div class="wdconfig-algo-suggestions hidden"></div>
            </span>
        </td>
        <td><input type="text" class="wdconfig-input oc-input" data-oc-field="lockCore" value="${escapeHtml(String(r.lockCore ?? 0))}" /></td>
        <td><input type="text" class="wdconfig-input oc-input" data-oc-field="coreOffset" value="${escapeHtml(String(r.coreOffset ?? 0))}" /></td>
        <td><input type="text" class="wdconfig-input oc-input" data-oc-field="powerLimit" value="${escapeHtml(String(r.powerLimit ?? 0))}" /></td>
        <td><input type="text" class="wdconfig-input oc-input" data-oc-field="lockMem" value="${escapeHtml(String(r.lockMem ?? 0))}" /></td>
        <td><input type="text" class="wdconfig-input oc-input" data-oc-field="memOffset" value="${escapeHtml(String(r.memOffset ?? 0))}" /></td>
        <td><input type="text" class="wdconfig-input oc-input" data-oc-field="fan" value="${escapeHtml(r.fan ?? "")}" placeholder="e.g. 75 or 30:30,40:45,50:65,55:90,65:100" /></td>
        <td><button class="oc-remove-row" title="Remove row">&times;</button></td>
    `;
    tr.querySelector(".oc-remove-row").addEventListener("click", (ev) => {
        ev.stopPropagation();
        tr.remove();
        rebuildOcRawFromRows();
    });
    tr.querySelectorAll(".oc-input").forEach(inp => {
        inp.addEventListener("input", () => rebuildOcRawFromRows());
    });
    const algoInput = tr.querySelector(".oc-algo");
    algoInput.addEventListener("input", () => {
        if (!algoInput.dataset.suppressSuggestions) renderOcAlgoSuggestions(algoInput);
    });
    algoInput.addEventListener("focus", () => renderOcAlgoSuggestions(algoInput));
    const fanInput = tr.querySelector('[data-oc-field="fan"]');
    fanInput.addEventListener("focus", () => { activeOcFanInput = fanInput; });
    tbody.appendChild(tr);
    if (!opts || !opts.skipRebuild) rebuildOcRawFromRows();
}
let activeOcFanInput = null;
function initOcFanCurveExampleButton() {
    const btn = document.getElementById("oc-fan-curve-example-btn");
    if (!btn) return;
    btn.addEventListener("click", (ev) => {
        ev.stopPropagation();
        ev.preventDefault();
        let target = activeOcFanInput;
        if (!target || !document.body.contains(target)) {
            target = document.querySelector('#oc-rows .oc-row [data-oc-field="fan"]');
        }
        if (!target) return;
        target.value = "30:30,40:45,50:65,55:90,65:100";
        target.dispatchEvent(new Event("input", { bubbles: true }));
        activeOcFanInput = target;
    });
}
function clearOcRows() {
    const tbody = document.getElementById("oc-rows");
    if (tbody) tbody.innerHTML = "";
}
function collectOcRows() {
    const rows = [];
    for (const tr of document.querySelectorAll("#oc-rows .oc-row")) {
        const algoRaw = tr.querySelector(".oc-algo").value.trim();
        const algoNames = algoRaw.split(",").map(a => a.trim()).filter(Boolean);
        if (algoNames.length === 0) continue;
        const algo = algoNames.join(", ");
        const field = (name) => tr.querySelector(`[data-oc-field="${name}"]`).value.trim();
        const numFieldNames = ["lockCore", "coreOffset", "powerLimit", "lockMem", "memOffset"];
        const nums = {};
        for (const name of numFieldNames) {
            const raw = field(name);
            const v = Number(raw === "" ? "0" : raw);
            if (Number.isNaN(v)) {
                alert(`Row "${algo}" has a non-numeric value - fix it before applying.`);
                return null;
            }
            nums[name] = v;
        }
        rows.push({
            algo,
            algoNames,
            lockCore: nums.lockCore,
            coreOffset: nums.coreOffset,
            powerLimit: nums.powerLimit,
            lockMem: nums.lockMem,
            memOffset: nums.memOffset,
            fan: field("fan"),
        });
    }
    return rows;
}
function buildOcScriptFromRows() {
    const rows = collectOcRows();
    if (rows === null) return document.getElementById("oc-raw")?.value || "";
    const ocCfg = TEMPLATES_CONFIG.overclocking;
    let body = ocCfg.apply_script_header;
    for (const r of rows) {
        const fan = classifyOcFanValue(r.fan);
        const algoPattern = r.algoNames.map(a => a.toLowerCase()).join("|");
        body += fillPlaceholders(ocCfg.apply_script_algo_block, {
            "ALGO": algoPattern,
            "Lock Core Clock": r.lockCore,
            "Core Clock Offset": r.coreOffset,
            "Power Limit": r.powerLimit,
            "Lock Memory Clock": r.lockMem,
            "Memory Clock Offset": r.memOffset,
            "Fan Mode": fan.type,
            "Fan Value": fan.value,
        });
    }
    // apply_script_footer is fully static now - fan-curve.service itself is installed once,
    // separately (Fan-control/py-nvtool/install_fan-curve.sh); the footer just syncs its --curve
    // value in place when curve mode is active, so there's no per-row template substitution left
    // to do here.
    return body + ocCfg.apply_script_footer;
}
function rebuildOcRawFromRows() {
    const el = document.getElementById("oc-raw");
    if (el) {
        let text = buildOcScriptFromRows();
        if (ocApplyToRigs.size > 0) {
            text = `# APPLY_TO=${Array.from(ocApplyToRigs).join(",")}\n${text}`;
        }
        el.value = text;
    }
    autoResizeOcRaw();
    populateOcAlgoApplySelect();
}
function populateOcAlgoApplySelect() {
    const select = document.getElementById("oc-algo-apply-select");
    if (!select) return;
    const names = [];
    document.querySelectorAll("#oc-rows .oc-row .oc-algo").forEach(input => {
        (input.value || "").split(",").map(a => a.trim()).filter(Boolean).forEach(n => {
            if (!names.includes(n)) names.push(n);
        });
    });
    select.innerHTML = "";
    const saveOnlyOpt = document.createElement("option");
    saveOnlyOpt.value = "";
    saveOnlyOpt.textContent = "-save only-";
    select.appendChild(saveOnlyOpt);
    names.forEach(name => {
        const opt = document.createElement("option");
        opt.value = name;
        opt.textContent = name;
        select.appendChild(opt);
    });
    if (ocApplyInvokeAlgo && names.includes(ocApplyInvokeAlgo)) {
        select.value = ocApplyInvokeAlgo;
    } else {
        ocApplyInvokeAlgo = "";
        select.value = "";
    }
}
function onOcAlgoApplySelectChange() {
    const select = document.getElementById("oc-algo-apply-select");
    const rawEl = document.getElementById("oc-raw");
    if (!select || !rawEl) return;
    ocApplyInvokeAlgo = select.value;
    let text = rawEl.value.replace(/\n*sudo \/usr\/local\/bin\/gpu_apply_ocs\.sh \S+\s*$/, "");
    text = text.replace(/\s+$/, "");
    if (ocApplyInvokeAlgo) {
        text += `\n\nsudo /usr/local/bin/gpu_apply_ocs.sh ${ocApplyInvokeAlgo}\n`;
    } else {
        text += "\n";
    }
    rawEl.value = text;
    autoResizeOcRaw();
}
function parseOcScriptRows(scriptText) {
    const rows = [];
    if (!scriptText) return rows;
    const blockRe = /^ {4}([a-z0-9_\-|]+)\)\s*\n\s*CORE=(-?\d+(?:\.\d+)?)\s*\n\s*CORE_OFFSET=(-?\d+(?:\.\d+)?)\s*\n\s*MEM=(-?\d+(?:\.\d+)?)\s*\n\s*MEM_OFFSET=(-?\d+(?:\.\d+)?)\s*\n\s*POWER_LIMIT=(-?\d+(?:\.\d+)?)\s*\n\s*FAN_MODE="([^"]*)"\s*\n\s*FAN_VALUE="([^"]*)"/gm;
    let m;
    while ((m = blockRe.exec(scriptText)) !== null) {
        rows.push({
            algo: m[1].split("|").join(", "),
            algoNames: m[1].split("|"),
            lockCore: Number(m[2]),
            coreOffset: Number(m[3]),
            lockMem: Number(m[4]),
            memOffset: Number(m[5]),
            powerLimit: Number(m[6]),
            fan: m[8] || "",
        });
    }
    return rows;
}
function loadOcRowsFromScript(scriptText) {
    clearOcRows();
    const rows = parseOcScriptRows(scriptText);
    ocApplyInvokeAlgo = getOcApplyInvokeAlgoFromScript(scriptText);
    if (rows.length === 0) {
        addOcRow(null, { skipRebuild: true });
        populateOcAlgoApplySelect();
        return;
    }
    for (const row of rows) {
        addOcRow(row, { skipRebuild: true });
    }
    populateOcAlgoApplySelect();
}
function getOcScriptAlgoSummary(scriptText) {
    const rows = parseOcScriptRows(scriptText);
    const names = [];
    rows.forEach(r => r.algoNames.forEach(n => { if (n && !names.includes(n)) names.push(n); }));
    return names.join(", ");
}
function getOcApplyInvokeAlgoFromScript(scriptText) {
    const m = (scriptText || "").match(/sudo \/usr\/local\/bin\/gpu_apply_ocs\.sh (\S+)\s*$/);
    return m ? m[1] : "";
}
function newOverclock() {
    const raw = document.getElementById("oc-raw").value.trim();
    if (raw) {
        alert("Overclock is not empty");
        return;
    }
    document.getElementById("oc-name").value = "";
    clearOcRows();
    addOcRow(null, { skipRebuild: true });
    rebuildOcRawFromRows();
}
function sendItOc() {
    const raw = document.getElementById("oc-raw").value.trim();
    if (!raw) {
        alert("Overclock is empty");
        return;
    }
    document.getElementById("cmd-input").value = raw;
    cmdModalRigOverride = ocApplyToRigs.size > 0 ? Array.from(ocApplyToRigs) : null;
    if (document.getElementById("confirm-oc")?.checked) {
        openCmdModal();
    } else {
        submitCmd();
    }
}
async function deleteOverclock() {
    if (selectedOverclockIds.size > 0) {
        const ids = [...selectedOverclockIds];
        if (!confirm(`Delete ${ids.length} overclock profile${ids.length !== 1 ? "s" : ""}?\n\n${ids.join(", ")}`)) {
            return;
        }
        const failed = [];
        for (const id of ids) {
            try {
                const res = await fetch(`${API}/api/overclocks/${encodeURIComponent(id)}`, { method: "DELETE" });
                if (!res.ok) failed.push(id);
            } catch (err) {
                failed.push(id);
            }
        }
        selectedOverclockIds.clear();
        if (selectedOverclockId && ids.includes(selectedOverclockId)) {
            document.getElementById("oc-name").value = "";
            clearOcRows();
            addOcRow(null, { skipRebuild: true });
            rebuildOcRawFromRows();
            selectedOverclockId = null;
        }
        loadOverclocks();
        if (failed.length > 0) {
            alert(`Deleted ${ids.length - failed.length} of ${ids.length}. Failed: ${failed.join(", ")}`);
        }
        return;
    }
    if (!selectedOverclockId) {
        alert("No overclock selected");
        return;
    }
    if (!confirm(`Delete overclock "${selectedOverclockId}"?`)) {
        return;
    }
    try {
        const res = await fetch(
            `${API}/api/overclocks/${encodeURIComponent(selectedOverclockId)}`,
            { method: "DELETE" }
        );
        if (!res.ok) throw new Error("Failed to delete");
        loadOverclocks();
        document.getElementById("oc-name").value = "";
        clearOcRows();
        addOcRow(null, { skipRebuild: true });
        rebuildOcRawFromRows();
        selectedOverclockId = null;
    } catch (err) {
        alert(err.message);
    }
}
function openOverclocksModal() {
    closeCmdModal();
    switchViewTab("overclocking");
    loadOverclocks();
    loadWallets();
    populateWdAlgoSuggestions();
    const tbody = document.getElementById("oc-rows");
    if (tbody && tbody.children.length === 0) {
        addOcRow(null, { skipRebuild: true });
        rebuildOcRawFromRows();
    }
    const ocCount = selectedRigs.size;
    const ocCountEl = document.getElementById("oc-target-count");
    const ocLabelEl = document.getElementById("oc-target-label");
    if (ocCountEl) ocCountEl.textContent = ocCount;
    if (ocLabelEl) ocLabelEl.textContent = ocCount === 1 ? "worker" : "workers";
}
function clearWalletFields() {
    document.getElementById("wallet-field-coin").value = "";
    document.getElementById("wallet-field-address").value = "";
    document.getElementById("wallet-field-notes").value = "";
    linkifyWalletNotesOverlay();
    setWalletPoolsSelect([]);
}
function setWalletPoolsSelect(pools) {
    const select = document.getElementById("wallet-field-pools");
    if (!select) return;
    select.innerHTML = "";
    (pools || []).forEach(pool => {
        const opt = document.createElement("option");
        opt.value = pool;
        opt.textContent = pool;
        select.appendChild(opt);
    });
}
function getWalletPoolsFromSelect() {
    const select = document.getElementById("wallet-field-pools");
    if (!select) return [];
    return Array.from(select.options).map(o => o.value);
}
function collectWalletEntries() {
    const coin = document.getElementById("wallet-field-coin").value.trim();
    const address = document.getElementById("wallet-field-address").value.trim();
    const notes = document.getElementById("wallet-field-notes").value;
    const pools = getWalletPoolsFromSelect();
    if (!coin || !address) {
        alert("Algo and Wallet Address are both required.");
        throw new Error("Missing coin or address");
    }
    const entries = [
        { key: "COIN", gpu: 0, value: coin },
        { key: "ADDRESS", gpu: 0, value: address },
        { key: "NOTES", gpu: 0, value: notes }
    ];
    pools.forEach((pool, idx) => {
        entries.push({ key: "POOL", gpu: idx, value: pool });
    });
    return entries;
}
function escapeHtmlForNotesOverlay(text) {
    return text
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
}
function stripTrailingPunctuation(url) {
    return url.replace(/[.,;:!?'")\]]+$/, "");
}
function linkifyWalletNotesOverlay() {
    const textarea = document.getElementById("wallet-field-notes");
    const overlay = document.getElementById("wallet-field-notes-overlay");
    if (!textarea || !overlay) return;
    const raw = textarea.value;
    const escaped = escapeHtmlForNotesOverlay(raw);
    const html = escaped.replace(NOTES_URL_REGEX, (match) => {
        const trimmed = stripTrailingPunctuation(match);
        const trailing = match.slice(trimmed.length);
        return `<a href="${trimmed}" target="_blank" rel="noopener noreferrer">${trimmed}</a>${trailing}`;
    });
    overlay.innerHTML = html;
    overlay.scrollTop = textarea.scrollTop;
    overlay.scrollLeft = textarea.scrollLeft;
}
function getWalletName() {
    const el = document.getElementById("wallet-name");
    return el ? el.value.trim() : "";
}
async function loadWallets() {
    const res = await fetch(`${API}/api/wallets`);
    if (!res.ok) {
        alert("Failed to load wallets");
        return;
    }
    const items = await res.json();
    const byId = {};
    for (const item of items) {
        if (!byId[item.WalletId]) {
            byId[item.WalletId] = { WalletId: item.WalletId, Coin: "", Address: "", Notes: "", Pools: [] };
        }
        if (item.Key === "COIN") byId[item.WalletId].Coin = item.Value || "";
        if (item.Key === "ADDRESS") byId[item.WalletId].Address = item.Value || "";
        if (item.Key === "NOTES") byId[item.WalletId].Notes = item.Value || "";
        if (item.Key === "POOL" && item.Value) byId[item.WalletId].Pools.push(item.Value);
    }
    wallets = Object.values(byId);
    renderWallets();
    populateWdAlgoSuggestions();
}
function selectWalletById(walletId) {
    const wallet = wallets.find(w => w.WalletId === walletId);
    if (!wallet) return;
    document
        .querySelectorAll("#wallet-list .fs-item.selected")
        .forEach(e => e.classList.remove("selected"));
    const row = document.querySelector(`#wallet-list .fs-item[data-id="${CSS.escape(wallet.WalletId)}"]`);
    if (row) row.classList.add("selected");
    selectedWalletId = wallet.WalletId;
    document.getElementById("wallet-name").value = wallet.WalletId;
    document.getElementById("wallet-field-coin").value = wallet.Coin || "";
    document.getElementById("wallet-field-address").value = wallet.Address || "";
    document.getElementById("wallet-field-notes").value = wallet.Notes || "";
    linkifyWalletNotesOverlay();
    setWalletPoolsSelect(wallet.Pools || []);
}
function renderWalletNameSuggestions() {
    const box = document.getElementById("wallet-name-suggestions");
    if (!box) return;
    const algo = (document.getElementById("wallet-field-coin")?.value || "").trim().toLowerCase();
    const pool = algo ? wallets.filter(w => (w.Coin || "").trim().toLowerCase() === algo) : wallets;
    const sorted = [...pool].sort((a, b) => naturalCompare(a.WalletId, b.WalletId));
    box.innerHTML = "";
    box.appendChild(createClearSelectionItem("fs-wallet-suggestion-item", box, () => {
        newWallet();
    }));
    sorted.slice(0, FS_WALLET_SUGGESTIONS_MAX).forEach(w => {
        const item = document.createElement("div");
        item.className = "fs-wallet-suggestion-item";
        item.textContent = w.WalletId; 
        item.addEventListener("mousedown", (e) => {
            e.preventDefault();
            box.classList.add("hidden");
            box.innerHTML = "";
            selectWalletById(w.WalletId);
        });
        box.appendChild(item);
    });
    box.classList.remove("hidden");
}
function renderWalletAlgoSuggestions() {
    const box = document.getElementById("wallet-algo-suggestions");
    if (!box) return;
    const coins = [...new Set(wallets.map(w => w.Coin).filter(Boolean))].sort((a, b) => a.localeCompare(b));
    box.innerHTML = "";
    box.appendChild(createClearSelectionItem("fs-wallet-suggestion-item", box, () => {
        const input = document.getElementById("wallet-field-coin");
        if (input) input.value = "";
    }));
    coins.forEach(coin => {
        const item = document.createElement("div");
        item.className = "fs-wallet-suggestion-item";
        item.textContent = coin;
        item.addEventListener("mousedown", (e) => {
            e.preventDefault();
            box.classList.add("hidden");
            box.innerHTML = "";
            const input = document.getElementById("wallet-field-coin");
            if (input) input.value = coin;
        });
        box.appendChild(item);
    });
    box.classList.remove("hidden");
}
function renderWallets() {
    const list = document.getElementById("wallet-list");
    list.innerHTML = "";
    const sortedWallets = [...wallets].sort((a, b) => naturalCompare(a.WalletId, b.WalletId));
    for (const wallet of sortedWallets) {
        const row = document.createElement("div");
        row.className = "fs-item";
        const nameCell = document.createElement("span");
        nameCell.textContent = wallet.WalletId;
        nameCell.title = wallet.WalletId;
        const algoCell = document.createElement("span");
        algoCell.textContent = wallet.Coin || "";
        algoCell.title = wallet.Coin || "";
        const addressCell = document.createElement("span");
        addressCell.textContent = wallet.Address || "";
        addressCell.title = wallet.Address || "";
        const poolsText = (wallet.Pools || []).join(", ");
        const poolsCell = document.createElement("span");
        poolsCell.textContent = poolsText;
        poolsCell.title = poolsText;
        row.append(nameCell, algoCell, addressCell, poolsCell);
        row.dataset.id = wallet.WalletId;
        row.dataset.coin = (wallet.Coin || "").toLowerCase();
        row.dataset.algo = wallet.Coin || "";
        row.dataset.name = wallet.WalletId.toLowerCase();
        if (wallet.WalletId === selectedWalletId) {
            row.classList.add("selected");
        }
        row.addEventListener("click", () => {
            selectWalletById(wallet.WalletId);
        });
        list.appendChild(row);
    }
    populateWalletAlgoFilter();
    filterWalletList();
}
const WALLET_ALGO_FILTER_NONE = "__none__";
function populateWalletAlgoFilter() {
    const select = document.getElementById("wallet-algo-filter");
    if (!select) return;
    const previousValue = select.value;
    const algos = [...new Set(
        Array.from(document.querySelectorAll("#wallet-list .fs-item"))
            .map((item) => item.dataset.algo || "")
            .filter((a) => a !== "")
    )].sort((a, b) => a.localeCompare(b));
    select.innerHTML = "";
    const allOption = document.createElement("option");
    allOption.value = "";
    allOption.textContent = "All algos";
    select.appendChild(allOption);
    const noneOption = document.createElement("option");
    noneOption.value = WALLET_ALGO_FILTER_NONE;
    noneOption.textContent = "(no algo)";
    select.appendChild(noneOption);
    for (const algo of algos) {
        const option = document.createElement("option");
        option.value = algo;
        option.textContent = algo;
        select.appendChild(option);
    }
    const validValues = new Set(["", WALLET_ALGO_FILTER_NONE, ...algos]);
    select.value = validValues.has(previousValue) ? previousValue : "";
}
function filterWalletList() {
    const query = (document.getElementById("wallet-search")?.value || "").trim().toLowerCase();
    const algoFilter = document.getElementById("wallet-algo-filter")?.value || "";
    document.querySelectorAll("#wallet-list .fs-item").forEach(item => {
        const cells = item.children;
        const searchable = cells.length >= 4
            ? `${cells[0].textContent} ${cells[1].textContent} ${cells[3].textContent}`
            : item.textContent;
        const matchesQuery = !query || searchable.toLowerCase().includes(query);
        const matchesAlgo = !algoFilter
            || (algoFilter === WALLET_ALGO_FILTER_NONE ? (item.dataset.algo || "") === "" : item.dataset.algo === algoFilter);
        item.style.display = (matchesQuery && matchesAlgo) ? "" : "none";
    });
}
async function saveWallet(walletId, entries) {
    if (!walletId) {
        throw new Error("Wallet name is required");
    }
    const res = await fetch(
        `${API}/api/wallets/${encodeURIComponent(walletId)}`,
        {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ entries })
        }
    );
    if (!res.ok) {
        const errorData = await res.json().catch(() => ({}));
        const errorMsg = errorData.detail || errorData.message || "Failed to save wallet";
        throw new Error(errorMsg);
    }
    return await res.json();
}
function computeWalletIdForSave(rawName, coin) {
    const base = (rawName || "").trim().replace(/\s*\([^)]*\)\s*$/, "").trim();
    const c = (coin || "").trim();
    if (!c) return base;
    const safeCoin = c.replace(/\//g, "-");
    return `${base} (${safeCoin})`;
}
async function saveWalletFromDialog() {
    const rawName = getWalletName();
    if (!rawName) {
        alert("Wallet name is required.");
        return;
    }
    try {
        const entries = collectWalletEntries();
        const coin = entries.find(e => e.key === "COIN")?.value || "";
        const walletId = computeWalletIdForSave(rawName, coin);
        await saveWallet(walletId, entries);
        loadWallets();
    } catch (err) {
        alert(`Error saving wallet: ${err.message}`);
    }
}
function newWallet() {
    document
        .querySelectorAll("#wallet-list .fs-item.selected")
        .forEach(e => e.classList.remove("selected"));
    selectedWalletId = null;
    document.getElementById("wallet-name").value = "";
    clearWalletFields();
}
async function deleteWallet() {
    if (!selectedWalletId) {
        alert("No wallet selected");
        return;
    }
    if (!confirm(`Delete wallet "${selectedWalletId}"?`)) {
        return;
    }
    try {
        const res = await fetch(
            `${API}/api/wallets/${encodeURIComponent(selectedWalletId)}`,
            { method: "DELETE" }
        );
        if (!res.ok) throw new Error("Failed to delete");
        loadWallets();
        document.getElementById("wallet-name").value = "";
        clearWalletFields();
        selectedWalletId = null;
    } catch (err) {
        alert(err.message);
    }
}
function openWalletsModal() {
    closeCmdModal();
    switchViewTab("wallets");
    loadWallets();
}
function populateWdAlgoSuggestions() {
    const algoNames = new Set();
    for (const rigName of Object.keys(rigsState || {})) {
        if (rigName === "rigs") continue;
        const data = rigsState[rigName]?.data;
        if (!data) continue;
        DataHelper.getAllAlgorithms(data).forEach(algo => {
            const name = DataHelper.getAlgorithmName(algo);
            if (name && name !== "--") algoNames.add(name);
        });
    }
    for (const w of wallets || []) {
        const coin = (w.Coin || "").trim();
        if (coin) algoNames.add(coin);
    }
    wdAlgoSuggestionsList = [...algoNames].sort();
}
function renderWdAlgoSuggestions(inputEl) {
    const box = inputEl.parentElement.querySelector(".wdconfig-algo-suggestions");
    if (!box) return;
    const rect = inputEl.getBoundingClientRect();
    box.style.left = `${rect.left}px`;
    box.style.top = `${rect.bottom + 4}px`;
    box.style.width = `${rect.width}px`;
    const q = (inputEl.value || "").trim().toLowerCase();
    const matches = q
        ? wdAlgoSuggestionsList.filter(name => name.toLowerCase().includes(q))
        : wdAlgoSuggestionsList;
    box.innerHTML = "";
    box.appendChild(createClearSelectionItem("wdconfig-algo-suggestion-item", box, () => {
        inputEl.value = "";
        inputEl.dataset.suppressSuggestions = "1";
        inputEl.dispatchEvent(new Event("input", { bubbles: true }));
        delete inputEl.dataset.suppressSuggestions;
    }));
    matches.forEach(name => {
        const item = document.createElement("div");
        item.className = "wdconfig-algo-suggestion-item";
        item.textContent = name;
        item.addEventListener("mousedown", (e) => {
            e.preventDefault();
            inputEl.value = name;
            box.classList.add("hidden");
            box.innerHTML = "";
            inputEl.dataset.suppressSuggestions = "1";
            inputEl.dispatchEvent(new Event("input", { bubbles: true }));
            delete inputEl.dataset.suppressSuggestions;
        });
        box.appendChild(item);
    });
    box.classList.remove("hidden");
}
// Watchdog "Apply to", same as Overclocking, is persisted as a leading "# APPLY_TO=..." comment
// line in wdconfig-raw, placed BEFORE the "tee ... <<'EOF'" line (see wrapWdConfigCommand()) so it
// never ends up inside the conf file actually written on the rig. It round-trips through
// save/load and drives cmdModalRigOverride at send time.
let wdApplyToRigs = new Set();
function isWdApplyToDropdownOpen() {
    const list = document.getElementById("wd-apply-to-list");
    return !!list && !list.classList.contains("hidden");
}
function openWdApplyToDropdown() {
    populateWdApplyToWorkerList();
    document.getElementById("wd-apply-to-list")?.classList.remove("hidden");
}
function closeWdApplyToDropdown() {
    document.getElementById("wd-apply-to-list")?.classList.add("hidden");
}
function toggleWdApplyToDropdown() {
    if (isWdApplyToDropdownOpen()) {
        closeWdApplyToDropdown();
    } else {
        openWdApplyToDropdown();
    }
}
function updateWdApplyToToggleLabel() {
    const btn = document.getElementById("btn-wd-apply-to-toggle");
    if (!btn) return;
    if (wdApplyToRigs.size === 0) {
        btn.textContent = "Workers";
    } else if (wdApplyToRigs.size === 1) {
        btn.textContent = Array.from(wdApplyToRigs)[0];
    } else {
        btn.textContent = `${wdApplyToRigs.size} workers`;
    }
}
function updateWdApplyToWorkersOptionCheckedState() {
    const opt = document.getElementById("wd-apply-to-workers-option");
    if (opt) opt.classList.toggle("fs-apply-to-active", wdApplyToRigs.size === 0);
}
function populateWdApplyToWorkerList() {
    const container = document.getElementById("wd-apply-to-workers");
    if (!container) return;
    container.innerHTML = "";
    const rigNames = Object.keys(rigsState || {})
        .filter(name => name !== "rigs")
        .sort();
    rigNames.forEach((name) => {
        const row = document.createElement("label");
        row.className = "fs-apply-to-worker-row";
        const cb = document.createElement("input");
        cb.type = "checkbox";
        cb.checked = wdApplyToRigs.has(name);
        cb.addEventListener("change", () => {
            if (cb.checked) {
                wdApplyToRigs.add(name);
            } else {
                wdApplyToRigs.delete(name);
            }
            updateWdApplyToToggleLabel();
            updateWdApplyToWorkersOptionCheckedState();
            syncWdRawAfterApplyToChange();
        });
        const span = document.createElement("span");
        span.textContent = name;
        row.appendChild(cb);
        row.appendChild(span);
        container.appendChild(row);
    });
    updateWdApplyToWorkersOptionCheckedState();
}
function setWdApplyToRigs(names) {
    const rigNames = new Set(Object.keys(rigsState || {}).filter(name => name !== "rigs"));
    wdApplyToRigs = new Set((Array.isArray(names) ? names : []).filter(name => rigNames.has(name)));
    updateWdApplyToToggleLabel();
    if (isWdApplyToDropdownOpen()) populateWdApplyToWorkerList();
}
function clearWdApplyToSelection() {
    wdApplyToRigs.clear();
    updateWdApplyToToggleLabel();
    populateWdApplyToWorkerList();
    syncWdRawAfterApplyToChange();
}
function getWdApplyToFromScript(scriptText) {
    const m = (scriptText || "").match(/^# APPLY_TO=(.*)$/m);
    if (!m) return [];
    return m[1].split(",").map(s => s.trim()).filter(Boolean);
}
function syncWdRawAfterApplyToChange() {
    const rawEl = document.getElementById("wdconfig-raw");
    if (!rawEl) return;
    let text = rawEl.value.replace(/^# APPLY_TO=.*\n?/m, "");
    if (wdApplyToRigs.size > 0) {
        text = `# APPLY_TO=${Array.from(wdApplyToRigs).join(",")}\n${text}`;
    }
    rawEl.value = text;
    autoResizeWdRaw();
}
function openWdConfigModal() {
    closeCmdModal();
    switchViewTab("watchdog");
    loadWatchdogProfiles();
    updateWdHashrateUnitLabel();
    loadWallets();
    populateWdAlgoSuggestions();
    const tbody = document.getElementById("wdconfig-rows");
    if (tbody && tbody.children.length === 0) {
        addWdConfigRow();
    }
    const count = selectedRigs.size;
    const countEl = document.getElementById("wdconfig-target-count");
    const labelEl = document.getElementById("wdconfig-target-label");
    if (countEl) countEl.textContent = count;
    if (labelEl) labelEl.textContent = count === 1 ? "worker" : "workers";
    const statusEl = document.getElementById("wdconfig-status");
    if (statusEl) statusEl.textContent = "";
    resetWdTabBodyHeight();
    setWdConfigTab("raw");
    rebuildWdRawFromSettings();
    autoLoadWdConfigForSelectedRig();
    lastSyncedWdConfigRig = selectedRigs.size === 1 ? Array.from(selectedRigs)[0] : null;
}
function closeWdConfigModal() {
    pendingWdConfigFetchRig = null;
}
function createDefaultWdRowSettings() {
    return {
        actions: { ...WD_ACTION_CHECKBOX_DEFAULTS },
        customScript: "",
    };
}
function saveWdPanelStateToSelectedRow() {
    if (!selectedWdRowId) return;
    const val = id => document.getElementById(id)?.value ?? "";
    const flag = id => !!document.getElementById(id)?.checked;
    const actions = {};
    for (const id of Object.keys(WD_ACTION_CHECKBOX_DEFAULTS)) {
        actions[id] = flag(id);
    }
    wdRowSettings.set(selectedWdRowId, {
        actions,
        customScript: val("wdconfig-custom-script"),
    });
}
function loadWdRowSettingsIntoPanel(rowId) {
    const settings = wdRowSettings.get(rowId) || createDefaultWdRowSettings();
    for (const [id, defaultChecked] of Object.entries(WD_ACTION_CHECKBOX_DEFAULTS)) {
        const el = document.getElementById(id);
        if (el) el.checked = settings.actions[id] ?? defaultChecked;
    }
    const scriptEl = document.getElementById("wdconfig-custom-script");
    if (scriptEl) scriptEl.value = settings.customScript || "";
    updateWdCustomScriptEnabled();
}
function updateWdEditingAlgoLabel() {
    const label = document.getElementById("wdconfig-editing-algo-label");
    const scriptLabel = document.getElementById("wdconfig-custom-script-selected-label");
    const triggerLabel = document.getElementById("wdconfig-when-triggered-selected-label");
    if (!selectedWdRowId) {
        if (label) label.textContent = "— select an algorithm row below to edit its settings";
        if (scriptLabel) scriptLabel.textContent = "";
        if (triggerLabel) triggerLabel.textContent = "";
        return;
    }
    const tr = document.querySelector(`#wdconfig-rows .wdconfig-row[data-wd-row-id="${selectedWdRowId}"]`);
    const algoName = tr?.querySelector(".wdconfig-algo")?.value.trim();
    if (label) label.textContent = `— editing "${algoName || "(unnamed algorithm)"}"`;
    if (scriptLabel) scriptLabel.textContent = `(${algoName || "unnamed algorithm"})`;
    if (triggerLabel) triggerLabel.textContent = `(${algoName || "unnamed algorithm"})`;
}
function selectWdRow(rowId) {
    if (rowId === selectedWdRowId) return;
    saveWdPanelStateToSelectedRow();
    selectedWdRowId = rowId;
    document.querySelectorAll("#wdconfig-rows .wdconfig-row").forEach(tr => {
        tr.classList.toggle("wdconfig-row-selected", tr.dataset.wdRowId === rowId);
    });
    loadWdRowSettingsIntoPanel(rowId);
    updateWdEditingAlgoLabel();
    rebuildWdRawFromSettings();
}
function selectFirstWdRow() {
    const firstTr = document.querySelector("#wdconfig-rows .wdconfig-row");
    if (firstTr) {
        selectWdRow(firstTr.dataset.wdRowId);
    } else {
        selectedWdRowId = null;
        updateWdEditingAlgoLabel();
        // No algorithm rows - rebuild explicitly since selectWdRow() won't run to do it.
        rebuildWdRawFromSettings();
    }
}
function getWdHashrateMultiplier() {
    return HASHRATE_UNIT_MULTIPLIERS[wdHashrateUnit] || 1;
}
function formatWdHashrateForDisplay(trueHs) {
    const n = Number(trueHs);
    if (Number.isNaN(n)) return 0;
    const displayValue = n / getWdHashrateMultiplier();
    return Math.round(displayValue * 100) / 100;
}
function updateWdHashrateUnitLabel() {
    document.querySelectorAll(".wdconfig-hashrate-unit-label").forEach(label => {
        label.textContent = wdHashrateUnit;
    });
    document.getElementById("wdconfig-hashrate-unit-down")?.toggleAttribute(
        "disabled", WD_HASHRATE_UNITS.indexOf(wdHashrateUnit) === 0
    );
    document.getElementById("wdconfig-hashrate-unit-up")?.toggleAttribute(
        "disabled", WD_HASHRATE_UNITS.indexOf(wdHashrateUnit) === WD_HASHRATE_UNITS.length - 1
    );
}
function setWdHashrateUnit(newUnit) {
    if (!HASHRATE_UNIT_MULTIPLIERS[newUnit] || newUnit === wdHashrateUnit) return;
    const oldMultiplier = getWdHashrateMultiplier();
    wdHashrateUnit = newUnit;
    document.querySelectorAll("#wdconfig-rows .wdconfig-row .wdconfig-hashrate").forEach(input => {
        const current = Number(input.value);
        if (Number.isNaN(current)) return;
        const trueHs = current * oldMultiplier;
        input.value = formatWdHashrateForDisplay(trueHs);
    });
    updateWdHashrateUnitLabel();
    rebuildWdRawFromSettings();
}
function stepWdHashrateUnit(direction) {
    const idx = WD_HASHRATE_UNITS.indexOf(wdHashrateUnit);
    const newIdx = idx + direction;
    if (newIdx < 0 || newIdx >= WD_HASHRATE_UNITS.length) return;
    setWdHashrateUnit(WD_HASHRATE_UNITS[newIdx]);
}
function stepWdGlobalStopFails(direction) {
    const el = document.getElementById("wdconfig-global-stop-fails");
    if (!el) return;
    const next = Math.max(0, (Number(el.value) || 0) + direction);
    el.value = next;
    rebuildWdRawFromSettings();
}
function stepWdInterval(inputId, direction) {
    const el = document.getElementById(inputId);
    if (!el) return;
    const next = Math.max(5, (Number(el.value) || 60) + direction * 5);
    el.value = next;
    rebuildWdRawFromSettings();
}
function addWdConfigRow(row, opts) {
    const r = row || { algo: "", minHashrate: 1, minWatts: 20, maxWatts: 0, grace: 3, cooldown: 600 };
    const tbody = document.getElementById("wdconfig-rows");
    if (!tbody) return;
    const rowId = String(++wdRowIdCounter);
    wdRowSettings.set(rowId, (opts && opts.settings) || createDefaultWdRowSettings());
    const tr = document.createElement("tr");
    tr.className = "wdconfig-row";
    tr.dataset.wdRowId = rowId;
    tr.innerHTML = `
        <td>
            <span class="wdconfig-algo-autocomplete">
                <input type="text" class="wdconfig-input wdconfig-algo" value="${escapeHtml(r.algo)}" placeholder="e.g. kheavyhash" autocomplete="off" />
                <div class="wdconfig-algo-suggestions hidden"></div>
            </span>
        </td>
        <td><input type="number" class="wdconfig-input wdconfig-hashrate" min="0" step="any" value="${formatWdHashrateForDisplay(r.minHashrate)}" /></td>
        <td><input type="number" class="wdconfig-input" min="0" step="1" value="${r.minWatts}" /></td>
        <td><input type="number" class="wdconfig-input" min="0" step="1" value="${r.maxWatts}" /></td>
        <td><input type="number" class="wdconfig-input" min="1" step="1" value="${r.grace}" /></td>
        <td><input type="number" class="wdconfig-input" min="0" step="1" value="${r.cooldown}" /></td>
        <td><button class="wdconfig-remove-row" title="Remove row">&times;</button></td>
    `;
    tr.querySelector(".wdconfig-remove-row").addEventListener("click", (ev) => {
        ev.stopPropagation();
        const wasSelected = rowId === selectedWdRowId;
        wdRowSettings.delete(rowId);
        tr.remove();
        if (wasSelected) {
            selectedWdRowId = null;
            selectFirstWdRow();
        }
        rebuildWdRawFromSettings();
    });
    tr.addEventListener("click", () => selectWdRow(rowId));
    const algoInput = tr.querySelector(".wdconfig-algo");
    algoInput.addEventListener("input", () => {
        if (rowId === selectedWdRowId) updateWdEditingAlgoLabel();
        if (!algoInput.dataset.suppressSuggestions) renderWdAlgoSuggestions(algoInput);
    });
    algoInput.addEventListener("focus", () => renderWdAlgoSuggestions(algoInput));
    tbody.appendChild(tr);
    if (!opts || !opts.skipSelect) selectWdRow(rowId);
    if (!opts || !opts.skipRebuild) rebuildWdRawFromSettings();
}
function collectWdConfigRows() {
    const rows = [];
    for (const tr of document.querySelectorAll("#wdconfig-rows .wdconfig-row")) {
        const inputs = tr.querySelectorAll(".wdconfig-input");
        const algo = inputs[0].value.trim();
        if (!algo) continue;
        const nums = [inputs[1].value, inputs[2].value, inputs[3].value, inputs[4].value, inputs[5].value]
            .map(v => Number(v));
        if (nums.some(n => Number.isNaN(n))) {
            alert(`Row "${algo}" has a non-numeric value - fix it before applying.`);
            return null;
        }
        rows.push({
            algo,
            minHashrate: nums[0] * getWdHashrateMultiplier(),
            minWatts: nums[1],
            maxWatts: nums[2],
            grace: nums[3],
            cooldown: nums[4],
        });
    }
    return rows;
}
function b64EncodeUtf8(str) {
    try {
        return btoa(unescape(encodeURIComponent(str || "")));
    } catch (e) {
        return "";
    }
}
function b64DecodeUtf8(b64) {
    try {
        return decodeURIComponent(escape(atob(b64 || "")));
    } catch (e) {
        return "";
    }
}
function saveWdLogTermScriptFromPanel() {
    if (!selectedWdLogTermRowId) return;
    const el = document.getElementById("wdconfig-logwatcher-custom-script");
    wdLogTermScripts.set(selectedWdLogTermRowId, el ? el.value : "");
}
function loadWdLogTermScriptIntoPanel(rowId) {
    const el = document.getElementById("wdconfig-logwatcher-custom-script");
    if (el) el.value = wdLogTermScripts.get(rowId) || "";
    updateWdLogTermScriptEnabled();
}
function updateWdLogTermScriptEnabled() {
    // Editable as soon as a term row is selected, independent of the "Script" action checkbox.
    const el = document.getElementById("wdconfig-logwatcher-custom-script");
    if (!el) return;
    el.disabled = !selectedWdLogTermRowId;
}
function updateWdEditingLogTermLabel() {
    const label = document.getElementById("wdconfig-editing-logterm-label");
    const scriptLabel = document.getElementById("wdconfig-logterm-script-selected-label");
    if (!selectedWdLogTermRowId) {
        if (label) label.textContent = "— select a term row above to edit its script";
        if (scriptLabel) scriptLabel.textContent = "";
        return;
    }
    const tr = document.querySelector(`#wdconfig-logterm-rows .wdconfig-logterm-row[data-wd-log-term-row-id="${selectedWdLogTermRowId}"]`);
    const contains = tr?.querySelector(".wdconfig-logterm-contains")?.value.trim();
    const notContains = tr?.querySelector(".wdconfig-logterm-notcontains")?.value.trim();
    const display = notContains ? `${contains || "unnamed term"} | ${notContains}` : (contains || "unnamed term");
    if (label) label.textContent = `— editing "${contains || "(unnamed term)"}"`;
    if (scriptLabel) scriptLabel.textContent = `(${display})`;
}
function selectWdLogTermRow(rowId) {
    if (rowId === selectedWdLogTermRowId) return;
    saveWdLogTermScriptFromPanel();
    selectedWdLogTermRowId = rowId;
    document.querySelectorAll("#wdconfig-logterm-rows .wdconfig-logterm-row").forEach(tr => {
        tr.classList.toggle("wdconfig-row-selected", tr.dataset.wdLogTermRowId === rowId);
    });
    loadWdLogTermScriptIntoPanel(rowId);
    updateWdEditingLogTermLabel();
}
function selectFirstWdLogTermRow() {
    const firstTr = document.querySelector("#wdconfig-logterm-rows .wdconfig-logterm-row");
    if (firstTr) {
        selectWdLogTermRow(firstTr.dataset.wdLogTermRowId);
    } else {
        selectedWdLogTermRowId = null;
        updateWdEditingLogTermLabel();
        updateWdLogTermScriptEnabled();
    }
}
function addWdLogTermRow(row, opts) {
    const r = row || { contains: "", notContains: "", severity: "warn", actions: {}, customScript: "", slot: "gpu" };
    const tbody = document.getElementById("wdconfig-logterm-rows");
    if (!tbody) return;
    const rowId = String(++wdLogTermRowIdCounter);
    wdLogTermScripts.set(rowId, r.customScript || "");
    const tr = document.createElement("tr");
    tr.className = "wdconfig-logterm-row";
    tr.dataset.wdLogTermRowId = rowId;
    const slotValue = WD_LOG_WATCHER_SLOT_IDS.includes(r.slot) ? r.slot : "all";
    const slotOptions = [["all", "All"], ...WD_LOG_WATCHER_SLOT_IDS.map(s => [s, s.toUpperCase()])]
        .map(([val, label]) => `<option value="${val}"${val === slotValue ? " selected" : ""}>${label}</option>`)
        .join("");
    const severityOptions = WD_LOG_WATCHER_SEVERITIES
        .map(sev => `<option value="${sev}"${sev === r.severity ? " selected" : ""}>${WD_LOG_WATCHER_SEVERITY_LABELS[sev]}</option>`)
        .join("");
    const actionsHtml = WD_LOG_TERM_ACTION_DEFS
        .map(([slug, key, label]) => `
            <label class="checkbox-label wdconfig-logterm-action-label" title="${label}">
                <input type="checkbox" class="wdconfig-logterm-action" data-action-key="${key}"${r.actions && r.actions[key] ? " checked" : ""}>
                <span class="checkbox-text">${label}</span>
            </label>`)
        .join("");
    tr.innerHTML = `
        <td><select class="wdconfig-logterm-slot" title="Which worker log this term scans - All checks every enabled Watch Slot above">${slotOptions}</select></td>
        <td><input type="text" class="wdconfig-input wdconfig-logterm-contains" value="${escapeHtml(r.contains)}" placeholder="e.g. error, timeout" autocomplete="off" title="Comma-separated list - line must contain ALL of these to match" /></td>
        <td><input type="text" class="wdconfig-input wdconfig-logterm-notcontains" value="${escapeHtml(r.notContains)}" placeholder="e.g. debug" autocomplete="off" title="Comma-separated list - line must contain NONE of these to match" /></td>
        <td><select class="wdconfig-severity-select" data-severity="${r.severity}">${severityOptions}</select></td>
        <td><div class="wdconfig-logterm-actions">${actionsHtml}</div></td>
        <td><button class="wdconfig-remove-row" title="Remove term">&times;</button></td>
    `;
    const slotSelect = tr.querySelector(".wdconfig-logterm-slot");
    slotSelect.addEventListener("change", () => {
        if (rowId === selectedWdLogTermRowId) updateWdEditingLogTermLabel();
    });
    for (const cls of [".wdconfig-logterm-contains", ".wdconfig-logterm-notcontains"]) {
        const input = tr.querySelector(cls);
        input.addEventListener("input", () => {
            if (/[;|]/.test(input.value)) input.value = input.value.replace(/[;|]/g, "");
            if (rowId === selectedWdLogTermRowId) updateWdEditingLogTermLabel();
        });
    }
    const severitySelect = tr.querySelector(".wdconfig-severity-select");
    severitySelect.addEventListener("change", () => {
        severitySelect.dataset.severity = severitySelect.value;
    });
    tr.querySelectorAll(".wdconfig-logterm-action").forEach(cb => {
        cb.addEventListener("change", () => {
            if (rowId === selectedWdLogTermRowId) updateWdLogTermScriptEnabled();
        });
    });
    tr.querySelector(".wdconfig-remove-row").addEventListener("click", (ev) => {
        ev.stopPropagation();
        const wasSelected = rowId === selectedWdLogTermRowId;
        wdLogTermScripts.delete(rowId);
        tr.remove();
        if (wasSelected) {
            selectedWdLogTermRowId = null;
            selectFirstWdLogTermRow();
        }
        rebuildWdRawFromSettings();
    });
    tr.addEventListener("click", () => selectWdLogTermRow(rowId));
    tbody.appendChild(tr);
    if (!opts || !opts.skipSelect) selectWdLogTermRow(rowId);
    if (!opts || !opts.skipRebuild) rebuildWdRawFromSettings();
}
function collectWdLogTermRows() {
    const rows = [];
    for (const tr of document.querySelectorAll("#wdconfig-logterm-rows .wdconfig-logterm-row")) {
        const contains = tr.querySelector(".wdconfig-logterm-contains")?.value.trim();
        if (!contains) continue;
        const notContains = tr.querySelector(".wdconfig-logterm-notcontains")?.value.trim() || "";
        const severity = tr.querySelector(".wdconfig-severity-select")?.value || "warn";
        const slot = tr.querySelector(".wdconfig-logterm-slot")?.value || "all";
        const actions = {};
        tr.querySelectorAll(".wdconfig-logterm-action").forEach(cb => {
            actions[cb.dataset.actionKey] = cb.checked;
        });
        const rowId = tr.dataset.wdLogTermRowId;
        const customScript = rowId === selectedWdLogTermRowId
            ? (document.getElementById("wdconfig-logwatcher-custom-script")?.value || "")
            : (wdLogTermScripts.get(rowId) || "");
        rows.push({ contains, notContains, severity, actions, customScript, slot });
    }
    return rows;
}
function buildWdConfigFileContent(rows) {
    const header = [
        "# rigcontrol-watchdog.conf - generated from the dashboard's Watchdog Config module",
        "# ALGO,MIN_HASHRATE_HS,MIN_WATTS_TOTAL,GRACE_CHECKS,COOLDOWN_SECONDS",
    ].join("\n");
    const lines = rows.map(r =>
        `${r.algo},${r.minHashrate},${r.minWatts},${r.grace},${r.cooldown}`
    );
    return `${header}\n${lines.join("\n")}\n`;
}
function getWatchdogProfileName() {
    const el = document.getElementById("wdconfig-name");
    if (!el) return "";
    return el.value
        .trim()
        .toLowerCase()
        .replace(/\s+/g, "-")
        .replace(/[^a-z0-9\-]/g, "");
}
async function loadWatchdogProfiles() {
    try {
        const res = await fetch(`${API}/api/watchdog-profiles`);
        if (!res.ok) {
            console.error("Failed to load watchdog profiles");
            return;
        }
        watchdogProfiles = await res.json();
        renderWatchdogProfiles();
    } catch (e) {
        console.error("Error loading watchdog profiles:", e);
    }
}
function extractWdListRawValue(rawText, key) {
    if (!rawText) return "";
    const m = rawText.match(new RegExp(`^${key}\\s+"([^"]*)"\\s*$`, "m"));
    return m ? m[1] : "";
}
function renderWatchdogProfiles() {
    const list = document.getElementById("wdconfig-list");
    if (!list) return;
    list.innerHTML = "";
    const sorted = [...watchdogProfiles].sort((a, b) =>
        naturalCompare(a.WatchdogProfileId, b.WatchdogProfileId)
    );
    for (const p of sorted) {
        const row = document.createElement("div");
        row.className = "fs-item";
        const raw = p.Value || "";
        const miningOn = extractWdListRawValue(raw, "MINING_WATCHDOG_ENABLED") === "1";
        const logsOn = extractWdListRawValue(raw, "LOG_WATCHER_ENABLED") === "1";
        const slotsRaw = extractWdListRawValue(raw, "LOG_WATCHER_SLOTS");
        const slotsDisplay = slotsRaw
            ? slotsRaw.split(",").filter(Boolean).map(s => s.toUpperCase()).join(", ")
            : "-";
        const algoNames = [...raw.matchAll(/^\[(.+?)\]\s*$/gm)].map(m => m[1].trim()).filter(Boolean);
        const algoDisplay = algoNames.length ? algoNames.join(", ") : "-";
        const applyToWorkers = getWdApplyToFromScript(raw);
        const applyToDisplay = applyToWorkers.length > 0 ? applyToWorkers.join(", ") : "Workers";
        row.innerHTML = `
            <div class="fs-item-grid">
                <span class="fs-item-col fs-item-col-name">${escapeHtml(p.WatchdogProfileId)}</span>
                <span class="fs-item-col fs-item-col-applyto" title="${escapeHtml(applyToDisplay)}">${escapeHtml(applyToDisplay)}</span>
                <span class="fs-item-col fs-item-col-slots" title="${escapeHtml(slotsDisplay)}">${escapeHtml(slotsDisplay)}</span>
                <span class="fs-item-col fs-item-col-mining" title="Mining Watchdog ${miningOn ? "enabled" : "disabled"}">${miningOn ? "✓" : "—"}</span>
                <span class="fs-item-col fs-item-col-logs" title="Log Watcher ${logsOn ? "enabled" : "disabled"}">${logsOn ? "✓" : "—"}</span>
                <span class="fs-item-col fs-item-col-algo" title="${escapeHtml(algoDisplay)}">${escapeHtml(algoDisplay)}</span>
            </div>
        `;
        row.dataset.id = p.WatchdogProfileId;
        row.dataset.value = raw;
        row.dataset.mining = miningOn ? "1" : "0";
        row.dataset.logs = logsOn ? "1" : "0";
        row.dataset.algo = algoNames.join(",");
        row.addEventListener("click", () => {
            document
                .querySelectorAll("#wdconfig-list .fs-item.selected")
                .forEach(e => e.classList.remove("selected"));
            row.classList.add("selected");
            selectedWatchdogProfileId = p.WatchdogProfileId;
            document.getElementById("wdconfig-name").value = p.WatchdogProfileId;
        });
        list.appendChild(row);
    }
    populateWdAlgoFilter();
    syncWdListColumnWidths();
}
function populateWdAlgoFilter() {
    const select = document.getElementById("wdconfig-algo-filter");
    if (!select) return;
    const previousValue = select.value;
    const algos = [...new Set(
        Array.from(document.querySelectorAll("#wdconfig-list .fs-item"))
            .flatMap((item) => (item.dataset.algo || "").split(",").filter(Boolean))
    )].sort((a, b) => a.localeCompare(b));
    select.innerHTML = "";
    const allOption = document.createElement("option");
    allOption.value = "";
    allOption.textContent = "All algos";
    select.appendChild(allOption);
    for (const algo of algos) {
        const option = document.createElement("option");
        option.value = algo;
        option.textContent = algo;
        select.appendChild(option);
    }
    select.value = algos.includes(previousValue) ? previousValue : "";
}
// Header and list items are separate grid containers, so measure the widest content per column and publish it as a shared CSS var to keep rows aligned.
function syncWdListColumnWidths() {
    const panel = document.querySelector("#wdconfig-modal .fs-list-panel");
    if (!panel) return;
    const headerCols = document.querySelectorAll("#wdconfig-modal .fs-list-header .fs-item-col");
    if (!headerCols.length) return;
    const canvas = syncWdListColumnWidths._canvas || (syncWdListColumnWidths._canvas = document.createElement("canvas"));
    const ctx = canvas.getContext && canvas.getContext("2d");
    if (!ctx) return; // no 2D canvas support - fall back to the CSS defaults
    // measureText() ignores CSS text-transform/letter-spacing, so compensate manually for the uppercased header.
    function measuredWidth(el) {
        const cs = getComputedStyle(el);
        ctx.font = cs.font;
        let text = el.textContent;
        if (cs.textTransform === "uppercase") text = text.toUpperCase();
        else if (cs.textTransform === "lowercase") text = text.toLowerCase();
        const letterSpacing = parseFloat(cs.letterSpacing) || 0;
        return ctx.measureText(text).width + Math.max(0, text.length - 1) * letterSpacing;
    }
    const cols = ["name", "applyto", "slots", "mining", "logs"];
    const widths = {};
    for (const col of cols) {
        const headerEl = document.querySelector(`#wdconfig-modal .fs-list-header .fs-item-col-${col}`);
        widths[col] = headerEl ? measuredWidth(headerEl) : 0;
    }
    document.querySelectorAll("#wdconfig-list .fs-item").forEach(item => {
        for (const col of cols) {
            const el = item.querySelector(`.fs-item-col-${col}`);
            if (!el) continue;
            const w = measuredWidth(el);
            if (w > widths[col]) widths[col] = w;
        }
    });
    // Apply To can grow unbounded (long worker lists) - cap it like flightsheet/overclock do,
    // so one profile with many selected workers can't blow out the whole column layout.
    widths.applyto = Math.min(widths.applyto, FS_LIST_APPLYTO_MAX_PX);
    const PADDING = 16;
    for (const col of cols) {
        panel.style.setProperty(`--wd-col-${col}`, `${Math.ceil(widths[col] + PADDING)}px`);
    }
    filterWatchdogProfileList();
}
function loadSelectedWatchdogProfile() {
    const status = document.getElementById("wdconfig-status");
    if (!selectedWatchdogProfileId) {
        if (status) status.textContent = "Select a profile from the list first";
        return;
    }
    const p = watchdogProfiles.find(x => x.WatchdogProfileId === selectedWatchdogProfileId);
    if (!p) {
        if (status) status.textContent = "Selected profile no longer exists";
        return;
    }
    // Profiles saved before the raw box showed the full mkdir/tee/EOF command have a bare body
    // stored (optionally with a leading "# APPLY_TO=..." line) - strip that comment, re-wrap the
    // body, then re-add the comment outside the wrapper, so an old profile displays the same full
    // command shape as a freshly-built one instead of showing stale, un-wrapped content forever.
    const storedValue = p.Value || "";
    const bare = stripWdApplyToComment(storedValue);
    document.getElementById("wdconfig-name").value = p.WatchdogProfileId;
    setWdApplyToRigs(getWdApplyToFromScript(storedValue));
    let wrapped = wrapWdConfigCommand(bare);
    if (wdApplyToRigs.size > 0) {
        wrapped = `# APPLY_TO=${Array.from(wdApplyToRigs).join(",")}\n${wrapped}`;
    }
    document.getElementById("wdconfig-raw").value = wrapped;
    populateWdSettingsFromRaw(bare);
    resetWdTabBodyHeight();
    setWdConfigTab("raw");
    if (status) status.textContent = `Loaded "${p.WatchdogProfileId}"`;
}
function filterWatchdogProfileList() {
    const query = (document.getElementById("wdconfig-search")?.value || "").trim().toLowerCase();
    const statusFilter = document.getElementById("wdconfig-status-filter")?.value || "";
    const algoFilter = document.getElementById("wdconfig-algo-filter")?.value || "";
    document.querySelectorAll("#wdconfig-list .fs-item").forEach(item => {
        const matchesQuery = !query || item.textContent.toLowerCase().includes(query);
        const matchesStatus = !statusFilter
            || (statusFilter === "mining" ? item.dataset.mining === "1" : item.dataset.logs === "1");
        const algoList = (item.dataset.algo || "").split(",").filter(Boolean);
        const matchesAlgo = !algoFilter || algoList.includes(algoFilter);
        item.style.display = (matchesQuery && matchesStatus && matchesAlgo) ? "" : "none";
    });
}
function collectWatchdogProfileEntries() {
    const raw = document.getElementById("wdconfig-raw").value.trim();
    if (!raw) {
        alert("Cannot save an empty watchdog profile! Configure the settings above first.");
        throw new Error("Empty watchdog config");
    }
    return [
        { key: "RAW_CONFIG", gpu: 0, value: raw }
    ];
}
async function saveWatchdogProfile(profileId, entries) {
    if (!profileId) {
        throw new Error("Watchdog profile name is required");
    }
    if (!Array.isArray(entries) || entries.length === 0) {
        throw new Error("Watchdog profile has no entries to save");
    }
    const res = await fetch(
        `${API}/api/watchdog-profiles/${encodeURIComponent(profileId)}`,
        {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ entries })
        }
    );
    if (!res.ok) {
        const errorData = await res.json().catch(() => ({}));
        const errorMsg = errorData.detail || errorData.message || "Failed to save watchdog profile";
        throw new Error(errorMsg);
    }
    return await res.json();
}
async function saveWatchdogProfileFromDialog() {
    const profileId = getWatchdogProfileName();
    try {
        rebuildWdRawFromSettings();
        const entries = collectWatchdogProfileEntries();
        await saveWatchdogProfile(profileId, entries);
        loadWatchdogProfiles();
    } catch (err) {
        alert(`Error saving watchdog profile: ${err.message}`);
    }
}
async function deleteWatchdogProfile() {
    if (!selectedWatchdogProfileId) {
        alert("No watchdog profile selected");
        return;
    }
    if (!confirm(`Delete watchdog profile "${selectedWatchdogProfileId}"?`)) {
        return;
    }
    try {
        const res = await fetch(
            `${API}/api/watchdog-profiles/${encodeURIComponent(selectedWatchdogProfileId)}`,
            { method: "DELETE" }
        );
        if (!res.ok) throw new Error("Delete failed");
        loadWatchdogProfiles();
    } catch (err) {
        alert(`Error deleting watchdog profile: ${err.message}`);
    } finally {
        selectedWatchdogProfileId = null;
    }
}
function clearWdConfigFields() {
    document
        .querySelectorAll("#wdconfig-list .fs-item.selected")
        .forEach(e => e.classList.remove("selected"));
    selectedWatchdogProfileId = null;
    wdApplyToRigs.clear();
    updateWdApplyToToggleLabel();
    const tbody = document.getElementById("wdconfig-rows");
    if (tbody) tbody.innerHTML = "";
    wdRowSettings.clear();
    selectedWdRowId = null;
    document.getElementById("wdconfig-name").value = "";
    const logTermTbody = document.getElementById("wdconfig-logterm-rows");
    if (logTermTbody) logTermTbody.innerHTML = "";
    wdLogTermScripts.clear();
    selectedWdLogTermRowId = null;
    updateWdEditingLogTermLabel();
    updateWdLogTermScriptEnabled();
    const miningEnabledEl = document.getElementById("wdconfig-mining-enabled");
    if (miningEnabledEl) miningEnabledEl.checked = false;
    const miningIntervalEl = document.getElementById("wdconfig-mining-interval");
    if (miningIntervalEl) miningIntervalEl.value = WD_MINING_INTERVAL_DEFAULT;
    const logWatcherEnabledEl = document.getElementById("wdconfig-logwatcher-enabled");
    if (logWatcherEnabledEl) logWatcherEnabledEl.checked = false;
    const logWatcherIntervalEl = document.getElementById("wdconfig-logwatcher-interval");
    if (logWatcherIntervalEl) logWatcherIntervalEl.value = WD_LOG_WATCHER_INTERVAL_DEFAULT;
    resetWdTabBodyHeight();
    setWdConfigTab("raw");
    addWdConfigRow();
}
function resetWdSettingsToDefaults() {
    for (const [id, checked] of Object.entries(WD_ACTION_CHECKBOX_DEFAULTS)) {
        const el = document.getElementById(id);
        if (el) el.checked = checked;
    }
    const script = document.getElementById("wdconfig-custom-script");
    if (script) script.value = "";
    updateWdCustomScriptEnabled();
    const globalStopInput = document.getElementById("wdconfig-global-stop-fails");
    if (globalStopInput) globalStopInput.value = WD_GLOBAL_STOP_FAILS_DEFAULT;
    const miningEnabledEl = document.getElementById("wdconfig-mining-enabled");
    if (miningEnabledEl) miningEnabledEl.checked = false;
    const miningIntervalEl = document.getElementById("wdconfig-mining-interval");
    if (miningIntervalEl) miningIntervalEl.value = WD_MINING_INTERVAL_DEFAULT;
    const logWatcherEnabledEl = document.getElementById("wdconfig-logwatcher-enabled");
    if (logWatcherEnabledEl) logWatcherEnabledEl.checked = false;
    const logWatcherIntervalEl = document.getElementById("wdconfig-logwatcher-interval");
    if (logWatcherIntervalEl) logWatcherIntervalEl.value = WD_LOG_WATCHER_INTERVAL_DEFAULT;
    const logTermTbody = document.getElementById("wdconfig-logterm-rows");
    if (logTermTbody) logTermTbody.innerHTML = "";
    wdLogTermScripts.clear();
    selectedWdLogTermRowId = null;
    updateWdEditingLogTermLabel();
    updateWdLogTermScriptEnabled();
}
function updateWdCustomScriptEnabled() {
    // Editable as soon as an algorithm row is selected, independent of the "Custom Script" action checkbox.
    const script = document.getElementById("wdconfig-custom-script");
    if (!script) return;
    script.disabled = !selectedWdRowId;
}
function buildWdConfigRawFromSettings() {
    saveWdPanelStateToSelectedRow();
    const globalStopEl = document.getElementById("wdconfig-global-stop-fails");
    const globalStopFails = globalStopEl ? Math.max(0, Number(globalStopEl.value) || 0) : WD_GLOBAL_STOP_FAILS_DEFAULT;
    const miningEnabled = document.getElementById("wdconfig-mining-enabled")?.checked ?? true;
    const miningIntervalEl = document.getElementById("wdconfig-mining-interval");
    const miningInterval = miningIntervalEl ? Math.max(5, Number(miningIntervalEl.value) || 60) : 60;
    const logWatcherEnabled = document.getElementById("wdconfig-logwatcher-enabled")?.checked ?? false;
    const logWatcherIntervalEl = document.getElementById("wdconfig-logwatcher-interval");
    const logWatcherInterval = logWatcherIntervalEl ? Math.max(5, Number(logWatcherIntervalEl.value) || 60) : 60;
    const logTermRows = collectWdLogTermRows();
    // Which logs need to be tailed, derived from the terms' own Slot dropdowns.
    const usedSlots = new Set(logTermRows.map(t => t.slot || "all"));
    const logWatcherSlots = (usedSlots.has("all") ? WD_LOG_WATCHER_SLOT_IDS : WD_LOG_WATCHER_SLOT_IDS.filter(s => usedSlots.has(s)))
        .join(",");
    const logWatcherTerms = logTermRows
        .map(t => {
            const actionKeys = Object.entries(t.actions)
                .filter(([, v]) => v)
                .map(([k]) => k)
                .join(",");
            return `${t.contains}|${t.notContains}|${t.severity}|${actionKeys}|${t.slot || "all"}`;
        })
        .join(";");
    const lines = [
        "# rigcontrol-watchdog.conf - generated from the dashboard's Watchdog Config module",
        "# Each algorithm below owns its own full settings block - click its row",
        "# in the Per-Algorithm Thresholds table above to edit it.",
        "# Mining Watchdog and Log Watcher run as two independent loops - each has its",
        "# own check interval below and is unaffected by the other's cadence or enable state.",
        "# Each log-watcher term owns its own custom script, shown below as a readable",
        "# LOG_WATCHER_TERM_SCRIPT_BEGIN/END block per term (in the same order as the",
        "# terms listed in LOG_WATCHER_TERMS above) - click its row above to edit it.",
        "",
        `MINING_WATCHDOG_STOP_AFTER_FAILS "${globalStopFails}"`,
        `MINING_WATCHDOG_ENABLED "${miningEnabled ? "1" : "0"}"`,
        `MINING_INTERVAL_SECONDS "${miningInterval}"`,
        `LOG_WATCHER_ENABLED "${logWatcherEnabled ? "1" : "0"}"`,
        `LOG_WATCHER_INTERVAL_SECONDS "${logWatcherInterval}"`,
        `LOG_WATCHER_SLOTS "${logWatcherSlots}"`,
        `LOG_WATCHER_TERMS "${logWatcherTerms}"`,
        "",
    ];
    logTermRows.forEach((t, idx) => {
        lines.push(`LOG_WATCHER_TERM_SCRIPT_BEGIN ${idx}`);
        lines.push(...(t.customScript || "").split("\n"));
        lines.push("LOG_WATCHER_TERM_SCRIPT_END");
        lines.push("");
    });
    for (const tr of document.querySelectorAll("#wdconfig-rows .wdconfig-row")) {
        const inputs = tr.querySelectorAll(".wdconfig-input");
        const algo = inputs[0].value.trim();
        if (!algo) continue;
        const settings = wdRowSettings.get(tr.dataset.wdRowId) || createDefaultWdRowSettings();
        const scriptLines = (settings.customScript || "").split("\n");
        const trueHashrateHs = Math.round((Number(inputs[1].value) || 0) * getWdHashrateMultiplier());
        lines.push(`[${algo}]`);
        lines.push(`MIN_HASHRATE_HS "${trueHashrateHs}"`);
        lines.push(`MIN_WATTS_TOTAL "${inputs[2].value}"`);
        lines.push(`MAX_WATTS_TOTAL "${inputs[3].value}"`);
        lines.push(`GRACE_CHECKS "${inputs[4].value}"`);
        lines.push(`COOLDOWN_SECONDS "${inputs[5].value}"`);
        for (const [id, key] of WD_ACTION_RAW_KEYS) {
            lines.push(`${key} "${settings.actions[id] ? "1" : "0"}"`);
        }
        lines.push("CUSTOM_SCRIPT_BEGIN");
        lines.push(...scriptLines);
        lines.push("CUSTOM_SCRIPT_END");
        lines.push("");
    }
    return lines.join("\n").replace(/\n+$/, "\n");
}
// Wraps the bare rigcontrol-watchdog.conf body in the actual mkdir/tee/heredoc command that gets
// sent - matching Overclocking/Flightsheets, whose raw boxes already show the full command rather
// than just the file body. Kept as its own function since 3 different places need to produce this
// same wrapped text: a fresh rebuild from the row/settings fields, a profile loaded from storage,
// and a live conf pulled from a rig via "cat".
function wrapWdConfigCommand(bareContent) {
    const heredocTag = "RIGCONTROL_WATCHDOG_CONF_EOF";
    return (
        `sudo mkdir -p ${TEMPLATES_CONFIG.watchdog.conf_dir}\n` +
        `tee ${TEMPLATES_CONFIG.watchdog.conf_path} > /dev/null <<'${heredocTag}'\n` +
        bareContent +
        (bareContent.endsWith("\n") ? "" : "\n") +
        heredocTag
    );
}
// Strips a leading "# APPLY_TO=..." line, if present, so it can be re-added OUTSIDE the tee
// heredoc instead of inside it - see the wdApplyToRigs comment above for why that placement matters.
function stripWdApplyToComment(text) {
    return (text || "").replace(/^# APPLY_TO=.*\n?/, "");
}
function rebuildWdRawFromSettings() {
    const bare = buildWdConfigRawFromSettings();
    let raw = wrapWdConfigCommand(bare);
    if (wdApplyToRigs.size > 0) {
        raw = `# APPLY_TO=${Array.from(wdApplyToRigs).join(",")}\n${raw}`;
    }
    const el = document.getElementById("wdconfig-raw");
    if (el) el.value = raw;
    autoResizeWdRaw();
}
function setWdConfigTab(tab) {
    // No-op: kept so existing call sites stay harmless.
}
function autoResizeWdRaw() {
}
function resetWdTabBodyHeight() {
}
function parseWdAlgoBlock(blockText) {
    const kv = {};
    for (const km of blockText.matchAll(/^([A-Z_]+)\s+"([^"]*)"\s*$/gm)) {
        kv[km[1]] = km[2];
    }
    const scriptMatch = blockText.match(/CUSTOM_SCRIPT_BEGIN\n([\s\S]*?)\nCUSTOM_SCRIPT_END/);
    const customScript = scriptMatch ? scriptMatch[1] : "";
    const actions = {};
    for (const [id, key] of WD_ACTION_RAW_KEYS) {
        actions[id] = kv[key] !== undefined ? kv[key] === "1" : WD_ACTION_CHECKBOX_DEFAULTS[id];
    }
    return {
        minHashrate: Number(kv.MIN_HASHRATE_HS) || 0,
        minWatts: Number(kv.MIN_WATTS_TOTAL) || 0,
        maxWatts: Number(kv.MAX_WATTS_TOTAL) || 0,
        grace: Number(kv.GRACE_CHECKS) || 1,
        cooldown: Number(kv.COOLDOWN_SECONDS) || 0,
        settings: {
            actions,
            customScript,
        },
    };
}
function populateWdSettingsFromRaw(rawText) {
    const tbody = document.getElementById("wdconfig-rows");
    if (tbody) tbody.innerHTML = "";
    wdRowSettings.clear();
    selectedWdRowId = null;
    resetWdSettingsToDefaults();
    if (!rawText || !rawText.trim()) {
        selectFirstWdRow();
        return;
    }
    const globalStopEl = document.getElementById("wdconfig-global-stop-fails");
    if (globalStopEl) {
        const gm = rawText.match(/^MINING_WATCHDOG_STOP_AFTER_FAILS\s+"(-?\d+)"\s*$/m);
        if (gm) globalStopEl.value = Math.max(0, Number(gm[1]) || 0);
    }
    const miningEnabledEl = document.getElementById("wdconfig-mining-enabled");
    if (miningEnabledEl) {
        const mm = rawText.match(/^MINING_WATCHDOG_ENABLED\s+"(\d)"\s*$/m);
        if (mm) miningEnabledEl.checked = mm[1] === "1";
    }
    const miningIntervalEl = document.getElementById("wdconfig-mining-interval");
    if (miningIntervalEl) {
        const mim = rawText.match(/^MINING_INTERVAL_SECONDS\s+"(\d+)"\s*$/m);
        miningIntervalEl.value = mim ? Math.max(5, Number(mim[1]) || WD_MINING_INTERVAL_DEFAULT) : WD_MINING_INTERVAL_DEFAULT;
    }
    const logWatcherEnabledEl = document.getElementById("wdconfig-logwatcher-enabled");
    if (logWatcherEnabledEl) {
        const lm = rawText.match(/^LOG_WATCHER_ENABLED\s+"(\d)"\s*$/m);
        if (lm) logWatcherEnabledEl.checked = lm[1] === "1";
    }
    const logWatcherIntervalEl = document.getElementById("wdconfig-logwatcher-interval");
    if (logWatcherIntervalEl) {
        const im = rawText.match(/^LOG_WATCHER_INTERVAL_SECONDS\s+"(\d+)"\s*$/m);
        logWatcherIntervalEl.value = im ? Math.max(5, Number(im[1]) || WD_LOG_WATCHER_INTERVAL_DEFAULT) : WD_LOG_WATCHER_INTERVAL_DEFAULT;
    }
    // LOG_WATCHER_SLOTS is derived output only; which logs get tailed comes from each term's Slot dropdown, parsed below.
    const legacySharedScriptMatch = rawText.match(/LOG_WATCHER_SCRIPT_BEGIN\n([\s\S]*?)\nLOG_WATCHER_SCRIPT_END/);
    const legacySharedScript = legacySharedScriptMatch ? legacySharedScriptMatch[1] : "";
    wdLogTermScripts.clear();
    selectedWdLogTermRowId = null;
    // Each term's script is a LOG_WATCHER_TERM_SCRIPT_BEGIN <index>/END block, index = its position in LOG_WATCHER_TERMS.
    const termScriptBlocks = new Map();
    for (const m of rawText.matchAll(/LOG_WATCHER_TERM_SCRIPT_BEGIN (\d+)\n([\s\S]*?)\nLOG_WATCHER_TERM_SCRIPT_END/g)) {
        termScriptBlocks.set(Number(m[1]), m[2]);
    }
    const termsMatch = rawText.match(/^LOG_WATCHER_TERMS\s+"([^"]*)"\s*$/m);
    if (termsMatch && termsMatch[1]) {
        termsMatch[1].split(";").forEach((entry, entryIdx) => {
            if (!entry.trim()) return;
            const rawParts = entry.split("|");
            let contains, notContains, severityRaw, actionsRaw, slotRaw, legacyScriptB64 = "";
            if (rawParts.length >= 6) {
                // Older format (briefly shipped): contains|notContains|severity|actions|scriptB64|slot
                [contains, notContains, severityRaw, actionsRaw, legacyScriptB64, slotRaw] = rawParts;
            } else {
                const parts = rawParts.slice();
                while (parts.length < 5) parts.push("");
                [contains, notContains, severityRaw, actionsRaw, slotRaw] = parts;
            }
            if (!contains.trim()) return;
            const actionKeys = new Set(actionsRaw.split(",").map(a => a.trim()).filter(Boolean));
            const actions = {};
            for (const [, key] of WD_LOG_TERM_ACTION_DEFS) {
                actions[key] = actionKeys.has(key);
            }
            const customScript = termScriptBlocks.has(entryIdx)
                ? termScriptBlocks.get(entryIdx)
                : (legacyScriptB64 ? b64DecodeUtf8(legacyScriptB64) : legacySharedScript);
            const slot = WD_LOG_WATCHER_SLOT_IDS.includes((slotRaw || "").trim()) ? slotRaw.trim() : "all";
            addWdLogTermRow({
                contains,
                notContains,
                severity: WD_LOG_WATCHER_SEVERITIES.includes(severityRaw) ? severityRaw : "warn",
                actions,
                customScript,
                slot,
            }, { skipSelect: true, skipRebuild: true });
        });
    }
    selectFirstWdLogTermRow();
    const blockHeaderRe = /^\[(.+?)\]\s*$/gm;
    const blockStarts = [];
    let hm;
    while ((hm = blockHeaderRe.exec(rawText)) !== null) {
        blockStarts.push({ algo: hm[1].trim(), headerIndex: hm.index, headerEnd: hm.index + hm[0].length });
    }
    if (blockStarts.length > 0) {
        for (let i = 0; i < blockStarts.length; i++) {
            const { algo, headerEnd } = blockStarts[i];
            if (!algo) continue;
            const blockEnd = i + 1 < blockStarts.length ? blockStarts[i + 1].headerIndex : rawText.length;
            const parsed = parseWdAlgoBlock(rawText.slice(headerEnd, blockEnd));
            addWdConfigRow({
                algo,
                minHashrate: parsed.minHashrate,
                minWatts: parsed.minWatts,
                maxWatts: parsed.maxWatts,
                grace: parsed.grace,
                cooldown: parsed.cooldown,
            }, { skipRebuild: true, skipSelect: true, settings: parsed.settings });
        }
        selectFirstWdRow();
        return;
    }
    const kv = {};
    for (const km of rawText.matchAll(/^([A-Z_]+)\s+"([^"]*)"\s*$/gm)) {
        kv[km[1]] = km[2];
    }
    const legacyActions = {};
    for (const [id, key] of WD_ACTION_RAW_KEYS) {
        legacyActions[id] = kv[key] !== undefined ? kv[key] === "1" : WD_ACTION_CHECKBOX_DEFAULTS[id];
    }
    const legacyCombinedMap = {
        ACTION_RESTART_SERVICE: ["wdconfig-action-restart-cpu", "wdconfig-action-restart-gpu"],
        ACTION_NOTIFY: ["wdconfig-action-email-notify", "wdconfig-action-sms-notify"],
        ACTION_RESTART_FAN_SERVICE: ["wdconfig-action-restart-fan"],
    };
    for (const [key, ids] of Object.entries(legacyCombinedMap)) {
        if (kv[key] === undefined) continue;
        ids.forEach(id => { legacyActions[id] = kv[key] === "1"; });
    }
    const legacyScriptMatch = rawText.match(/CUSTOM_SCRIPT_BEGIN\n([\s\S]*?)\nCUSTOM_SCRIPT_END/);
    const legacyScript = legacyScriptMatch ? legacyScriptMatch[1] : "";
    for (const line of rawText.split("\n")) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith("#")) continue;
        const parts = trimmed.split(",").map(p => p.trim());
        if (parts.length !== 5) continue;
        const [algo, minHashrate, minWatts, grace, cooldown] = parts;
        if (!algo || [minHashrate, minWatts, grace, cooldown].some(v => v === "" || isNaN(Number(v)))) continue;
        addWdConfigRow({
            algo,
            minHashrate: Number(minHashrate),
            minWatts: Number(minWatts),
            maxWatts: 0,
            grace: Number(grace),
            cooldown: Number(cooldown),
        }, {
            skipRebuild: true,
            skipSelect: true,
            settings: {
                actions: { ...legacyActions },
                customScript: legacyScript,
            },
        });
    }
    selectFirstWdRow();
}
function buildWdConfigCommand() {
    const rows = collectWdConfigRows();
    if (rows === null) return null;
    const miningEnabled = document.getElementById("wdconfig-mining-enabled")?.checked ?? true;
    if (rows.length === 0 && miningEnabled) {
        alert("Add at least one algorithm row before applying, or uncheck \"Enable Mining Watchdog\" on the Mining tab if you only want the Log Watcher.");
        return null;
    }
    // No rebuild and no re-wrapping here on purpose - the raw box already holds the FULL command
    // (mkdir + tee heredoc-wrapped conf body + closing tag, via rebuildWdRawFromSettings()'s call to
    // wrapWdConfigCommand()) and already reflects every field change (each row/checkbox handler calls
    // rebuildWdRawFromSettings() itself), so what's sent is exactly what's on screen, including any
    // direct manual edit to the raw box that a forced rebuild would otherwise clobber.
    return document.getElementById("wdconfig-raw").value;
}
function sendItWd() {
    if (selectedRigs.size === 0 && wdApplyToRigs.size === 0) {
        alert("No workers selected");
        return;
    }
    const command = buildWdConfigCommand();
    if (command === null) return;
    closeWdConfigModal();
    const input = document.getElementById("cmd-input");
    if (input) input.value = command;
    cmdModalRigOverride = wdApplyToRigs.size > 0 ? Array.from(wdApplyToRigs) : null;
    if (document.getElementById("confirm-wd")?.checked) {
        openCmdModal();
    } else {
        submitCmd();
    }
}
function autoLoadWdConfigForSelectedRig() {
    pendingWdConfigFetchRig = null;
    if (selectedRigs.size !== 1) return;
    const [rig] = selectedRigs;
    const statusEl = document.getElementById("wdconfig-status");
    pendingWdConfigFetchRig = rig;
    if (statusEl) statusEl.textContent = `Loading current config from ${rig}…`;
    sendCommandToSelectedRigs(`cat ${TEMPLATES_CONFIG.watchdog.conf_path}`).catch(err => {
        console.error("Failed to request current watchdog config", err);
        if (pendingWdConfigFetchRig === rig) pendingWdConfigFetchRig = null;
        if (statusEl) statusEl.textContent = `Failed to load current config from ${rig}`;
    });
}
const AGENTCONF_RAW_HEIGHT_KEY = "rigcontrol_agentconf_raw_height";
function restoreAgentConfRawHeight() {
    // Restores a manually-dragged height (native textarea resize handle, not the auto-fit
    // below) so it survives a page reload - same localStorage-per-element pattern as
    // CMD_INPUT_HEIGHT_KEY/CMD_OUTPUT_HEIGHT_KEY use for the Send Cmd modal's resizable boxes.
    // Only matters until the next real content load/edit, since resizeAgentConfRaw() below
    // will auto-fit over top of it then - that's fine, a saved height from a DIFFERENT rig's
    // (likely different-length) conf shouldn't outlive an actual new load anyway.
    const el = document.getElementById("agentconf-raw");
    const saved = localStorage.getItem(AGENTCONF_RAW_HEIGHT_KEY);
    if (el && saved) el.style.height = saved;
}
function saveAgentConfRawHeight() {
    const el = document.getElementById("agentconf-raw");
    if (el && el.style.height) localStorage.setItem(AGENTCONF_RAW_HEIGHT_KEY, el.style.height);
}
function resizeAgentConfRaw() {
    // Grows the textarea to fit its content instead of it having its own inner scrollbar -
    // #refresh-modal .cmd-body is already the scrollable container for the whole modal, so a
    // tall conf file scrolls the modal/page instead. Reset to "auto" first so shrinking (e.g.
    // Clear replacing a long real conf with the shorter template) actually shrinks the box
    // back down instead of scrollHeight staying pinned to the old, larger content.
    const el = document.getElementById("agentconf-raw");
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
}
// Wraps a bare rigcontrol-agent.conf body in the actual mkdir/tee/heredoc (+ optional restart)
// command that gets sent - same reasoning as Watchdog's wrapWdConfigCommand(): the raw box should
// always show the literal command Send Cmd will use, not just the file body with the wrapper
// assembled invisibly elsewhere at send time.
// Generic heredoc tag - fine for it to be shared across all CONF_EDIT_TYPES since only one type is
// ever loaded into agentconf-raw at a time (the box holds one conf's write-command at once).
const CONF_EDIT_HEREDOC_TAG = "RIGCONTROL_CONF_EDIT_EOF";
function wrapConfEditCommand(confType, bareContent, includeRestart) {
    const cfg = CONF_EDIT_TYPES[confType];
    if (!cfg) return bareContent;
    let command =
        `sudo mkdir -p ${cfg.dir()}\n` +
        `tee ${cfg.path()} > /dev/null <<'${CONF_EDIT_HEREDOC_TAG}'\n` +
        bareContent +
        (bareContent.endsWith("\n") ? "" : "\n") +
        CONF_EDIT_HEREDOC_TAG;
    if (includeRestart) command += `\n${cfg.restartCmd()}`;
    return command;
}
// Reverse of the above - pulls just the heredoc body back out of a (possibly hand-edited) wrapped
// command, for the one caller that wants the actual .conf file text rather than the send-command
// shape: the DB Backups snapshot (agent.conf only), which stores "what did this rig's conf file
// contain" for reference, not a shell command to replay. Falls back to the input unchanged if the
// wrapper markers aren't found (e.g. the user rewrote the box into something else entirely).
function unwrapConfEditCommand(text) {
    // wrapConfEditCommand() always leaves exactly one "\n" right before the closing tag (either
    // the body's own trailing newline, or one added for it) - that single newline is inherently
    // ambiguous to reverse (a bodyless-of-trailing-newline input is indistinguishable from one
    // that already had it), so this always re-adds it. Harmless: real conf files end in a newline
    // anyway, and this is only used for the informational DB Backups snapshot, never for sending.
    const tag = CONF_EDIT_HEREDOC_TAG;
    const openIdx = text.indexOf(`<<'${tag}'\n`);
    if (openIdx === -1) return text || "";
    const bodyStart = openIdx + `<<'${tag}'\n`.length;
    const closeIdx = text.indexOf(`\n${tag}`, bodyStart);
    if (closeIdx === -1) return text || "";
    return text.slice(bodyStart, closeIdx) + "\n";
}
// Refreshes the Conf tab's chrome (path label, Clear button visibility) to match whatever's
// currently selected in the type dropdown - called on dropdown change and whenever the tab is opened.
function updateConfEditTypeUi() {
    const cfg = CONF_EDIT_TYPES[selectedConfEditType];
    const labelEl = document.getElementById("agentconf-raw-label");
    if (labelEl) labelEl.textContent = cfg ? cfg.path() : "";
    // Only agent.conf has a bundled blank-example template to load - hide Clear for everything else
    // rather than have it silently do nothing. Inline style, not a "hidden" class - app.css only
    // defines that class scoped to specific parent selectors, not as a bare display:none utility.
    const clearBtn = document.getElementById("btn-agentconf-clear");
    if (clearBtn) clearBtn.style.display = cfg?.isAgent ? "" : "none";
}
function loadDefaultConfEditTemplate() {
    // Only agent.conf has a bundled blank example - the Clear button is hidden for every other
    // type (see updateConfEditTypeUi()), so this shouldn't normally be reachable otherwise.
    if (selectedConfEditType !== "agent.conf") return;
    const rawEl = document.getElementById("agentconf-raw");
    const includeRestart = document.getElementById("agentconf-restart-after-apply")?.checked ?? false;
    if (rawEl) rawEl.value = wrapConfEditCommand("agent.conf", AGENT_CONF_DEFAULT_TEMPLATE, includeRestart);
    resizeAgentConfRaw();
    const statusEl = document.getElementById("agentconf-status");
    if (statusEl) statusEl.textContent = "Loaded blank example template (not read from any worker)";
}
function autoLoadConfForSelectedRig() {
    pendingAgentConfFetchRig = null;
    const statusEl = document.getElementById("agentconf-status");
    const confType = selectedConfEditType;
    const confLabel = LOGS_TYPE_LABELS[confType] || confType;
    if (selectedRigs.size !== 1) {
        if (statusEl) statusEl.textContent = `Select exactly one worker to load/edit its ${confLabel}`;
        return;
    }
    const [rig] = selectedRigs;
    pendingAgentConfFetchRig = rig;
    if (statusEl) statusEl.textContent = `Loading current ${confLabel} from ${rig}…`;
    const catCmd = LOGS_COMMAND_BUILDERS[confType]?.() || `cat ${CONF_EDIT_TYPES[confType]?.path() ?? ""}`;
    sendCommandToSelectedRigs(catCmd).catch(err => {
        console.error(`Failed to request current ${confLabel}`, err);
        if (pendingAgentConfFetchRig === rig) pendingAgentConfFetchRig = null;
        if (statusEl) statusEl.textContent = `Failed to load current ${confLabel} from ${rig}`;
    });
}
function buildConfEditCommand() {
    // agentconf-raw already holds the full command (mkdir + tee heredoc-wrapped conf body +
    // optional restart line, via wrapConfEditCommand()) - send it exactly as shown, no rebuilding.
    return document.getElementById("agentconf-raw")?.value ?? "";
}
function sendItConfEdit() {
    const confType = selectedConfEditType;
    const confLabel = LOGS_TYPE_LABELS[confType] || confType;
    if (selectedRigs.size !== 1) {
        alert(`Select exactly one worker to write its ${confLabel}`);
        return;
    }
    const [rig] = selectedRigs;
    const command = buildConfEditCommand();
    // Snapshot what we're ABOUT to send now, rather than waiting for a reply - the Confirm
    // path hands off to the free-form Send Cmd modal, which has no structured success
    // callback back to this tab, so there's no reliable "it actually landed" moment to hook.
    // Optimistic, but this is a local backup convenience, not a correctness-critical value.
    // Only agent.conf gets a DB Backups snapshot - the other conf types have no BACKUP_TARGETS entry.
    if (CONF_EDIT_TYPES[confType]?.isAgent) {
        saveAgentConfSnapshot(rig, unwrapConfEditCommand(document.getElementById("agentconf-raw")?.value ?? ""));
    }
    const input = document.getElementById("cmd-input");
    if (document.getElementById("confirm-agentconf")?.checked) {
        if (input) input.value = command;
        openCmdModal();
    } else {
        sendCommandToSelectedRigs(command).catch(err => {
            console.error(`Failed to send ${confLabel}`, err);
            alert(`Failed to send ${confLabel}`);
        });
    }
}
function saveAgentConfSnapshot(rig, content) {
    if (!rig) return;
    fetch(`${API}/api/agent-conf/save`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ rig, content }),
    }).catch(err => {
        // Best-effort local backup convenience - a failure here shouldn't interrupt the
        // actual load/apply flow the user is doing, just log it.
        console.warn("Failed to save agent conf snapshot for DB Backups:", err);
    });
}
// Settings modal's Templates tab - lets templates.json (flightsheet/overclocking/watchdog/
// agentconf/flightsheet_derivation) be edited and saved from the dashboard itself instead of
// hand-editing the file on the server. Same auto-grow-textarea pattern as Agent Conf above.
function resizeTemplatesConfigRaw() {
    const el = document.getElementById("templates-config-raw");
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
}
function loadTemplatesConfigTab() {
    const rawEl = document.getElementById("templates-config-raw");
    const statusEl = document.getElementById("templates-config-status");
    if (statusEl) statusEl.textContent = "Loading templates.json from server…";
    fetch(`${API}/api/templates-config`)
        .then(res => {
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            return res.json();
        })
        .then(data => {
            if (rawEl) rawEl.value = data.content ?? "";
            resizeTemplatesConfigRaw();
            if (statusEl) statusEl.textContent = "Loaded from server";
        })
        .catch(err => {
            console.error("Failed to load templates.json", err);
            if (statusEl) statusEl.textContent = "Failed to load templates.json from server";
        });
}
function applyTemplatesConfig() {
    const rawEl = document.getElementById("templates-config-raw");
    const statusEl = document.getElementById("templates-config-status");
    const content = rawEl?.value ?? "";
    // Validate client-side first so a typo shows an immediate, specific error instead of a
    // round-trip to the server just to get the same JSON.parse failure back.
    try {
        JSON.parse(content);
    } catch (err) {
        if (statusEl) statusEl.textContent = `Not valid JSON: ${err.message}`;
        return;
    }
    // This isn't a per-rig write like the rest of the Conf tab - it overwrites templates.json on
    // the dashboard SERVER itself, which every open dashboard (and every rig's next-generated
    // Flightsheet/Overclock/Watchdog script) picks up. Worth a confirm, unlike a single worker's conf.
    if (!confirm("Save this content to templates.json on the server? This affects every dashboard and rig, not just this one.")) {
        if (statusEl) statusEl.textContent = "Save cancelled";
        return;
    }
    if (statusEl) statusEl.textContent = "Saving…";
    fetch(`${API}/api/templates-config/save`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content }),
    })
        .then(async res => {
            const data = await res.json().catch(() => ({}));
            if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
            return data;
        })
        .then(() => {
            if (statusEl) statusEl.textContent = "Saved - reloading into this dashboard...";
            // Re-run the same startup fetch/merge app.js uses on page load, so the new values
            // take effect immediately here too, not just for the next person to open the page.
            return loadTemplatesConfig();
        })
        .then(() => {
            if (statusEl) statusEl.textContent = "Saved and applied";
        })
        .catch(err => {
            console.error("Failed to save templates.json", err);
            if (statusEl) statusEl.textContent = `Failed to save: ${err.message}`;
        });
}
function populateStatusLogRigSelect() {
    const sel = document.getElementById("statuslog-rig-select");
    if (!sel) return;
    const prevValue = sel.value;
    const rigNames = Object.keys(rigsState || {})
        .filter(name => name !== "rigs")
        .sort();
    const totalCount = rigNames.reduce((sum, name) => sum + (statusLogCounts[name] || 0), 0);
    sel.innerHTML = "";
    const allOpt = document.createElement("option");
    allOpt.value = "";
    allOpt.textContent = totalCount > 0 ? `All Workers (${totalCount})` : "All Workers";
    sel.appendChild(allOpt);
    rigNames.forEach((name) => {
        const opt = document.createElement("option");
        opt.value = name;
        const count = statusLogCounts[name] || 0;
        opt.textContent = count > 0 ? `${name} (${count})` : name;
        sel.appendChild(opt);
    });
    if (selectedRigs && selectedRigs.size === 1) {
        const [only] = selectedRigs;
        if (rigNames.includes(only)) {
            sel.value = only;
            return;
        }
    }
    if (rigNames.includes(prevValue)) {
        sel.value = prevValue;
    }
}
// ===== Backups Tab =====
let selectedBackupFileIds = new Set();
// Same save-on-mouseup / separate-restore pattern as STATUSLOG_LIST_WIDTH_KEY above - these 3
// sizers were previously drag-only (in-memory, reset every reload); now persisted like every
// other module sizer/handle in the app.
const BACKUPS_HSIZER_WIDTH_KEY = "rigcontrol_backups_hsizer_width";
const BACKUPS_TOP_HSIZER_WIDTH_KEY = "rigcontrol_backups_top_hsizer_width";
const BACKUPS_VSIZER_HEIGHT_KEY = "rigcontrol_backups_vsizer_height";
function initBackupsHSizer() {
    const bar = document.getElementById("backups-hsizer");
    const listEl = document.getElementById("backups-preview-list");
    if (!bar || !listEl || bar.dataset.wired) return;
    bar.dataset.wired = "1";
    bar.addEventListener("mousedown", (e) => {
        e.preventDefault();
        const startX = e.clientX;
        const startWidth = listEl.getBoundingClientRect().width;
        bar.classList.add("dragging");
        document.body.style.userSelect = "none";
        function onMouseMove(moveEvent) {
            const deltaX = moveEvent.clientX - startX;
            const newWidth = Math.max(120, startWidth + deltaX);
            listEl.style.flex = "0 0 auto";
            listEl.style.width = `${newWidth}px`;
        }
        function onMouseUp() {
            bar.classList.remove("dragging");
            document.body.style.userSelect = "";
            document.removeEventListener("mousemove", onMouseMove);
            document.removeEventListener("mouseup", onMouseUp);
            if (listEl.style.width) localStorage.setItem(BACKUPS_HSIZER_WIDTH_KEY, listEl.style.width);
        }
        document.addEventListener("mousemove", onMouseMove);
        document.addEventListener("mouseup", onMouseUp);
    });
}
function initBackupsTopHSizer() {
    const bar = document.getElementById("backups-top-hsizer");
    const listPanel = document.getElementById("backups-list-panel") || document.querySelector("#backups-modal .backups-list-panel");
    if (!bar || !listPanel || bar.dataset.wired) return;
    bar.dataset.wired = "1";
    bar.addEventListener("mousedown", (e) => {
        e.preventDefault();
        const startX = e.clientX;
        const startWidth = listPanel.getBoundingClientRect().width;
        bar.classList.add("dragging");
        document.body.style.userSelect = "none";
        function onMouseMove(moveEvent) {
            const deltaX = moveEvent.clientX - startX;
            const newWidth = Math.max(120, startWidth + deltaX);
            listPanel.style.flex = "0 0 auto";
            listPanel.style.width = `${newWidth}px`;
        }
        function onMouseUp() {
            bar.classList.remove("dragging");
            document.body.style.userSelect = "";
            document.removeEventListener("mousemove", onMouseMove);
            document.removeEventListener("mouseup", onMouseUp);
            if (listPanel.style.width) localStorage.setItem(BACKUPS_TOP_HSIZER_WIDTH_KEY, listPanel.style.width);
        }
        document.addEventListener("mousemove", onMouseMove);
        document.addEventListener("mouseup", onMouseUp);
    });
}
function initBackupsVSizer() {
    const bar = document.getElementById("backups-vsizer");
    const previewPanel = document.getElementById("backups-preview-panel");
    if (!bar || !previewPanel || bar.dataset.wired) return;
    bar.dataset.wired = "1";
    bar.addEventListener("mousedown", (e) => {
        e.preventDefault();
        const startY = e.clientY;
        const startHeight = previewPanel.getBoundingClientRect().height;
        bar.classList.add("dragging");
        document.body.style.userSelect = "none";
        function onMouseMove(moveEvent) {
            const deltaY = startY - moveEvent.clientY;
            const newHeight = Math.max(80, startHeight + deltaY);
            previewPanel.style.flex = "0 0 auto";
            previewPanel.style.height = `${newHeight}px`;
        }
        function onMouseUp() {
            bar.classList.remove("dragging");
            document.body.style.userSelect = "";
            document.removeEventListener("mousemove", onMouseMove);
            document.removeEventListener("mouseup", onMouseUp);
            if (previewPanel.style.height) localStorage.setItem(BACKUPS_VSIZER_HEIGHT_KEY, previewPanel.style.height);
        }
        document.addEventListener("mousemove", onMouseMove);
        document.addEventListener("mouseup", onMouseUp);
    });
}
function restoreBackupsSizers() {
    const listEl = document.getElementById("backups-preview-list");
    const listPanel = document.getElementById("backups-list-panel") || document.querySelector("#backups-modal .backups-list-panel");
    const previewPanel = document.getElementById("backups-preview-panel");
    const savedListWidth = localStorage.getItem(BACKUPS_HSIZER_WIDTH_KEY);
    if (listEl && savedListWidth) {
        listEl.style.flex = "0 0 auto";
        listEl.style.width = savedListWidth;
    }
    const savedTopWidth = localStorage.getItem(BACKUPS_TOP_HSIZER_WIDTH_KEY);
    if (listPanel && savedTopWidth) {
        listPanel.style.flex = "0 0 auto";
        listPanel.style.width = savedTopWidth;
    }
    const savedPreviewHeight = localStorage.getItem(BACKUPS_VSIZER_HEIGHT_KEY);
    if (previewPanel && savedPreviewHeight) {
        previewPanel.style.flex = "0 0 auto";
        previewPanel.style.height = savedPreviewHeight;
    }
}
function openBackupsModal() {
    closeCmdModal();
    switchViewTab("backups");
    setBackupsStatus("");
    const previewEl = document.getElementById("backups-preview-textarea");
    if (previewEl) previewEl.value = "";
    initBackupsVSizer();
    initBackupsHSizer();
    initBackupsTopHSizer();
    restoreBackupsSizers();
    loadBackupFiles();
}
function setBackupsStatus(msg, isError) {
    const el = document.getElementById("backups-status");
    if (!el) return;
    el.textContent = msg || "";
    el.classList.toggle("error", !!isError);
    el.classList.toggle("ok", !isError && !!msg);
}
function formatBackupBytes(n) {
    if (n === null || n === undefined) return "-";
    if (n < 1024) return `${n} B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
    return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}
async function loadBackupFiles() {
    setBackupsStatus("Loading...");
    try {
        const res = await fetch(`${API}/api/backups/files`);
        if (!res.ok) {
            setBackupsStatus("Failed to load backup files", true);
            return;
        }
        const files = await res.json();
        renderBackupFilesList(files);
        setBackupsStatus("");
    } catch (e) {
        console.error("Error loading backup files:", e);
        setBackupsStatus("Failed to load backup files", true);
    }
}
function renderBackupFilesList(files) {
    const list = document.getElementById("backups-list");
    if (!list) return;
    list.innerHTML = "";
    files.forEach(file => {
        const row = document.createElement("div");
        row.className = "fs-item backups-item";
        row.dataset.id = file.id;
        const checkCell = document.createElement("label");
        checkCell.className = "backups-item-checkbox";
        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.checked = selectedBackupFileIds.has(file.id);
        checkbox.addEventListener("change", () => {
            if (checkbox.checked) selectedBackupFileIds.add(file.id);
            else selectedBackupFileIds.delete(file.id);
            updateBackupsSelectAllState();
        });
        checkCell.appendChild(checkbox);
        const nameCell = document.createElement("span");
        nameCell.textContent = file.label;
        nameCell.title = file.file_name;
        const countCell = document.createElement("span");
        countCell.textContent = file.item_count === null ? "?" : file.item_count;
        const sizeCell = document.createElement("span");
        sizeCell.textContent = file.exists ? formatBackupBytes(file.size_bytes) : "missing";
        row.append(checkCell, nameCell, countCell, sizeCell);
        list.appendChild(row);
    });
    updateBackupsSelectAllState();
}
function updateBackupsSelectAllState() {
    const selectAll = document.getElementById("backups-select-all");
    if (!selectAll) return;
    const rows = document.querySelectorAll("#backups-list .backups-item");
    const total = rows.length;
    const checkedCount = selectedBackupFileIds.size;
    selectAll.checked = total > 0 && checkedCount === total;
    selectAll.indeterminate = checkedCount > 0 && checkedCount < total;
}
function toggleAllBackupFiles(checked) {
    const rows = document.querySelectorAll("#backups-list .backups-item");
    rows.forEach(row => {
        const id = row.dataset.id;
        const checkbox = row.querySelector('input[type="checkbox"]');
        if (checkbox) checkbox.checked = checked;
        if (checked) selectedBackupFileIds.add(id);
        else selectedBackupFileIds.delete(id);
    });
    updateBackupsSelectAllState();
}
function getSelectedBackupFileIds() {
    return Array.from(selectedBackupFileIds);
}
function summarizeBackupResults(results) {
    return results.map(r => {
        if (r.ok) return `${r.id}: ${r.count} item(s)`;
        return `${r.id}: FAILED (${r.error || "unknown error"})`;
    }).join(" | ");
}
async function runBackupsBackup() {
    const ids = getSelectedBackupFileIds();
    if (ids.length === 0) {
        setBackupsStatus("Select at least one file first", true);
        return;
    }
    setBackupsStatus("Backing up to DynamoDB...");
    try {
        const res = await fetch(`${API}/api/backups/backup`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ files: ids }),
        });
        if (!res.ok) {
            const text = await res.text().catch(() => "");
            setBackupsStatus(`Backup failed - server returned ${res.status}${text ? `: ${text}` : ""}`, true);
            return;
        }
        const data = await res.json();
        const results = data.results || [];
        const allOk = results.length > 0 && results.every(r => r.ok);
        const prefix = allOk ? "Backup successful \u2014 " : "Backup finished with errors \u2014 ";
        const summary = prefix + summarizeBackupResults(results);
        await loadBackupFiles();
        setBackupsStatus(summary, !allOk);
    } catch (e) {
        console.error("Error backing up:", e);
        setBackupsStatus("Backup failed - see console", true);
    }
}
const BACKUP_SERVER_FILE_TARGET_IDS = new Set(["server_config", "templates"]);
async function runBackupsRestore() {
    const ids = getSelectedBackupFileIds();
    if (ids.length === 0) {
        setBackupsStatus("Select at least one file first", true);
        return;
    }
    const missingOnly = !!document.getElementById("backups-restore-missing-only")?.checked;
    const names = ids.join(", ");
    const serverFileIds = ids.filter(id => BACKUP_SERVER_FILE_TARGET_IDS.has(id));
    if (serverFileIds.length > 0) {
        const confirmed1 = confirm(
            `Restore server file(s): ${serverFileIds.join(", ")}?\n\nThis pulls the backed-up JSON from DynamoDB and writes it to the local file(s) the server reads its configuration from. Continue?`
        );
        if (!confirmed1) return;
        const confirmed2 = confirm(
            `\u26A0\uFE0F WARNING! This overwrites the live configuration the server is CURRENTLY RUNNING from.\n\nIf the restored data is bad, outdated, or incompatible, this CAN BREAK THE CURRENTLY RUNNING SERVER and may require manual recovery.\n\nOnly continue if you're sure. Continue anyway?`
        );
        if (!confirmed2) return;
    } else if (!missingOnly) {
        const confirmed = confirm(
            `This replaces the LOCAL data for: ${names}\n\nEverything currently in these local files will be overwritten with what's in DynamoDB. Check "Import missing entries only" first if you want to merge instead. Continue?`
        );
        if (!confirmed) return;
    }
    setBackupsStatus("Restoring from DynamoDB...");
    try {
        const res = await fetch(`${API}/api/backups/restore`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ files: ids, missing_only: missingOnly }),
        });
        if (!res.ok) {
            const text = await res.text().catch(() => "");
            setBackupsStatus(`Restore failed - server returned ${res.status}${text ? `: ${text}` : ""}`, true);
            return;
        }
        const data = await res.json();
        const results = data.results || [];
        const allOk = results.length > 0 && results.every(r => r.ok);
        const prefix = allOk ? "Restore successful \u2014 " : "Restore finished with errors \u2014 ";
        const summary = prefix + summarizeBackupResults(results);
        await loadBackupFiles();
        setBackupsStatus(summary, !allOk);
    } catch (e) {
        console.error("Error restoring:", e);
        setBackupsStatus("Restore failed - see console", true);
    }
}
function summarizeBackupDeleteResults(results) {
    return results.map(r => {
        if (r.ok) return `${r.id}: deleted`;
        return `${r.id}: FAILED (${r.error || "unknown error"})`;
    }).join(" | ");
}
async function runBackupsDelete() {
    const ids = getSelectedBackupFileIds();
    if (ids.length === 0) {
        setBackupsStatus("Select at least one file first", true);
        return;
    }
    const serverFileIds = ids.filter(id => BACKUP_SERVER_FILE_TARGET_IDS.has(id));
    if (serverFileIds.length > 0) {
        setBackupsStatus(
            `Deleting server file(s) is not allowed: ${serverFileIds.join(", ")}. Deselect them to delete the rest.`,
            true
        );
        return;
    }
    const source = getBackupsPreviewSource();
    const scopeLabel = source === "dynamo" ? "DynamoDB backup" : "LOCAL data";
    const names = ids.join(", ");
    const confirmed = confirm(
        `This PERMANENTLY deletes the ${scopeLabel} for: ${names}\n\nThis cannot be undone. Continue?`
    );
    if (!confirmed) return;
    setBackupsStatus(`Deleting ${scopeLabel}...`);
    try {
        const res = await fetch(`${API}/api/backups/delete`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ files: ids, source }),
        });
        if (!res.ok) {
            const text = await res.text().catch(() => "");
            setBackupsStatus(`Delete failed - server returned ${res.status}${text ? `: ${text}` : ""}`, true);
            return;
        }
        const data = await res.json();
        const results = data.results || [];
        const allOk = results.length > 0 && results.every(r => r.ok);
        const prefix = allOk ? "Delete successful \u2014 " : "Delete finished with errors \u2014 ";
        const summary = prefix + summarizeBackupDeleteResults(results);
        await loadBackupFiles();
        setBackupsStatus(summary, !allOk);
    } catch (e) {
        console.error("Error deleting:", e);
        setBackupsStatus("Delete failed - see console", true);
    }
}
let backupsPreviewItems = [];
function backupPreviewItemLabel(item) {
    const idKey = Object.keys(item).find(k => /Id$/.test(k) && k !== "GpuId");
    if (idKey && item.Key !== undefined) {
        const name = String(item[idKey]);
        if (/^RAW_/.test(item.Key)) {
            const preview = (item.Value || "").replace(/\s+/g, " ").trim().slice(0, 50);
            return `${name}${preview ? " \u00b7 " + preview : ""}`;
        }
        return `${name} \u00b7 ${item.Key}`;
    }
    if (item.title !== undefined) return `#${item.id} \u00b7 ${item.title}`;
    if (idKey) return String(item[idKey]);
    return JSON.stringify(item).slice(0, 60);
}
function getBackupsPreviewSource() {
    return document.getElementById("backups-preview-source-dynamo")?.checked ? "dynamo" : "local";
}
async function runBackupsPreview() {
    const ids = getSelectedBackupFileIds();
    const listEl = document.getElementById("backups-preview-list");
    const textareaEl = document.getElementById("backups-preview-textarea");
    if (!listEl || !textareaEl) return;
    if (ids.length === 0) {
        setBackupsStatus("Select at least one file first", true);
        return;
    }
    const source = getBackupsPreviewSource();
    setBackupsStatus(source === "dynamo" ? "Loading preview from DynamoDB..." : "Loading preview from local files...");
    try {
        backupsPreviewItems = [];
        listEl.innerHTML = "";
        textareaEl.value = "";
        let anyFailed = false;
        for (const id of ids) {
            const res = await fetch(`${API}/api/backups/preview/${encodeURIComponent(id)}?source=${source}`);
            if (!res.ok) {
                anyFailed = true;
                continue;
            }
            const data = await res.json();
            (data.items || []).forEach(item => {
                backupsPreviewItems.push({ fileLabel: data.label, item });
            });
        }
        backupsPreviewItems.forEach((entry) => {
            const row = document.createElement("div");
            row.className = "fs-item backups-preview-item";
            row.textContent = `${entry.fileLabel} \u00b7 ${backupPreviewItemLabel(entry.item)}`;
            row.addEventListener("click", () => {
                document.querySelectorAll("#backups-preview-list .fs-item.selected").forEach(e => e.classList.remove("selected"));
                row.classList.add("selected");
                textareaEl.value = JSON.stringify(entry.item, null, 2);
            });
            listEl.appendChild(row);
        });
        const sourceLabel = source === "dynamo" ? "DynamoDB" : "local";
        setBackupsStatus(
            `${backupsPreviewItems.length} item(s) from ${sourceLabel}${anyFailed ? " (one or more files failed to load)" : ""}`,
            anyFailed
        );
    } catch (e) {
        console.error("Error loading preview:", e);
        setBackupsStatus("Preview failed - see console", true);
    }
}
async function runBackupsCheckConfig() {
    setBackupsStatus("Checking config...");
    try {
        const res = await fetch(`${API}/api/backups/check-config`);
        const data = await res.json();
        setBackupsStatus(data.message, !data.ok);
    } catch (e) {
        console.error("Error checking config:", e);
        setBackupsStatus("Check config failed - see console", true);
    }
}
async function runBackupsTestConnection() {
    setBackupsStatus("Testing DynamoDB connection...");
    try {
        const res = await fetch(`${API}/api/backups/test-connection`, { method: "POST" });
        const data = await res.json();
        setBackupsStatus(data.message, !data.ok);
    } catch (e) {
        console.error("Error testing connection:", e);
        setBackupsStatus("Test connection failed - see console", true);
    }
}
async function importAccessKeysFile(file) {
    if (!file) return;
    setBackupsStatus(`Uploading ${file.name}...`);
    try {
        const formData = new FormData();
        formData.append("file", file);
        const res = await fetch(`${API}/api/backups/import-accesskeys`, {
            method: "POST",
            body: formData,
        });
        const data = await res.json();
        setBackupsStatus(data.message, !data.ok);
    } catch (e) {
        console.error("Error importing accessKeys.csv:", e);
        setBackupsStatus("Import failed - see console", true);
    }
}
function openStatusLogModal(autoSelectId) {
    closeCmdModal();
    statuslogPage = 0;
    populateStatusLogRigSelect();
    if (autoSelectId) {
        const sel = document.getElementById("statuslog-rig-select");
        if (sel) sel.value = "";
    }
    const statusEl = document.getElementById("statuslog-status");
    if (statusEl) statusEl.textContent = "";
    switchViewTab("statuslog");
    loadStatusLogList(autoSelectId);
    lastSyncedStatuslogRig = selectedRigs.size === 1 ? Array.from(selectedRigs)[0] : null;
    lastObservedStatuslogSelectionRig = lastSyncedStatuslogRig;
}
function openStatusLogForRig(rigName) {
    closeCmdModal();
    statuslogPage = 0;
    populateStatusLogRigSelect();
    switchViewTab("statuslog");
    const sel = document.getElementById("statuslog-rig-select");
    if (sel && Array.from(sel.options).some(opt => opt.value === rigName)) {
        sel.value = rigName;
    }
    lastSyncedStatuslogRig = rigName;
    // Snapshot the checkbox selection as-is (which may well be a DIFFERENT rig than rigName - that's
    // the whole point of clicking a specific rig's badge instead of relying on the checkbox) so
    // syncOpenModulesToSelection() treats this as already-observed and doesn't immediately stomp the
    // badge click back to whatever's checkbox-selected on its next tick.
    lastObservedStatuslogSelectionRig = selectedRigs.size === 1 ? Array.from(selectedRigs)[0] : null;
    const statusEl = document.getElementById("statuslog-status");
    if (statusEl) statusEl.textContent = "";
    loadStatusLogList();
}
// Mirrors get_status_log()'s default `limit: int = 200` in rigcontrol_dashboard_server.py - sent
// explicitly (rather than just relying on the server's own default) so this stays in lockstep even
// if that default is ever changed there without a matching edit here.
const STATUSLOG_QUERY_LIMIT = 200;
let statuslogPage = 0; // 0-indexed - reset to 0 whenever the rig/search filters change
async function loadStatusLogList(autoSelectId) {
    const list = document.getElementById("statuslog-list");
    const statusEl = document.getElementById("statuslog-status");
    const rigSel = document.getElementById("statuslog-rig-select");
    const rig = rigSel ? rigSel.value : "";
    const titleQ = document.getElementById("statuslog-search-title")?.value.trim() || "";
    const contentQ = document.getElementById("statuslog-search-content")?.value.trim() || "";
    const severity = document.getElementById("statuslog-severity-filter")?.value || "";
    if (statusEl) statusEl.textContent = "Loading...";
    try {
        const params = new URLSearchParams();
        params.set("limit", String(STATUSLOG_QUERY_LIMIT));
        params.set("offset", String(statuslogPage * STATUSLOG_QUERY_LIMIT));
        if (rig) params.set("rig", rig);
        if (titleQ) params.set("title_q", titleQ);
        if (contentQ) params.set("content_q", contentQ);
        if (severity) params.set("severity", severity);
        const res = await fetch(`${API}/api/status-log?${params.toString()}`);
        if (!res.ok) {
            if (statusEl) statusEl.textContent = "Failed to load";
            return;
        }
        // {items, total} - total is the TRUE count matching the current rig/search filters across
        // every page, not just how many came back on this one (see get_status_log() server-side).
        const data = await res.json();
        const items = data.items || [];
        const total = data.total ?? items.length;
        // Deleting entries (e.g. all of page 2) can leave statuslogPage pointing past the new
        // last page - that showed up as "list doesn't refresh" (an empty page render instead of
        // snapping back). Clamp and refetch the now-valid last page instead of rendering nothing.
        if (items.length === 0 && total > 0 && statuslogPage > 0) {
            statuslogPage = Math.max(0, Math.ceil(total / STATUSLOG_QUERY_LIMIT) - 1);
            return loadStatusLogList(autoSelectId);
        }
        renderStatusLogList(items);
        updateStatuslogPageDisplay(items.length, total);
        if (autoSelectId != null) {
            selectStatusLogEntry(autoSelectId);
        }
    } catch (e) {
        console.error("Error loading status log:", e);
        if (statusEl) statusEl.textContent = "Failed to load";
    }
}
// Single combined status text (same span/style as before "N entries" always used) - now also
// covers the Prev/Next page range instead of a separate page-count element.
function updateStatuslogPageDisplay(shownCount, total) {
    const statusEl = document.getElementById("statuslog-status");
    const prevBtn = document.getElementById("btn-statuslog-prev-page");
    const nextBtn = document.getElementById("btn-statuslog-next-page");
    const totalPages = Math.max(1, Math.ceil(total / STATUSLOG_QUERY_LIMIT));
    const pageNum = statuslogPage + 1;
    if (statusEl) {
        const startIdx = total === 0 ? 0 : statuslogPage * STATUSLOG_QUERY_LIMIT + 1;
        const endIdx = statuslogPage * STATUSLOG_QUERY_LIMIT + shownCount;
        statusEl.textContent = totalPages > 1
            ? `Page ${pageNum} of ${totalPages} · ${startIdx}-${endIdx} of ${total} entries`
            : `${total} entries`;
    }
    if (prevBtn) prevBtn.disabled = statuslogPage <= 0;
    if (nextBtn) nextBtn.disabled = pageNum >= totalPages;
}
function renderStatusLogList(items) {
    const list = document.getElementById("statuslog-list");
    if (!list) return;
    list.innerHTML = "";
    selectedStatusLogIds.clear();
    for (const item of items) {
        const row = document.createElement("div");
        row.className = "fs-item";
        row.dataset.id = item.id;
        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.className = "statuslog-item-checkbox";
        checkbox.addEventListener("click", (ev) => ev.stopPropagation());
        checkbox.addEventListener("change", () => {
            if (checkbox.checked) selectedStatusLogIds.add(String(item.id));
            else selectedStatusLogIds.delete(String(item.id));
            updateStatuslogSelectAllState();
        });
        const textWrap = document.createElement("div");
        textWrap.className = "statuslog-item-text";
        const titleEl = document.createElement("div");
        titleEl.className = "statuslog-item-title";
        titleEl.textContent = item.title || `${item.rig || "unknown"}: ${item.algo || ""}`;
        const sevMatch = /\[(GOOD|WARN|IMPORTANT|CRITICAL)\]/.exec(titleEl.textContent);
        if (sevMatch) titleEl.dataset.severity = sevMatch[1].toLowerCase();
        const timeEl = document.createElement("div");
        timeEl.className = "statuslog-item-time";
        timeEl.textContent = item.created_at ? statsTimestampToLocalLabel(item.created_at) : "";
        textWrap.appendChild(titleEl);
        textWrap.appendChild(timeEl);
        row.appendChild(checkbox);
        row.appendChild(textWrap);
        row.addEventListener("click", () => selectStatusLogEntry(item.id));
        list.appendChild(row);
    }
    updateStatuslogSelectAllState();
}
function updateStatuslogSelectAllState() {
    const selectAll = document.getElementById("statuslog-select-all");
    if (!selectAll) return;
    const rows = document.querySelectorAll("#statuslog-list .fs-item");
    const total = rows.length;
    const checkedCount = selectedStatusLogIds.size;
    selectAll.checked = total > 0 && checkedCount === total;
    selectAll.indeterminate = checkedCount > 0 && checkedCount < total;
}
function toggleAllStatusLogEntries(checked) {
    const rows = document.querySelectorAll("#statuslog-list .fs-item");
    rows.forEach(row => {
        const id = row.dataset.id;
        const checkbox = row.querySelector('input[type="checkbox"]');
        if (checkbox) checkbox.checked = checked;
        if (checked) selectedStatusLogIds.add(String(id));
        else selectedStatusLogIds.delete(String(id));
    });
    updateStatuslogSelectAllState();
}
async function deleteStatusLogEntriesByIds(ids, statusEl) {
    if (ids.length === 0) {
        if (statusEl) statusEl.textContent = "No entries selected";
        return;
    }
    const confirmed = confirm(
        `Delete ${ids.length} status log ${ids.length === 1 ? "entry" : "entries"}? This cannot be undone.`
    );
    if (!confirmed) return;
    if (statusEl) statusEl.textContent = "Deleting...";
    try {
        const res = await fetch(`${API}/api/status-log?ids=${ids.join(",")}`, { method: "DELETE" });
        if (!res.ok) {
            if (statusEl) statusEl.textContent = "Failed to delete";
            return;
        }
        const details = document.getElementById("statuslog-details");
        if (details) details.value = "";
        await loadStatusLogList();
        fetchStatusLogCounts();
        fetchStatusLogSeverity();
    } catch (e) {
        console.error("Error deleting status log entries:", e);
        if (statusEl) statusEl.textContent = "Failed to delete";
    }
}
async function clearVisibleStatusLogEntries() {
    const statusEl = document.getElementById("statuslog-status");
    const ids = [...document.querySelectorAll("#statuslog-list .fs-item")]
        .map(row => row.dataset.id)
        .filter(Boolean);
    await deleteStatusLogEntriesByIds(ids, statusEl);
}
async function deleteSelectedStatusLogEntries() {
    const statusEl = document.getElementById("statuslog-status");
    const ids = [...selectedStatusLogIds];
    await deleteStatusLogEntriesByIds(ids, statusEl);
}
function localizeDetailsTimeLine(text) {
    if (!text) return text;
    return text.replace(
        /Time: (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) UTC/,
        (match, ts) => `Time: ${statsTimestampToLocalLabel(ts)}`
    );
}
async function selectStatusLogEntry(id) {
    document
        .querySelectorAll("#statuslog-list .fs-item.selected")
        .forEach(e => e.classList.remove("selected"));
    const row = document.querySelector(`#statuslog-list .fs-item[data-id="${id}"]`);
    if (row) {
        row.classList.add("selected");
        row.scrollIntoView({ block: "nearest" });
    }
    const details = document.getElementById("statuslog-details");
    if (details) details.value = "Loading...";
    try {
        const res = await fetch(`${API}/api/status-log/${encodeURIComponent(id)}`);
        if (!res.ok) {
            if (details) details.value = "Failed to load entry details.";
            return;
        }
        const entry = await res.json();
        if (details) details.value = localizeDetailsTimeLine(entry.details) || "(no details)";
    } catch (e) {
        console.error("Error loading status log entry:", e);
        if (details) details.value = "Failed to load entry details.";
    }
}
function updateStatsStartDateFromDays() {
    const daysInput = document.getElementById("stats-days-input");
    const startInput = document.getElementById("stats-start-date");
    if (!daysInput || !startInput) return;
    const days = Math.max(1, parseInt(daysInput.value, 10) || 1);
    const start = new Date();
    start.setDate(start.getDate() - days);
    startInput.value = formatLocalDateForInput(start);
}
function openStatsModal() {
    closeCmdModal();
    switchViewTab("stats");
    populateStatsRigSelect();
    updateStatsStartDateFromDays();
    loadStatsForSelectedRig();
    lastSyncedStatsRig = selectedRigs.size === 1 ? Array.from(selectedRigs)[0] : null;
}
function populateStatsRigSelect() {
    const sel = document.getElementById("stats-rig-select");
    if (!sel) return;
    const prevValue = sel.value;
    const rigNames = Object.keys(rigsState || {})
        .filter(name => name !== "rigs")
        .sort();
    sel.innerHTML = "";
    rigNames.forEach((name) => {
        const opt = document.createElement("option");
        opt.value = name;
        opt.textContent = name;
        sel.appendChild(opt);
    });
    if (selectedRigs && selectedRigs.size === 1) {
        const [only] = selectedRigs;
        if (rigNames.includes(only)) {
            sel.value = only;
            return;
        }
    }
    if (rigNames.includes(prevValue)) {
        sel.value = prevValue;
    }
}
function clearStatsProgressStatus() {
    const statusEl = document.getElementById("stats-status");
    if (statusEl) statusEl.textContent = "";
}
function requestStatsHistory(rig, days, limit, startDateIso) {
    return new Promise((resolve, reject) => {
        const id = `stats-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
        const timeoutId = setTimeout(() => {
            delete pendingStatsRequests[id];
            clearStatsProgressStatus();
            reject(new Error("Timed out waiting for worker response"));
        }, 20000);
        pendingStatsRequests[id] = { resolve, reject, timeoutId };
        const body = { rig, days, limit, id };
        if (startDateIso) body.start_date = startDateIso;
        fetch(`${API}/api/stats/request`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(body)
        }).catch((err) => {
            clearTimeout(timeoutId);
            delete pendingStatsRequests[id];
            clearStatsProgressStatus();
            reject(err);
        });
    });
}
function handleStatsResponse(resp) {
    const pending = pendingStatsRequests[resp.id];
    if (!pending) return;
    clearTimeout(pending.timeoutId);
    delete pendingStatsRequests[resp.id];
    clearStatsProgressStatus();
    if (resp.error) {
        pending.reject(new Error(resp.error));
    } else {
        pending.resolve(resp);
    }
}
function handleStatsResponseProgress(progress) {
    if (!progress || !pendingStatsRequests[progress.id]) return;
    const statusEl = document.getElementById("stats-status");
    if (statusEl) {
        statusEl.textContent = `Receiving stats ${progress.chunk_index + 1} of ${progress.chunk_count}...`;
    }
}
async function loadStatsForSelectedRig() {
    const sel = document.getElementById("stats-rig-select");
    const rig = sel ? sel.value : null;
    const daysInput = document.getElementById("stats-days-input");
    const days = Math.max(1, parseInt(daysInput ? daysInput.value : "1", 10) || 1);
    const startDateInput = document.getElementById("stats-start-date");
    const startDateStr = startDateInput ? startDateInput.value : "";
    const statusEl = document.getElementById("stats-status");
    if (!rig) {
        if (statusEl) statusEl.textContent = "No worker selected";
        return;
    }
    if (statusEl) statusEl.textContent = "Loading...";
    const startDateIso = startDateStr ? startDateInputToIso(startDateStr) : null;
    try {
        const resp = await requestStatsHistory(rig, days, null, startDateIso);
        _lastStatsResp = resp;
        renderStatsCharts(resp);
        const count = resp.count ?? (resp.entries ? resp.entries.length : 0);
        if (statusEl) {
            const rangeLabel = startDateStr ? formatStatsRangeLabel(startDateStr, days) : `last ${resp.days} day${resp.days === 1 ? "" : "s"}`;
            statusEl.textContent = `${count} entries (${rangeLabel})`;
        }
    } catch (err) {
        console.error("Stats history request failed", err);
        if (statusEl) statusEl.textContent = "Failed to load: " + err.message;
        clearStatsProgressStatus();
    }
}
function buildLabelsAndSeries(entries, extractFn) {
    const labels = entries.map((e) => statsTimestampToLocalLabel(e.timestamp));
    const seriesMap = {};
    entries.forEach((entry) => {
        const values = extractFn(entry.data) || {};
        Object.keys(values).forEach((name) => {
            if (!seriesMap[name]) seriesMap[name] = [];
        });
    });
    const allNames = Object.keys(seriesMap);
    entries.forEach((entry, i) => {
        const values = extractFn(entry.data) || {};
        allNames.forEach((name) => {
            seriesMap[name][i] = (name in values) ? values[name] : null;
        });
    });
    return { labels, seriesMap };
}
// opts (all optional): axisForName(name) -> "y"|"y1" to overlay a series on a second axis; y1Label for its title; dashForName(name) -> borderDash array.
function renderStatsChart(canvasId, labels, seriesMap, yLabel, colorForName, opts) {
    const canvas = document.getElementById(canvasId);
    if (!canvas || typeof Chart === "undefined") return;
    if (statsCharts[canvasId]) {
        statsCharts[canvasId].destroy();
        delete statsCharts[canvasId];
    }
    const names = Object.keys(seriesMap);
    if (names.length === 0) return;
    const { axisForName, y1Label, dashForName } = opts || {};
    const datasets = names.map((name, i) => ({
        label: name,
        data: seriesMap[name],
        borderColor: colorForName ? colorForName(name) : STATS_CHART_COLORS[i % STATS_CHART_COLORS.length],
        backgroundColor: "transparent",
        borderWidth: 2,
        borderDash: dashForName ? dashForName(name) : undefined,
        pointRadius: 0,
        tension: 0.15,
        spanGaps: true,
        yAxisID: axisForName ? axisForName(name) : "y"
    }));
    const scales = {
        x: {
            afterBuildTicks: (axis) => {
                if (axis.ticks.length > 2) {
                    axis.ticks = [axis.ticks[0], axis.ticks[axis.ticks.length - 1]];
                }
            },
            ticks: { maxRotation: 0, color: "#9aa4b2" },
            grid: { color: "rgba(255,255,255,0.06)" }
        },
        y: {
            title: { display: !!yLabel, text: yLabel || "", color: "#9aa4b2" },
            ticks: { color: "#9aa4b2" },
            grid: { color: "rgba(255,255,255,0.06)" }
        }
    };
    if (axisForName && names.some((name) => axisForName(name) === "y1")) {
        scales.y1 = {
            position: "right",
            title: { display: !!y1Label, text: y1Label || "", color: "#9aa4b2" },
            ticks: { color: "#9aa4b2" },
            grid: { drawOnChartArea: false }
        };
    }
    statsCharts[canvasId] = new Chart(canvas.getContext("2d"), {
        type: "line",
        data: { labels, datasets },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            animation: false,
            interaction: { mode: "nearest", axis: "x", intersect: false },
            scales,
            plugins: {
                legend: { display: names.length > 1, labels: { color: "#c9d1d9", boxWidth: 12 } }
            }
        }
    });
}
function mostRecentStatsAlgoName(entries) {
    for (let i = (entries || []).length - 1; i >= 0; i--) {
        const algos = DataHelper.getAllAlgorithms(entries[i].data) || [];
        const name = algos.map((a) => DataHelper.getAlgorithmName(a)).find((n) => n && n !== "--");
        if (name) return name;
    }
    return "all";
}
function populateStatsAlgoSelect(entries) {
    const sel = document.getElementById("stats-algo-select");
    if (!sel) return;
    const prevValue = sel.value || "all";
    const userTouched = sel.dataset.userSet === "1";
    const algoNames = new Set();
    (entries || []).forEach((entry) => {
        (DataHelper.getAllAlgorithms(entry.data) || []).forEach((algo) => {
            const name = DataHelper.getAlgorithmName(algo);
            if (name && name !== "--") algoNames.add(name);
        });
    });
    const sortedNames = Array.from(algoNames).sort();
    sel.innerHTML = "";
    const allOpt = document.createElement("option");
    allOpt.value = "all";
    allOpt.textContent = "-All-";
    sel.appendChild(allOpt);
    sortedNames.forEach((name) => {
        const opt = document.createElement("option");
        opt.value = name;
        opt.textContent = name;
        sel.appendChild(opt);
    });
    if (userTouched) {
        // Respect whatever the person explicitly picked (including "-All-"), as long as it's
        // still a valid option - only fall back if their choice disappeared from the list.
        sel.value = (prevValue === "all" || sortedNames.includes(prevValue)) ? prevValue : "all";
    } else {
        // Never manually changed yet - default to the most recently active algorithm instead
        // of "-All-", so the chart opens already focused on what's currently mining.
        const mostRecent = mostRecentStatsAlgoName(entries);
        sel.value = sortedNames.includes(mostRecent) ? mostRecent : "all";
    }
}
function renderStatsCharts(resp) {
    const entries = resp.entries || [];
    populateStatsAlgoSelect(entries);
    const algoFilter = document.getElementById("stats-algo-select")?.value || "all";
    const gpuWatts = buildLabelsAndSeries(entries, (d) => {
        const out = {};
        (d.gpus || []).forEach((g) => { out[`GPU${g.index}`] = g.power_watts; });
        return out;
    });
    renderStatsChart("stats-chart-gpu-watts", gpuWatts.labels, gpuWatts.seriesMap, "Watts");
    const gpuTemp = buildLabelsAndSeries(entries, (d) => {
        const out = {};
        (d.gpus || []).forEach((g) => {
            out[`GPU${g.index} Temp`] = g.temp;
            out[`GPU${g.index} Fan`] = g.fan_percent ?? g.fan_speed;
        });
        return out;
    });
    const STATS_FAN_COLOR = "#f0a860";
    renderStatsChart("stats-chart-gpu-temp", gpuTemp.labels, gpuTemp.seriesMap, "°C", (name) => {
        if (name.endsWith(" Fan")) return STATS_FAN_COLOR;
        const idx = parseInt(name.replace("GPU", "").replace(" Temp", ""), 10) || 0;
        return STATS_CHART_COLORS[idx % STATS_CHART_COLORS.length];
    }, {
        axisForName: (name) => (name.endsWith(" Fan") ? "y1" : "y"),
        y1Label: "Fan %",
        dashForName: (name) => (name.endsWith(" Fan") ? [4, 3] : undefined)
    });
    const gpuUtil = buildLabelsAndSeries(entries, (d) => {
        const out = {};
        (d.gpus || []).forEach((g) => { out[`GPU${g.index}`] = g.util; });
        return out;
    });
    renderStatsChart("stats-chart-gpu-util", gpuUtil.labels, gpuUtil.seriesMap, "%");
    const gpuMemTemp = buildLabelsAndSeries(entries, (d) => {
        const out = {};
        (d.gpus || []).forEach((g) => {
            const memTemp = DataHelper.getGpuMemTemp(g);
            if (memTemp !== null && memTemp !== undefined) out[`GPU${g.index}`] = memTemp;
        });
        return out;
    });
    renderStatsChart("stats-chart-gpu-mem-temp", gpuMemTemp.labels, gpuMemTemp.seriesMap, "°C", (name) => {
        const idx = parseInt(name.replace("GPU", ""), 10) || 0;
        return STATS_CHART_COLORS[idx % STATS_CHART_COLORS.length];
    });
    const gpuVram = buildLabelsAndSeries(entries, (d) => {
        const out = {};
        (d.gpus || []).forEach((g) => {
            out[`GPU${g.index}`] = typeof g.vram_used === "number" ? (g.vram_used / 1024) : undefined;
        });
        return out;
    });
    renderStatsChart("stats-chart-gpu-vram", gpuVram.labels, gpuVram.seriesMap, "GB");
    const gpuCoreClock = buildLabelsAndSeries(entries, (d) => {
        const out = {};
        (d.gpus || []).forEach((g) => { out[`GPU${g.index}`] = g.sm_clock ?? g.core_clock; });
        return out;
    });
    renderStatsChart("stats-chart-gpu-core-clock", gpuCoreClock.labels, gpuCoreClock.seriesMap, "MHz");
    const gpuMemClock = buildLabelsAndSeries(entries, (d) => {
        const out = {};
        (d.gpus || []).forEach((g) => { out[`GPU${g.index}`] = g.mem_clock ?? g.memory_clock; });
        return out;
    });
    renderStatsChart("stats-chart-gpu-mem-clock", gpuMemClock.labels, gpuMemClock.seriesMap, "MHz");
    const cpuTemp = buildLabelsAndSeries(entries, (d) => ({ "CPU Temp": d.cpu_temp }));
    renderStatsChart("stats-chart-cpu-temp", cpuTemp.labels, cpuTemp.seriesMap, "°C");
    const cpuUsage = buildLabelsAndSeries(entries, (d) => ({ "CPU Usage": d.cpu_usage }));
    renderStatsChart("stats-chart-cpu-util", cpuUsage.labels, cpuUsage.seriesMap, "%");
    const ramUsage = buildLabelsAndSeries(entries, (d) => {
        const mem = d.memory || {};
        return { "RAM Usage": typeof mem.used_mb === "number" ? (mem.used_mb / 1024) : undefined };
    });
    renderStatsChart("stats-chart-ram", ramUsage.labels, ramUsage.seriesMap, "GB");
    const load = buildLabelsAndSeries(entries, (d) => {
        const l = d.load || {};
        return { "1m": l["1m"], "5m": l["5m"], "15m": l["15m"] };
    });
    renderStatsChart("stats-chart-load", load.labels, load.seriesMap, "Load");
    let maxHashrateHs = 0;
    entries.forEach((entry) => {
        (DataHelper.getAllAlgorithms(entry.data) || []).forEach((algo) => {
            if (algoFilter !== "all" && DataHelper.getAlgorithmName(algo) !== algoFilter) return;
            const hr = DataHelper.getTotalHashrateHS(algo);
            if (hr > maxHashrateHs) maxHashrateHs = hr;
        });
    });
    const hashrateUnitOverride = document.getElementById("stats-hashrate-unit-select")?.value || "auto";
    const hashrateUnit = hashrateUnitOverride !== "auto" && HASHRATE_UNIT_MULTIPLIERS[hashrateUnitOverride]
        ? { unit: hashrateUnitOverride === "KH/s" ? "kH/s" : hashrateUnitOverride, divisor: HASHRATE_UNIT_MULTIPLIERS[hashrateUnitOverride] }
        : pickHashrateUnitForChart(maxHashrateHs);
    const hashrate = buildLabelsAndSeries(entries, (d) => {
        const out = {};
        (DataHelper.getAllAlgorithms(d) || []).forEach((algo) => {
            const algoName = DataHelper.getAlgorithmName(algo);
            if (algoFilter !== "all" && algoName !== algoFilter) return;
            const hr = DataHelper.getTotalHashrateHS(algo);
            if (hr > 0) {
                out[algoName] = (out[algoName] || 0) + hr / hashrateUnit.divisor;
            }
        });
        return out;
    });
    renderStatsChart("stats-chart-hashrate", hashrate.labels, hashrate.seriesMap, hashrateUnit.unit, stableColorForName);
}
function openUnlockModal() {
    if (!viewOnlyMode) return;
    document.getElementById("unlock-modal").classList.remove("hidden");
    document.getElementById("unlock-code-row").classList.add("hidden");
    setUnlockStatus("", "");
    document.getElementById("unlock-code-input").value = "";
    document.getElementById("unlock-email-input").value = "";
}
function closeUnlockModal() {
    document.getElementById("unlock-modal").classList.add("hidden");
}
function setUnlockStatus(text, kind) {
    const el = document.getElementById("unlock-status");
    if (!el) return;
    el.textContent = text;
    el.className = "unlock-status" + (kind ? ` ${kind}` : "");
}
async function requestUnlockCode() {
    const emailInput = document.getElementById("unlock-email-input");
    const email = (emailInput?.value || "").trim();
    if (!email) {
        setUnlockStatus("Enter the configured email address first.", "error");
        emailInput?.focus();
        return;
    }
    const btn = document.getElementById("btn-unlock-request-code");
    if (btn) btn.disabled = true;
    setUnlockStatus("Sending code...", "");
    try {
        const res = await fetch(`${API}/api/view-only/request-code`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ email }),
        });
        const data = await res.json().catch(() => ({}));
        if (res.ok && data.status === "sent") {
            setUnlockStatus("Code sent - check your email.", "ok");
            document.getElementById("unlock-code-row").classList.remove("hidden");
            document.getElementById("unlock-code-input").focus();
        } else if (data.status === "already_unlocked") {
            setUnlockStatus("Already unlocked.", "ok");
        } else {
            setUnlockStatus(data.detail || "Failed to send code.", "error");
        }
    } catch (e) {
        setUnlockStatus("Network error sending code.", "error");
    } finally {
        if (btn) btn.disabled = false;
    }
}
async function submitUnlockCode() {
    const input = document.getElementById("unlock-code-input");
    const code = (input?.value || "").trim();
    if (!code) {
        setUnlockStatus("Enter the code from the email first.", "error");
        return;
    }
    const btn = document.getElementById("btn-unlock-submit-code");
    if (btn) btn.disabled = true;
    setUnlockStatus("Checking code...", "");
    try {
        const res = await fetch(`${API}/api/view-only/verify-code`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ code }),
        });
        const data = await res.json().catch(() => ({}));
        if (res.ok && data.status === "unlocked") {
            viewOnlyMode = false;
            applyViewOnlyMode();
            setUnlockStatus("Unlocked! Full control restored on this browser.", "ok");
            setTimeout(closeUnlockModal, 1200);
        } else {
            setUnlockStatus(data.detail || "Invalid or expired code.", "error");
        }
    } catch (e) {
        setUnlockStatus("Network error verifying code.", "error");
    } finally {
        if (btn) btn.disabled = false;
    }
}
async function logoutRemoteUnlock() {
    if (!confirm("Log out of remote unlock and return to view-only mode?")) {
        return;
    }
    const btn = document.getElementById("btn-remote-logout");
    if (btn) btn.disabled = true;
    try {
        await fetch(`${API}/api/view-only/logout`, { method: "POST" });
    } catch (e) {
        console.warn("[ViewOnly] Logout request failed:", e);
    } finally {
        viewOnlyMode = true;
        applyViewOnlyMode();
        if (btn) btn.disabled = false;
    }
}
console.log("Location pathname:", window.location.pathname);
console.log("Calculated BASE_PATH before config:", BASE_PATH);
function initModalCollapseToggle(modalId, buttonId) {
    const btn = document.getElementById(buttonId);
    const modal = document.getElementById(modalId);
    if (!btn || !modal || btn.dataset.wired) return;
    btn.dataset.wired = "1";
    btn.addEventListener("click", () => {
        const collapsed = modal.classList.toggle("row-collapsed");
        btn.classList.toggle("active", collapsed);
        btn.textContent = collapsed ? "Expand" : "Collapse";
    });
}
function resetModalCollapseState(modalId, buttonId) {
    const modal = document.getElementById(modalId);
    const btn = document.getElementById(buttonId);
    modal?.classList.remove("row-collapsed");
    btn?.classList.remove("active");
    if (btn) btn.textContent = "Collapse";
}
let statusLogCounts = {};
// Per-rig {critical, warn} flags - not from a DB column, derived server-side from the same
// "[CRITICAL]"/"[WARN]" title tag the client already parses in renderStatusLogList(). Drives the
// worker status log badge color (critical beats warn if a worker has both - see updateStatusLogBadgeClass()).
let statusLogSeverityByRig = {};
function refreshStatusLogRigSelectIfOpen() {
    if (!document.getElementById("statuslog-modal")?.classList.contains("hidden")) {
        populateStatusLogRigSelect();
    }
}
async function fetchStatusLogCounts() {
    try {
        const res = await fetch(`${API}/api/status-log-counts`);
        if (!res.ok) return;
        statusLogCounts = await res.json();
        queueRender();
        refreshStatusLogRigSelectIfOpen();
    } catch (e) {
        console.error("Error fetching status log counts:", e);
    }
}
async function fetchStatusLogSeverity() {
    try {
        const res = await fetch(`${API}/api/status-log-severity`);
        if (!res.ok) return;
        statusLogSeverityByRig = await res.json();
        queueRender();
    } catch (e) {
        console.error("Error fetching status log severity:", e);
    }
}
// Applies the right modifier class to an already-built badge element - shared by the main worker
// list render and the live websocket update path so both stay in sync with the same priority
// rule (critical > warn > plain).
function updateStatusLogBadgeClass(badgeEl, rigName) {
    const sev = statusLogSeverityByRig[rigName];
    badgeEl.classList.toggle("has-critical", !!sev?.critical);
    badgeEl.classList.toggle("has-warn", !sev?.critical && !!sev?.warn);
}
let lastSyncedStatsRig = null;
let lastSyncedStatuslogRig = null;
// Tracks the checkbox-selected rig we've already reacted to, separately from
// lastSyncedStatuslogRig (which tracks what rig the status log is currently showing). These used to
// be the same variable, which broke openStatusLogForRig()'s circle-badge click: clicking a badge for
// rig B while some other rig A was checkbox-selected set lastSyncedStatuslogRig to B, so the very
// next syncOpenModulesToSelection() tick saw "checkbox-selected rig A !== lastSyncedStatuslogRig B"
// and treated that as a fresh selection change, auto-syncing the dropdown right back to A - silently
// overriding the badge click. Keeping a separate baseline that only openStatusLogForRig()/
// openStatusLogModal() are allowed to move lets this function tell "the checkbox selection itself
// changed" apart from "the displayed rig changed for some other reason".
let lastObservedStatuslogSelectionRig = null;
let lastSyncedWdConfigRig = null;
let lastSyncedAgentConfRig = null;
function syncOpenModulesToSelection() {
    const count = selectedRigs.size;
    const countLabel = count === 1 ? "worker" : "workers";
    const fsModal = document.getElementById("fs-modal");
    if (fsModal && !fsModal.classList.contains("hidden")) {
        const el = document.getElementById("fs-target-count");
        const label = document.getElementById("fs-target-label");
        if (el) el.textContent = count;
        if (label) label.textContent = countLabel;
    }
    const ocModal = document.getElementById("oc-modal");
    if (ocModal && !ocModal.classList.contains("hidden")) {
        const el = document.getElementById("oc-target-count");
        const label = document.getElementById("oc-target-label");
        if (el) el.textContent = count;
        if (label) label.textContent = countLabel;
    }
    const wdModal = document.getElementById("wdconfig-modal");
    if (wdModal && !wdModal.classList.contains("hidden")) {
        const el = document.getElementById("wdconfig-target-count");
        const label = document.getElementById("wdconfig-target-label");
        if (el) el.textContent = count;
        if (label) label.textContent = countLabel;
        if (count === 1) {
            const [onlyWd] = selectedRigs;
            if (onlyWd !== lastSyncedWdConfigRig) {
                lastSyncedWdConfigRig = onlyWd;
                autoLoadWdConfigForSelectedRig();
            }
        } else {
            lastSyncedWdConfigRig = null;
        }
    }
    const settingsModal = document.getElementById("refresh-modal");
    const agentConfPanel = settingsModal?.querySelector('.settings-main-tab-panel[data-tab-panel="agentconf"]');
    if (settingsModal && !settingsModal.classList.contains("hidden") &&
        agentConfPanel && !agentConfPanel.classList.contains("hidden")) {
        if (count === 1) {
            const [onlyAc] = selectedRigs;
            if (onlyAc !== lastSyncedAgentConfRig) {
                lastSyncedAgentConfRig = onlyAc;
                autoLoadConfForSelectedRig();
            }
        } else {
            lastSyncedAgentConfRig = null;
            const statusEl = document.getElementById("agentconf-status");
            const confLabel = LOGS_TYPE_LABELS[selectedConfEditType] || selectedConfEditType;
            if (statusEl) statusEl.textContent = `Select exactly one worker to load/edit its ${confLabel}`;
        }
    }
    const statsModal = document.getElementById("stats-modal");
    if (statsModal && !statsModal.classList.contains("hidden") && count === 1) {
        const [only] = selectedRigs;
        if (only !== lastSyncedStatsRig) {
            lastSyncedStatsRig = only;
            const sel = document.getElementById("stats-rig-select");
            if (sel && Array.from(sel.options).some(opt => opt.value === only)) {
                sel.value = only;
                loadStatsForSelectedRig();
            }
        }
    }
    const statuslogModal = document.getElementById("statuslog-modal");
    if (statuslogModal && !statuslogModal.classList.contains("hidden") && count === 1) {
        const [onlyLog] = selectedRigs;
        // Only auto-sync when the checkbox selection has itself actually changed since we last
        // looked - NOT just whenever it happens to differ from whatever rig is currently displayed
        // (lastSyncedStatuslogRig), which would also be true right after a circle-badge click on a
        // different rig and would incorrectly stomp it back to the checkbox selection.
        if (onlyLog !== lastObservedStatuslogSelectionRig) {
            lastObservedStatuslogSelectionRig = onlyLog;
            if (onlyLog !== lastSyncedStatuslogRig) {
                lastSyncedStatuslogRig = onlyLog;
                const sel = document.getElementById("statuslog-rig-select");
                if (sel && Array.from(sel.options).some(opt => opt.value === onlyLog)) {
                    sel.value = onlyLog;
                    loadStatusLogList();
                }
            }
        }
    }
    if (isLogsModuleVisible() && count === 1) {
        const [onlyLogs] = selectedRigs;
        if (onlyLogs !== lastSyncedLogsRig) {
            lastSyncedLogsRig = onlyLogs;
            const sel = document.getElementById("logs-rig-select");
            if (sel && Array.from(sel.options).some(opt => opt.value === onlyLogs)) {
                sel.value = onlyLogs;
                fetchLogs();
            }
        }
    }
}
document.addEventListener("DOMContentLoaded", async () => {
    setupHeaderBarHeightSync();
    setupActionOutputWidthSync();
    setupWorkerListWidthSync();
    restoreCmdAreaHeights();
    setupCmdAreaResizeSaving();
    restoreCmdOutputHeight();
    setupCmdOutputResizeSaving();
    restoreCmdModalSize();
    setupCmdModalSizeSaving();
    restoreLogsModalSize();
    setupLogsModalSizeSaving();
    // Width-only persistence - these all use .dialog-resize-handle-right (width-drag only), so
    // there's no height to save. statuslog-modal and backups-modal use the -corner handle
    // (width+height) instead and are wired below via restoreResizableDialogSize/
    // setupResizableDialogSizeSaving, same as raw-content-modal.
    const RESIZABLE_TAB_MODALS = [
        ["stats-modal", "rigcontrol_stats_modal_width"],
        ["wallet-modal", "rigcontrol_wallet_modal_width"],
        ["fs-modal", "rigcontrol_fs_modal_width"],
        ["oc-modal", "rigcontrol_oc_modal_width"],
        ["wdconfig-modal", "rigcontrol_wdconfig_modal_width"],
        ["refresh-modal", "rigcontrol_refresh_modal_width"],
    ];
    for (const [containerId, storageKey] of RESIZABLE_TAB_MODALS) {
        restoreResizableDialogWidth(containerId, storageKey);
        setupResizableDialogWidthSaving(containerId, storageKey);
    }
    initDialogResizeHandles();
    initStatuslogColResizer();
    restoreStatuslogListWidth();
    initRawContentTriggers();
    restoreResizableDialogSize("raw-content-modal", "rigcontrol_raw_content_modal_size");
    setupResizableDialogSizeSaving("raw-content-modal", "rigcontrol_raw_content_modal_size");
    restoreResizableDialogSize("statuslog-modal", "rigcontrol_statuslog_modal_size");
    setupResizableDialogSizeSaving("statuslog-modal", "rigcontrol_statuslog_modal_size");
    restoreResizableDialogSize("backups-modal", "rigcontrol_backups_modal_size");
    setupResizableDialogSizeSaving("backups-modal", "rigcontrol_backups_modal_size");
    setupFsPoolsDialogSizeSaving();
    setupFsMcDialogSizeSaving();
    initColorSchemeControls();
    initWallpaperControls();
    initStatPanelStyleControls();
    initToolbarBtnStyleControls();
    initPageAlignControl();
    document.querySelectorAll(".action-tab").forEach(btn => {
        btn.addEventListener("click", (e) => {
            const mode = e.target.dataset.mode;
            if (mode) setActionMode(mode);
        });
    });
    document.getElementById("btn-wd-enable")?.addEventListener("click", toggleWdEnabled);
    setupHeaderClickHandlers();
    loadColumnState();
    applyHiddenColumnsToDOM();
    document.getElementById("btn-toggle-select")?.addEventListener("click", toggleSelectAll);
    document.getElementById("rig-select-all-checkbox")?.addEventListener("click", (ev) => {
        ev.stopPropagation();
        toggleSelectAllRows();
    });
    document.getElementById("btn-send-cmd")?.addEventListener("click", openCmdModal);
    document.getElementById("btn-close-cmd-modal")?.addEventListener("click", closeCmdModal);
    document.getElementById("btn-open-logs")?.addEventListener("click", openLogsModal);
    document.getElementById("btn-close-logs-modal")?.addEventListener("click", closeLogsModal);
    document.getElementById("btn-logs-refresh")?.addEventListener("click", fetchLogs);
    document.getElementById("logs-filter-input")?.addEventListener("input", (e) => {
        localStorage.setItem("rigcontrol_logs_filter", e.target.value);
        applyLogsFilter(false);
    });
    window.addEventListener("resize", () => {
        if (isLogsModuleVisible()) syncLogsFilterWidth();
    });
    document.getElementById("logs-type-select")?.addEventListener("change", (e) => {
        localStorage.setItem("rigcontrol_logs_type", e.target.value);
        updateLogsLinesFieldVisibility();
        fetchLogs();
    });
    document.getElementById("logs-lines-input")?.addEventListener("change", (e) => {
        localStorage.setItem("rigcontrol_logs_lines", e.target.value);
    });
    document.getElementById("logs-auto-refresh-checkbox")?.addEventListener("change", (e) => {
        localStorage.setItem("rigcontrol_logs_auto", e.target.checked ? "1" : "0");
        handleLogsAutoRefreshToggle();
    });
    document.getElementById("logs-interval-input")?.addEventListener("change", (e) => {
        let secs = parseInt(e.target.value, 10);
        if (!Number.isFinite(secs) || secs < 2) secs = 2;
        if (secs > 300) secs = 300;
        e.target.value = secs;
        localStorage.setItem("rigcontrol_logs_interval", String(secs));
        if (document.getElementById("logs-auto-refresh-checkbox")?.checked) {
            startLogsAutoRefresh();
        }
    });
    document.getElementById("btn-logs-interval-up")?.addEventListener("click", () => adjustLogsInterval(1));
    document.getElementById("btn-logs-interval-down")?.addEventListener("click", () => adjustLogsInterval(-1));
    restoreLogsPrefs();
    document.getElementById("rig-search")?.addEventListener("input", (e) => {
        rigSearchQuery = (e.target.value || "").trim().toLowerCase();
        scheduleRender();
    });
    document.getElementById("view-only-banner")?.addEventListener("click", openUnlockModal);
    document.getElementById("btn-unlock-request-code")?.addEventListener("click", requestUnlockCode);
    document.getElementById("btn-unlock-submit-code")?.addEventListener("click", submitUnlockCode);
    document.getElementById("btn-unlock-close")?.addEventListener("click", closeUnlockModal);
    document.getElementById("btn-unlock-close-x")?.addEventListener("click", closeUnlockModal);
    document.getElementById("unlock-code-input")?.addEventListener("keydown", (e) => {
        if (e.key === "Enter") submitUnlockCode();
    });
    document.getElementById("unlock-email-input")?.addEventListener("keydown", (e) => {
        if (e.key === "Enter") requestUnlockCode();
    });
    document.getElementById("btn-remote-logout")?.addEventListener("click", logoutRemoteUnlock);
    document.getElementById("btn-action-start")?.addEventListener("click", actionStart);
    document.getElementById("btn-action-stop")?.addEventListener("click", actionStop);
    document.getElementById("btn-action-restart")?.addEventListener("click", actionRestart);
    document.getElementById("btn-quick-a")?.addEventListener("click", (e) => handleQuickActionClick("a", e));
    document.getElementById("btn-quick-b")?.addEventListener("click", (e) => handleQuickActionClick("b", e));
    document.getElementById("btn-quick-c")?.addEventListener("click", (e) => handleQuickActionClick("c", e));
    document.getElementById("btn-qa-apply")?.addEventListener("click", applyQuickActionsModal);
    document.getElementById("btn-qa-cancel")?.addEventListener("click", closeQuickActionsModal);
    document.getElementById("btn-qa-close-x")?.addEventListener("click", closeQuickActionsModal);
    document.getElementById("btn-cmd-send")?.addEventListener("click", submitCmd);
    document.getElementById("btn-cmd-clear-send")?.addEventListener("click", clearOutputAndSend);
    document.getElementById('btn-cmd-clear').addEventListener('click', function() {
        document.getElementById('cmd-input').value = '';
        document.getElementById('cmd-output').textContent = '';
        document.getElementById('saved-cmd-name').value = '';
        document
            .querySelectorAll('#saved-cmd-list .fs-item.selected')
            .forEach(e => e.classList.remove('selected'));
        selectedSavedCommandId = null;
        const status = document.getElementById('saved-cmd-status');
        if (status) status.textContent = '';
    });
    document.getElementById('btn-clear-fs').addEventListener('click', function() {
        document.getElementById("fs-raw").value = '';
        autoResizeFsRaw();
        clearFsFields();
        document.querySelectorAll('.selected').forEach(item => {
            item.classList.remove('active');
            item.classList.remove('selected');
            item.removeAttribute('aria-selected');
        });
        document.getElementById("fs-name").value = '';
        clearFsApplyToSelection();
    });
    document.getElementById("fs-raw")?.addEventListener("input", (e) => {
        autoResizeFsRaw();
        populateFsFieldsFromRaw(e.target.value);
    });
    document.getElementById("btn-fs-open-miner-config")?.addEventListener("click", () => {
        openFsMinerConfigModal();
    });
    document.getElementById("btn-fs-miner-config-close")?.addEventListener("click", () => {
        closeFsMinerConfigModal();
    });
    document.getElementById("btn-fs-mc-apply")?.addEventListener("click", () => {
        // Force a full rebuild from the live form state so the raw content reflects the modal's changes.
        const rawEl = document.getElementById("fs-raw");
        if (rawEl) {
            rawEl.value = buildFsActivePreview();
            autoResizeFsRaw();
        }
        closeFsMinerConfigModal();
    });
    document.getElementById("btn-fs-mc-cancel")?.addEventListener("click", () => {
        fsMcCancel();
    });
    document.getElementById("btn-fs-mc-clear")?.addEventListener("click", () => {
        fsMcClearCurrentTab();
    });
    document.getElementById("fs-miner-config-tabs")?.addEventListener("click", (e) => {
        const btn = e.target.closest(".fs-miner-config-tab");
        if (!btn) return;
        fsMcSwitchTab(btn.dataset.service);
    });
    document.getElementById("fs-service-tabs")?.addEventListener("click", (e) => {
        const btn = e.target.closest(".fs-service-tab");
        if (!btn) return;
        fsSwitchServiceTab(btn.dataset.service);
    });
    fsSyncServiceTabsUI();
    document.getElementById("btn-fs-apply-to-toggle")?.addEventListener("click", (evt) => {
        evt.stopPropagation();
        toggleFsApplyToDropdown();
    });
    document.getElementById("fs-apply-to-workers-option")?.addEventListener("click", () => {
        fsApplyToRigs.clear();
        updateFsApplyToToggleLabel();
        closeFsApplyToDropdown();
        syncFsRawAfterApplyToChange();
    });
    document.getElementById("fs-apply-to-clear-btn")?.addEventListener("click", () => {
        clearFsApplyToSelection();
    });
    document.addEventListener("click", (evt) => {
        const wrap = document.getElementById("fs-apply-to-wrap");
        if (wrap && !wrap.contains(evt.target)) {
            closeFsApplyToDropdown();
        }
    });
    document.getElementById("btn-send-it-fs")?.addEventListener("click", sendItFs);
    initSendConfirmCheckbox("confirm-fs", "fs");
    document.getElementById("btn-save-fs")?.addEventListener("click", saveFlightsheetFromDialog);
    document.getElementById("btn-delete-fs")?.addEventListener("click", deleteFlightsheet);
    document.getElementById("fs-select-all-checkbox")?.addEventListener("click", toggleSelectAllFlightsheets);
    document.getElementById("fs-search")?.addEventListener("input", filterFlightsheetList);
    document.getElementById("fs-algo-filter")?.addEventListener("change", filterFlightsheetList);
    document.getElementById("fs-miner-filter")?.addEventListener("change", filterFlightsheetList);
    document.getElementById("fs-fields-panel")?.addEventListener("input", (e) => {
        updateRawFromFieldChange(e.target);
    });
    // Fields are relocated into the miner-config modal while open (see openFsMinerConfigModal), out from
    // under #fs-fields-panel's delegated listener above - mirror it here so live sync keeps working.
    document.getElementById("fs-miner-config-modal")?.addEventListener("input", (e) => {
        updateRawFromFieldChange(e.target);
    });
    // fs-mc-pool-token mirrors miner_config.url, not pool_urls, so it needs its own listener.
    document.getElementById("fs-mc-pool-token")?.addEventListener("input", (e) => {
        fsPoolUrlToken = e.target.value;
        const poolEl = document.getElementById("fs-field-pool");
        if (poolEl) updateRawFromFieldChange(poolEl);
    });
    document.getElementById("fs-field-miner")?.addEventListener("input", () => {
        if (!document.getElementById("fs-miner-config-modal")?.classList.contains("hidden")) {
            updateFsMinerConfigTitle();
            updateFsMinerConfigCustomVisibility();
        }
    });
    ["fs-field-wallet", "fs-field-miner", "fs-field-algo", "fs-field-pass", "fs-field-pool"].forEach((id) => {
        document.querySelector(`label[for="${id}"]`)?.addEventListener("click", (e) => {
            e.preventDefault();
        });
    });
    document.getElementById("fs-field-wallet")?.addEventListener("input", (e) => {
        renderFsWalletSuggestions(e.target.value);
    });
    document.getElementById("fs-field-wallet")?.addEventListener("focus", (e) => {
        renderFsWalletSuggestions(e.target.value);
    });
    document.getElementById("fs-field-wallet")?.addEventListener("click", (e) => {
        renderFsWalletSuggestions(e.target.value);
    });
    document.getElementById("fs-field-miner")?.addEventListener("input", (e) => {
        fsMinerRawOriginal = "";
        renderFsMinerSuggestions(e.target.value);
        refreshFsPoolFieldDisplay();
    });
    document.getElementById("fs-field-miner")?.addEventListener("focus", (e) => {
        renderFsMinerSuggestions(e.target.value);
    });
    document.getElementById("fs-field-miner")?.addEventListener("click", (e) => {
        renderFsMinerSuggestions(e.target.value);
    });
    document.getElementById("fs-field-algo")?.addEventListener("input", (e) => {
        renderFsAlgoSuggestions(e.target.value);
    });
    document.getElementById("fs-field-algo")?.addEventListener("focus", (e) => {
        renderFsAlgoSuggestions(e.target.value);
    });
    document.getElementById("fs-field-algo")?.addEventListener("click", (e) => {
        renderFsAlgoSuggestions(e.target.value);
    });
    document.getElementById("fs-field-pass")?.addEventListener("input", (e) => {
        renderFsPassSuggestions(e.target.value);
    });
    document.getElementById("fs-field-pass")?.addEventListener("focus", (e) => {
        renderFsPassSuggestions(e.target.value);
    });
    document.getElementById("fs-field-pass")?.addEventListener("click", (e) => {
        renderFsPassSuggestions(e.target.value);
    });
    document.getElementById("fs-field-pool")?.addEventListener("input", (e) => {
        fsPrimaryPoolUrl = e.target.value;
        renderFsPoolSuggestions(e.target.value);
    });
    document.getElementById("fs-field-pool")?.addEventListener("focus", (e) => {
        renderFsPoolSuggestions(e.target.value);
    });
    document.getElementById("fs-field-pool")?.addEventListener("click", (e) => {
        renderFsPoolSuggestions(e.target.value);
    });
    document.getElementById("fs-field-pool")?.addEventListener("paste", (e) => {
        const text = (e.clipboardData || window.clipboardData)?.getData("text") || "";
        const addrs = extractPoolAddressesFromText(text);
        if (addrs.length === 0) return;
        if (addrs.length === 1 && addrs[0] === text.trim()) return;
        e.preventDefault();
        const sslOn = !!document.getElementById("fs-field-ssl")?.checked;
        const poolEl = e.target;
        if (addrs.length === 1) {
            poolEl.value = styledFsPoolUrl(addrs[0], sslOn);
            fsExtraPoolUrls = [];
            fsPrimaryPoolUrl = "";
        } else {
            fsPrimaryPoolUrl = styledFsPoolUrl(addrs[0], sslOn);
            fsExtraPoolUrls = addrs.slice(1);
        }
        updateManagePoolsBtnLabel();
        refreshFsPoolFieldDisplay();
        updateRawFromFieldChange(poolEl);
    });
    document.getElementById("fs-field-ssl")?.addEventListener("change", (e) => {
        const poolEl = document.getElementById("fs-field-pool");
        if (!poolEl) return;
        if (fsExtraPoolUrls.length > 0) {
            const bare = bareFsPoolUrl(fsPrimaryPoolUrl);
            if (!bare) return;
            fsPrimaryPoolUrl = styledFsPoolUrl(bare, e.target.checked);
            refreshFsPoolFieldDisplay();
            updateRawFromFieldChange(poolEl);
            return;
        }
        const bare = (poolEl.value || "")
            .replace(/^stratum\+ssl:\/\//, "")
            .replace(/^stratum\+tcp:\/\//, "");
        if (!bare) return;
        poolEl.value = e.target.checked ? `stratum+ssl://${bare}` : bare;
        updateRawFromFieldChange(poolEl);
    });
    document.getElementById("fs-field-tls")?.addEventListener("change", (e) => {
        const argsEl = document.getElementById("fs-field-args");
        const minerLowerForTls = (document.getElementById("fs-field-miner")?.value || "").toLowerCase();
        if (argsEl) {
            if (isSrbminerFamily(minerLowerForTls)) {
                const hasTls = /(^|\s)--tls\s+\S+/.test(argsEl.value);
                if (e.target.checked) {
                    argsEl.value = hasTls
                        ? argsEl.value.replace(/(^|\s)--tls\s+\S+/, (m, pre) => `${pre}--tls true`)
                        : (argsEl.value.trim() ? argsEl.value.trim() + " " : "") + "--tls true";
                } else if (hasTls) {
                    argsEl.value = argsEl.value
                        .replace(/(^|\s)--tls\s+\S+/, " ")
                        .replace(/\s+/g, " ")
                        .trim();
                }
                // Clear the stashed original user_config so it doesn't win over this TLS-corrected ARGS edit on rebuild.
                fsSrbminerOriginalUserConfig = "";
            } else {
                const hasTls = /(^|\s)--tls(\s|$)/.test(argsEl.value);
                if (e.target.checked && !hasTls) {
                    argsEl.value = (argsEl.value.trim() ? argsEl.value.trim() + " " : "") + "--tls";
                } else if (!e.target.checked && hasTls) {
                    argsEl.value = argsEl.value
                        .replace(/(^|\s)--tls(?=\s|$)/, " ")
                        .replace(/\s+/g, " ")
                        .trim();
                }
            }
        }
        const poolEl = document.getElementById("fs-field-pool");
        if (poolEl) updateRawFromFieldChange(poolEl);
    });
    document.getElementById("btn-manage-pools")?.addEventListener("click", openManagePoolsDialog);
    document.getElementById("btn-fs-pools-save")?.addEventListener("click", saveManagePoolsDialog);
    document.getElementById("btn-fs-pools-cancel")?.addEventListener("click", closeManagePoolsDialog);
    document.getElementById("btn-fs-pools-close-x")?.addEventListener("click", closeManagePoolsDialog);
    document.getElementById("btn-save-fs-wallet")?.addEventListener("click", openFsWalletSaveDialog);
    document.getElementById("btn-fs-wallet-save-confirm")?.addEventListener("click", confirmFsWalletSave);
    document.getElementById("btn-fs-wallet-save-cancel")?.addEventListener("click", closeFsWalletSaveDialog);
    document.getElementById("btn-fs-wallet-save-close-x")?.addEventListener("click", closeFsWalletSaveDialog);
    document.getElementById("btn-fs-copy-json")?.addEventListener("click", copyFsCombinedJsonToClipboard);
    document.getElementById("fs-field-args")?.addEventListener("input", () => {
        fsBzminerOcJsonUserConfig = "";
        fsSrbminerOriginalUserConfig = "";
        fsXmrigOcJsonUserConfig = "";
        fsXmrigCpuConfigJson = "";
    });
    document.getElementById("fs-pools-textarea")?.addEventListener("paste", (e) => {
        const text = (e.clipboardData || window.clipboardData)?.getData("text") || "";
        const addrs = extractPoolAddressesFromText(text);
        if (addrs.length === 0) return;
        if (addrs.length === 1 && addrs[0] === text.trim()) return;
        e.preventDefault();
        const sslOn = !!document.getElementById("fs-field-ssl")?.checked;
        const cleaned = addrs.map((a) => styledFsPoolUrl(a, sslOn)).join("\n");
        const ta = e.target;
        const start = ta.selectionStart ?? ta.value.length;
        const end = ta.selectionEnd ?? ta.value.length;
        ta.value = ta.value.slice(0, start) + cleaned + ta.value.slice(end);
        const caret = start + cleaned.length;
        ta.setSelectionRange(caret, caret);
    });
    document.addEventListener("click", (e) => {
        const box = document.getElementById("fs-wallet-suggestions");
        if (box && !box.classList.contains("hidden") && !e.target.closest(".fs-wallet-autocomplete")) {
            box.classList.add("hidden");
        }
        const minerBox = document.getElementById("fs-miner-suggestions");
        if (minerBox && !minerBox.classList.contains("hidden") && !e.target.closest(".fs-miner-autocomplete")) {
            minerBox.classList.add("hidden");
        }
        const algoBox = document.getElementById("fs-algo-suggestions");
        if (algoBox && !algoBox.classList.contains("hidden") && !e.target.closest(".fs-algo-autocomplete")) {
            algoBox.classList.add("hidden");
        }
        const passBox = document.getElementById("fs-pass-suggestions");
        if (passBox && !passBox.classList.contains("hidden") && !e.target.closest(".fs-pass-autocomplete")) {
            passBox.classList.add("hidden");
        }
        const poolBox = document.getElementById("fs-pool-suggestions");
        if (poolBox && !poolBox.classList.contains("hidden") && !e.target.closest(".fs-pool-autocomplete")) {
            poolBox.classList.add("hidden");
        }
        const walletNameBox = document.getElementById("wallet-name-suggestions");
        if (walletNameBox && !walletNameBox.classList.contains("hidden") && !e.target.closest(".wallet-name-autocomplete")) {
            walletNameBox.classList.add("hidden");
        }
        const walletAlgoBox = document.getElementById("wallet-algo-suggestions");
        if (walletAlgoBox && !walletAlgoBox.classList.contains("hidden") && !e.target.closest(".wallet-algo-autocomplete")) {
            walletAlgoBox.classList.add("hidden");
        }
    });
    document.addEventListener("keydown", (e) => {
        if (e.key !== "Escape") return;
        const suggestionBoxIds = [
            "fs-wallet-suggestions",
            "fs-miner-suggestions",
            "fs-algo-suggestions",
            "fs-pass-suggestions",
            "fs-pool-suggestions",
            "wallet-name-suggestions",
            "wallet-algo-suggestions",
        ];
        suggestionBoxIds.forEach((id) => {
            const box = document.getElementById(id);
            if (box && !box.classList.contains("hidden")) {
                box.classList.add("hidden");
                box.innerHTML = "";
            }
        });
    });
    wireUpFsTemplateToken("worker-name-token", "%WORKER_NAME%");
    wireUpFsTemplateToken("cpu-threads-token", "%CPU_THREADS%");
    wireUpFsTemplateToken("warthog-target-token", "--warthog_verus_hr_target %WARTHOG_TARGET%");
    wireUpFsTemplateToken("url-value-token", "%URL%");
    wireUpFsTemplateToken("pass-value-token", "%PASS%");
    wireUpFsTemplateToken("algo-value-token", "%ALGO%");
    wireUpFsTemplateToken("wallet-template-token-wal", "%WAL%");
    wireUpFsTemplateToken("wallet-worker-combo-token", "%WAL%.%WORKER_NAME%");
    document.getElementById('btn-clear-oc').addEventListener('click', function() {
        document.querySelectorAll('.selected').forEach(item => {
            item.classList.remove('active');
            item.classList.remove('selected');
            item.removeAttribute('aria-selected');
        });
        document.getElementById("oc-name").value = '';
        selectedOverclockId = null;
        ocApplyToRigs.clear();
        updateOcApplyToToggleLabel();
        clearOcRows();
        addOcRow(null, { skipRebuild: true });
        rebuildOcRawFromRows();
    });
    document.getElementById("btn-send-it-oc")?.addEventListener("click", sendItOc);
    initSendConfirmCheckbox("confirm-oc", "oc");
    document.getElementById("btn-save-oc")?.addEventListener("click", saveOverclockFromDialog);
    document.getElementById("btn-delete-oc")?.addEventListener("click", deleteOverclock);
    document.getElementById("oc-select-all-checkbox")?.addEventListener("click", toggleSelectAllOverclocks);
    document.getElementById("oc-algo-apply-select")?.addEventListener("change", onOcAlgoApplySelectChange);
    document.getElementById("oc-search")?.addEventListener("input", filterOverclockList);
    document.getElementById("oc-algo-filter")?.addEventListener("change", filterOverclockList);
    document.getElementById("btn-oc-apply-to-toggle")?.addEventListener("click", (evt) => {
        evt.stopPropagation();
        toggleOcApplyToDropdown();
    });
    document.getElementById("oc-apply-to-workers-option")?.addEventListener("click", () => {
        ocApplyToRigs.clear();
        updateOcApplyToToggleLabel();
        closeOcApplyToDropdown();
        syncOcRawAfterApplyToChange();
    });
    document.getElementById("oc-apply-to-clear-btn")?.addEventListener("click", () => {
        clearOcApplyToSelection();
    });
    document.addEventListener("click", (evt) => {
        const wrap = document.getElementById("oc-apply-to-wrap");
        if (wrap && !wrap.contains(evt.target)) {
            closeOcApplyToDropdown();
        }
    });
    document.getElementById("btn-oc-add-row")?.addEventListener("click", () => addOcRow());
    initOcFanCurveExampleButton();
    document.getElementById("oc-raw")?.addEventListener("input", (e) => {
        loadOcRowsFromScript(e.target.value);
        autoResizeOcRaw();
    });
    document.getElementById("btn-stats-load")?.addEventListener("click", loadStatsForSelectedRig);
    document.getElementById("stats-rig-select")?.addEventListener("change", () => {
        // Switching rigs - let the new rig auto-pick its own most-recent algo again
        // instead of carrying over a choice that applied to the previous rig.
        const algoSel = document.getElementById("stats-algo-select");
        if (algoSel) delete algoSel.dataset.userSet;
        loadStatsForSelectedRig();
    });
    document.getElementById("logs-rig-select")?.addEventListener("change", () => {
        fetchLogs();
    });
    document.getElementById("stats-hashrate-unit-select")?.addEventListener("change", () => {
        if (_lastStatsResp) renderStatsCharts(_lastStatsResp);
    });
    document.getElementById("stats-algo-select")?.addEventListener("change", (e) => {
        e.target.dataset.userSet = "1";
        if (_lastStatsResp) renderStatsCharts(_lastStatsResp);
    });
    document.getElementById("stats-days-input")?.addEventListener("keydown", (e) => {
        if (e.key === "Enter") loadStatsForSelectedRig();
    });
    document.getElementById("stats-days-input")?.addEventListener("input", updateStatsStartDateFromDays);
    document.getElementById("btn-wdconfig-add-row")?.addEventListener("click", () => addWdConfigRow());
    document.getElementById("btn-wdconfig-logterm-add")?.addEventListener("click", () => addWdLogTermRow());
    document.getElementById("wdconfig-logwatcher-panel")?.addEventListener("input", (e) => {
        if (e.target && e.target.id === "wdconfig-logwatcher-custom-script") {
            rebuildWdRawFromSettings();
            return;
        }
        updateWdLogTermScriptEnabled();
        rebuildWdRawFromSettings();
    });
    document.getElementById("btn-send-it-wd")?.addEventListener("click", sendItWd);
    initSendConfirmCheckbox("confirm-wd", "wd");
    document.getElementById("btn-statuslog-refresh")?.addEventListener("click", () => loadStatusLogList());
    document.getElementById("btn-statuslog-clear")?.addEventListener("click", clearVisibleStatusLogEntries);
    document.getElementById("btn-statuslog-delete-selected")?.addEventListener("click", deleteSelectedStatusLogEntries);
    document.getElementById("statuslog-select-all")?.addEventListener("change", (e) => {
        toggleAllStatusLogEntries(e.target.checked);
    });
    let statuslogSearchDebounceTimer = null;
    const debounceStatuslogSearch = () => {
        clearTimeout(statuslogSearchDebounceTimer);
        statuslogSearchDebounceTimer = setTimeout(() => {
            statuslogPage = 0; // a new search should start back at page 1, not wherever you were
            loadStatusLogList();
        }, 300);
    };
    document.getElementById("statuslog-search-title")?.addEventListener("input", debounceStatuslogSearch);
    document.getElementById("statuslog-search-content")?.addEventListener("input", debounceStatuslogSearch);
    document.getElementById("btn-statuslog-prev-page")?.addEventListener("click", () => {
        if (statuslogPage > 0) {
            statuslogPage--;
            loadStatusLogList();
        }
    });
    document.getElementById("btn-statuslog-next-page")?.addEventListener("click", () => {
        statuslogPage++;
        loadStatusLogList();
    });
    document.getElementById("backups-select-all")?.addEventListener("change", (e) => {
        toggleAllBackupFiles(e.target.checked);
    });
    document.getElementById("btn-backups-backup")?.addEventListener("click", runBackupsBackup);
    document.getElementById("btn-backups-restore")?.addEventListener("click", runBackupsRestore);
    document.getElementById("btn-backups-delete")?.addEventListener("click", runBackupsDelete);
    document.getElementById("btn-backups-preview")?.addEventListener("click", runBackupsPreview);
    document.getElementById("btn-backups-check-config")?.addEventListener("click", runBackupsCheckConfig);
    document.getElementById("btn-backups-test-connection")?.addEventListener("click", runBackupsTestConnection);
    document.getElementById("btn-backups-import-keys")?.addEventListener("click", () => {
        document.getElementById("backups-accesskeys-file-input")?.click();
    });
    document.getElementById("backups-accesskeys-file-input")?.addEventListener("change", (e) => {
        const file = e.target.files && e.target.files[0];
        importAccessKeysFile(file);
        e.target.value = "";
    });
    document.getElementById("statuslog-rig-select")?.addEventListener("change", () => {
        statuslogPage = 0; // switching rigs should start back at page 1 of that rig's results
        loadStatusLogList();
    });
    document.getElementById("statuslog-severity-filter")?.addEventListener("change", () => {
        statuslogPage = 0; // same reset-to-page-1 rule as the other filters above
        loadStatusLogList();
    });
    document.getElementById("wdconfig-hashrate-unit-up")?.addEventListener("click", () => stepWdHashrateUnit(1));
    document.getElementById("wdconfig-hashrate-unit-down")?.addEventListener("click", () => stepWdHashrateUnit(-1));
    document.getElementById("wdconfig-global-stop-up")?.addEventListener("click", () => stepWdGlobalStopFails(1));
    document.getElementById("wdconfig-global-stop-down")?.addEventListener("click", () => stepWdGlobalStopFails(-1));
    document.getElementById("wdconfig-mining-interval-up")?.addEventListener("click", () => stepWdInterval("wdconfig-mining-interval", 1));
    document.getElementById("wdconfig-mining-interval-down")?.addEventListener("click", () => stepWdInterval("wdconfig-mining-interval", -1));
    document.getElementById("wdconfig-logwatcher-interval-up")?.addEventListener("click", () => stepWdInterval("wdconfig-logwatcher-interval", 1));
    document.getElementById("wdconfig-logwatcher-interval-down")?.addEventListener("click", () => stepWdInterval("wdconfig-logwatcher-interval", -1));
    document.getElementById("wdconfig-global-stop-fails")?.addEventListener("input", () => {
        const el = document.getElementById("wdconfig-global-stop-fails");
        if (el && Number(el.value) < 0) el.value = 0;
        rebuildWdRawFromSettings();
    });
    document.getElementById("wdconfig-mining-interval")?.addEventListener("input", () => {
        const el = document.getElementById("wdconfig-mining-interval");
        if (el && Number(el.value) < 5) el.value = 5;
        rebuildWdRawFromSettings();
    });
    document.getElementById("wdconfig-logwatcher-interval")?.addEventListener("input", () => {
        const el = document.getElementById("wdconfig-logwatcher-interval");
        if (el && Number(el.value) < 5) el.value = 5;
        rebuildWdRawFromSettings();
    });
    document.getElementById("wdconfig-mining-enabled")?.addEventListener("input", () => {
        rebuildWdRawFromSettings();
    });
    document.getElementById("wdconfig-logwatcher-enabled")?.addEventListener("input", () => {
        rebuildWdRawFromSettings();
    });
    document.addEventListener("click", (e) => {
        if (e.target.closest(".wdconfig-algo-autocomplete")) return;
        document.querySelectorAll(".wdconfig-algo-suggestions").forEach(box => {
            box.classList.add("hidden");
            box.innerHTML = "";
        });
    });
    document.addEventListener("scroll", (e) => {
        document.querySelectorAll(".wdconfig-algo-suggestions:not(.hidden)").forEach(box => {
            if (box === e.target || box.contains(e.target)) return;
            const inputEl = box.parentElement?.querySelector("input");
            if (!inputEl) return;
            const rect = inputEl.getBoundingClientRect();
            box.style.left = `${rect.left}px`;
            box.style.top = `${rect.bottom + 4}px`;
            box.style.width = `${rect.width}px`;
        });
    }, true);
    document.getElementById("btn-load-wdconfig")?.addEventListener("click", loadSelectedWatchdogProfile);
    document.getElementById("btn-save-wdconfig")?.addEventListener("click", saveWatchdogProfileFromDialog);
    document.getElementById("btn-delete-wdconfig")?.addEventListener("click", deleteWatchdogProfile);
    document.getElementById("btn-clear-wdconfig")?.addEventListener("click", clearWdConfigFields);
    document.getElementById("wdconfig-search")?.addEventListener("input", filterWatchdogProfileList);
    document.getElementById("wdconfig-status-filter")?.addEventListener("change", filterWatchdogProfileList);
    document.getElementById("wdconfig-algo-filter")?.addEventListener("change", filterWatchdogProfileList);
    document.getElementById("btn-wd-apply-to-toggle")?.addEventListener("click", (evt) => {
        evt.stopPropagation();
        toggleWdApplyToDropdown();
    });
    document.getElementById("wd-apply-to-workers-option")?.addEventListener("click", () => {
        wdApplyToRigs.clear();
        updateWdApplyToToggleLabel();
        closeWdApplyToDropdown();
        syncWdRawAfterApplyToChange();
    });
    document.getElementById("wd-apply-to-clear-btn")?.addEventListener("click", () => {
        clearWdApplyToSelection();
    });
    document.addEventListener("click", (evt) => {
        const wrap = document.getElementById("wd-apply-to-wrap");
        if (wrap && !wrap.contains(evt.target)) {
            closeWdApplyToDropdown();
        }
    });
    document.getElementById("btn-save-saved-cmd")?.addEventListener("click", saveSavedCommandFromDialog);
    document.getElementById("btn-delete-saved-cmd")?.addEventListener("click", deleteSavedCommandSelected);
    document.getElementById("saved-cmd-search")?.addEventListener("input", filterSavedCommandsList);
    document.getElementById("wdconfig-settings-panel")?.addEventListener("input", (e) => {
        if (e.target && e.target.id === "wdconfig-raw") return;
        updateWdCustomScriptEnabled();
        saveWdPanelStateToSelectedRow();
        rebuildWdRawFromSettings();
    });
    document.getElementById("wdconfig-raw")?.addEventListener("input", (e) => {
        populateWdSettingsFromRaw(e.target.value);
        autoResizeWdRaw();
    });
    initWdconfigMainTabs();
    initSettingsMainTabs();
    document.getElementById("btn-agentconf-reload")?.addEventListener("click", autoLoadConfForSelectedRig);
    document.getElementById("btn-agentconf-clear")?.addEventListener("click", loadDefaultConfEditTemplate);
    document.getElementById("btn-agentconf-apply")?.addEventListener("click", sendItConfEdit);
    document.getElementById("agentconf-raw")?.addEventListener("input", resizeAgentConfRaw);
    document.getElementById("agentconf-raw")?.addEventListener("mouseup", saveAgentConfRawHeight);
    restoreAgentConfRawHeight();
    document.getElementById("settings-conf-type-select")?.addEventListener("change", (e) => {
        selectedConfEditType = e.target.value;
        updateConfEditTypeUi();
        autoLoadConfForSelectedRig();
    });
    updateConfEditTypeUi();
    document.getElementById("btn-templates-config-reload")?.addEventListener("click", loadTemplatesConfigTab);
    document.getElementById("btn-templates-config-apply")?.addEventListener("click", applyTemplatesConfig);
    document.getElementById("templates-config-raw")?.addEventListener("input", resizeTemplatesConfigRaw);
    // Toggling "restart after apply" changes what actually gets sent, so re-wrap the raw box right
    // away to add/remove the restart line - keeps the box showing the real command at all times
    // instead of only reflecting the checkbox once Send is clicked.
    document.getElementById("agentconf-restart-after-apply")?.addEventListener("change", (e) => {
        const rawEl = document.getElementById("agentconf-raw");
        if (!rawEl) return;
        rawEl.value = wrapConfEditCommand(selectedConfEditType, unwrapConfEditCommand(rawEl.value), e.target.checked);
        resizeAgentConfRaw();
    });
    initSendConfirmCheckbox("confirm-agentconf", "agentconf");
    document.getElementById("btn-save-wallet")?.addEventListener("click", saveWalletFromDialog);
    document.getElementById("btn-delete-wallet")?.addEventListener("click", deleteWallet);
    document.getElementById("btn-clear-wallet")?.addEventListener("click", newWallet);
    document.getElementById("btn-add-wallet-pool")?.addEventListener("click", () => {
        openWalletManagePoolsDialog();
    });
    document.getElementById("wallet-field-pools")?.addEventListener("dblclick", () => {
        const select = document.getElementById("wallet-field-pools");
        const selected = select.options[select.selectedIndex];
        if (!selected) return;
        if (confirm(`Remove pool "${selected.value}"?`)) {
            select.remove(select.selectedIndex);
        }
    });
    document.getElementById("wallet-search")?.addEventListener("input", filterWalletList);
    document.getElementById("wallet-algo-filter")?.addEventListener("change", filterWalletList);
    document.getElementById("wallet-name")?.addEventListener("input", (e) => {
        renderWalletNameSuggestions(e.target.value);
    });
    document.getElementById("wallet-name")?.addEventListener("focus", (e) => {
        renderWalletNameSuggestions(e.target.value);
    });
    document.getElementById("wallet-name")?.addEventListener("click", (e) => {
        renderWalletNameSuggestions(e.target.value);
    });
    document.querySelector('label[for="wallet-name"]')?.addEventListener("click", (e) => {
        e.preventDefault();
    });
    document.getElementById("wallet-field-coin")?.addEventListener("input", () => {
        renderWalletAlgoSuggestions();
    });
    document.getElementById("wallet-field-coin")?.addEventListener("focus", () => {
        renderWalletAlgoSuggestions();
    });
    document.getElementById("wallet-field-coin")?.addEventListener("click", () => {
        renderWalletAlgoSuggestions();
    });
    document.querySelector('label[for="wallet-field-coin"]')?.addEventListener("click", (e) => {
        e.preventDefault();
    });
    const walletNotesEl = document.getElementById("wallet-field-notes");
    walletNotesEl?.addEventListener("input", () => linkifyWalletNotesOverlay());
    walletNotesEl?.addEventListener("scroll", () => {
        const overlay = document.getElementById("wallet-field-notes-overlay");
        if (overlay) {
            overlay.scrollTop = walletNotesEl.scrollTop;
            overlay.scrollLeft = walletNotesEl.scrollLeft;
        }
    });
    document.getElementById("btn-reset")?.addEventListener("click", (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        hardReset(ev);
    });
    document.addEventListener("keydown", (e) => {
        if (e.key === "Escape") {
            const colorSchemeModal = document.getElementById("color-scheme-modal");
            const cmdModal = document.getElementById("cmd-modal");
            if (colorSchemeModal && !colorSchemeModal.classList.contains("hidden")) {
                closeColorSchemeModal();
            }
            else if (cmdModal && !cmdModal.classList.contains("hidden")) {
                closeCmdModal();
            }
        }
        if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
            const cmdModal = document.getElementById("cmd-modal");
            if (cmdModal && !cmdModal.classList.contains("hidden")) {
                submitCmd();
                e.preventDefault();
            }
        }
        if ((e.ctrlKey || e.metaKey) && e.key === "s") {
            e.preventDefault();
            const fsModal = document.getElementById("fs-modal");
            if (fsModal && !fsModal.classList.contains("hidden")) {
                saveFlightsheetFromDialog();
            }
        }
        if ((e.ctrlKey || e.metaKey) && e.key === "a") {
            const activeElement = document.activeElement;
            if (activeElement.tagName !== "INPUT" && activeElement.tagName !== "TEXTAREA") {
                e.preventDefault();
                toggleSelectAll();
            }
        }
    });
    const actionBox = document.getElementById("action-output");
    if (actionBox) {
        actionBox.addEventListener("focus", () => {
            actionBox.classList.remove("collapsed");
            actionBox.classList.add("expanded");
        });
        actionBox.addEventListener("blur", () => {
            actionBox.classList.remove("expanded");
            actionBox.classList.add("collapsed");
        });
    }
    setActionMode(currentActionMode);
    await loadConfig();
    syncTelemetryColumnsToServer();
    applyViewOnlyMode();
    loadQuickActionsConfig().then(updateQuickActionTooltips);
    initRefreshTimer();
    initAfterConfig();
    initViewTabs();
    render();
    setupRigEventDelegation();
    window.addEventListener('beforeunload', cleanupWebSocket);
    console.log("Page initialization complete");
});
if (window.hasOwnProperty('webSocketInitialized')) {
    console.log('WebSocket already initialized in this window context');
} else {
    window.webSocketInitialized = false;
}
for (const [key, info] of Object.entries(FS_RAW_KEY_MAP)) {
    FS_FIELD_ID_TO_KEY[info.id] = { key, type: info.type };
}
