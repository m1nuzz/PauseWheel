; PauseWheel.ahk — AHK v2
; Wheel press (Volume_Mute, VK=0xAD) is swallowed on the keyboard hook and replayed
; as play/pause straight to the Spotify window only. System master volume is never
; touched, other media apps are never touched. 100ms debounce: autorepeat swallowed.
; Tray-only app (no console window, no taskbar button). One hook only: the
; blocking $*vkAD (wheel). Nothing else is listened to. All logging is OFF by
; default — enable with `PauseWheel.exe --log` or tray menu (Logging: OFF -> ON).
; Fallback: if a master-mute arrives via another path (HID consumer key, vendor
; driver), the event-driven IAudioEndpointVolumeCallback catches it, it is rolled
; back and the Spotify session mute is toggled instead (Spotify-hijack ON|OFF).
; Zero polling — no timers anywhere.

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
global LogStarted := false
for _arg in A_Args {
    if (_arg = "--log" || _arg = "/log") {
        LogEnabled := true
        break
    }
}

EnsureLogFile() {
    ; One-shot: recreate the file with BOM. Every Log() line is appended
    ; with FileAppend (open-write-close), so lines are always flushed to disk.
    global LogFile, LogStarted
    if (LogStarted)
        return true
    try FileDelete(LogFile)
    try {
        f := FileOpen(LogFile, "w", "UTF-8") ; "w" already emits one BOM
        f.Close()
    } catch {
        return false
    }
    LogStarted := true
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
    if (EnsureLogFile()) {
        ; Duplicate to stdout for terminal launches (FileAppend "*" works if a parent console exists)
        try FileAppend(line . "`n", "*", "UTF-8")
        catch {
        }
        try FileAppend(line . "`n", LogFile, "UTF-8")
        catch {
        }
    }
}

; --- Event path globals (must execute before --selftest, which runs top-to-bottom) ---
WM_MUTE_EVENT := 0x8001 ; WM_APP+1
WM_DEVICE_EVENT := 0x8002 ; WM_APP+2
CLSID_MMDeviceEnumerator := "{BCDE0395-E52F-467C-8E3D-C4579291692E}"
; NOTE: SDK documents ...636BEE6, but on this machine only ...63617E6 QIs
; successfully (empirically verified; thqby's Audio.ahk uses the same).
IID_IMMDeviceEnumerator := "{A95664D2-9614-4F35-A746-DE8DB63617E6}"
IID_IAudioEndpointVolume := "{5CDF2C82-841E-4546-9722-0CF74078229A}"
global evtEnum := "", evtVol := ""
global evtCbVtbl := "", evtCbObj := "", evtCbAddr := 0
global notifVtbl := "", notifObj := "", notifObjAddr := 0
global evtCallbacks := []
global evtGuidBuf := Buffer(16, 0)

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
            ; Check event-driven mute notify chain (enumerator -> default device -> endpoint volume)
            try {
                RegisterMuteNotify()
                UnregisterEndpointVolume()
                Log("SELFTEST OK: event mute-notify chain registers")
            } catch as e {
                Log("SELFTEST FAIL: event chain: " . e.Message)
            }
            try {
                if (IsObject(console))
                    console.Close()
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
    global console
    Log("Exit via tray.")
    try {
        if (IsObject(console))
            console.Close()
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

; --- Event path: IAudioEndpointVolume::RegisterControlChangeNotify. Zero polling. ---
; Master-mute arrivals invoke CbMuteNotify on an audio-service thread; the handler
; copies bMuted + guidEventContext and PostMessages WM_APP+1 to the main thread.
; IMMNotificationClient re-registers after default-device switches (WM_APP+2).
; (Constants/globals live above --selftest; they must execute before it does.)

; COM callbacks below run on foreign (audio-service RPC) threads: body is
; NumGet/NumPut + async PostMessageW only. No COM, no alloc, no I/O, no Fast mode.
CbQI(this, iid, pobj) {
    NumPut("Ptr", this, pobj, 0)
    return 0
}
CbAddRef(this) {
    return 1
}
CbRelease(this) {
    return 1
}
CbMuteNotify(this, pNotify) {
    global evtGuidBuf
    muted := NumGet(pNotify, 16, "Int")
    Loop 4
        NumPut("UInt", NumGet(pNotify, (A_Index - 1) * 4, "UInt"), evtGuidBuf, (A_Index - 1) * 4)
    DllCall("User32\PostMessageW", "Ptr", A_ScriptHwnd, "UInt", 0x8001, "Ptr", muted, "Ptr", 0)
    return 0
}
NotifStateChanged(this, devId, state) {
    return 0
}
NotifAdded(this, devId) {
    return 0
}
NotifRemoved(this, devId) {
    return 0
}
NotifDefaultChanged(this, flow, role, devId) {
    if (flow = 0) ; eRender only
        DllCall("User32\PostMessageW", "Ptr", A_ScriptHwnd, "UInt", 0x8002, "Ptr", role, "Ptr", 0)
    return 0
}
NotifPropChanged(this, devId, key) {
    return 0
}

GuidToStr(buf) {
    return Format("{:08X}-{:04X}-{:04X}-{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
        NumGet(buf, 0, "UInt"), NumGet(buf, 4, "UShort"), NumGet(buf, 6, "UShort"),
        NumGet(buf, 8, "UChar"), NumGet(buf, 9, "UChar"), NumGet(buf, 10, "UChar"),
        NumGet(buf, 11, "UChar"), NumGet(buf, 12, "UChar"), NumGet(buf, 13, "UChar"),
        NumGet(buf, 14, "UChar"), NumGet(buf, 15, "UChar"))
}

GetDeviceEnumerator() {
    global CLSID_MMDeviceEnumerator, IID_IMMDeviceEnumerator
    try
        return ComObject(CLSID_MMDeviceEnumerator, IID_IMMDeviceEnumerator)
    catch as e {
        Log("Enumerator ComObject failed (" . e.Message . "), manual CoCreateInstance")
    }
    clsidBuf := Buffer(16, 0)
    iidBuf := Buffer(16, 0)
    DllCall("Ole32\CLSIDFromString", "WStr", CLSID_MMDeviceEnumerator, "Ptr", clsidBuf)
    DllCall("Ole32\CLSIDFromString", "WStr", IID_IMMDeviceEnumerator, "Ptr", iidBuf)
    pEnum := 0
    hr := DllCall("Ole32\CoCreateInstance", "Ptr", clsidBuf.Ptr, "Ptr", 0, "UInt", 0x17, "Ptr", iidBuf.Ptr, "Ptr*", &pEnum)
    if (hr != 0 || !pEnum)
        throw Error("CoCreateInstance failed, HRESULT=" . hr)
    return ComValue(13, pEnum)
}

RegisterEndpointVolume() {
    global evtEnum, evtVol, evtCbVtbl, evtCbObj, evtCbAddr, evtCallbacks, IID_IAudioEndpointVolume
    pDev := 0
    ComCall(4, evtEnum, "Int", 0, "Int", 0, "Ptr*", &pDev) ; GetDefaultAudioEndpoint(eRender, eConsole)
    if (!pDev)
        throw Error("no default render device")
    dev := ComValue(13, pDev)
    iidBuf := Buffer(16, 0)
    DllCall("Ole32\CLSIDFromString", "WStr", IID_IAudioEndpointVolume, "Ptr", iidBuf)
    pVol := 0
    ComCall(3, dev, "Ptr", iidBuf.Ptr, "UInt", 0x17, "Ptr", 0, "Ptr*", &pVol) ; IMMDevice.Activate
    if (!pVol)
        throw Error("Activate IAudioEndpointVolume failed")
    evtVol := ComValue(13, pVol)
    if (!evtCbAddr) {
        evtCbVtbl := Buffer(4 * A_PtrSize, 0)
        vcb := [CallbackCreate(CbQI, , 3), CallbackCreate(CbAddRef, , 1), CallbackCreate(CbRelease, , 1), CallbackCreate(CbMuteNotify, , 2)]
        for a in vcb
            evtCallbacks.Push(a)
        Loop 4
            NumPut("Ptr", vcb[A_Index], evtCbVtbl, (A_Index - 1) * A_PtrSize)
        evtCbObj := Buffer(2 * A_PtrSize, 0)
        NumPut("Ptr", evtCbVtbl.Ptr, "Ptr", 0, evtCbObj, 0)
        evtCbAddr := evtCbObj.Ptr
    }
    ComCall(3, evtVol, "Ptr", evtCbAddr) ; RegisterControlChangeNotify
}

UnregisterEndpointVolume() {
    global evtVol, evtCbAddr
    if (IsObject(evtVol) && evtCbAddr) {
        try ComCall(4, evtVol, "Ptr", evtCbAddr) ; UnregisterControlChangeNotify
        catch as e {
            Log("UnregisterEndpointVolume: " . e.Message)
        }
    }
    evtVol := ""
}

RegisterMuteNotify() {
    global evtEnum, notifVtbl, notifObj, notifObjAddr, evtCallbacks
    OnMessage(0x8001, OnMuteEvent)
    OnMessage(0x8002, OnDeviceEvent)
    evtEnum := GetDeviceEnumerator()
    ; Notification client first: recovery path if the endpoint reg fails.
    notifVtbl := Buffer(8 * A_PtrSize, 0)
    ncb := [CallbackCreate(CbQI, , 3), CallbackCreate(CbAddRef, , 1), CallbackCreate(CbRelease, , 1),
        CallbackCreate(NotifStateChanged, , 3), CallbackCreate(NotifAdded, , 2),
        CallbackCreate(NotifRemoved, , 2), CallbackCreate(NotifDefaultChanged, , 4),
        CallbackCreate(NotifPropChanged, , 3)]
    for a in ncb
        evtCallbacks.Push(a)
    Loop 8
        NumPut("Ptr", ncb[A_Index], notifVtbl, (A_Index - 1) * A_PtrSize)
    notifObj := Buffer(2 * A_PtrSize, 0)
    NumPut("Ptr", notifVtbl.Ptr, "Ptr", 0, notifObj, 0)
    notifObjAddr := notifObj.Ptr
    ComCall(6, evtEnum, "Ptr", notifObjAddr) ; RegisterEndpointNotificationCallback
    RegisterEndpointVolume()
    OnExit(MuteNotifyExit)
    return true
}

ReregisterMuteNotify() {
    Log("Default device changed — re-registering mute notify")
    try UnregisterEndpointVolume()
    catch as e {
        Log("Reregister: unregister failed: " . e.Message)
    }
    try {
        RegisterEndpointVolume()
        Log("Mute notify re-registered OK")
    } catch as e {
        Log("Reregister FAILED: " . e.Message . " (will retry on next device event)")
    }
}

OnMuteEvent(wParam, lParam, msg, hwnd) {
    Critical
    global HijackSpotify, evtGuidBuf
    muted := wParam
    guid := GuidToStr(evtGuidBuf)
    Log("MUTE-EVENT muted=" . muted . " ctx=" . guid)
    if (!muted)
        return ; unmuted transitions (including our own rollback) are ignored
    if (guid != "00000000-0000-0000-0000-000000000000") {
        ; Non-NULL context = click from system UI (tray flyout/mixer), not the wheel.
        ; Leave master alone. NULL ctx = HID/wheel path -> hijack below.
        Log("UI mute (mouse click, ctx tagged) — left alone, master stays muted")
        return
    }
    if (!HijackSpotify) {
        Log("SYSTEM MUTE → MUTED (event path)")
        return
    }
    res := HijackMasterMuteToSpotify()
    if (StrLen(res) < 10) {
        ; Corruption trap: dump char codes so the next occurrence identifies itself
        codes := ""
        Loop StrLen(res)
            codes .= Format("{:04X} ", Ord(SubStr(res, A_Index, 1)))
        Log("HIJACK-RESULT-GARBLED len=" . StrLen(res) . " codes=" . codes)
    } else {
        Log(res)
    }
}

OnDeviceEvent(wParam, lParam, msg, hwnd) {
    Critical
    ReregisterMuteNotify()
}

MuteNotifyExit(exitReason, exitCode) {
    global evtEnum, evtVol, evtCbAddr, notifObjAddr, evtCallbacks
    if (IsObject(evtVol) && evtCbAddr) {
        try ComCall(4, evtVol, "Ptr", evtCbAddr)
        catch {
        }
    }
    if (IsObject(evtEnum) && notifObjAddr) {
        try ComCall(7, evtEnum, "Ptr", notifObjAddr)
        catch {
        }
    }
    for a in evtCallbacks {
        try CallbackFree(a)
        catch {
        }
    }
}

try {
    RegisterMuteNotify()
    Log("Event mute-notify registered (zero polling)")
} catch as e {
    Log("Event mute-notify FAILED: " . e.Message . " (wheel-block path still works)")
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
