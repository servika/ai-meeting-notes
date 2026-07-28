using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using MeetingNotes.Audio;
using MeetingNotes.Core;
using Wpf.Ui.Appearance;
using Microsoft.Win32;
using Application = System.Windows.Application;
using Button = System.Windows.Controls.Button;
using Clipboard = System.Windows.Clipboard;
using MessageBox = System.Windows.MessageBox;
using OpenFileDialog = Microsoft.Win32.OpenFileDialog;
using Orientation = System.Windows.Controls.Orientation;
using TextBox = System.Windows.Controls.TextBox;

namespace MeetingNotes.App;

public partial class MainWindow : Wpf.Ui.Controls.FluentWindow
{
    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "MeetingNotes", "settings.json");
    private static readonly string AppVersion = BuildInfo.Version;

    private readonly HttpClient _http = new() { Timeout = Timeout.InfiniteTimeSpan };
    private MeetingRecorder? _recorder;
    private bool _recording;
    private bool _processing;
    private string _audioBase = "";
    private string _outBase = "";
    private DateTime _recordStart;
    private CancellationTokenSource? _processingCts;
    private List<Meeting> _allMeetings = [];

    // Progress / ETA
    private DateTime _processStart;
    private readonly DispatcherTimer _elapsedTimer = new() { Interval = TimeSpan.FromSeconds(1) };

    // Auto-hides the "Settings saved" confirmation bar.
    private DispatcherTimer? _settingsSavedTimer;

    // Audio player
    private AudioPlayer? _player;
    private bool _sliderDragging;
    private string _currentNoteContent = "";

    // Meeting detection
    private readonly MeetingDetector _detector = new();

    // Auto-stop
    private DispatcherTimer? _autoStopTimer;
    private DateTime _lastSound = DateTime.Now;
    private const float SilenceLevel = 0.02f;

    // Update checker
    private readonly UpdateChecker _updateChecker = new();

    // System tray
    private System.Windows.Forms.NotifyIcon? _trayIcon;

    public MainWindow()
    {
        InitializeComponent();
        ModelPicker.ItemsSource = ModelDownloader.Available;
        ModelPicker.SelectedItem = "base";
        VersionLabel.Text = $"v{AppVersion}";

        SpeedPicker.ItemsSource = AudioPlayer.Speeds.Select(s =>
            s == (int)s ? $"{(int)s}×" : $"{s:0.#}×").ToArray();
        SpeedPicker.SelectedIndex = 1; // 1×

        _elapsedTimer.Tick += (_, _) => UpdateElapsedEta();

        PopulateMicDevices();
        LoadSettings();
        ApplyDefaults();
        RefreshMeetings();
        SetupTrayIcon();
        SetupMeetingDetection();

        Loaded += async (_, _) => await CheckForUpdatesAsync();
        Closing += (_, _) =>
        {
            _trayIcon?.Dispose();
            _player?.Dispose();
            _detector.Dispose();
        };

        // Auto-stop on sleep/lock
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.SessionSwitch += OnSessionSwitch;
    }

    // ---- system tray ----

    private void SetupTrayIcon()
    {
        _trayIcon = new System.Windows.Forms.NotifyIcon
        {
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(
                System.Reflection.Assembly.GetExecutingAssembly().Location)
                ?? System.Drawing.SystemIcons.Application,
            Text = "AI Meeting Notes",
            Visible = true,
        };

        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add("Open AI Meeting Notes", null, (_, _) => { Show(); Activate(); });
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        var recordItem = new System.Windows.Forms.ToolStripMenuItem("Start Recording");
        recordItem.Click += (_, _) => Dispatcher.Invoke(() =>
        {
            Show(); Activate();
            if (!_recording && !_processing) StartRecording();
        });
        menu.Items.Add(recordItem);
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => Application.Current.Shutdown());
        _trayIcon.ContextMenuStrip = menu;
        _trayIcon.DoubleClick += (_, _) => Dispatcher.Invoke(() => { Show(); Activate(); });
    }

    private void UpdateTrayIcon()
    {
        if (_trayIcon is null) return;
        _trayIcon.Text = _recording ? "● Recording…"
            : _processing ? $"Processing {_lastProgressPercent}%"
            : "AI Meeting Notes - Ready";
    }

    // ---- meeting detection ----

    private void SetupMeetingDetection()
    {
        _detector.IsBusy = () => _recording || _processing;
        _detector.IsEnabled = () => DetectMeetingsCheck.IsChecked == true;
        _detector.MeetingDetected += () => Dispatcher.Invoke(() =>
        {
            DetectedBanner.Visibility = Visibility.Visible;
            ShowToast("Meeting detected", "Another app is using your microphone. Start recording?");
        });
        _detector.Start();
    }

    private void OnDetectedRecordClick(object sender, RoutedEventArgs e)
    {
        _detector.Clear();
        DetectedBanner.Visibility = Visibility.Collapsed;
        if (!_recording && !_processing) StartRecording();
    }

    // ---- auto-stop ----

    private void StartAutoStopWatchdog()
    {
        _lastSound = DateTime.Now;
        _autoStopTimer?.Stop();
        _autoStopTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        _autoStopTimer.Tick += (_, _) => AutoStopTick();
        _autoStopTimer.Start();
    }

    private void StopAutoStopWatchdog()
    {
        _autoStopTimer?.Stop();
        _autoStopTimer = null;
    }

    private void AutoStopTick()
    {
        if (!_recording || AutoStopCheck.IsChecked != true) return;
        var now = DateTime.Now;
        if (Math.Max(SystemLevel.Value, MicLevel.Value) > SilenceLevel)
            _lastSound = now;

        if ((now - _recordStart).TotalHours >= 4)
        {
            AutoStop("4-hour limit reached");
            return;
        }

        if (!int.TryParse(AutoStopMinutesBox.Text, out var mins)) mins = 5;
        if ((now - _lastSound).TotalMinutes >= Math.Max(1, mins))
            AutoStop($"silent for {mins} minutes");
    }

    private async void AutoStop(string reason)
    {
        if (!_recording) return;
        StatusText.Text = $"Auto-stopped ({reason}). Processing…";
        ShowToast("Recording auto-stopped", reason);
        await StopAndProcessAsync();
    }

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend && _recording && AutoStopCheck.IsChecked == true)
            Dispatcher.Invoke(() => AutoStop("system going to sleep"));
    }

    private void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionLock && _recording && AutoStopCheck.IsChecked == true)
            Dispatcher.Invoke(() => AutoStop("screen locked"));
    }

    // ---- update checker ----

    private async Task CheckForUpdatesAsync()
    {
        await _updateChecker.CheckIfDueAsync(_http);
        if (_updateChecker.UpdateAvailable)
        {
            UpdateText.Text = $"Version {_updateChecker.LatestVersion} is available.";
            UpdateBanner.Visibility = Visibility.Visible;
        }
    }

    private void OnDismissUpdate(object sender, RoutedEventArgs e)
        => UpdateBanner.Visibility = Visibility.Collapsed;

    private void OnDownloadUpdate(object sender, RoutedEventArgs e)
    {
        if (_updateChecker.ReleaseUrl is { } url)
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
    }

    // ---- toast notifications ----

    private void ShowToast(string title, string message)
    {
        _trayIcon?.ShowBalloonTip(5000, title, message, System.Windows.Forms.ToolTipIcon.Info);
    }

    // ---- browse dialogs ----

    private void PopulateMicDevices()
    {
        var devices = new List<Audio.InputDevice> { new("", "Default microphone") };
        try { devices.AddRange(MeetingRecorder.InputDevices()); } catch { }
        MicPicker.ItemsSource = devices;
        MicPicker.SelectedValue = "";
    }

    private void ApplyDefaults()
    {
        if (string.IsNullOrWhiteSpace(WhisperBox.Text))
            WhisperBox.Text = ModelDownloader.ResolveWhisperCli();
        if (string.IsNullOrWhiteSpace(ModelBox.Text))
        {
            var installed = ModelDownloader.Available.FirstOrDefault(ModelDownloader.IsInstalled);
            if (installed is not null) ModelBox.Text = ModelDownloader.ModelPath(installed);
        }
    }

    private void OnBrowseVault(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog { Title = "Choose your notes folder" };
        if (dlg.ShowDialog() == true) { VaultBox.Text = dlg.FolderName; RefreshMeetings(); }
    }

    private void OnBrowseModel(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog { Filter = "Whisper model (*.bin)|*.bin|All files|*.*" };
        if (dlg.ShowDialog() == true) ModelBox.Text = dlg.FileName;
    }

    private void OnBrowseWhisper(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog { Filter = "whisper-cli (*.exe)|*.exe|All files|*.*" };
        if (dlg.ShowDialog() == true) WhisperBox.Text = dlg.FileName;
    }

    // ---- model download ----

    private async void OnDownloadModel(object sender, RoutedEventArgs e)
    {
        if (ModelPicker.SelectedItem is not string model) return;
        if (ModelDownloader.IsInstalled(model))
        {
            ModelBox.Text = ModelDownloader.ModelPath(model);
            StatusText.Text = $"{model} already downloaded.";
            return;
        }
        DownloadButton.IsEnabled = false;
        StatusText.Text = $"Downloading {model}…";
        var progress = new Progress<double>(p => DownloadProgress.Value = p);
        try
        {
            var path = await new ModelDownloader(_http).DownloadAsync(model, progress);
            ModelBox.Text = path;
            StatusText.Text = $"Downloaded {Path.GetFileName(path)}.";
        }
        catch (Exception ex) { StatusText.Text = "Download failed: " + ex.Message; }
        finally { DownloadButton.IsEnabled = true; DownloadProgress.Value = 0; }
    }

    // ---- recording ----

    private async void OnRecordClick(object sender, RoutedEventArgs e)
    {
        if (!_recording) { StartRecording(); return; }
        await StopAndProcessAsync();
    }

    private void StartRecording()
    {
        if (string.IsNullOrWhiteSpace(VaultBox.Text))
        {
            StatusText.Text = "Choose a notes folder first (Settings → Notes folder).";
            return;
        }

        _detector.Clear();
        DetectedBanner.Visibility = Visibility.Collapsed;

        var name = "Meeting " + DateTime.Now.ToString("yyyy-MM-dd HH-mm-ss");
        _recordStart = DateTime.Now;
        _audioBase = "recordings/" + name;
        _outBase = Path.Combine(VaultBox.Text, "recordings", name);
        Directory.CreateDirectory(Path.GetDirectoryName(_outBase)!);

        _recorder = new MeetingRecorder();
        _recorder.OnLevel += (sys, mic) => Dispatcher.Invoke(() =>
        {
            SystemLevel.Value = sys;
            MicLevel.Value = mic;
        });
        try
        {
            var micId = MicPicker.SelectedValue as string;
            _recorder.Start(_outBase, string.IsNullOrEmpty(micId) ? null : micId);
        }
        catch (Exception ex)
        {
            StatusText.Text = "Couldn't start recording: " + ex.Message;
            _recorder.Dispose();
            _recorder = null;
            return;
        }
        _recording = true;
        RecordButton.Content = "■ Stop & Process";
        StatusText.Text = "Recording…";
        StartAutoStopWatchdog();
        UpdateTrayIcon();
    }

    private async Task StopAndProcessAsync()
    {
        StopAutoStopWatchdog();
        RecordButton.IsEnabled = false;
        StatusText.Text = "Stopping…";
        try
        {
            var result = await _recorder!.StopAsync();
            _recorder.Dispose();
            _recorder = null;
            _recording = false;
            SystemLevel.Value = MicLevel.Value = 0;
            RecordButton.Content = "● Record";
            UpdateTrayIcon();

            var duration = (int)(DateTime.Now - _recordStart).TotalSeconds;
            var title = Path.GetFileName(_outBase);

            await RunPipelineAsync(result.SystemPath, result.MicPath, title, _recordStart,
                _audioBase, duration, result.MicWarning);
        }
        catch (Exception ex)
        {
            // Never let a stop/dispose failure escape onto the async-void caller
            // (process crash) or leave the UI stuck non-recording with a disabled
            // button.
            _recorder?.Dispose();
            _recorder = null;
            _recording = false;
            SystemLevel.Value = MicLevel.Value = 0;
            RecordButton.Content = "● Record";
            RecordButton.IsEnabled = true;
            UpdateTrayIcon();
            StatusText.Text = "Stop failed: " + ex.Message;
        }
    }

    // ---- pipeline (shared by record + re-generate) ----

    private int _lastProgressPercent;

    private async Task RunPipelineAsync(
        string systemWav, string micWav, string title, DateTime date,
        string audioBase, int duration, string? micWarning = null)
    {
        _processing = true;
        _processingCts = new CancellationTokenSource();
        _processStart = DateTime.Now;
        _lastProgressPercent = 0;
        SetProcessingUI(true);
        _elapsedTimer.Start();
        UpdateTrayIcon();

        var progress = new Progress<PipelineProgress>(p =>
        {
            _lastProgressPercent = (int)(p.Fraction * 100);
            ProcessingProgress.Value = _lastProgressPercent;
            ProgressPercent.Text = $"{_lastProgressPercent}%";
            StatusText.Text = p.Status;
            UpdateTrayIcon();
        });

        try
        {
            var store = new MeetingStore(VaultBox.Text);
            var pipeline = new MeetingPipeline(
                new WhisperTranscriber(WhisperBox.Text),
                new Summarizer(_http),
                store);
            var prompt = string.IsNullOrWhiteSpace(PromptBox.Text)
                ? SummaryPrompts.Default
                : PromptBox.Text;
            var opts = new PipelineOptions
            {
                Transcribe = TranscribeCheck.IsChecked == true,
                Summarize = SummarizeCheck.IsChecked == true,
                Language = LanguageBox.Text,
                WhisperModelPath = ModelBox.Text,
                SummaryPrompt = prompt,
                Engine = BuildEngine(),
                AppVersion = AppVersion,
                AudioRetention = AudioRetentionBox.SelectedIndex switch
                {
                    1 => "compressed",
                    2 => "delete",
                    _ => "original",
                },
            };

            var ct = _processingCts.Token;
            var result = await Task.Run(() => pipeline.ProcessAsync(
                systemWav, micWav, title, date, audioBase, duration, 0, opts, ct, progress), ct);

            // Audio retention: compress or delete after successful transcription,
            // then rewrite the note's audio embeds to match - the pipeline wrote the
            // note with .wav links before the final extension was known.
            if (opts.Transcribe && opts.AudioRetention != "original")
            {
                StatusText.Text = "Optimizing audio…";
                await Task.Run(() =>
                {
                    var newExt = AudioCompressor.ApplyRetention(systemWav, micWav, opts.AudioRetention);
                    AudioRetention.RewriteNote(result.NotePath, audioBase, newExt);
                });
            }

            var msg = "Done.";
            if (result.SummaryWarning is not null) msg = "⚠ " + result.SummaryWarning;
            else if (opts.AudioRetention == "compressed") msg += " Audio compressed.";
            else if (opts.AudioRetention == "delete") msg += " Audio removed.";
            if (micWarning is not null) msg += "  ⚠ " + micWarning;
            StatusText.Text = msg;
            ShowToast("Meeting processed", title);
            RefreshMeetings();
            SelectMeetingByTitle(title);
        }
        catch (OperationCanceledException)
        {
            StatusText.Text = "Cancelled.";
        }
        catch (Exception ex)
        {
            StatusText.Text = "Processing failed: " + ex.Message;
        }
        finally
        {
            _processing = false;
            _processingCts?.Dispose();
            _processingCts = null;
            SetProcessingUI(false);
            _elapsedTimer.Stop();
            UpdateTrayIcon();
        }
    }

    private void SetProcessingUI(bool active)
    {
        RecordButton.IsEnabled = !active;
        ProgressPanel.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        if (active)
        {
            // Re-arm the Stop button for every run - OnCancelClick disables it, and
            // without this it would stay greyed out on the second and later runs.
            CancelButton.IsEnabled = true;
            ProcessingProgress.Value = 0;
            ProgressPercent.Text = "0%";
            ProgressElapsed.Text = "0s";
            ProgressEta.Text = "";
            StatusText.Text = "Processing…";
        }
    }

    private void UpdateElapsedEta()
    {
        var elapsed = DateTime.Now - _processStart;
        ProgressElapsed.Text = FormatTime(elapsed.TotalSeconds);

        if (_lastProgressPercent > 5 && _lastProgressPercent < 99)
        {
            var rate = _lastProgressPercent / elapsed.TotalSeconds;
            var remaining = (100 - _lastProgressPercent) / Math.Max(rate, 0.001);
            ProgressEta.Text = remaining > 2 ? $"~{FormatTime(remaining)} left" : "finishing…";
        }
    }

    private static string FormatTime(double seconds)
    {
        var s = Math.Max(0, (int)seconds);
        return s >= 3600 ? $"{s / 3600}:{(s % 3600) / 60:D2}:{s % 60:D2}"
            : s >= 60 ? $"{s / 60}:{s % 60:D2}"
            : $"{s}s";
    }

    private void OnCancelClick(object sender, RoutedEventArgs e)
    {
        _processingCts?.Cancel();
        CancelButton.IsEnabled = false;
        StatusText.Text = "Cancelling…";
    }

    // ---- re-generate ----

    private async void OnRegenerate(object sender, RoutedEventArgs e)
    {
        if (_processing) { StatusText.Text = "Already processing."; return; }
        if (SelectedMeeting() is not { } m) return;

        var content = File.Exists(m.Path) ? File.ReadAllText(m.Path) : "";
        var audioBase = NoteFormat.FrontmatterValue("audio", content) ?? $"recordings/{m.Title}";
        var dir = Path.GetDirectoryName(m.Path)!;

        var (systemPath, micPath) = FindAudioTracks(dir, audioBase);
        if (systemPath is null && micPath is null)
        {
            StatusText.Text = "No audio tracks found - cannot re-generate.";
            return;
        }

        StatusText.Text = $"Re-generating {m.Title}…";
        await RunPipelineAsync(systemPath ?? "", micPath ?? "", m.Title, m.Date, audioBase, m.DurationSeconds);
    }

    // ---- trim recording ----

    private async void OnTrimRecording(object sender, RoutedEventArgs e)
    {
        if (_processing) { StatusText.Text = "Already processing."; return; }
        if (SelectedMeeting() is not { } m) return;

        var content = File.Exists(m.Path) ? File.ReadAllText(m.Path) : "";
        var audioBase = NoteFormat.FrontmatterValue("audio", content) ?? $"recordings/{m.Title}";
        var dir = Path.GetDirectoryName(m.Path)!;
        var (systemPath, micPath) = FindAudioTracks(dir, audioBase);

        if (systemPath is null && micPath is null)
        {
            StatusText.Text = "No audio tracks to trim.";
            return;
        }

        var currentDur = m.DurationSeconds > 0 ? m.DurationSeconds
            : (int)(systemPath is not null ? AudioTrimmer.GetDurationSeconds(systemPath) : 0);
        if (currentDur <= 0) { StatusText.Text = "Cannot determine recording duration."; return; }

        // Don't let the detail-pane player and the trim preview play at once.
        _player?.Pause();
        PlayerPlayPause.Content = "▶";

        var tracks = new List<string>();
        if (systemPath is not null) tracks.Add(systemPath);
        if (micPath is not null) tracks.Add(micPath);

        var win = new TrimWindow(tracks, currentDur) { Owner = this };
        if (win.ShowDialog() != true) return;

        var startSeconds = win.StartSeconds;
        var endSeconds = win.EndSeconds;
        var keepSeconds = (int)Math.Round(endSeconds - startSeconds);
        if (keepSeconds <= 0) return;

        StatusText.Text = $"Trimming to {FormatTime(keepSeconds)}…";
        var ok = true;
        await Task.Run(() =>
        {
            if (systemPath is not null && !AudioTrimmer.TrimWav(systemPath, startSeconds, endSeconds)) ok = false;
            if (micPath is not null && !AudioTrimmer.TrimWav(micPath, startSeconds, endSeconds)) ok = false;
        });

        if (!ok) { StatusText.Text = "Trim failed - recording may be in a compressed format."; return; }

        AudioTrimmer.UpdateFrontmatterDuration(m.Path, keepSeconds);
        StatusText.Text = "Trimmed. Re-generating transcript…";

        var reloadedContent = File.Exists(m.Path) ? File.ReadAllText(m.Path) : "";
        var reAudioBase = NoteFormat.FrontmatterValue("audio", reloadedContent) ?? audioBase;
        await RunPipelineAsync(systemPath ?? "", micPath ?? "", m.Title, m.Date, reAudioBase, keepSeconds);
    }

    /// <summary>Find audio tracks (system + mic) for a meeting, trying WAV then M4A.</summary>
    private static (string? system, string? mic) FindAudioTracks(string dir, string audioBase) =>
        AudioRetention.FindTracks(dir, audioBase);

    // ---- rename ----

    private void OnRename(object sender, RoutedEventArgs e)
    {
        if (SelectedMeeting() is not { } m) return;
        var newName = ShowInputDialog("Rename meeting", "New name:", m.Title);
        if (newName is null || newName.Trim() == m.Title) return;

        var store = new MeetingStore(VaultBox.Text);
        var newPath = store.Rename(m, newName.Trim());
        if (newPath is null) { StatusText.Text = "Rename failed (name conflict or invalid)."; return; }
        StatusText.Text = $"Renamed to {Path.GetFileNameWithoutExtension(newPath)}.";
        RefreshMeetings();
    }

    private static string? ShowInputDialog(string title, string prompt, string defaultValue)
    {
        var dlg = new Window
        {
            Title = title, Width = 400, Height = 180,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize,
        };
        var stack = new StackPanel { Margin = new Thickness(16) };
        stack.Children.Add(new TextBlock { Text = prompt, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) });
        var textBox = new TextBox { Text = defaultValue };
        textBox.SelectAll();
        stack.Children.Add(textBox);
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0),
        };
        var ok = new Button { Content = "OK", Width = 80, IsDefault = true };
        var cancel = new Button { Content = "Cancel", Width = 80, Margin = new Thickness(8, 0, 0, 0), IsCancel = true };
        ok.Click += (_, _) => { dlg.DialogResult = true; dlg.Close(); };
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);
        stack.Children.Add(buttons);
        dlg.Content = stack;
        textBox.Focus();
        return dlg.ShowDialog() == true && !string.IsNullOrWhiteSpace(textBox.Text)
            ? textBox.Text : null;
    }

    // ---- delete ----

    private void OnDelete(object sender, RoutedEventArgs e)
    {
        if (SelectedMeeting() is not { } m) return;
        var result = MessageBox.Show($"Delete \"{m.Title}\" and its audio tracks?",
            "Delete meeting", MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (result != MessageBoxResult.Yes) return;

        _player?.Unload();
        new MeetingStore(VaultBox.Text).Delete(m);
        ClearDetail();
        StatusText.Text = "Deleted.";
        RefreshMeetings();
    }

    // ---- copy ----

    private void OnCopyNote(object sender, RoutedEventArgs e)
    {
        var text = DetailTabs.SelectedIndex switch
        {
            0 => SummaryBox.Text,
            1 => TranscriptBox.Text,
            _ => DetailBox.Text,
        };
        if (string.IsNullOrEmpty(text)) return;
        Clipboard.SetText(text);
        StatusText.Text = DetailTabs.SelectedIndex switch
        {
            0 => "Summary copied.",
            1 => "Transcript copied.",
            _ => "Markdown copied.",
        };
    }

    // ---- search ----

    private void OnSearchChanged(object sender, TextChangedEventArgs e) => ApplySearchFilter();

    private void ApplySearchFilter()
    {
        var query = SearchBox.Text.Trim();
        if (string.IsNullOrEmpty(query))
        {
            MeetingList.ItemsSource = _allMeetings;
            return;
        }
        MeetingList.ItemsSource = _allMeetings
            .Where(m => m.Title.Contains(query, StringComparison.OrdinalIgnoreCase)
                || (File.Exists(m.Path) && File.ReadAllText(m.Path)
                    .Contains(query, StringComparison.OrdinalIgnoreCase)))
            .ToList();
    }

    // ---- meetings list ----

    private SummaryEngine? BuildEngine() => (EngineBox.SelectedItem as ComboBoxItem)?.Content switch
    {
        "Ollama" => new SummaryEngine.Ollama(OllamaUrlBox.Text, OllamaModelBox.Text),
        "Claude" => new SummaryEngine.Claude(ClaudeKeyBox.Password, ClaudeModelBox.Text),
        _ => null,
    };

    private void RefreshMeetings()
    {
        if (string.IsNullOrWhiteSpace(VaultBox.Text)) return;
        _allMeetings = new MeetingStore(VaultBox.Text).List();
        ApplySearchFilter();
    }

    private void SelectMeetingByTitle(string title)
    {
        var list = MeetingList.ItemsSource as IEnumerable<Meeting>;
        var match = list?.FirstOrDefault(m => m.Title == title);
        if (match is not null) MeetingList.SelectedItem = match;
    }

    private Meeting? SelectedMeeting() => MeetingList.SelectedItem as Meeting;

    private void OnMeetingSelected(object sender, SelectionChangedEventArgs e)
    {
        if (MeetingList.SelectedItem is Meeting m && File.Exists(m.Path))
        {
            _currentNoteContent = File.ReadAllText(m.Path);
            DetailContent.Visibility = Visibility.Visible;
            DetailEmpty.Visibility = Visibility.Collapsed;
            DetailTitle.Text = m.Title;
            DetailBox.Text = _currentNoteContent;
            SummaryBox.Text = NoteFormat.ExtractSummary(_currentNoteContent);
            TranscriptBox.Text = NoteFormat.ExtractTranscript(_currentNoteContent);

            // Duration
            DurationLabel.Text = m.DurationSeconds > 0 ? $"Duration: {FormatTime(m.DurationSeconds)}" : "";

            // Outdated version banner
            if (!string.IsNullOrEmpty(m.AppVersion) && m.AppVersion != AppVersion
                && UpdateChecker.IsNewer(AppVersion, m.AppVersion))
            {
                OutdatedText.Text = $"Generated with v{m.AppVersion}. Current app (v{AppVersion}) " +
                    "has improved summary quality. Re-generate to refresh.";
                OutdatedBanner.Visibility = Visibility.Visible;
            }
            else
            {
                OutdatedBanner.Visibility = Visibility.Collapsed;
            }

            LoadAudioPlayer(m);
        }
        else
        {
            ClearDetail();
        }
    }

    private void ClearDetail()
    {
        _currentNoteContent = "";
        DetailBox.Text = "";
        SummaryBox.Text = "";
        TranscriptBox.Text = "";
        DurationLabel.Text = "";
        DetailTitle.Text = "";
        DetailContent.Visibility = Visibility.Collapsed;
        DetailEmpty.Visibility = Visibility.Visible;
        OutdatedBanner.Visibility = Visibility.Collapsed;
        _player?.Unload();
        PlayerPanel.Visibility = Visibility.Collapsed;
    }

    private void OnDetailTabChanged(object sender, SelectionChangedEventArgs e) { }

    private void OnOpenSettings(object sender, RoutedEventArgs e)
    {
        _settingsSavedTimer?.Stop();
        _settingsSavedTimer = null;
        SettingsSavedBar.IsOpen = false;
        SettingsOverlay.Visibility = Visibility.Visible;
    }

    private void OnCloseSettings(object sender, RoutedEventArgs e) =>
        SettingsOverlay.Visibility = Visibility.Collapsed;

    // ---- audio player ----

    private void LoadAudioPlayer(Meeting m)
    {
        _player?.Unload();

        var content = _currentNoteContent;
        var audioBase = NoteFormat.FrontmatterValue("audio", content) ?? $"recordings/{m.Title}";
        var dir = Path.GetDirectoryName(m.Path)!;
        var (sysPath, micPath) = FindAudioTracks(dir, audioBase);

        var tracks = new List<string>();
        if (sysPath is not null) tracks.Add(sysPath);
        if (micPath is not null) tracks.Add(micPath);

        if (tracks.Count == 0)
        {
            PlayerPanel.Visibility = Visibility.Collapsed;
            return;
        }

        _player = new AudioPlayer();
        _player.PositionChanged += () => Dispatcher.Invoke(() =>
        {
            if (!_sliderDragging && _player.IsReady)
            {
                PlayerSlider.Maximum = _player.Duration;
                PlayerSlider.Value = _player.CurrentTime;
                PlayerTime.Text = FormatTime(_player.CurrentTime);
            }
        });
        _player.PlaybackStopped += () => Dispatcher.Invoke(() =>
            PlayerPlayPause.Content = "▶");

        _player.Load(tracks.ToArray());
        if (_player.IsReady)
        {
            PlayerPanel.Visibility = Visibility.Visible;
            PlayerSlider.Maximum = _player.Duration;
            PlayerDuration.Text = FormatTime(_player.Duration);
            PlayerTime.Text = FormatTime(0);
            PlayerPlayPause.Content = "▶";
        }
        else
        {
            PlayerPanel.Visibility = Visibility.Collapsed;
        }
    }

    private void OnPlayerPlayPause(object sender, RoutedEventArgs e)
    {
        if (_player is null || !_player.IsReady) return;
        _player.TogglePlay();
        PlayerPlayPause.Content = _player.IsPlaying ? "⏸" : "▶";
    }

    private void OnPlayerRestart(object sender, RoutedEventArgs e) => _player?.Seek(0);
    private void OnPlayerBack(object sender, RoutedEventArgs e) => _player?.Skip(-15);
    private void OnPlayerForward(object sender, RoutedEventArgs e) => _player?.Skip(15);

    private void OnPlayerSliderChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_player is null || !_player.IsReady) return;
        if (Mouse.LeftButton == System.Windows.Input.MouseButtonState.Pressed)
        {
            _sliderDragging = true;
            _player.Seek(PlayerSlider.Value);
            PlayerTime.Text = FormatTime(PlayerSlider.Value);
        }
        else if (_sliderDragging)
        {
            _sliderDragging = false;
        }
    }

    private void OnSpeedChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_player is null || SpeedPicker.SelectedIndex < 0) return;
        _player.SetSpeed(AudioPlayer.Speeds[SpeedPicker.SelectedIndex]);
    }

    // ---- links ----

    private void OnOpenLink(object sender, System.Windows.Navigation.RequestNavigateEventArgs e)
    {
        System.Diagnostics.Process.Start(
            new System.Diagnostics.ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true });
        e.Handled = true;
    }

    // ---- theme ----

    private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
        => ApplyTheme(ThemeBox.SelectedIndex);

    private static void ApplyTheme(int index)
    {
        var theme = index switch
        {
            1 => ApplicationTheme.Light,
            2 => ApplicationTheme.Dark,
            _ => GetSystemTheme(),
        };
        ApplicationThemeManager.Apply(theme);
    }

    private static ApplicationTheme GetSystemTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var val = key?.GetValue("AppsUseLightTheme");
            if (val is int i) return i == 0 ? ApplicationTheme.Dark : ApplicationTheme.Light;
        }
        catch { }
        return ApplicationTheme.Dark;
    }

    // ---- settings persistence ----

    private sealed record Settings(
        string Vault = "", string Model = "", string Whisper = "", string Language = "auto",
        int Engine = 0, string OllamaUrl = "http://localhost:11434", string OllamaModel = "qwen2.5:7b",
        string ClaudeModel = "claude-opus-4-8", string MicDeviceId = "", int Theme = 0,
        int AudioRetention = 0, bool AutoStop = true, int AutoStopMinutes = 5,
        bool DetectMeetings = true, string CustomPrompt = "");

    private void OnSaveSettings(object sender, RoutedEventArgs e)
    {
        var s = new Settings(
            VaultBox.Text, ModelBox.Text, WhisperBox.Text, LanguageBox.Text,
            EngineBox.SelectedIndex, OllamaUrlBox.Text, OllamaModelBox.Text, ClaudeModelBox.Text,
            (MicPicker.SelectedValue as string) ?? "", ThemeBox.SelectedIndex,
            AudioRetentionBox.SelectedIndex, AutoStopCheck.IsChecked == true,
            int.TryParse(AutoStopMinutesBox.Text, out var m) ? m : 5,
            DetectMeetingsCheck.IsChecked == true, PromptBox.Text);
        Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(s));
        StatusText.Text = "Settings saved.";
        ShowSettingsSaved();
        RefreshMeetings();
    }

    // Green in-pane confirmation that auto-fades after a few seconds, so a save is
    // visible without hunting for the small status line by the level meters.
    private void ShowSettingsSaved()
    {
        SettingsSavedBar.IsOpen = true;
        _settingsSavedTimer?.Stop();
        _settingsSavedTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _settingsSavedTimer.Tick += (_, _) =>
        {
            _settingsSavedTimer?.Stop();
            _settingsSavedTimer = null;
            SettingsSavedBar.IsOpen = false;
        };
        _settingsSavedTimer.Start();
    }

    private void LoadSettings()
    {
        if (!File.Exists(SettingsPath)) return;
        var s = JsonSerializer.Deserialize<Settings>(File.ReadAllText(SettingsPath));
        if (s is null) return;
        VaultBox.Text = s.Vault;
        ModelBox.Text = s.Model;
        WhisperBox.Text = s.Whisper;
        LanguageBox.Text = s.Language;
        EngineBox.SelectedIndex = s.Engine;
        OllamaUrlBox.Text = s.OllamaUrl;
        OllamaModelBox.Text = s.OllamaModel;
        ClaudeModelBox.Text = s.ClaudeModel;
        MicPicker.SelectedValue = s.MicDeviceId;
        if (MicPicker.SelectedValue is null) MicPicker.SelectedValue = "";
        ThemeBox.SelectedIndex = s.Theme;
        ApplyTheme(s.Theme);
        AudioRetentionBox.SelectedIndex = s.AudioRetention;
        AutoStopCheck.IsChecked = s.AutoStop;
        AutoStopMinutesBox.Text = s.AutoStopMinutes.ToString();
        DetectMeetingsCheck.IsChecked = s.DetectMeetings;
        PromptBox.Text = s.CustomPrompt;
    }
}
