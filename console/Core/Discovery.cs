using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RobloxCDNAutoFix.Core;

public interface ICandidateProvider
{
    Task<IReadOnlyList<DnsAnswer>> ResolveAsync(string hostname, CancellationToken cancellation);
}

public sealed class SystemDnsProvider(int timeoutSeconds) : ICandidateProvider
{
    public async Task<IReadOnlyList<DnsAnswer>> ResolveAsync(string hostname, CancellationToken cancellation)
    {
        AddressPolicy.Hostname(hostname);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        var addresses = await Dns.GetHostAddressesAsync(hostname, AddressFamily.InterNetwork, timeout.Token);
        return addresses.Select(address => new DnsAnswer(hostname, address.ToString(), "system_dns", null)).ToArray();
    }
}

public static class LimitedHttp
{
    public static async Task<byte[]> GetAsync(Uri uri, IPAddress? bootstrap, int limit, TimeSpan timeout, CancellationToken cancellation)
    {
        if (uri.Scheme != "https" || uri.Port != 443 || !string.IsNullOrEmpty(uri.UserInfo)) throw new InvalidDataException("Требуется HTTPS endpoint.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(timeout);
        using var handler = new SocketsHttpHandler
        {
            UseProxy = false,
            AllowAutoRedirect = false,
            UseCookies = false,
            ConnectCallback = async (context, token) =>
            {
                if (context.DnsEndPoint.Host != uri.Host || context.DnsEndPoint.Port != 443) throw new IOException("Unexpected endpoint.");
                var addresses = bootstrap is null ? await Dns.GetHostAddressesAsync(uri.Host, AddressFamily.InterNetwork, token) : [bootstrap];
                foreach (var address in addresses.Where(address => AddressPolicy.IsPublicV4(address.ToString())).Take(8))
                {
                    var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                    try
                    {
                        using var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                        connectTimeout.CancelAfter(TimeSpan.FromSeconds(3));
                        await socket.ConnectAsync(address, 443, connectTimeout.Token);
                        return new NetworkStream(socket, ownsSocket: true);
                    }
                    catch { socket.Dispose(); token.ThrowIfCancellationRequested(); }
                }
                throw new IOException("HTTPS endpoint недоступен.");
            }
        };
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        using var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > limit) throw new InvalidDataException("HTTP response слишком большой.");
        await using var input = await response.Content.ReadAsStreamAsync(deadline.Token);
        using var output = new MemoryStream();
        var buffer = new byte[8192];
        int count;
        while ((count = await input.ReadAsync(buffer, deadline.Token)) > 0)
        {
            if (output.Length + count > limit) throw new InvalidDataException("HTTP response слишком большой.");
            output.Write(buffer, 0, count);
        }
        return output.ToArray();
    }
}

public static class DnsWire
{
    public static byte[] Query(string hostname, ushort identifier, bool anonymousSubnet = false)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(hostname, @"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$"))
            throw new InvalidDataException("Invalid DNS question name.");
        using var output = new MemoryStream();
        var header = new byte[12];
        BinaryPrimitives.WriteUInt16BigEndian(header, identifier);
        header[2] = 1;
        header[5] = 1;
        if (anonymousSubnet) header[11] = 1;
        output.Write(header);
        foreach (var label in hostname.Split('.'))
        {
            var bytes = Encoding.ASCII.GetBytes(label);
            output.WriteByte((byte)bytes.Length);
            output.Write(bytes);
        }
        output.Write([0, 0, 1, 0, 1]);
        if (anonymousSubnet) output.Write([0, 0, 41, 4, 208, 0, 0, 0, 0, 0, 8, 0, 8, 0, 4, 0, 1, 0, 0]);
        return output.ToArray();
    }

    public static IReadOnlyList<DnsAnswer> Parse(byte[] bytes, ushort identifier, string hostname, string source)
        => Parse(bytes, identifier, hostname, source, out _);

    public static IReadOnlyList<DnsAnswer> Parse(byte[] bytes, ushort identifier, string hostname, string source, out string? canonical)
    {
        if (bytes.Length < 12 || BinaryPrimitives.ReadUInt16BigEndian(bytes) != identifier || (bytes[2] & 0x80) == 0 ||
            (bytes[2] & 2) != 0 || (bytes[3] & 15) != 0 || BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(4)) != 1)
            throw new InvalidDataException("Некорректный DNS response.");
        var position = 12;
        var question = ReadName(bytes, ref position);
        if (question != hostname || position + 4 > bytes.Length || BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(position)) != 1 || BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(position + 2)) != 1)
            throw new InvalidDataException("DNS question mismatch.");
        position += 4;
        var answers = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(6));
        if (answers > 128) throw new InvalidDataException("Too many DNS answers.");
        var records = new List<(string Name, ushort Type, uint Ttl, string Data)>();
        for (var index = 0; index < answers; index++)
        {
            var name = ReadName(bytes, ref position);
            if (position + 10 > bytes.Length) throw new InvalidDataException("Truncated DNS record.");
            var type = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(position));
            var recordClass = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(position + 2));
            var ttl = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(position + 4));
            var length = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(position + 8));
            position += 10;
            if (position + length > bytes.Length) throw new InvalidDataException("Truncated DNS data.");
            if (recordClass == 1 && type == 1 && length == 4) records.Add((name, type, ttl, new IPAddress(bytes.AsSpan(position, 4)).ToString()));
            if (recordClass == 1 && type == 5)
            {
                var aliasPosition = position;
                var alias = ReadName(bytes, ref aliasPosition);
                if (aliasPosition > position + length) throw new InvalidDataException("Invalid CNAME length.");
                records.Add((name, type, ttl, alias));
            }
            position += length;
        }
        var accepted = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { hostname };
        for (var depth = 0; depth < 16; depth++)
            foreach (var record in records.Where(record => record.Type == 5 && accepted.Contains(record.Name))) accepted.Add(record.Data);
        canonical = records.LastOrDefault(record => record.Type == 5 && accepted.Contains(record.Name)).Data;
        return records.Where(record => record.Type == 1 && accepted.Contains(record.Name))
            .Select(record => new DnsAnswer(hostname, record.Data, source, (int)Math.Min(record.Ttl, int.MaxValue))).ToArray();
    }

    private static string ReadName(byte[] bytes, ref int position)
    {
        var cursor = position;
        var jumped = false;
        var labels = new List<string>();
        for (var depth = 0; depth < 128; depth++)
        {
            if (cursor >= bytes.Length) throw new InvalidDataException("Truncated DNS name.");
            var length = bytes[cursor++];
            if ((length & 0xc0) == 0xc0)
            {
                if (cursor >= bytes.Length) throw new InvalidDataException("Truncated DNS pointer.");
                if (!jumped) position = cursor + 1;
                cursor = ((length & 63) << 8) | bytes[cursor];
                jumped = true;
                continue;
            }
            if (length == 0)
            {
                if (!jumped) position = cursor;
                var name = string.Join('.', labels).ToLowerInvariant();
                if (name.Length > 253) throw new InvalidDataException("DNS name too long.");
                return name;
            }
            if (length > 63 || cursor + length > bytes.Length) throw new InvalidDataException("Invalid DNS label.");
            labels.Add(Encoding.ASCII.GetString(bytes, cursor, length));
            cursor += length;
        }
        throw new InvalidDataException("DNS pointer loop.");
    }
}

public sealed class PublicDnsProvider(string resolver, int timeoutSeconds) : ICandidateProvider
{
    public async Task<IReadOnlyList<DnsAnswer>> ResolveAsync(string hostname, CancellationToken cancellation)
    {
        var (host, address) = resolver switch
        {
            "google" => ("dns.google", "8.8.8.8"),
            "cloudflare" => ("cloudflare-dns.com", "1.1.1.1"),
            "quad9" => ("dns.quad9.net", "9.9.9.9"),
            _ => throw new InvalidDataException("Unknown resolver.")
        };
        AddressPolicy.Hostname(hostname);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        var question = hostname;
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var depth = 0; depth < 8 && visited.Add(question); depth++)
        {
            var identifier = (ushort)RandomNumberGenerator.GetInt32(65536);
            var query = Convert.ToBase64String(DnsWire.Query(question, identifier, resolver == "google")).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            var response = await LimitedHttp.GetAsync(new Uri($"https://{host}/dns-query?dns={query}"), IPAddress.Parse(address), 65536, TimeSpan.FromSeconds(timeoutSeconds), deadline.Token);
            var answers = DnsWire.Parse(response, identifier, question, resolver + "_dns", out var canonical);
            if (answers.Count > 0) return answers.Select(answer => answer with { Hostname = hostname }).ToArray();
            if (canonical is null) return [];
            question = canonical;
        }
        return [];
    }
}

public sealed class StaticProvider(string source, IReadOnlyList<string> addresses) : ICandidateProvider
{
    public Task<IReadOnlyList<DnsAnswer>> ResolveAsync(string hostname, CancellationToken cancellation) =>
        Task.FromResult<IReadOnlyList<DnsAnswer>>(addresses.Select(address => new DnsAnswer(hostname, address, source, null)).ToArray());
}

public static class CandidatePool
{
    public static List<Candidate> Merge(IEnumerable<DnsAnswer> answers, int limit)
    {
        var pool = new Dictionary<string, Candidate>();
        foreach (var answer in answers.OrderBy(answer => answer.Source.EndsWith("dns", StringComparison.Ordinal) ? 0 : answer.Source == "cache" ? 1 : 2))
        {
            if (!AddressPolicy.IsPublicV4(answer.Ip)) continue;
            if (!pool.TryGetValue(answer.Ip, out var candidate)) pool[answer.Ip] = candidate = new Candidate(answer.Ip);
            if (!candidate.Origins.Any(origin => origin.Source == answer.Source)) candidate.Origins.Add(answer);
        }
        return pool.Values.Take(limit).ToList();
    }
}

public sealed class AwsRanges
{
    public string CreateDate { get; init; } = "";
    public string SyncToken { get; init; } = "";
    public bool Stale { get; set; }
    public List<AwsPrefix> Prefixes { get; init; } = [];
    private readonly List<(IPNetwork Network, AwsPrefix Metadata)> networks = [];
    public AwsPrefix? Find(string ip) => IPAddress.TryParse(ip, out var parsed) ? networks.FirstOrDefault(prefix => prefix.Network.Contains(parsed)).Metadata : null;

    public static AwsRanges Parse(string json)
    {
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 16 });
        var root = document.RootElement;
        var result = new AwsRanges { CreateDate = root.GetProperty("createDate").GetString() ?? "", SyncToken = root.GetProperty("syncToken").GetString() ?? "" };
        foreach (var entry in root.GetProperty("prefixes").EnumerateArray())
        {
            if (entry.GetProperty("service").GetString() != "CLOUDFRONT") continue;
            var prefix = entry.GetProperty("ip_prefix").GetString() ?? "";
            var parts = prefix.Split('/');
            if (parts.Length != 2 || !AddressPolicy.IsPublicV4(parts[0]) || !int.TryParse(parts[1], out var bits) || bits is < 8 or > 32 || !IPNetwork.TryParse(prefix, out var network))
                throw new InvalidDataException("Некорректный CloudFront prefix.");
            var metadata = new AwsPrefix(prefix, entry.GetProperty("region").GetString() ?? "");
            result.Prefixes.Add(metadata);
            result.networks.Add((network, metadata));
            if (result.Prefixes.Count > 10000) throw new InvalidDataException("Слишком много AWS prefixes.");
        }
        if (result.Prefixes.Count == 0) throw new InvalidDataException("AWS не вернул CloudFront prefixes.");
        return result;
    }
}
