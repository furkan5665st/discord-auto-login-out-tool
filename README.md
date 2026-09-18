# Discord Auto Login-Out Tool

Keep your Discord desktop session logged in **only while Discord is open**.

* Open Discord with the provided shortcut: you are logged in instantly, no password.
* Close Discord: the session is deleted from disk, so nobody else can open Discord and get into your account.
* Shut down or restart Windows while Discord is open: the session is removed on shutdown, and any leftover is removed at the next logon.

Everything runs silently in the background. No console window, no tray icon, no running window to keep open.

> **Disclaimer** - This project is not affiliated with, endorsed by or associated with Discord Inc. It only copies and deletes files that Discord itself writes on your own computer and launches the official Discord app; it does not use Discord's API. Automating a user session may be a gray area under Discord's Terms of Service, so use it at your own risk.

---

## Table of contents

1. [Download](#download)
2. [How it works](#how-it-works)
3. [Requirements](#requirements)
4. [Project structure](#project-structure)
5. [Installation](#installation)
6. [Daily usage](#daily-usage)
7. [Settings](#settings)
8. [How the monitor works](#how-the-monitor-works)
9. [Security notes](#security-notes)
10. [Troubleshooting](#troubleshooting)
11. [Uninstalling](#uninstalling)
12. [FAQ](#faq)
13. [License](#license)

---

## Download

Grab the latest ZIP from the [Releases](https://github.com/furkan5665st/discord-auto-login-out-tool/releases) page, extract it wherever you like and follow the installation steps below. Git is not required.

The ZIP contains source files only. No session data, no token, nothing machine specific.

---

## How it works

Discord's desktop app stores your login (the session token) in a LevelDB folder:

```
%APPDATA%\discord\Local Storage\leveldb
```

* **Copying that folder = saving the token.**
* **Deleting that folder = logging out.**

The tool does exactly this at the right moments:

| Moment | Action |
|---|---|
| You open Discord with the shortcut | The saved session folder is copied back into place, then Discord is started, so it logs in automatically |
| You close Discord (tray icon > Quit Discord) | The current session is saved back to the backup folder, then the session files are deleted |
| Windows shuts down or you log off | A shutdown hook closes Discord and deletes the session files |
| Windows starts or you log on | The monitor starts, and any leftover session files from a previous crash or forced shutdown are deleted |
| You open Discord normally (not the shortcut) | Nothing is restored, so Discord shows the login screen |

The small hidden background program that performs all of this is called the **monitor**.

---

## Requirements

* Windows 10 or Windows 11
* Windows PowerShell 5.1 (already included in Windows, nothing to install)
* Discord desktop app installed for the current Windows user
* No administrator rights needed

---

## Project structure

```
discord-auto-login-out-tool\
|-- README.md                  this file
|-- Settings.ini               configuration
|-- Install.bat                installs the monitor and creates the desktop shortcut
|-- Uninstall.bat              removes the monitor and the shortcut
|-- 1-Backup-Session.bat       saves (or refreshes) the session token
|-- 2-Open-Discord.bat         opens Discord with the saved session (console visible)
|-- 2-Open-Discord.vbs         the same launcher without any window, created by Install.bat
|-- 3-Status.bat               shows everything the monitor knows
|-- Pause-Monitor.bat          temporarily disables auto login and auto logout
|-- Resume-Monitor.bat         re-enables the monitor
|-- engine\
|  \-- Monitor.ps1             the program itself
|-- backup\
|  |-- leveldb\                the saved session (contains your token, keep it private)
|  \-- leveldb-previous\       one older copy of the session, kept as a safety net
\-- state\
   |-- monitor.log             what happened and when
   |-- paused.flag             exists while the monitor is paused
   |-- busy.flag               exists while a launch or repair is running
   |-- ready.flag              set when a session was just restored
   \-- repair-history.txt      timestamps of automatic repairs
```

`backup\` and `state\` are runtime folders. They are created automatically and are **excluded from Git** by `.gitignore`, because the backup contains a credential.

---

## Installation

### 1. Prepare Discord

1. Start Discord and sign in normally.
2. Leave the application fully signed in, then close it completely:
   * close the Discord window, then
   * right click the Discord icon in the system tray (bottom right, next to the clock) and choose **Quit Discord**.

Signing out is not required, and it is not the same thing: just close the application.

### 2. Save the session

Double click `1-Backup-Session.bat`.

You should see:

```
 [OK] Session saved and token verified inside the backup.
```

If you see an error instead, read the [troubleshooting](#troubleshooting) section.

### 3. Install the monitor

Double click `Install.bat`. It creates:

* a startup entry in your Windows Startup folder, so the monitor runs at every logon
* a desktop shortcut named **Discord (Auto Login)**, which opens Discord without any window

You should see:

```
 [OK] Installation finished.
      Startup entry  : ...\Startup\Discord-Session-Monitor.vbs
      Desktop shortcut: ...\Desktop\Discord (Auto Login).lnk
      Monitor running : True
```

**Important:** from now on, open Discord with the **Discord (Auto Login)** desktop shortcut. Opening Discord any other way shows the login screen, because the saved session is not restored.

### 4. Optional: open Discord automatically at logon

Discord's own "Open Discord on startup" option must stay **off**. If you want Discord to open automatically, set `OPEN_AT_STARTUP=1` in `Settings.ini` instead and restart the monitor. See [Settings](#settings).

### 5. Done

Open Discord with the shortcut, use it, close it. When you quit it, the session is removed from disk.

---

## Daily usage

**Open Discord**

Use the desktop shortcut **Discord (Auto Login)**, or run `2-Open-Discord.bat`. Discord starts already signed in.

**Close Discord**

Close it normally. If it only minimises to the tray, right click the tray icon and choose **Quit Discord**.

About four seconds after Discord exits, the session is saved and then deleted. The log records it:

```
Discord closed -> ending the session
Backup refreshed with the current token
Logged out
```

**Check the state**

Run `3-Status.bat`:

```
 --- Discord Session Monitor - Status ---
  Installed (runs at logon)   : True
  Monitor running             : True
  Paused                      : False
  Discord running             : False
  Token found in Discord data : False
  Session evidence in logs    : True
  Backup valid (CURRENT file) : True
  Backup last updated         : 09/18/2026 19:16:47
  Backup size (KB)            : 2311
  Previous backup generation  : True
```

**Pause temporarily**

Run `Pause-Monitor.bat` before doing something that would otherwise conflict, for example logging into a different account. With the monitor paused, nothing is restored and nothing is deleted. Run `Resume-Monitor.bat` to activate it again.

---

## Settings

All settings live in `Settings.ini`, one `KEY=value` per line. Any line starting with `;` or `#` is ignored, so you can keep your own notes there.

| Key | Default | Meaning |
|---|---|---|
| `POLL_SECONDS` | `3` | How often the monitor checks whether Discord is running. Values below 2 are raised to 2. |
| `AUTO_REPAIR` | `0` | `1` makes the monitor also fix a normal Discord start: if Discord is running but never logged in, it closes Discord, restores the saved session and starts Discord again. More convenient, less strict. |
| `REFRESH_BACKUP` | `1` | `1` saves the current session back to `backup\leveldb` every time Discord closes, so the stored token stays fresh. It is only refreshed when a successful login was confirmed for that session. |
| `WRITE_LOG` | `1` | `1` writes `state\monitor.log`. |
| `OPEN_AT_STARTUP` | `0` | `1` starts Discord with the saved session when the monitor starts at logon. Requires Discord's own "Open Discord on startup" option to be off. |

Changes to `AUTO_REPAIR` take effect immediately. For `OPEN_AT_STARTUP`, restart the monitor (log off and on again, or run `Uninstall.bat` and then `Install.bat`).

---

## How the monitor works

The monitor is a single hidden PowerShell process. It is started at logon by `Discord-Session-Monitor.vbs` in your Startup folder, and it exits if another copy is already running (single instance through a named mutex).

Every `POLL_SECONDS` it looks at whether Discord is running and reacts to changes:

### Discord starts

1. It records the start time of the Discord process.
2. It reads Discord's own log `%APPDATA%\discord\logs\renderer_js.log` and looks for a gateway `READY` entry that is newer than that process start. That entry only appears when Discord really established a session, which is how the monitor knows the difference between "logged in" and "sitting on the login screen".
3. Login confirmed -> `Session evidence` becomes true and the session is allowed to be saved later.

### Discord closes

1. It waits four seconds so Discord can flush its data.
2. If this session was confirmed to be logged in, it saves the current session to `backup\leveldb`. The previous backup is moved to `backup\leveldb-previous` first, so a good copy is never lost.
3. It deletes `Local Storage\leveldb` and `Session Storage`, which logs the account out on disk.

### Windows shuts down or you log off

The monitor registers a session-ending hook. When Windows starts shutting down, it closes Discord, deletes the session files and writes `SHUTDOWN: session removed` to the log. If Windows does not give it the chance (power loss, reset button, forced power off), the leftover session is deleted the next time the monitor starts.

### At logon

If Discord is not running and session files are still present on disk, they are deleted immediately. This is what makes a shutdown without quitting Discord safe.

### Race protection

Launching Discord and the monitor background work must never overlap, otherwise a half-copied session could be restored. The launcher therefore raises a `busy.flag` before touching anything and clears it only after Discord is running. The monitor does nothing at all while that flag, or `paused.flag`, exists.

### Copy validation

Every restore and every backup is validated: the folder must contain a `CURRENT` file and be at least 50 KB. Each copy is retried up to three times. A backup is never overwritten with something that does not pass this check.

---

## Security notes

* `backup\leveldb` contains your Discord session token. Anyone who gets that folder can sign in to your account **without knowing your password**.
* Never commit, upload or share the `backup` folder. `.gitignore` already excludes it, keep it that way.
* Keep the whole project folder private. On a shared PC, restrict the folder permissions to your own Windows account.
* If you think the token leaked: in Discord open **User Settings > Devices** and use **Log Out All Known Devices**, change your password, then sign in again and run `1-Backup-Session.bat` to store a fresh token.
* Deleting the session folder does not sign you out on Discord's servers. It removes the local session, so someone who opens Discord on this PC afterwards sees the login screen.
* The monitor does not read, decrypt, print or transmit your password or token content. It only copies and deletes files, and it reads Discord's log file to check whether a login succeeded.

---

## Troubleshooting

**Discord asks for the password / auto login stopped working**

1. Sign in to Discord manually.
2. Quit Discord completely (tray icon > Quit Discord).
3. Run `1-Backup-Session.bat`.
4. Open Discord with the shortcut again.

**`[ERROR] Discord is currently running`**

The session can only be saved while Discord is closed. Close the window, quit it from the tray icon, then run the backup again.

**`[ERROR] No session backup found`**

`1-Backup-Session.bat` has never been run successfully. Run it while Discord is closed and signed in.

**Discord is not logged out when I close it**

Run `3-Status.bat` and check:

* `Monitor running` must be `True`. If it is `False`, run `Install.bat`.
* `Paused` must be `False`. If it is `True`, run `Resume-Monitor.bat`.
* The last log lines should end with `Logged out`.

**A normal Discord start shows the login screen**

That is intended when `AUTO_REPAIR=0`. Use the desktop shortcut instead, or set `AUTO_REPAIR=1` if you want any start to be repaired automatically.

**The backup looks broken**

Copy the content of `backup\leveldb-previous` into `backup\leveldb` and try again.

**Start over**

Run `Uninstall.bat`, then delete the `backup` and `state` folders, then follow the installation steps again.

---

## Uninstalling

1. Run `Uninstall.bat`. It removes the startup entry, the desktop shortcut and stops the monitor. The `backup` folder is kept on purpose.
2. Delete the project folder if you do not need it anymore. Deleting `backup` throws away the saved session, so Discord will simply ask for your password next time.

---

## FAQ

**Does this work with Discord PTB or Canary?**
The monitor watches `Discord.exe`, `DiscordPTB.exe` and `DiscordCanary.exe` for process detection, but the session paths used are the stable Discord ones. Stable Discord is the tested configuration.

**Do I have to keep any window open?**
No. The monitor runs hidden and is restarted automatically at every logon.

**Will a Discord update break it?**
No. Discord is always started through its own updater, `Update.exe --processStart Discord.exe`, with a fallback to the newest installed `app-*` folder.

**Is my password stored anywhere?**
No. Only Discord's own session files are copied, exactly as Discord wrote them.

**Can I use several accounts?**
Yes, one at a time: sign in with the account you want, run `1-Backup-Session.bat`, and that account becomes the one restored by the shortcut.

---

## License

MIT, see [LICENSE](LICENSE).

The software is provided as is, without warranty of any kind. See the disclaimer at the top of this document.
