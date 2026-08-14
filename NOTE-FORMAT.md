# Meeting note format

This is the **output contract** of AI Meeting Notes. Every meeting becomes one
Markdown file (plus its audio) in a folder you choose. Because it's plain
Markdown, any tool can read it - [Obsidian](https://obsidian.md) is one nice
option, but nothing here depends on Obsidian.

Both the macOS and Windows apps write **byte-for-byte the same format**, so notes
are interchangeable across platforms.

## Where files go

For a notes folder `<folder>` (often, but not necessarily, an Obsidian vault):

```
<folder>/
  Meeting 2026-06-24 09-30-00.md          ← the note
  recordings/
    Meeting 2026-06-24 09-30-00.mic.wav   ← your microphone
    Meeting 2026-06-24 09-30-00.system.wav← everyone else (system audio)
```

## The note

```markdown
---
type: meeting
tags: [meeting]
date: 2026-06-24 09-30-00
audio: recordings/Meeting 2026-06-24 09-30-00
duration: 1800
speakers: 3
model: ggml-large-v3-turbo.bin
summary_model: ollama/llama3.1:8b
app_version: 0.1.0
---

# Meeting 2026-06-24 09-30-00

## Short summary
…

## Summary
…

## Topics discussed
…

## Action items
- [ ] …

## Transcript

[0:00] **You:** Hi everyone, thanks for joining…

[0:08] **Them:** Morning! …

## Audio

**You (microphone)**

![[Meeting 2026-06-24 09-30-00.mic.wav]]

**Them (system audio)**

![[Meeting 2026-06-24 09-30-00.system.wav]]
```

## Frontmatter keys

| Key | Always? | Meaning |
|---|---|---|
| `type` | yes | Always `meeting` - lets you query meetings (e.g. Dataview). |
| `tags` | yes | `[meeting]`. |
| `date` | yes | Recording start, `yyyy-MM-dd HH-mm-ss`. Used for stable ordering. |
| `audio` | yes | Vault-relative stem of the two audio tracks (no extension). |
| `duration` | if > 0 | Recording length in seconds. |
| `speakers` | if ≥ 2 | Fixed remote-speaker count (diarization); absent means auto. |
| `model` | if known | The whisper model file that produced the transcript, so a garbled transcript is traceable to the model used. |
| `summary_model` | if summarized | Engine + model that wrote the summary, as `provider/model` (e.g. `ollama/llama3.1:8b`, `claude/claude-opus-4-8`). Absent when there's no summary. Never contains an API key. On a re-generate whose summary failed, the note keeps the previous summary *and* this value. |
| `app_version` | yes | App version that produced the note. |

Keys are written in the order above; readers must not depend on it (use
`frontmatterValue` / `NoteFormat.FrontmatterValue`), but both apps emit it
identically so notes stay byte-comparable.

## Body conventions

- **`# <title>`** - the note title (same as the file name).
- **Summary block** (optional) - the AI summary sections, present only when
  summarization ran. The exact subheadings come from the summary prompt; the
  default is *Short summary / Summary / Topics discussed / Action items*.
- **`## Transcript`** - lines are `[m:ss] **Speaker:** text`. Speakers are
  **You** (your mic) and **Them** (system audio); with diarization on, the system
  side may split into `Them 1`, `Them 2`, … If there's no speech: `_(no speech
  detected)_`.
- **`## Audio`** - embeds the two tracks with Obsidian's `![[…]]` syntax so they
  render as inline players *if* you're in Obsidian. In any other editor these are
  just links to the `.wav` files. The app hides this section in its own UI (it has
  direct access to the recordings).

## Why this is a contract

Treating the note format as a stable, documented contract means:

- the two apps stay interchangeable (they already produce identical output);
- you can point the notes folder at Obsidian, Logseq, a plain folder, or a future
  web viewer - the files don't change;
- anything that wants to read or index your meetings (a script, a plugin, a
  dashboard) can rely on these keys and headings.