#!/bin/zsh
# Command regression suite: feeds each phrase word by word (like live speech) and checks the actions.
# Format of Tests/commands.txt: what the user says | expected actions, in order.
set -uo pipefail
cd "$(dirname "$0")"
swift build -c release >/dev/null || exit 1
fails=0; total=0; skipped=0
# The model suites need Apple Intelligence; without it they're skipped (and said so), not failed.
model=$(.build/release/Vox --model-status)
[[ "$model" == available ]] || print -r -- "On-device model $model: skipping the model and song-title cases."
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    said="${line%%|*}"
    expected="${line#*|}"
    got=$(.build/release/Vox --simulate "$said" 2>&1 | sed 's/.*→  //' | paste -sd'|' -)
    total=$((total + 1))
    if [[ "$got" != "$expected" ]]; then
        fails=$((fails + 1))
        print -r -- "✗ $said"
        print -r -- "    got:  $got"
        print -r -- "    want: $expected"
    fi
done < Tests/commands.txt
# Wake word: strong, weak or none.
while IFS='|' read -r heard want; do
    [[ -z "$heard" || "$heard" == \#* ]] && continue
    out=$(.build/release/Vox --simulate "$heard" --wake | head -1)
    got=none
    [[ "$out" == *woke* ]] && got=strong
    [[ "$out" == *weak* ]] && got=weak
    total=$((total + 1))
    if [[ "$got" != "$want" ]]; then
        fails=$((fails + 1))
        print -r -- "✗ wake: $heard"
        print -r -- "    got:  $got ($out)"
        print -r -- "    want: $want"
    fi
done < Tests/wake.txt
# On-device model rewrites.
while IFS='|' read -r said want; do
    [[ -z "$said" || "$said" == \#* ]] && continue
    [[ "$model" == available ]] || { skipped=$((skipped + 1)); continue }
    got=$(.build/release/Vox --brain "$said" | sed -nE 's/^rewrite \([0-9]+ ms\): (.*)$/\1/p')
    total=$((total + 1))
    if [[ "$got" != "$want" ]]; then
        fails=$((fails + 1))
        print -r -- "✗ model: $said"
        print -r -- "    got:  $got"
        print -r -- "    want: $want"
    fi
done < Tests/brain.txt
# Song-title correction (on-device model; skipped when Apple Intelligence is off).
while IFS='|' read -r heard want; do
    [[ -z "$heard" || "$heard" == \#* ]] && continue
    [[ "$model" == available ]] || { skipped=$((skipped + 1)); continue }
    got=$(.build/release/Vox --song "$heard" | sed -E 's/^.* -> (.*)  \([0-9]+ ms\)$/\1/')
    total=$((total + 1))
    if [[ "${got:l}" != "${want:l}" ]]; then
        fails=$((fails + 1))
        print -r -- "✗ song: $heard"
        print -r -- "    got:  $got"
        print -r -- "    want: $want"
    fi
done < Tests/songs.txt
# Helper checks (email addresses, file names, maths …) built into the binary.
self=$(.build/release/Vox --self-test)
self_total=$(print -r -- "$self" | sed -nE 's|^[0-9]+/([0-9]+) passed$|\1|p')
self_pass=$(print -r -- "$self" | sed -nE 's|^([0-9]+)/[0-9]+ passed$|\1|p')
print -r -- "$self" | grep -v ' passed$' || true
total=$((total + ${self_total:-1})); fails=$((fails + ${self_total:-1} - ${self_pass:-0}))
print "$((total - fails))/$total passed$( ((skipped)) && print -n ", $skipped skipped (no on-device model)")"
exit $(( fails > 0 ))
