namespace RobloxCDNAutoFix.Core;

public interface IDiscovery
{
    Task<IReadOnlyList<DnsAnswer>> SystemAsync(string target, CancellationToken cancellation);
    Task<IReadOnlyList<DnsAnswer>> DiscoverAsync(string target, CancellationToken cancellation);
    Task<bool> ConnectivityAsync(string target, CancellationToken cancellation);
}

public sealed class Discovery(AutoFixConfig config, FixLog log) : IDiscovery
{
    public async Task<IReadOnlyList<DnsAnswer>> SystemAsync(string target, CancellationToken cancellation) => await Resolve(new SystemDnsProvider(config.DnsTimeoutSeconds), target, cancellation);
    private async Task<IReadOnlyList<DnsAnswer>> Resolve(ICandidateProvider provider, string target, CancellationToken cancellation)
    {
        try { return await provider.ResolveAsync(target, cancellation); }
        catch (Exception exception) when (exception is IOException or System.Net.Sockets.SocketException or HttpRequestException or OperationCanceledException)
        {
            cancellation.ThrowIfCancellationRequested();
            log.Write("DNS", provider.GetType().Name + ": response unavailable", true);
            return [];
        }
    }
    public async Task<IReadOnlyList<DnsAnswer>> DiscoverAsync(string target, CancellationToken cancellation)
    {
        var providers = new List<ICandidateProvider> { new SystemDnsProvider(config.DnsTimeoutSeconds) };
        providers.AddRange(config.Resolvers.Select(resolver => new PublicDnsProvider(resolver, config.DnsTimeoutSeconds)));
        var results = await Task.WhenAll(providers.Select(provider => Resolve(provider, target, cancellation)));
        return results.SelectMany(result => result).ToArray();
    }
    public async Task<bool> ConnectivityAsync(string target, CancellationToken cancellation)
    {
        var probes = new[] { ("dns.google", "8.8.8.8"), ("cloudflare-dns.com", "1.1.1.1") }.Select(async endpoint =>
        {
            try
            {
                var request = Convert.ToBase64String(DnsWire.Query(target, 1, endpoint.Item1 == "dns.google")).TrimEnd('=').Replace('+', '-').Replace('/', '_');
                var bytes = await LimitedHttp.GetAsync(new Uri($"https://{endpoint.Item1}/dns-query?dns={request}"), System.Net.IPAddress.Parse(endpoint.Item2), 65536, TimeSpan.FromSeconds(config.DnsTimeoutSeconds), cancellation);
                return bytes.Length >= 12 && (bytes[2] & 0x80) != 0;
            }
            catch (Exception exception) when (exception is IOException or HttpRequestException or OperationCanceledException)
            { cancellation.ThrowIfCancellationRequested(); return false; }
        });
        return (await Task.WhenAll(probes)).Any(result => result);
    }
}

public interface IPlayerState : IDisposable { bool WasRunning { get; } }
public interface IRobloxProcessManager
{
    IPlayerState Capture();
    Task RestartAsync(IPlayerState state, CancellationToken cancellation);
}
public sealed record FixResult(bool Success, bool HostsChanged, bool VerificationPassed, int FixedTargets);

public sealed class RepairEngine(AutoFixConfig config, IDiscovery discovery, ICdnProbe probe, IResultCache cache,
    IHostsStore hosts, IRobloxProcessManager player, FixLog log)
{
    public static bool ShouldRestart(bool wasRunning, bool changed, bool verified) => wasRunning && changed && verified;

    public async Task<FixResult> RunAsync(RunMode mode, bool force, CancellationToken cancellation)
    {
        using var state = mode == RunMode.Repair ? player.Capture() : null;
        if (state is not null) log.Write("ROBLOX", state.WasRunning ? "Player обнаружен. Перезапуск только после успешного изменения." : "Player не запущен; перезапуск не требуется.");
        var changed = false;
        var successful = true;
        var fixedTargets = 0;
        if (mode == RunMode.Restore)
        {
            HostsChange? restored = null;
            try
            {
                restored = hosts.Restore();
                changed = restored is not null;
                if (changed) await hosts.FlushAsync(cancellation);
                hosts.Commit();
                log.Write("HOSTS", changed ? "Собственный блок удалён; стандартное разрешение DNS восстановлено." : "Managed block отсутствует; изменений нет.");
                return new(true, changed, true, 0);
            }
            catch
            {
                if (changed)
                {
                    hosts.Rollback(restored!);
                    await hosts.FlushAsync(CancellationToken.None);
                }
                throw;
            }
        }
        try
        {
            foreach (var target in config.Targets)
            {
                cancellation.ThrowIfCancellationRequested();
                log.State(FixState.Checking, target);
                var snapshot = hosts.Read();
                var block = HostsDocument.Parse(snapshot.Text);
                log.Write("HOSTS", target + " override: " + (block.Entries.TryGetValue(target, out var mapped) ? mapped : HostsDocument.HasForeign(snapshot.Text, target) ? "foreign entry" : "none"));
                var currentDns = await discovery.SystemAsync(target, cancellation);
                LogDns(currentDns);
                var current = CandidatePool.Merge(currentDns, config.MaxCandidates);
                await TestAsync(target, current, 1, cancellation);
                var healthy = current.Count > 0 && current.Count == currentDns.Select(answer => answer.Ip).Distinct().Count() && current.All(candidate => candidate.SuccessRate == 1)
                    ? current.OrderBy(candidate => candidate.MedianMs).First() : null;
                if (healthy is not null)
                {
                    await TestAsync(target, [healthy], config.Samples, cancellation);
                    if (!healthy.Stable(config.Samples)) healthy = null;
                }
                if (mode == RunMode.Diagnose)
                {
                    log.State(healthy is null ? FixState.ProblemDetected : FixState.Healthy, target);
                    log.Write("DIAGNOSE", "Fix required: " + (healthy is null ? "YES" : "NO"));
                    successful &= healthy is not null;
                    continue;
                }
                if (healthy is not null && !force && mode != RunMode.DryRun)
                {
                    log.State(FixState.Healthy, target + ": HTTPS стабилен; изменений нет.");
                    continue;
                }
                if (healthy is null) log.State(FixState.ProblemDetected, target);
                if (HostsDocument.HasForeign(snapshot.Text, target))
                {
                    log.State(FixState.Failed, target + ": чужая запись hosts сохранена.");
                    successful = false;
                    continue;
                }
                var ranked = new List<Candidate>();
                var cached = cache.Get(target);
                if (cached is not null && !force && mode != RunMode.DryRun)
                {
                    ranked = CandidatePool.Merge([new DnsAnswer(target, cached.Ip, "cache", null)], 1);
                    await TestAsync(target, ranked, config.Samples, cancellation);
                    ranked = ranked.Where(candidate => candidate.Stable(config.Samples)).ToList();
                    if (ranked.Count == 0) SafeCache(() => cache.Reject(target, cached.Ip));
                    else
                    {
                        var metadata = await cache.GetAwsAsync(cancellation);
                        ranked[0].CloudFront = metadata?.Find(ranked[0].Ip);
                        ranked[0].AwsMetadataStale = metadata?.Stale ?? false;
                    }
                }
                var usedCache = ranked.Count > 0;
                if (ranked.Count == 0) ranked = await DiscoverRankedAsync(target, cached, cancellation);
                if (ranked.Count == 0)
                {
                    log.State(FixState.Failed, target + ": стабильный IP не найден; hosts не изменён.");
                    successful = false;
                    continue;
                }
                var best = ranked[0];
                log.State(FixState.CandidateFound, $"{target} -> {best.Ip}; HTTPS median={best.MedianMs:F1} ms; source={string.Join('+', best.Origins.Select(origin => origin.Source))}; CloudFront={(best.CloudFront is null ? "unverified" : "verified")}");
                if (mode == RunMode.DryRun)
                {
                    log.Write("DRY-RUN", $"Would modify: {target} -> {best.Ip}; hosts не изменён, Roblox не перезапускается.");
                    continue;
                }
                if (healthy is not null && best.MedianMs >= healthy.MedianMs)
                {
                    log.State(FixState.Healthy, "Текущий вариант не хуже выбранного; hosts не изменён.");
                    continue;
                }
                var applied = false;
                for (var attempt = 0; attempt < ranked.Count && attempt < config.MaxApplyAttempts; attempt++)
                {
                    cancellation.ThrowIfCancellationRequested();
                    var candidate = ranked[attempt];
                    HostsChange? transaction = null;
                    try
                    {
                        log.State(FixState.Applying, target + " -> " + candidate.Ip);
                        transaction = hosts.Apply(target, candidate.Ip);
                        if (transaction is null) { applied = true; break; }
                        await hosts.FlushAsync(cancellation);
                        log.Write("DNS", "Cache flushed");
                        log.State(FixState.Verifying, target);
                        var resolved = await discovery.SystemAsync(target, cancellation);
                        if (resolved.Count == 0 || resolved.Any(answer => answer.Ip != candidate.Ip)) throw new IOException("System DNS не использует установленный IP.");
                        await TestAsync(target, [candidate], config.Samples, cancellation);
                        if (!candidate.Stable(config.Samples)) throw new IOException("Final HTTPS verification failed.");
                        hosts.Commit();
                        transaction = null;
                        changed = true;
                        fixedTargets++;
                        applied = true;
                        SafeCache(() => cache.Save(target, candidate));
                        log.State(FixState.Fixed, $"{target} -> {candidate.Ip}; HTTPS median={candidate.MedianMs:F1} ms");
                        break;
                    }
                    catch (Exception exception) when (exception is IOException or OperationCanceledException or UnauthorizedAccessException)
                    {
                        if (transaction is not null)
                        {
                            log.State(FixState.Rollback, target);
                            hosts.Rollback(transaction);
                            await hosts.FlushAsync(CancellationToken.None);
                            using var recoveryTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
                            try
                            {
                                var previous = await discovery.SystemAsync(target, recoveryTimeout.Token);
                                log.Write("VERIFY", "Rollback bytes restored; previous DNS addresses=" + previous.Count);
                                if (previous.FirstOrDefault(answer => AddressPolicy.IsPublicV4(answer.Ip)) is { } prior)
                                {
                                    var restoredProbe = await probe.TestAsync(target, prior.Ip, recoveryTimeout.Token);
                                    log.Write("VERIFY", "Rollback HTTPS=" + restoredProbe.Success);
                                }
                            }
                            catch (Exception recoveryError) when (recoveryError is IOException or OperationCanceledException)
                            { log.Write("VERIFY", "Rollback completed; previous connectivity remains unavailable."); }
                        }
                        SafeCache(() => cache.Reject(target, candidate.Ip));
                        candidate.RejectReason = "Final verification failed";
                        log.Write("REJECT", candidate.Ip + ": " + exception.GetType().Name);
                        cancellation.ThrowIfCancellationRequested();
                        if (usedCache)
                        {
                            usedCache = false;
                            var discovered = await DiscoverRankedAsync(target, null, cancellation);
                            ranked.AddRange(discovered.Where(found => found.Ip != candidate.Ip));
                        }
                    }
                }
                if (!applied) { successful = false; log.State(FixState.Failed, target + ": попытки исчерпаны; предыдущий hosts восстановлен."); }
            }
        }
        finally
        {
            if (mode == RunMode.Repair && state is not null && config.RestartPlayer && ShouldRestart(state.WasRunning, changed, fixedTargets > 0))
            {
                try { await player.RestartAsync(state, CancellationToken.None); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException or InvalidOperationException or System.ComponentModel.Win32Exception or OperationCanceledException)
                { log.Write("ROBLOX", "CDN исправлен, но перезапуск не завершён. Запусти Roblox вручную. " + exception.GetType().Name); }
            }
        }
        return new(successful, changed, fixedTargets > 0, fixedTargets);
    }


    private async Task<List<Candidate>> DiscoverRankedAsync(string target, CachedAddress? cached, CancellationToken cancellation)
    {
        log.State(FixState.Discovering, target);
        var answers = (await discovery.DiscoverAsync(target, cancellation)).ToList();
        LogDns(answers);
        if (!answers.Any(answer => answer.Source != "system_dns") && !await discovery.ConnectivityAsync(target, cancellation))
        {
            log.State(FixState.Failed, "Общая сеть недоступна двум DNS-сервисам. Проверь интернет/VPN/proxy; hosts не изменён.");
            return [];
        }
        if (cached is not null) answers.Add(new DnsAnswer(target, cached.Ip, "cache", null));
        var candidates = CandidatePool.Merge(answers, config.MaxCandidates);
        var ranges = await cache.GetAwsAsync(cancellation);
        var ranked = await RankPoolAsync(target, candidates, ranges, cancellation);
        if (ranked.Count > 0) return ranked;
        if (!config.Fallback.TryGetValue(target, out var fallback)) return [];
        var remaining = config.MaxCandidates - candidates.Count;
        var fallbackPool = CandidatePool.Merge(await new StaticProvider("fallback", fallback).ResolveAsync(target, cancellation), config.MaxCandidates)
            .Where(candidate => candidates.All(tested => tested.Ip != candidate.Ip)).Take(remaining).ToList();
        log.Write("DISCOVERY", "Динамические кандидаты не прошли проверку; emergency fallback.");
        return await RankPoolAsync(target, fallbackPool, ranges, cancellation);
    }

    private async Task<List<Candidate>> RankPoolAsync(string target, List<Candidate> candidates, AwsRanges? ranges, CancellationToken cancellation)
    {
        foreach (var candidate in candidates)
        {
            candidate.CloudFront = ranges?.Find(candidate.Ip);
            candidate.AwsMetadataStale = ranges?.Stale ?? false;
            log.Write("AWS", $"{candidate.Ip} -> {(candidate.CloudFront is null ? "unverified" : candidate.CloudFront.Prefix + " " + candidate.CloudFront.Region)} stale={candidate.AwsMetadataStale}", true);
        }
        log.State(FixState.TestingCandidates, $"{target}: {candidates.Count} кандидатов, workers={config.Concurrency}");
        await TestAsync(target, candidates, 1, cancellation);
        var finalists = candidates.Where(candidate => candidate.SuccessRate == 1).OrderByDescending(candidate => candidate.Score).Take(config.Finalists).ToList();
        await TestAsync(target, finalists, config.Samples, cancellation);
        Report(candidates);
        return finalists.Where(candidate => candidate.Stable(config.Samples)).OrderByDescending(candidate => candidate.Score).ToList();
    }

    private void SafeCache(Action action)
    {
        try { action(); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { log.Write("CACHE", "Не удалось сохранить cache; результат ремонта сохранён."); }
    }
    private void LogDns(IEnumerable<DnsAnswer> answers)
    {
        foreach (var answer in answers) log.Write("DNS", $"{answer.Hostname} -> {answer.Ip}; source={answer.Source}; TTL={answer.Ttl?.ToString() ?? "unknown"}", true);
    }
    private async Task TestAsync(string target, IReadOnlyCollection<Candidate> candidates, int samples, CancellationToken cancellation)
    {
        await Parallel.ForEachAsync(candidates, new ParallelOptions { MaxDegreeOfParallelism = config.Concurrency, CancellationToken = cancellation }, async (candidate, token) =>
        {
            candidate.Probes = [];
            for (var sample = 0; sample < samples; sample++)
            {
                var result = await probe.TestAsync(target, candidate.Ip, token);
                candidate.Probes.Add(result);
                candidate.RejectReason = result.RejectReason;
                log.Write("PROBE", $"{candidate.Ip} TCP={result.Tcp} {result.TcpMs:F1}ms TLS={result.Tls} {result.TlsMs:F1}ms HTTP={result.HttpStatus} TTFB={result.TtfbMs:F1}ms total={result.TotalMs:F1}ms reject={result.RejectReason ?? "none"}", true);
                if (!result.Success) break;
            }
            candidate.Score = Scoring.Calculate(candidate, config.Weights);
        });
    }
    private void Report(IEnumerable<Candidate> candidates)
    {
        log.Write("REPORT", "IP | SOURCES | CF | HTTPS rate | MEDIAN/MIN/MAX ms | SCORE | REJECT", true);
        foreach (var candidate in candidates)
            log.Write("SCORE", $"{candidate.Ip} | {string.Join('+', candidate.Origins.Select(origin => origin.Source))} | {candidate.CloudFront is not null} | {candidate.SuccessRate:P0} | {candidate.MedianMs:F1}/{candidate.MinMs:F1}/{candidate.MaxMs:F1} | {candidate.Score:F1} | {candidate.RejectReason ?? "none"}", true);
    }
}
