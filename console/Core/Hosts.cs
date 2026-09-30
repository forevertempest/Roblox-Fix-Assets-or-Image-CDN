using System.Diagnostics;
using System.Net;
using System.Security.AccessControl;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RobloxCDNAutoFix.Core;

public sealed record HostsSnapshot(byte[] Bytes, string Text, Encoding Encoding, string Hash);
public sealed record HostsChange(HostsSnapshot Before, string AfterHash, string Backup);
public sealed record RecoveryRecord(byte[] Before, string BeforeHash, string AfterHash);

public static class HostsDocument
{
    public const string Begin = "# BEGIN ROBLOX-CDN-AUTOFIX";
    public const string End = "# END ROBLOX-CDN-AUTOFIX";
    public sealed record Parsed(Dictionary<string, string> Entries, int Start, int Length);
    public static Parsed Parse(string text)
    {
        var entries = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var start = -1;
        var end = -1;
        var inside = false;
        var expectedEnd = "";
        foreach (Match match in Regex.Matches(text, @"[^\r\n]*(?:\r\n|\n|\r|$)"))
        {
            if (match.Length == 0) continue;
            var line = match.Value.TrimEnd('\r', '\n');
            var offset = match.Index == 0 && line.StartsWith('\uFEFF') ? 1 : 0;
            line = line[offset..];
            if (line is Begin or "# RobloxCDNAutoFix BEGIN")
            {
                if (start >= 0) throw new InvalidDataException("Дублирующий managed block.");
                start = match.Index + offset;
                inside = true;
                expectedEnd = line == Begin ? End : "# RobloxCDNAutoFix END";
                continue;
            }
            if (line is End or "# RobloxCDNAutoFix END")
            {
                if (!inside || line != expectedEnd) throw new InvalidDataException("Повреждён managed block.");
                end = match.Index + match.Length;
                inside = false;
                continue;
            }
            if (!inside) continue;
            var fields = Regex.Split(line.Trim(), @"\s+");
            if (fields.Length != 2 || !IPAddress.TryParse(fields[0], out var address) || address.ToString() != fields[0])
                throw new InvalidDataException("Неизвестная строка внутри managed block; запись запрещена.");
            var hostname = AddressPolicy.Hostname(fields[1]);
            if (!entries.TryAdd(hostname, fields[0])) throw new InvalidDataException("Дубликат target в managed block.");
        }
        if (inside) throw new InvalidDataException("Незавершённый managed block.");
        return new(entries, start, start < 0 ? 0 : end - start);
    }
    public static string Remove(string text)
    {
        var block = Parse(text);
        return block.Start < 0 ? text : text.Remove(block.Start, block.Length);
    }
    public static bool HasForeign(string text, string hostname) => Regex.Split(Remove(text), @"\r\n|\r|\n").Any(line =>
        Regex.Split(line.Split('#', 2)[0].Trim(), @"\s+").Skip(1).Contains(hostname, StringComparer.OrdinalIgnoreCase));
    public static string Update(string text, string hostname, string ip)
    {
        hostname = AddressPolicy.Hostname(hostname);
        if (!AddressPolicy.IsPublicV4(ip)) throw new InvalidDataException("Invalid hosts IP.");
        var block = Parse(text);
        if (HasForeign(text, hostname)) throw new InvalidDataException("Чужая запись target в hosts; автоматическое изменение запрещено.");
        if (block.Entries.TryGetValue(hostname, out var previous) && previous == ip) return text;
        block.Entries[hostname] = ip;
        var newline = text.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : text.Contains('\r') ? "\r" : "\n";
        var replacement = Begin + newline + string.Join(newline, block.Entries.Select(entry => entry.Value + "\t" + entry.Key)) + newline + End;
        if (block.Start >= 0)
        {
            var old = text.Substring(block.Start, block.Length);
            if (old.EndsWith('\n') || old.EndsWith('\r')) replacement += newline;
            return text[..block.Start] + replacement + text[(block.Start + block.Length)..];
        }
        var separator = text.Length > 0 && !text.EndsWith('\n') && !text.EndsWith('\r') && text != "\uFEFF" ? newline : "";
        return text + separator + replacement + newline;
    }
}

public interface IHostsStore
{
    HostsSnapshot Read();
    HostsChange? Apply(string hostname, string ip);
    void Rollback(HostsChange change);
    void Commit();
    HostsChange? Restore();
    Task FlushAsync(CancellationToken cancellation);
}

public sealed class WindowsHostsStore : IHostsStore
{
    private readonly string hostsPath;
    private readonly string dataRoot;
    private readonly string journalPath;
    private readonly Func<CancellationToken, Task>? testFlush;
    public WindowsHostsStore() : this(Path.Combine(Environment.SystemDirectory, "drivers", "etc", "hosts"), SecureFiles.Root, null) { }
    internal WindowsHostsStore(string hostsPath, string dataRoot, Func<CancellationToken, Task>? testFlush)
    {
        this.hostsPath = hostsPath;
        this.dataRoot = dataRoot;
        this.testFlush = testFlush;
        journalPath = Path.Combine(dataRoot, "pending-hosts.json");
    }
    public HostsSnapshot Read()
    {
        var bytes = SecureFiles.Read(hostsPath, 4 * 1024 * 1024);
        Encoding encoding = new UTF8Encoding(false, true);
        string text;
        try { text = encoding.GetString(bytes); }
        catch (DecoderFallbackException) { encoding = Encoding.Latin1; text = encoding.GetString(bytes); }
        if (text.Contains('\0')) throw new InvalidDataException("Неподдерживаемая кодировка hosts.");
        return new(bytes, text, encoding, SecureFiles.Hash(bytes));
    }
    public HostsChange? Apply(string hostname, string ip)
    {
        var before = Read();
        return Write(before, HostsDocument.Update(before.Text, hostname, ip));
    }
    public HostsChange? Restore()
    {
        var before = Read();
        return Write(before, HostsDocument.Remove(before.Text));
    }
    private HostsChange? Write(HostsSnapshot before, string text)
    {
        if (before.Text == text) return null;
        var backup = Path.Combine(dataRoot, "backups", $"hosts_{DateTime.UtcNow:yyyyMMdd_HHmmssfff}_{Guid.NewGuid():N}.bak");
        SecureFiles.Write(backup, before.Bytes);
        if (SecureFiles.Hash(SecureFiles.Read(backup)) != before.Hash) throw new IOException("Backup verification failed.");
        SecureFiles.Write(backup + ".sha256", Encoding.ASCII.GetBytes(before.Hash));
        var after = before.Encoding.GetBytes(text);
        var afterHash = SecureFiles.Hash(after);
        SecureFiles.Write(journalPath, JsonSerializer.SerializeToUtf8Bytes(new RecoveryRecord(before.Bytes, before.Hash, afterHash), AutoFixConfig.Json));
        try { Replace(after, before.Hash); }
        catch
        {
            var actual = Read().Hash;
            if (actual == afterHash) Replace(before.Bytes, afterHash);
            if (Read().Hash == before.Hash) Commit();
            throw;
        }
        return new(before, afterHash, backup);
    }
    private void Replace(byte[] bytes, string expectedHash)
    {
        Program.AssertWindowsProtectedPath(Path.GetDirectoryName(hostsPath)!);
        Program.AssertWindowsProtectedPath(hostsPath);
        var temporary = Path.Combine(Path.GetDirectoryName(hostsPath)!, "RobloxCDNAutoFixV2-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { stream.Write(bytes); stream.Flush(true); }
            new FileInfo(temporary).SetAccessControl(new FileInfo(hostsPath).GetAccessControl());
            if (Read().Hash != expectedHash) throw new IOException("hosts изменён другой программой; запись отменена.");
            File.Replace(temporary, hostsPath, null);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public void Rollback(HostsChange change) { Replace(change.Before.Bytes, change.AfterHash); Commit(); }
    public void Commit() => SecureFiles.Delete(journalPath);
    public async Task RecoverAsync(FixLog log)
    {
        if (!File.Exists(journalPath)) return;
        var record = JsonSerializer.Deserialize<RecoveryRecord>(SecureFiles.Read(journalPath, 8 * 1024 * 1024), AutoFixConfig.Json) ?? throw new IOException("Повреждён журнал восстановления.");
        if (SecureFiles.Hash(record.Before) != record.BeforeHash) throw new IOException("Повреждён snapshot восстановления.");
        var current = Read().Hash;
        if (current == record.AfterHash)
        {
            Replace(record.Before, current);
            await FlushAsync(CancellationToken.None);
            log.Write("Rollback", "Восстановлен hosts после прерванной операции.");
        }
        else if (current != record.BeforeHash) throw new IOException("После прерывания hosts изменён извне. Нужна ручная проверка; backup сохранён.");
        Commit();
    }
    public async Task FlushAsync(CancellationToken cancellation)
    {
        if (testFlush is not null) { await testFlush(cancellation); return; }
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        using var process = Process.Start(new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "ipconfig.exe"))
        { UseShellExecute = false, CreateNoWindow = true, ArgumentList = { "/flushdns" }, RedirectStandardOutput = true, RedirectStandardError = true }) ?? throw new IOException("DNS flush не запущен.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        try { await process.WaitForExitAsync(timeout.Token); }
        catch { if (!process.HasExited) process.Kill(); throw; }
        await Task.WhenAll(output, error);
        if (process.ExitCode != 0) throw new IOException("Не удалось очистить DNS-кэш.");
    }
}
