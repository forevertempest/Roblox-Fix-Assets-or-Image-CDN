using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using RobloxCDNAutoFix.Core;

namespace RobloxCDNAutoFix;

internal static partial class Program
{
    private static FileStream LockStaging()
    {
        SecureFiles.Initialize();
        var path = Path.Combine(SecureFiles.Root, "staging.lock");
        AssertNoLink(path);
        if (File.Exists(path)) AssertWindowsProtectedPath(path);
        return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }
    private static AutoFixConfig LoadV2Config(string[] args)
    {
        var index = Array.IndexOf(args, "--config");
        var system = args.Contains("--system-settings", StringComparer.Ordinal);
        if (system && index >= 0) throw new InvalidDataException("SYSTEM cannot use a user config.");
        string? path = system ? Path.Combine(AppContext.BaseDirectory, "autofix-config.json") : null;
        if (index >= 0)
        {
            if (index + 1 >= args.Length) throw new InvalidDataException("--config requires a path.");
            path = Path.GetFullPath(args[index + 1]);
        }
        var config = new AutoFixConfig();
        if (path is not null)
        {
            AssertNoLink(path);
            if (system) AssertWindowsProtectedPath(path);
            using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (input.Length > 65536) throw new InvalidDataException("Config exceeds 64 KiB.");
            config = JsonSerializer.Deserialize<AutoFixConfig>(input, AutoFixConfig.Json) ?? throw new InvalidDataException("Empty config.");
        }
        config.Validate();
        return config;
    }

    private static void ValidateInstalledRuntime()
    {
        var directory = Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
        var root = Path.Combine(WindowsInstallRoot, "versions") + Path.DirectorySeparatorChar;
        if (!directory.StartsWith(root, StringComparison.OrdinalIgnoreCase) ||
            !Guid.TryParseExact(Path.GetFileName(directory), "N", out _))
            throw new UnauthorizedAccessException("SYSTEM runtime must be a protected installed release.");
        AssertWindowsProtectedPath(WindowsInstallRoot);
        AssertWindowsProtectedPath(Path.GetDirectoryName(directory)!);
        AssertWindowsProtectedPath(directory);
        var manifest = JsonSerializer.Deserialize<Dictionary<string, string>>(SecureFiles.Read(Path.Combine(directory, "manifest.json")))
            ?? throw new IOException("Missing manifest.");
        foreach (var name in new[] { "AutoFixV2.exe", "autofix-config.json", "AutoFix.Common.ps1", "Roblox-CDN-Monitor.ps1", "Roblox-CDN-AutoFix.ps1" })
        {
            var path = Path.Combine(directory, name);
            AssertWindowsProtectedPath(path);
            using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (!manifest.TryGetValue(name, out var expected) || !Convert.ToHexString(SHA256.HashData(input)).Equals(expected, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Installed integrity check failed: " + name);
        }
    }

    private static async Task<int> RunV2Async(string[] args)
    {
        var mode = args[0].TrimStart('-') switch
        {
            "diagnose" => RunMode.Diagnose,
            "dry-run" => RunMode.DryRun,
            "restore" => RunMode.Restore,
            _ => RunMode.Repair
        };
        var writable = mode is RunMode.Repair or RunMode.Restore;
        var system = args.Contains("--system-settings", StringComparer.Ordinal);
        if (WindowsIdentity.GetCurrent().IsSystem && !system) throw new UnauthorizedAccessException("SYSTEM requires --system-settings.");
        if (system) ValidateInstalledRuntime();
        var config = LoadV2Config(args);
        if (writable && !IsAdministrator())
        {
            WriteLine("Для изменения hosts нужны права администратора.");
            var elevated = args.ToArray();
            var configIndex = Array.IndexOf(elevated, "--config");
            if (configIndex >= 0) elevated[configIndex + 1] = Path.GetFullPath(elevated[configIndex + 1]);
            return await RelaunchElevatedAsync(elevated.Concat(["--elevated"]).ToArray());
        }
        using var operation = writable ? SecureFiles.Lock() : null;
        var log = new FixLog(Console.WriteLine, args.Contains("--verbose", StringComparer.Ordinal), writable ? SecureFiles.Log : null);
        var hosts = new WindowsHostsStore();
        if (writable) await hosts.RecoverAsync(log);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(Lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(config.OperationTimeoutSeconds));
        ConsoleCancelEventHandler cancel = (_, eventArgs) => { eventArgs.Cancel = true; timeout.Cancel(); };
        Console.CancelKeyPress += cancel;
        try
        {
            var proxy = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("HTTPS_PROXY")) ||
                Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings", "ProxyEnable", 0) is int enabled && enabled != 0;
            if (proxy) log.Write("NETWORK", "Proxy detected. Direct CDN probes bypass proxy; settings are not changed.");
            if (System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces().Any(network => network.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Tunnel))
                log.Write("NETWORK", "Tunnel interface detected; VPN settings are not changed.");
            var engine = new RepairEngine(config, new Discovery(config, log), new CdnProbe(config),
                new ResultCache(config, log, writable), hosts, new RobloxProcessManager(log), log);
            var result = await engine.RunAsync(mode, args.Contains("--force", StringComparer.Ordinal), timeout.Token);
            return result.Success ? 0 : 1;
        }
        finally
        {
            Console.CancelKeyPress -= cancel;
            if (writable) await hosts.RecoverAsync(log);
        }
    }
}
