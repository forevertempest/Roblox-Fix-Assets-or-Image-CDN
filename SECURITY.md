# Security model / Модель безопасности

## Trust boundaries

- Репозиторий и скачанный EXE доверяются **только при явном запуске пользователем**. Перед UAC нужно доверять источнику бинарника. Сборка не подписана; SHA-256 подтверждает совпадение, не личность издателя.
- SYSTEM-задача не запускает код из репозитория, Downloads, Desktop, AppData или TEMP. Установщик сначала создаёт защищённый staging, копирует embedded scripts/native EXE/validated config, формирует отдельный release и SHA-256 manifest; только затем регистрирует задачу.
- Installed root: `%ProgramFiles%\RobloxCDNAutoFixV2`; persistent data: `%ProgramData%\RobloxCDNAutoFixV2-Secure`. SYSTEM runtime extraction is explicitly redirected to protected `dotnet-bundle` storage.
- ACL: `O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)`. Owner: Administrators. SYSTEM and Administrators: FullControl. Built-in Users: ReadAndExecute, no write/delete/ACL changes. Reparse points and untrusted writable ownership/ancestors are refused.
- Task ACL: `O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;BU)`. SYSTEM/Highest is needed for hosts modification. The action uses absolute Windows PowerShell and a quoted fixed installed `.ps1`; no `cmd /c`. Native `--system-settings` also verifies protected location and runtime hashes.
- Hashes detect corruption or unexpected changes within protected storage. They do not defend against an administrator who can replace both files and manifest. No claim of security against kernel/admin compromise.

## Audit findings and treatment

| Area | Treatment in v2 |
|---|---|
| Static-address maintenance | Multi-provider DNS, revalidated cache; emergency fallback only |
| AWS address mistaken for Roblox | Membership is metadata only; strict target TLS/SNI + HTTPS remains mandatory |
| False success from open TCP or arbitrary HTTP | Certificate validation, CDN headers, status policy, repeated samples |
| SYSTEM executing user-writable files | Protected versioned installation + ACL + absolute paths + manifest |
| SYSTEM reading user config | Validated snapshot installed with protected runtime; no external `--config` with `--system-settings` |
| Restarting user executable as SYSTEM | Duplicate original non-elevated Player token; validate identity/path/signature; launch as original user |
| Reusing Player secrets | No original command line, cookies, join tickets or authentication data read/logged |
| User hosts loss | Managed-only text transform, foreign override refusal, backups, atomic replace and conflict hashes |
| Failure/cancellation after applying | Rollback and flush; protected recovery journal for interrupted transactions |
| Concurrent repair/install | Exclusive operation, installation and staging locks; candidate workers own separate objects |
| SSRF/path/command injection | Roblox DNS names only, public IPv4 parser, allowlisted resolvers, ArgumentList/API calls, no dynamic code evaluation |
| DLL/PATH hijacking | Absolute OS executable paths; project P/Invoke libraries load from System32; minimal PowerShell module PATH |
| Log growth | 1 MiB rotation plus one previous file |

Search audit covers `Invoke-Expression`, `iex`, `DownloadString`, `DownloadFile`, `WebClient`, shell execution, encoded commands, TLS bypass, deletion paths and P/Invoke. No dynamic downloaded code or encoded PowerShell execution is used. **Base64url is DNS wire-format transport, not executable code.** `Start-Process -Verb RunAs -WindowStyle Hidden` is retained for explicit administrative operations/tests. Scoped recursive deletion is restricted to the fixed protected installation tree and validates every child; repository deletion is refused.

`build-release.ps1` contacts NuGet for official .NET SDK/runtime assets during development. This is not a runtime telemetry endpoint. Runtime network destinations are the configured Roblox CDN names, Google/Cloudflare/optional Quad9 DNS and the official AWS ranges endpoint. Windows DNS/TLS may use OS-managed resolver/certificate infrastructure; AutoFix neither disables certificate validation nor controls all Windows background traffic.

## Validation commands

From the v2 project root:

```powershell
dotnet run --project tests/CoreTests/CoreTests.csproj
powershell -NoProfile -File tests/Test-Local.ps1
powershell -NoProfile -File tests/Test-Lifecycle.ps1
```

The lifecycle test requests UAC, removes/reinstalls **v2 only**, tests failed update recovery, checks the task principal/action, measures idle CPU and executes native atomic hosts operations against protected fixture files. It leaves v2 monitoring installed. It never intentionally changes the actual system hosts or terminates Roblox.

Then run **without elevation**:

```powershell
powershell -NoProfile -File tests/Test-InstalledSecurity.ps1
```

Expected: **Access Denied** for write-open on every installed `.ps1`, native EXE, JSON and manifest; creation denied in protected directories; task ACL modification denied. The test opens existing files for write but writes no bytes, and checks their hashes unchanged.

Optional `tests/Test-MonitorEvent.ps1` installs a temporary diagnosis-only process filter, starts a harmless copied Windows `where.exe` under a test name without a window, waits for SYSTEM diagnosis and restores normal monitor configuration. It does not enable repair during that event. Do not run lifecycle/event tests while relying on a customized monitor configuration; they replace its settings.

Uninstall:

```powershell
.\release\windows-x64.exe monitor remove
.\release\windows-x64.exe monitor remove
```

Both calls must succeed; the task/runtime disappear, repository and backups remain, hosts is unchanged. `--restore` removes only owned mappings; it is deliberately tested through fake/native fixture backends rather than deleting a user's active v1 fix during development.

## Residual limitations / Ограничения

1. Forced termination/power loss cannot execute `finally`; a pending snapshot is recovered on the next mutating run. `--diagnose` and `--dry-run` intentionally do not repair pending storage. If hosts was edited externally, recovery refuses to overwrite it; inspect the protected backup/journal manually.
2. Windows does not expose a file-system compare-and-swap for hosts. Hash checks detect observed conflicts, but another privileged editor can race between check and replace. Ordinary users cannot write hosts. Avoid simultaneously running v1/v2 or other hosts editors.
3. Read-only protected data includes hosts backups; local Users can read them, as with standard hosts. They are never uploaded. Operators needing stricter local confidentiality may choose an administrator-only ACL, but must retest diagnostics and installation.
4. TLS trusts the Windows trust store. A compromised trusted root or privileged administrator is outside this model. CDN fingerprinting is a conservative availability signal, not proof every asset is retrievable.
5. Restart requires an accessible original user token, unchanged PID/start time/path and a valid Roblox Corporation signature. Protected/MS Store/updated or differently signed installations may require manual restart. Specific game sessions are not restored. Actual interactive Player restart needs on-device validation; unit tests use a fake backend and never kill the real game.
6. IPv4 only for discovery/repair. Proxy-only networks and resolver filtering may prevent discovery. CloudFront cache may be stale and is marked as such; TLS validation is still required.
7. ARM64 build is provided; x64-host testing does not replace native ARM64 runtime validation. The project uses .NET 8 and the installed Windows security stack; rebuild with maintained SDK/runtime patches before publication.

Report security issues privately to the maintainer (Discord `foreverfame`). Do not post cookies, tokens, original Player command lines or full private hosts contents in public issues.
