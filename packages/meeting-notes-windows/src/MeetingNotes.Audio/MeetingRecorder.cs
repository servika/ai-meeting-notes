using MeetingNotes.Core;
using NAudio.CoreAudioApi;
using NAudio.MediaFoundation;
using NAudio.Wave;

namespace MeetingNotes.Audio;

/// <summary>An input (microphone) device the user can choose.</summary>
public readonly record struct InputDevice(string Id, string Name);

/// <summary>
/// Paths + frame counts for a finished recording's two tracks. <see cref="MicWarning"/>
/// is non-null when the microphone couldn't be captured (failed to start, or stayed
/// silent) - the system-audio track is still saved regardless.
/// </summary>
public readonly record struct CaptureResult(
    string SystemPath, string MicPath, long SystemFrames, long MicFrames, string? MicWarning);

/// <summary>
/// A capture track died mid-recording (device unplugged, endpoint invalidated,
/// format switched by another app). <see cref="Recovered"/> is true when the
/// recorder managed to restart it into the same file without losing the track.
/// </summary>
public readonly record struct CaptureLoss(string Track, string Message, bool Recovered);

/// <summary>
/// Captures the meeting as two separate WAV tracks with zero setup:
/// system audio via WASAPI loopback on the default render endpoint, and the mic
/// via WASAPI capture (default or a chosen input device). The mic is best-effort:
/// if it can't start or stays silent, the system track is still recorded and a
/// warning is surfaced. Tracks are resampled to whisper's 16 kHz mono on Stop().
///
/// Devices can vanish mid-meeting - a Bluetooth headset reconnects, a call app
/// switches the default endpoint, the machine resumes from sleep. WASAPI ends the
/// capture thread when that happens, so the recorder watches for it, tries to
/// restart the track, and reports through <see cref="CaptureLost"/> either way;
/// <see cref="SystemAlive"/>/<see cref="MicAlive"/> let the UI tell "nobody spoke"
/// apart from "nothing is being captured".
/// </summary>
public sealed class MeetingRecorder : IDisposable
{
    // whisper.cpp wants 16 kHz mono 16-bit PCM.
    private static readonly WaveFormat WhisperFormat = new(16000, 16, 1);
    // Peak below this over the whole recording == effectively silent (no mic input).
    private const float SilenceThreshold = 0.001f;
    // How long to wait for a capture's RecordingStopped before giving up on it.
    // A capture whose thread already ended never raises it again, and waiting
    // unconditionally is what used to hang the app on "Stopping…" forever.
    private static readonly TimeSpan StopTimeout = TimeSpan.FromSeconds(5);

    private WasapiLoopbackCapture? _system;
    private WasapiCapture? _mic;
    private WaveFileWriter? _systemWriter;
    private WaveFileWriter? _micWriter;
    private readonly object _writeGate = new();
    private string _systemTemp = "";
    private string _micTemp = "";
    private string _outBase = "";
    private string? _micDeviceId;
    private float _systemLevel;
    private float _micLevel;
    private float _micPeak;       // loudest mic sample seen this session
    private string? _micError;    // set when the mic failed to start
    private volatile bool _systemDead;  // capture ended on its own and couldn't be restarted
    private volatile bool _micDead;
    private volatile bool _stopping;    // Stop requested - an ending capture is expected now
    private long _lastSystemDataTicks;
    private long _lastMicDataTicks;
    private long _systemBytes;
    private long _micBytes;

    /// <summary>Fired per buffer with the latest peak levels (0…1) for (system, mic).</summary>
    public event Action<float, float>? OnLevel;

    /// <summary>Fired when a track dies mid-recording, whether or not it was recovered.</summary>
    public event Action<CaptureLoss>? CaptureLost;

    /// <summary>False once the system-audio capture has died and could not be restarted.</summary>
    public bool SystemAlive => _system is not null && !_systemDead;

    /// <summary>False when there is no mic, or its capture died and could not be restarted.</summary>
    public bool MicAlive => _mic is not null && !_micDead;

    /// <summary>
    /// Seconds since the last buffer arrived from any live capture. A live mic
    /// delivers buffers continuously even in silence, so a growing value means the
    /// device stopped feeding us - a different problem from a quiet meeting.
    /// (Loopback alone can legitimately go quiet when nothing is playing, so this
    /// is only meaningful while a mic capture is alive.)
    /// </summary>
    public double SecondsSinceData
    {
        get
        {
            var latest = Math.Max(
                Interlocked.Read(ref _lastSystemDataTicks), Interlocked.Read(ref _lastMicDataTicks));
            return latest == 0 ? 0 : (DateTime.UtcNow - new DateTime(latest, DateTimeKind.Utc)).TotalSeconds;
        }
    }

    /// <summary>
    /// Audio bytes written to the larger of the two temp tracks. The tracks are held
    /// in the device's own format until Stop, so this - not elapsed time - is what
    /// approaches the WAV format's 4 GiB ceiling; see <see cref="RecordingLimits"/>.
    /// </summary>
    public long MaxTrackBytes =>
        Math.Max(Interlocked.Read(ref _systemBytes), Interlocked.Read(ref _micBytes));

    /// <summary>Active input (microphone) devices, for a settings picker.</summary>
    public static IReadOnlyList<InputDevice> InputDevices()
    {
        var en = new MMDeviceEnumerator();
        var list = new List<InputDevice>();
        foreach (var d in en.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            list.Add(new InputDevice(d.ID, d.FriendlyName));
        return list;
    }

    /// <summary>
    /// Begin capturing to temp files. <paramref name="micDeviceId"/> selects a specific
    /// input device; null/empty uses the system default. A mic that can't start does
    /// not abort the recording - system audio is captured either way.
    /// </summary>
    public void Start(string outBase, string? micDeviceId = null)
    {
        _outBase = outBase;
        _micDeviceId = micDeviceId;
        _systemTemp = Path.GetTempFileName();
        _micTemp = Path.GetTempFileName();
        _micPeak = 0;
        _micError = null;
        _systemBytes = _micBytes = 0;
        _systemDead = _micDead = _stopping = false;
        // Seed from "now" so a device that never delivers a single buffer reads as
        // stalled from the start rather than as a quiet room.
        _lastSystemDataTicks = _lastMicDataTicks = DateTime.UtcNow.Ticks;

        // System audio (loopback) - the critical track. Throws if there's no default
        // render device; that's a genuine error and propagates.
        _system = new WasapiLoopbackCapture();
        _systemWriter = new WaveFileWriter(_systemTemp, _system.WaveFormat);
        WireSystem(_system);
        _system.StartRecording();
        DiagnosticLog.Write($"capture: system started, format {Describe(_system.WaveFormat)}, temp {_systemTemp}");

        // Microphone - best-effort. If it throws (no device, in use, blocked), keep
        // recording system audio and remember the error for the warning on Stop.
        try
        {
            _mic = OpenMic(micDeviceId);
            _micWriter = new WaveFileWriter(_micTemp, _mic.WaveFormat);
            WireMic(_mic);
            _mic.StartRecording();
            DiagnosticLog.Write($"capture: mic started, format {Describe(_mic.WaveFormat)}, temp {_micTemp}");
        }
        catch (Exception ex)
        {
            _micError = ex.Message;
            _micWriter?.Dispose(); _micWriter = null;
            _mic?.Dispose(); _mic = null;
            DiagnosticLog.Exception("capture: mic failed to start", ex);
        }
    }

    private static WasapiCapture OpenMic(string? micDeviceId) =>
        string.IsNullOrEmpty(micDeviceId)
            ? new WasapiCapture()
            : new WasapiCapture(new MMDeviceEnumerator().GetDevice(micDeviceId));

    private void WireSystem(WasapiLoopbackCapture capture)
    {
        capture.DataAvailable += (_, e) =>
        {
            Interlocked.Exchange(ref _lastSystemDataTicks, DateTime.UtcNow.Ticks);
            lock (_writeGate)
            {
                if (_systemWriter is null) return;   // a late buffer after Stop
                _systemWriter.Write(e.Buffer, 0, e.BytesRecorded);
                Interlocked.Add(ref _systemBytes, e.BytesRecorded);
            }
            _systemLevel = PeakLevel(e.Buffer, e.BytesRecorded, capture.WaveFormat);
            OnLevel?.Invoke(_systemLevel, _micLevel);
        };
        capture.RecordingStopped += (_, e) => OnCaptureStopped("system", capture, e.Exception);
    }

    private void WireMic(WasapiCapture capture)
    {
        capture.DataAvailable += (_, e) =>
        {
            Interlocked.Exchange(ref _lastMicDataTicks, DateTime.UtcNow.Ticks);
            lock (_writeGate)
            {
                if (_micWriter is null) return;
                _micWriter.Write(e.Buffer, 0, e.BytesRecorded);
                Interlocked.Add(ref _micBytes, e.BytesRecorded);
            }
            _micLevel = PeakLevel(e.Buffer, e.BytesRecorded, capture.WaveFormat);
            if (_micLevel > _micPeak) _micPeak = _micLevel;
            OnLevel?.Invoke(_systemLevel, _micLevel);
        };
        capture.RecordingStopped += (_, e) => OnCaptureStopped("mic", capture, e.Exception);
    }

    /// <summary>
    /// A capture thread ended. During Stop that's expected; mid-recording it means
    /// the device went away, so try exactly one restart into the same writer (only
    /// possible when the new endpoint's format matches what the WAV already holds)
    /// and report the outcome either way.
    /// </summary>
    private void OnCaptureStopped(string track, IWaveIn who, Exception? error)
    {
        if (_stopping) return;
        // Ignore an old instance's event arriving after we already replaced it.
        if (track == "system" ? !ReferenceEquals(who, _system) : !ReferenceEquals(who, _mic)) return;

        var cause = error?.Message ?? "device stopped delivering audio";
        DiagnosticLog.Write($"capture: {track} stopped mid-recording ({cause}) - attempting restart");

        var recovered = false;
        try { recovered = track == "system" ? RestartSystem() : RestartMic(); }
        catch (Exception ex) { DiagnosticLog.Exception($"capture: {track} restart", ex); }

        if (!recovered)
        {
            if (track == "system") _systemDead = true; else _micDead = true;
        }
        DiagnosticLog.Write($"capture: {track} restart {(recovered ? "succeeded" : "failed")}");

        var message = recovered
            ? $"The {track} audio device dropped out ({cause}) and was reconnected. "
                + "A few seconds may be missing from the recording."
            : $"The {track} audio device stopped ({cause}) and could not be reconnected. "
                + "Stop the recording to keep what was captured so far.";
        CaptureLost?.Invoke(new CaptureLoss(track, message, recovered));
    }

    private bool RestartSystem()
    {
        if (_systemWriter is null) return false;
        var old = _system;
        var fresh = new WasapiLoopbackCapture();
        if (!SameFormat(fresh.WaveFormat, _systemWriter.WaveFormat)) { fresh.Dispose(); return false; }
        _system = fresh;
        WireSystem(fresh);
        fresh.StartRecording();
        TryDispose(old);
        return true;
    }

    private bool RestartMic()
    {
        if (_micWriter is null) return false;
        var old = _mic;
        var fresh = OpenMic(_micDeviceId);
        if (!SameFormat(fresh.WaveFormat, _micWriter.WaveFormat)) { fresh.Dispose(); return false; }
        _mic = fresh;
        WireMic(fresh);
        fresh.StartRecording();
        TryDispose(old);
        return true;
    }

    // A restarted endpoint can only continue writing into the same WAV when it
    // produces byte-identical frames; anything else would corrupt the track.
    private static bool SameFormat(WaveFormat a, WaveFormat b) =>
        a.SampleRate == b.SampleRate && a.Channels == b.Channels
        && a.BitsPerSample == b.BitsPerSample && a.Encoding == b.Encoding;

    /// <summary>
    /// Stop both captures and write the resampled 16 kHz mono tracks. Never blocks
    /// forever: a capture that already died is not waited on, and the resampling
    /// (minutes of CPU for a long meeting) runs off the calling thread.
    /// </summary>
    public async Task<CaptureResult> StopAsync(IProgress<string>? stage = null)
    {
        _stopping = true;
        DiagnosticLog.Write("capture: stopping "
            + $"(system {(SystemAlive ? "alive" : "dead")}, mic {(MicAlive ? "alive" : _mic is null ? "none" : "dead")})");

        stage?.Report("Stopping…");
        await StopAndFlushAsync("system", _system, _systemDead,
            () => { lock (_writeGate) { _systemWriter?.Dispose(); _systemWriter = null; } });
        await StopAndFlushAsync("mic", _mic, _micDead,
            () => { lock (_writeGate) { _micWriter?.Dispose(); _micWriter = null; } });
        _system = null;
        _mic = null;

        var systemOut = _outBase + ".system.wav";
        var micOut = _outBase + ".mic.wav";

        // Resampling reads the whole capture through Media Foundation - well over a
        // minute for a long meeting. On the UI thread that freezes the window on
        // "Stopping…" and Windows paints it as "Not Responding".
        stage?.Report("Converting audio…");
        var systemTemp = _systemTemp;
        var micTemp = _micTemp;
        var (systemFrames, micFrames) = await Task.Run(() =>
        {
            var sys = ResampleSafe(systemTemp, systemOut, "system");
            var mic = ResampleSafe(micTemp, micOut, "mic");
            return (sys, mic);
        });

        TryDelete(_systemTemp);
        TryDelete(_micTemp);

        // Decide whether the mic actually captured anything useful.
        string? micWarning = null;
        if (_micError is not null)
            micWarning = $"Microphone unavailable ({_micError}). Recorded system audio only.";
        else if (micFrames == 0 || _micPeak < SilenceThreshold)
            micWarning = "No microphone audio captured - check Windows mic permissions "
                + "(Settings → Privacy & security → Microphone → \"Let desktop apps access your microphone\"), "
                + "or pick your mic in Settings.";

        DiagnosticLog.Write($"capture: stopped, system {systemFrames} frames, mic {micFrames} frames"
            + (micWarning is null ? "" : $", warning: {micWarning}"));
        return new CaptureResult(systemOut, micOut, systemFrames, micFrames, micWarning);
    }

    /// <summary>
    /// Stop one capture and wait for its buffers to drain. A capture that already
    /// ended on its own will never raise RecordingStopped again, so waiting on it
    /// is skipped; the timeout covers the rest (a wedged driver still lets the user
    /// keep the audio instead of hanging the app).
    /// </summary>
    private static async Task StopAndFlushAsync(string track, IWaveIn? capture, bool alreadyDead, Action disposeWriter)
    {
        if (capture is null) { disposeWriter(); return; }

        if (!alreadyDead)
        {
            var tcs = new TaskCompletionSource();
            void Stopped(object? s, StoppedEventArgs e) => tcs.TrySetResult();
            capture.RecordingStopped += Stopped;
            try
            {
                capture.StopRecording();
                if (await Task.WhenAny(tcs.Task, Task.Delay(StopTimeout)) != tcs.Task)
                    DiagnosticLog.Write($"capture: {track} did not confirm stop within "
                        + $"{StopTimeout.TotalSeconds:0}s - continuing without it");
            }
            catch (Exception ex) { DiagnosticLog.Exception($"capture: {track} StopRecording", ex); }
            finally { capture.RecordingStopped -= Stopped; }
        }

        disposeWriter();
        TryDispose(capture);
    }

    /// <summary>Resample a captured temp WAV to 16 kHz mono 16-bit; returns frame count.</summary>
    private static long Resample(string src, string dst)
    {
        if (!File.Exists(src) || new FileInfo(src).Length == 0) return 0;
        MediaFoundationApi.Startup();
        using var reader = new WaveFileReader(src);
        using var resampler = new MediaFoundationResampler(reader, WhisperFormat) { ResamplerQuality = 60 };
        WaveFileWriter.CreateWaveFile(dst, resampler);
        using var outReader = new WaveFileReader(dst);
        return outReader.SampleCount;
    }

    // One unreadable track (a device that died mid-write, a truncated WAV) must not
    // cost the user the other one - the pipeline handles a missing/zero-frame track.
    private static long ResampleSafe(string src, string dst, string track)
    {
        try
        {
            var bytes = File.Exists(src) ? new FileInfo(src).Length : 0;
            DiagnosticLog.Write($"capture: resampling {track} ({bytes / 1_048_576} MB)");
            return Resample(src, dst);
        }
        catch (Exception ex)
        {
            DiagnosticLog.Exception($"capture: resampling {track}", ex);
            TryDelete(dst);
            return 0;
        }
    }

    /// <summary>Peak amplitude (0…1) of a capture buffer, for VU metering.</summary>
    private static float PeakLevel(byte[] buffer, int bytes, WaveFormat format)
    {
        float peak = 0;
        if (format.Encoding == WaveFormatEncoding.IeeeFloat && format.BitsPerSample == 32)
        {
            for (var i = 0; i + 4 <= bytes; i += 4)
            {
                var sample = Math.Abs(BitConverter.ToSingle(buffer, i));
                if (sample > peak) peak = sample;
            }
        }
        else if (format.BitsPerSample == 16)
        {
            for (var i = 0; i + 2 <= bytes; i += 2)
            {
                var sample = Math.Abs(BitConverter.ToInt16(buffer, i) / 32768f);
                if (sample > peak) peak = sample;
            }
        }
        return Math.Clamp(peak, 0f, 1f);
    }

    private static string Describe(WaveFormat f) =>
        $"{f.SampleRate} Hz, {f.Channels} ch, {f.BitsPerSample}-bit {f.Encoding}";

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { /* best effort */ }
    }

    private static void TryDispose(IDisposable? d)
    {
        try { d?.Dispose(); } catch { /* a dead endpoint can throw on release */ }
    }

    public void Dispose()
    {
        _stopping = true;
        lock (_writeGate)
        {
            _systemWriter?.Dispose(); _systemWriter = null;
            _micWriter?.Dispose(); _micWriter = null;
        }
        TryDispose(_system); _system = null;
        TryDispose(_mic); _mic = null;
    }
}