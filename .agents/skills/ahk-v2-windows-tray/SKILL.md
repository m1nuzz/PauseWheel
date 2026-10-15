---
name: ahk-v2-windows-tray
description: Build and debug AutoHotkey v2 tray-only Windows apps that use low-level hooks, Core Audio COM (per-app mute, endpoint notifications), and Ahk2Exe releases. Use when writing, fixing, or shipping AHK v2 scripts with hotkeys, SoundGetInterface/ComCall/COM callbacks, or GitHub releases of compiled exes.
---

# AHK v2 Windows Tray Apps — field manual

Distilled from shipping PauseWheel (wheel-button → Spotify-only play/pause) and from
TrueCrimeDev/ClautoHotkey (`Modules/Module_Errors.md`, `Module_Instructions.md`).
Assumes AutoHotkey v2.0+, Ahk2Exe at `C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe`
(not under `v2\` — that path fails silently and leaves stale exes).

## 1. Running scripts without popups

- Always run probes as `AutoHotkey64.exe /ErrorStdOut=UTF-8 script.ahk [args] > out.log 2>&1`.
  Without it, every error is a GUI popup on the user's screen.
- `FileAppend(x, "*")` writes to stdout. Under `>` redirect or detached launch
  (WMI, `cmd /c start`) there is no valid stdout handle → error 6 "handle is invalid".
  Never rely on `*` in production code paths; guard with try or log to file.
- `Start-Process` from a harness shell often returns empty output even on success.
  Verify with `tasklist /FI "IMAGENAME eq X.exe"` in a SEPARATE call, or use
  `Invoke-WmiMethod Win32_Process.Create` which returns the PID.
- When filtering processes, match the real image name: an interpreter run is
  `AutoHotkey64.exe`, not your script name.

## 2. ComCall / COM rules that actually matter

- `SoundGetInterface(IID[, Component, Device])` returns a raw Integer pointer.
  Pass it STRAIGHT into `ComCall`. Wrap only OUT params: `ComValue(13, ptr)`.
  Wrapping the manager itself in ComValue before ComCall → `Invalid return type`.
- Every `ComCall` arg needs an explicit type string: `ComCall(5, mgr, "Ptr*", &out)`.
  Bare `&var` without a type is the `Invalid return type` bug.
- Never `ObjRelease()` a pointer you wrapped in `ComValue` (double-free →
  `Invalid memory read/write`). The wrapper releases on scope exit.
- `Component` (2nd param) is a mixer sub-part, NOT a device. Device = 3rd param,
  1-based index over all endpoints (render + capture + unplugged) or name.
  Dead endpoints throw `0x88890008 AUDCLNT_E_DEVICE_INVALIDATED` → try/catch + continue.
- `GetSessionEnumerator`=5, `GetCount`=3, `GetSession`=4 on the session manager.
  `GetProcessId`=14 needs `IAudioSessionControl2`; `GetMute`=6 / `SetMute`=5 need
  `ISimpleAudioVolume`. `GetState`=3, `GetDisplayName`=4, `GetSessionIdentifier`=12
  work on the base `IAudioSessionControl` with no QI at all.
- QI-ing the session MANAGER for session interfaces correctly returns
  `E_NOINTERFACE` — that is expected, not a bug. Only QI objects from `GetSession`.
- `CLSIDFromString` needs `"WStr"` + a 16-byte `Buffer`. Passing GUID text to
  `CoCreateInstance`/`Activate` directly is the classic `E_NOINTERFACE`.
- Empirical: on some machines the SDK-correct enumerator IID (`…BEE6`) fails while
  the widely-copied `…17E6` variant works (and vice versa). If one gives
  `E_NOINTERFACE`, try the other before assuming the class is broken.
- `GetDisplayName`/`GetSessionIdentifier` return CoTaskMem LPWSTR → free with
  `CoTaskMemFree`, NOT `SysFreeString` (silent crash otherwise).
- BSTR vs LPWSTR, `StrGet(ptr, "UTF-16")`, then free. Getting this wrong corrupts logs.

## 3. COM callbacks from foreign threads (endpoint volume, notifications)

- Hand-roll the vtable: `Buffer(nSlots*A_PtrSize)` of `CallbackCreate` addresses,
  object = `[lpVtbl, userCtx]`. Keep buffers and callback addresses in globals;
  `CallbackFree` only at exit, after unregister.
- NEVER `"F"` (Fast) mode for system-invoked callbacks — the calling thread varies.
- Callback body must be 2 lines: `NumGet` the fields + async `PostMessageW`
  via DllCall to `A_ScriptHwnd`. NOTHING else: no `ComCall`, no objects/arrays,
  no file I/O, no `SendMessage`, no unregister. MS forbids blocking/waiting here.
- Main-thread handler: `Critical` as first line, `OnMessage(0x8001/0x8002)` —
  `WM_APP` range (`0x8000+`), never `WM_USER`.
- `AUDIO_VOLUME_NOTIFICATION_DATA`: `bMuted` int@16, `fMasterVolume` float@20,
  `nChannels` uint@24. Offsets identical on x86/x64.
- `guidEventContext` is NULL for your own `SoundSetMute` calls AND for HID/foreign
  mutes — useless for self-filtering. Filter on DIRECTION (`muted==1` only) instead.
  Conversely, a NON-NULL context marks system-UI (mouse-click) changes — usable to
  EXCLUDE UI-initiated mutes. The UI GUID is undocumented: capture it empirically
  (one logging run, click vs key) and match `00000000-0000-0000-0000-000000000000`
  vs non-NULL rather than hardcoding a GUID list.
- Endpoint callbacks are per-device: on `OnDefaultDeviceChanged` (flow==0 render)
  re-register (unregister old → GetDefault → Activate → register). Never
  register/unregister INSIDE the callback — post a message and do it on main thread.
- Backstop: keep a slow safety poll (2–5 s) even with events. Silent deafness after
  device switches is only observable by a second observer; the poll self-heals it.

## 4. Hotkeys and hooks

- One blocking hook: `Hotkey("$*vkAD", Fn)` — `$` stops self-trigger on re-Send,
  no `~` means the system never sees the key. Hijack-off mode re-sends explicitly.
- Never register `~*` hooks on all 256 VKs in production: any burst over
  `A_MaxHotkeysPerInterval` (70/2 s) pops the "71 hotkeys received" dialog.
- Debounce on press timestamp (`A_TickCount - last < N`), not a timer. 100 ms kills
  autorepeat (~30 ms) while allowing fast double-press; 20 ms lets repeats through.
- Two instances racing for one hook → "hook could not be activated" warning.
  Always `Stop-Process` before start; verify exactly ONE instance in tasklist.
- `#SingleInstance Force` + `Persistent(true)` are mandatory headers.

## 5. Logging that survives production

- `FileOpen(path, "a").WriteLine()` BUFFERs — lines stay invisible until flush/close.
  (A prior "cleanup" removed the accidental flush and logs went dark for hours.)
  Use `FileAppend(line, path, "UTF-8")` per line (open-write-close), or flush.
- `FileOpen(path, "w", "UTF-8")` already emits a BOM — don't prepend another one.
- Default logging OFF: early-return before any write (no file created, no console,
  no stdout). `--log` flag + tray toggle, selftest forces logging on.
- Concurrent writes from a message handler can tear a line (seen twice, same spot):
  keep handler-emitted lines short, and add a garble-trap that dumps char codes.

## 6. Build / release / verify loop

- `#Requires AutoHotkey v2.0` as line 1 — wrong interpreter fails fast, not weird.
- `OnError(GlobalHandler)` writing `CRASH <msg> @ <line>` to the log + `return 1`.
- Rebuild BOTH: `/base AutoHotkey64.exe` and `/base AutoHotkey32.exe`, `/icon icon.ico`.
- Windows file tunneling preserves timestamps on fast rebuilds — NEVER trust dates.
  Verify with byte search: new strings present, removed strings absent.
- Icon pipeline: PIL `convert("RGBA")` → recolor preserving alpha →
  `save(".ico", sizes=[(16,16),(32,32),(48,48),(256,256)])`.
- Selftest mode (`--selftest`): vk identity, hotkey registration, SoundGetMute,
  event-chain registration — must exit 0 and prove each subsystem. Keep it above
  COM init so it never leaks callbacks.
- Single instance running, commit, push, `gh release create vX.Y.Z exe1 exe2 --notes`.
  Confirm release integrity by comparing SHA256 of local exes vs downloaded assets.

## 7. Debugging checklist (in order)

1. `/ErrorStdOut` run — read the actual error, not the popup description.
2. `tasklist` — exactly one instance? Right image name?
3. Byte-check the binary — is the NEW code actually inside?
4. Log file present and growing? (Flush bug if BOM-only.)
5. Selftest green? Then live-trip with an external mute and read the log.
6. Races: async handlers mean a state read 100 ms later can differ — re-read before concluding.
