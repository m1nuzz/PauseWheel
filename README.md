# PauseWheel

Wheel press (multimedia `Volume_Mute`, VK `0xAD`) → **play/pause Spotify only**.

- The key is swallowed on the low-level keyboard hook, so the Windows master
  volume is never touched and other media apps are never touched.
- The press is replayed as `WM_APPCOMMAND / APPCOMMAND_MEDIA_PLAY_PAUSE`
  posted straight to the Spotify window.
- 500 ms debounce: key autorepeat from a held wheel is swallowed.
- Tray-only app: no console window, no taskbar button.
- Fallback: if a master-mute arrives via another path (HID-consumer, AppCommand),
  it is rolled back and the Spotify audio-session mute is toggled instead
  (tray: `Spotify-hijack ON|OFF`).
- Logging is **OFF by default** (see below).

## Run

Double-click `PauseWheel.exe` (64-bit) or `PauseWheel_x32.exe` (32-bit).
Lives in the tray. Tray menu: Show/Hide console, Open log, Spotify-hijack
ON|OFF, Logging ON|OFF, Exit.

Optional: put a shortcut into `shell:startup` to launch on Windows logon.

## Logging (off by default)

When logging is off, the app writes nothing anywhere — no file, no console output.

Enable for the current run — either:

1. Command-line flag:
   ```
   PauseWheel.exe --log
   ```
2. Tray menu: right-click the tray icon → `Logging: OFF` (switches to ON).

Log file: `pausewheel_log.txt` next to the exe (UTF-8 with BOM).
`PauseWheel.exe --selftest` always logs (it is a diagnostics mode).

## Build

Requires [AutoHotkey v2](https://www.autohotkey.com/) + Ahk2Exe:

```
Ahk2Exe.exe /in PauseWheel.ahk /out PauseWheel.exe /base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" /icon headphones.ico
Ahk2Exe.exe /in PauseWheel.ahk /out PauseWheel_x32.exe /base "C:\Program Files\AutoHotkey\v2\AutoHotkey32.exe" /icon headphones.ico
```

## Files

- `PauseWheel.ahk` — the whole app (single script)
- `headphones.ico` — tray + exe icon
- `pausewheel_log.txt` — created at runtime only when logging is enabled
  (git-ignored, never committed)
