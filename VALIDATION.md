# AutoFix v2 — Implementation & validation report

**Scope:** separate `version2` project; original v1 sources preserved. Windows x64 validated locally; ARM64 cross-published, not executed on ARM hardware.

**Final machine state:** test monitoring v2 was uninstalled twice successfully; its installed code directory is absent. The original system hosts SHA-256 remained unchanged. Protected test reports/logs were retained, and v1 was not uninstalled or modified.

## 1. Files and modules

| Files | Responsibility |
|---|---|
| `console/Program.cs` | Existing menu/settings/UAC retained; new CLI/menu modes, same-window output and cancellation relay; separate v2 identity |
| `console/V2Runtime.cs` | Config loading, elevation, protected installed manifest verification, operation lock, cancellation/deadlines and crash recovery |
| `console/InteropPolicy.cs` | Restricts project native imports to System32; grants test assembly internal fixture access |
| `console/Core/Models.cs` | Config validation, states, candidate/result model, public-address/hostname policy, standard .NET CIDR, scoring, synchronized logging |
| `console/Core/Discovery.cs` | Provider interface, all-A system DNS, bounded DoH/CNAME parser, zero-subnet Google ECS, deduplication, AWS parsing and cached prefix lookup |
| `console/Core/Probe.cs` | Direct TCP + strict TLS/SNI + HTTP Host, bounded response validation, separate latency metrics |
| `console/Core/Storage.cs` | Protected atomic files, exclusive locks, successful-address/AWS TTL caches, log rotation |
| `console/Core/Hosts.cs` | Managed-block preservation, unique backups, conflict detection, atomic replace, rollback, crash journal, DNS flush |
| `console/Core/RepairEngine.cs` | Diagnosis, early cached path, discovery/ranking, bounded attempts, final verification, rollback and one post-fix restart phase |
| `console/Core/RobloxProcessManager.cs` | Player capture, original-user token, executable/signature verification, bounded close and safe relaunch |
| `AutoFix.Common.ps1` | Retained installation ACL/manifest/settings/rotation utilities, separate v2 directories/task identity |
| `Manage-AutoFixTask.ps1` | Versioned protected deployment of EXE/scripts/config; task and settings rollback; repair lock acquired before stopping watcher |
| `Roblox-CDN-Monitor.ps1` | Event-driven WMI watcher, persistent cooldown, hidden protected native checks, protected .NET extraction |
| `Roblox-CDN-AutoFix.ps1`, five `.cmd` launchers | Compatibility entry points to native v2 modes |
| `console/RobloxCDNAutoFix.Console.csproj`, `NuGet.Config`, `build-release.ps1` | .NET 8.0.31 self-contained x64/ARM64 outputs and checksums, official package source |
| `config.example.json`, `.gitignore`, `.github/workflows/ci.yml` | Documented configuration, build-artifact exclusions, Windows validation/publish CI |
| `tests/CoreTests/*`, `tests/Test-*.ps1` | Offline core, native fixture, installation, ACL, console and WMI event checks |
| `README.md`, `RELEASES.md`, `SECURITY.md`, this file | Bilingual guide/release notes, threat model, audit and reproducible validation |

## 2. Discovery, validation and selection

The healthy current mapping is left untouched. A fresh cached address is always probed before use. Otherwise system DNS and independent allowlisted DoH providers return candidate A records; CNAME chains, source attribution and available TTLs are handled. Deduplication precedes the configured bound. Dynamic results take priority; built-in addresses are only tested when dynamic finalists fail. No address enumeration from AWS ranges occurs.

AWS JSON is fetched from its official endpoint, parsed for `CLOUDFRONT`, and cached. CIDR membership uses `System.Net.IPNetwork`; AWS networks are parsed once per metadata load rather than once per candidate comparison. A stale cached list or no metadata is allowed when refresh fails. CloudFront is a scoring hint, never a substitute for hostname-authenticated TLS.

The probe connects to the candidate's public IPv4, using the Roblox hostname for SNI/certificate validation and HTTP Host. It records TCP, TLS, TTFB and total-to-headers time. Known CDN 403/404 replies may pass; 5xx, 429, unknown fingerprints or network/TLS failure do not. Finalists must pass all repeated samples; selection uses documented configurable bonuses and median/jitter penalties.

## 3. Hosts and restart guarantees

Only owned entries are transformed. Foreign mappings, malformed blocks and unexpected external modifications are refused. Unique verified backups precede protected recovery records and atomic file replacement. Effective system DNS and repeated HTTPS must confirm the applied IP. A failed candidate is rolled back and rejected before the next attempt; all failures leave the previous snapshot intact unless a concurrent external modification requires manual recovery.

Player state is captured before repair. Restart is gated by `was running && hosts changed && verification passed`, after commit, once per captured Player in one post-fix phase. Studio is excluded. Launch uses a checked Roblox executable and original non-elevated token. Restart failure cannot revert an already successful network fix. Credentials and original launch arguments are not collected.

## 4. Tests performed

| Check | Result |
|---|---|
| Core offline runner | **72 assertions passed** |
| Core + live network runner | **76 assertions passed**: offline suite plus Google DoH, direct-IP HTTPS, wrong-hostname TLS rejection, official AWS JSON |
| Core + protected native file fixtures | **78 assertions passed**: offline suite plus backup, File.Replace, byte-exact rollback, backup uniqueness, crash journal recovery, concurrent-edit preservation |
| Retained PowerShell safety tests | **55 assertions passed**: syntax, ACL/path guards, managed hosts helpers, atomic write failure rollback, manifest tampering, scoped deletion, locks, rotation |
| Installer lifecycle | Install, repeated install, no duplicate task, uninstall twice, failed file copy rollback, settings rollback, protected action/SYSTEM/Highest, one watcher — passed |
| Active repair vs uninstall | Held operation lock causes uninstall refusal **without stopping the watcher** — passed |
| Ordinary-user attack | **12 Access Denied checks** across two retained releases: EXE, three scripts, config and manifest; directory creation/task ACL modification also denied |
| Event-driven SYSTEM invocation | WMI test process starts protected native diagnosis, no hosts mutation — passed |
| Console settings | AutoRepair, cooldown, process names and theme persist — passed |
| Console output | UAC output returns to original menu; UTF-8 intact; menu remains usable — passed |
| Real release `--diagnose` | Healthy existing mapping reported; no mutation |
| Real release `--dry-run` | Dynamic Google DNS candidate selected, AWS verified, hosts hash unchanged |
| Real release `--repair` | Existing healthy mapping retained; no restart when Player absent |
| Restore / failed repair scenarios | Tested with fake and protected fixture backends, **not by deleting the user's active v1 system mapping** |
| Build/analyzers | `dotnet build -warnaserror`: zero warnings/errors |
| Format | `dotnet format --verify-no-changes`: passed |
| Publish | Self-contained `win-x64` and `win-arm64`: succeeded |

The healthy, bad-DNS, candidate-dies-before-final-verify, AWS-unavailable and user-hosts-preservation scenarios all have offline tests. Additional cases cover all-candidates-fail, cached fast path, cached final failure followed by discovery, forced discovery keeping an equivalent healthy IP, cancellation during verification, restart gating and restart failure.

Live DNS really changed between runs: some candidates timed out during TLS, while later candidates passed. The network test consequently checks a bounded pool, not an assumption that the first returned IP must work. A dry-run selected a **dynamically discovered** Google DNS/CloudFront candidate with roughly 142 ms median in one sample; this is an observation, not a performance promise or hardcoded preferred address.

One intentionally overlapping installer/status test encountered the exclusive staging lock. The operation safely refused rather than concurrently modifying installation files; the event test was rerun sequentially. Users should wait for one installation/settings operation to finish before starting another.

### Resource sample

Idle PowerShell watcher: approximately **92 MiB private memory**; a 10-second sample consumed **0.000–0.016 CPU seconds**. This is a short local sample, not a universal resource guarantee. There are no periodic CDN requests. Native discovery only runs on demand/process-start and uses at most the configured workers. EXE copying is streamed; status/uninstall do not copy the large runtime binary into staging.

## 5. Reproduction

Run from the v2 root on Windows:

```powershell
dotnet build console/RobloxCDNAutoFix.Console.csproj -warnaserror
dotnet format console/RobloxCDNAutoFix.Console.csproj --verify-no-changes
dotnet run --project tests/CoreTests/CoreTests.csproj
powershell -NoProfile -File tests/Test-Local.ps1
dotnet run --project tests/CoreTests/CoreTests.csproj -- --network
.\build-release.ps1
powershell -NoProfile -File tests/Test-Lifecycle.ps1
powershell -NoProfile -File tests/Test-InstalledSecurity.ps1
powershell -NoProfile -File tests/Test-MonitorEvent.ps1
powershell -NoProfile -File tests/Test-ConsoleSettings.ps1
powershell -NoProfile -File tests/Test-ConsoleOutput.ps1
```

Run lifecycle/event/console installation tests **sequentially**. Lifecycle requests UAC; InstalledSecurity must run **unelevated**. Lifecycle/event tests replace v2 monitoring configuration. Offline tests never kill Roblox or touch actual system hosts. The native fixture option needs an elevated test process and uses separate protected fixture files, not system hosts.

## 6. Build and release

Preserved C#/.NET + PowerShell stack. Runtime pinned to **8.0.31**, checked against [Microsoft's .NET 8 release metadata](https://builds.dotnet.microsoft.com/dotnet/release-metadata/8.0/releases.json), instead of embedding the older locally installed 8.0.21. Recheck maintained runtime patches before future releases; .NET 8 maintenance ends 2026-11-10 according to that metadata.

Release output: `release/windows-x64.exe`, `release/windows-arm64.exe`, optional `release/SHA256SUMS.txt`. Each EXE is independently runnable, approximately 65/72 MiB. Checksums are regenerated by the build script; the checksum file, not this report, is authoritative for the final bytes.

Publication checklist:

1. Publish the contents of `version2` as the repository root; its nested workflow is not active while left under a parent repository's `version2` directory.
2. Do not upload `bin`, `obj`, local settings/cache/backups or test fixtures; exclusions are provided.
3. Create GitHub release/tag `v2.0.0`, paste the bilingual `RELEASES.md` description and attach the two EXEs plus optional SHA256SUMS.
4. Verify downloaded asset hashes match. No GitHub release, tag or commit was created automatically during this task.
5. Remove the v1 watcher with the old application before installing v2 monitoring. The source tree for v1 remains separate.

## 7. Remaining limitations

- ARM64 was cross-built, not run on native ARM64 hardware.
- Real interactive Roblox restart was **not** tested by closing the user's game. Decision/order/failure behavior is tested with fake process backends; native token/signature/launcher behavior needs validation on the relevant Roblox installation.
- IPv6 repair and preservation of a specific game session are not implemented. Paired v1 hosts blocks migrate; much older standalone markers need v1 restore first.
- Root-CDN HTTPS is an availability signal, not an asset-download guarantee. Strict direct probes can fail on proxy-only networks. AWS metadata can be unavailable/stale.
- A forced process kill/power failure postpones journal recovery until the next mutating run. Concurrent privileged hosts editors are outside the process lock; observed conflicts are refused, not overwritten.
- EXEs are unsigned. Keep Windows security enabled; hashes are not publisher signatures.
- No Go race detector applies to this .NET project. Bounded parallel tests share no mutable candidate map; logging is serialized and mutation uses cross-process file locks. This is not a formal proof against every possible race.

Detailed permissions, external endpoints and residual trust assumptions: [SECURITY.md](SECURITY.md). Full command/config reference: [README.md](README.md).
