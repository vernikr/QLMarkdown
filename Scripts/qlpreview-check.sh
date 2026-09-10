#!/bin/bash
#
# Check the QLMarkdown Quick Look preview on a live system.
#
#     Scripts/qlpreview-check.sh [--app PATH] [--files FILE ...] [--profile] [--keep] [--no-clear]
#
# What it does:
#   1. registers the Quick Look extension of the given application for the current user,
#      remembering the previously registered one;
#   2. runs preview sessions with `qlmanage`, reads the unified log of the extension and reports
#      the cold start (from `qlmanage` to the first rendering), the time every document took to be
#      prepared and whether it came from the cache;
#   3. restores the previous plugin registration on exit (unless --keep is given).
#
# Quick Look terminates the extension process when a panel is closed, so two rounds are run: the
# first one inside a single panel (documents cached in memory) and the second one with a new panel
# (documents cached on disk). The check fails when a document previewed in the first round is not
# reused in the second one.
#
# Options:
#   --app PATH       Application to test (default: /Applications/QLMarkdown.app).
#   --files F ...    Documents to preview (default: two generated sample files).
#   --profile        Also print where the cold start of the extension process goes, phase by
#                    phase, from the signposts the extension logs at the debug level. The labels
#                    are in `QLExtension/PreviewViewController.swift`.
#   --keep           Leave the plugin registration pointing to the tested application.
#   --no-clear       Do not empty the cache folder before the first round.
#
# A GUI session is required: `qlmanage` opens a real preview panel.
#
set -uo pipefail

PLUGIN_ID="org.sbarex.QLMarkdown.QLExtension"
APP="${APP:-/Applications/QLMarkdown.app}"
FILES=()
KEEP=0
CLEAR=1
PROFILE=0
PANEL_SECONDS=7
# Where the extension keeps the cached documents: its own container, and (for older layouts or a
# hand copied application) the containers that may hold it too.
CACHE_DIRS=(
    "$HOME/Library/Containers/org.sbarex.QLMarkdown.QLExtension/Data/Library/Caches/preview-cache"
    "$HOME/Library/Containers/org.sbarex.QLMarkdown/Data/Library/Caches/preview-cache"
    "$HOME/Library/Group Containers/group.org.sbarex.qlmarkdown/Library/Application Support/preview-cache"
)
TMP_DIR=""
LOG_PIDS=()
LOGS_DIR=""
RESTORE_APPEX=""
FAILURES=0

usage() {
    sed -n '3,26p' "$0" | sed -e 's/^#\( \|$\)//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --files)
            shift
            while [[ $# -gt 0 && "$1" != --* ]]; do
                FILES+=("$1")
                shift
            done
            ;;
        --profile) PROFILE=1; shift ;;
        --keep) KEEP=1; shift ;;
        --no-clear) CLEAR=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

# MARK: - Helpers

now() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print("%.3f" % time.time())'
    else
        date +%s
    fi
}

appex_path() { echo "$APP/Contents/PlugIns/Markdown QL Extension.appex"; }

# Every registered copy of the plug-in: the same application can be registered from more than one
# place, and Quick Look would then pick one of them (not necessarily the one under test).
registered_appexes() {
    # The output of pluginkit is tab separated and ends with the path of the plug-in.
    pluginkit -m -v -i "$PLUGIN_ID" 2>/dev/null | awk -F'\t' '{ print $NF }' | grep '\.appex$'
}

registered_appex() { registered_appexes | head -1; }

# Keep Launch Services aware of the application under test, so that a copy outside /Applications
# is a candidate for the preview too.
register_with_launch_services() {
    local lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    [[ -x "$lsregister" ]] || return 0
    "$lsregister" -f "$APP" >/dev/null 2>&1
}

banner() { printf '\n\033[1m%s\033[0m\n' "$1"; }

stop_log() {
    local pid
    for pid in "${LOG_PIDS[@]:-}"; do
        [[ -n "$pid" ]] || continue
        kill "$pid" >/dev/null 2>&1
        wait "$pid" 2>/dev/null
    done
    LOG_PIDS=()
}

start_log() { # $1: file of the extension log, $2: file of the process log
    # The debug level carries the cold start signposts; it only adds them, not the level of noise a
    # debug stream usually brings, because the predicate is restricted to the subsystem of the app.
    local level=info
    [[ "$PROFILE" -eq 1 ]] && level=debug
    log stream --predicate "subsystem == \"org.sbarex.QLMarkdown\"" --level "$level" --style compact >"$1" 2>&1 &
    LOG_PIDS+=($!)
    # The process life cycle (and so when Quick Look actually starts the extension) is logged by
    # RunningBoard, not by the extension itself.
    log stream --predicate "subsystem == \"com.apple.runningboard\"" --level default --style compact >"$2" 2>&1 &
    LOG_PIDS+=($!)
    sleep 1
}

cleanup() {
    stop_log
    pkill -f "^qlmanage" >/dev/null 2>&1
    pkill -f "Markdown QL Extension" >/dev/null 2>&1

    if [[ "$KEEP" -eq 0 ]]; then
        local current
        while IFS= read -r current; do
            [[ -n "$current" ]] && pluginkit -r "$current" >/dev/null 2>&1
        done < <(registered_appexes)
        [[ -n "$RESTORE_APPEX" ]] && pluginkit -a "$RESTORE_APPEX" >/dev/null 2>&1
        echo "Plugin registration restored: ${RESTORE_APPEX:-none}"
    else
        echo "Plugin registration left on: $(registered_appex)"
    fi

    [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
    return 0
}

register_extension() {
    local appex; appex="$(appex_path)"
    [[ -d "$appex" ]] || { echo "No Quick Look extension inside $APP" >&2; exit 1; }

    # Drop every registered copy, so that Quick Look cannot use another build of the plug-in.
    local old
    while IFS= read -r old; do
        [[ -n "$old" ]] && pluginkit -r "$old" >/dev/null 2>&1
    done < <(registered_appexes)

    pluginkit -a "$appex" >/dev/null 2>&1
    register_with_launch_services

    if [[ "$(registered_appex)" != "$appex" ]]; then
        # An application extension is normally registered by its own host application.
        open -g "$APP" >/dev/null 2>&1
        sleep 3
        pkill -f "$APP/Contents/MacOS/" >/dev/null 2>&1
        sleep 1
    fi

    if [[ "$(registered_appex)" != "$appex" ]]; then
        echo "Unable to register $appex (Quick Look would use: $(registered_appex))" >&2
        exit 1
    fi
}

# MARK: - One preview panel

# Preview the given files in a single panel, then report what the extension logged.
# $1: label of the round; the remaining arguments are the documents.
run_round() {
    local label="$1"; shift
    local appex; appex="$(appex_path)"
    local round_log="$TMP_DIR/round-${label//\//-}.log"
    local round_spawn_log="$TMP_DIR/round-${label//\//-}-spawn.log"

    pkill -f "Markdown QL Extension" >/dev/null 2>&1
    sleep 1

    # The logs are captured for this round only, and the streams are closed before reading them.
    start_log "$round_log" "$round_spawn_log"

    local round_start; round_start="$(now)"

    qlmanage -p "$@" >/dev/null 2>&1 &
    local ql_pid=$!
    sleep 2
    local served_by
    served_by="$(pgrep -fl "Markdown QL Extension" | head -1 | sed 's/^[0-9]* //; s/ -AppleLanguages.*//')"
    sleep $((PANEL_SECONDS - 2))
    kill "$ql_pid" >/dev/null 2>&1
    wait "$ql_pid" 2>/dev/null
    sleep 1

    stop_log

    banner "[$label] $# document(s) in one panel"
    if [[ -z "$served_by" ]]; then
        echo "  ⚠️  no extension process was seen: is a GUI session available?"
        FAILURES=$((FAILURES + 1))
    else
        echo "  served by: $served_by"
        if [[ "$served_by" != "$appex/Contents/MacOS/Markdown QL Extension" ]]; then
            echo "  ⚠️  that is not the application under test ($appex)"
            FAILURES=$((FAILURES + 1))
        fi
    fi

    report_round "$round_log" "$round_start" "$round_spawn_log"
    [[ "$PROFILE" -eq 1 ]] && report_phases "$round_log"
    ROUND_LOG="$round_log"
}

# Where the time of a preview goes inside the extension process: the delay between the signposts it
# logs, and the same delay counted from the start of the process.
report_phases() {
    local log="$1"
    python3 - "$log" <<'PY' 2>/dev/null
import datetime, re, sys
stamp_re = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)")
marks = []
for line in open(sys.argv[1], errors="replace"):
    match = stamp_re.match(line)
    if not match or "mark " not in line:
        continue
    stamp = datetime.datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp()
    label = line.rstrip().split("mark ", 1)[1]
    marks.append((stamp, label))
if len(marks) < 2:
    print("  no profile signposts were logged (an ordinary preview does not log them)")
    sys.exit()
print("  %-34s %9s %12s" % ("phase", "step", "from start"))
print("  %-34s %9s %12s" % ("---------------------------------", "--------", "-----------"))
print()
# Quick Look builds a fresh view controller (and so a fresh web view) for every document it is
# asked to preview, so the signposts restart: a group per document.
groups = []
for stamp, label in marks:
    if label == "loadView:begin" or not groups:
        groups.append([])
    groups[-1].append((stamp, label))
for index, group in enumerate(groups):
    if index:
        print()
    base = group[0][0]
    previous = base
    for stamp, label in group:
        print("  %-34s %6.0f ms %9.0f ms" % (label, (stamp - previous) * 1000, (stamp - base) * 1000))
        previous = stamp
PY
}

report_round() {
    local log="$1" start="$2" spawn_log="${3:-}"

    local cold
    cold="$(python3 - "$start" "$log" <<'PY' 2>/dev/null || echo n/a
import datetime, re, sys
started = float(sys.argv[1])
pattern = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)")
for line in open(sys.argv[2], errors="replace"):
    match = pattern.match(line)
    if match and "Generating preview for file" in line:
        stamp = datetime.datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp()
        print("%.0f" % ((stamp - started) * 1000))
        break
PY
)"
    [[ -n "$cold" ]] && echo "  extension cold start: ${cold} ms (from qlmanage to the first rendering)"

    # Where the cold start goes: the part before the extension process exists belongs to Quick Look
    # (qlmanage or Finder, the preview service, the plug-in lookup), the rest is the process launch
    # (exec, dyld, the extension bootstrap) and what the extension itself does.
    if [[ -n "$spawn_log" && -f "$spawn_log" ]]; then
        python3 - "$start" "$cold" "$spawn_log" <<'PY' 2>/dev/null
import datetime, re, sys
started = float(sys.argv[1])
cold = sys.argv[2]
stamp_re = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)")
spawn = None
for line in open(sys.argv[3], errors="replace"):
    match = stamp_re.match(line)
    if match and "org.sbarex.QLMarkdown.QLExtension" in line:
        spawn = datetime.datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp()
        break
if spawn:
    print("  Quick Look before the extension process: %.0f ms" % ((spawn - started) * 1000))
    if cold.isdigit():
        print("  extension process to the first rendering: %.0f ms" % (int(cold) - (spawn - started) * 1000))
PY
    fi

    printf '  %-28s %-8s %s\n' "document" "cached" "rendering"
    printf '  %-28s %-8s %s\n' "----------------------------" "------" "---------"

    local hits=0 misses=0 name ms cached cached_text
    while IFS=$'\t' read -r name ms cached; do
        [[ -z "${name:-}" ]] && continue
        if [[ "$cached" == "1" ]]; then
            cached_text="yes"; hits=$((hits + 1))
        else
            cached_text="no"; misses=$((misses + 1))
        fi
        printf '  %-28s %-8s %s ms\n' "$name" "$cached_text" "$ms"
    done < <(sed -n 's/.*Preview of \(.*\) ready in \([0-9.]*\) ms (cached: \([01]\)).*/\1\t\2\t\3/p' "$log")

    if [[ $((hits + misses)) -eq 0 ]]; then
        echo "  ⚠️  no rendering was logged"
        FAILURES=$((FAILURES + 1))
    fi
    echo "  documents: $misses rendered, $hits from the cache"
}

# MARK: - Main

APP="${APP/#\~/$HOME}"
if [[ ! -d "$APP" ]]; then
    echo "Not an application: $APP" >&2
    exit 1
fi
# Resolve the symlinks (/tmp is a link to /private/tmp): the plugin registry reports physical
# paths, and the two have to be comparable.
APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
command -v qlmanage >/dev/null 2>&1 || { echo "qlmanage is required" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
LOG_FILE="$TMP_DIR/preview.log"
RESTORE_APPEX="$(registered_appex)"

banner "QLMarkdown preview check"
echo "  application: $APP"
echo "  extension:   $(appex_path)"
echo "  registered before this run: ${RESTORE_APPEX:-none}"

trap cleanup EXIT
trap 'exit 130' INT TERM

if [[ ${#FILES[@]} -eq 0 ]]; then
    cat >"$TMP_DIR/code.md" <<'EOF'
# Sample with code

```swift
func compute(value: Int) -> Int {
    return value * 2
}
```

```c
int main(void) {
    return 0;
}
```
EOF
    cat >"$TMP_DIR/plain.md" <<'EOF'
# Sample without code

A paragraph with **bold** text, `inline code` and a [link](https://example.com).
EOF
    FILES=("$TMP_DIR/code.md" "$TMP_DIR/plain.md")
fi

for file in "${FILES[@]}"; do
    [[ -f "$file" ]] || { echo "No such file: $file" >&2; exit 1; }
done

if [[ "$CLEAR" -eq 1 ]]; then
    for dir in "${CACHE_DIRS[@]}"; do
        rm -rf "$dir"
    done
    echo "  the cache folder was emptied"
fi

register_extension

# Round 1: all the documents, then the first one again. The second request for the same document
# has to be served by the cache in memory.
run_round "1/2" "${FILES[@]}" "${FILES[0]}"

# Round 2: a new panel with the same documents, so a new extension process: they have to come from
# the cache on disk.
run_round "2/2" "${FILES[@]}"
second_round_log="$ROUND_LOG"

banner "Cache folder"
cache_dir="$(sed -n 's/.*Preview cache folder: \(.*\)$/\1/p' "$second_round_log" | tail -1)"
[[ -n "$cache_dir" ]] && echo "  reported by the extension: $cache_dir"
cache_found=0
for dir in "$cache_dir" "${CACHE_DIRS[@]}"; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    echo "  $dir: $(find "$dir" -name '*.json' | wc -l | tr -d ' ') document(s), $(du -sh "$dir" | cut -f1)"
    cache_found=1
    break
done
if [[ "$cache_found" -eq 0 ]]; then
    echo "  ⚠️  no cache folder was created"
    FAILURES=$((FAILURES + 1))
fi

banner "Result"
persisted="$(grep -c "cached: 1" "$second_round_log")"
if [[ "${persisted:-0}" -lt 1 ]]; then
    echo "  ❌ FAIL: no document of the second round came from the cache on disk"
    FAILURES=$((FAILURES + 1))
else
    echo "  ✅ PASS: $persisted document(s) were reused by a new extension process"
fi

if [[ "$FAILURES" -gt 0 ]]; then
    # Keep the logs of the rounds for inspection when something went wrong.
    LOGS_DIR="/tmp/qlpreview-check-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$LOGS_DIR"
    cp "$TMP_DIR"/round-*.log "$LOGS_DIR"/ 2>/dev/null
    echo "  $FAILURES check(s) failed"
    [[ -d "$LOGS_DIR" ]] && echo "  logs of the rounds: $LOGS_DIR"
    exit 1
fi
