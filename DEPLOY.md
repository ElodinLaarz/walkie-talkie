# DEPLOY — build app, throw on phones, watch logs

Caveman runbook. Two-phone radio test. Windows host + WSL Debian (flutter live there, not Windows PATH).

## Need first

- WSL Debian. flutter inside (`/home/elodin/.local/flutter/bin/flutter`).
- Windows `adb` on PATH.
- Two real phones, USB debug on. Radio test need real BLE — emulator no good.

## Gotcha #1 — opus submodule (THIS break build)

`android/app/src/main/cpp/opus` = git **submodule** (gitlab.xiph.org, pinned `c6f8d82`). Fresh clone / fresh worktree = opus empty. cmake configure die:

```
add_subdirectory given source "opus" which is not an existing directory
Process 'cmake' finished with non-zero exit value 1
```

Fix — init submodule:

```bash
git submodule update --init android/app/src/main/cpp/opus
```

**Run with Windows git, NOT WSL git.** Worktree `.git` point at `C:/...` gitdir. WSL try resolve `C:/...` under `/mnt/...` → `fatal: not a git repository`. So submodule init from PowerShell / Windows shell.

## Gotcha #2 — path split brain

- WSL build = `/mnt/c/...` path. Works only in WSL, NOT git-bash.
- git-bash / Windows tool = `C:/...` or `/c/...`. NOT `/mnt/c`.
- git command on worktree = Windows git only (gitdir = `C:/...`).

Mix wrong = silent `cd: no such file` → `&&` chain die → command no-op. Check it run.

## Gotcha #3 — flutter exit code hide

`flutter build apk | tail` give exit 0 even when build FAIL (pipe return tail status). Redirect to file, read tail:

```bash
flutter build apk --profile > build.log 2>&1   # last cmd = real exit
```

## Build (WSL)

```bash
cd /mnt/c/Users/<you>/.../walkie-talkie     # worktree root
mkdir -p logs
rm -rf android/app/.cxx                      # nuke stale cmake cache
flutter build apk --profile > logs/build.log 2>&1
# out: build/app/outputs/flutter-apk/app-profile.apk
```

Profile build = good logs + near-release speed.

## Install (Windows adb, both phones)

```bash
APK="C:/Users/<you>/.../build/app/outputs/flutter-apk/app-profile.apk"
adb -s <serialA> install -r "$APK"
adb -s <serialB> install -r "$APK"
```

`-r` = reinstall, keep data. Signature clash → `adb uninstall com.elodin.walkie_talkie` first.

## Logs — app only, no OS spam

Raw logcat = flood (WifiHAL, SELinux denial, etc). Filter to app tags:

```bash
adb -s <serial> logcat -c                    # clear first
adb -s <serial> shell monkey -p com.elodin.walkie_talkie -c android.intent.category.LAUNCHER 1
adb -s <serial> logcat -v time \
  MainActivity:V GattServerManager:V GattClientManager:V \
  L2capVoiceTransport:V HostAdvertiser:V WalkieTalkieService:V flutter:V '*:S'
```

Tag filter survive app restart (host↔guest toggle). `--pid` no good — break on restart.

## Watch for (blocker signal)

- `drop talking ... seq N <= watermark M` — voice frame drop, seq/watermark logic.
- `GATT connected` / `GATT disconnected` — control plane.
- `L2CAP client connected` / `L2CAP server listening on PSM 0x..` — voice plane up.
- `Advertising started` / fail — host discoverable.
- any `E/flutter` / `FATAL` / `Exception` — crash.
