# Release checklist

Written to be executed by an AI agent (Claude Code or similar) with a terminal on
the target machine, with a human doing only the physical steps that need a real
meeting. Work top to bottom; **stop at the first FAIL** and report it rather than
continuing.

The automated suites cover the note format, the vault bookkeeping, the audio
retention policy, the transcription/summary flows and the trim paths. What they
**cannot** cover is the part that needs real hardware and real permissions: audio
capture, device selection, the tray/menu-bar UI, and the installer. That is what
sections C-E exist for.

---

## A. Automated gates (agent, ~5 min)

Run every command from the repo root. Record the actual numbers - not "looks fine".

```bash
# macOS app: unit + integration
cd packages/meeting-engine && swift test 2>&1 | tail -5

# Windows app: portable suites (also runnable on macOS)
cd packages/meeting-notes-windows
DOTNET_ROLL_FORWARD=Major dotnet test tests/MeetingNotes.Core.Tests/MeetingNotes.Core.Tests.csproj
DOTNET_ROLL_FORWARD=Major dotnet test tests/MeetingNotes.Integration.Tests/MeetingNotes.Integration.Tests.csproj

# Windows-only (Media Foundation): must be run on Windows or read from CI
dotnet test tests/MeetingNotes.Audio.Tests/MeetingNotes.Audio.Tests.csproj
```

| Check | Pass criteria |
|---|---|
| macOS suite | 0 failures |
| Windows Core + Integration | 0 failures |
| Windows Audio suite | 0 failures (from the Windows CI run if not on Windows) |
| CI | The `Build` and `Windows app` workflows are green on the release commit |
| `VERSION` files | Bumped, and the top CHANGELOG entry matches the version being shipped |
| Note format | `NOTE-FORMAT.md` still matches `NoteFormat.BuildNote` / `RecordingController.buildNote` if either changed |

**Coverage spot-check** (agent, when logic changed):

```bash
cd packages/meeting-notes-windows && DOTNET_ROLL_FORWARD=Major \
  dotnet test tests/MeetingNotes.Core.Tests/MeetingNotes.Core.Tests.csproj --collect:"XPlat Code Coverage"
cd packages/meeting-engine && swift test --enable-code-coverage
```

Every new or changed non-UI function should be exercised by a test. If coverage
for a changed file dropped, add tests before shipping.

---

## B. Data-safety regression (agent, ~2 min)

The recording is the one artifact the app can never re-create. These flows have
destroyed audio before, so verify them explicitly on a **scratch vault**:

```bash
cd packages/meeting-notes-windows
DOTNET_ROLL_FORWARD=Major dotnet test tests/MeetingNotes.Integration.Tests/MeetingNotes.Integration.Tests.csproj \
  --filter "RetentionFlowTests"
cd ../meeting-engine && swift test --filter 'MeetingFlowTests|AudioRetentionTests|TrimTests'
```

| Flow | Expected |
|---|---|
| Compress → re-generate | Both `.m4a` tracks still exist afterwards |
| Compress → trim → re-generate | Tracks exist, `duration:` updated |
| Compress twice | Files unchanged in size |
| Retention = delete | Audio gone **and** the note says so, transcript intact |
| Failed encode | Original `.wav` kept, note still links `.wav` |
| Failed transcription | Note **unchanged**, audio untouched |

---

## C. macOS smoke test (human + agent, ~15 min)

Needs a real meeting (a 2-minute call with anyone, or a video playing plus talking
into the mic). Use a scratch vault, not the real one.

1. **Fresh-install path** - move `~/Library/Preferences/<app>.plist` aside (agent can
   do this) and launch the built `.app`. Expect: onboarding asks for a vault, mic
   permission, and system-audio permission. *Both* permission prompts must appear.
2. **Record** - start a recording, talk, play audio from another app, stop.
   - Level meters move for **both** mic and system while talking/playing.
   - The note appears in the list while recording (placeholder).
3. **Result** - after processing: transcript has both `**You:**` and `**Them:**`
   lines, the summary has all four sections, `duration:` roughly matches real time.
4. **Audio in Obsidian** - open the note in Obsidian; both embedded players load.
5. **Re-generate** - click Re-generate; note is rewritten, audio still present.
6. **Trim** - trim to a shorter range, confirm; audio is shortened, duration updated,
   transcript re-generated.
7. **Retention** - set "Compress", record a short meeting: `.wav` becomes `.m4a` and
   the note's embeds point at `.m4a`. Then re-generate that meeting: **audio must
   still exist**.
8. **Auto-stop** - enable auto-stop with 1 minute, record silence, wait; recording
   stops on its own and a notification appears.
9. **Menu bar** - record from the menu bar item; the icon reflects recording and
   processing state.
10. **Rename / delete** - rename a meeting (heading and file follow, audio stays
    linked); delete it (note and audio both go).

## D. Windows smoke test (human + agent, ~15 min)

1. **Installer** - run the built installer on a machine with the previous version
   installed. Expect: old version removed, settings/models/notes preserved, app
   launches configured.
2. **Devices** - the mic dropdown lists real devices; the selected one is used.
3. Repeat **C2-C7 and C10** in the Windows app.
4. **Tray** - minimize to tray, record and stop from the tray menu.
5. **Long path / unicode** - record with a vault under a path containing spaces and
   non-ASCII characters; note and audio are written correctly.

## E. Cross-platform note compatibility (agent, ~2 min)

Both apps must read each other's notes.

- Open a note produced by the macOS app in the Windows app: title, duration,
  summary and transcript all render; Re-generate finds the audio.
- Open a Windows-produced note in the macOS app: same.
- `NoteFormat.FrontmatterValue` on either side reads `audio:`, `duration:`,
  `speakers:`, `app_version:` from the other side's note.

---

## F. Sign-off

Record in the release PR/commit:

- Suite results (counts, not adjectives) and the CI run link.
- Which smoke sections were executed, on what OS versions and hardware.
- Anything skipped, and why.

**Known gaps no test covers** - re-read these each release and decide whether the
change touches them:

- Core Audio process taps / WASAPI loopback capture (needs real devices).
- macOS permission prompts and TCC state.
- Audio device hot-swap mid-recording.
- Obsidian's own rendering of the note.
- The installer and code-signing/notarization output.
