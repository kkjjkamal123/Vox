# Changelog

## 1.3 (build 130) · 2026-11-06

Updating keeps your Microphone, Speech Recognition, Accessibility and Automation permissions: the app is
signed with the same identity as 1.2.

### Fixed
- **A command could stall Vox for good.** "Open file …" with a broad name made Spotlight print more than a pipe
  holds, and Vox waited for it forever; every later command queued behind it. Helper tools are now read while
  they run, with a time limit, and no single command can hold the queue for more than two minutes.
- **"Next song" on Spotify could leave the next track paused** and reply "nothing queued". It now starts it.
- **Push-to-talk dictation typed ⌥-characters.** Text typed while ⌥Space was still held carried the Option key
  (shortcuts or odd symbols in some apps); typed text no longer inherits held modifiers.
- **Screenshots overwrote each other.** Each one now gets its own name ("Vox Screenshot 2026-11-06 at 10.15.30.png").
- **Emailing a spoken address** ("email john at gmail dot com saying …") looked the address up as a contact name.
- **Contacts were searched on the main thread**, freezing the popup and hotkey with a large address book. A denied
  Contacts permission now says so instead of "I couldn't find … in your contacts".
- Turning Wi-Fi on or off no longer blocks the main thread while it finds the Wi-Fi interface.
- "Cancel all timers" and "how much time is left" read naturally ("Cancelled one timer and two alarms.",
  "1 hour and 5 minutes left", no more "1 seconds").
- YouTube titles with accents, quotes or other escaped characters are shown and spoken correctly.
- An empty model answer no longer shows an empty popup or risks leaving the mic muted.
- If speech setup fails at first launch (for example offline while the speech model downloads), Vox retries every
  minute instead of staying deaf until relaunched.
- Song titles with a backslash no longer break the Apple Music library search.

### Security and privacy
- Developer modes that use the microphone, keystrokes or other apps (`--exec`, `--listen-test`,
  `--lifecycle-test`, `--test-spotify`, the `VOX_LOG` trace) are compiled only into `./build.sh --dev` builds.
  In 1.2 any program could launch Vox with these arguments and use Vox's Microphone and Accessibility
  permissions, for example to transcribe the room into a file.
- The approximate-location lookup for weather now uses HTTPS (it went over plain HTTP); the App Transport
  Security exception is gone.
- New setting **Look up answers on the web** (Settings → General → Privacy). Questions were always sent to
  DuckDuckGo to ground answers, which the README's "nothing you say leaves the Mac" didn't mention; the docs and
  the Permissions page now say exactly what goes out, and you can keep answers fully on-device.
- AppleScript error messages (which can quote a message body or phone number) are kept private in the system log.
- Spotify credentials: a failed Keychain save is reported instead of showing "connected", and they can be removed
  (Connect Spotify… → Disconnect).

### Improved
- Swift 6 language mode: the compiler now checks the whole app for data races. The audio thread no longer reads
  listener settings that the main thread can change.
- The menu says when Microphone access is off (with a shortcut to fix it) and when another app has taken ⌥Space.
- About shows the build number.
- `./test.sh` skips (and reports) the on-device-model cases when Apple Intelligence isn't available instead of
  failing them, and runs new helper checks (`Vox --self-test`). `Vox --model-status` tells whether the model is ready.
- `./build.sh --no-install [--out DIR]` builds and signs without quitting or replacing the installed app.

## 1.2 (build 120)

First public release: hands-free "Hey Vox" and ⌥Space push-to-talk, streaming command parsing, on-device
speech and language model, Spotify / YouTube / Apple Music playback, messaging with confirmation, timers,
calendar, weather, text tools and Mac controls.
