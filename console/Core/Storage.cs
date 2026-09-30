using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RobloxCDNAutoFix.Core;

public static class SecureFiles
{
    public static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "RobloxCDNAutoFixV2-Secure");
    public static void Initialize()
    {
        Program.EnsureWindowsProtectedDirectory(Root);
        Program.EnsureWindowsProtectedDirectory(Path.Combine(Root, "backups"));
    }
    public static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    public static byte[] Read(string path, int maxBytes = 5 * 1024 * 1024)
    {
        Program.AssertWindowsProtectedPath(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length > maxBytes) throw new InvalidDataException("Файл превышает допустимый размер.");
        using var content = new MemoryStream();
        stream.CopyTo(content);
        return content.ToArray();
    }
    public static void Write(string path, byte[] bytes)
        => WriteContent(path, stream => stream.Write(bytes));
    public static void Copy(string path, Stream input)
        => WriteContent(path, input.CopyTo);
    private static void WriteContent(string path, Action<Stream> writer)
    {
        var directory = Path.GetDirectoryName(path)!;
        Program.AssertWindowsProtectedPath(directory);
        Program.AssertNoLink(path);
        if (File.Exists(path)) Program.AssertWindowsProtectedPath(path);
        var temporary = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                writer(stream);
                stream.Flush(true);
            }
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static void Delete(string path)
    {
        Program.AssertNoLink(path);
        if (!File.Exists(path)) return;
        Program.AssertWindowsProtectedPath(path);
        File.Delete(path);
    }
    public static FileStream Lock()
    {
        Initialize();
        var path = Path.Combine(Root, "operation.lock");
        Program.AssertNoLink(path);
        if (File.Exists(path)) Program.AssertWindowsProtectedPath(path);
        try { return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { throw new IOException("Другая операция AutoFix v2 уже выполняется."); }
    }
    public static void Log(string message)
    {
        try
        {
            var path = Path.Combine(Root, "AutoFixV2.log");
            Program.AssertWindowsProtectedPath(Root);
            Program.AssertNoLink(path);
            if (File.Exists(path)) Program.AssertWindowsProtectedPath(path);
            if (File.Exists(path) && new FileInfo(path).Length >= 1024 * 1024)
            {
                Delete(path + ".1");
                File.Move(path, path + ".1");
            }
            File.AppendAllText(path, $"[{DateTimeOffset.UtcNow:O}] {message}{Environment.NewLine}", new UTF8Encoding(false));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }
}

public sealed record CachedAddress(string Ip, DateTimeOffset VerifiedAt, double LatencyMs);
public sealed record AwsCacheRecord(DateTimeOffset DownloadedAt, string Json);
public interface IResultCache
{
    CachedAddress? Get(string hostname);
    void Save(string hostname, Candidate candidate);
    void Reject(string hostname, string ip);
    Task<AwsRanges?> GetAwsAsync(CancellationToken cancellation);
}

public sealed class ResultCache(AutoFixConfig config, FixLog log, bool writable) : IResultCache
{
    private readonly string goodPath = Path.Combine(SecureFiles.Root, "candidates-v2.json");
    private readonly string awsPath = Path.Combine(SecureFiles.Root, "aws-ip-ranges.json");
    private AwsRanges? loadedAws;
    private bool awsAttempted;
    public static bool Fresh(DateTimeOffset timestamp, int hours, DateTimeOffset now) => timestamp <= now && now - timestamp < TimeSpan.FromHours(hours);

    private T? Read<T>(string path)
    {
        try { return File.Exists(path) ? JsonSerializer.Deserialize<T>(SecureFiles.Read(path), AutoFixConfig.Json) : default; }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException) { log.Write("CACHE", "Повреждённый или недоступный cache проигнорирован.", true); return default; }
    }
    public CachedAddress? Get(string hostname)
    {
        var entries = Read<Dictionary<string, CachedAddress>>(goodPath);
        if (entries is null || !entries.TryGetValue(hostname, out var record) || record is null || !AddressPolicy.IsPublicV4(record.Ip) || !double.IsFinite(record.LatencyMs)) return null;
        if (!Fresh(record.VerifiedAt, config.CacheTtlHours, DateTimeOffset.UtcNow)) { log.Write("CACHE", hostname + ": TTL expired", true); return null; }
        return record;
    }
    public void Save(string hostname, Candidate candidate)
    {
        if (!writable) return;
        var entries = Read<Dictionary<string, CachedAddress>>(goodPath) ?? [];
        entries = entries.Where(entry => config.Targets.Contains(entry.Key)).ToDictionary();
        entries[hostname] = new CachedAddress(candidate.Ip, DateTimeOffset.UtcNow, candidate.MedianMs);
        SecureFiles.Write(goodPath, JsonSerializer.SerializeToUtf8Bytes(entries, AutoFixConfig.Json));
    }
    public void Reject(string hostname, string ip)
    {
        if (!writable) return;
        var entries = Read<Dictionary<string, CachedAddress>>(goodPath);
        if (entries is null || !entries.TryGetValue(hostname, out var cached) || cached is null || cached.Ip != ip) return;
        entries.Remove(hostname);
        SecureFiles.Write(goodPath, JsonSerializer.SerializeToUtf8Bytes(entries, AutoFixConfig.Json));
    }
    public async Task<AwsRanges?> GetAwsAsync(CancellationToken cancellation)
    {
        if (awsAttempted) return loadedAws;
        awsAttempted = true;
        var cached = Read<AwsCacheRecord>(awsPath);
        if (cached is not null)
        {
            try { loadedAws = AwsRanges.Parse(cached.Json); }
            catch (Exception exception) when (exception is JsonException or InvalidDataException or KeyNotFoundException or InvalidOperationException or ArgumentNullException) { cached = null; }
        }
        if (loadedAws is not null && cached is not null && Fresh(cached.DownloadedAt, config.AwsCacheTtlHours, DateTimeOffset.UtcNow)) return loadedAws;
        try
        {
            var bytes = await LimitedHttp.GetAsync(new Uri("https://ip-ranges.amazonaws.com/ip-ranges.json"), null, 5 * 1024 * 1024, TimeSpan.FromSeconds(10), cancellation);
            var json = Encoding.UTF8.GetString(bytes);
            loadedAws = AwsRanges.Parse(json);
            if (writable) SecureFiles.Write(awsPath, JsonSerializer.SerializeToUtf8Bytes(new AwsCacheRecord(DateTimeOffset.UtcNow, json), AutoFixConfig.Json));
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException or InvalidOperationException or OperationCanceledException)
        {
            cancellation.ThrowIfCancellationRequested();
            if (loadedAws is not null) loadedAws.Stale = true;
            log.Write("AWS", loadedAws is null ? "Endpoint недоступен; продолжение без CloudFront metadata." : "Endpoint недоступен; используется устаревшая копия диапазонов.");
        }
        return loadedAws;
    }
}
