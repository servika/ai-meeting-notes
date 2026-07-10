# Changelog

All notable changes are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This repo ships these apps, versioned independently:

- **macOS app** - `packages/meeting-engine` (version in `packages/meeting-engine/VERSION`)
- **Windows app** - `packages/meeting-notes-windows` (version in its `VERSION`)
- **Obsidian plugin** (legacy) - `packages/ai-meeting-notes` (version in its `manifest.json`)

---

## macOS app

### [0.37.0] - 2026-07-07

#### Added
- **Loudness diagram in the Trim window.** The trim screen now shows a compact
  waveform-style strip of the recording's loudness over time: quiet stretches are
  dimmed so the spot where the meeting actually ended (sound dies down, but the
  recording keeps going) stands out at a glance. The part that would be removed is
  tinted red, and clicking or dragging on the diagram places the cut point directly.

### [0.36.1] - 2026-07-07

#### Fixed
- **Trim window now closes after confirming a trim.** Confirming "Trim & Re-generate"
  left the trim window open in a dead state (player unloaded, every control except
  Cancel disabled) because the dismiss call from inside the confirmation dialog only
  closed the dialog. The confirm action now closes the window itself; the trim ran
  fine either way.

### [0.36.0] - 2026-07-07

#### Added
- **Trim recording.** For meetings where you forgot to stop recording (and the file
  ends with unrelated audio), a new scissors button in the meeting's toolbar opens a
  dedicated Trim window: listen with the built-in player, place the cut point (slider
  or "Set to playhead"), and trim. Both tracks (mic + system, WAV or compressed m4a)
  are shortened in place - each replaced atomically only after the shortened copy is
  fully written - and the note is then re-transcribed and re-summarized from the
  shorter audio, so the summary no longer includes the after-meeting noise.

### [0.35.0] - 2026-07-03

#### Fixed
- **Compress button no longer appears while a meeting is still processing.** Because
  compression is the last pipeline step (transcribe → summarize → compress), a long
  meeting's note showed a Compress button for the minutes before its audio was
  compressed - making it look like auto-compression hadn't run. It now shows only
  when a meeting is idle and still has uncompressed WAVs (a genuinely interrupted or
  failed recording); normal processing compresses at the end as before, with the
  progress bar reporting it.

### [0.34.0] - 2026-07-02

#### Changed
- **Meeting-detected prompt is now a desktop card, not an in-app banner.** When
  another app starts using your microphone, a floating "Are you in a meeting?" card
  (Start meeting notes / Not now) now appears at the **top-center of your screen**,
  over whatever app you're in - so you actually see it during the call instead of
  only inside this app's window. It doesn't steal focus and auto-dismisses if
  ignored. Detection remains microphone-based (a real call uses your mic), which
  avoids false alarms from things like a YouTube video.

### [0.33.0] - 2026-06-30

#### Fixed
- **Re-generate no longer wipes a good summary when summarization fails.** If the
  summary step errored or returned nothing - e.g. a local model timing out while the
  CPU was overloaded - Re-generate used to overwrite the note with an *empty* summary
  and still report "✅ Re-generated", silently losing the previous summary. Now a
  failed summary is reported honestly ("⚠️ summary failed…") and the note keeps its
  existing summary instead of being cleared; only the transcript is refreshed. New
  recordings likewise surface the failure ("⚠️ Saved … - summary failed. Re-generate
  to retry.") instead of a false success. An empty model response is treated as a
  failure too, not a valid (blank) summary.

### [0.32.0] - 2026-06-30

#### Added
- **Notion-style floating meeting prompt.** When a meeting is detected while you're
  in another app, a small floating card now appears over your screen - "Are you in a
  meeting?" with **Start meeting notes** / **Not now** - instead of a plain system
  notification. It's non-intrusive (doesn't steal focus) and auto-dismisses if
  ignored. The in-app banner still covers the case where this app is in front.
- **Optional calendar confirmation (EventKit).** New Settings → Recording toggle,
  "Use my calendar to confirm meetings" (off by default). When on, the prompt only
  fires during a real scheduled event and names it in the card ("'Standup' is on your
  calendar right now") - cutting false "are you in a meeting?" nudges from incidental
  mic use. Calendar access is requested only when you turn this on.

### [0.31.0] - 2026-06-29

#### Added
- **Auto-stop a recording you forgot to stop.** A recording no longer runs forever
  if you end the meeting but forget to click Stop. It stops on its own - and then
  transcribes/summarizes as usual - when the call goes silent (both tracks quiet) for
  a configurable number of minutes (default 10), when your Mac sleeps or the screen
  locks, or after a 4-hour safety cap. A notification tells you when it happened. The
  whole behavior is a single checkbox in Settings → Recording ("Auto-stop a recording
  I forgot to stop"), with the silence window adjustable; turn it off for fully manual
  recording.

### [0.30.0] - 2026-06-26

#### Added
- **Built-in meeting audio player.** Listen to a recording without juggling its two
  files - the mic ("You") and system ("Them") tracks are mixed into one timeline and
  played through a single transport in the meeting detail view: play/pause (Space),
  back-to-start, jump ±15 s, and a clickable position bar you can scrub to any second.
  A speed menu offers 0.5×, 1×, 1.5×, 2×, 3×, and 5× with pitch correction so voices
  stay intelligible. Works with both the original WAVs and compressed m4a tracks.

### [0.29.0] - 2026-06-26

#### Added
- **More meeting languages in the record-panel picker.** Added Polish, Croatian, and
  Spanish (Argentina) alongside Auto-detect, English, and Ukrainian. As with any
  non-English language, transcription needs a multilingual model (not the `.en`
  variant).
- **`model:` recorded in note frontmatter.** Each transcribed note now records which
  whisper model produced it (e.g. `model: large-v3-turbo`), so a garbled transcript
  is traceable to the model used rather than a mystery.

#### Fixed
- **Cross-track echo removed from transcripts.** In-person and speakerphone meetings
  capture the same room on both the mic ("You") and system ("Them") tracks, so every
  utterance was transcribed twice and the merged transcript came out doubled and
  mislabeled. Near-duplicate segments that overlap in time are now collapsed to the
  fullest copy. The pass is conservative - it only drops words already carried by a
  kept segment, so no content is lost, and genuine remote meetings (different audio
  per track) are unaffected.
- **Per-language model override now applies under Auto-detect.** When the meeting
  language was left at `auto`, a configured override (e.g. large-v3-turbo for
  Ukrainian) was silently ignored and transcription fell back to the weaker default
  model - producing garbled, hallucinated transcripts on non-English audio. With a
  single override configured, it's now honored for `auto` too.

### [0.28.0] - 2026-06-25

#### Added
- **Native macOS notification on meeting detection.** When another app (Zoom,
  Teams, Meet, FaceTime…) starts using your mic while AI Meeting Notes is in the
  background or hidden, you now get a system notification ("Meeting detected") with
  a **Record** action that starts capture directly. Foreground keeps the existing
  in-app nudge (no double-alert). Respects the "Suggest recording when a meeting is
  detected" toggle, asks for notification permission on first use, and fires once
  per meeting.
- **First-run onboarding in the main window.** Before a notes folder is set, the
  main (detail) area now shows a "Welcome to AI Meeting Notes" prompt with an
  **Open Settings to set up** button, instead of the unhelpful "No meeting
  selected". (The record panel already showed a smaller "choose a folder" banner;
  this makes the central area guide first-time users too.)

### [0.27.1] - 2026-06-24

#### Added
- **"Compress audio" button** on a meeting whose recording is still uncompressed
  WAV. It transcodes the tracks to AAC `.m4a` in place and updates the note's audio
  embeds - **without re-transcribing** (fast, and the transcript is untouched). A
  direct way to shrink older, high-quality recordings. Re-generate is now purely
  re-transcription and never changes the audio.

### [0.27.0] - 2026-06-24

#### Added
- **Audio storage options after transcription.** A new Settings → Recording
  control - **Audio after transcription**: *Compressed (recommended, default)*,
  *Best quality (keep original WAV)*, or *Delete (text only)*. Compressed transcodes
  the two tracks to small AAC `.m4a` files (~10× smaller) via afconvert and updates
  the note's audio embeds; Delete removes the audio and notes "_Audio removed after
  transcription_" in the meeting. Re-generate and the meeting list keep working with
  either format; only Delete forgoes re-listen/Re-generate (it's an explicit opt-in).
  Audio-only recordings (transcription off) are never touched.
- **Ollama: detect state, guide setup, and download models in-app.** The Summary
  tab now checks whether Ollama is **running**, **installed but not running**, or
  **not installed**, and shows the right next step for each: a **Download Ollama**
  link (ollama.com) when absent, an **Open Ollama** button when it's installed but
  stopped, or the model controls when it's running. You can now **download a model
  from inside the app** - a model picker (recommended size for your Mac first) + a
  Download button with a progress bar, mirroring the whisper-model download in the
  Transcription tab - instead of running `ollama pull` in a terminal. The
  summarize-time error also now
  distinguishes "not installed" from "not running" instead of always saying
  "install it".
- **Update notifications.** The app checks GitHub Releases on launch (throttled to
  once a day) for a newer macOS version and, when one exists, shows a slim
  "Version X is available - Download" bar at the top of the window (dismissible
  until the next version). Settings → About also has a manual **Check for updates**
  button. Privacy-safe: a single outbound request to the public GitHub API, no
  telemetry, and nothing auto-installs - the Download button just opens the
  release page.

#### Fixed
- **No silent failure when no notes folder is set.** If you click Record before
  choosing a notes folder, the record panel now shows a clear "Choose a notes
  folder to start" banner with an **Open Settings** button, and the Record button
  is disabled until a folder is set - instead of doing nothing with only a small
  status line. Also reworded the prompt away from "Obsidian vault" (any folder
  works; Obsidian is optional).

#### Changed
- **Each process owns its Settings tab.** The on/off toggle for transcription now
  lives on the **Transcription** tab and the summary toggle on the **Summary** tab,
  each next to that process's own settings - instead of both being bundled in a
  shared "Processing steps" section under General. Cleaner separation; no behavior
  change.
- **Accurate "time left" on the first run.** The processing ETA now extrapolates
  from live transcription progress once it's underway, instead of relying only on
  the per-model estimate (which isn't calibrated until you've processed at least
  one meeting). Previously a first-run transcription could show "finishing…" for
  minutes; now it shows a real, shrinking estimate from the start.
- **Removed "Obsidian" wording from Settings.** The Storage section, folder field,
  and folder-picker no longer say "Obsidian vault" - they just refer to a notes
  folder (any folder works), with a one-line hint that meetings are saved as
  Markdown there. Existing saved folders are unaffected.

### [0.26.1] - 2026-06-24

#### Added
- **One-command release.** `scripts/make-dmg.sh --release` now publishes a
  GitHub Release (tag `v<VERSION>`) with the notarized DMG attached under the
  stable name `AI-Meeting-Notes.dmg` - the filename the landing page's download
  button points at via `/releases/latest/`. Refuses to release a non-notarized
  DMG; updates the asset in place if the release tag already exists.

### [0.26.0] - 2026-06-21

#### Changed
- **Feature-flag system for experiments.** Experimental features are now driven
  by a small catalog of flags (`FeatureFlag`) instead of one-off booleans. Each
  flag's on/off state lives in `featureFlags` and only takes effect when
  Experimental mode is on; the Settings UI renders a toggle (with description and
  a dependency/availability note) for every flag automatically. Adding a new
  experiment is now one enum case. Speaker recognition is the first flag, and its
  on/off moved to General → Experimental features (its speaker-count config stays
  in the Transcription tab). The legacy `recognizeSpeakers` setting is migrated
  automatically.
- **Refactor: summary prompts extracted.** The baked-in per-model summary prompts
  moved out of `AppSettings` into a dedicated `SummaryPrompts` file, leaving the
  settings type focused on persisted state.
- **About: trimmed personal links.** The About tab now shows only the project
  GitHub link; the personal Website and LinkedIn links were removed.

### [0.25.0] - 2026-06-21

#### Added
- **Experimental mode.** A master switch in Settings → General → "Experimental
  features" that gates new, in-development R&D features. Off by default, so the
  regular experience is unchanged; speaker recognition (and future experiments)
  only appear and run when it's on.
- **Per-meeting speaker count.** When speaker recognition is on, you can set how
  many remote speakers are on the call instead of relying on auto-detection
  (which is unreliable on real, mixed/compressed meeting audio - verified on a
  real daily sync where auto-detect found 70+ "speakers"). The count is stored
  per meeting in the note's `speakers:` frontmatter, can be set before recording
  (record panel) or corrected on an existing meeting and applied via
  Re-generate, and is passed to sherpa-onnx as a fixed cluster count.

#### Changed
- Speaker recognition is now gated behind Experimental mode (it was previously
  always visible in the Transcription tab).

### [0.24.0] - 2026-06-21

#### Added
- **Per-stage processing controls.** Settings → General → "Processing steps" now
  has explicit toggles for each step after a recording stops: **Transcribe
  meetings** and **Generate summary & action items**. Audio is always saved; you
  can keep audio-only, transcript-only, or the full transcript + summary.
- **Availability gating with notes.** Each toggle is disabled when its
  dependency is missing, with an inline explanation - e.g. transcription is
  unavailable until a whisper model is downloaded, and summary generation is
  unavailable (and noted) when no local Ollama model is selected or no Claude API
  key is set. The summary step also requires transcription to be on.

#### Changed
- Removed the summary engine **"None"** option; turning summaries off now lives
  in the new Processing steps section (existing "None" setups are migrated to the
  toggle automatically).

### [0.23.0] - 2026-06-21

#### Added
- **Recognize speakers (experimental).** Optionally splits the remote side of a
  call into separate speakers - "Them 1", "Them 2", … - instead of a single
  "Them". Runs sherpa-onnx speaker diarization (segmentation + speaker
  embeddings + clustering, all native/offline) on the **system-audio track**
  only; your own mic stays cleanly "You". Whisper's system-track segments are
  relabeled by time overlap with the detected speaker spans. Off by default;
  enable it under Settings → Transcription. The toggle stays disabled until the
  binary + models are installed via `scripts/setup-diarization.sh`. Accuracy
  varies with audio quality and overlapping speech, and it adds processing time.

#### Fixed
- **Map-reduce was triggering too early and hurting coverage.** The char→token
  estimate was off (Cyrillic ≈ 3.4 chars/token), so meetings that fit a single
  pass were being chunked, which dropped content. Raised the threshold to ~90k
  chars (genuinely long meetings only) and enlarged chunks. Also pinned summary
  section headings to English so localized headings don't break section rendering.

### [0.22.0] - 2026-06-20

#### Added
- **Map-reduce summarization for long meetings.** Transcripts over ~40k chars are
  chunked (~24k each), summarized per chunk, then combined into the final summary
  - so coverage stays even on long meetings and smaller models can handle them.
  The model stays loaded between chunks and unloads after the final pass.

### [0.21.4] - 2026-06-20

#### Changed
- **Clear message when Ollama isn't installed/running.** Recording and
  transcription work without Ollama (only the AI summary needs it); if Ollama is
  unreachable, the summary is skipped with an actionable message (install from
  ollama.com + `ollama pull …`, or switch the Summary engine to Claude/None)
  instead of a raw network error.

### [0.21.3] - 2026-06-20

#### Changed
- **Free the summary model after use.** The Ollama request now sends
  `keep_alive: 0`, so the model is unloaded from memory right after summarizing
  instead of staying resident (Ollama's 5-minute default) - less idle RAM/heat
  between meetings.

### [0.21.2] - 2026-06-20

#### Changed
- **Record panel shows which meeting is processing.** During transcription/
  summarization the sidebar panel now displays the meeting's name above the
  progress bar, so it's clear what's being (re)generated.

### [0.21.1] - 2026-06-19

#### Fixed
- **Processing bar showed on the wrong meeting.** While one meeting was
  regenerating, selecting a different meeting also displayed the progress bar.
  The busy state is now scoped to the meeting actually being processed
  (`controller.activeID == meeting.id`).

### [0.21.0] - 2026-06-19

#### Added
- **Hardware-based model recommendations.** Settings now suggests a whisper model
  (Transcription) and a local summary model (Summary) sized to your Mac's RAM -
  e.g. `large-v3` + `qwen2.5:14b` on 32 GB, `large-v3-turbo` + `qwen2.5:7b` on
  16 GB - with the `ollama pull` command to copy. On low-RAM Macs it points to
  Claude for best quality without local memory limits.

### [0.20.2] - 2026-06-19

#### Fixed
- **Prompt improvements had no effect for some users.** A legacy `summaryPrompt`
  setting was migrated onto the active model on every launch, silently shadowing
  the (much-improved) built-in prompts - so summaries stayed 2-section/English no
  matter what. Removed the legacy migration and the stale key; per-model prompts
  now come from the baked defaults unless you explicitly edit one in Settings.

### [0.20.1] - 2026-06-19

#### Fixed
- **Summaries dropping "Topics discussed" / writing in the wrong language.** The
  Qwen prompt now forces every heading (including Topics discussed, with 2-5
  sentences per topic) and the summary language is injected explicitly
  (`{{language}}`) - generic "same language" let the model default to English.
  `noteQualityBaseline` bumped to 0.20.1.

### [0.20.0] - 2026-06-19

#### Fixed
- **Summaries only covered the end of long meetings.** Ollama defaults to a tiny
  context window (~2k tokens) and silently truncates the prompt to its end, so
  long transcripts lost their beginning (and key early decisions/action items).
  We now size `num_ctx` to fit the whole transcript. Verified: a 9.4k-token
  meeting that previously dropped the early "token economy / $250 limit" topic
  now surfaces it, with the right action items.

#### Changed
- Strengthened the Qwen summary prompt: cover the whole meeting evenly, preserve
  amounts/limits/dates/owners, keep names exactly as spoken, and never invent
  dates/numbers (only include a deadline if explicitly stated).

### [0.19.0] - 2026-06-19

#### Changed
- **Better processing time estimate.** The "time left" is now an up-front
  estimate from the audio length × a learned per-model rate (self-calibrating),
  shown counting down from the start - and it covers the summary phase too. This
  replaces the 0.18.0 progress-based ETA, which sat near the end during the
  (opaque) summary step.

### [0.18.0] - 2026-06-19

#### Added
- **Live transcription ETA.** During processing the app now shows an estimated
  time remaining (e.g. `~2m 10s left`), extrapolated from progress and refined
  each second - in the record panel and the meeting's processing bar.

### [0.17.2] - 2026-06-19

#### Changed
- **Copy button is now tab-aware.** On the Summary tab it copies just the
  summary, on Transcript it copies the transcript, on Markdown the full note -
  so you can grab the summary text even when in-place selection is awkward.

### [0.17.1] - 2026-06-19

#### Fixed
- **Empty Summary tab regression from 0.17.0.** The new `## Audio` section
  defeated the fallback that surfaces a heading-less summary, so summaries the
  model wrote under `###`/plain text vanished. The fallback now ignores the
  Audio (and Transcript) sections. Also render `####` headings and numbered
  lists in summaries instead of raw Markdown.

### [0.17.0] - 2026-06-19

#### Added
- **Inline audio in Obsidian.** Notes now embed both tracks in an Audio section
  (`![[… .mic.wav]]` / `… .system.wav`), so Obsidian shows playable audio
  players. The app hides this section (it accesses recordings directly).
- **`tags: [meeting]` frontmatter** for Obsidian tag/Dataview queries (alongside
  the existing `type: meeting`).

#### Changed
- `noteQualityBaseline` bumped to `0.17.0` so notes without the audio embeds/tags
  surface the re-generate prompt.

### [0.16.1] - 2026-06-19

#### Changed
- **`noteQualityBaseline` bumped to 0.15.0.** Notes generated before the VAD
  (0.13), paragraph (0.14), and timeline (0.15) improvements now show the
  "Generated with an older version - Re-generate" prompt.

### [0.16.0] - 2026-06-19

#### Added
- **Search** the meetings list by title or content (sidebar search field).

#### Changed
- **Stable ordering by meeting date/time** (from the note's frontmatter) instead
  of file modification time, so re-transcribing a meeting no longer moves it to
  the top of the list.

### [0.15.0] - 2026-06-19

#### Added
- **Transcript timeline.** Each turn/paragraph is now timestamped (`[m:ss]` from
  the meeting start), so you can see when - and who - said something. The app
  shows the times in a left gutter beside the speaker; the markdown note carries
  them inline. Applies to new transcripts and re-generations.

### [0.14.0] - 2026-06-19

#### Changed
- **Readable transcripts.** Long monologues are now broken into paragraphs (on
  speech pauses and at sentence boundaries) instead of one giant block. In the
  app, continuation paragraphs are indented under the speaker. Applies to new
  transcripts and re-generations.

### [0.13.1] - 2026-06-19

#### Fixed
- **Deleting a meeting no longer removes audio another note still uses.** Audio
  tracks are deleted only when no remaining note references that recording -
  preventing data loss when an older duplicate note shared the same audio.

### [0.13.0] - 2026-06-19

#### Added
- **Voice Activity Detection (VAD).** A small Silero VAD model is now bundled and
  used during transcription, plus `--suppress-nst`. This skips non-speech regions
  so whisper no longer hallucinates phrases like "Дякую за перегляд!" on silence,
  and it noticeably improves real transcription quality.
- **Default model is now a dropdown** of downloaded models (like the per-language
  setting), instead of a free-text path field.

#### Fixed
- **Renaming a meeting while recording created a duplicate note.** On finish, the
  recording now updates the (possibly renamed) note by matching its audio link,
  instead of recreating the original filename.

### [0.12.1] - 2026-06-19

#### Fixed
- **Empty Summary tab when the model skipped section headings.** If a summary
  came back as plain text without `## ` headings, the Summary tab showed nothing
  (while the Markdown tab showed the text). That leading content is now surfaced
  as a Summary section so it's always visible.

### [0.12.0] - 2026-06-19

#### Added
- **"Best quality for Ukrainian" preset** (Settings → Transcription → Quick
  setup). One click sets the language to Ukrainian and pins the `large-v3` model
  for it, downloading large-v3 first if it isn't present.

### [0.11.0] - 2026-06-19

#### Added
- **Vocabulary hint for transcription.** A new optional field (Settings →
  Transcription) is passed to whisper as an initial prompt (carried across the
  whole recording) to improve spelling of participant names, product/company
  names, jargon, and to reinforce the spoken language - especially helpful for
  Ukrainian.

### [0.10.0] - 2026-06-19

#### Added
- **Tuned Qwen prompt.** Qwen models (`qwen2.5` / `qwen3`) now get a dedicated
  strict prompt instead of the generic fallback. On messy speech-recognition
  transcripts the generic prompt made Qwen refuse or go chatty; the tuned prompt
  forbids that and enforces the four-section format with unchecked action-item
  boxes.

#### Fixed
- Generic fallback prompt said "three sections" but listed four; corrected to
  four, and hardened against refusals/preamble.

### [0.9.0] - 2026-06-18

#### Added
- **Menu bar item.** A status-bar icon reflects state at a glance (idle /
  recording / processing / meeting-detected) and its menu offers one-click
  Start/Stop, the "meeting detected" nudge, Open window, and Quit - so you can
  control recording even when the main window is closed or behind your call.

### [0.8.0] - 2026-06-18

#### Added
- **"Meeting detected" suggestion.** When another app (Zoom, Teams, Google
  Meet, FaceTime…) starts using your microphone, the record panel shows a
  gentle "Start recording?" nudge with Record / dismiss buttons. Detection uses
  Core Audio (`kAudioDevicePropertyDeviceIsRunningSomewhere`) - no new
  permissions - and **never records on its own**. Toggle in Settings → General
  (on by default).

### [0.7.1] - 2026-06-18

#### Changed
- **Tuned the default Llama prompt.** Replaced the placeholder `llamaPrompt`
  with a proper plain-instruction prompt (fixed "three"→"four" sections, You/Them
  roles, stronger no-preamble and no-invention rules) so Llama-family models
  reliably produce all four sections.

### [0.7.0] - 2026-06-18

#### Added
- **Bundled whisper.cpp** - the app now ships a self-contained, native
  `whisper-cli` inside the bundle (`Contents/Resources/whisper-cli`), so there's
  no longer any need to `brew install whisper-cpp`. Built statically and signed
  by `scripts/build-whisper.sh` (pinned to whisper.cpp v1.8.6); the transcriber
  prefers the bundled binary and only falls back to Homebrew/system paths for
  CLI and dev use.

### [0.6.1] - 2026-06-18

#### Added
- **Website link** (sergb.com) in the About tab, alongside GitHub and LinkedIn.

### [0.6.0] - 2026-06-18

#### Added
- **Model descriptions** under the download picker: size, speed/accuracy, and
  whether each model is multilingual or English-only (`.en`).
- **About tab links** to the project's GitHub and to the author's LinkedIn.

#### Changed
- **Taller summary-prompt editor** (min 300pt) so long prompts are easier to edit.

### [0.5.0] - 2026-06-18

#### Added
- **Per-language model is now a dropdown** of the whisper models you've
  downloaded (scanned from `~/models`), instead of typing a file path. A
  not-downloaded path still shows, marked "(missing)".

#### Changed
- **Settings is now tabbed** - General, Transcription, Summary, and About -
  instead of one long scrolling form.

### [0.4.2] - 2026-06-18

#### Changed
- Language picker limited to **Auto-detect, English, and Ukrainian** (also
  narrows the per-language model override options in Settings to match).

### [0.4.1] - 2026-06-18

#### Fixed
- **Missing summary sections** (e.g. *Topics discussed* not appearing): Ollama
  summarization now runs at `temperature: 0`, so the model deterministically
  emits every required section instead of occasionally dropping one.

### [0.4.0] - 2026-06-18

#### Added
- **Note version stamping**: each meeting note records the app version that
  generated it (`app_version` in the frontmatter).
- **Outdated-note prompts**: when a note was generated by a version older than
  the current quality baseline (`noteQualityBaseline`), the meeting shows a
  "Generated with an older version" banner with a one-click **Re-generate**
  action, and a ✨ marker appears on its row in the list. Bump
  `noteQualityBaseline` in a release whenever generated-note output changes.

### [0.3.2] - 2026-06-18

#### Changed
- **Topics discussed** now renders each topic as a larger, clearly separated
  block - numbered badge, prominent heading, accent bar, and a tinted
  background - so topics stand apart from the summary prose.

### [0.3.1] - 2026-06-18

#### Changed
- Meeting duration is now shown in plain words (e.g. `10 min 10 sec`,
  `1 hr 5 min 0 sec`) instead of a `mm:ss` clock format.

### [0.3.0] - 2026-06-18

#### Added
- **Per-language whisper models**: assign a specific model to a language (e.g.
  `large-v3` for Ukrainian) in Settings. Meetings in that language use the
  assigned model; all others fall back to the default model path.
- **`large-v3`** added to the in-app downloadable model list (full large model,
  alongside `large-v3-turbo`).

### [0.2.0] - 2026-06-18

#### Added
- **Meeting-language picker** on the record panel for better transcription
  quality; whisper is pinned to the chosen language instead of auto-detecting.
- **Topic blocks** in the summary: *Topics discussed* now renders each topic as
  an accent-barred block with a heading and 1-3 paragraphs/bullets.
- **Total meeting duration** stored in the note frontmatter and shown in the
  meetings list and meeting header.
- **State-aware row icons** distinguishing recording, processing, and idle
  meetings.

#### Changed
- Clicking **Record** now creates and selects a new meeting in the list
  immediately, so it's no longer confused with a previously highlighted note.
- Russian removed from the language options.

### [0.1.0] - 2026-06-18

First release of the standalone macOS app.

#### Added
- **Zero-setup capture** of system audio **and** microphone via Core Audio
  process taps - no virtual audio device or Multi-Output Device. The two sides are
  recorded as **separate tracks** (works with Bluetooth output).
- **Local transcription** via `whisper.cpp`, with **automatic language detection**
  using a multilingual model.
- **"You vs. Them" diarization** derived from the separate tracks (no model).
- **AI summary** with four sections - *Short summary*, *Summary*,
  *Topics discussed*, *Action items* - via a local **Ollama** model or the
  **Claude API**, with **per-model prompts**.
- **Meetings library**: sidebar list + tabbed detail (**Summary / Transcript /
  Markdown**), written into your **Obsidian vault**.
- **Rename**, **re-generate**, and **delete** meetings; **copy** a note as Markdown.
- Live **System/Mic level meters**, a determinate **progress bar** + elapsed time,
  and **stop/cancel** processing (cancelled recordings stay re-generatable).
- **In-app whisper model download**; configurable storage folder, model, language,
  and summary engine/prompt.
- App **icon** and a signed **`.dmg`** build with Developer ID + notarization hooks.

---

## Windows app

### [0.2.0] - 2026-06-25

#### Changed
- **Modern Fluent UI.** Adopted the WPF-UI design kit for a native Windows 11
  look - a Mica window with an integrated title bar, Fluent-styled controls,
  accent-colored Record button, card surfaces, and proper typography (replaces the
  plain default WPF chrome). Same layout and features, just much nicer.

### [0.1.1] - 2026-06-25

#### Fixed
- **Microphone capture is now resilient.** If the mic can't start (no device, in
  use, or blocked), the recording no longer aborts - system audio is still captured
  and a clear warning is shown. After a recording, a flat/empty mic track is
  detected and surfaced ("No microphone audio captured - check Windows mic
  permissions…").

#### Added
- **Microphone picker in Settings.** Choose a specific input device (or Default);
  the choice is saved. Helps when the default capture endpoint isn't your mic.

### [0.1.0] - 2026-06-24

#### Added
- **Initial Windows build (beta).** Native .NET 8 / WPF port: WASAPI loopback +
  mic capture as two tracks, whisper.cpp transcription, Ollama/Claude summarization,
  Markdown notes, in-app whisper-model download, self-contained installer + zip.

## Obsidian plugin

### [0.1.0] - 2026-06-12

#### Added
- Record microphone + system audio (via a loopback device) via the Web Audio API, kept as a stereo split (mic left, system right) to preserve speaker separation.
- In-browser resampling to 16 kHz mono WAV via `OfflineAudioContext` (no `ffmpeg`).
- Local transcription by shelling out to a `whisper.cpp` binary (`whisper-cli`).
- Transcript written to a timestamped Markdown note with frontmatter; optional saved audio.
- Settings tab: device pickers, whisper binary/model paths, language, output folders.
- Ribbon icon, status-bar recording indicator, and start/stop/toggle commands.
- Optional AI summary & action items via a local Ollama LLM (opt-in, off by default).