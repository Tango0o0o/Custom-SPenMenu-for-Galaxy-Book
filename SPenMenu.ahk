#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
; =====================================================================
;  S Pen Menu  v30
;  Turns a pen's side button into a pop-up menu and shortcuts.
;  Made for the Samsung S Pen on Galaxy Book laptops; works with most Windows pens.
;
;  Settings : SPenMenu_settings.ini (same folder, created on first run)
;             tray icon > Settings, edit, save, then tray icon > Reload
;  Icons    : put PNGs in the icons\ folder to replace the built-in ones
;  Help     : README.md
; =====================================================================

DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")   ; work in real screen pixels (sharp + correct position)
SetWinDelay(-1)                                             ; no built-in pause after window switches

global INI_FILE := A_ScriptDir "\SPenMenu_settings.ini"
if !FileExist(INI_FILE)
    FileAppend(DefaultSettings(), INI_FILE, "UTF-16")

; =====================================================================
;  Settings
; =====================================================================
Ini(sec, key, def := "") {
    v := ""
    try v := Trim(IniRead(INI_FILE, sec, key, ""))
    return v = "" ? def : v
}
IniInt(sec, key, def) {
    try return Integer(Ini(sec, key, def))
    return def
}
IniSection(sec) {          ; -> [[key, value], ...] (comment lines skipped)
    out := [], txt := ""
    try txt := IniRead(INI_FILE, sec)
    loop parse txt, "`n", "`r" {
        line := Trim(A_LoopField)
        if line = "" || SubStr(line, 1, 1) = ";" || !(p := InStr(line, "="))
            continue
        out.Push([Trim(SubStr(line, 1, p - 1)), Trim(SubStr(line, p + 1))])
    }
    return out
}
ExpandEnv(s) {
    buf := Buffer(2048 * 2, 0)
    DllCall("ExpandEnvironmentStrings", "Str", s, "Ptr", buf, "UInt", 2048)
    return StrGet(buf)
}

; pen side button: list of [usage page, usage] that count as "the button"
BUTTONS := []
for _spec in StrSplit(Ini("Pen", "ButtonUsages", "0x3C,0x44"), ",", " `t") {
    _parts := StrSplit(_spec, ":")
    try BUTTONS.Push(_parts.Length = 2 ? [Integer(_parts[1]), Integer(_parts[2])] : [0x0D, Integer(_parts[1])])
}
TAP_MAX_MS := IniInt("Pen", "TapMaxMs", 300)
MULTI_MS   := IniInt("Pen", "MultiTapMs", 300)

GEST := Map("tap", Ini("Gestures", "Tap", "menu"), "double", Ini("Gestures", "DoubleTap", "playpause")
    , "triple", Ini("Gestures", "TripleTap", "keyboard"), "doublehold", Ini("Gestures", "DoubleTapHold", "translate"))

MENU_HOTKEY    := Ini("Keyboard", "MenuHotkey", "")
MENU_ITEMS_STR := Ini("Menu", "Items", "snip,translate,paste,undo,apps,spotify,taskview")

APPS := []                 ; Label=exe|path|icon
for _kv in IniSection("Apps") {
    _f := StrSplit(_kv[2], "|")
    APPS.Push({label: _kv[1], exe: Trim(_f[1]), path: _f.Length >= 2 ? ExpandEnv(Trim(_f[2])) : ""
        , icon: _f.Length >= 3 ? Trim(_f[3]) : ""})
}

DESKTOP_ICONS := Map()     ; desktop name -> icon
DESKTOP_ICONS.CaseSense := "Off"
for _kv in IniSection("Desktops")
    DESKTOP_ICONS[_kv[1]] := _kv[2]

TR_FROM     := StrLower(Ini("Translate", "From", "en"))
TR_TO       := StrLower(Ini("Translate", "To", ""))
TR_PROVIDER := StrLower(Ini("Translate", "Provider", "googlefree"))
TR_KEY      := Ini("Translate", "ApiKey", "")
TR_REGION   := Ini("Translate", "Region", "")
TR_EMAIL    := Ini("Translate", "Email", "")

SPOTIFY_CLIENT_ID  := Ini("Spotify", "ClientId", "")
SPOTIFY_TOKEN_FILE := A_ScriptDir "\spotify_token.txt"

MENU_BG      := Ini("Look", "Background", "1F1F1F")
MENU_HOVER   := Ini("Look", "Hover", "383838")
MENU_TEXT    := Ini("Look", "Text", "F2F2F2")
MENU_ACCENT  := Ini("Look", "Accent", "6CB4FF")
MENU_W       := IniInt("Look", "MenuWidth", 190)
ROW_H        := IniInt("Look", "RowHeight", 40)
ICON_PX      := IniInt("Look", "IconSize", 22)
SCROLL_SPEED := IniInt("Look", "ScrollSpeed", 35)
ROW_GAP := 2, FONT_PT := 10.5, ICON_PT := 12, SUB_W := 150

; =====================================================================
;  State
; =====================================================================
global gClicks := 0, gPressAt := 0, gTouched := false, gDown := false, gHoldFired := false
global gHold := false      ; true while the menu briefly hands focus back to the app
global gMain := 0, gSub := 0, gMon := 0, gPrevWin := 0, gShownAt := 0, gWasActive := false
global gTr := {gui: 0}, gSel := {gui: 0}, gBusy := 0
global VDA := LoadVDA()

; VirtualDesktopAccessor.dll (optional, next to this script) = instant jumps between desktops
LoadVDA() {
    path := A_ScriptDir "\VirtualDesktopAccessor.dll"
    if !FileExist(path)
        return 0
    h := DllCall("LoadLibrary", "Str", path, "Ptr")
    if !h {
        TrayTip("VirtualDesktopAccessor.dll didn't load (wrong Windows version?) - using the slower fallback", "S Pen Menu", 3)
        return 0
    }
    p := (name) => DllCall("GetProcAddress", "Ptr", h, "AStr", name, "Ptr")
    v := {goTo: p("GoToDesktopNumber"), cur: p("GetCurrentDesktopNumber"), count: p("GetDesktopCount")}
    return (v.goTo && v.cur && v.count) ? v : 0
}

; =====================================================================
;  Keyboard shortcut + tray menu
; =====================================================================
if MENU_HOTKEY != "" {
    try Hotkey("~" MENU_HOTKEY, MenuHotkeyPressed)
    catch
        TrayTip("MenuHotkey in the settings isn't valid: " MENU_HOTKEY, "S Pen Menu", 3)
}
MenuHotkeyPressed(*) {     ; double-press = menu at the mouse; a single press still reaches the app
    static last := 0
    try KeyWait(RegExReplace(MENU_HOTKEY, "^[\^\+!#<>\*~\$]+"))
    if A_TickCount - last < 400 {
        last := 0
        ShowMenu()
    } else
        last := A_TickCount
}

; Other scripts can open the menu by posting window message 0x5A51 to this script's window
OnMessage(0x5A51, (*) => (SetTimer(ShowMenu, -1), 1))

A_IconTip := "S Pen Menu"
A_TrayMenu.Add()
A_TrayMenu.Add("Settings", (*) => Run('notepad.exe "' INI_FILE '"'))
A_TrayMenu.Add("README", (*) => Run('notepad.exe "' A_ScriptDir '\README.md"'))
A_TrayMenu.Add("Translate - select text", (*) => SetTimer(TranslateSelect, -1))
A_TrayMenu.Add("Translate - whole screen", (*) => SetTimer(TranslateScreen, -1))
A_TrayMenu.Add("Connect Spotify (Liked Songs)", (*) => SpotifyConnect())

; =====================================================================
;  Pen input (raw HID)
; =====================================================================
gWin := Gui()              ; hidden window that receives pen input
OnMessage(0x00FF, OnRawInput)          ; WM_INPUT
OnMessage(0x02E0, IgnoreDpiChange)     ; WM_DPICHANGED
OnMessage(0x0201, OvMouseDown)         ; translate overlays: buttons, selecting text
OnMessage(0x0202, OvMouseUp)
OnMessage(0x0200, OvMouseMove)
RegisterPen()

RegisterPen() {   ; pen collections only (digitizer page 0x0D: 0x02 Pen, 0x01 Digitizer) - finger touch is ignored
    sz := 8 + A_PtrSize, rid := Buffer(2 * sz, 0)
    for i, usage in [0x02, 0x01] {
        o := (i - 1) * sz
        NumPut("UShort", 0x0D, rid, o), NumPut("UShort", usage, rid, o + 2)
        NumPut("UInt", 0x100, rid, o + 4), NumPut("Ptr", gWin.Hwnd, rid, o + 8)    ; RIDEV_INPUTSINK
    }
    if !DllCall("RegisterRawInputDevices", "Ptr", rid, "UInt", 2, "UInt", sz)
        TrayTip("Couldn't register for pen input", "S Pen Menu", 3)
}

OnRawInput(wParam, lParam, msg, hwnd) {
    global gClicks, gPressAt, gTouched, gDown, gHoldFired
    static hdr := 8 + 2 * A_PtrSize
    static list := Buffer(4 * 64), penDev := 0
    static buf := Buffer(512), lastKey := Map()
    size := buf.Size                            ; reuse one buffer (no allocation per pen report)
    if DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", buf, "UInt*", &size, "UInt", hdr, "Int") <= 0 {
        size := 0
        DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", 0, "UInt*", &size, "UInt", hdr)
        if !size
            return
        buf := Buffer(size)
        if DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", buf, "UInt*", &size, "UInt", hdr, "Int") <= 0
            return
    }
    if NumGet(buf, 0, "UInt") != 2              ; RIM_TYPEHID only
        return
    hDev := NumGet(buf, 8, "Ptr")
    repSize := NumGet(buf, hdr, "UInt"), count := NumGet(buf, hdr + 4, "UInt")
    pp := Preparsed(hDev)
    loop count {
        rep := buf.Ptr + hdr + 8 + (A_Index - 1) * repSize
        rid := NumGet(rep, 0, "UChar")
        if offs := ButtonBytes(hDev, pp, rid, repSize) {   ; buttons/tip unchanged = pen just moved -> skip
            k := ""
            for o in offs
                k .= NumGet(rep, o, "UChar") ","
            kk := hDev "|" rid
            if lastKey.Has(kk) && lastKey[kk] == k
                continue
            lastKey[kk] := k
        }
        len := 64
        if DllCall("hid\HidP_GetUsagesEx", "Int", 0, "UShort", 0, "Ptr", list, "UInt*", &len
            , "Ptr", pp, "Ptr", rep, "UInt", repSize, "UInt") != 0x110000
            continue
        pressed := false, contact := false
        loop len {
            u := NumGet(list, (A_Index - 1) * 4, "UShort"), p := NumGet(list, (A_Index - 1) * 4 + 2, "UShort")
            for b in BUTTONS
                if p = b[1] && u = b[2]
                    pressed := true
            if p = 0x0D && (u = 0x42 || u = 0x45)  ; Tip or Eraser = pen touching the screen
                contact := true
        }
        if pressed
            penDev := hDev
        if hDev != penDev
            continue

        if pressed && !gDown {                      ; ---- button down
            gDown := true, gPressAt := A_TickCount, gTouched := contact, gHoldFired := false
            SetTimer(FireTaps, 0)
            if gClicks = 1 && GEST["doublehold"] != "none"
                SetTimer(CheckDoubleHold, -TAP_MAX_MS)    ; tap, then press-and-hold
        } else if pressed && contact {
            gTouched := true                        ; writing/erasing with the button held
        } else if !pressed && gDown {               ; ---- button up
            gDown := false
            SetTimer(CheckDoubleHold, 0)
            if gHoldFired || gTouched || (A_TickCount - gPressAt > TAP_MAX_MS) {
                gClicks := 0                        ; hold / erase -> nothing more
                continue
            }
            gClicks += 1
            if gClicks >= 3 {
                gClicks := 0
                SetTimer(FireTaps, 0)
                Gesture("triple")
            } else
                SetTimer(FireTaps, -MULTI_MS)       ; wait to see if another tap comes
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

; Finds which bytes of a pen report hold the button/tip bits (works for any pen), so plain pen
; movement can be skipped without decoding the whole report. 0 = unknown -> always decode.
ButtonBytes(hDev, pp, rid, repSize) {
    static cache := Map()
    key := hDev "|" rid "|" repSize
    if cache.Has(key)
        return cache[key]
    base := Buffer(repSize, 0), work := Buffer(repSize, 0), ul := Buffer(2, 0), offs := Map()
    if DllCall("hid\HidP_InitializeReportForID", "Int", 0, "UChar", rid, "Ptr", pp, "Ptr", base, "UInt", repSize, "UInt") != 0x110000
        return cache[key] := 0
    usages := [[0x0D, 0x42], [0x0D, 0x45]]
    for b in BUTTONS
        usages.Push(b)
    for pu in usages {
        DllCall("RtlMoveMemory", "Ptr", work, "Ptr", base, "UPtr", repSize)
        NumPut("UShort", pu[2], ul), n := 1
        if DllCall("hid\HidP_SetUsages", "Int", 0, "UShort", pu[1], "UShort", 0, "Ptr", ul, "UInt*", &n
            , "Ptr", pp, "Ptr", work, "UInt", repSize, "UInt") != 0x110000
            continue
        loop repSize
            if NumGet(work, A_Index - 1, "UChar") != NumGet(base, A_Index - 1, "UChar")
                offs[A_Index - 1] := 1
    }
    if !offs.Count
        return cache[key] := 0
    arr := []
    for o in offs
        arr.Push(o)
    return cache[key] := arr
}

; =====================================================================
;  Gestures -> actions
; =====================================================================
CheckDoubleHold() {
    global gHoldFired, gClicks
    if gDown && !gTouched && gClicks = 1 {
        gHoldFired := true, gClicks := 0
        Gesture("doublehold")
    }
}

FireTaps() {
    global gClicks
    n := gClicks, gClicks := 0
    if n = 1
        Gesture("tap")
    else if n = 2
        Gesture("double")
}

Gesture(kind) {
    if gTr.gui || gSel.gui {                        ; any pen gesture closes the translation
        SetTimer(gTr.gui ? CloseTranslate : CloseSelect, -1)
        return
    }
    SetTimer(RunAction.Bind(GEST[kind]), -1)
}

; actions usable in [Gestures]: menu, translate (select text), translatescreen (whole screen),
;                                playpause, keyboard, snip, paste, undo, taskview, none
RunAction(name) {
    switch StrLower(name) {
        case "menu":      ShowMenu()
        case "translate": TranslateSelect()
        case "translatescreen": TranslateScreen()
        case "playpause": Send("{Media_Play_Pause}")
        case "keyboard":  ToggleTouchKeyboard()
        case "snip":      DoSnip()
        case "paste":     Send("^v")
        case "undo":      Send("^z")
        case "taskview":  Send("#{Tab}")
    }
}

; Shows/hides the Windows touch keyboard via its own COM interface (ITipInvocation.Toggle)
ToggleTouchKeyboard() {
    static tabTip := A_ProgramFiles "\Common Files\microsoft shared\ink\TabTip.exe"
    loop 2 {
        try {
            tip := ComObject("{4ce576fa-83dc-4F88-951c-9d0782b4e376}", "{37c994e7-432b-4834-a2f7-dce1f13b834b}")
            ComCall(3, tip, "Ptr", DllCall("GetDesktopWindow", "Ptr"))
            return
        } catch {
            if A_Index = 1 && FileExist(tabTip) {   ; keyboard service not running yet -> start it, retry
                Run(tabTip)
                Sleep(400)
            }
        }
    }
    TrayTip("Couldn't open the touch keyboard", "S Pen Menu", 3)
}

DoSnip() => Run("ms-screenclip:")

; =====================================================================
;  Menu contents
; =====================================================================
; item: [icon, label, onClick, submenu, textColor, liveLabelFn, liveIconFn, fallbackText]
;   icon: "png:NAME" (icons\NAME.png, else built-in), "exe:C:\path\app.exe" (the app's own icon),
;         a Segoe icon-font character, or plain text
BuildMenuItems() {
    items := []
    for word in StrSplit(MENU_ITEMS_STR, ",", " `t") {
        switch StrLower(word) {
            case "snip":      items.Push(["png:SNIP", "Screen snip", MenuSnip])
            case "translate": items.Push(["png:TRANSLATE", "Translate", MenuTranslate, "translate"])
            case "paste":     items.Push(["png:PASTE", "Paste", MenuPaste, "paste"])
            case "undo":      items.Push(["png:UNDO", "Undo", MenuUndo, "undo"])
            case "taskview":  items.Push(["png:TASKVIEW", "Task View", MenuTaskView, "desktops"])
            case "spotify":
                if SpotifyInstalled()
                    items.Push(["png:SPOTIFY", "Spotify", MenuSpotify, "media", "", SpotifyLabel])
            case "apps":
                for app in APPS {
                    path := AppPath(app)
                    if path = ""
                        continue                        ; not installed -> no row
                    icon := (app.icon != "" && IconSrc(app.icon)) ? app.icon : "exe:" path
                    items.Push([icon, app.label, MenuApp.Bind(app)])
                }
        }
    }
    return items
}

AppPath(app) {   ; full path if the app is installed, else ""
    if app.path != "" && FileExist(app.path)
        return app.path
    if app.exe = ""
        return ""
    if pid := ProcessExist(app.exe) {
        try return ProcessGetPath(pid)
    }
    for root in ["HKCU", "HKLM"] {
        p := ""
        try p := Trim(RegRead(root "\Software\Microsoft\Windows\CurrentVersion\App Paths\" app.exe), '"')
        if p != "" && FileExist(p)
            return p
    }
    return ""
}

; =====================================================================
;  Menu window
; =====================================================================
CursorPos(&x, &y) {
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    x := NumGet(pt, 0, "Int"), y := NumGet(pt, 4, "Int")
}

MonitorAt(x, y, full := false) {   ; DPI + work area (or full area) of the monitor under a point
    hMon := DllCall("MonitorFromPoint", "Int64", (y << 32) | (x & 0xFFFFFFFF), "UInt", 2, "Ptr")
    dpi := 96, dpiY := 96
    DllCall("shcore\GetDpiForMonitor", "Ptr", hMon, "Int", 0, "UInt*", &dpi, "UInt*", &dpiY)
    mi := Buffer(40, 0), NumPut("UInt", 40, mi, 0)
    DllCall("GetMonitorInfo", "Ptr", hMon, "Ptr", mi)
    o := full ? 4 : 20
    return {l: NumGet(mi, o, "Int"), t: NumGet(mi, o + 4, "Int"), r: NumGet(mi, o + 8, "Int")
        , b: NumGet(mi, o + 12, "Int"), dpi: dpi, s: dpi / 96}
}

ShowMenu() {
    global gMain, gSub, gMon, gPrevWin, gShownAt, gWasActive
    DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    CursorPos(&x, &y)
    gMon := MonitorAt(x, y)
    a := WinExist("A")
    if !(gMain && a = gMain.gui.Hwnd)
        gPrevWin := a                              ; where Paste / Undo should go
    DestroyPanel(&gSub), DestroyPanel(&gMain)
    off := Round(8 * gMon.s)
    gMain := BuildPanel(BuildMenuItems(), MENU_W, x + off, y + off)
    WinActivate(gMain.gui.Hwnd)
    SetTimer(() => (gMain && PlacePanel(gMain)), -60)   ; re-pin in case anything nudged it
    gShownAt := A_TickCount, gWasActive := false
    SetTimer(WatchMenu, 30)
    SetTimer(MarqueeTick, 15)
}

IsImageSpec(s) => RegExMatch(s, "i)^(png|exe):")

BuildPanel(items, widthDip, wantX, wantY) {
    m := gMon, s := m.s
    pad := Round(6 * s), gap := Round(ROW_GAP * s), rowH := Round(ROW_H * s)
    iw := Round(42 * s), cw := Round(26 * s), lw := Round(widthDip * s) - iw
    w := 2 * pad + iw + lw
    h := 2 * pad + Max(items.Length, 1) * rowH + Max(items.Length - 1, 0) * gap
    x := Max(m.l, Min(wantX, m.r - w)), y := Max(m.t, Min(wantY, m.b - h))

    g := Gui("-Caption +AlwaysOnTop +ToolWindow -DPIScale")
    g.BackColor := MENU_BG
    g.SetFont("c" MENU_TEXT)
    textFont := MakeFont("Segoe UI", FONT_PT, m.dpi)
    iconFont := MakeFont(IconFace(), ICON_PT, m.dpi)
    chevFont := MakeFont(IconFace(), 8, m.dpi)
    ipx := Round(ICON_PX * s)
    rows := []
    for i, it in items {
        ry := pad + (i - 1) * (rowH + gap)
        row := {pic: 0, bmpN: 0, bmpH: 0, sub: (it.Length >= 4 && it[4])}
        spec := it[1]
        row.dynIcon := (it.Length >= 7 && it[7]) ? it[7] : 0       ; live icon (e.g. play/pause)
        if row.dynIcon
            spec := row.dynIcon.Call()
        row.iconName := spec, row.iw := iw, row.ipx := ipx
        if IsImageSpec(spec) {
            row.bmpN := IconBitmap(spec, iw, rowH, ipx, MENU_BG)
            row.bmpH := row.bmpN ? IconBitmap(spec, iw, rowH, ipx, MENU_HOVER) : 0
        }
        if row.bmpN {
            ic := g.AddPicture("x" pad " y" ry " w" iw " h" rowH, "HBITMAP:*" row.bmpN)
            row.pic := ic
        } else {
            txt := !IsImageSpec(spec) ? spec : (it.Length >= 8 && it[8] != "") ? it[8] : SubStr(it[2], 1, 1)
            ic := g.AddText("x" pad " y" ry " w" iw " h" rowH " 0x201 Background" MENU_BG, txt)
            SendMessage(0x30, (Ord(txt) >= 0xE000) ? iconFont : textFont, 1, ic)
        }
        row.ic := ic
        color := (it.Length >= 5 && it[5] != "") ? " c" it[5] : ""
        row.dyn := (it.Length >= 6 && it[6]) ? it[6] : 0          ; live label (e.g. now playing)
        lbW := row.sub ? lw - cw : lw
        lb := g.AddText("x" (pad + iw) " y" ry " w" lbW " h" rowH
            . " 0x200 Background" MENU_BG color, row.dyn ? "" : it[2])
        SendMessage(0x30, textFont, 1, lb)
        row.lb := lb, row.lbFull := lbW, row.h := rowH, row.font := textFont
        row.color := (it.Length >= 5 && it[5] != "") ? it[5] : MENU_TEXT, row.margin := Round(8 * s)
        row.text := "", row.off := 0, row.pauseUntil := 0, row.fits := true, row.stripW := 0
        row.stripN := 0, row.stripH := 0
        ctrls := [ic, lb]
        if row.sub {                                   ; little ">" arrow
            ch := g.AddText("x+0 yp w" cw " h" rowH " 0x201 Background" MENU_BG, Chr(0xE76C))
            SendMessage(0x30, chevFont, 1, ch)
            ctrls.Push(ch)
        }
        for c in ctrls
            c.OnEvent("Click", it[3]), c.OnEvent("DoubleClick", it[3])   ; quick repeat taps all count
        row.ctrls := ctrls
        rows.Push(row)
    }
    g.OnEvent("Escape", (*) => HideMenu())
    g.Show("Hide x" x " y" y " w" w " h" h)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4) ; rounded corners
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 20, "Int*", 1, "UInt", 4) ; dark frame
    p := {gui: g, rows: rows, x: x, y: y, w: w, h: h, pad: pad, rowH: rowH, gap: gap, hover: 0, parentRow: 0, kind: ""}
    PlacePanel(p, true)
    return p
}

PlacePanel(p, show := false) {   ; exact position + size, topmost, never steals focus
    DllCall("SetWindowPos", "Ptr", p.gui.Hwnd, "Ptr", -1, "Int", p.x, "Int", p.y
        , "Int", p.w, "Int", p.h, "UInt", 0x10 | (show ? 0x40 : 0))
}

DestroyPanel(&p) {
    if p {
        for row in p.rows
            row.dead := true, FreeStrips(row)      ; timers skip rows of a closed panel
        p.gui.Destroy()
    }
    p := 0
}

PanelHit(p, x, y) {   ; -1 = outside, 0 = inside but not on a row, n = row n
    if (x < p.x || x >= p.x + p.w || y < p.y || y >= p.y + p.h)
        return -1
    rel := y - p.y - p.pad
    i := Floor(rel / (p.rowH + p.gap)) + 1
    return (rel >= 0 && i <= p.rows.Length && Mod(rel, p.rowH + p.gap) < p.rowH) ? i : 0
}

SetPanelHover(p, i) {
    if p.hover = i
        return
    p.hover := i
    for n, row in p.rows
        for c in row.ctrls {
            if c = row.pic
                c.Value := "HBITMAP:*" (n = i ? row.bmpH : row.bmpN)
            else
                c.Opt("Background" (n = i ? MENU_HOVER : MENU_BG))
        }
    DllCall("RedrawWindow", "Ptr", p.gui.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x1 | 0x4 | 0x80 | 0x100)
    for n, row in p.rows
        if row.dyn
            DrawRow(row, n = i)
}

IgnoreDpiChange(wParam, lParam, msg, hwnd) {   ; keep our own size/position on mixed-DPI setups
    if (gMain && hwnd = gMain.gui.Hwnd) || (gSub && hwnd = gSub.gui.Hwnd) || (gTr.gui && hwnd = gTr.gui.Hwnd) || (gSel.gui && hwnd = gSel.gui.Hwnd)
        return 0
}

MakeFont(face, pt, dpi) {
    static cache := Map()
    key := face "|" pt "|" dpi
    if cache.Has(key)
        return cache[key]
    return cache[key] := DllCall("CreateFont", "Int", -Round(pt * dpi / 72), "Int", 0, "Int", 0, "Int", 0
        , "Int", 400, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 1, "UInt", 0, "UInt", 0
        , "UInt", 5, "UInt", 0, "Str", face, "Ptr")              ; 5 = ClearType
}

IconFace() {   ; Win11 has Segoe Fluent Icons; Win10 has Segoe MDL2 Assets
    return (StrSplit(A_OSVersion, ".")[3] >= 22000) ? "Segoe Fluent Icons" : "Segoe MDL2 Assets"
}

; Polls pen position: hover highlight, opens/closes submenus, closes the menu when focus leaves
WatchMenu() {
    global gWasActive, gSub
    Critical
    DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    if !gMain
        return SetTimer(WatchMenu, 0)
    CursorPos(&x, &y)
    hs := gSub ? PanelHit(gSub, x, y) : -1
    if hs >= 0 {                                   ; over the submenu
        SetPanelHover(gSub, hs)
        SetPanelHover(gMain, gSub.parentRow)       ; keep the parent row lit
    } else {
        if gSub
            SetPanelHover(gSub, 0)
        hm := PanelHit(gMain, x, y)
        if hm > 0 {
            SetPanelHover(gMain, hm)
            if gMain.rows[hm].sub {
                if !gSub || gSub.parentRow != hm
                    OpenSub(hm)
            } else if gSub {
                subWasActive := WinActive("ahk_id " gSub.gui.Hwnd)
                DestroyPanel(&gSub)
                if subWasActive
                    WinActivate(gMain.gui.Hwnd)
            }
        } else if !gSub
            SetPanelHover(gMain, 0)
    }
    if WinActive("ahk_id " gMain.gui.Hwnd) || (gSub && WinActive("ahk_id " gSub.gui.Hwnd))
        gWasActive := true
    else if !gHold && (gWasActive || (A_TickCount - gShownAt > 4000))
        HideMenu()
}

HideMenu() {
    SetTimer(WatchMenu, 0)
    SetTimer(MarqueeTick, 0)
    if gSub
        gSub.gui.Hide()
    if gMain
        gMain.gui.Hide()
}

; =====================================================================
;  Submenus
; =====================================================================
OpenSub(i) {
    global gSub
    wasActive := gSub && WinActive("ahk_id " gSub.gui.Hwnd)
    DestroyPanel(&gSub)
    items := [], kind := gMain.rows[i].sub, subW := SUB_W
    if kind = "desktops" {
        cur := 0, count := 0
        DesktopState(&cur, &count)
        names := DesktopNames()
        while names.Length < count
            names.Push("Desktop " (names.Length + 1))
        for n, name in names
            items.Push([DESKTOP_ICONS.Has(name) ? DESKTOP_ICONS[name] : String(n), name, SubPick.Bind(n)
                , false, n = cur ? MENU_ACCENT : "", 0, 0, String(n)])
    } else if kind = "translate" {
        items.Push(["png:TRSELECT", "Select text", MenuTranslate])
        items.Push(["png:TRSCREEN", "Whole screen", MenuTrScreen])
    } else if kind = "paste" {
        items.Push(["png:CLIPBOARD", "Clipboard history", MenuClipboard])
        subW += 30
    } else if kind = "undo" {
        items.Push(["png:UNDO2", "Undo ×2", (*) => SendToPrev("^z", 2)])
        items.Push(["png:REDO",  "Redo",    (*) => SendToPrev(RedoKeys())])
        items.Push(["png:REDO2", "Redo ×2", (*) => SendToPrev(RedoKeys(), 2)])
    } else if kind = "media" {
        items.Push(["png:PLAY", "Play", MediaToggle, false, "", PlayPauseLabel, PlayPauseIcon])
        items.Push(["png:NEXT", "Next track", MenuNext])
        items.Push(["png:PREV", "Previous track", MenuPrev])
        if SPOTIFY_CLIENT_ID != ""
            items.Push(["png:LIKE", "Liked Songs", LikeToggle, false, "", LikeLabel])
        subW += 60
    }
    if !items.Length
        return
    s := gMon.s, edge := Round(6 * s), sw := Round(subW * s) + 2 * edge
    sy := gMain.y + gMain.pad + (i - 1) * (gMain.rowH + gMain.gap) - edge   ; line up with the row
    sx := gMain.x + gMain.w + Round(4 * s)
    if sx + sw > gMon.r                                                      ; no room -> open on the left
        sx := gMain.x - sw - Round(4 * s)
    gSub := BuildPanel(items, subW, sx, sy)
    gSub.kind := kind, gSub.parentRow := i
    if wasActive
        WinActivate(gMain.gui.Hwnd)        ; keep the menu alive when swapping submenus
}

; =====================================================================
;  Menu actions
; =====================================================================
MenuSnip(*) {
    HideMenu()
    Sleep(120)
    DoSnip()
}

MenuTranslate(*) {          ; tap Translate = select text (Circle to Search style)
    HideMenu()
    SetTimer(TranslateSelect, -50)
}

MenuTrScreen(*) {
    HideMenu()
    SetTimer(TranslateScreen, -50)
}

FocusPrev() {
    if gPrevWin && WinExist("ahk_id " gPrevWin) {
        WinActivate("ahk_id " gPrevWin)
        WinWaitActive("ahk_id " gPrevWin, , 1)
    }
}

MenuPaste(*) {
    HideMenu()
    FocusPrev()
    Sleep(80)
    Send("^v")
}

MenuClipboard(*) {           ; Windows clipboard history, opened in the app you were in
    HideMenu()
    FocusPrev()
    Sleep(80)
    Send("#v")
}

MenuUndo(*) => SendToPrev("^z")     ; menu stays open - tap outside / Esc to close

; Sends keys to the window you were in before the menu opened, then gives focus back to the menu
SendToPrev(keys, times := 1) {
    global gHold
    if !gPrevWin || !WinExist("ahk_id " gPrevWin)
        return
    gHold := true
    try {
        WinActivate("ahk_id " gPrevWin)
        WinWaitActive("ahk_id " gPrevWin, , 0.5)
        Sleep(10)
        loop times {
            Send(keys)
            Sleep(20)
        }
        if gMain && WinExist("ahk_id " gMain.gui.Hwnd) {
            WinActivate("ahk_id " gMain.gui.Hwnd)
            WinWaitActive("ahk_id " gMain.gui.Hwnd, , 0.5)
        }
    }
    gHold := false
}

RedoKeys() {                 ; DaVinci Resolve uses Ctrl+Shift+Z, most apps Ctrl+Y
    return WinExist("ahk_id " gPrevWin " ahk_exe Resolve.exe") ? "^+z" : "^y"
}

MenuApp(app, *) {
    HideMenu()
    if WinExist("ahk_exe " app.exe) {           ; already open -> bring it forward
        WinActivate()
        return
    }
    p := AppPath(app)
    try Run(p != "" ? p : app.exe)
    catch
        TrayTip("Couldn't open " app.label " - check its line in the settings", "S Pen Menu", 3)
}

MenuTaskView(*) {
    HideMenu()
    Sleep(100)
    Send("#{Tab}")
}

; =====================================================================
;  Virtual desktops
; =====================================================================
SubPick(n, *) {
    static last := 0
    if A_TickCount - last < 600
        return
    last := A_TickCount
    HideMenu()
    Sleep(80)
    GoToDesktop(n)
}

; Desktop names as shown in Windows Task View (unnamed ones are "Desktop N")
DesktopNames() {
    static key := "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops"
    ids := "", names := []
    try ids := RegRead(key, "VirtualDesktopIDs")
    loop StrLen(ids) // 32 {
        h := SubStr(ids, (A_Index - 1) * 32 + 1, 32)
        guid := "{" SubStr(h, 7, 2) SubStr(h, 5, 2) SubStr(h, 3, 2) SubStr(h, 1, 2) "-" SubStr(h, 11, 2) SubStr(h, 9, 2)
            . "-" SubStr(h, 15, 2) SubStr(h, 13, 2) "-" SubStr(h, 17, 4) "-" SubStr(h, 21, 12) "}"
        name := ""
        try name := RegRead(key "\Desktops\" guid, "Name")
        names.Push(name != "" ? name : "Desktop " A_Index)
    }
    if !names.Length
        names.Push("Desktop 1")
    return names
}

DesktopState(&cur, &count) {
    if VDA {
        c := DllCall(VDA.cur, "Int"), k := DllCall(VDA.count, "Int")
        if c >= 0 && k > 0 {
            cur := c + 1, count := k
            return true
        }
    }
    static key := "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer"
    cur := 0, count := 0, ids := "", curId := ""
    try ids := RegRead(key "\VirtualDesktops", "VirtualDesktopIDs")
    count := Max(StrLen(ids) // 32, 1)
    try curId := RegRead(key "\VirtualDesktops", "CurrentVirtualDesktop")
    if curId = "" {
        sid := 0
        DllCall("ProcessIdToSessionId", "UInt", DllCall("GetCurrentProcessId", "UInt"), "UInt*", &sid)
        try curId := RegRead(key "\SessionInfo\" sid "\VirtualDesktops", "CurrentVirtualDesktop")
    }
    loop StrLen(ids) // 32
        if SubStr(ids, (A_Index - 1) * 32 + 1, 32) = curId
            cur := A_Index
    if !cur && count = 1
        cur := 1
    return cur > 0
}

SwitchKey(dir) {
    SendEvent("{LWin down}{LCtrl down}")
    Sleep(30)
    SendEvent("{" dir "}")
    Sleep(30)
    SendEvent("{LCtrl up}{LWin up}")
}

GoToDesktop(n) {
    if VDA && DllCall(VDA.goTo, "Int", n - 1, "Int") != -1
        return
    if DesktopState(&cur, &count) {
        if n > count
            return
        diff := n - cur
    } else {
        loop 10 {
            SwitchKey("Left")
            Sleep(60)
        }
        diff := n - 1
    }
    loop Abs(diff) {
        SwitchKey(diff > 0 ? "Right" : "Left")
        Sleep(150)
    }
}

; =====================================================================
;  Spotify (now playing + media submenu)
; =====================================================================
SpotifyInstalled() {
    static known := ""
    if known != ""
        return known
    sz := 260, buf := Buffer(520, 0)
    hr := DllCall("shlwapi\AssocQueryStringW", "UInt", 0x1000, "Int", 4, "Str", "spotify", "Ptr", 0, "Ptr", buf, "UInt*", &sz, "Int")
    return known := (hr = 0 || FileExist(A_AppData "\Spotify\Spotify.exe") != "" || ProcessExist("Spotify.exe") != 0)
}

MenuSpotify(*) {
    HideMenu()
    try Run("spotify:")
    catch
        TrayTip("Couldn't open Spotify", "S Pen Menu", 3)
}

MenuNext(*) => Send("{Media_Next}")      ; menu stays open
MenuPrev(*) => Send("{Media_Prev}")
MediaToggle(*) => Send("{Media_Play_Pause}")

SpotifyPlaying() => InStr(SpotifyTitle(), " - ") > 0
PlayPauseLabel() => SpotifyPlaying() ? "Pause" : "Play"
PlayPauseIcon() => SpotifyPlaying() ? "png:PAUSE" : "png:PLAY"

SpotifyLabel() {
    ti := SpotifyTitle()
    if (p := InStr(ti, " - "))
        return SubStr(ti, p + 3) "  –  " SubStr(ti, 1, p - 1)   ; Song – Artist
    return "Spotify"
}

; The Spotify desktop app shows "Artist - Song" as its window title while playing
SpotifyTitle() {
    static hwnd := 0, lastScan := 0
    DetectHiddenWindows(true)
    if !hwnd || !WinExist("ahk_id " hwnd) {
        hwnd := 0
        if A_TickCount - lastScan < 3000
            return ""
        lastScan := A_TickCount
        try for h in WinGetList("ahk_exe Spotify.exe") {
            ti := WinGetTitle(h)
            if InStr(ti, " - ") || (ti != "" && WinGetClass(h) = "Chrome_WidgetWin_0") {
                hwnd := h
                if InStr(ti, " - ")
                    break
            }
        }
        if !hwnd
            return ""
    }
    ti := ""
    try ti := WinGetTitle(hwnd)
    return ti
}

; ---------- Spotify Liked Songs (Web API, optional) ----------
global gSpot := {token: "", tokenExp: 0, liked: -1, uri: "", err: "", lastTitle: "", lastCheck: 0}

LikeLabel() {
    if !FileExist(SPOTIFY_TOKEN_FILE)
        return "Liked Songs (connect first)"
    if gSpot.err != ""
        return "Liked Songs: " gSpot.err
    return gSpot.liked = 1 ? "Remove from Liked Songs" : gSpot.liked = 0 ? "Add to Liked Songs" : "Liked Songs…"
}

LikeToggle(*) {
    if !FileExist(SPOTIFY_TOKEN_FILE) {
        HideMenu()
        return SpotifyConnect()
    }
    if gSpot.uri = "" || gSpot.liked < 0
        return
    tok := SpotToken()
    if !tok
        return
    method := gSpot.liked = 1 ? "DELETE" : "PUT"
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open(method, "https://api.spotify.com/v1/me/library?uris=" StrReplace(gSpot.uri, ":", "%3A"), false)
        req.SetRequestHeader("Authorization", "Bearer " tok)
        req.SetRequestHeader("Content-Length", "0")
        req.Send()
        if req.Status >= 200 && req.Status < 300 {
            gSpot.liked := gSpot.liked = 1 ? 0 : 1
            gSpot.lastCheck := A_TickCount
        } else
            gSpot.err := "error " req.Status
    } catch
        gSpot.err := "no connection"
}

; Background check of whether the current song is liked (async web requests -> no menu lag)
SpotCheckLiked() {
    static stage := 0, req := 0, started := 0, title := ""
    if SPOTIFY_CLIENT_ID = "" || !FileExist(SPOTIFY_TOKEN_FILE)
        return
    now := A_TickCount
    if stage = 0 {
        title := SpotifyTitle()
        if title = gSpot.lastTitle && now - gSpot.lastCheck < 15000
            return
        tok := SpotToken()
        if !tok
            return
        try {
            req := ComObject("WinHttp.WinHttpRequest.5.1")
            req.Open("GET", "https://api.spotify.com/v1/me/player/currently-playing", true)
            req.SetRequestHeader("Authorization", "Bearer " tok)
            req.Send()
            stage := 1, started := now
        }
        return
    }
    try done := req.WaitForResponse(0)
    catch
        done := true
    if !done {
        if now - started > 6000
            stage := 0, gSpot.lastTitle := title, gSpot.lastCheck := now
        return
    }
    status := 0, txt := ""
    try status := req.Status, txt := req.ResponseText
    if stage = 1 {
        if status = 200 && RegExMatch(txt, '"(spotify:track:[A-Za-z0-9]+)"', &m) {
            gSpot.uri := m[1]
            try {
                req := ComObject("WinHttp.WinHttpRequest.5.1")
                req.Open("GET", "https://api.spotify.com/v1/me/library/contains?uris=" StrReplace(gSpot.uri, ":", "%3A"), true)
                req.SetRequestHeader("Authorization", "Bearer " SpotToken())
                req.Send()
                stage := 2, started := now
                return
            }
        }
        gSpot.uri := "", gSpot.liked := -1
        gSpot.err := (status = 200 || status = 204) ? "" : "error " status
    } else {
        gSpot.liked := (status = 200) ? (InStr(txt, "true") ? 1 : 0) : -1
        gSpot.err := (status = 200) ? "" : "error " status
    }
    stage := 0, gSpot.lastTitle := title, gSpot.lastCheck := now
}

SpotToken() {
    if gSpot.token && A_TickCount < gSpot.tokenExp
        return gSpot.token
    if !FileExist(SPOTIFY_TOKEN_FILE)
        return ""
    refresh := Trim(FileRead(SPOTIFY_TOKEN_FILE))
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("POST", "https://accounts.spotify.com/api/token", false)
        req.SetRequestHeader("Content-Type", "application/x-www-form-urlencoded")
        req.Send("grant_type=refresh_token&refresh_token=" refresh "&client_id=" SPOTIFY_CLIENT_ID)
        txt := req.ResponseText
        if req.Status != 200 {
            gSpot.err := (req.Status = 400) ? "log in again (tray menu)" : "error " req.Status
            return ""
        }
        RegExMatch(txt, '"access_token"\s*:\s*"([^"]+)"', &a)
        RegExMatch(txt, '"expires_in"\s*:\s*(\d+)', &e)
        if RegExMatch(txt, '"refresh_token"\s*:\s*"([^"]+)"', &r) && r[1] != refresh {
            f := FileOpen(SPOTIFY_TOKEN_FILE, "w"), f.Write(r[1]), f.Close()
        }
        gSpot.token := a[1], gSpot.tokenExp := A_TickCount + ((e ? e[1] : 3600) - 60) * 1000
        gSpot.err := ""
        return gSpot.token
    } catch {
        gSpot.err := "no connection"
        return ""
    }
}

SpotifyConnect() {
    if SPOTIFY_CLIENT_ID = "" {
        MsgBox("Add your Spotify app's Client ID to the settings ([Spotify] ClientId=), save, Reload, "
            . "then try again.`n`nSee README > Spotify Liked Songs.", "S Pen Menu - Spotify", "Icon!")
        return
    }
    ps := A_Temp "\spen_spotify_login.ps1"
    try FileDelete(ps)
    FileAppend(SpotifyLoginPS(), ps, "UTF-8")
    TrayTip("Log in to Spotify in your browser and press Agree.", "S Pen Menu - Spotify")
    exitCode := RunWait('powershell -NoProfile -ExecutionPolicy Bypass -File "' ps '" -clientId "' SPOTIFY_CLIENT_ID
        . '" -outFile "' SPOTIFY_TOKEN_FILE '"', , "Hide")
    try FileDelete(ps)
    if exitCode = 0 && FileExist(SPOTIFY_TOKEN_FILE) {
        gSpot.token := "", gSpot.err := "", gSpot.lastCheck := 0
        TrayTip("Spotify connected.", "S Pen Menu - Spotify")
    } else
        TrayTip("Spotify login didn't finish (code " exitCode "). Check the Client ID and redirect URI.", "S Pen Menu - Spotify", 3)
}

SpotifyLoginPS() {
    return "
    (
param([string]$clientId, [string]$outFile)
$ErrorActionPreference = 'Stop'
$redirect = 'http://127.0.0.1:8888/callback'
function B64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_') }
$rnd = New-Object byte[] 48
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rnd)
$verifier = B64Url $rnd
$challenge = B64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
$state = [guid]::NewGuid().ToString('N')
$scope = 'user-read-currently-playing user-library-read user-library-modify'
$url = 'https://accounts.spotify.com/authorize?response_type=code&client_id=' + $clientId +
  '&redirect_uri=' + [uri]::EscapeDataString($redirect) + '&code_challenge_method=S256&code_challenge=' + $challenge +
  '&scope=' + [uri]::EscapeDataString($scope) + '&state=' + $state
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 8888)
$listener.Start()
Start-Process $url
$code = $null
$deadline = (Get-Date).AddMinutes(5)
$crlf = [string][char]13 + [char]10
while (-not $code -and (Get-Date) -lt $deadline) {
  if (-not $listener.Pending()) { Start-Sleep -Milliseconds 200; continue }
  $client = $listener.AcceptTcpClient()
  $client.ReceiveTimeout = 3000
  try {
    $stream = $client.GetStream()
    $line = (New-Object IO.StreamReader($stream)).ReadLine()
    $msg = 'Not the Spotify reply.'
    if ($line -match '/callback\?' -and $line -match ('state=' + $state)) {
      if ($line -match 'code=([^&\s]+)') { $code = $Matches[1]; $msg = 'Spotify connected - you can close this tab.' }
      else { $msg = 'Spotify login was cancelled.'; $deadline = Get-Date }
    }
    $body = [Text.Encoding]::UTF8.GetBytes('<html><body style="font-family:Segoe UI;background:#1f1f1f;color:#f2f2f2;padding:40px"><h2>' + $msg + '</h2></body></html>')
    $head = [Text.Encoding]::ASCII.GetBytes('HTTP/1.1 200 OK' + $crlf + 'Content-Type: text/html; charset=utf-8' + $crlf +
      'Content-Length: ' + $body.Length + $crlf + 'Connection: close' + $crlf + $crlf)
    $stream.Write($head, 0, $head.Length); $stream.Write($body, 0, $body.Length); $stream.Flush()
  } catch { } finally { $client.Close() }
}
$listener.Stop()
if (-not $code) { exit 2 }
$tok = Invoke-RestMethod -Method Post -Uri 'https://accounts.spotify.com/api/token' -ContentType 'application/x-www-form-urlencoded' -Body @{
  grant_type = 'authorization_code'; code = $code; redirect_uri = $redirect; client_id = $clientId; code_verifier = $verifier }
if (-not $tok.refresh_token) { exit 3 }
[IO.File]::WriteAllText($outFile, $tok.refresh_token)
exit 0
    )"
}

; =====================================================================
;  Smooth scrolling live labels (now playing, play/pause, liked)
; =====================================================================
MarqueeTick() {
    static lastText := 0, lastTick := 0
    Critical                                   ; don't let other timers close a panel mid-draw
    if !gMain
        return SetTimer(MarqueeTick, 0)
    DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    now := A_TickCount
    dt := lastTick ? Min(now - lastTick, 100) : 15
    lastTick := now
    refresh := (now - lastText > 250)
    if refresh
        lastText := now
    if gSub && gSub.kind = "media"
        SpotCheckLiked()
    for p in [gMain, gSub] {
        if !p
            continue
        for i, row in p.rows {
            if row.HasOwnProp("dead")
                break
            if row.dynIcon && refresh {
                nm := row.dynIcon.Call()
                if nm != row.iconName && row.pic && IsImageSpec(nm) {
                    bN := IconBitmap(nm, row.iw, row.h, row.ipx, MENU_BG)
                    if bN {
                        row.iconName := nm, row.bmpN := bN
                        row.bmpH := IconBitmap(nm, row.iw, row.h, row.ipx, MENU_HOVER)
                        row.pic.Value := "HBITMAP:*" (i = p.hover ? row.bmpH : row.bmpN)
                    }
                }
            }
            if !row.dyn
                continue
            if refresh || !row.stripN {
                nt := row.dyn.Call()
                if nt != row.text || !row.stripN
                    SetRowText(row, nt)
            }
            if !row.fits && now >= row.pauseUntil {
                row.off += dt * SCROLL_SPEED * gMon.s / 1000
                if row.off >= row.stripW
                    row.off := 0, row.pauseUntil := now + 1500
            }
            DrawRow(row, i = p.hover)
        }
    }
}

SetRowText(row, txt) {
    FreeStrips(row)
    row.text := txt
    tw := TextWidth(row.font, txt)
    row.fits := tw <= row.lbFull - row.margin
    row.stripW := row.fits ? row.lbFull : tw + Round(48 * gMon.s)
    row.stripN := MakeStrip(row, MENU_BG)
    row.stripH := MakeStrip(row, MENU_HOVER)
    row.off := 0, row.pauseUntil := A_TickCount + 1500
}

MakeStrip(row, bg) {
    hdc0 := DllCall("GetDC", "Ptr", 0, "Ptr")
    dc := DllCall("CreateCompatibleDC", "Ptr", hdc0, "Ptr")
    bmp := DllCall("CreateCompatibleBitmap", "Ptr", hdc0, "Int", row.stripW, "Int", row.h, "Ptr")
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc0)
    old := DllCall("SelectObject", "Ptr", dc, "Ptr", bmp, "Ptr")
    rc := Buffer(16, 0), NumPut("Int", row.stripW, rc, 8), NumPut("Int", row.h, rc, 12)
    br := DllCall("CreateSolidBrush", "UInt", Cref(bg), "Ptr")
    DllCall("FillRect", "Ptr", dc, "Ptr", rc, "Ptr", br)
    DllCall("DeleteObject", "Ptr", br)
    oldF := DllCall("SelectObject", "Ptr", dc, "Ptr", row.font, "Ptr")
    DllCall("SetBkMode", "Ptr", dc, "Int", 1)
    DllCall("SetTextColor", "Ptr", dc, "UInt", Cref(row.color))
    DllCall("DrawText", "Ptr", dc, "Str", row.text, "Int", -1, "Ptr", rc, "UInt", 0x20 | 0x4 | 0x800)
    DllCall("SelectObject", "Ptr", dc, "Ptr", oldF)
    return {dc: dc, bmp: bmp, old: old}
}

DrawRow(row, hot) {
    st := hot ? row.stripH : row.stripN
    if !st || row.HasOwnProp("dead")
        return
    try {
        w := row.lbFull, h := row.h, off := Floor(row.off)
        lbH := row.lb.Hwnd
        hdc := DllCall("GetDC", "Ptr", lbH, "Ptr")
        first := Min(w, row.stripW - off)
        DllCall("BitBlt", "Ptr", hdc, "Int", 0, "Int", 0, "Int", first, "Int", h, "Ptr", st.dc, "Int", off, "Int", 0, "UInt", 0xCC0020)
        if first < w
            DllCall("BitBlt", "Ptr", hdc, "Int", first, "Int", 0, "Int", w - first, "Int", h, "Ptr", st.dc, "Int", 0, "Int", 0, "UInt", 0xCC0020)
        DllCall("ReleaseDC", "Ptr", lbH, "Ptr", hdc)
    }
}

FreeStrips(row) {
    if !row.HasOwnProp("stripN")
        return
    for st in [row.stripN, row.stripH]
        if st {
            DllCall("SelectObject", "Ptr", st.dc, "Ptr", st.old)
            DllCall("DeleteObject", "Ptr", st.bmp)
            DllCall("DeleteDC", "Ptr", st.dc)
        }
    row.stripN := 0, row.stripH := 0
}

Cref(rgbHex) {   ; "RRGGBB" -> COLORREF
    v := Integer("0x" rgbHex)
    return ((v >> 16) & 0xFF) | (v & 0xFF00) | ((v & 0xFF) << 16)
}

TextWidth(hFont, str) {
    hdc := DllCall("GetDC", "Ptr", 0, "Ptr")
    old := DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    sz := Buffer(8, 0)
    DllCall("GetTextExtentPoint32", "Ptr", hdc, "Str", str, "Int", StrLen(str), "Ptr", sz)
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    return NumGet(sz, 0, "Int")
}

; =====================================================================
;  Translate screen
;  Screenshot -> Windows' built-in text recognition -> translator -> frozen, translated
;  copy of the screen on top, with "Show original" and "Close" buttons.
; =====================================================================
; Checks the translate settings; returns the target language or "" (after explaining what to fix)
TrTargetLang() {
    to := TR_TO != "" ? TR_TO : WindowsLang()
    if to = "" || to = TR_FROM {
        MsgBox("Choose the language to translate into: tray icon > Settings > [Translate] To= (for example To=es), "
            . "save, then Reload.", "S Pen Menu - Translate", "Icon!")
        return ""
    }
    if TR_PROVIDER != "mymemory" && TR_PROVIDER != "googlefree" && TR_KEY = "" {
        MsgBox("The translator '" TR_PROVIDER "' needs an ApiKey in the settings ([Translate] ApiKey=).", "S Pen Menu - Translate", "Icon!")
        return ""
    }
    return to
}

; The PowerShell helper (written to Temp once per run)
WriteTranslatePS() {
    static ps := A_Temp "\spen_translate_v30.ps1", written := false
    if !written || !FileExist(ps) {
        try FileDelete(ps)
        FileAppend(TranslatePS(), ps, "UTF-8")
        written := true
    }
    return ps
}

PsCmd(mode, img, out, inFile, to) {
    EnvSet("SPEN_TR_KEY", TR_KEY)            ; the key goes via the environment, not the command line
    return 'powershell -NoProfile -ExecutionPolicy Bypass -File "' WriteTranslatePS() '" -mode ' mode ' -img "' img
        . '" -out "' out '" -in "' inFile '" -from "' TR_FROM '" -to "' to '" -provider "' TR_PROVIDER
        . '" -region "' TR_REGION '" -email "' TR_EMAIL '"'
}

; Whole-screen translation. hbmIn/mIn = reuse a screenshot (from the select overlay's "Whole screen" button)
TranslateScreen(hbmIn := 0, mIn := 0) {
    global gTr
    static busy := false
    if busy
        return
    if gTr.gui
        return CloseTranslate()
    if gSel.gui
        CloseSelect()
    if (to := TrTargetLang()) = "" {
        if hbmIn
            DllCall("DeleteObject", "Ptr", hbmIn)
        return
    }
    busy := true
    try {
        DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
        if hbmIn {
            hbm := hbmIn, m := mIn
        } else {
            HideMenu()
            Sleep(120)                           ; let the menu disappear before the screenshot
            CursorPos(&x, &y)
            m := MonitorAt(x, y, true)
            hbm := CaptureScreen(m.l, m.t, m.r - m.l, m.b - m.t)
        }
        w := m.r - m.l, h := m.b - m.t
        img := A_Temp "\spen_translate.png", out := A_Temp "\spen_translate.txt"
        for f in [img, out, img ".small.png"]
            try FileDelete(f)
        SaveHBitmapPng(hbm, img)
        ShowBusy(m, "Translating…")
        code := RunWait(PsCmd("full", img, out, "", to), , "Hide")
        HideBusy()
        res := FileExist(out) ? FileRead(out, "UTF-8") : ""
        for f in [img, out, img ".small.png"]
            try FileDelete(f)
        lines := StrSplit(res, "`n", "`r")
        head := StrSplit(lines.Length ? lines[1] : "", "`t")
        if head[1] != "OK" {
            DllCall("DeleteObject", "Ptr", hbm)
            TrayTip("Translate failed: " (head.Length >= 2 ? head[2] : "PowerShell code " code), "S Pen Menu", 3)
            return
        }
        blocks := []
        loop lines.Length - 1 {
            f := StrSplit(lines[A_Index + 1], "`t")
            if f.Length < 6 || f[6] = ""
                continue
            blocks.Push({x: Integer(f[1]), y: Integer(f[2]), w: Integer(f[3]), h: Integer(f[4]), lineH: Integer(f[5]), text: f[6]})
        }
        if !blocks.Length {
            DllCall("DeleteObject", "Ptr", hbm)
            TrayTip("No text found on the screen", "S Pen Menu")
            return
        }
        tb := TrToolbarLayout(w, m.dpi / 96)
        hbmTr := RenderTranslation(hbm, w, h, blocks, m.dpi, tb)               ; translated + buttons
        hbmOrig := RenderToolbarOnly(hbm, m.dpi, tb, "Show translation")       ; original + buttons
        DllCall("DeleteObject", "Ptr", hbm)
        ShowTranslateOverlay(m, w, h, hbmTr, hbmOrig, tb)
    } finally {
        busy := false
        HideBusy()
    }
}

WindowsLang() {   ; Windows display language, e.g. "pl"
    buf := Buffer(170, 0)
    DllCall("LCIDToLocaleName", "UInt", DllCall("GetUserDefaultUILanguage", "UShort"), "Ptr", buf, "Int", 85, "UInt", 0)
    return StrLower(StrSplit(StrGet(buf), "-")[1])
}

CaptureScreen(x, y, w, h) {
    hdcS := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcM := DllCall("CreateCompatibleDC", "Ptr", hdcS, "Ptr")
    hbm := DllCall("CreateCompatibleBitmap", "Ptr", hdcS, "Int", w, "Int", h, "Ptr")
    old := DllCall("SelectObject", "Ptr", hdcM, "Ptr", hbm, "Ptr")
    DllCall("BitBlt", "Ptr", hdcM, "Int", 0, "Int", 0, "Int", w, "Int", h, "Ptr", hdcS, "Int", x, "Int", y, "UInt", 0x40CC0020)
    DllCall("SelectObject", "Ptr", hdcM, "Ptr", old)
    DllCall("DeleteDC", "Ptr", hdcM)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcS)
    return hbm
}

SaveHBitmapPng(hbm, path) {
    GdipStart()
    pBmp := 0, clsid := Buffer(16)
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", &pBmp)
    DllCall("ole32\CLSIDFromString", "Str", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)   ; PNG encoder
    DllCall("gdiplus\GdipSaveImageToFile", "Ptr", pBmp, "Str", path, "Ptr", clsid, "Ptr", 0)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
}

ShowBusy(m, text) {   ; small "Translating…" pill at the top of the screen (never takes focus)
    global gBusy
    HideBusy()
    s := m.dpi / 96, w := Round(190 * s), h := Round(40 * s)
    g := Gui("-Caption +AlwaysOnTop +ToolWindow -DPIScale +E0x08000000")
    g.BackColor := MENU_BG
    g.SetFont("c" MENU_TEXT)
    t := g.AddText("x0 y0 w" w " h" h " 0x201", text)
    SendMessage(0x30, MakeFont("Segoe UI", FONT_PT, m.dpi), 1, t)
    g.Show("NA x" (m.l + (m.r - m.l - w) // 2) " y" (m.t + Round(20 * s)) " w" w " h" h)
    DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "UInt", 33, "Int*", 2, "UInt", 4)
    gBusy := g
}

HideBusy() {
    global gBusy
    if gBusy
        gBusy.Destroy()
    gBusy := 0
}

RenderTranslation(hbm, w, h, blocks, dpi, tb) {
    GdipStart()
    s := dpi / 96
    pBmp := 0, g := 0, fmt := 0, out := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", &pBmp)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBmp, "Ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 4)
    brDim := GpBrush(0x38000000), brBox := GpBrush(0xF0202124), brTxt := GpBrush(0xFFFFFFFF)
    DllCall("gdiplus\GdipFillRectangleI", "Ptr", g, "Ptr", brDim, "Int", 0, "Int", 0, "Int", w, "Int", h)
    fam := GpFamily()
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "Int", 0, "Ptr*", &fmt)
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmt, "Int", 1)       ; centred vertically
    minPx := 11 * s
    for b in blocks {
        pad := Max(Round(3 * s), Round(b.lineH * 0.2))
        bx := b.x - pad, by := b.y - pad, bw := b.w + 2 * pad, bh := b.h + 2 * pad
        if bw < 60 * s                                  ; tiny words: give the translation some room
            bx -= (60 * s - bw) / 2, bw := 60 * s
        size := Max(minPx, b.lineH * 0.82)
        loop {                                          ; shrink the text until it fits the box
            font := GpFont(fam, size)
            GpMeasure(g, b.text, font, fmt, bw - 2 * pad, &tw, &th)
            if th <= bh - pad || size <= minPx
                break
            DllCall("gdiplus\GdipDeleteFont", "Ptr", font)
            size := Max(minPx, size * 0.9)
        }
        if th > bh - pad
            bh := th + pad                              ; still too long -> grow the box downwards
        bx := Max(0, Min(bx, w - bw)), by := Max(0, Min(by, h - bh))
        GpRoundRect(g, brBox, bx, by, bw, bh, Min(6 * s, bh / 2))
        GpText(g, b.text, font, fmt, brTxt, bx + pad, by, bw - 2 * pad, bh)
        DllCall("gdiplus\GdipDeleteFont", "Ptr", font)
    }
    DrawTrToolbar(g, fam, tb, s, "Show original")
    for br in [brDim, brBox, brTxt]
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmt)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", fam)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBmp, "Ptr*", &out, "UInt", 0xFF000000)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
    return out
}

; Two buttons at the top of the translated screen (same place on both images)
TrToolbarLayout(w, s) {
    bh := Round(44 * s), gap := Round(10 * s), bw1 := Round(190 * s), bw2 := Round(120 * s)
    x := (w - bw1 - gap - bw2) // 2, y := Round(18 * s)
    return {s: s, toggle: {x: x, y: y, w: bw1, h: bh}, close: {x: x + bw1 + gap, y: y, w: bw2, h: bh}}
}

DrawTrToolbar(g, fam, tb, s, toggleText) {
    DrawPills(g, fam, s, [[tb.toggle, 0xFA1A73E8, toggleText], [tb.close, 0xF5303134, "Close"]])
}

; Rounded "pill" buttons with a soft shadow: items = [[rect, argb, text], ...]
DrawPills(g, fam, s, items) {
    fmtC := 0
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "Int", 0, "Ptr*", &fmtC)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmtC, "Int", 1)
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmtC, "Int", 1)
    font := GpFont(fam, 15 * s)
    brShadow := GpBrush(0x50000000), brTxt := GpBrush(0xFFFFFFFF)
    for it in items {
        r := it[1], br := GpBrush(it[2])
        GpRoundRect(g, brShadow, r.x, r.y + 2 * s, r.w, r.h, r.h / 2)
        GpRoundRect(g, br, r.x, r.y, r.w, r.h, r.h / 2)
        GpText(g, it[3], font, fmtC, brTxt, r.x, r.y, r.w, r.h)
        DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
    }
    DllCall("gdiplus\GdipDeleteFont", "Ptr", font)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brShadow)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brTxt)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmtC)
}

RenderToolbarOnly(hbm, dpi, tb, toggleText) {   ; copy of the screenshot with the two buttons on it
    GdipStart()
    pBmp := 0, g := 0, out := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", &pBmp)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBmp, "Ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 4)
    fam := GpFamily()
    DrawTrToolbar(g, fam, tb, dpi / 96, toggleText)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", fam)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBmp, "Ptr*", &out, "UInt", 0xFF000000)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
    return out
}

GpFamily() {   ; Segoe UI, or the default font if it's missing
    fam := 0
    DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", "Segoe UI", "Ptr", 0, "Ptr*", &fam)
    if !fam
        DllCall("gdiplus\GdipGetGenericFontFamilySansSerif", "Ptr*", &fam)
    return fam
}

GpBrush(argb) {
    b := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &b)
    return b
}
GpFont(fam, px) {
    f := 0
    DllCall("gdiplus\GdipCreateFont", "Ptr", fam, "Float", px, "Int", 0, "Int", 2, "Ptr*", &f)   ; regular, pixels
    return f
}
GpMeasure(g, text, font, fmt, maxW, &outW, &outH) {
    rc := Buffer(16, 0), box := Buffer(16, 0)
    NumPut("Float", maxW, rc, 8), NumPut("Float", 100000, rc, 12)
    DllCall("gdiplus\GdipMeasureString", "Ptr", g, "WStr", text, "Int", -1, "Ptr", font, "Ptr", rc, "Ptr", fmt
        , "Ptr", box, "Ptr", 0, "Ptr", 0)
    outW := NumGet(box, 8, "Float"), outH := NumGet(box, 12, "Float")
}
GpText(g, text, font, fmt, br, x, y, w, h) {
    rc := Buffer(16, 0)
    NumPut("Float", x, rc, 0), NumPut("Float", y, rc, 4), NumPut("Float", w, rc, 8), NumPut("Float", h, rc, 12)
    DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", text, "Int", -1, "Ptr", font, "Ptr", rc, "Ptr", fmt, "Ptr", br)
}
GpRoundRect(g, br, x, y, w, h, r) {
    path := 0, d := Max(1, r * 2)
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &path)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x, "Float", y, "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y, "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y + h - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x, "Float", y + h - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", path)
    DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", br, "Ptr", path)
    DllCall("gdiplus\GdipDeletePath", "Ptr", path)
}

ShowTranslateOverlay(m, w, h, hbmTr, hbmOrig, tb) {
    global gTr
    g := Gui("-Caption +AlwaysOnTop +ToolWindow -DPIScale")
    g.MarginX := 0, g.MarginY := 0
    pic := g.AddPicture("x0 y0 w" w " h" h " +0x100", "HBITMAP:*" hbmTr)    ; 0x100 = receives taps
    g.OnEvent("Escape", (*) => CloseTranslate())
    g.Show("Hide x" m.l " y" m.t " w" w " h" h)
    DllCall("SetWindowPos", "Ptr", g.Hwnd, "Ptr", -1, "Int", m.l, "Int", m.t, "Int", w, "Int", h, "UInt", 0x40)
    WinActivate(g.Hwnd)
    gTr := {gui: g, pic: pic, hbmTr: hbmTr, hbmOrig: hbmOrig, tb: tb, w: w, h: h, orig: false, wasActive: false}
    SetTimer(WatchTranslate, 150)
}

WatchTranslate() {           ; close if you switch to another window
    if !gTr.gui
        return SetTimer(WatchTranslate, 0)
    if WinActive("ahk_id " gTr.gui.Hwnd)
        gTr.wasActive := true
    else if gTr.wasActive
        CloseTranslate()
}

OvMouseDown(wParam, lParam, msg, hwnd) {
    x := lParam & 0xFFFF, y := (lParam >> 16) & 0xFFFF
    if gSel.gui && (hwnd = gSel.pic.Hwnd || hwnd = gSel.gui.Hwnd)
        return SelDown(x, y)
    if gTr.gui && (hwnd = gTr.pic.Hwnd || hwnd = gTr.gui.Hwnd)
        return 0
}

OvMouseMove(wParam, lParam, msg, hwnd) {
    if gSel.gui && gSel.down && (hwnd = gSel.pic.Hwnd || hwnd = gSel.gui.Hwnd) {
        x := lParam & 0xFFFF, y := (lParam >> 16) & 0xFFFF
        x := x > 0x7FFF ? x - 0x10000 : x, y := y > 0x7FFF ? y - 0x10000 : y   ; dragged off-screen (captured)
        SelMove(x, y)
        return 0
    }
}

OvMouseUp(wParam, lParam, msg, hwnd) {
    x := lParam & 0xFFFF, y := (lParam >> 16) & 0xFFFF
    x := x > 0x7FFF ? x - 0x10000 : x, y := y > 0x7FFF ? y - 0x10000 : y
    if gSel.gui && (hwnd = gSel.pic.Hwnd || hwnd = gSel.gui.Hwnd)
        return SelUp(x, y)
    if gTr.gui && (hwnd = gTr.pic.Hwnd || hwnd = gTr.gui.Hwnd)
        return TrMouseUp(x, y)
}

; Whole-screen overlay buttons: "Show original / Show translation" toggles, "Close" closes.
TrMouseUp(x, y) {
    global gTr
    if InRect(gTr.tb.toggle, x, y) {
        gTr.orig := !gTr.orig
        TrSwap(gTr.orig ? gTr.hbmOrig : gTr.hbmTr)
    } else if InRect(gTr.tb.close, x, y)
        SetTimer(CloseTranslate, -1)
    return 0
}

; Swap a full-screen picture with no flash: change it without a repaint (which would blank it first),
; then copy the new image straight onto the screen in one go. keep* = our own bitmaps (never deleted here).
SwapPicture(pic, hbm, w, h, keep*) {
    SendMessage(0x000B, 0, 0, pic)                          ; WM_SETREDRAW off
    prev := SendMessage(0x0172, 0, hbm, pic)                ; STM_SETIMAGE
    ours := false
    for k in keep
        if prev = k
            ours := true
    if prev && !ours
        DllCall("DeleteObject", "Ptr", prev)                ; the control's private copy of the old image
    SendMessage(0x000B, 1, 0, pic)                          ; WM_SETREDRAW on (no repaint)
    hdc := DllCall("GetDC", "Ptr", pic, "Ptr")
    mdc := DllCall("CreateCompatibleDC", "Ptr", hdc, "Ptr")
    old := DllCall("SelectObject", "Ptr", mdc, "Ptr", hbm, "Ptr")
    DllCall("BitBlt", "Ptr", hdc, "Int", 0, "Int", 0, "Int", w, "Int", h, "Ptr", mdc, "Int", 0, "Int", 0, "UInt", 0xCC0020)
    DllCall("SelectObject", "Ptr", mdc, "Ptr", old)
    DllCall("DeleteDC", "Ptr", mdc)
    DllCall("ReleaseDC", "Ptr", pic, "Ptr", hdc)
}

TrSwap(hbm) => SwapPicture(gTr.pic.Hwnd, hbm, gTr.w, gTr.h, gTr.hbmTr, gTr.hbmOrig)

InRect(r, x, y) => x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h

CloseTranslate() {
    global gTr
    SetTimer(WatchTranslate, 0)
    if !gTr.gui
        return
    old := gTr
    gTr := {gui: 0}
    try {
        prev := SendMessage(0x0172, 0, 0, old.pic.Hwnd)     ; take the image back so nothing leaks
        if prev && prev != old.hbmTr && prev != old.hbmOrig
            DllCall("DeleteObject", "Ptr", prev)
    }
    old.gui.Destroy()
    DllCall("DeleteObject", "Ptr", old.hbmTr)
    DllCall("DeleteObject", "Ptr", old.hbmOrig)
}

; PowerShell helper: Windows OCR (built in, offline) + translation. Modes:
;   full - read + translate everything -> "OK<tab>count", then: x y w h lineHeight translation (per block)
;   ocr  - only read the screen        -> "OK", then L idx block x y w h / W line x y w h text
;   text - translate the text in -in   -> "OK<tab>translation"
TranslatePS() {
    return "
    (
param([string]$mode = 'full', [string]$img, [string]$out, [string]$in, [string]$from, [string]$to, [string]$provider, [string]$region, [string]$email)
$ErrorActionPreference = 'Stop'
$tab = [string][char]9
$nl = [string][char]10
$key = $env:SPEN_TR_KEY
function Finish([string]$text) { [IO.File]::WriteAllText($out, $text, (New-Object Text.UTF8Encoding($false))); exit 0 }
function Clean([string]$s) { return ($s -replace '\s+', ' ').Trim() }

# ======== text recognition (Windows OCR, built in, offline) ========
function Read-Screen {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  Add-Type -AssemblyName System.Drawing
  $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
  $null = [Windows.Storage.Streams.RandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
  $null = [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]
  $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -like 'IAsyncOperation?1' } | Select-Object -First 1
  function Await($op, [Type]$type) { $t = $asTask.MakeGenericMethod($type).Invoke($null, @($op)); [void]$t.Wait(-1); $t.Result }

  $engine = $null
  if ($from) { try { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new($from)) } catch { $engine = $null } }
  if (-not $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
  if (-not $engine) { Finish ('ERROR' + $tab + 'no text-recognition language installed - see README') }
  $max = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
  $src = [Drawing.Image]::FromFile($img)
  $scale = 1.0
  $ocrPath = $img
  $big = [Math]::Max($src.Width, $src.Height)
  if ($big -gt $max) {
    $scale = $max / $big
    $small = New-Object Drawing.Bitmap($src, [int]($src.Width * $scale), [int]($src.Height * $scale))
    $ocrPath = $img + '.small.png'
    $small.Save($ocrPath, [Drawing.Imaging.ImageFormat]::Png)
    $small.Dispose()
  }
  $src.Dispose()
  $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($ocrPath)) ([Windows.Storage.StorageFile])
  $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $ocr = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
  $stream.Dispose()

  # lines (with their words)
  $lines = New-Object System.Collections.ArrayList
  foreach ($ln in $ocr.Lines) {
    $words = New-Object System.Collections.ArrayList
    $l = [double]::MaxValue; $t = [double]::MaxValue; $r = -1.0; $b = -1.0
    foreach ($wd in $ln.Words) {
      $rc = $wd.BoundingRect
      [void]$words.Add([pscustomobject]@{ text = $wd.Text; x = $rc.X / $scale; y = $rc.Y / $scale; w = $rc.Width / $scale; h = $rc.Height / $scale })
      $l = [Math]::Min($l, $rc.X); $t = [Math]::Min($t, $rc.Y)
      $r = [Math]::Max($r, $rc.X + $rc.Width); $b = [Math]::Max($b, $rc.Y + $rc.Height)
    }
    if ($r -lt 0) { continue }
    [void]$lines.Add([pscustomobject]@{ text = $ln.Text; l = $l / $scale; t = $t / $scale; r = $r / $scale; b = $b / $scale; words = $words; block = -1 })
  }
  # blocks: lines of the same paragraph are translated together
  $blocks = New-Object System.Collections.ArrayList
  foreach ($ln in $lines) {
    $lh = $ln.b - $ln.t
    $last = $null
    if ($blocks.Count -gt 0) { $last = $blocks[$blocks.Count - 1] }
    $join = $false
    if ($last) {
      $gap = $ln.t - $last.lastB
      $similar = [Math]::Abs($lh - $last.lastH) -le (0.35 * [Math]::Max($lh, $last.lastH))
      $overlap = ($ln.l -lt $last.r) -and ($ln.r -gt $last.l)
      $join = $similar -and $overlap -and ($gap -gt (-0.3 * $lh)) -and ($gap -lt (0.9 * $lh))
    }
    if ($join) {
      $last.text = $last.text + ' ' + $ln.text
      $last.l = [Math]::Min($last.l, $ln.l); $last.r = [Math]::Max($last.r, $ln.r); $last.b = [Math]::Max($last.b, $ln.b)
      $last.lastB = $ln.b; $last.lastH = $lh
    } else {
      [void]$blocks.Add([pscustomobject]@{ text = $ln.text; l = $ln.l; t = $ln.t; r = $ln.r; b = $ln.b; lastB = $ln.b; lastH = $lh; lineH = $lh })
    }
    $ln.block = $blocks.Count - 1
  }
  return @{ lines = $lines; blocks = $blocks }
}

# ======== translation ========
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = 8
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(20)

function PostJson([string]$url, $obj, $headers) {
  $json = ConvertTo-Json -InputObject $obj -Depth 6 -Compress
  $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $url)
  foreach ($k in $headers.Keys) { [void]$req.Headers.TryAddWithoutValidation($k, [string]$headers[$k]) }
  $req.Content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
  $resp = $client.SendAsync($req).Result
  $body = [Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().Result)
  if (-not $resp.IsSuccessStatusCode) { throw ('translator said ' + [int]$resp.StatusCode + ': ' + $body) }
  return (ConvertFrom-Json $body)
}
function Slice($arr, [int]$i, [int]$n) { return @($arr[$i..([Math]::Min($i + $n - 1, $arr.Count - 1))]) }

# MyMemory: free, no account. One request per text, sent in parallel.
function MyMemoryAll($texts) {
  $src2 = 'en'
  if ($from) { $src2 = $from }
  $tasks = New-Object System.Collections.ArrayList
  foreach ($tx in $texts) {
    $q = [string]$tx
    if ($q.Length -gt 450) { $q = $q.Substring(0, 450) }
    $u = 'https://api.mymemory.translated.net/get?q=' + [uri]::EscapeDataString($q) + '&langpair=' + $src2 + '%7C' + $to
    if ($email) { $u = $u + '&de=' + [uri]::EscapeDataString($email) }
    [void]$tasks.Add($client.GetByteArrayAsync($u))
  }
  try { [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks.ToArray()) } catch { }
  $list = New-Object System.Collections.ArrayList
  foreach ($tk in $tasks) {
    $tr = ''
    if ($tk.Status -eq 'RanToCompletion') {
      $j = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($tk.Result))
      $tr = [string]$j.responseData.translatedText
      if ($tr -like 'MYMEMORY WARNING*') { throw 'the free MyMemory limit for today is used up - add Email= in the settings or pick another translator' }
      if ([int]$j.responseStatus -ne 200) { $tr = '' }
    }
    [void]$list.Add([System.Net.WebUtility]::HtmlDecode($tr))
  }
  return $list
}

# Free Google Translate (the unofficial endpoint free bots and extensions use)
function GoogleOne([string]$q) {
  $sl = 'auto'
  if ($from) { $sl = $from }
  $u = 'https://translate.googleapis.com/translate_a/single?client=gtx&dt=t&ie=UTF-8&oe=UTF-8&sl=' + $sl + '&tl=' + $to + '&q=' + [uri]::EscapeDataString($q)
  $resp = $client.GetAsync($u).Result
  if (-not $resp.IsSuccessStatusCode) { throw ('Google said ' + [int]$resp.StatusCode) }
  $j = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().Result))
  $sbg = New-Object Text.StringBuilder
  foreach ($seg in $j[0]) { if ($seg -and $seg[0]) { [void]$sbg.Append([string]$seg[0]) } }
  return $sbg.ToString()
}
# many texts per request (joined by line breaks), split back afterwards
function GoogleFreeAll($texts) {
  $list = New-Object System.Collections.ArrayList
  $i = 0
  while ($i -lt $texts.Count) {
    $chunk = New-Object System.Collections.ArrayList
    $len = 0
    while ($i -lt $texts.Count -and ($chunk.Count -eq 0 -or ($len + ([string]$texts[$i]).Length) -lt 1200)) {
      [void]$chunk.Add([string]$texts[$i]); $len += ([string]$texts[$i]).Length + 1; $i++
    }
    $parts = @((GoogleOne ($chunk -join $nl)).TrimEnd() -split $nl)
    if ($parts.Count -eq $chunk.Count) {
      foreach ($x in $parts) { [void]$list.Add($x.Trim()) }
    } else {
      foreach ($c in $chunk) { [void]$list.Add((GoogleOne $c).Trim()) }
    }
  }
  return $list
}

function Translate-All($texts) {
  $res = New-Object System.Collections.ArrayList
  $p = $provider.ToLower()
  if ($p -eq 'deepl') {
    $base = 'https://api.deepl.com'
    if ($key.EndsWith(':fx')) { $base = 'https://api-free.deepl.com' }
    for ($i = 0; $i -lt $texts.Count; $i += 50) {
      $body = @{ text = @(Slice $texts $i 50); target_lang = $to.ToUpper() }
      if ($from) { $body['source_lang'] = $from.ToUpper() }
      $r = PostJson ($base + '/v2/translate') $body @{ Authorization = ('DeepL-Auth-Key ' + $key) }
      foreach ($x in $r.translations) { [void]$res.Add([string]$x.text) }
    }
  } elseif ($p -eq 'azure') {
    $url = 'https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=' + $to
    if ($from) { $url = $url + '&from=' + $from }
    $hd = @{ 'Ocp-Apim-Subscription-Key' = $key }
    if ($region) { $hd['Ocp-Apim-Subscription-Region'] = $region }
    for ($i = 0; $i -lt $texts.Count; $i += 100) {
      $chunk = @(Slice $texts $i 100 | ForEach-Object { @{ Text = $_ } })
      $r = PostJson $url $chunk $hd
      foreach ($x in $r) { [void]$res.Add([string]$x.translations[0].text) }
    }
  } elseif ($p -eq 'google') {
    for ($i = 0; $i -lt $texts.Count; $i += 100) {
      $body = @{ q = @(Slice $texts $i 100); target = $to; format = 'text' }
      if ($from) { $body['source'] = $from }
      $r = PostJson ('https://translation.googleapis.com/language/translate/v2?key=' + [uri]::EscapeDataString($key)) $body @{}
      foreach ($x in $r.data.translations) { [void]$res.Add([string]$x.translatedText) }
    }
  } elseif ($p -eq 'googlefree') {
    try {
      foreach ($x in (GoogleFreeAll $texts)) { [void]$res.Add($x) }
    } catch {
      $res.Clear()
      foreach ($x in (MyMemoryAll $texts)) { [void]$res.Add($x) }      # Google blocked -> MyMemory
    }
  } else {
    foreach ($x in (MyMemoryAll $texts)) { [void]$res.Add($x) }
  }
  if (-not ($res | Where-Object { $_ })) { throw 'could not reach the translation service' }
  return $res
}

# ======== main ========
# modes: text = translate the text in -in   |   ocr = only read the screen   |   full = read + translate everything
try {
  if ($mode -eq 'text') {
    [string[]]$one = @(Clean ([IO.File]::ReadAllText($in, [Text.Encoding]::UTF8)))
    $r = @(Translate-All $one)
    Finish ('OK' + $tab + (Clean ([string]$r[0])))
  }
  $scr = Read-Screen
  if ($mode -eq 'ocr') {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('OK' + $nl)
    for ($i = 0; $i -lt $scr.lines.Count; $i++) {
      $ln = $scr.lines[$i]
      [void]$sb.Append((@('L', $i, $ln.block, [int]$ln.l, [int]$ln.t, [int]($ln.r - $ln.l), [int]($ln.b - $ln.t)) -join $tab) + $nl)
      foreach ($wd in $ln.words) {
        [void]$sb.Append((@('W', $i, [int]$wd.x, [int]$wd.y, [int][Math]::Ceiling($wd.w), [int][Math]::Ceiling($wd.h), (Clean $wd.text)) -join $tab) + $nl)
      }
    }
    Finish $sb.ToString()
  }
  $blocks = $scr.blocks
  if ($blocks.Count -eq 0) { Finish ('OK' + $tab + '0' + $nl) }
  [string[]]$texts = @($blocks | ForEach-Object { [string]$_.text })
  $res = @(Translate-All $texts)
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append('OK' + $tab + $blocks.Count + $nl)
  for ($i = 0; $i -lt $blocks.Count; $i++) {
    $bk = $blocks[$i]
    $tr = ''
    if ($i -lt $res.Count) { $tr = Clean ([string]$res[$i]) }
    [void]$sb.Append((@([int]$bk.l, [int]$bk.t, [int]($bk.r - $bk.l), [int]($bk.b - $bk.t), [int]$bk.lineH, $tr) -join $tab) + $nl)
  }
  Finish $sb.ToString()
} catch {
  Finish ('ERROR' + $tab + (Clean $_.Exception.GetBaseException().Message))
}
    )"
}

; =====================================================================
;  Select & translate  (like Circle to Search)
;  Freezes the screen under a glowing blue layer. Circle / scribble over text or tap a line,
;  and its translation appears in a card just below (or above) it. The screen's text is read in
;  the background as soon as the layer opens, so translations come back quickly.
; =====================================================================
TranslateSelect() {
    global gSel
    if gSel.gui
        return CloseSelect()
    if gTr.gui
        CloseTranslate()
    if (to := TrTargetLang()) = ""
        return
    HideMenu()
    Sleep(120)                                   ; let the menu disappear before the screenshot
    DllCall("SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")
    CursorPos(&x, &y)
    m := MonitorAt(x, y, true)
    w := m.r - m.l, h := m.b - m.t, s := m.dpi / 96
    hbm := CaptureScreen(m.l, m.t, w, h)
    tb := SelToolbarLayout(w, s)
    base := RenderSelectBase(hbm, w, h, s, tb)
    ; start reading the screen's text right away (in the background)
    img := A_Temp "\spen_select.png", out := A_Temp "\spen_select_ocr.txt"
    for f in [img, out, img ".small.png"]
        try FileDelete(f)
    SaveHBitmapPng(hbm, img)
    pid := 0
    Run(PsCmd("ocr", img, out, "", to), , "Hide", &pid)
    g := Gui("-Caption +AlwaysOnTop +ToolWindow -DPIScale")
    g.MarginX := 0, g.MarginY := 0
    pic := g.AddPicture("x0 y0 w" w " h" h " +0x100", "HBITMAP:*" base)     ; 0x100 = receives taps
    g.OnEvent("Escape", (*) => CloseSelect())
    g.Show("Hide x" m.l " y" m.t " w" w " h" h)
    DllCall("SetWindowPos", "Ptr", g.Hwnd, "Ptr", -1, "Int", m.l, "Int", m.t, "Int", w, "Int", h, "UInt", 0x40)
    WinActivate(g.Hwnd)
    gSel := {gui: g, pic: pic, m: m, w: w, h: h, s: s, tb: tb, to: to, hbmShot: hbm, hbmBase: base, hbmShown: base
        , ocrPid: pid, ocrOut: out, img: img, words: 0, lines: 0, ocrErr: "", pending: 0
        , down: false, btn: "", pts: [], len: 0
        , trPid: 0, trOut: "", trIn: "", trId: 0, selRect: 0, selWords: [], copyRect: 0, translation: "", copied: false
        , wasActive: false}
    SetTimer(SelPoll, 100)
    SetTimer(WatchSelect, 150)
}

SelToolbarLayout(w, s) {   ; hint + "Whole screen" + "Close" across the top
    bh := Round(44 * s), gap := Round(10 * s)
    hw := Round(290 * s), ww := Round(160 * s), cw := Round(110 * s)
    x := (w - hw - ww - cw - 2 * gap) // 2, y := Round(18 * s)
    return {s: s, hint: {x: x, y: y, w: hw, h: bh}, whole: {x: x + hw + gap, y: y, w: ww, h: bh}
        , close: {x: x + hw + ww + 2 * gap, y: y, w: cw, h: bh}}
}

; Frozen screen + light blue veil + glowing edges + toolbar
RenderSelectBase(hbm, w, h, s, tb) {
    GdipStart()
    pBmp := 0, g := 0, out := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", &pBmp)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBmp, "Ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 4)
    br := GpBrush(0x301A73E8)                                       ; the blue layer
    DllCall("gdiplus\GdipFillRectangleI", "Ptr", g, "Ptr", br, "Int", 0, "Int", 0, "Int", w, "Int", h)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
    n := 22                                                         ; glow: bands fading in from the edges
    loop n {
        i := A_Index - 1, f := 1 - i / n
        a := Round(170 * f * f)
        col := (a << 24) | (i < n / 3 ? 0x8AB4FF : 0x5B8CFF)
        pen := 0, inset := (i + 0.5) * 2 * s
        DllCall("gdiplus\GdipCreatePen1", "UInt", col, "Float", 2 * s, "Int", 2, "Ptr*", &pen)
        DllCall("gdiplus\GdipDrawRectangle", "Ptr", g, "Ptr", pen, "Float", inset, "Float", inset, "Float", w - 2 * inset, "Float", h - 2 * inset)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    }
    fam := GpFamily()
    DrawPills(g, fam, s, [[tb.hint, 0xE6202124, "Circle or tap text to translate"]
        , [tb.whole, 0xFA1A73E8, "Whole screen"], [tb.close, 0xF5303134, "Close"]])
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", fam)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBmp, "Ptr*", &out, "UInt", 0xFF000000)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
    return out
}

SelShow(hbm) {   ; show a new picture without flashing; free the previous temporary one
    global gSel
    old := gSel.hbmShown
    SwapPicture(gSel.pic.Hwnd, hbm, gSel.w, gSel.h, gSel.hbmBase, old, hbm)
    gSel.hbmShown := hbm
    if old && old != gSel.hbmBase && old != hbm
        DllCall("DeleteObject", "Ptr", old)
}

SelDown(x, y) {
    global gSel
    for name in ["whole", "close"]
        if InRect(gSel.tb.%name%, x, y) {
            gSel.btn := name
            return 0
        }
    if gSel.copyRect && InRect(gSel.copyRect, x, y) {
        gSel.btn := "copy"
        return 0
    }
    gSel.btn := "", gSel.down := true, gSel.pts := [[x, y]], gSel.len := 0
    DllCall("SetCapture", "Ptr", gSel.pic.Hwnd)
    if gSel.hbmShown != gSel.hbmBase                ; clear the previous selection + card
        SelShow(gSel.hbmBase)
    SelStroke(x, y, x, y)
    return 0
}

SelMove(x, y) {
    global gSel
    p := gSel.pts[gSel.pts.Length]
    d := Sqrt((x - p[1]) ** 2 + (y - p[2]) ** 2)
    if d < 2
        return
    SelStroke(p[1], p[2], x, y)
    gSel.pts.Push([x, y]), gSel.len += d
}

SelStroke(x1, y1, x2, y2) {   ; glowing white line, drawn straight onto the screen while you draw
    hdc := DllCall("GetDC", "Ptr", gSel.pic.Hwnd, "Ptr"), g := 0, s := gSel.s
    DllCall("gdiplus\GdipCreateFromHDC", "Ptr", hdc, "Ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
    for spec in [[0x38FFFFFF, 16 * s], [0xF2FFFFFF, 5 * s]] {
        pen := 0
        DllCall("gdiplus\GdipCreatePen1", "UInt", spec[1], "Float", spec[2], "Int", 2, "Ptr*", &pen)
        DllCall("gdiplus\GdipSetPenStartCap", "Ptr", pen, "Int", 2)
        DllCall("gdiplus\GdipSetPenEndCap", "Ptr", pen, "Int", 2)
        DllCall("gdiplus\GdipDrawLine", "Ptr", g, "Ptr", pen, "Float", x1, "Float", y1, "Float", x2, "Float", y2)
        DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    }
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("ReleaseDC", "Ptr", gSel.pic.Hwnd, "Ptr", hdc)
}

SelUp(x, y) {
    global gSel
    if gSel.btn != "" {                              ; a button: act if released on the same button
        b := gSel.btn, gSel.btn := ""
        r := (b = "copy") ? gSel.copyRect : gSel.tb.%b%
        if r && InRect(r, x, y) {
            if b = "close"
                SetTimer(CloseSelect, -1)
            else if b = "whole"
                SetTimer(SelToWhole, -1)
            else if b = "copy" && gSel.translation != "" {
                A_Clipboard := gSel.translation
                gSel.copied := true
                SelRender(gSel.translation, true)
            }
        }
        return 0
    }
    if !gSel.down
        return 0
    gSel.down := false
    DllCall("ReleaseCapture")
    if gSel.len < 12 * gSel.s
        req := {tap: true, x: x, y: y, w: 1, h: 1}  ; tap -> that line's paragraph
    else {
        l := 1e9, t := 1e9, r := -1e9, b := -1e9
        for p in gSel.pts
            l := Min(l, p[1]), t := Min(t, p[2]), r := Max(r, p[1]), b := Max(b, p[2])
        req := {tap: false, x: l, y: t, w: r - l, h: b - t}     ; circle/scribble -> words inside it
    }
    if !gSel.words {                                 ; still reading the screen -> do it when ready
        gSel.pending := req
        gSel.selWords := [], gSel.selRect := req
        SelRender("Reading the text…")
        return 0
    }
    SelApply(req)
    return 0
}

SelApply(req) {
    global gSel
    if gSel.ocrErr != "" {
        gSel.selWords := [], gSel.selRect := req
        return SelRender("Couldn't read the screen: " gSel.ocrErr)
    }
    picked := []
    if req.tap {
        tol := 8 * gSel.s, blk := ""
        for wd in gSel.words
            if req.x >= wd.x - tol && req.x < wd.x + wd.w + tol && req.y >= wd.y - tol && req.y < wd.y + wd.h + tol {
                blk := gSel.lines.Has(wd.line) ? gSel.lines[wd.line] : ""
                break
            }
        if blk != ""
            for wd in gSel.words
                if gSel.lines.Has(wd.line) && gSel.lines[wd.line] = blk
                    picked.Push(wd)
    } else {
        pad := 4 * gSel.s
        for wd in gSel.words {
            cx := wd.x + wd.w / 2, cy := wd.y + wd.h / 2
            if cx >= req.x - pad && cx <= req.x + req.w + pad && cy >= req.y - pad && cy <= req.y + req.h + pad
                picked.Push(wd)
        }
    }
    if !picked.Length {
        gSel.selWords := [], gSel.selRect := req
        return SelRender("No text there - circle or tap some text")
    }
    text := "", l := 1e9, t := 1e9, r := -1e9, b := -1e9
    for wd in picked {
        text .= (text = "" ? "" : " ") wd.text
        l := Min(l, wd.x), t := Min(t, wd.y), r := Max(r, wd.x + wd.w), b := Max(b, wd.y + wd.h)
    }
    gSel.selWords := picked, gSel.selRect := {x: l, y: t, w: r - l, h: b - t}
    gSel.translation := "", gSel.copied := false
    SelRender("Translating…")
    ; translate in the background so the screen stays responsive
    gSel.trId += 1
    inF := A_Temp "\spen_sel_in_" gSel.trId ".txt", outF := A_Temp "\spen_sel_out_" gSel.trId ".txt"
    for f in [inF, outF]
        try FileDelete(f)
    FileAppend(text, inF, "UTF-8")
    pid := 0
    Run(PsCmd("text", "", outF, inF, gSel.to), , "Hide", &pid)
    gSel.trPid := pid, gSel.trOut := outF, gSel.trIn := inF
}

; Background work: screen text read? translation back?
SelPoll() {
    global gSel
    if !gSel.gui
        return SetTimer(SelPoll, 0)
    if gSel.ocrPid && !ProcessExist(gSel.ocrPid) {
        gSel.ocrPid := 0
        SelLoadOcr()
        if gSel.pending {
            req := gSel.pending, gSel.pending := 0
            SelApply(req)
        }
    }
    if gSel.trPid && !ProcessExist(gSel.trPid) {
        gSel.trPid := 0
        res := ""
        try res := FileRead(gSel.trOut, "UTF-8")
        for f in [gSel.trOut, gSel.trIn]
            try FileDelete(f)
        parts := StrSplit(Trim(res, " `t`r`n"), "`t", , 2)
        if parts.Length = 2 && parts[1] = "OK" && parts[2] != "" {
            gSel.translation := parts[2], gSel.copied := false
            SelRender(parts[2], true)
        } else
            SelRender("Couldn't translate: " (parts.Length = 2 ? parts[2] : "no answer from the translator"))
    }
}

SelLoadOcr() {
    global gSel
    res := ""
    try res := FileRead(gSel.ocrOut, "UTF-8")
    for f in [gSel.ocrOut, gSel.img, gSel.img ".small.png"]
        try FileDelete(f)
    rows := StrSplit(res, "`n", "`r")
    lines := Map(), words := []
    if !rows.Length || SubStr(rows[1], 1, 2) != "OK" {
        f := StrSplit(rows.Length ? rows[1] : "", "`t")
        gSel.ocrErr := f.Length >= 2 ? f[2] : "text recognition didn't run"
        gSel.lines := lines, gSel.words := words
        return
    }
    for row in rows {
        f := StrSplit(row, "`t")
        if f.Length < 7
            continue
        if f[1] = "L"
            lines[Integer(f[2])] := Integer(f[3])            ; line -> paragraph (block)
        else if f[1] = "W" && f[7] != ""
            words.Push({line: Integer(f[2]), x: Integer(f[3]), y: Integer(f[4]), w: Integer(f[5]), h: Integer(f[6]), text: f[7]})
    }
    gSel.lines := lines, gSel.words := words
}

; Blue layer + highlighted words + the card
SelRender(cardText, isResult := false) {
    global gSel
    GdipStart()
    s := gSel.s, pBmp := 0, g := 0, out := 0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", gSel.hbmBase, "Ptr", 0, "Ptr*", &pBmp)
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBmp, "Ptr*", &g)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", g, "Int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", g, "Int", 4)
    br := GpBrush(0x66FFFFFF)                                   ; selected words light up
    for wd in gSel.selWords
        GpRoundRect(g, br, wd.x - 3 * s, wd.y - 3 * s, wd.w + 6 * s, wd.h + 6 * s, 4 * s)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
    gSel.copyRect := SelDrawCard(g, s, gSel.w, gSel.h, gSel.selRect, cardText, isResult)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBmp, "Ptr*", &out, "UInt", 0xFF000000)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBmp)
    SelShow(out)
}

; Card just below the selection (above it if there's no room). Returns the Copy button's rect.
SelDrawCard(g, s, W, H, sel, text, withCopy) {
    fam := GpFamily(), fmt := 0, fmtC := 0, copy := 0
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "Int", 0, "Ptr*", &fmt)
    fBody := GpFont(fam, 17 * s), fHead := GpFont(fam, 12.5 * s), fBtn := GpFont(fam, 14 * s)
    pad := 16 * s, gap := 12 * s, headH := 18 * s, btnH := 34 * s
    cw := Min(Max(sel.w + 2 * pad, 340 * s), 640 * s, W - 2 * gap)
    GpMeasure(g, text, fBody, fmt, cw - 2 * pad, &tw, &th)
    ch := pad + headH + 8 * s + th + (withCopy ? 14 * s + btnH : 0) + pad
    cy := sel.y + sel.h + gap
    if cy + ch > H - gap
        cy := sel.y - gap - ch                                   ; no room below -> above
    cy := Max(gap, Min(cy, H - gap - ch))
    cx := Max(gap, Min(sel.x, W - gap - cw))
    br := GpBrush(0x60000000), GpRoundRect(g, br, cx, cy + 3 * s, cw, ch, 18 * s), DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
    br := GpBrush(0xF7202124), GpRoundRect(g, br, cx, cy, cw, ch, 18 * s), DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
    brHead := GpBrush(0xFF8AB4F8), brTxt := GpBrush(0xFFFFFFFF)
    GpText(g, StrUpper(TR_FROM) "  →  " StrUpper(gSel.to), fHead, fmt, brHead, cx + pad, cy + pad, cw - 2 * pad, headH)
    GpText(g, text, fBody, fmt, brTxt, cx + pad, cy + pad + headH + 8 * s, cw - 2 * pad, th + 4 * s)
    if withCopy {
        bw := 100 * s, bx := cx + pad, by := cy + ch - pad - btnH
        DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "Int", 0, "Ptr*", &fmtC)
        DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", fmtC, "Int", 1)
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", fmtC, "Int", 1)
        br := GpBrush(0xFF3C4043), GpRoundRect(g, br, bx, by, bw, btnH, btnH / 2), DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
        GpText(g, gSel.copied ? "Copied!" : "Copy", fBtn, fmtC, brTxt, bx, by, bw, btnH)
        DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmtC)
        copy := {x: bx, y: by, w: bw, h: btnH}
    }
    for f in [fBody, fHead, fBtn]
        DllCall("gdiplus\GdipDeleteFont", "Ptr", f)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brHead)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", brTxt)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", fmt)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", fam)
    return copy
}

SelToWhole() {   ; "Whole screen" button: translate everything, reusing the same screenshot
    global gSel
    if !gSel.gui
        return
    hbm := gSel.hbmShot, m := gSel.m
    gSel.hbmShot := 0                              ; hand it over instead of deleting it
    CloseSelect()
    TranslateScreen(hbm, m)
}

WatchSelect() {   ; close if you switch to another window
    global gSel
    if !gSel.gui
        return SetTimer(WatchSelect, 0)
    if WinActive("ahk_id " gSel.gui.Hwnd)
        gSel.wasActive := true
    else if gSel.wasActive && !gSel.down
        CloseSelect()
}

CloseSelect() {
    global gSel
    SetTimer(SelPoll, 0), SetTimer(WatchSelect, 0)
    if !gSel.gui
        return
    old := gSel
    gSel := {gui: 0}
    DllCall("ReleaseCapture")
    try {
        prev := SendMessage(0x0172, 0, 0, old.pic.Hwnd)      ; take the image back so nothing leaks
        if prev && prev != old.hbmShown && prev != old.hbmBase
            DllCall("DeleteObject", "Ptr", prev)
    }
    old.gui.Destroy()
    done := Map()
    for hb in [old.hbmShown, old.hbmBase, old.hbmShot]
        if hb && !done.Has(hb)
            done[hb] := 1, DllCall("DeleteObject", "Ptr", hb)
    for f in [old.img, old.img ".small.png", old.ocrOut, old.trIn, old.trOut]
        if f != ""
            try FileDelete(f)
}

; =====================================================================
;  Icons (GDI+)
; =====================================================================
GdipStart() {
    static token := 0
    if !token {
        DllCall("LoadLibrary", "Str", "gdiplus", "Ptr")
        si := Buffer(A_PtrSize = 8 ? 24 : 16, 0), NumPut("UInt", 1, si)
        DllCall("gdiplus\GdiplusStartup", "UPtr*", &token, "Ptr", si, "Ptr", 0)
    }
}

; "png:NAME" -> GDI+ image. icons\NAME.png (next to the script) beats the built-in icon. 0 = none.
IconSrc(spec) {
    static srcs := Map()
    if srcs.Has(spec)
        return srcs[spec]
    p := 0
    if SubStr(spec, 1, 4) = "png:" {
        GdipStart()
        name := SubStr(spec, 5)
        iconFile := A_ScriptDir "\icons\" name ".png"
        if FileExist(iconFile)
            DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", iconFile, "Ptr*", &p)
        else if (b64 := IconB64(StrUpper(name))) != "" {
            size := 0
            DllCall("Crypt32\CryptStringToBinary", "Str", b64, "UInt", 0, "UInt", 1, "Ptr", 0, "UInt*", &size, "Ptr", 0, "Ptr", 0)
            raw := Buffer(size)
            DllCall("Crypt32\CryptStringToBinary", "Str", b64, "UInt", 0, "UInt", 1, "Ptr", raw, "UInt*", &size, "Ptr", 0, "Ptr", 0)
            stream := DllCall("shlwapi\SHCreateMemStream", "Ptr", raw, "UInt", size, "Ptr")
            DllCall("gdiplus\GdipCreateBitmapFromStream", "Ptr", stream, "Ptr*", &p)   ; stream kept alive on purpose
        }
    }
    return srcs[spec] := p
}

; Icon drawn centred in a w x h cell on a solid background -> cached HBITMAP (0 if unavailable)
IconBitmap(spec, w, h, px, bg) {
    static cache := Map()
    key := spec "|" w "|" h "|" px "|" bg
    if cache.Has(key)
        return cache[key]
    GdipStart()
    isExe := SubStr(spec, 1, 4) = "exe:", src := 0, hIcon := 0
    if isExe {
        imgType := 0
        try hIcon := LoadPicture(SubStr(spec, 5), "Icon1 w" px " h" px, &imgType)
        if !hIcon
            return cache[key] := 0
        if imgType != 1 {
            DllCall("DeleteObject", "Ptr", hIcon)
            return cache[key] := 0
        }
    } else if !(src := IconSrc(spec))
        return cache[key] := 0
    pDst := 0, g := 0, hbm := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", w, "Int", h, "Int", 0, "Int", 0x22009, "Ptr", 0, "Ptr*", &pDst)  ; 32bpp RGB
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pDst, "Ptr*", &g)
    DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", g, "Int", 7)
    DllCall("gdiplus\GdipSetPixelOffsetMode", "Ptr", g, "Int", 4)
    DllCall("gdiplus\GdipGraphicsClear", "Ptr", g, "UInt", 0xFF000000 | Integer("0x" bg))
    x := (w - px) // 2, y := (h - px) // 2
    if isExe {
        hdc := 0
        DllCall("gdiplus\GdipGetDC", "Ptr", g, "Ptr*", &hdc)
        DllCall("DrawIconEx", "Ptr", hdc, "Int", x, "Int", y, "Ptr", hIcon, "Int", px, "Int", px, "UInt", 0, "Ptr", 0, "UInt", 3)
        DllCall("gdiplus\GdipReleaseDC", "Ptr", g, "Ptr", hdc)
        DllCall("DestroyIcon", "Ptr", hIcon)
    } else
        DllCall("gdiplus\GdipDrawImageRectI", "Ptr", g, "Ptr", src, "Int", x, "Int", y, "Int", px, "Int", px)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", g)
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pDst, "Ptr*", &hbm, "UInt", 0xFF000000)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pDst)
    return cache[key] := hbm
}

; Default settings, written to SPenMenu_settings.ini on first run
DefaultSettings() {
    return "
    (
; =====================================================================
;  S Pen Menu - settings
;  Edit, save, then right-click the tray icon (green H) > Reload.
;  Lines starting with ; are notes. Don't put notes after a value on the same line.
; =====================================================================

[Pen]
; Which pen signals count as the side button (hex, comma-separated).
;   0x3C = Samsung S Pen (Galaxy Book)   0x44 = most other pens   0x5A = a 2nd side button
; Run SPenMenu_diagnostic.ahk if your button isn't detected.
ButtonUsages=0x3C,0x44
; A press longer than this (milliseconds) counts as a hold.
TapMaxMs=300
; Most time allowed between the taps of a double or triple tap (milliseconds).
MultiTapMs=300

[Gestures]
; What each pen gesture does. Choose from:
;   menu, translate, translatescreen, playpause, keyboard, snip, paste, undo, taskview, none
;   translate = circle/tap the text you want translated; translatescreen = translate everything
; DoubleTapHold = tap, then press and hold.
Tap=menu
DoubleTap=playpause
TripleTap=keyboard
DoubleTapHold=translate

[Keyboard]
; Double-press this key combo to open the menu at the mouse.
; ^ = Ctrl, + = Shift, ! = Alt, # = Win. Leave empty to turn it off.
MenuHotkey=^+]

[Menu]
; Menu rows, top to bottom. Remove a word to hide that row.
;   snip, translate, paste, undo, apps, spotify, taskview
; "apps" = the apps listed under [Apps]. "spotify" only shows if Spotify is installed.
Items=snip,translate,paste,undo,apps,spotify,taskview

[Apps]
; Apps to show in the menu, one per line:   Label=program.exe|full path|icon
;   - The path is optional if the app is already running or registered with Windows.
;   - Icon is optional: png:NAME uses icons\NAME.png. Leave it out to use the app's own icon.
;   - An app only shows up if it's installed.
; Examples (remove the ; to use):
;Notepad=notepad.exe|C:\Windows\notepad.exe
;OneNote=ONENOTE.EXE
RemNote=RemNote.exe|%LOCALAPPDATA%\Programs\remnote\RemNote.exe|png:REMNOTE

[Desktops]
; The Task View submenu lists your real virtual desktops (names from Windows).
; Optional icon per desktop name:   Name=png:ICON   (icons\ICON.png)
; Desktops without an icon show their number.
; Example (remove the ; to use):
;School=png:SCHOOL

[Translate]
; Translate: reads the text on screen (Windows' built-in text recognition).
;   Select text  - a blue layer covers the screen; circle or tap text and its translation pops up next to it.
;   Whole screen - shows a translated copy of the whole screen ("Show original" / "Close" buttons).
; Language codes: en, es, fr, de, it, pt, pl, uk, ru, tr, ar, hi, ja, ko, zh-CN ...
; From = the language on screen.  To = your language (empty = your Windows language).
From=en
To=
; Translator:
;   googlefree - free Google Translate, no account (unofficial; falls back to mymemory if Google blocks it)
;   mymemory   - free, no account, about 5000 characters a day
;   deepl, azure, google - official services, need an API key (see README)
Provider=googlefree
ApiKey=
; Azure only: your resource's region, e.g. westeurope
Region=
; MyMemory (also the googlefree fallback): your email raises its free limit to about 50000 characters a day
Email=

[Spotify]
; Optional "Add to / Remove from Liked Songs" button - see README (needs Spotify Premium).
ClientId=

[Look]
; Colours are hex RRGGBB. Sizes are at 100% display scaling.
Background=1F1F1F
Hover=383838
Text=F2F2F2
Accent=6CB4FF
MenuWidth=190
RowHeight=40
IconSize=22
ScrollSpeed=35
    )"
}

; =====================================================================
;  Built-in icons (PNG, base64). icons\NAME.png next to the script overrides these.
; =====================================================================
IconB64(name) {
    switch name {
        case "SNIP": return "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"
        case "PASTE": return "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"
        case "REMNOTE": return "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAYAAADimHc4AAAM00lEQVR42u1dbWxb1Rl+zrnXN07sxHGsFsjWlAEl29RuQCkCbSAkNGmDFg2maXx0Xdkm0CahpSAkStlaTaMgAWsY2jRNA/4wIXXQbiD2g7WFlrG1W7qB1mWq45a0cUM/8lE7dnJzP867H8c3dtJ82ff62u58JEtRPm7OeZ73fc573vOecxlmaUTEADDGmACAeDx+YywWWxcMBm9mjK1QFCWmaVoA9TbVDMMwhRBDQoiEruvvDw0NvdnZ2XkohycHQIwxWvBBO3fuVJyvk8nkukwms880TZPqrahmGIaZzWb3JJPJtQWGzecFn4gUADh8+HB7KpXaNeOZFhHZRCTq8M7ZRA4jq/CbqVTq9Z6enssKMZ4T/EQisVrX9RMFoFt1XEtgQohp+Om63h+Px6+dSQJzXIMxJvr6+q7r6OjYq2laKwALgFpXd/dNCGFxzlXDMEb6+/tv6+zs/NDBnG/dupUDoEOHDl26bNmyNzVNaxVC2HXwvWucc1UIYWua1tbR0fHWBx98sBQAtm7dyhkRKYwxe2xs7I/hcPjOuuWX3xPS6fQfIpHIXUSkcMaYPTAwcHsdfH88AYDV0tLy9ZMnT36VMWZzACwajW4GQM6cUG9lbQwAxWKxxwGAHz16dE0wGLwp90Oljk/ZmwIAmqZ9OZFIrOZLliy5W1EUBYCoY+PfdKCqqhKNRu/mmqbdUhiS1ptvMoSGhoZbOOf8qjoBlSFAUZSruKqq0ToBlSGAMdbGiIiqvbdEgCiyl5wBjFX7uAhVTwBR6UC6+Vu/WlUvuggSwOHzhCN9AoYJ2GJuraSc5TdowMoVHLFWVvWLm6olQJAEM94v8JMXDQyfJzAmrXpecc39TqyV4acPa7j6cj71rDoBRZs/8Po7Fs6NEGJRBtte2JoJgKIA50YIb7xjYfODWlWv8auWAEe702NAgybBF0UsFRs0htTY9GdVY+NVv2SknOxQcd5TSuR0UXpAIRA1ERoi72l+9Ff1I4RUWG2EhlP95f71Vy3f5gPAOZAdB97/p42ACtxyvYKAiqqMSpw+WRawv8eGaQE3r1YQasyPpWYIsIW0olNnCNt+aeB4UgAEvL2f48c/0BBtYWUdVKnGMpom/OzXBj78L4Exwq4/c2z9oYZPXcKmxlT1k7DT0eQZwhM7DCRPE9oiDG0RhiN9hCe7DYymCZwXF9X4Af6T3Qb+HSe0RYBohOHkJ/kxKFyOraoJEIXgdxs4N0oINUq3tmwgEgYSA4QtVULCFPgp2afEACESln21LCDcBJwblWNxSPC6v9xLy+c58LfsMDA0QmgKTrcaywaaQ8DxAcKWFypLwjTwXzBwfIDQHJJ9nBqTDTQFgaFRSVDyjOyvl57AvZadLTuk5c8Ev3BQ4RBw/KQc1HDKfxIc8IfP58EPh2TfZhtbU1B6wpYdkgQv5YiXQ3bmAv8CEgbkoIbP+0fCNPC75wd/NhIK5wQv+svdxs0Lyc5CJPQP5jzBBxJmgt8/uDD4M0kYcuaEnBy5TeZzt4uWwbNyMIux/FlJaAL6T5WfhAvAP0UINy0O/NlI2NJtYPDs4jK0ZfMAIYAXf2di8KyMdkrRxSlPKCMJs4IfKg78QhJCjdLwfvGq6bqf3I31Z8YJxwcEwk2A5aIjM+Vo6DxBUdy7t9NXRQGGSpCduZolpOd+nBTIjLvzAl5qqpgICDUyLG/nyE4QVJfT+WxyxJg7TxAiv6NWquzMmj7gQHYCWN7OEWpirvJFrmBTFODh9QEsbWMY190v1R1POHFKTnQjKUJjsLS0siCgMQiMpOSzTpxyb/mAHOO4Dixtk2N3O2ZXm/IO8ycG86vbxgb3MbKiAGMZoPMKuRFzYpCgBRbv5owBhgksb2dQFODocUJz2BvwJyaBaAvDU10alrcz19lS11URziLsxKDAE90mzntEAufApCEzlKpavMayXGZTkNykdztZOuC3tjBs7wpgeTv3JEHnSVlKngTClu5JjKbhCQmOZZXaQ7d/f6HlA091NWB5u3fZUc/qgqaT4J0cVbrNJjtepqa5lx21hdTdp7oCaG1hmJj0rqOVBL+1RY7Ja/A9T0fnSeDY3qUh2oKaJaFQdrZ3aZ5pftk3ZKZ7QgOiNegJ02WnoSyWX9aylFqWIz9kx5e6oFqUI79kp6QoiKi0cM4WQEAFPk7mQ9SmxurYD5657hifyIean/k0g2mVBj4rop5oUQR4VRtzZliGqGeGCQEVqJbCeMYA0wIuiclQ85IY862sfkECnLrWzDhh4DSVbLm2AIIa0HeS8Nvfm57Wj3pF5Pe/GcCKDgbdKF12GAOWXcrQHGLuPcApVvroqMCzLxkYTbu3Ci0gB+e2bpNzwMzxGAi4lzTOpJEYpntvb20GHvuehms+u3Bp/LwEOLq/6ZlJ9B4jRJrdD9Qra53QgaU5qTg7IlfdXnqVG8NIjQGfu4Khe3PDgvOBupCGjeuQE2dQgl9p3eYMyOrAxrtUrL1VARHwpwM2XtltIRR071luxydy25apMRlRhRrnnw/UxRwkKzUC8jxMVIBUmnDPHQHcc3u+69/6morMOPDa2yZaW5jrtLNXFeFSXFhtnw8ojNEzWWD1SgUP3K3CFnmJtAXwwF0qrl+pIJOtrVV3TXTV2WCJRoBHNwbAWb52n+W+5lz+LBrxZiKtEzDjVLNhAps2BLCkjU3t9RYSJASwpI1h03cCMKzaOXVe9QQoCpDKEO69Q8UNX1CmalBniz5sAdywSsG9t6tIZWRlRZ0AD3R/zUoF375TXfBMgVNPtP7O2pkPeLXrflsr8MjGADjPaf6CFzBI0B/dGEBbDcwHvKp13yJs2qDNqvvzrRPy84EmCah7QGm6f98dAaxZxefU/fmkyBbAmlUc962t7vmALywFrKj0qhe6P5YF1qxSsH6djPdLOdDneML6dSrWrFIw5uN8wApC5JIJYExmQoMNcjk9mcsQ8jJ+VAXQDSDaDHRtCEzLRwlR3KfwfHLXhgCizfLZqlLeMSi5eqZwExBsWLhwa1HZ0L/+y8azL5uY0Is7sF6s5guShD/ziIbPX+mtufYeE3j85wb0STkmKtctTJAbTo99N4CbrlHcZUML9wPOjshK6HLtZAkCVIXhbx/ZMHLeRh4CYwuCpjHc9EUFlk1lO6fMOXDlMo4lbYu7Kkdd1CWXBCxtY1jaVt6Z7OQnhL8ctpEaIyiceU5ApJnhG19R0XEZr5qLpsq+J7wYyweA7DjhR08bODssD3t4fdEGZ7KkfGmM4YXNGkJNbOr75ZqEfS1NhMuSxu2/MfHe3220eFDFPF94m84At96g4IkHA2WveKj6dYADwO49FvYdtNASQllz+bYNtISAfQct7N5jl+30e00Q4Bxv7T0m8NIbFppDzBcwbAE0hxheesNE7zFRltPvVU+AM0Gls4TnXzHLpsXzRSoA8NzLJtJZ9ycda44AkSPgxVdNDJwWCDb4e7uVEHK9kTwt8OKrptxP+H8hoFD33z1koyVcmT1c2wZamhnePWRj9x6rYvMB99vyFQ70JvK6Lyq4gS5sZz6w8J9EZeYD7qvuA0hnCM85us/Ll9pY7P1wnMsvnn/FRDrj/3zA/b4F91evmRg4TVL3q6BAVwggGAQGThN+9Zo5lYS8qAgQuZTy/n/Y2HvQRiSMitfuzJwPImFg70EbB3rsqVT2RUOAsyx/e7+NgMpAQFVeVxlQGd56z/L1slfV750u0wLCvLpeWEC5jSDTkiTgYru62EnL3r9WxfEBA+fTBJJ51oqXPDqWziDPhN2/Vp3W57L/f7+TcSMpQryfMKETLHv+6+j9snxFAZqCDFdfLm939NUA/CSgFl6o4HcfVb/d3dlXoCosg2E+321NRFBN07QCgYDqJwm1UjiL8r+F2+CWZY0WSGK9+Tf9gIhGuBAiUSegMgTYtp3ghmEcqBNQGQImJycP8HPnzu2ybduupdMyF0HjlmXZo6OjuxgAlslkDoRCoS9BvtCz/kbV8jYbAB8fHz8QCoVu5QBodHT0aacEqI6PP4mB4eHhZ5yFWP2V5qjgK823bdtGRMR6e3sfmpycPAVAFULYdbg8B9/mnKu6riePHDnyEBHxbdu2EcvFo5wxJvr6+q7r6OjYq2laa90TvLd8wzBG+vv7b+vs7PzQwbxwWawAQCKRWK3r+gmSzcp96q3IJoSYhp+u6/3xePzaQqxny00oAHD48OH2VCq1a8YzLSKyiUjU4Z0b9xxG04w2lUq93tPTc9m84Dtt586dU7+QTCbXZTKZfaZpmnVsi2uGYZjZbHZPMplcW2DgfK4zBTM9QSYHcxoVj8dvjMVi64LB4M2MsRWKosQ0TQvU1X1aYs0UQgwJIRK6rr8/NDT0Zmdn56EC4IkxdkGY/z9Jecm2gtL28wAAAABJRU5ErkJggg=="
        case "NEXT": return "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"
        case "TASKVIEW": return "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"
        case "SCHOOL": return "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"
        case "BUSINESS": return "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"
        case "EDITING": return "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAYAAADimHc4AAAVMElEQVR42u2de5BfR3XnP6e77+8xL72M5Adgl8Fgy7YsbMcB4t0ReL28jLPFWsYkC8GLeRW7/LObVHmzwZ5Aaslu2CVVIRQJqbCb3SRVctasgx2Mia0JBoFiE2NHwsIPPSzZeCzN+/e493b32T9+D2lGv5FmRvNU3FU/1ej369t97/l2nz59zvn2hcUtwuovslobF0AfeeQRd88991w8Pj5OsVikWOxr/pwyPp52vLCvrwgUG7XScdIO1Yp9RYrtOilph0rFIvPqb//+IxSA666/7sDAwEDWepbVBIAAfPazd24cG3/5fu/9NTFGYoxtQYkIpVKp48VpmhJjbAqxiLUW1ePPLyJkWYb3HgDnHIVC4aQ6IYR2f8YYisVix/7q9Xr72mKxSIyRsZERouoTvb3d77333nt/3qy64CC4xZB+f3+/HRwc9JOTR/+1MeaaEEKIMdre3l62bt2KiJCmKfv27SOEgIhMEdyWLVdSKpUBeO655xgdHcVa2/49z3MuvPBCNm7cCMDQ0BCHDh3COdcWpPeetWvX8oY3vKEp5Br79v1sCkiqirWWrVu3UiwWUVWeffZZqtUqhWIxZGm6NatntwK/39/f7wYHB/2qAKBVrDU99TSNxphYq9XMddddx6c//Smp1+t47xkYGGBo6BWSJJkitI9//OOUSmXK5RJf//qf8N3vfpeenp72rPDec/PNN3PNNVcD8PjjP+bLX/4yzrn2aK9Wq1x55ZXcccfHqNXq1Os17r57gNHR0XY97z0bNqznU5/6JM45SqUSX/3qV3n00e+rcy7Wa1VRW1yzmDJaVACAKCIGiI3BK9TrdarValtQ04sxhjzPiVERYcrsmKpeYrudEOKM9Vr9heBn7C/LMrIsa1+DiKAqIMZAWEwBmcVsXFXlRGHked6cGZYQAt77k9SP954QAs41VE6WZScJV1XxPsNai7UW77MpquV4f1lzjTh9fy0Vl+f59IVx9VlBLX15xx2f+PXc+/+aZZlXVZckCRs2bGiDcezYsY7Xb9iwniRpLKrDw8NTQBARYoz09vbS09ODCExMTDIxMYExpg2EqlIoFNiwYT3QAOPYseEZ+ttAkiSoKseOHSOEQGWy4mvViiuVy791333f/MKqXAPy3JNmaXt6p2nK6Ogoqg1BJq5z9wcPvtAWZOJcB/UiDFVf4aWXfg5KeyZMN1Lq9ZTh4ZE2cDP3dwjVhspzzmGtJU0bqksXWUcvCgB3330373jHO7j99o9kvX1rGBsfbwixKXiTHB+lHaelSHtq6gz1RIQWLqqnqHOado63JcQcYlSMEcbHx/Hek+VZ/tBDD7Jt2zYGBwdXBwDbtm0DYMuWLWHtunWMjIwABmMVEGpDgupibm/mqIcFQlC6N4FY0ADVWg1rLeOV8dh6poGBgdVlBdVqNQrFEtVqHWMg5sJTf1Di2FMG41gxxRjDsbEJut5Y5Yb/XKZQNlQrVYw11Cs1Vq0ZaoxpfDAk3cpLf5fw8g8KFNbqIht3czWWDdYJB74fObxbuex9hskJad//at4HTNm/hxRsoTHlVVaWu00MuALktaXViWapH1SVFVsa1tnS9ulYJUUkgiiooGo4W8rqAEAUn5eJ3iFGSUoTDRB09YcbzGoY+SErsemiH7Ht9o/w2ku/S1rpQ4NDTHgVgKUY/SF3XHLtX3LhW/+Md/7ar/FL2/8DSWmCtNqHmICIvgrA4i/eDq2sJ+ZlLrn+j3nfv3sPF2+9j6zaR/AFjPGvArDYxqwYj0hEK+fQve4w//wjt9P/q5+m3DtEvbIGkdhYrF8FYJEnhPFoXkJrvVz0C3/B+/79u3nTL/45edaD92VEwqsALMXiLCailfWUuoZ5+7/5DDd86FdZu+YZsqxv1cyE1W1QK4j1oAX05TVcsOF+3v2Bd3HRxd8iz8urAoQZ9wF33XWX2blz57wA+sY3vuH6+/uJMS6+IyUDhj2MGyLrSNYe5JyNP2b/szdBogsR1TP9/f1u586drr+/n3l6h+PAwECcNQDbt2+3AwMDgUYsd86lFTlav37NpC6GY0manzGFYUUzi5THIRT4xx98gSf/4bMUChVU7Rl3193TUxkcHPRnEg0bHBxk+/btdseOHWE2AJgdO3aE7du3v94Vi29XlS71QZjDsxSSkhkdPZb/7SPfu2Fbfz8ao1mw6KcFcuBYRCcM4gLSPcLRl67n73/weV5+8TqSQrWpfubfZ4xqJEaeeOKJ/l/+5Q9M9vX1JlnIZz8gA4izKqLVtFrdtWPHjoNNlR9nBOCuu+4yAwMD8bbbfuUz1rkvWmt7GrWSObqhhUJS4oUXDreSp8yCRK9FYFRhLKK5QcpjhLyPJ3/4Bfb+5NMEX6RUHiNGuxDhbuO95+cvvXxLUizcYl1C0cxhFCatRUrIbV7dtm3b53bu3PmlloxPAqCldm677bZ3JoXCH3jv8SF4QRohojkBYMmzlOC9WSjhayrwYkSHBCl4pGeSnx+8kcd2fZ5Xhq6gWKyQFCaIcWHdWyH4mKdpzJwjxjCbbMzj2lJMK3TaVUiKv3fDDTfsGRgY+PaJ6qjD3dpPiIhGVS8aEtGA2q65RmLAJA0n+0LofAO2UoNKwHSPkqXreWLw8+zbczuoUC6PEaNbEJ3fYdNhMInBJE39N4vYh1gUcLEKCF7JVdXFyCeAb3dUQZs3b25Cp5uiqohGo66HyYtuJ3Rd1JwFMmv5T9SV+nkWCdUmEHpGKIyNXUI0liPP3czjP/wcI8NvoFSaBHTBR31T8EiYpL7pXYxe9X58UYlRThtb9sFTrdeop5Ewsp83pn+NYcQ0ky7OA9ixY0c8xSIsCgYJVern30y68e2YPEPFzmnQBhE0qYFOnJE+VrUUkhp7nvwkB/e/h/GRS9ATRv3i5k0pmvQRyhsISSCepi8jgs9Tcj+Kz+sM2SvpLQxxQfr/0Ma1Mqd4QEz6kBAh5nPa3ouARAH1C+YRRYWxkTdhbR2RRRr1HTHwSMwQDcjp4g8iiOaIeoSA05zM9LWEP4+AjMam+pB5jDRZ4NGpWFdbhoiYTPvMvq4iyGlUr1ta/00z00B0/sEsWRwR594veTx4SQFocAI8E7UKpRLEsHL4R3WfUde0MbvC0hKrliYtRSDm0HtRYDRMkB6MGLNyMiSkmSdT7BZes9kQ0qUDYVYAxGa6hsw7QQt8HV7zZsP7freLw4+FBdkiLOggicprr3Wcc4khTxUxS5M1OSsAuoqQB/BxbiC0db4RjEDI4IK3GF7/i0lz9OuMikGmJHXpItZp1hMImZLXwFppETWWEQBpuzJY1wNjVcjrs7unGCOlYpknn9jFbz/8VwTTDRrbU/3EHP6TZDKdFTNT5rORk0ZwR9UiU4kdp+qvUV8RESYmK0y88gL5G/8tpU3vJ/q8kbm7ZADo8Uy2V8YgKBiZm0NucnKCyvPPo64XQfHek+fHrY1CodCR/dLiE6hCkrgp5LtWybLjrBgRoVAonCT8+fZXKBSYmKgwNnSQNRvHMOfJ8q8B81GI1lqSYhEKZbJ6jUsvvZT3vvc9xBip1ercc889VCqVNj0oxkixWGT79lvo7u7GWsuDD36Hp59+mnK5TIwRI0KaZdx8881ceumlADz99E/5znceolgoEFUxxlCv17niiit417v+ZYPxUqmwY8c9pGnaTrgNIdDd3c0tt9xCuVzCGMMDDzzA8/sPUCqXqBeLWOfwy62CXrMGxqtQSec2C1S1wTxpjrJNmzZx7bXXUq1WiTHywAP3MzY21haI956+vj6uvvpqkqRAd3cXTz31jzz55JNtGmlsCu6yyy7jqqu2tEf73/zNt4nN/lqj+vzzz+faa6+lUqmS5xn33ffXVCqVKazMrq4y11xzNcYYurq6ePzxx3l6388QTLutZV2E5QRX/Hw3XtJKU28KusVImf596+/W71MXctPQiq02O9SRpm17Yjsn9mc69CfT2mpsFIU8y5fEFnWLFy2HPK3jJytIqUSWew4cPMTuv3+cEAL1Wo1jR4dJsxzvY1sFjYyMsXv3Y/T09GCdY//+A+R5oFqtEzVixJCmGT958il8aFy3Z88e6vUMVWnXyfPA/v0HGv15z+TkJCMjY6RpTp43doEhBo4dHWH37scolctYazh48AUmJyuEKI29SoyrEQBBNFIvXkg6Okb0R8EYHnv0ED8afLBJw1WSJOm4KH5x4M52HWst1lkq0zTB//mTr0z5f5IkTE6burt2HuLRv73/lP2NqvI7n/uNaf05BMW4BF23GWJctNngFilzCnwK57yF4j/77zC0u+EpbJLmtOmqIkZUzJT1XZoq40QKWSc93NUBuJlIeu22VDtZoR37U1Vk4y+gG65qPMsi7RzdYjLfNKSw6W3IeW9r2PNNt4REyB14C8Vs6qLfqtPeNunM7o2ONJxpX52urZnqSCsSG2qLuiFzi+7qyqucOO5ElbRQZt3Qi6wbe5FDr9uCCpgQV+DpQsJi+0zcEiRyniD8SFYscdGBp/jE1z/J+okj7HrLdv73h7/YDN2vOAQ4q1ITRZWsYHnrrnvYOPE8k2Y91/3DvZz30nPkSRnR+E8OgCWnKNmg7L/4atIf9lDUKi+e82ZG1p2L89m8Z4AsI9tbzzBK5JaWjmsp12p8/5c+wIX7n2Dbrv/J//rol5jsXU+pViXOg5MrKEEdEVlS4n2rLyvhjAaAW3rGkaIGhjecT06RkXXn4XKPzsvSaAi/y01SMLWl1agKSKTqe8liATPPVMhlY0k6nyMozufzEr6g5FpgU/EI/2PrrXS7MVTtkqmjiMHYCj8dfRv/6ak/nbcaWjYAWkLXedrYIkqIljWFETaWD4DaE7ZcS2S/mBqv73qWgsnINZkX+KuGqD2zq9zgQ9eSm7CtlJN6KJ8y72dVAyBoU7d2ykKLWPENNZaMgPglJm4bsFW603PPXgCCOiZ8MkO0txHBembicr7y9O/RlwwTsUs2D1QFa1Oen7icLCYk4udlBLiVOvKDWnqSMW489yGc+JNUjKpgTMrBymX82aGPYWWRTlY9lRmq4Ax02XpTJZ0lM8BIZMKXeefGnfz6lg9D3gfTc1PVgKtwePStfPyxB7ESlmU7pgjxDNLiV7QKMhIJ+TpivhYzDYCoBhPLZKGIInh1r7oiFh6AgDUZIh4jftoSaBDxJCZbKUfPLT0ARuKc0wuFiJHYtpmF2P609LygWAmM5+vwoYsGvcNO48AZHMpwtolcLYn4M7JGViUAVd8151iFiYGqN+TayEyoxy7qMcFFN2VTZoBHj76bO370PWx7EdYputcQGMlfg0HPXm+ots/lnO4GcHzmjb/Nm9fsRkPX7FnpQYnrLOaxlwlYvnjFR9H1DsmPp6yrGsRN8p0jH+H/HrmNLheIHTkBgpUcJ2FVjv5ZZ8YdHW+QWxs5QUrEUDQZN2z8Juu790Hsmj2nOwDrIyNdPRyihy3rHoX1AfIT0gjVQjLMRP187nvxg5RslRDtKYxWObvjAT52DotO+LX0+XVoLDd1+CzMtgDkShoaXad+DdYrnGDqB7VYoBp6mmaeQTl7zombMwAzja9eN4pzIxDrs58BAiSRou0lmjUU3Svg4hQ/mlMLhWG67OQq1u6LtggLhkgaCzz48nYuW7ObEGY/A4hKjJbCxGG64n5+PPJOUDtlDYgYrK3wvaPvxklchbFiXcDURKFDrrzgiHzt+TvnbIOLQp7Aa88/wCW37eZ7+2+dsQEDlF2KYpeFvzWPk1XI0vqcTHN3Sk5X7hkfH8OGCtohPcNInPsOSARbVw719fLM1TfRXXupeWLqNCQFogoZZpVsswSNAR98I9t7lii4UwkqRPB5SgxpRwDO6HazjIKOkRrL2VIEwYgQvKdWTRFJTusidzPvciGtjDPkM4paI7JYgsrPsmVViUHRGIm2hA2VU0bK3IzBbimysbaLUS6gJuuQpeZvzpKR32K2rCQArDQO7OgNz3Bu+iMCRYR6RxjcTFsbxVGMo1xR/VNyysuaezPj/iQ0PKTO2pV4yCaJ1hCJ5OJmXMfcKacSDlRJqKy4B4xROXf9egCGh4cxRlYgCKYp4ny+ZmiL3GlXlNrJved1r30db3pzgyP2s31P88LhF0icW3HqCJTgw4xUJzO7nYSuoA8QI2vXrm1/t3bt2iaJYuXdq4hQrVZQVVVOTn5tA9A6ojJq3G+MEWNMEDnOn1r+j6F1P9Y5jhw5TLVapVqtcuTI4Qarpck7WxH33VSJ46Oj1KrV4KwTkOeg8a7Nk1TQtm3b4uDgIJXJ8T+cHB//qDGm4EOIK+hFO1Nm69joKEcOH27TTds/tybJYpO7Tps3quRZjvce51whxKDWyu8DbNy4UWfysxkg9l/f/69sknwJ9GJZCT4AVdIGMTtOf8jWBkjbpPfGv534YMtyCEjjBp+PMfzHhx9++N7pR1dKpxNzBwYG4k033dSV51ylmq2JUXQ5lmE1ViQGLZTLpS1XXfW1JHEbvA/aUbACPvdUazWrquP7n/vZx7JaVmm1sdT3HgCjKuJkLEmSn3zrW9+qTj+yckZP80ynvC5Xsc7xlT/82mHn3AV5njPjm1PTlMmJSVTj0d+88zc2yQo6PHommZ5qjsr27duXNQqyefNm2bt3r26+/vru9bbw08S58/M8V+mAQPMl0To5WRHVeIyYv2nv3r1jrTaW8zmapyTqXPcButyzQFVFRPS/vf/9QSaqU6yMTi+NO/5+SaFULocdO3aEVhu8mhd05u/4OtXZDd57arXaynlB5XK+T7il86YeCDv3cvnll8uePXu0VCqtyXx8xlq3IYTQUQXFGIkxqnNOYgzHiom9pF6vj7XamO897N27V5pqJKwmABZ0GKqq+/zv/JeXRMw5MwHQSpe11kqM4ehv/ead54mI/6c4AwTQD37wVz7sEnerD6E4XyxERVRUBeO6uspvEzGJtqJnM50RIqCqebVa26VE32pjfpl/RtMsDSNDR7/5yN898keLod9kMUytWz/0ofeWCuX7VeOCkIZOPNVqtqXT6VjzObe7WqkwNjJCiPqBhx9+6N6FNtEXdBEeGhqSxsix20SIWZZnIpIswKgRa62Z27HzIZ5pv2KM5FmWR40J8C+Ae1vPuKKtoJFXjpVcwZk8yxIRWS5ftl0I33eeZVhrbVgk19KiAJDnuQsxkOcZIqv//Afnkvm+TmfJF2EB9MYbb9zonFs7V729UkuhUMB7P/rQQw8NrbqNxqvl1OX/Ayo61oKsqxQNAAAAAElFTkSuQmCC"
        case "OTHER": return "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"
        case "SPOTIFY": return "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"
        case "PLAY": return "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"
        case "PAUSE": return "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAYAAADimHc4AAAE6klEQVR42u2dz29UVRiGv++cO3dm7hR0kJakiaauaMpCF/wBJGygyMLFdCOkC7AmLHShcXszS0U3NpFYUUOQzczCxGDBBQl/ABpdUOvKBhMSWmUQ2vlx597zupiWFJSm6b0zQPI+yV3dzMn3fc8592RWrwghhBBCngqa5WJhCLNwQHR5+HqqdUdWDqFeESeqyKQwQCt1MVnUNXFTUK2qe6YshiFMCJis163UYJ+FNf7TL2DCMJt+NYvhb+yId660xqDeOJKkJJLsbLOqdSZnVrxG45fPp/atikBFdnoSer89U7szFJfLr7uuG1YkOxycFbV2TREvfnG0uPR4709FwEYBJ2qNV0vl0kcucW94fr6oafYGRJIYAsR/uiSePX80OAtAVUW2LwIKiKgq3p5vf6DWvKvGe9l6mqpjOJE46rTUmB+a99Y+/Haq/EdaCZp2+DNX2+Oi5lqumBvtPGgLkDhN+e0GRK3nm/xuT5qN5sWvJoPpUESrur1GQ8BURXBqvn0hKBdOdh7EknQjpyop64KqWpPfVZBuq3tb4A7PHSksppFgdn60RWZuIJfE7pJXyI227zcjEQdVY0TUpnlU1SRJ5FqNVhS8GJw8Pd88U1V12/meV2qwVVV3er55JigXTrYarSiJI6eqGdRljIhD+34z8gq50SROLs3cQG7zTAZyAio12PqUJqfm147ng+D7zmozVlUv68sOgPPyeYnb7VuBLY3PTkq0Xja22hjT3yzlveGR37x8/pW405He8DOvLc4PBV60tnb8/LGhyxszGcgJmBheF+f0sBqB9AlVNUkUqfFyY01Z3S+iCPHkTdN7pzB7h/cb640lnUj7MfyH9RkBxBx+ZCaDEHD94YDwkkBUpX9AAJvzRdTbIyKyUH9yoxvvjGfLNuevX8V9/AMFURXs3TyTAd0BJCsogAIogFAABRAKoABCARRAKIACCAVQAKEACiAUQAGEAiiAUAAFEAqgAEIBFEAogAIIBVAAoQAKIBRAAYQCKIBQAAUQCqAAQgEUQCiAAggFUAChAAogFEABhAIogFAABRAKoABCARRAKIACCAVQAKEACiAUQAEUwBFQAAWQ50zAIXkYUvq3qPQvqkhEVFSTbgRBfFdEZKLy5NisjXcuThpJNxLtY8ATesUBon9tnslABCysrA/B4Rqc9K9JwFnfh0vipUCGfheBVreII+y9gw7Z0qJLukvW9wGgb9GzcKIq7tojMxmEgPqUuDCEsaPB1c5q8+f8rsADEEmGhwECp6qxH1gDkU9mJ7VTqYnZOtBTUamJmZ3UjjH2rB9Yo6oxJEsJAIAovyvwotXWT2Zf6ccwhKlPySCzJHtDmDuoXeuSt+J293Zhd+CLGAWcE0GS5gHgrOebYrnoN+81L359LDgXAmY7UYH1KU1CwHx5tHCuebd5sVgu+tbzTe8kpK3LORGjhd2BH7e7t7suPjF3ULtbxysOIM52+rvGWKFU+ti57OJsxcW3APfZ3JHCp2nibGeutt8X1ffU5LKJs+10Wsaay+215MMLbxaXnlqc7f8FOk9faY3lVcaRaKpAZ2vzy3f/Wf61nlGgc6V2Z2jPCyOvJUlnJF2gM9Y6kMULGQY6CyPNn/NI88dFLBwQXR6+nmrdkZVDqFfEScpg6E33plbqYrKoa+Km4JnY9YQQQghJx7/NRZcRxOH41AAAAABJRU5ErkJggg=="
        case "UNDO": return "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"
        case "LIKE": return "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"
        case "UNDO2": return "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"
        case "REDO": return "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"
        case "REDO2": return "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAYAAADimHc4AAASy0lEQVR42u1de5BcVZn/feece/s5w0xgIuQBFgLq4FbWUllBJTOWCiFAULdjua6PkJCgW4gsGxKrdrenywcv5bHlrpsxCatRsGYWUYHIczPZFdl1gwUqIxuBBEIIJpPHPPr27XvvOd/+0adDZ2oeeUz39KT6qzrVM933ztz+ft/7O/e7QIMa1KAGNahBDWpQgxpUc6IGC46GmNADAQBYSrrBj2nFgqdUaFWDo5Mwm4gXZlntSO+9CpF/6FWiJ5BlgRwYIG6YoGpSlgUAnJnYs0mmT/srDn3oYOS2XWvmrEEPSyyFOVEQGgBMIv1n3vxKK0O+QUIR2EAkWxz2Dt3+yto5N00FCKLB6fFEkxhZFq/6Zw4SsFkmWxzAsPEORpRsWT3/ltdvw1LSJed8/H6hoQFH4XDPvvVgcySCB0Us/SHjHQpBRCLZorQ/ePuum05MExoaMJkWAHh57azBBMvFHOT/SyRbHDCz8Q5FMn7KCWtCA4CjASHTI/9vTdtw3IjFXPR+eQQIyZbV8287fhAaJuhYIqIcmXOy25vDdPNmctMfOMIcFQ59a9eauauP1Rw1NOBoKUcGWRYv5s4bckaGLuPAe+oITUi0/N38m3fffqyaUO8aQADX0+VwScJJn33LS6do0bSZYqmLjHcgAgmIZKvShYPHpAlUD5FGFqC+PogOAP37wO3Pg3NTlGlW0xzNyg40p1LRL2QsfZHxDmkQ8bGaI5oenjN19PXJ2fs6uHeS4lY2m61LM9mHDrE11xktuHNHy4Eg8RCEukhonxlkRLJF6fyhb+366tzVyGYFcjlTFwBkelgCQCXTb/gVJ7yh/HnaiHcxuJ0M3sqszyChmgHEgNI5dWgdmQEhBIIoMqltO/23DQwW2FUEBmmRbFVUPHTX50bOuDFX9iHTBUCmh2XvUqHL9vzqx/JzHKM+wuBFzHwhQGc5iRhIAGwqFnN9uYDRnGMGSIBgEPg+ntk5goGRCKrkuSKZPEVRYeAjL69565Nl34FaVkMzPT2yN5MxvVT6xysfLXwMTMvY4FIZd1sAICpqmKioiyNeRETMzBJEUpAQIAJRfccJDAMiQEqCFGRBITCDQQJEwkHNy9HMlOmFKJualY8VM8S4gaR7oVBAWCiiOJIPAEAI6TrxpBQOJBtABwZR4EcMMwRG0QCmPhWAmMFCAJFmlr95pXDGGweLcB0BZo5k6lQH3sD3513w0hMvZVmM18hRVZF6It0L6KsfGrpYOe7XleN+iA0QFjzNQCSEiMXSKRcAQs8fDvz8cyhgGwi/hRLboUf+xODhpPOWgk7sNYnW2fVliP4EHExBBGkY89qg+6s/FO/XkKe7ipiZjUieqrR3cP2utfOv2TFJPjCl+r1wC6utnRR9ZtP25uTss75ORNdJ5SDwvAiAkY7rOnGFIO/nifCIIX4Ahreuvyz12oxMzhZuUfMWtz+g3NTl7A9qBvObzJ9zDZgFAC7XlKqqAdktrHKdFK3YnH+/VO56FVfn+0Me6yAMhVSum3QRFIq7w4L+XiyFH3xnYWJHZVja1QfZB2C2zQO6usB1af17IZCBOatrZ4xTiZ/IeNMi7R2IAEAkZ73J/OzkzJ8iAJgyPRAl5o8sl477HSIV94fyIYGEm066uhgMRsXiHSPB/n+578q5A5UhafvzXUxEBkB0ROafq9cETOj27O/ckdRp94t48yKdPxCCQEdIfpYFuiZn/okDUOFsr3m40OUk49mwUITRxVBI5TiJGCI/eECjcNOGS1peLGsK+mByM213QSn75fbs793hVNtPZLzpMpM/YItxFZLf0yORgTka5p+gD2BauKVPbu3sjFY87N0Rb07c4A8XNGvDTiKp2EQes76h+5JE92H/0AF9tBdWf8wHt2efd4ZTbffLeNPl5rDkz1LaO3TMkn/CGpDdApnr7IxWPJS/Nd6cuMEfLETMBrF0SkVB+DKi8FPdi1PbMj0s258H5zopwsztDZv3rGNn32Dbvx/J/OMzOycMwMKyw30w/5VYc/Imf8gyvymldDHYFhWiJRuvSr2+ct02p3sphZjhLclz7t4e23dob69INF0xFWbnhADI9LDs7aRo2c8HF6lk/M4g72s2VvL94v8UC4VLv//x1kMLs6y6V81g5gNAFwjoQjG5cr1KtVyhh/dZyW9VunDwe7vWzlmJLIvjZf4x+4BslkWuC7zqSW8OR/JZkDhVB0XtJNNKh36/7+2/eNMn5u0v1X5m+BY+uy3l9G9sb3Nl8g0IFbHRkMlZrvb2r9+1dt5xmx0cb0es/3wQiDgsYr2Kx06LgiCSbkyyDgdMsbjkpGF+xbaUN4JzDzLoEZk+zZWpWW5J8qeG+cekAWXGLn94ZFk8ndroD3sRCUHKdWRYyC/ecMUpm8vJGHBybc5q/86f0iO++DxFwcFX1s699/D+UKrR1kRmpq4u0MsLhlpjcbdfSNmmwzCKNycdfyh/x4bL0zeedMyfaKf0FHbqjsoELe2FyOXIuDG1OpaOz9ZhGKpYTBVHCn9snpX6+0wPy1wH9Em9QSvLCj0sp7pNKo7G8fYuhbn6sfwcIcQXAy8wAAkhBXEU3njnRVSYKnWsa3+Qo6ga9wZMCkBfBwRALIpY5abizSaKQjeZUKFX6Ntw5SkP1rvTZWZiZsnMipmF/Z3sz8p+Nm11PzWZ6m0lilb+nJOGvGWRH4FAko2BEebr9W01mAAIKnXj9JjNrIpmDzNLe2z9AJABRC+gIwwviqea5hfzXugkEk7oeds2XJ7+j/lZFvVYVGNmYSusmplTADoALARwPoC32OBjH4DfA3gcwBNEpKcDBDVJ7btkAqVcCipJjFSESNAGIuKFW1giV18tQ2YmIjLMHAPwFQDXAnjrOIdfAuBGAM8x81oieqTWINBkMfDKxw+cYorxP5JSbTCGmU1eCHNe96L0HvtluZ4k35qWswDcB+D99iONN/sNsuI9sr+X37uWiNZVaFDVaVwnnOktfaYD5wIVj7eZKAydRIwA/mX3ovSebOkiuc5sPgDEAPzCMj+wjJf2/ZjVemV/di0I2vqDf2XmD1gNktMKQHtbSTvY4IPSJRCgSQKAeRxgQl91Nvba6ERWrgmim3IUoyyTyTL9rorvpwD4AH4E4LMAPmjXtQCetceICof8tQonPY0+oKN0QYLwXi5tqVJhIYLR5mmAuH8fc3VC7qNTfat90TgOeB0zzwHwj1Yb/paIXhh16FPM/EMA/wng3RXm+EJmnktEu2thimiidDu7hdVuz+uXTvxcoyMYHR0MgoPnbvrEvP1lHzHVkQszXwfgIivJDoDdRLS64vPy69sAdNnvYAAkANxMRL9hZkVEETN/FsCP7PFqlFQ7ROQz87UAvlthqgjAhUT037VwyGpsZgBEwIsH9rUl4unTdRRAuXEYE72y6RPzDgBUzcz3KQD/NAqcnUT0z6OY2A3gwxWH/RrAC9YRaxsgbKoANxrDhIlxzHDNIjsxdh+ipBlxlWgDURPYaCEBYt4FgDM9RlbD9FiJ+w2A5fbtgpXMW63EGxuvf8ky37eash/AVUTklc1TeZtjOSydwNwtHmURhgHsqBUQYwLQ32tNk8As6bgASJMAmHlvpYOuAgjamo+NAB62ZsUASAG4x4J0NoBbbeQibSTzFSLaY881lX9vrEiNmR1roq4EsGgUo/uIaJ8VBp62KAgAdOQ3CSlKG01L32iwBlppbEi5ykq2AhAC+BAzXw/gWwDSFgAHQA8R/bBs94/C1zhEFDLzuwF8f4xDbq5l+DwhAKSUssGovVmIi9UvPJIBIIloN4Dr7DWWHe1dAD5ewfw9AP7G2nJzDMz/CwCPAmixPkVboO8ioqdrmQ1PDEAUHamCxsjaVH8pshJ9H4AfW+ZwxSK7VhHRQOmU8cPFckXUMn8JgCcAtFnQymA+CWC1zTtMfWiAED4b65wYIEGpGmqntpK9CsBua+/L0ioArCOiBy1QegLmS+uUNTOvAfBTa8KMXQ6A/wXwyXJGXMsMX0xUhTMyftBEpX2nzABBtgJAf0dNssRyEnQegKYKqSwHAOcxs1Pi8dj1/DI4zNzMzPcCuKWC8cZq1hMAPkol/1bz2taYALQ/n2EAEDrcr8NiBLBkAzB4LgD0VFlFywxl5gSAHwBottIvrCZoAJ0Auqz0y3FMTsTM77G5xadtSEsVJYp/A3AFgGELJtW6QTMmALmukoT7Q3v3Eon9QrlkIg0QnXnp3dtjJSmp6kWWneDNAN5poyBpnW7BMjEC8FVm/qBltKwsU1jJv8aWGt5VkekCwAEAy4hoGRH5RGSIKLRhq55+E0TEYKYfffa8IWbzqnQc6KDIRGLumefOngcA2Wx1coEKyf0ogOsrpJZtzJ6rKJ4RgHuYOV1RyBPM3MrMG222nKwwN+Xk7nYAv2XmDzNzBzMvtOti+3r6qApr7Z1wtq8sLfw7qQAGAicRd7URC0q94j5RrXo+M7cAWF/RNlS2zvOcDUWftQlYAOAcAHdajXGs3/gGgGX2c674ngQgDuCbAJ6xkc8WAH12bbWvi0f1DqYnCrLa8LSN+1gIgIToLBVLO6oUgZIBcAeAM22pwQXwHIAu61SLtlRR1gwfwApmvsJ+Bps5BxUA6opVDmXDMVah4udpDkP7So5WSvXLMF+MmMiNAgM2+GhpE5aIqmB6NDNfbaUXthShAXyBiEKrHcrWi75mQ8i4PbaHmd9ecZ6LUtNFjrGEPXf0StjXGKa7J5zLkQEzndGF7a+9z3veiScWhMWCVm7s7a/nhy4AzNOZnjdvRZ2CqMfYBvol1jSUE6T7iejZCoDKVcxvAHgbgPlWYuMArrJ1omcBnFpRLzrq3MMe/2qtmjITNuWzfZC5HEUrHhz+mXRpQeQjVHElC6H8HEC/mqrrK0cdzOwR0afGabTrimPL//jz4/y9b1o7f8LFwen1AdYMMfGPg3wxghBukA9YkFz61/fvmd2bgcna0Y5TBUTFpqnDa5yKZjlmP3zcqLbmiSyqi1JELkcmm2Wx4fLmP7COtjiJuDA6CmLpeGvMSVwLIi7tnJtSL8w2Lj+8JjhOj3Xc6POPY3FdAAAA/V2leJ8c3IlSG1iGXsDkxL68bPNQW0cfTL2OlJkJNCnjeol0NstizsdSj4ae92s3mVA6CsNYKn6q0KIrlyODjq4GANXcnt5/PihHZITAP5RUXIhgxNcqHlt1zQP7L8p1UlS+8bpB1b5D5qGRn8WaUlcWh73AicfdKCi+IKLEe864An4OJ37LTkMDxqH2DBjMpKS8PvKDYaGUCgqFKJZKvEML77s5IrOy+5nGNPZqAZAjMpleiHWLEjtNFN7oJl1BQrA/XIjiTcnPXf3QyJruVe8NV65jp8HWKg5uXbhli9ra2Rktfzh/b7wp+Wl/KB8KIYWKx2Xo5Vesvzy9YeU6dmb8PcJ1+wgTO2Zy5DEkhrT/lErEFxRH8pFUUkjHEUEQLt94WWLjjJ4NUY8maPRA629fQnlteIkOwtfcRFKZSBsdhsaNxTas+IW3emsnRSDiRnRUpWkp5ajo6geH36Vi7pNCOLNDz4tICeEmEyL0ww0U7Pty95VzvewWVrmGNkz9yLIyCF94YPjPYqnYZqGceYHnhUQQsXRSRsXo2VCHX9q4KPn0jB9ZU6+PsSqDsOyhwtmOK+934s6f+0NeBGY4iZQyOowAfTeK4S3dVzYPlIHo6IDJ1egulJP+OWJlED6zaaA5PTvdrRKxTwX5InQUhUIIJ5ZOICiEu4nM3SgG95SBAEoTtPr3gXsytd2Pc9I9yC3LLMoSvWJz/jqhnG8q10kHI3nNIF2emBgWinsYfB+TvHf9Je4zY4G5tw3UcTJwtw8ml5tYy6kak9BzRGbZTwfanUTTbdJxF7MBQj8fAfTm6EovAMDbmPXj0LzVaPrdxqtSr+MkfRpTTYd3V949f80j/icF0Vrpuu9lBgLPM2AOQeQ48aSQLqBDIPK9YYB2MOudAO0C0wCbsEBEwcyaagBmBsmYGxjf37x+SeuOiUCoWuen3CnL5chkMj2ydfmSvwTwRRAWOgkXUZGhg4IGI2RAkhCOcuIQCiBRcWU8E4UekA5QGPT3APkL1i86dTdXtF5rOj199CyJ5Y/kL5CklkKbxRDyHU7SARtAhwwdFgFjIhAMM3imOmVmJgbrVGsq6Q0c+uSGJa0/GW+mBtVqxk6mB6K3Yrbaym3bHBx45wJoeTGDL2TD5wM8j4RqUq57WAvqfHj6hBrgD/qvEA1f2H1p2xvjTZSh2o/gZNHXB7F11HCnbDYrdr5v9eyYCecYojYQZmnNSSLjzEC/S04i5UeIHt34sdTr0+IDjkYrsgxCH0T/PnDvyfqc3kmiIDWdjwDJUeXIGCbm0h2a/b2gvW19VLUNkDXLA7oa2X6DGtSgBjWoQQ1qUIPqkf4fYcq77yW0BQAAAAAASUVORK5CYII="
        case "CLIPBOARD": return "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"
        case "PREV": return "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"
        case "TRANSLATE": return "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"
        case "TRSELECT": return "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"
        case "TRSCREEN": return "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"
    }
    return ""
}
