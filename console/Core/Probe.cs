using System.Diagnostics;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace RobloxCDNAutoFix.Core;

public interface ICdnProbe
{
    Task<ProbeResult> TestAsync(string hostname, string ip, CancellationToken cancellation);
}

public sealed class CdnProbe(AutoFixConfig config) : ICdnProbe
{
    public async Task<ProbeResult> TestAsync(string hostname, string ip, CancellationToken cancellation)
    {
        AddressPolicy.Hostname(hostname);
        if (!AddressPolicy.IsPublicV4(ip)) return new(false, false, false, null, 0, 0, 0, 0, "private/reserved/invalid IPv4");
        var watch = Stopwatch.StartNew();
        double tcpMs = 0, tlsMs = 0, ttfbMs = 0;
        var tcp = false;
        var tls = false;
        var stage = "TCP";
        try
        {
            using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            using (var timeout = Deadline(cancellation, config.ConnectTimeoutSeconds)) await socket.ConnectAsync(IPAddress.Parse(ip), 443, timeout.Token);
            tcpMs = watch.Elapsed.TotalMilliseconds;
            tcp = true;
            stage = "TLS";
            await using var network = new NetworkStream(socket, ownsSocket: false);
            await using var secure = new SslStream(network, leaveInnerStreamOpen: false);
            using (var timeout = Deadline(cancellation, config.TlsTimeoutSeconds))
                await secure.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = hostname, ApplicationProtocols = [SslApplicationProtocol.Http11] }, timeout.Token);
            tlsMs = watch.Elapsed.TotalMilliseconds - tcpMs;
            tls = secure.IsAuthenticated && secure.IsEncrypted;
            stage = "HTTPS";
            using var requestDeadline = Deadline(cancellation, config.HttpTimeoutSeconds);
            var request = Encoding.ASCII.GetBytes($"GET / HTTP/1.1\r\nHost: {hostname}\r\nConnection: close\r\nUser-Agent: RobloxCDNAutoFix/2.0\r\nAccept: */*\r\n\r\n");
            await secure.WriteAsync(request, requestDeadline.Token);
            var sentAt = watch.Elapsed.TotalMilliseconds;
            using var headers = new MemoryStream();
            var buffer = new byte[1024];
            while (headers.Length <= 32768)
            {
                var count = await secure.ReadAsync(buffer, requestDeadline.Token);
                if (count == 0) throw new IOException("Incomplete response.");
                if (headers.Length == 0) ttfbMs = watch.Elapsed.TotalMilliseconds - sentAt;
                if (headers.Length + count > 32768) throw new IOException("Response headers exceed 32 KiB.");
                headers.Write(buffer, 0, count);
                var text = Encoding.ASCII.GetString(headers.GetBuffer(), 0, (int)headers.Length);
                var end = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                if (end < 0) continue;
                var firstLine = text.Split("\r\n", 2)[0];
                var match = Regex.Match(firstLine, @"^HTTP/1\.[01] ([0-9]{3})(?: |$)");
                if (!match.Success) throw new IOException("Invalid HTTP status line.");
                var status = int.Parse(match.Groups[1].Value);
                var valid = AcceptResponse(status, tls, text[..end]);
                return new(valid, tcp, tls, status, tcpMs, tlsMs, ttfbMs, watch.Elapsed.TotalMilliseconds, valid ? null : "HTTP status or CDN fingerprint rejected");
            }
            throw new IOException("Response headers exceed 32 KiB.");
        }
        catch (Exception exception) when (exception is IOException or SocketException or System.Security.Authentication.AuthenticationException or OperationCanceledException)
        {
            cancellation.ThrowIfCancellationRequested();
            return new(false, tcp, tls, null, tcpMs, tlsMs, ttfbMs, watch.Elapsed.TotalMilliseconds, stage + ": " + exception.GetType().Name);
        }
    }

    public static bool AcceptResponse(int status, bool tlsValid, string headers) => tlsValid && status is >= 200 and < 500 && status != 429 &&
        Regex.IsMatch(headers, @"(?im)^(?:server:\s*(?:CloudFront|AmazonS3|Akamai|cloudflare|Roblox)|x-amz-cf-[a-z-]+:|x-amz-request-id:|cf-ray:|x-roblox-[a-z-]+:|via:[^\r\n]*cloudfront|x-cache:[^\r\n]*(?:cloudfront|akamai))", RegexOptions.IgnoreCase);

    private static CancellationTokenSource Deadline(CancellationToken cancellation, int seconds)
    {
        var source = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        source.CancelAfter(TimeSpan.FromSeconds(seconds));
        return source;
    }
}
