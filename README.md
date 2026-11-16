# S Pen Menu

*Version 30 · free and open source (MIT licence)*

Turns the side button of your pen into a pop-up menu and shortcuts on Windows. It was made for the Samsung S Pen on Galaxy Book laptops, and works with most Windows pens that have a side button.

- **Tap** the pen button → a menu opens right at the pen.
- **Double tap** → play/pause music or video.
- **Triple tap** → show/hide the touch keyboard.
- **Tap, then press and hold** → **translate what you circle** (like *Circle to Search* on Android).
- Holding the button or erasing does nothing, so writing isn't affected.

Every gesture can be changed in the settings.

---

## What's in the menu

| Row | Tap | Hover |
|---|---|---|
| Screen snip | Windows region snip (goes to the clipboard) | — |
| Translate | Select-text translation (circle or tap text) | Select text, Whole screen |
| Paste | Pastes into the window you were in | Clipboard history (Win+V) |
| Undo | Undo; the menu stays open so you can tap again | Undo ×2, Redo, Redo ×2 |
| *Your apps* | Opens the app, or brings it to the front | — |
| Spotify | Opens Spotify. Shows the current song (scrolls if long) | Play/Pause, Next, Previous, Add to/Remove from Liked Songs (optional) |
| Task View | Win+Tab | Your virtual desktops; tap one to jump to it. The current one is highlighted |

Rows for apps that aren't installed (including Spotify) are hidden automatically. Close the menu by tapping outside it or pressing Esc.

You can also open the menu with the keyboard: **double-press Ctrl+Shift+]** (changeable).

---

## Install

1. Install **AutoHotkey v2** from [autohotkey.com](https://www.autohotkey.com), or run `winget install AutoHotkey.AutoHotkey`.
2. Download this project (green **Code** button → **Download ZIP**, or the latest release), unzip it, and put the folder somewhere permanent, for example `Documents\SPenMenu` (not Downloads).
3. Double-click **`SPenMenu.ahk`**. A green **H** appears in the tray.
4. **Start with Windows:** press Win+R, type `shell:startup`, and press Enter. Right-click `SPenMenu.ahk` → *Show more options* → *Create shortcut*, then move the shortcut into that folder.

**Samsung laptops:** if the Air Command menu still pops up when you press the pen button, turn it off in its settings gear, or disable *Air Command* in Task Manager → Startup apps.

---

## Settings

Right-click the tray icon → **Settings** to open `SPenMenu_settings.ini`. Every option has a note above it explaining what it does. Edit, save, then right-click the tray icon → **Reload**.

| Section | What you can change |
|---|---|
| `[Pen]` | Which pen signal counts as the button, and the tap/hold timing |
| `[Gestures]` | What tap, double tap, triple tap and tap+hold do (`menu`, `translate`, `translatescreen`, `playpause`, `keyboard`, `snip`, `paste`, `undo`, `taskview`, `none`) |
| `[Keyboard]` | The keyboard shortcut for the menu |
| `[Menu]` | Which rows appear and in what order |
| `[Apps]` | Your own apps in the menu (see below) |
| `[Desktops]` | Icons for your virtual desktops |
| `[Translate]` | Languages and the translation service |
| `[Spotify]` | Liked Songs button (optional) |
| `[Look]` | Colours and sizes |

The settings file is created the first time the script runs. If you delete it, a fresh one is made the next time the script starts.

### Add or swap apps
Under `[Apps]`, add one line per app:
```
Label=program.exe|full path|icon
```
- `Notepad=notepad.exe` is enough if the app is registered with Windows or already running.
- Add the full path if it isn't: `RemNote=RemNote.exe|%LOCALAPPDATA%\Programs\remnote\RemNote.exe`
- The icon is optional. Leave it out to use the app's own icon, or use `png:NAME` for `icons\NAME.png`.
- To remove an app, delete its line or put `;` in front of it.

### Desktop icons
The Task View submenu always shows your real desktops, using the names you gave them in Windows Task View. To add an icon, use the desktop's name:
```
[Desktops]
School=png:SCHOOL
Work=png:WORK
```
Desktops without an icon show their number.

### Replace icons
Put a PNG into the `icons` folder with the same name to replace a built-in icon. Square images with a transparent background look best. Reload afterwards.

`snip` `translate` `trselect` `trscreen` `paste` `clipboard` `undo` `undo2` `redo` `redo2` `remnote` `spotify` `play` `pause` `next` `prev` `like` `taskview` `school` `business` `editing` `other`

You can add new names too (for example `icons\work.png` → `png:WORK`).

---

## Translate

**Select text (default).** Tap the pen button, then press and hold (or tap *Translate* in the menu). The screen freezes under a glowing blue layer, like Circle to Search.
- **Circle or scribble** over the words you want, or **tap** a line to take its whole paragraph.
- The words light up, and the translation appears in a card just below them (or above, if there's no room), with a **Copy** button.
- Select again as often as you like; the blue layer stays until you press **Close** (or Esc, or any pen-button gesture).
- **Whole screen** at the top switches to translating everything.

**Whole screen.** In the menu, hover over Translate → *Whole screen*. You get a frozen copy of the screen with every piece of text replaced by its translation, plus two buttons at the top: **Show original / Show translation** switches between the two, and **Close** closes it.

Set your languages under `[Translate]`. `From` is the language on screen (default English). `To` is your language; if you leave it empty, your Windows language is used.

**Translation services:**

| Provider | Account needed | Free limit | Quality |
|---|---|---|---|
| `googlefree` (default) | No | No fixed limit, but Google may slow down or block heavy use | Very good |
| `mymemory` | No | About 5,000 characters a day (about 50,000 if you add `Email=`) | OK |
| `deepl` | Free DeepL API account → `ApiKey` | 500,000 characters a month | Best |
| `azure` | Azure Translator → `ApiKey` + `Region` | Has a free tier (check Azure's current limits) | Very good |
| `google` | Google Cloud Translation → `ApiKey` | Paid (new accounts get a trial credit) | Very good |

`googlefree` uses the same free Google Translate address that browser extensions and chat bots use. It isn't Google's official paid API, so Google could limit it or change it at any time. If it fails, the script automatically uses MyMemory instead.

**Things to know:**
- **Text recognition** is Windows' own and works offline. Windows needs the *on-screen* language installed for it: Settings → Time & language → Language & region → *Add a language* (for example English). It's usually there already.
- **Privacy:** the recognised text is sent to the translation service you chose, so don't use it on screens with passwords or private information.
- **Protected video** (for example Netflix in some browsers) can show up black in screenshots. Subtitles usually still work, because they're drawn on top of the video.
- **Games** should run in *borderless/windowed* mode; exclusive fullscreen can block the overlay.

---

## Optional extras

### Instant desktop switching
Download `VirtualDesktopAccessor.dll` from [github.com/Ciantic/VirtualDesktopAccessor/releases](https://github.com/Ciantic/VirtualDesktopAccessor/releases) and put it next to the script. Without it, desktop switching still works but slides through the desktops in between. After a big Windows update you may need a newer DLL.

### Spotify "Liked Songs" button
This needs **Spotify Premium** (a Spotify rule for personal developer apps). Every user needs their own app:
1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) → **Create app**.
   - Redirect URI: `http://127.0.0.1:8888/callback`, then click **Add**.
   - Tick **Web API**, then **Save**.
2. Copy the app's **Client ID** into the settings: `[Spotify] ClientId=...`. Save, then Reload.
3. Tray icon → **Connect Spotify (Liked Songs)**. Log in and press **Agree**.
4. If it says your account isn't registered: in the dashboard app, go to **User Management** and add your name and Spotify email, then try again.

Your login is saved in `spotify_token.txt`. Keep it private, and delete it to log out. Spotify asks you to log in again about every 6 months.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Pen button does nothing | Close S Pen Menu (tray → Exit) and run **`SPenMenu_diagnostic.ahk`**. Hover the pen and press the button, and note the name that appears only while it's pressed (for example `Invert(D/3C)` or `BARREL(D/44)`). Put the code after the `/` into `[Pen] ButtonUsages` (for example `0x3C`). |
| Menu opens when flipping the pen to its eraser end | Remove `0x3C` from `ButtonUsages` if your pen's side button is `0x44`. |
| Translate says "no text-recognition language" | Add the on-screen language in Windows settings (see above). |
| Translate says the free limit is used up | Add `Email=` under `[Translate]`, or switch to DeepL/Azure. |
| Paste/Undo doesn't work in one app | Apps running as administrator can't receive keys from a normal script. |
| Touch keyboard doesn't open | Make sure the touch keyboard is enabled in Settings → Time & language → Typing → Touch keyboard. |
| Something else | Right-click the tray icon → Reload. |

Other scripts can open the menu by posting window message `0x5A51` to the S Pen Menu script window.

---

## Files

| File | What it is |
|---|---|
| `SPenMenu.ahk` | The script |
| `SPenMenu_settings.ini` | Your settings (created on first run) |
| `SPenMenu_diagnostic.ahk` | Finds your pen's button signal |
| `icons\` | Replaceable icons |
| `VirtualDesktopAccessor.dll` | Optional; download it yourself |
| `spotify_token.txt` | Created if you connect Spotify; private |

## Tested on

- Samsung Galaxy Book5 Pro with its S Pen (Windows 11).

Other laptops and pens should work, since the button detection is generic, but they haven't been tested yet. If yours doesn't work, please open an issue (see below).

## Contributing / problems

Found a bug, or your pen isn't detected? [Open an issue](../../issues) and include:
- your laptop and pen model
- your Windows version
- for pen problems: the output of `SPenMenu_diagnostic.ahk` (hover the pen and press its button a few times, then use *Copy log*)

Pull requests are welcome.

## Credits & icon licences

- Desktop switching uses [VirtualDesktopAccessor](https://github.com/Ciantic/VirtualDesktopAccessor) by Ciantic (optional, downloaded separately).
- Icons: *[add the icon authors and sources here, e.g. "Icons by AUTHOR from flaticon.com"]*. Some icon sites require this credit; check each icon's licence.
- The Spotify and RemNote logos are trademarks of their owners and are only used to label those apps' buttons.
- You can replace any icon using the `icons` folder.

## Licence

MIT, see [LICENSE](LICENSE). Free to use, change and share.
