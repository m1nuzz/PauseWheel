# PauseWheel — agent notes

Single-file AHK v2 tray app (`PauseWheel.ahk`, ~20 KB). Wheel button → Spotify-only
play/pause; no polling (event-driven `IAudioEndpointVolumeCallback`), logging OFF by default.
Deep AHK/COM field manual: `.agents/skills/ahk-v2-windows-tray/SKILL.md` — read it before
touching hooks, COM, or logging.

## Commands (PowerShell, from repo root)

- Syntax + selftest: `& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /ErrorStdOut=UTF-8 PauseWheel.ahk --selftest`
- Build x64/x32: `& 'C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe' /in PauseWheel.ahk /out PauseWheel.exe /base 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' /icon headphones.ico`
  (x32: `AutoHotkey32.exe`, out `PauseWheel_x32.exe`). Ahk2Exe lives under `Compiler\`, NOT `v2\`.
- Restart single instance: `Stop-Process -Name PauseWheel -Force`; launch detached via
  `Invoke-WmiMethod Win32_Process.Create` (returns PID); verify with
  `tasklist /FI "IMAGENAME eq PauseWheel.exe"` in a separate call.
- Release: commit + push, then `gh release create vX.Y.Z PauseWheel.exe PauseWheel_x32.exe`.
  Confirm with SHA256 local vs downloaded assets.

## Gotchas

- Always use `/ErrorStdOut=UTF-8`; without it errors are GUI popups on the user's screen.
- `Start-Process` from a harness often returns empty output even on success — verify separately.
- Never trust exe timestamps (Windows file tunneling) — byte-check binaries for new/removed strings.
- Logging is `FileAppend`-per-line; `FileOpen().WriteLine()` buffers invisibly. No `fileLog` handle pattern.
- Only ONE instance may run (hook conflict → "hook could not be activated" warning).
- Don't add `~*` hooks on all keys (trips the 70-hotkeys/2s AHK flood dialog) or any polling loop.
- `*.exe` and `*_log.txt` are gitignored; commit only `.ahk`, `.ico`, `.md`, `.agents/`.
