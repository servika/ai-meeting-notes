using System.Reflection;

namespace MeetingNotes.Core;

/// <summary>
/// App identity and version info for the Windows build. The version is read
/// from the assembly metadata (injected by MSBuild from the VERSION file).
/// </summary>
public static class BuildInfo
{
    public const string Name = "AI Meeting Notes (Windows)";

    /// <summary>
    /// Assembly informational version (e.g. "0.2.0"), sourced from the VERSION
    /// file at build time. Falls back to "0.0.0" if the attribute is absent.
    /// </summary>
    public static string Version { get; } =
        typeof(BuildInfo).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? typeof(BuildInfo).Assembly.GetName().Version?.ToString(3)
        ?? "0.0.0";
}