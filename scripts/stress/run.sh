#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
app=${1:-"$here/../../build/Joplin Native.app"}
work=${STRESS_DIR:-/tmp/stress}
runs=${RUNS:-3}
mkdir -p "$work"
cd "$work"
quit_joplin() { osascript -e 'quit app "Joplin"' 2>/dev/null || true; sleep 8; }
sampler=""
sample() { python3 "$here/sample.py" "$1" "$2" & sampler=$!; }
stop_sampling() { kill "$sampler" 2>/dev/null || true; wait "$sampler" 2>/dev/null || true; }

if [ ! -d jprof-pristine ]; then
  echo "Generating the dataset and loading it into a new Joplin profile…"
  python3 "$here/gen.py" > data.jsonl
  rm -rf jprof && mkdir jprof
  cat > jprof/settings.json <<'EOF'
{
  "locale": "en_US",
  "api.token": "stresstoken",
  "clipperServer.autoStart": true,
  "featureFlag.autoUpdaterServiceEnabled": false,
  "noteVisiblePanes": ["editor"],
  "sync.target": 0
}
EOF
  quit_joplin
  open -n -a Joplin --args --profile "$work/jprof"
  until curl -s localhost:41184/ping >/dev/null; do sleep 1; done
  python3 "$here/load.py" data.jsonl
  sleep 15
  quit_joplin
  cp -R jprof jprof-pristine
fi

if [ ! -d native-pristine ]; then
  echo "Importing the same profile into Joplin Native…"
  rm -rf jprof-import && cp -R jprof-pristine jprof-import
  open -W -n --env JN_DATA_DIR="$work/native-pristine" --env JN_IMPORT_DESKTOP="$work/jprof-import" \
    --env JN_SNAPSHOT="$work/import.png" --env JN_SNAPSHOT_DELAY=30 --env JN_SNAPSHOT_QUIT=1 "$app"
fi

expected=$(python3 - <<'EOF'
import re, sqlite3
word = re.compile(r"(?<!\w)значение(?!\w)", re.I)
db = sqlite3.connect("jprof-pristine/database.sqlite")
print(sum(1 for t, b in db.execute("select title, body from notes") if word.search(t) or word.search(b)))
EOF
)

for i in $(seq "$runs"); do
  echo "Joplin Native, run ${i}…"
  rm -rf nrun && cp -R native-pristine nrun
  sample "/$(basename "$app")/" "$work/res-native-$i.samples.jsonl"
  open -W -n --env JN_DATA_DIR="$work/nrun" --env JN_STRESS_LOG="$work/res-native-$i.json" --env JN_STRESS_EXPECTED="$expected" \
    --env JN_STRESS_T0="$(python3 -c 'import time; print(time.time())')" "$app"
  stop_sampling
  sleep 10
  echo "Joplin Desktop, run ${i}…"
  quit_joplin
  rm -rf jrun && cp -R jprof-pristine jrun
  sample "/Applications/Joplin.app/" "$work/res-joplin-$i.samples.jsonl"
  python3 "$here/jbench.py" "$work/jrun" "$work/res-joplin-$i.json" > "$work/res-joplin-$i.log" 2>&1
  quit_joplin
  stop_sampling
done

python3 "$here/report.py" "Joplin Desktop=$work/res-joplin-*.json" "Joplin Native=$work/res-native-*.json"
