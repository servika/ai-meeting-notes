# AI Meeting Notes

> Record a meeting - **your microphone + the other participants' audio** - then
> transcribe and summarize it **100% locally**. You get a Markdown note (summary,
> action items, speaker-labeled transcript) plus the audio, saved to a folder you
> choose. No cloud, no API keys, no companion server. Your audio never leaves your
> machine.

[![macOS release](https://img.shields.io/github/v/release/servika/ai-meeting-notes?filter=v*&label=macOS&logo=apple&logoColor=white&color=111111)](https://github.com/servika/ai-meeting-notes/releases/latest)
[![Windows release](https://img.shields.io/github/v/release/servika/ai-meeting-notes?filter=win-v*&label=Windows&logo=windows&logoColor=white&color=0078D6)](https://github.com/servika/ai-meeting-notes/releases?q=win&expanded=true)
[![Downloads](https://img.shields.io/github/downloads/servika/ai-meeting-notes/total?label=downloads&color=6f42c1)](https://github.com/servika/ai-meeting-notes/releases)
![License: MIT](https://img.shields.io/badge/license-MIT-green)
![Built with Swift &amp; .NET](https://img.shields.io/badge/built%20with-Swift%20%26%20.NET-orange)

🌐 **Website / downloads:** https://servika.github.io/ai-meeting-notes/

## What it is

A **desktop app** that does three things and gets out of the way:

**record → transcribe → summarize**, written out as plain Markdown.

The output is the point: a **folder of Markdown notes + audio files** in the exact
[meeting-note format](NOTE-FORMAT.md). That folder is portable - read it with
anything. If it's inside an [Obsidian](https://obsidian.md) vault you get inline
audio players and queryable frontmatter for free, but **Obsidian is optional** -
the notes are just Markdown.

```
  [ macOS app ]  ┐
                 ├──►  folder of Markdown notes + audio  ──►  read with anything
  [ Windows app ]┘        (the portable output)               (Obsidian, an editor,
                                                               plain Finder…)
```

## The apps

### 🍎 macOS (recommended)

Zero-setup capture of system audio + your mic via Core Audio process taps (**no
virtual audio device**), automatic language detection, "You vs. Them" diarization,
AI summaries, and a built-in meetings library.

**[Download the latest `.dmg`](https://servika.github.io/ai-meeting-notes/)** -
signed & notarized, opens with no Gatekeeper warning. Details:
**[packages/meeting-engine/README.md](packages/meeting-engine/README.md)**.

### 🪟 Windows (paused)

> **Builds are temporarily paused** while the Windows build environment is
> unavailable. The source stays in the repo and earlier
> [beta releases](https://github.com/servika/ai-meeting-notes/releases?q=win&expanded=true)
> remain downloadable, but new builds aren't being produced and the port isn't
> currently maintained.

The same record → transcribe → summarize flow, capturing system audio via WASAPI
loopback + the mic via WASAPI - also **no virtual audio device**. Self-contained
installer, no .NET needed. Details:
**[packages/meeting-notes-windows/README.md](packages/meeting-notes-windows/README.md)**.

## How it works

1. **Record** - your mic and the system audio are captured as two separate tracks
   (so "who spoke" is free: you vs. everyone else).
2. **Transcribe** - each track runs through [whisper.cpp](https://github.com/ggerganov/whisper.cpp)
   locally, then they're merged by timestamp into one speaker-labeled transcript.
3. **Summarize** (optional) - a local [Ollama](https://ollama.com) model or the
   Claude API turns the transcript into a short summary, summary, topics, and
   action items.
4. **Save** - a Markdown note + the audio land in your chosen folder, in the
   [documented format](NOTE-FORMAT.md).

Transcription and summaries run on your machine. The only time anything leaves it
is if you deliberately choose the Claude summary option (using your own API key).

## Obsidian (optional)

Point the app's notes folder at an Obsidian vault and the `![[audio.wav]]` embeds
render as inline players and the `type: meeting` frontmatter becomes queryable
(e.g. with Dataview). That's the whole integration - the app never depends on
Obsidian.

There is also a **retired Obsidian plugin** that records inside Obsidian itself
(it predates the app and needs a loopback-device setup the app avoids). It's **no
longer maintained** and superseded by the app in every respect - you don't need it
for the vault workflow above. Kept for the record only - see
**[packages/ai-meeting-notes/README.md](packages/ai-meeting-notes/README.md)**.

## Privacy

Recording, transcription, and (with Ollama) summarizing all happen on your device.
The only outbound request is the optional Claude summary, which sends transcript
text to Anthropic with your key. A local-only setup makes no network requests
except when you ask it to download a model.

## Credits & license

Built on whisper.cpp, Silero VAD, Ollama, NAudio, .NET, and more - see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Planned work:
[ROADMAP.md](ROADMAP.md).

[MIT](LICENSE) © Sergii Bataiev