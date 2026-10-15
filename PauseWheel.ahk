; PauseWheel.ahk — AHK v2
; Wheel press (Volume_Mute, VK=0xAD) is swallowed on the keyboard hook and replayed
; as play/pause straight to the Spotify window only. System master volume is never
; touched, other media apps are never touched. 100ms debounce: autorepeat swallowed.
; Tray-only app (no console window, no taskbar button). One hook only: the
; blocking $*vkAD (wheel). Nothing else is listened to. All logging is OFF by
; default — enable with `PauseWheel.exe --log` or tray menu (Logging: OFF -> ON).
; Fallback: if a master-mute arrives via another path (HID/AppCommand), it is rolled
; back and the Spotify session mute is toggled instead (Spotify-hijack ON|OFF).

#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent(true)

; Last-resort net (Module_Errors TIER 5): uncaught exceptions go to the log
; file instead of a popup. Registered before any throwable code.
OnError(GlobalCrashHandler)
GlobalCrashHandler(err, mode) {
    try {
        f := FileOpen(A_ScriptDir . "\pausewheel_log.txt", "a", "UTF-8")
        f.WriteLine(Format("[{1}] CRASH [{2}] {3} @ {4}:{5}", FormatTime(, "HH:mm:ss"), Type(err), err.Message, err.File, err.Line))
        f.Close()
    }
    return 1 ; suppress the default AHK crash dialog
}

InstallKeybdHook()
SetTitleMatchMode(2)
A_IconTip := "PauseWheel"
if FileExist(A_ScriptDir . "\headphones.ico") {
    try TraySetIcon(A_ScriptDir . "\headphones.ico")
}

; --- No console: tray-only app. Log() writes to file/stdout only when enabled. ---
console := ""

; --- Logging is OFF by default. Enable with: PauseWheel.exe --log
; or via tray menu (Logging: OFF -> ON). When off, nothing is written anywhere.
global LogEnabled := false
global LogFile := A_ScriptDir . "\pausewheel_log.txt"
global fileLog := ""
for _arg in A_Args {
    if (_arg = "--log" || _arg = "/log") {
        LogEnabled := true
        break
    }
}

EnsureLogFile() {
    global LogFile, fileLog
    if (IsObject(fileLog))
        return true
    try FileDelete(LogFile)
    try fileLog := FileOpen(LogFile, "w", "UTF-8")
    if (!IsObject(fileLog))
        return false
    try fileLog.Write(Chr(0xFEFF)) ; BOM so Cyrillic reads correctly in notepad/powershell
    return true
}

Log(msg) {
    global console, LogEnabled
    if (!LogEnabled)
        return
    line := Format("[{1}] {2}", FormatTime(, "HH:mm:ss"), msg)
    try {
        if (IsObject(console))
            console.WriteLine(line)
    }
    try {
        if (EnsureLogFile()) {
            fileLog.WriteLine(line)
        }
    }
    ; Duplicate to stdout for terminal launches (FileAppend "*" works if a parent console exists)
    try FileAppend(line . "`n", "*", "UTF-8")
}

; --- Selftest: PauseWheel.exe --selftest ---
if (A_Args.Length > 0) {
    for arg in A_Args {
        if (arg = "--selftest" || arg = "/selftest") {
            LogEnabled := true ; selftest is diagnostics: always log
            nameAD := ""
            scAD := ""
            try nameAD := GetKeyName("vkAD")
            try scAD := GetKeySC("vkAD")
            Log("SELFTEST GetKeyName(vkAD)=" . nameAD . " SC=" . scAD)
            if (nameAD = "Volume_Mute")
                Log("SELFTEST OK: VK 0xAD = Volume_Mute")
            else
                Log("SELFTEST WARN: VK 0xAD name is not Volume_Mute, it is '" . nameAD . "'")
            ; Check that the vkAD hotkey can be registered
            try {
                Hotkey("$*vkAD", (*) => 0)
                Log("SELFTEST OK: hotkey $*vkAD registers")
            } catch as e {
                Log("SELFTEST FAIL: hotkey $*vkAD failed: " . e.Message)
            }
            ; Check system mute-state polling (effect path — works even when the event is invisible)
            try {
                m := SoundGetMute()
                Log("SELFTEST OK: SoundGetMute()=" . m)
            } catch as e {
                Log("SELFTEST FAIL: SoundGetMute threw: " . e.Message)
            }
            try {
                if (IsObject(console))
                    console.Close()
                if (IsObject(fileLog))
                    fileLog.Close()
            }
            ExitApp(0)
        }
    }
}

Log("=== PauseWheel (AHK v2): wheel press = Spotify play/pause ===")
Log("Only the wheel (Volume_Mute) is hooked. Nothing else is listened to.")
Log("Spotify-hijack is ON: Volume_Mute is blocked on the hook and replays as play/pause to Spotify only.")
Log("No taskbar button, no console — app lives in the tray.")
Log("Tray: Open pausewheel_log.txt / Spotify-hijack ON|OFF / Logging ON|OFF / Exit.")
Log("------------------------------------------------------------")

global HijackSpotify := true
global hijackLabel := "Spotify-hijack: ON"
global logLabel := LogEnabled ? "Logging: ON" : "Logging: OFF"

; --- Tray menu (headphones icon, no default AHK items) ---
A_TrayMenu.Delete()
A_TrayMenu.Add("Open pausewheel_log.txt", OpenLog)
A_TrayMenu.Add()
A_TrayMenu.Add(hijackLabel, ToggleHijack)
A_TrayMenu.Add(logLabel, ToggleLogging)
A_TrayMenu.Add()
A_TrayMenu.Add("Exit", TrayExit)
A_TrayMenu.Default := "Open pausewheel_log.txt" ; double-click opens the log

OpenLog(*) {
    global LogFile
    try Run('notepad.exe "' . LogFile . '"')
}

TrayExit(*) {
    global console, fileLog
    Log("Exit via tray.")
    try {
        if (IsObject(console))
            console.Close()
        if (IsObject(fileLog))
            fileLog.Close()
    }
    ExitApp(0)
}

ToggleHijack(*) {
    global HijackSpotify, hijackLabel
    HijackSpotify := !HijackSpotify
    newLabel := HijackSpotify ? "Spotify-hijack: ON" : "Spotify-hijack: OFF"
    try A_TrayMenu.Rename(hijackLabel, newLabel)
    hijackLabel := newLabel
    Log("Spotify-hijack " . (HijackSpotify ? "ENABLED" : "DISABLED"))
}

ToggleLogging(*) {
    global LogEnabled, logLabel
    LogEnabled := !LogEnabled
    newLabel := LogEnabled ? "Logging: ON" : "Logging: OFF"
    try A_TrayMenu.Rename(logLabel, newLabel)
    logLabel := newLabel
    Log("Logging " . (LogEnabled ? "ENABLED (pausewheel_log.txt)" : "DISABLED"))
}

; Single hook: the blocking Volume_Mute (wheel). "$" = no self-trigger on
; re-Send, no "~" = system never sees it. Nothing else is listened to.
Registered := 0
try {
    Hotkey("$*vkAD", OnMuteKey)
    Registered++
}
OnMuteKey(ThisHotkey) {
    global HijackSpotify, lastBlockToggle
    now := A_TickCount
    if (now - lastBlockToggle < 100) {
        Log("Volume_Mute repeat swallowed (debounce 100ms)")
        return
    }
    lastBlockToggle := now
    if (!HijackSpotify) {
        try Send("{Volume_Mute}") ; hijack off: pass the key through to the system
        return
    }
    Log(ToggleSpotifyPlayback())
}
lastBlockToggle := 0

Log(Format("Hotkeys registered: {1} (wheel only).", Registered))

; --- Effect path: poll the system mute state. Fires even when the event itself is invisible. ---
; If Spotify-hijack is on, a master-mute is rolled back and the Spotify session is toggled instead.
lastMute := ""
try lastMute := SoundGetMute()
SetTimer(PollMute, 100)

PollMute() {
    global lastMute, HijackSpotify
    m := ""
    try m := SoundGetMute()
    catch {
        return
    }
    if (m == lastMute)
        return
    lastMute := m
    if (!m)
        return ; unmuted transitions (including our own rollback) are ignored
    if (!HijackSpotify) {
        Log("SYSTEM MUTE STATE CHANGED → MUTED (event came as HID/AppCommand, not VK)")
        return
    }
    res := HijackMasterMuteToSpotify()
    Log(res)
}

; Proven recipe (SessProbe3/HijackTest): SoundGetInterface for IASM2 on default +
; indexed devices, raw Integer pointers straight into ComCall, wrap only outs.
; Sessions matched by GetSessionIdentifier text (IASC2 QI is E_NOINTERFACE here),
; ACTIVE or INACTIVE (paused Spotify still mutable), ISimpleAudioVolume for GetMute/SetMute. Wrappers own their refs —
; never ObjRelease a wrapped pointer (double-free = Invalid memory read/write).
ScanSpotifySessions(mgr, savs) {
    ISAV := "{87CE5498-68D6-44E5-9215-6DA47EF883D8}"
    pen := 0
    try
        ComCall(5, mgr, "Ptr*", &pen := 0)
    catch as e {
        Log("ScanSpotifySessions: GetSessionEnumerator failed: " . e.Message)
        return
    }
    if (!pen)
        return
    sessEnum := ComValue(13, pen)
    count := 0
    try
        ComCall(3, sessEnum, "UInt*", &count := 0)
    catch as e {
        Log("ScanSpotifySessions: GetCount failed: " . e.Message)
        return
    }
    Loop count {
        ps := 0
        try
            ComCall(4, sessEnum, "Int", A_Index - 1, "Ptr*", &ps := 0)
        catch as e {
            Log("ScanSpotifySessions: GetSession failed: " . e.Message)
            continue
        }
        if (!ps)
            continue
        sess := ComValue(13, ps)
        st := 0
        try
            ComCall(3, sess, "UInt*", &st := 0)
        catch as e {
            Log("ScanSpotifySessions: GetState failed: " . e.Message)
            continue
        }
        if (st > 1) ; 0=ACTIVE, 1=INACTIVE ok (paused Spotify), skip EXPIRED(2)
            continue
        pb := 0
        try
            ComCall(12, sess, "Ptr*", &pb := 0)
        catch as e {
            Log("ScanSpotifySessions: GetSessionIdentifier failed: " . e.Message)
            continue
        }
        sid := pb ? StrGet(pb, "UTF-16") : ""
        if (pb)
            DllCall("Ole32\CoTaskMemFree", "Ptr", pb) ; LPWSTR, NOT BSTR
        if (!InStr(StrLower(sid), "spotify.exe"))
            continue
        try sav := ComObjQuery(sess, ISAV)
        catch as e {
            Log("ScanSpotifySessions: ISimpleAudioVolume QI failed: " . e.Message)
            continue
        }
        savs.Push(sav)
    }
}

CollectSpotifySavs() {
    savs := []
    IASM2 := "{77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F}"
    try ScanSpotifySessions(SoundGetInterface(IASM2), savs)
    catch as e {
        Log("CollectSpotifySavs: default device failed: " . e.Message)
    }
    Loop 32 {
        try
            mgr := SoundGetInterface(IASM2, "", String(A_Index))
        catch as e {
            Log("CollectSpotifySavs: device " . A_Index . " skipped: " . e.Message)
            continue ; dead/unplugged endpoint (0x88890008) — keep scanning rest
        }
        if (!mgr)
            continue
        try ScanSpotifySessions(mgr, savs)
        catch as e {
            Log("CollectSpotifySavs: device " . A_Index . " scan failed: " . e.Message)
        }
    }
    return savs
}

; Play/pause ONLY Spotify: WM_APPCOMMAND/PLAY_PAUSE posted straight to its
; window. Master volume untouched, other media apps untouched.
WM_APPCOMMAND_MSG := 0x319
APPCOMMAND_PLAY_PAUSE := 0xE0000 ; APPCOMMAND_MEDIA_PLAY_PAUSE (14) << 16
ToggleSpotifyPlayback() {
    global WM_APPCOMMAND_MSG, APPCOMMAND_PLAY_PAUSE
    try {
        PostMessage(WM_APPCOMMAND_MSG, 0, APPCOMMAND_PLAY_PAUSE, , "ahk_exe Spotify.exe")
        return "Wheel-block: play/pause sent to Spotify only, master untouched"
    } catch as e {
        return "Wheel-block: Spotify window not found (" . e.Message . "), session-mute fallback: " . ToggleSpotifyDirect()
    }
}

; Shared mute-flip: read current Spotify session mute, apply the opposite to
; every collected session. Returns 1 if Spotify is now MUTED, 0 if UNMUTED.
FlipSpotifyMute(savs) {
    cur := 0
    ComCall(6, savs[1], "Int*", &cur := 0)
    target := cur ? 0 : 1
    for sav in savs {
        try ComCall(5, sav, "Int", target, "Ptr", 0)
    }
    return target
}

; Direct Spotify toggle for the blocking OnMuteKey path: master is never
; touched (the key never reaches the system), so no rollback is needed.
ToggleSpotifyDirect() {
    savs := CollectSpotifySavs()
    if (savs.Length = 0)
        return "Wheel-block: key swallowed, but Spotify has no audio session (not playing?). Nothing muted."
    try {
        target := FlipSpotifyMute(savs)
        return "Wheel-block: system master untouched → Spotify " . (target ? "MUTED" : "UNMUTED")
    } catch as e {
        return "Wheel-block apply failed: " . e.Message
    }
}

HijackMasterMuteToSpotify() {
    savs := CollectSpotifySavs()
    if (savs.Length = 0)
        return "SYSTEM MUTE → MUTED. Hijack skipped: Spotify has no audio session (not playing?). Master left muted."
    try {
        target := FlipSpotifyMute(savs)
        try SoundSetMute(false) ; roll back the system-wide mute
        return "Wheel-hijack: system master restored → Spotify " . (target ? "MUTED" : "UNMUTED")
    } catch as e {
        return "SYSTEM MUTE → MUTED. Hijack STAGE3 apply: " . e.Message
    }
}

Log("Waiting for wheel press...")

; Exit is via tray menu.
