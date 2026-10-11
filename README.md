# Vox: voice control for macOS

![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black)
![Chip](https://img.shields.io/badge/Apple%20silicon-arm64-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![Offline](https://img.shields.io/badge/speech%20%2B%20LLM-on--device-brightgreen)

Say **"Hey Vox, open Safari and YouTube and play a random LTT video"**, or hold **⌥Space** and talk.
Commands start while you're still speaking, and Vox goes back to sleep after each one. Speech recognition
and the language model run on-device. Vox replies in American English.

## Requirements
- **macOS 26 or later on Apple silicon** (built and used daily on macOS 27, MacBook Air). Not available for Windows or Linux:
  Vox is built on macOS-only frameworks (Speech, AppleScript, Accessibility, the on-device Foundation model).
- Xcode command-line tools with Swift 6 (`xcode-select --install`).
- On first run, macOS asks for **Microphone**, **Speech Recognition** and **Accessibility** access, and for
  permission to control each app Vox drives (Spotify, Safari, Messages …).

## Install
- **This Mac:** `./build.sh` runs the command tests, builds, and installs to /Applications.
- **Installer:** `./build.sh --dmg` also writes `dist/Vox.dmg`. It's ad-hoc signed; other Macs need
  right-click → Open the first time. Shipping to the public needs an Apple Developer ID and notarization.

## What it does
| Area | Examples |
|---|---|
| Apps & web | open / quit / switch apps, websites, Google/YouTube/Amazon search, tabs, back, scroll, find on page |
| Music & video | play songs (Spotify, Apple Music library, YouTube), play/watch videos ("random", "latest"), pause/next, "what's playing" |
| Typing & text | live dictation, summarize/explain/translate/rewrite/fix grammar for the selection, page or clipboard |
| Messages | iMessage, WhatsApp and email to contacts (always asks before sending) |
| Time & plans | timers, alarms, reminders with dates, calendar agenda, add events, notes |
| Answers | web-grounded answers, weather and rain, exact math, unit and currency conversion, date/time, battery, storage |
| Maps & files | directions, places near me, Spotlight file open, folders, Settings panes |
| Mac | volume/brightness levels, Wi-Fi, dark mode, window tiling, screenshots, lock, Shortcuts, restart/shut down (asks first) |

Anything the rules don't understand is rewritten by the on-device model into these commands.

## Principles
- **Finish the request.** "Play X" plays X; it never stops at a search page. Results are checked:
  Spotify tracks skipped in your region fall back to the next match, YouTube is nudged to play if autoplay is blocked,
  and failures are said out loud. A song Spotify can't find plays on YouTube instead of stopping at a search page.
- **Never launch Apple Music by accident.** Play, pause and next go to the app that's actually playing (Spotify, Music
  or a browser tab), not to the media key, which opens Music when nothing is playing.
- **The model never invents.** Song-title fixes must sound like what was heard; lone fragments aren't rewritten.
- **Ask before anything irreversible**, such as sending a message or shutting down.
- **Don't fire early.** Unfinished clauses ("play a …", "cancel the …") wait, and so does a short command that
  starts a different longer one ("quit…", "stop…", "send…", "play…") when you pause after it, so "quit… Spotify"
  never presses ⌘Q on the app in front. "Yes" never presses keys; "send it" sends.
- **Never hang.** AppleScript runs off the main thread with a hard deadline, keychain reads too. If macOS hasn't
  allowed Vox to control an app (or can't ask, on the lock screen), Vox says how to fix it instead of freezing.
- **Recover by itself.** If the mic or recognizer stops (headphones connect, sleep, an error), hands-free
  restarts, backing off if it keeps failing.
- **Use the right mic.** With Bluetooth headphones as the input, Vox listens with the Mac's mic: a headset mic
  switches the headphones into call mode (muffled music, first words cut off). Settings can turn this off.
- Every command and every fixed bug gets a test: `Tests/commands.txt` (use `--` for a pause mid-sentence),
  `Tests/wake.txt`, `Tests/brain.txt`, `Tests/songs.txt`. `./test.sh` must pass before installing.

## Power (MacBook Air, measured with powermetrics)
- **Waiting for "Hey Vox":** Vox ~3 ms of CPU per second, plus ~0.1 core in coreaudiod, which is the Mac mic's own
  processing and the same for any app that listens. In total, tens of milliwatts. A volume gate (two loud 100 ms
  buffers in a row, adaptive noise floor) feeds the recognizer only while someone speaks, and 0.8 s of silence
  afterwards lets it finish the phrase and stop. ⌥Space only (hands-free off): 0.
- **During a command:** Vox peaks around 13 ms/s of CPU. The popup's orb is drawn by Core Animation (about 1% CPU
  while shown, down from ~5%). Recognition is a few tens of mW on the Neural Engine.
- **The language model is the only big burst** (about 1 s at 5–6 W on the Neural Engine). It runs only for phrasing
  the rules don't understand, questions, and song titles Spotify can't match as heard, never on wake.
- Echo cancellation ("Hear me over music") costs about 20% CPU, so it's off by default.

## Developer test modes
    .build/release/Vox --simulate "open safari and youtube" [--wake]    # parse only, word by word
    .build/release/Vox --brain "put on some arijit"                     # on-device model rewrite / answer
    .build/release/Vox --song "chan marrier"                            # song-title correction
    .build/release/Vox --render-hud /tmp                                # popup design → PNG
    open -n /Applications/Vox.app --args --exec "<command>" /tmp/x.log  # REALLY executes, logs outcomes
    open -n /Applications/Vox.app --args --listen-test 8 /tmp/l.log [--continuous]   # mic → transcript, gate stats
    open -n /Applications/Vox.app --args --hud-test 20                  # live popup, to measure drawing cost
    open -n /Applications/Vox.app --args --permissions /tmp/p.log       # which apps Vox may control
    open --env VOX_LOG=/tmp/vox.log /Applications/Vox.app               # trace wakes, commands and outcomes
