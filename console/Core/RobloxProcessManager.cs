using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Win32.SafeHandles;

namespace RobloxCDNAutoFix.Core;

public sealed class RobloxProcessManager(FixLog log) : IRobloxProcessManager
{
    private sealed record CapturedPlayer(int Id, long StartTicks, int Session, string Path, SafeAccessTokenHandle Token) : IDisposable
    {
        public void Dispose() => Token.Dispose();
    }
    private sealed class State : IPlayerState
    {
        public bool WasRunning { get; set; }
        public List<CapturedPlayer> Players { get; } = [];
        public void Dispose() { foreach (var player in Players) player.Dispose(); }
    }

    public IPlayerState Capture()
    {
        var state = new State();
        foreach (var name in new[] { "RobloxPlayerBeta", "RobloxPlayer" })
        {
            foreach (var process in Process.GetProcessesByName(name))
            {
                using (process)
                {
                    state.WasRunning = true;
                    log.Write("ROBLOX", "Player detected: PID " + process.Id, true);
                    SafeAccessTokenHandle? primary = null;
                    try
                    {
                        var path = process.MainModule?.FileName ?? throw new IOException("Player path недоступен.");
                        if (process.SessionId == 0 || !Path.IsPathFullyQualified(path) || path.Contains('"')) throw new IOException("Некорректный Player context.");
                        Program.AssertNoLink(path);
                        if (!OpenProcessToken(process.Handle, 0x000a, out var token)) throw new Win32Exception();
                        using (token)
                        {
                            if (!GetTokenInformation(token, 20, out var elevated, sizeof(int), out _) || elevated != 0)
                                throw new IOException("Автозапуск повышенного Player запрещён.");
                            if (!DuplicateTokenEx(token, 0x02000000, IntPtr.Zero, 2, 1, out primary)) throw new Win32Exception();
                        }
                        state.Players.Add(new CapturedPlayer(process.Id, process.StartTime.ToUniversalTime().Ticks, process.SessionId, path, primary));
                        primary = null;
                    }
                    catch (Exception exception) when (exception is Win32Exception or IOException or InvalidOperationException or UnauthorizedAccessException)
                    { log.Write("ROBLOX", "Не удалось безопасно сохранить Player context; этот процесс не будет закрыт."); }
                    finally { primary?.Dispose(); }
                }
            }
        }
        return state;
    }

    public async Task RestartAsync(IPlayerState captured, CancellationToken cancellation)
    {
        if (captured is not State state || !state.WasRunning) return;
        if (state.Players.Count == 0) throw new IOException("Нет безопасного контекста Player.");
        var failures = 0;
        foreach (var player in state.Players)
        {
            try
            {
                cancellation.ThrowIfCancellationRequested();
                using var process = Process.GetProcessById(player.Id);
                if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != player.StartTicks || process.SessionId != player.Session ||
                    !string.Equals(process.MainModule?.FileName, player.Path, StringComparison.OrdinalIgnoreCase))
                    continue;
                Program.AssertNoLink(player.Path);
                using var fileLock = new FileStream(player.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
                VerifyPublisher(player.Path);
                log.Write("ROBLOX", "Closing Roblox Player...");
                process.CloseMainWindow();
                using (var grace = CancellationTokenSource.CreateLinkedTokenSource(cancellation))
                {
                    grace.CancelAfter(TimeSpan.FromSeconds(5));
                    try { await process.WaitForExitAsync(grace.Token); }
                    catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
                    {
                        if (!process.HasExited) process.Kill(entireProcessTree: false);
                        using var killed = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                        await process.WaitForExitAsync(killed.Token);
                    }
                }
                log.Write("ROBLOX", "Player exited. Starting Roblox Player...");
                StartAsOriginalUser(player);
                log.Write("ROBLOX", "Restart successful; повторный вход в игру может потребоваться.");
            }
            catch (ArgumentException) { log.Write("ROBLOX", "Player уже закрыт пользователем; запуск не требуется.", true); }
            catch (Exception exception) when (exception is IOException or System.Security.Cryptography.CryptographicException or Win32Exception or InvalidOperationException or UnauthorizedAccessException or OperationCanceledException)
            { failures++; log.Write("ROBLOX", "Автоперезапуск не завершён. Запусти Roblox вручную. " + exception.GetType().Name); }
        }
        if (failures > 0) log.Write("ROBLOX", "Ошибка перезапуска не отменяет успешный сетевой Fix.");
    }

    private static void VerifyPublisher(string path)
    {
        var file = new TrustFile { Size = (uint)Marshal.SizeOf<TrustFile>(), Path = path };
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<TrustFile>());
        Marshal.StructureToPtr(file, pointer, false);
        try
        {
            var data = new TrustData { Size = (uint)Marshal.SizeOf<TrustData>(), UiChoice = 2, UnionChoice = 1, File = pointer, ProviderFlags = 0x1000 };
            var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
            if (WinVerifyTrust(new IntPtr(-1), ref action, ref data) != 0) throw new IOException("Подпись Player не прошла проверку.");
            using var certificate = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
            if (!certificate.GetNameInfo(X509NameType.SimpleName, false).Equals("Roblox Corporation", StringComparison.OrdinalIgnoreCase))
                throw new IOException("Неизвестный издатель Player.");
        }
        finally { Marshal.DestroyStructure<TrustFile>(pointer); Marshal.FreeHGlobal(pointer); }
    }

    private static void StartAsOriginalUser(CapturedPlayer player)
    {
        if (!CreateEnvironmentBlock(out var environment, player.Token, false)) throw new Win32Exception();
        try
        {
            var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>(), Desktop = "winsta0\\default" };
            var command = new System.Text.StringBuilder('"' + player.Path + '"');
            var started = CreateProcessAsUser(player.Token, player.Path, command, IntPtr.Zero, IntPtr.Zero, false, 0x400, environment, Path.GetDirectoryName(player.Path)!, ref startup, out var information);
            if (!started && Process.GetCurrentProcess().SessionId == player.Session)
            {
                command = new System.Text.StringBuilder('"' + player.Path + '"');
                started = CreateProcessWithToken(player.Token, 0, player.Path, command, 0x400, environment, Path.GetDirectoryName(player.Path)!, ref startup, out information);
            }
            if (!started) throw new Win32Exception();
            CloseHandle(information.Thread);
            CloseHandle(information.Process);
        }
        finally { DestroyEnvironmentBlock(environment); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct TrustFile { public uint Size; [MarshalAs(UnmanagedType.LPWStr)] public string Path; public IntPtr Handle; public IntPtr Subject; }
    [StructLayout(LayoutKind.Sequential)]
    private struct TrustData { public uint Size; public IntPtr Policy; public IntPtr Sip; public uint UiChoice; public uint RevocationChecks; public uint UnionChoice; public IntPtr File; public uint StateAction; public IntPtr State; public IntPtr Url; public uint ProviderFlags; public uint Context; public IntPtr Signature; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo { public int Size; public string? Reserved; public string? Desktop; public string? Title; public int X; public int Y; public int XSize; public int YSize; public int XChars; public int YChars; public int Fill; public int Flags; public short Show; public short ReservedCount; public IntPtr ReservedBytes; public IntPtr Input; public IntPtr Output; public IntPtr Error; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation { public IntPtr Process; public IntPtr Thread; public int Id; public int ThreadId; }
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out SafeAccessTokenHandle token);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DuplicateTokenEx(SafeAccessTokenHandle token, uint access, IntPtr attributes, int level, int type, out SafeAccessTokenHandle duplicate);
    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(SafeAccessTokenHandle token, int informationClass, out int value, int length, out int returned);
    [DllImport("userenv.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateEnvironmentBlock(out IntPtr environment, SafeAccessTokenHandle token, [MarshalAs(UnmanagedType.Bool)] bool inherit);
    [DllImport("userenv.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyEnvironmentBlock(IntPtr environment);
    [DllImport("advapi32.dll", EntryPoint = "CreateProcessAsUserW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessAsUser(SafeAccessTokenHandle token, string application, System.Text.StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation information);
    [DllImport("advapi32.dll", EntryPoint = "CreateProcessWithTokenW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessWithToken(SafeAccessTokenHandle token, uint logonFlags, string application, System.Text.StringBuilder command, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation information);
    [DllImport("kernel32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("wintrust.dll", ExactSpelling = true)] private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
}
