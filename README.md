<div align="center">

<img src="docs/hero.png" alt="The NotchVoice panel open under a MacBook notch while Claude Code speaks, with a violet and orange glow around it" width="820">

# NotchVoice

**Claude Code, out loud. Right in your MacBook's notch.**

Hear every Claude Code reply spoken aloud. The notch glows while Claude talks, and hovering over it brings up the controls.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#install)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](Package.swift)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Stop%20hook-D97757?logo=claude&logoColor=white)](https://claude.com/claude-code)
[![Speech](https://img.shields.io/badge/speech-100%25%20offline-2EA44F)](#how-it-works)

</div>

## Features

- **Spoken replies.** Claude Code reads each reply aloud as soon as it finishes. Speech runs fully offline through macOS `say`, with markdown tidied up and code blocks skipped.
- **A notch that glows.** A soft, shifting glow surrounds the notch while Claude talks.
- **Music steps aside.** Spotify and Apple Music get quieter while Claude speaks, then return to the volume they were at.
- **Controls in the notch.** Hover over the notch to turn voice replies on or off. Turning them off mid-sentence stops the speech straight away.
- **Your choice of voice.** Pick any installed macOS voice and hear a short sample straight away.
- **Stays out of the way.** No Dock icon and no menu bar item. It uses almost no CPU while idle, and it opens at login.

<table>
  <tr>
    <td width="50%"><img src="docs/glow.png" alt="The closed notch glowing in violet and orange while Claude speaks"></td>
    <td width="50%"><img src="docs/muted.png" alt="The NotchVoice panel with voice replies switched off"></td>
  </tr>
  <tr>
    <td align="center"><b>Glows while Claude speaks</b></td>
    <td align="center"><b>Off with one click</b></td>
  </tr>
</table>

## Install

You need macOS 14 or later, [Claude Code](https://claude.com/claude-code), and Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/NCSmit/notch-voice.git
cd notch-voice
./install.sh
```

Then restart Claude Code and hover over the notch.

> [!TIP]
> The first time Claude speaks while Spotify or Music is open, macOS asks whether it may control that app. Allow it, so the music can get quieter.

The installer does four things:

1. It copies the voice hook to `~/.claude/hooks/speak.py`. If a file is already there, it is saved as `speak.py.bak` first.
2. It adds the hook to `~/.claude/settings.json` and keeps a backup of that file.
3. It builds the app on your Mac and puts it in `~/Applications`. Because the app is built locally, macOS doesn't show a security warning.
4. It starts the app, which then opens at login.

On a Mac without a notch, the panel sits at the top center of the screen instead.

## How it works

```mermaid
flowchart LR
    A["Claude Code finishes a reply"] --> B["speak.py (Stop hook)"]
    B --> C["say reads the reply aloud"]
    B --> D["Spotify and Music get quieter"]
    B -.->|writes| E[("Shared files")]
    F["NotchVoice in the notch"] -.->|reads and writes| E
```

The hook does the speaking. The app gives you the controls and the glow. They share three small files:

| File | Written by | Used for |
| --- | --- | --- |
| `~/.claude/tts_off` | The switch | While this file exists, the hook stays silent. |
| `~/.claude/tts_voice` | The voice picker | The hook passes this voice to `say -v`. Without the file, `say` uses your system voice. |
| `$TMPDIR/claude_tts_owner` | The hook | Holds `<hook pid> <say pid>` while a reply is spoken. The glow follows this file. |

Right-click the panel for **Open at Login** and **Quit**.

## Configuration

Set these in the `env` block of `~/.claude/settings.json`:

| Variable | Default | What it does |
| --- | --- | --- |
| `CLAUDE_TTS_RATE` | System rate | Speaking rate, in words per minute. |
| `CLAUDE_TTS_DUCK` | `0.5` | How loud the music stays while Claude speaks, as a fraction of its volume. |
| `CLAUDE_TTS_VOICE` | System voice | The voice to use when none is picked in the notch. |

## Uninstall

```bash
./install.sh --uninstall
```

This removes the app, its login item, the hook, and the hook's entry in `settings.json`.

## Troubleshooting

<details>
<summary><b>Claude doesn't speak</b></summary>

- Restart Claude Code after installing. Hooks are loaded when a session starts.
- Hover over the notch and check that voice replies are on.
- Run `say hello` in Terminal to check that your Mac can speak.

</details>

<details>
<summary><b>The music doesn't get quieter</b></summary>

Open System Settings → Privacy & Security → Automation. Allow Claude Code, or your terminal app, to control Spotify and Music.

</details>

<details>
<summary><b>I want better voices</b></summary>

Download Premium or Enhanced voices in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices. The next time you open the voice menu in the notch, they're in the list.

</details>
