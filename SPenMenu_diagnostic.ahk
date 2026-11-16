#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
; ============================================================
;  S Pen Menu - pen button diagnostic
;  Use this if the pen's side button isn't detected.
;  1. Close S Pen Menu (tray icon > Exit).  2. Run this.
;  3. Hover the pen just above the screen (not touching) and press the side button a few times.
;  4. Look for the name that appears only while the button is down, e.g. Invert(D/3C) or BARREL(D/44).
;     Put the part after "/" into SPenMenu_settings.ini > [Pen] ButtonUsages, e.g. 0x3C
;     (for a page other than D, write page:usage, e.g. 0xFF00:0x01).
;  Logs keyboard keys, mouse buttons and raw pen button signals. Pen movement is ignored.
; ============================================================

; ---------- window ----------
g := Gui("+AlwaysOnTop +Resize", "S Pen Menu diagnostic - hover the pen and press its side button")
g.SetFont("s9", "Consolas")
logBox := g.AddEdit("w760 h440 ReadOnly -Wrap +HScroll")
g.AddButton("w120", "Copy log").OnEvent("Click", CopyLog)
g.AddButton("x+10 w120", "Clear").OnEvent("Click", (*) => logBox.Value := "")
g.OnEvent("Close", (*) => ExitApp())
g.Show()

CopyLog(*) {
    A_Clipboard := logBox.Value
    ToolTip("Log copied")
    SetTimer(() => ToolTip(), -1500)
}

Log(msg) {
    logBox.Value .= FormatTime(, "HH:mm:ss") "." Format("{:03}", A_MSec) "  " msg "`r`n"
    SendMessage(0x0115, 7, 0, logBox)   ; scroll to bottom
}

Log("AHK " A_AhkVersion "  |  " A_OSVersion "  |  " (A_PtrSize = 8 ? "64" : "32") "-bit")

; ---------- 1) keyboard ----------
ih := InputHook("V L0")
ih.KeyOpt("{All}", "N")
ih.OnKeyDown := (ih, vk, sc) => Log(Format("KEY   down  {:-12} vk={:02X} sc={:03X}", GetKeyName(Format("vk{:x}sc{:x}", vk, sc)), vk, sc))
ih.OnKeyUp   := (ih, vk, sc) => Log(Format("KEY   up    {:-12} vk={:02X} sc={:03X}", GetKeyName(Format("vk{:x}sc{:x}", vk, sc)), vk, sc))
ih.Start()

; ---------- 2) mouse buttons via low-level hook (tells pen vs mouse) ----------
global gMouseCb := CallbackCreate(MouseProc, , 3)
global gMouseHook := DllCall("SetWindowsHookEx", "Int", 14, "Ptr", gMouseCb
    , "Ptr", DllCall("GetModuleHandle", "Ptr", 0, "Ptr"), "UInt", 0, "Ptr")
Log(gMouseHook ? "Mouse hook: OK" : "Mouse hook: FAILED")

MouseProc(nCode, wParam, lParam) {
    static names := Map(0x201, "LButton down", 0x204, "RButton down", 0x207, "MButton down"
        , 0x20B, "XButton down", 0x20A, "Wheel", 0x20E, "HWheel", 0x205, "RButton up")
    if (nCode & 0xFFFFFFFF) = 0 && names.Has(wParam) {
        e := NumGet(lParam, A_PtrSize = 8 ? 24 : 20, "UPtr") & 0xFFFFFFFF
        src := (e & 0xFFFFFF00) = 0xFF515700 ? ((e & 0x80) ? "TOUCH" : "PEN") : "mouse"
        SetTimer(Log.Bind(Format("MOUSE {:-14} src={:-5} extra={:08X}", names[wParam], src, e)), -1)
    }
    return DllCall("CallNextHookEx", "Ptr", 0, "Int", nCode, "UPtr", wParam, "Ptr", lParam, "Ptr")
}

; ---------- 3) raw HID (pen / digitizer / consumer / vendor) ----------
OnMessage(0x00FF, OnRawInput)   ; WM_INPUT
for page in [0x0D, 0x0C, 0xFF00]
    RegisterPage(page)

RegisterPage(page) {
    rid := Buffer(8 + A_PtrSize, 0)
    NumPut("UShort", page, rid, 0)
    NumPut("UShort", 0, rid, 2)
    NumPut("UInt", 0x100 | 0x20, rid, 4)       ; RIDEV_INPUTSINK | RIDEV_PAGEONLY
    NumPut("Ptr", g.Hwnd, rid, 8)
    ok := DllCall("RegisterRawInputDevices", "Ptr", rid, "UInt", 1, "UInt", rid.Size)
    Log(Format("Raw input page {:02X}: {}", page, ok ? "OK" : "FAILED (err " A_LastError ")"))
}

OnRawInput(wParam, lParam, msg, hwnd) {
    static hdr := 8 + 2 * A_PtrSize
    static last := Map(), badStatus := Map()
    static list := Buffer(4 * 64)
    size := 0
    DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", 0, "UInt*", &size, "UInt", hdr)
    if !size
        return
    buf := Buffer(size)
    if DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", buf, "UInt*", &size, "UInt", hdr, "Int") <= 0
        return
    if NumGet(buf, 0, "UInt") != 2              ; RIM_TYPEHID only
        return
    hDev := NumGet(buf, 8, "Ptr")
    repSize := NumGet(buf, hdr, "UInt"), count := NumGet(buf, hdr + 4, "UInt")
    pp := Preparsed(hDev)
    loop count {
        rep := buf.Ptr + hdr + 8 + (A_Index - 1) * repSize
        len := 64
        st := DllCall("hid\HidP_GetUsagesEx", "Int", 0, "UShort", 0, "Ptr", list, "UInt*", &len
            , "Ptr", pp, "Ptr", rep, "UInt", repSize, "UInt")
        if st != 0x110000 {
            if !badStatus.Has(hDev) {
                badStatus[hDev] := 1
                Log(Format("HID   {}  (status {:08X}) raw: {}", DevInfo(hDev), st, Hex(rep, repSize)))
            }
            continue
        }
        s := ""
        loop len
            s .= UsageName(NumGet(list, (A_Index - 1) * 4 + 2, "UShort"), NumGet(list, (A_Index - 1) * 4, "UShort")) " "
        s := s = "" ? "(none)" : RTrim(s)
        if !last.Has(hDev) || last[hDev] != s {
            last[hDev] := s
            Log(Format("HID   {}  ON: {}", DevInfo(hDev), s))
            Log("      raw: " Hex(rep, repSize))
        }
    }
}

Preparsed(hDev) {
    static cache := Map()
    if cache.Has(hDev)
        return cache[hDev]
    size := 0
    DllCall("GetRawInputDeviceInfo", "Ptr", hDev, "UInt", 0x20000005, "Ptr", 0, "UInt*", &size)
    pp := Buffer(Max(size, 1))
    DllCall("GetRawInputDeviceInfo", "Ptr", hDev, "UInt", 0x20000005, "Ptr", pp, "UInt*", &size)
    return cache[hDev] := pp
}

DevInfo(hDev) {
    static cache := Map()
    if cache.Has(hDev)
        return cache[hDev]
    info := Buffer(32, 0), NumPut("UInt", 32, info, 0), size := 32
    DllCall("GetRawInputDeviceInfo", "Ptr", hDev, "UInt", 0x2000000B, "Ptr", info, "UInt*", &size)
    s := Format("[VID {:04X} PID {:04X} top {:02X}/{:02X}]", NumGet(info, 8, "UInt") & 0xFFFF
        , NumGet(info, 12, "UInt") & 0xFFFF, NumGet(info, 20, "UShort"), NumGet(info, 22, "UShort"))
    return cache[hDev] := s
}

UsageName(page, usage) {
    static dig := Map(0x32, "InRange", 0x33, "Touch", 0x3C, "Invert", 0x42, "Tip", 0x44, "BARREL"
        , 0x45, "Eraser", 0x47, "Confidence", 0x5A, "BARREL2")
    name := (page = 0x0D && dig.Has(usage)) ? dig[usage] : (page = 0x09 ? "Button" usage : "?")
    return Format("{}({:X}/{:X})", name, page, usage)
}

Hex(p, n) {
    s := ""
    loop Min(n, 24)
        s .= Format("{:02X} ", NumGet(p, A_Index - 1, "UChar"))
    return RTrim(s)
}
