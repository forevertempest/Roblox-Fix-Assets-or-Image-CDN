using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RobloxCDNAutoFix.Core;

public enum FixState { Checking, Healthy, ProblemDetected, Discovering, TestingCandidates, CandidateFound, Applying, Verifying, Fixed, Rollback, Failed }
public enum RunMode { Diagnose, DryRun, Repair, Restore }

public sealed class AutoFixConfig
{
    public int SchemaVersion { get; set; } = 2;
    public string[] Targets { get; set; } = ["tr.rbxcdn.com"];
    public string[] Resolvers { get; set; } = ["cloudflare", "google"];
    public int MaxCandidates { get; set; } = 24;
    public int Concurrency { get; set; } = 4;
    public int Finalists { get; set; } = 5;
    public int Samples { get; set; } = 3;
    public int MaxApplyAttempts { get; set; } = 3;
    public int DnsTimeoutSeconds { get; set; } = 3;
    public int ConnectTimeoutSeconds { get; set; } = 3;
    public int TlsTimeoutSeconds { get; set; } = 5;
    public int HttpTimeoutSeconds { get; set; } = 5;
    public int OperationTimeoutSeconds { get; set; } = 150;
    public int CacheTtlHours { get; set; } = 24;
    public int AwsCacheTtlHours { get; set; } = 24;
    public bool RestartPlayer { get; set; } = true;
    public ScoreWeights Weights { get; set; } = new();
    public Dictionary<string, string[]> Fallback { get; set; } = new()
    {
        ["tr.rbxcdn.com"] = ["3.171.117.54", "3.171.117.73", "3.164.195.121", "18.65.39.105", "2.20.245.170", "18.64.211.78", "18.64.211.88", "18.64.211.103", "18.64.211.77"]
    };
    public static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };

    public void Validate()
    {
        if (SchemaVersion != 2) throw new InvalidDataException("Неизвестная версия config; ожидается schemaVersion=2.");
        if (Targets is null || Targets.Length is < 1 or > 8) throw new InvalidDataException("Нужно от 1 до 8 targets.");
        Targets = Targets.Select(AddressPolicy.Hostname).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if (Resolvers is null || Resolvers.Length is < 1 or > 3 || Resolvers.Any(name => name is not ("google" or "cloudflare" or "quad9")))
            throw new InvalidDataException("Resolvers: google, cloudflare, quad9; максимум три.");
        Resolvers = Resolvers.Distinct().ToArray();
        Check(MaxCandidates, 1, 50, nameof(MaxCandidates));
        Check(Concurrency, 1, 8, nameof(Concurrency));
        Check(Finalists, 1, MaxCandidates, nameof(Finalists));
        Check(Samples, 3, 5, nameof(Samples));
        Check(MaxApplyAttempts, 1, Math.Min(3, Finalists), nameof(MaxApplyAttempts));
        Check(DnsTimeoutSeconds, 1, 10, nameof(DnsTimeoutSeconds));
        Check(ConnectTimeoutSeconds, 1, 10, nameof(ConnectTimeoutSeconds));
        Check(TlsTimeoutSeconds, 1, 15, nameof(TlsTimeoutSeconds));
        Check(HttpTimeoutSeconds, 1, 15, nameof(HttpTimeoutSeconds));
        Check(OperationTimeoutSeconds, 10, 300, nameof(OperationTimeoutSeconds));
        Check(CacheTtlHours, 1, 168, nameof(CacheTtlHours));
        Check(AwsCacheTtlHours, 1, 168, nameof(AwsCacheTtlHours));
        if (Weights is null || Fallback is null || Fallback.Count > 8) throw new InvalidDataException("Некорректная конфигурация.");
        Weights.Validate();
        foreach (var entry in Fallback)
        {
            AddressPolicy.Hostname(entry.Key);
            if (entry.Value is null || entry.Value.Length > 16 || entry.Value.Any(address => !AddressPolicy.IsPublicV4(address)))
                throw new InvalidDataException("Fallback должен содержать не более 16 публичных IPv4 на target.");
        }
        Fallback = Fallback.ToDictionary(entry => AddressPolicy.Hostname(entry.Key), entry => entry.Value, StringComparer.OrdinalIgnoreCase);
    }

    private static void Check(int value, int minimum, int maximum, string name)
    {
        if (value < minimum || value > maximum) throw new InvalidDataException($"{name}: допустимо {minimum}–{maximum}.");
    }
}

public sealed class ScoreWeights
{
    public double Https { get; set; } = 100;
    public double CloudFront { get; set; } = 4;
    public double AdditionalDnsSource { get; set; } = 2;
    public double Cached { get; set; } = 2;
    public double LatencyPer100Ms { get; set; } = 10;
    public double JitterPer100Ms { get; set; } = 3;
    public void Validate()
    {
        foreach (var value in new[] { Https, CloudFront, AdditionalDnsSource, Cached, LatencyPer100Ms, JitterPer100Ms })
            if (!double.IsFinite(value) || value < 0 || value > 1000) throw new InvalidDataException("Вес score вне диапазона 0–1000.");
        if (LatencyPer100Ms <= 0) throw new InvalidDataException("Штраф HTTPS latency должен быть положительным.");
    }
}

public sealed record DnsAnswer(string Hostname, string Ip, string Source, int? Ttl);
public sealed record ProbeResult(bool Success, bool Tcp, bool Tls, int? HttpStatus, double TcpMs, double TlsMs, double TtfbMs, double TotalMs, string? RejectReason);
public sealed record AwsPrefix(string Prefix, string Region);
public sealed class Candidate(string ip)
{
    public string Ip { get; } = ip;
    public string AddressFamily => "IPv4";
    public List<DnsAnswer> Origins { get; } = [];
    public List<ProbeResult> Probes { get; set; } = [];
    public AwsPrefix? CloudFront { get; set; }
    public bool AwsMetadataStale { get; set; }
    public string? RejectReason { get; set; }
    public double Score { get; set; }
    public double SuccessRate => Probes.Count == 0 ? 0 : (double)Probes.Count(probe => probe.Success) / Probes.Count;
    public double MedianMs => Scoring.Median(Probes.Where(probe => probe.Success).Select(probe => probe.TotalMs));
    public double MinMs => Probes.Where(probe => probe.Success).Select(probe => probe.TotalMs).DefaultIfEmpty(double.PositiveInfinity).Min();
    public double MaxMs => Probes.Where(probe => probe.Success).Select(probe => probe.TotalMs).DefaultIfEmpty(double.PositiveInfinity).Max();
    public bool Stable(int samples) => Probes.Count >= samples && Probes.All(probe => probe.Success);
}

public static class AddressPolicy
{
    private static readonly IPNetwork[] Excluded = new[] { "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4" }.Select(IPNetwork.Parse).ToArray();
    public static string Hostname(string hostname)
    {
        if (hostname is null || hostname.Length > 253 || !hostname.EndsWith(".rbxcdn.com", StringComparison.OrdinalIgnoreCase) ||
            !Regex.IsMatch(hostname, @"^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+rbxcdn\.com$", RegexOptions.IgnoreCase))
            throw new InvalidDataException("Target должен быть DNS-именем в зоне *.rbxcdn.com.");
        return hostname.ToLowerInvariant();
    }

    public static bool IsPublicV4(string? text) => IPAddress.TryParse(text, out var address) && address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork &&
        address.ToString() == text && !Excluded.Any(prefix => prefix.Contains(address));

    public static bool InCidr(IPAddress address, string prefix) => IPNetwork.TryParse(prefix, out var network) && network.Contains(address);
}

public static class Scoring
{
    public static double Median(IEnumerable<double> values)
    {
        var sorted = values.Order().ToArray();
        if (sorted.Length == 0) return double.PositiveInfinity;
        var middle = sorted.Length / 2;
        return sorted.Length % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle];
    }
    public static double Calculate(Candidate candidate, ScoreWeights weights)
    {
        if (candidate.SuccessRate < 1 || candidate.Probes.Count == 0) return double.NegativeInfinity;
        var dnsSources = candidate.Origins.Select(origin => origin.Source).Distinct().Count(source => source.EndsWith("dns", StringComparison.Ordinal));
        return weights.Https + (candidate.CloudFront is null ? 0 : weights.CloudFront) + Math.Max(0, dnsSources - 1) * weights.AdditionalDnsSource +
            (candidate.Origins.Any(origin => origin.Source == "cache") ? weights.Cached : 0) -
            candidate.MedianMs / 100 * weights.LatencyPer100Ms - (candidate.MaxMs - candidate.MinMs) / 100 * weights.JitterPer100Ms;
    }
}

public sealed class FixLog(Action<string> output, bool verbose, Action<string>? persist = null)
{
    private readonly object sync = new();
    public void Write(string stage, string message, bool details = false)
    {
        var line = $"[{stage}] {message}";
        lock (sync)
        {
            if (!details || verbose) { try { output(line); } catch (IOException) { } }
            persist?.Invoke(line);
        }
    }
    public void State(FixState state, string target) => Write(state.ToString(), target);
}
