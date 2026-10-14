; PauseWheel.ahk — AHK v2
; Wheel press (Volume_Mute, VK=0xAD) is swallowed on the keyboard hook and replayed
; as play/pause straight to the Spotify window only. System master volume is never
; touched, other media apps are never touched. 100ms debounce: autorepeat swallowed.
; Tray-only app (no console window, no taskbar button). All logging is OFF by
; default — enable with `PauseWheel.exe --log` or tray menu (Logging: OFF -> ON).
; Fallback: if a master-mute arrives via another path (HID/AppCommand), it is rolled
; back and the Spotify session mute is toggled instead (Spotify-hijack ON|OFF).

#SingleInstance Force
Persistent(true)
InstallKeybdHook()
InstallMouseHook()
SetTitleMatchMode(2)
A_IconTip := "PauseWheel — wheel = Spotify play/pause"
if FileExist(A_ScriptDir . "\headphones.ico") {
    try TraySetIcon(A_ScriptDir . "\headphones.ico")
}

; --- Console: attach to parent or create a new one ---
Attached := DllCall("kernel32\AttachConsole", "UInt", 0xFFFFFFFF) ; ATTACH_PARENT_PROCESS
if (!Attached)
    DllCall("kernel32\AllocConsole", "UInt")
try DllCall("kernel32\SetConsoleOutputCP", "UInt", 65001) ; UTF-8 so Cyrillic key names display correctly
; Reopen CONOUT$ after Attach/Alloc
console := FileOpen("CONOUT$", "w", "UTF-8")
if (!IsObject(console)) {
    MsgBox("Could not open CONOUT$ console. Log will be written to pausewheel_log.txt next to the exe.", "PauseWheel", 0x40)
}

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
            fileLog.Read(0) ; no-op, keep handle alive
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
            ; Check RawInput HID consumer registration (wheel path that bypasses the keyboard hook)
            try {
                dev := Buffer(16, 0)
                NumPut("UShort", 0x0C, dev, 0)
                NumPut("UShort", 0x01, dev, 2)
                NumPut("UInt", 0x100, dev, 4)
                NumPut("Ptr", A_ScriptHwnd, dev, 8)
                ok := DllCall("user32\RegisterRawInputDevices", "Ptr", dev, "UInt", 1, "UInt", 16)
                Log("SELFTEST RawInput HID consumer register: " . (ok ? "OK" : "FAIL err=" . A_LastError))
            } catch as e {
                Log("SELFTEST FAIL: RawInput register threw: " . e.Message)
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
Log("Press keys / the wheel. Log goes here + pausewheel_log.txt")
Log("NOTE: keyboard wheels often send HID-consumer (Mute=0xE2), NOT a VK key.")
Log("So a wheel press may show NO 'PRESSED' line — watch for HID-INPUT / APPCOMMAND / MUTE STATE lines instead.")
Log("Spotify-hijack is ON: Volume_Mute is blocked on the hook and replays as play/pause to Spotify only.")
Log("No taskbar button — app lives in the tray (headphones icon).")
Log("Tray: Show console / Hide console / Open pausewheel_log.txt / Spotify-hijack ON|OFF / Logging ON|OFF / Exit.")
Log("------------------------------------------------------------")

global HijackSpotify := true
global hijackLabel := "Spotify-hijack: ON"
global logLabel := LogEnabled ? "Logging: ON" : "Logging: OFF"

; --- Hide console from taskbar (tool window), keep it visible. Tray-only app. ---
; Only when we created our own console. If attached to a parent terminal, leave it alone.
consoleHwnd := 0
if (!Attached) {
    consoleHwnd := DllCall("kernel32\GetConsoleWindow", "ptr")
    if (consoleHwnd) {
        try {
            GWL_EXSTYLE := -20
            exStyle := DllCall("user32\GetWindowLongPtrW", "ptr", consoleHwnd, "int", GWL_EXSTYLE, "ptr")
            DllCall("user32\SetWindowLongPtrW", "ptr", consoleHwnd, "int", GWL_EXSTYLE, "ptr", (exStyle | 0x80) & ~0x40000)
            DllCall("user32\SetWindowPos", "ptr", consoleHwnd, "ptr", 0, "int", 0, "int", 0, "int", 0, "int", 0, "uint", 0x27)
            DllCall("user32\ShowWindow", "ptr", consoleHwnd, "int", 0) ; SW_HIDE: start clean in tray
        }
    }
}

; --- Tray menu (headphones icon, no default AHK items) ---
A_TrayMenu.Delete()
A_TrayMenu.Add("Show console", ShowConsole)
A_TrayMenu.Add("Hide console", HideConsole)
A_TrayMenu.Add()
A_TrayMenu.Add("Open pausewheel_log.txt", OpenLog)
A_TrayMenu.Add()
A_TrayMenu.Add(hijackLabel, ToggleHijack)
A_TrayMenu.Add(logLabel, ToggleLogging)
A_TrayMenu.Add()
A_TrayMenu.Add("Exit", TrayExit)
A_TrayMenu.Default := "Show console"

ShowConsole(*) {
    global consoleHwnd
    if (consoleHwnd) {
        try DllCall("user32\ShowWindow", "ptr", consoleHwnd, "int", 5)
    } else {
        Log("No own console window (started from terminal).")
    }
}

HideConsole(*) {
    global consoleHwnd
    if (consoleHwnd)
        try DllCall("user32\ShowWindow", "ptr", consoleHwnd, "int", 0)
}

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

; Highlights for important keys
Highlight := Map(
    0xAD, ">>> THIS IS Volume_Mute (wheel in office mode / multimedia Mute) <<<",
    0xAE, ">>> Volume_Down <<<",
    0xAF, ">>> Volume_Up <<<",
    0x04, ">>> MButton (middle mouse click / wheel press as a button) <<<",
    0xB3, ">>> Media_Play_Pause <<<",
    0xB0, ">>> Media_Next <<<",
    0xB1, ">>> Media_Prev <<<",
    0xB2, ">>> Media_Stop <<<"
)

OnKeyPress(ThisHotkey) {
    global Highlight
    ; ThisHotkey looks like "~*vkAD" — extract hex
    vkHex := ""
    if (RegExMatch(ThisHotkey, "i)vk([0-9A-F]{2,4})", &m))
        vkHex := m[1]
    vk := vkHex != "" ? Integer("0x" . vkHex) : -1
    name := ""
    sc := ""
    scHex := "?"
    try name := GetKeyName("vk" . vkHex)
    try sc := GetKeySC("vk" . vkHex)
    if (sc != "") {
        try scHex := Format("0x{:03X} ({})", sc, sc)
    }
    if (name = "")
        name := "(no name)"
    line := Format("PRESSED  {1}  | VK=0x{2:02X} ({2}) | SC={3} | Hotkey={4}", name, vk, scHex, ThisHotkey)
    Log(line)
    if (Highlight.Has(vk))
        Log(Highlight[vk])
}

; Register hotkeys for the full VK range (keyboard).
; Ignore errors (some VKs are reserved).
; 0xAD (Volume_Mute) is registered separately below WITHOUT "~": the key is
; swallowed on the hook so Windows never mutes master (no 1-sec blip) and we
; toggle the Spotify session directly in OnMuteKey.
Registered := 0
Loop 256 {
    vk := A_Index - 1
    if (vk = 0x00 || vk = 0xAD)
        continue
    vkHex := Format("{:02X}", vk)
    try {
        Hotkey("~*vk" . vkHex, OnKeyPress)
        Registered++
    }
}

; Blocking Volume_Mute handler: "$" = no self-trigger on re-Send, no "~" = system never sees it.
try {
    Hotkey("$*vkAD", OnMuteKey)
    Registered++
}
OnMuteKey(ThisHotkey) {
    global HijackSpotify, lastBlockToggle
    OnKeyPress(ThisHotkey) ; same PRESSED log line as other keys
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

; Mouse separately (in case the wheel sends MButton instead of Volume_Mute)
try Hotkey("~*MButton", (*) => (Log("PRESSED  MButton (middle click) | VK=0x04 (4)"), Log(Highlight[0x04])))
try Hotkey("~*XButton1", (*) => Log("PRESSED  XButton1 (side button 1)"))
try Hotkey("~*XButton2", (*) => Log("PRESSED  XButton2 (side button 2)"))
try Hotkey("~*WheelUp", (*) => Log("Wheel up (WheelUp)"))
try Hotkey("~*WheelDown", (*) => Log("Wheel down (WheelDown)"))

Log(Format("Hotkeys registered: {1}. Focus does not matter — hook is global.", Registered))

; --- HID consumer path: many keyboards send wheel press as HID (usage page 0x0C), ---
; --- which never reaches the low-level keyboard hook. RawInput with INPUTSINK sees it. ---
try {
    hidDev := Buffer(16, 0)
    NumPut("UShort", 0x0C, hidDev, 0) ; usage page: Consumer
    NumPut("UShort", 0x01, hidDev, 2) ; usage: Consumer Control
    NumPut("UInt", 0x100, hidDev, 4)  ; RIDEV_INPUTSINK: receive even when not focused
    NumPut("Ptr", A_ScriptHwnd, hidDev, 8)
    hidOk := DllCall("user32\RegisterRawInputDevices", "Ptr", hidDev, "UInt", 1, "UInt", 16)
    Log("RawInput HID consumer listener: " . (hidOk ? "OK (watch for HID-INPUT lines)" : "FAIL err=" . A_LastError))
} catch as e {
    Log("RawInput HID consumer listener: EXCEPTION " . e.Message)
}
OnMessage(0xFF, WM_INPUT)

WM_INPUT(wParam, lParam, msg, hwnd) {
    size := 0
    DllCall("user32\GetRawInputData", "Ptr", lParam, "UInt", 0, "Ptr", 0, "Ptr*", &size, "UInt", 16)
    if (!size)
        return 0
    buf := Buffer(size, 0)
    got := DllCall("user32\GetRawInputData", "Ptr", lParam, "UInt", 0, "Ptr", buf, "Ptr*", &size, "UInt", 16)
    if (got != size || size < 33)
        return 0
    if (NumGet(buf, 0, "UInt") != 2) ; 0=mouse, 1=keyboard (covered by hooks), 2=HID
        return 0
    dcount := NumGet(buf, 24, "UInt")
    dsize := NumGet(buf, 28, "UInt")
    hex := ""
    n := dsize > 64 ? 64 : dsize
    Loop n
        hex .= Format("{:02X} ", NumGet(buf, 32 + A_Index - 1, "UChar"))
    if (dsize > 64)
        hex .= "..."
    hdev := NumGet(buf, 8, "Ptr")
    Log(Format("HID-INPUT  dev=0x{:X} count={} size={} data=[ {}]", hdev, dcount, dsize, hex))
    Log("^^^ HID event above — keyboard wheels/mute keys arrive here, NOT as VK (HID consumer page 0x0C).")
    return 0
}

; --- WM_APPCOMMAND path (best effort): multimedia keys also arrive as 0x319 to the foreground window ---
AppCmdNames := Map(8, "VOLUME_MUTE", 9, "VOLUME_DOWN", 10, "VOLUME_UP",
    11, "MEDIA_NEXTTRACK", 12, "MEDIA_PREVIOUSTRACK", 13, "MEDIA_STOP", 14, "MEDIA_PLAY_PAUSE",
    25, "MIC_VOLUME_MUTE", 26, "MIC_VOLUME_DOWN", 27, "MIC_VOLUME_UP")
OnMessage(0x319, WM_APPCOMMAND)

WM_APPCOMMAND(wParam, lParam, msg, hwnd) {
    global AppCmdNames
    cmd := (lParam >> 16) & 0x0FFF
    name := AppCmdNames.Has(cmd) ? AppCmdNames[cmd] : "APPCOMMAND_" . cmd
    Log(Format("APPCOMMAND  {} (code {})", name, cmd))
    if (cmd = 8)
        Log(">>> THIS IS APPCOMMAND_VOLUME_MUTE — your wheel press arrived via AppCommand path <<<")
    return 0 ; do not block, let the system handle it
}

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
    catch {
        return
    }
    if (!pen)
        return
    sessEnum := ComValue(13, pen)
    count := 0
    try
        ComCall(3, sessEnum, "UInt*", &count := 0)
    catch {
        return
    }
    Loop count {
        ps := 0
        try
            ComCall(4, sessEnum, "Int", A_Index - 1, "Ptr*", &ps := 0)
        catch {
            continue
        }
        if (!ps)
            continue
        sess := ComValue(13, ps)
        st := 0
        try
            ComCall(3, sess, "UInt*", &st := 0)
        catch {
            continue
        }
        if (st > 1) ; 0=ACTIVE, 1=INACTIVE ok (paused Spotify), skip EXPIRED(2)
            continue
        pb := 0
        try
            ComCall(12, sess, "Ptr*", &pb := 0)
        catch {
            continue
        }
        sid := pb ? StrGet(pb, "UTF-16") : ""
        if (pb)
            DllCall("Ole32\CoTaskMemFree", "Ptr", pb) ; LPWSTR, NOT BSTR
        if (!InStr(StrLower(sid), "spotify.exe"))
            continue
        try sav := ComObjQuery(sess, ISAV)
        catch {
            continue
        }
        savs.Push(sav)
    }
}

CollectSpotifySavs() {
    savs := []
    IASM2 := "{77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F}"
    try ScanSpotifySessions(SoundGetInterface(IASM2), savs)
    catch {
    }
    Loop 32 {
        try
            mgr := SoundGetInterface(IASM2, "", String(A_Index))
        catch {
            continue ; dead/unplugged endpoint (0x88890008) — keep scanning rest
        }
        if (!mgr)
            continue
        try ScanSpotifySessions(mgr, savs)
        catch {
        }
    }
    return savs
}

; Play/pause ONLY Spotify: WM_APPCOMMAND/PLAY_PAUSE posted straight to its
; window. Master volume untouched, other media apps untouched.
ToggleSpotifyPlayback() {
    try {
        PostMessage(0x319, 0, 0xE0000, , "ahk_exe Spotify.exe") ; APPCOMMAND_MEDIA_PLAY_PAUSE = 14 << 16
        return "Wheel-block: play/pause sent to Spotify only, master untouched"
    } catch as e {
        return "Wheel-block: Spotify window not found (" . e.Message . "), session-mute fallback: " . ToggleSpotifyDirect()
    }
}

; Direct Spotify toggle for the blocking OnMuteKey path: master is never
; touched (the key never reaches the system), so no rollback is needed.
ToggleSpotifyDirect() {
    savs := CollectSpotifySavs()
    if (savs.Length = 0)
        return "Wheel-block: key swallowed, but Spotify has no audio session (not playing?). Nothing muted."
    try {
        cur := 0
        ComCall(6, savs[1], "Int*", &cur := 0)
        target := cur ? 0 : 1
        for sav in savs {
            try ComCall(5, sav, "Int", target, "Ptr", 0)
        }
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
        cur := 0
        ComCall(6, savs[1], "Int*", &cur := 0)
        target := cur ? 0 : 1
        for sav in savs {
            try ComCall(5, sav, "Int", target, "Ptr", 0)
        }
        try SoundSetMute(false) ; roll back the system-wide mute
        return "Wheel-hijack: system master restored → Spotify " . (target ? "MUTED" : "UNMUTED")
    } catch as e {
        return "SYSTEM MUTE → MUTED. Hijack STAGE3 apply: " . e.Message
    }
}

Log("Waiting for wheel press...")

; Esc hides the console, but only when the console is focused (pass-through everywhere else).
; Exit is via tray menu. Esc itself is also logged as VK=0x1B, that is normal.
~Esc:: {
    global consoleHwnd
    if (consoleHwnd && WinActive("ahk_id " . consoleHwnd)) {
        try DllCall("user32\ShowWindow", "ptr", consoleHwnd, "int", 0)
        Log("Console hidden (tray icon > Show console to bring back).")
    }
}

; Do not close via console X button — that kills the process. Use Hide / tray Exit, log file remains.
