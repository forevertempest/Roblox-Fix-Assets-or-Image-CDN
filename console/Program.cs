using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Reflection;
using System.IO.Pipes;
using System.Runtime.InteropServices;

namespace RobloxCDNAutoFix;

internal static class Program
{
    private const string Domain = "tr.rbxcdn.com";
    private const string TaskManager = "Manage-AutoFixTask.ps1";
    private const string FixScript = "Roblox-CDN-AutoFix.ps1";
    private const string InstallDirectoryName = "RobloxCDNAutoFix";
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private sealed class Preferences
    {
        public string Theme { get; set; } = "neon";
        public int CooldownMinutes { get; set; } = 30;
        public bool AutoRepair { get; set; } = true;
        public string[] ProcessNames { get; set; } = ["RobloxPlayer", "RobloxPlayerBeta", "RobloxPlayerLauncher"];
    }

    private static bool IsWindows => OperatingSystem.IsWindows();
    private static string UserConfigDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Tempest", InstallDirectoryName);
    private static string UserSettingsPath => Path.Combine(UserConfigDirectory, "settings.json");
    private static string WindowsInstallRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), InstallDirectoryName);
    private static string WindowsSourceDirectory => Path.Combine(WindowsInstallRoot, "embedded-source");
    private static readonly string[] EmbeddedWindowsScripts =
    [
        "AutoFix.Common.ps1",
        "Manage-AutoFixTask.ps1",
        "Roblox-CDN-AutoFix.ps1",
        "Roblox-CDN-Monitor.ps1"
    ];

    public static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        if (!IsWindows)
        {
            Console.Error.WriteLine("Roblox CDN AutoFix поддерживает только Windows.");
            return 1;
        }
        var pipeIndex = Array.IndexOf(args, "--output-pipe");
        if (pipeIndex < 0)
            return await RunAsync(args);
        if (!IsWindows || !IsAdministrator() || pipeIndex + 1 >= args.Length ||
            !Guid.TryParseExact(args[pipeIndex + 1], "N", out var pipeId))
            return 2;

        try
        {
            using var pipe = new NamedPipeClientStream(".", "RobloxCDNAutoFix-" + pipeId.ToString("N"),
                PipeDirection.Out, PipeOptions.Asynchronous, TokenImpersonationLevel.Anonymous);
            await pipe.ConnectAsync(15000);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true };
            var originalOutput = Console.Out;
            var originalError = Console.Error;
            Console.SetOut(writer);
            Console.SetError(writer);
            try
            {
                return await RunAsync(args.Where((_, index) => index != pipeIndex && index != pipeIndex + 1).ToArray());
            }
            finally
            {
                Console.SetOut(originalOutput);
                Console.SetError(originalError);
            }
        }
        catch (Exception exception)
        {
            TryWriteWindowsDiagnostic("Output relay: " + exception.Message);
            return 1;
        }
    }

    private static async Task<int> RunAsync(string[] args)
    {
        if (!Console.IsOutputRedirected)
            Console.Title = "Roblox CDN AutoFix | Tempest";
        var preferences = LoadPreferences();
        ApplyOverrides(preferences, args);
        SetTheme(preferences.Theme);

        try
        {
            if (args.Length == 0 || args[0] is "menu" or "--menu")
                return await MenuAsync(preferences);

            return await DispatchAsync(args, preferences);
        }
        catch (OperationCanceledException)
        {
            WriteLine("Операция отменена.");
            return 130;
        }
        catch (Exception exception)
        {
            TryWriteWindowsDiagnostic("Unhandled: " + exception.Message);
            WriteLine("Ошибка: " + exception.Message, ConsoleColor.Red);
            Console.WriteLine("Проверь журнал операции и системный Console.log приложения.");
            return 1;
        }
    }

    private static async Task<int> DispatchAsync(string[] args, Preferences preferences)
    {
        var action = args[0].ToLowerInvariant();
        switch (action)
        {
            case "check":
            case "fix":
                return await RunWindowsScriptAsync(FixScript, action);
            case "reset":
                if (!args.Contains("--yes", StringComparer.Ordinal) && !AskYesNo("Убрать управляемую запись CDN из hosts?"))
                    return 0;
                return await RunWindowsManagerAsync("Reset", preferences, "reset");
            case "monitor":
                return await HandleMonitorAsync(args.Skip(1).FirstOrDefault() ?? "status", preferences);
            case "settings":
                return await SettingsMenuAsync(preferences);
            case "info":
                ShowInformation(preferences);
                return 0;
            case "status":
                return await HandleMonitorAsync("status", preferences);
            case "help":
            case "--help":
            case "-h":
                PrintHelp();
                return 0;
            case "--version":
                WriteLine("Roblox CDN AutoFix 1.0.0 • Tempest");
                return 0;
            default:
                PrintHelp();
                return 2;
        }
    }

    private static async Task<int> MenuAsync(Preferences preferences)
    {
        while (true)
        {
            DrawHeader(preferences);
            Console.WriteLine("  [1]  Проверить и исправить CDN");
            Console.WriteLine("  [2]  Настроить автопроверку Roblox");
            Console.WriteLine("  [3]  Изменить параметры");
            Console.WriteLine("  [4]  Сбросить изменение hosts");
            Console.WriteLine("  [5]  Состояние автопроверки");
            Console.WriteLine("  [6]  Информация — функции и примеры");
            Console.WriteLine("  [0]  Выход");
            Console.Write("\n  Выбор › ");
            var key = Console.ReadLine()?.Trim();
            Console.WriteLine();
            switch (key)
            {
                case "1":
                    await RunMenuActionAsync(() => DispatchAsync(["fix"], preferences));
                    break;
                case "2":
                    await RunMenuActionAsync(() => HandleMonitorAsync("menu", preferences));
                    break;
                case "3":
                    await SettingsMenuAsync(preferences);
                    break;
                case "4":
                    await RunMenuActionAsync(() => DispatchAsync(["reset"], preferences));
                    break;
                case "5":
                    await RunMenuActionAsync(() => HandleMonitorAsync("status", preferences));
                    break;
                case "6":
                    ShowInformation(preferences);
                    break;
                case "0":
                case null:
                    return 0;
            }
        }
    }

    private static void ShowInformation(Preferences preferences)
    {
        (string Title, string Description)[] topics =
        [
            ("Что делает AutoFix", """
                Roblox получает часть файлов через CDN — серверы доставки контента.
                AutoFix проверяет доступность tr.rbxcdn.com по HTTPS и при проблеме
                ищет рабочий IP. Если он найден, программа добавляет свою запись в hosts.
                Этот файл позволяет Windows обращаться к домену по выбранному IP.

                Пример: Roblox не загружает контент из-за недоступного адреса CDN.
                AutoFix может подобрать доступный адрес. Если CDN уже работает,
                менять hosts не требуется.

                Программа не исправляет все ошибки Roblox: сбой серверов игры,
                проблемы аккаунта или отсутствие интернета могут иметь другую причину.
                Просмотр этой справки ничего не меняет и не обращается к сети.
                """),
            ("Ручная проверка и исправление", """
                Главный экран → 1. Проверка запускается сразу, даже если Roblox закрыт.
                Сначала проверяется текущая доступность CDN. Если есть проблема,
                программа ищет и проверяет другие IP по HTTPS перед записью в hosts.
                Перед изменением создаётся резервная копия; при ошибке предусмотрен откат.

                Пример: игра не загружает контент. Выбери 1, подтверди запрос прав
                администратора и дождись результата в этом же окне.
                Если написано «CDN уже доступен», hosts менять не пришлось.

                Ручной запуск не ограничен кулдауном и работает даже при выключенном
                автоисправлении. Команды check и fix обе могут исправлять hosts.
                """),
            ("Установка, обновление и удаление автопроверки", """
                Главный экран → 2 → 1: установить или обновить наблюдатель.
                Он работает в фоне после закрытия консольного меню.
                Используется защищённая копия программы и Планировщик заданий Windows.

                Windows сообщает наблюдателю о запуске выбранного процесса Roblox.
                CDN проверяется при обнаружении запуска, а не каждые пять минут.
                На Windows после установки перезапусти уже открытую игру.

                Пример: поменял кулдаун в параметрах → выбери установку / обновление,
                чтобы работающий наблюдатель получил новые настройки.
                Главный экран → 2 → 2: удалить автопроверку. Это не сбрасывает hosts;
                резервные копии и журналы сохраняются.
                """),
            ("Автоматическое исправление", $"""
                Параметры → 1. Текущее сохранённое значение: {(preferences.AutoRepair ? "ВКЛ" : "ВЫКЛ")}.
                ВКЛ: если при запуске Roblox CDN недоступен, наблюдатель может
                запустить исправление с учётом кулдауна.
                ВЫКЛ: наблюдатель проверяет доступность и сообщает о проблеме в журнале,
                но автоматический ремонт не запускает.

                Пример: хочешь решать сам, когда менять hosts — выключи автоисправление.
                При необходимости запусти ручную проверку из главного меню.
                Эта настройка не удаляет уже добавленную запись hosts.
                После изменения обнови установленную автопроверку через пункт 2.
                """),
            ("Кулдаун ремонта", $"""
                Параметры → 2. Сейчас: {preferences.CooldownMinutes} мин. Диапазон: 1–1440 мин.
                Это минимальная пауза между попытками автоматического ремонта,
                включая неудачные. Она предотвращает частые повторные исправления.
                Проверять доступность CDN во время паузы по-прежнему можно.

                Пример для 30 минут: попытка ремонта была в 12:00.
                При запуске Roblox в 12:05 CDN проверится, но повторного ремонта не будет.
                При запуске после 12:30 ремонт снова разрешён, если CDN недоступен.
                Само окончание паузы не запускает ремонт: нужен новый запуск игры.

                Ручная проверка из пункта 1 обходит кулдаун.
                После изменения обнови установленную автопроверку через пункт 2.
                """),
            ("Как обнаруживается запуск Roblox", """
                Наблюдатель ждёт системное событие запуска выбранного процесса Roblox.
                Интервал опроса не нужен: список процессов не проверяется по таймеру.
                При событии запуска выполняется проверка CDN по HTTPS.

                Пример: установил автопроверку → закрыл меню → запустил Roblox.
                Наблюдатель проверит CDN в фоне. Пока игра открыта, повторных
                сетевых проверок каждые несколько минут нет.

                Если Roblox уже был открыт при установке, полностью перезапусти игру.
                Закрытие меню не останавливает установленный наблюдатель.
                """),
            ("Названия процессов Roblox", $"""
                Параметры → 3. По этим именам наблюдатель узнаёт запуск Roblox.
                Сейчас: {string.Join(", ", preferences.ProcessNames)}
                Можно указать до восьми имён через запятую, без пути к файлу.
                Расширение .exe можно опустить — при сохранении оно убирается.

                Пример: RobloxPlayerBeta,RobloxPlayerLauncher
                Имена можно сверить в Диспетчере задач → Подробности.

                Если указать неверные имена, запуск игры не будет обнаружен.
                Если указать другую программу, проверка будет реагировать на неё.
                После изменения обнови установленную автопроверку через пункт 2.
                """),
            ("Цветовая схема и сохранение настроек", $"""
                Параметры → 4. Сейчас: {preferences.Theme}.
                Каждый выбор переключает оформление: neon → amber → mono.
                Это меняет цвета консоли и не влияет на CDN или нагрузку наблюдателя.

                Пример: для спокойного оформления выбери mono.
                Параметры сохраняются для текущего пользователя после изменения.
                Наблюдатель использует отдельную копию настроек, созданную при установке.

                Изменения автоисправления, кулдауна и процессов
                применяются к наблюдателю через «Установить / обновить» в пункте 2.
                Для изменения цвета обновлять наблюдатель не нужно.
                """),
            ("Сброс изменений hosts", """
                Главный экран → 4. После подтверждения удаляется только запись,
                которой управляет AutoFix. Чужие строки hosts сохраняются.
                Сброс также удаляет установленную автопроверку.
                Резервные копии сохраняются. Это не замена всего hosts старой копией.

                Пример: больше не нужен подобранный IP — выполни сброс.
                Домен снова будет разрешаться обычным способом, если нет чужой записи.
                Чтобы сохранить запись hosts, но выключить фоновые проверки,
                выбери удаление автопроверки в пункте 2 вместо сброса.
                """),
            ("Состояние автопроверки", """
                Главный экран → 5. Показывает состояние установленного наблюдателя.
                На Windows выводятся состояние задачи и путь к защищённому скрипту.
                Если автопроверка отсутствует, программа сообщит об этом.

                Пример: после установки открой пункт 5. Running на Windows означает,
                что наблюдатель запущен и может ожидать запуска Roblox.
                Это не означает, что CDN проверяется в данный момент или уже исправлен.
                Для немедленной проверки самого CDN используй пункт 1.
                """),
            ("Журналы, резервные копии и безопасность", """
                При ручной операции ход работы и результат видны в основном окне.
                Фоновые операции записываются в журналы; отдельные консоли скрыты.
                Запрос прав администратора нужен для системных изменений.

                Каталог: %ProgramData%\RobloxCDNAutoFix-Secure\
                Журналы: RobloxCDNAutoFix.log, RobloxCDNMonitor.log, Installer.log, Console.log.
                Размер журналов ограничивается ротацией. До записи hosts создаётся backup.

                Пример: автоматический ремонт не сработал — посмотри журнал наблюдателя,
                затем при необходимости запусти ручную проверку и прочитай её вывод.
                Программа не отправляет телеметрию. Сетевые обращения нужны для CDN
                tr.rbxcdn.com и поиска его IP через Google / Cloudflare DNS-over-HTTPS.
                """),
            ("Команды консоли", """
                Вместо меню можно передать команду исполняемому файлу:

                  windows-x64.exe fix              Проверить и исправить CDN
                  windows-x64.exe check            То же, может менять hosts
                  windows-x64.exe monitor install  Установить / обновить наблюдатель
                  windows-x64.exe monitor remove   Удалить наблюдатель
                  windows-x64.exe status           Посмотреть его состояние
                  windows-x64.exe settings         Открыть параметры
                  windows-x64.exe reset            Сбросить собственную запись hosts
                  windows-x64.exe info             Открыть эту справку
                  windows-x64.exe help             Краткий список команд

                Пример: в PowerShell, находясь в папке EXE, введи .\windows-x64.exe status
                """)
        ];

        while (true)
        {
            DrawHeader(preferences);
            WriteLine("ИНФОРМАЦИЯ — выбери тему", AccentColor(preferences.Theme));
            for (var index = 0; index < topics.Length; index++)
                Console.WriteLine($"  [{index + 1}]  {topics[index].Title}");
            Console.WriteLine("  [0]  Назад");
            Console.Write("\n  Тема › ");
            var input = Console.ReadLine()?.Trim();
            if (input is null or "0")
                return;
            if (!int.TryParse(input, out var selection) || selection < 1 || selection > topics.Length)
            {
                WriteLine($"Введи номер темы от 1 до {topics.Length} или 0 для возврата.", ConsoleColor.Yellow);
                Pause();
                continue;
            }
            var topic = topics[selection - 1];
            DrawHeader(preferences);
            WriteLine(topic.Title.ToUpperInvariant(), AccentColor(preferences.Theme));
            Console.WriteLine();
            foreach (var line in topic.Description.Split('\n'))
                Console.WriteLine("  " + line);
            Pause();
        }
    }

    private static async Task RunMenuActionAsync(Func<Task<int>> action)
    {
        try
        {
            var exitCode = await action();
            if (exitCode != 0)
                WriteLine($"Операция завершилась с кодом {exitCode}.", ConsoleColor.Red);
        }
        catch (System.ComponentModel.Win32Exception exception) when (exception.NativeErrorCode == 1223)
        {
            WriteLine("Запрос прав администратора отменён.", ConsoleColor.Yellow);
        }
        catch (Exception exception)
        {
            TryWriteWindowsDiagnostic(exception.Message);
            WriteLine("Ошибка: " + exception.Message, ConsoleColor.Red);
        }
        Pause();
    }

    private static void DrawHeader(Preferences preferences)
    {
        if (!Console.IsOutputRedirected)
            Console.Clear();
        var accent = AccentColor(preferences.Theme);
        Console.ForegroundColor = accent;
        Console.WriteLine("╭──────────────────────────────────────────────────────────────╮");
        Console.WriteLine("│   ████████╗███████╗███╗   ███╗██████╗ ███████╗███████╗████████╗ │");
        Console.WriteLine("│   ╚══██╔══╝██╔════╝████╗ ████║██╔══██╗██╔════╝██╔════╝╚══██╔══╝ │");
        Console.WriteLine("│      ██║   █████╗  ██╔████╔██║██████╔╝█████╗  ███████╗   ██║    │");
        Console.WriteLine("│      ██║   ██╔══╝  ██║╚██╔╝██║██╔═══╝ ██╔══╝  ╚════██║   ██║    │");
        Console.WriteLine("│      ██║   ███████╗██║ ╚═╝ ██║██║     ███████╗███████║   ██║    │");
        Console.WriteLine("│      ╚═╝   ╚══════╝╚═╝     ╚═╝╚═╝     ╚══════╝╚══════╝   ╚═╝    │");
        Console.WriteLine("│                 ROBLOX CDN AUTOFIX  •  v1.0.0                  │");
        Console.WriteLine("╰──────────────────────────────────────────────────────────────╯");
        Console.ResetColor();
        Console.WriteLine("  Разработчик: Tempest  •  Discord: foreverfame  •  TGC: t.me/tempestdevelop");
        Console.WriteLine($"  Платформа: Windows   CDN: {Domain}");
        Console.WriteLine();
    }

    private static Task<int> SettingsMenuAsync(Preferences preferences)
    {
        while (true)
        {
            DrawHeader(preferences);
            Console.WriteLine("  ПАРАМЕТРЫ");
            Console.WriteLine($"  [1]  Автоматически исправлять CDN    {(preferences.AutoRepair ? "ВКЛ" : "ВЫКЛ")}");
            Console.WriteLine($"  [2]  Cooldown ремонта                {preferences.CooldownMinutes} мин");
            Console.WriteLine($"  [3]  Названия процессов              {string.Join(", ", preferences.ProcessNames)}");
            Console.WriteLine($"  [4]  Цветовая схема                  {preferences.Theme}");
            Console.WriteLine("  [0]  Назад");
            Console.Write("\n  Изменить › ");
            var input = Console.ReadLine()?.Trim();
            switch (input)
            {
                case "1":
                    preferences.AutoRepair = !preferences.AutoRepair;
                    break;
                case "2":
                    preferences.CooldownMinutes = ReadInt("Cooldown в минутах (1–1440)", preferences.CooldownMinutes, 1, 1440);
                    break;
                case "3":
                    Console.WriteLine("Введи имена процессов через запятую; расширение .exe не нужно.");
                    Console.Write("Процессы › ");
                    var names = (Console.ReadLine() ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)
                        .Where(name => Regex.IsMatch(name, "^[A-Za-z0-9_.-]{1,80}$"))
                        .Distinct(StringComparer.OrdinalIgnoreCase).Take(8).ToArray();
                    if (names.Length > 0)
                        preferences.ProcessNames = ValidateProcessNames(names);
                    else
                        WriteLine("Оставлены прежние имена процессов.", ConsoleColor.Yellow);
                    break;
                case "4":
                    preferences.Theme = preferences.Theme == "neon" ? "amber" : preferences.Theme == "amber" ? "mono" : "neon";
                    SetTheme(preferences.Theme);
                    break;
                case "0":
                case null:
                    SavePreferences(preferences);
                    WriteLine("Настройки сохранены.");
                    WriteLine("Для применения новых параметров к системному наблюдателю выбери установку/обновление мониторинга.", ConsoleColor.Yellow);
                    Pause();
                    return Task.FromResult(0);
            }
            SavePreferences(preferences);
        }
    }

    private static async Task<int> HandleMonitorAsync(string action, Preferences preferences)
    {
        if (action == "menu")
        {
            Console.WriteLine("  [1] Установить / обновить");
            Console.WriteLine("  [2] Удалить");
            Console.WriteLine("  [0] Назад");
            Console.Write("  Выбор › ");
            action = Console.ReadLine()?.Trim() switch
            {
                "1" => "install",
                "2" => "remove",
                _ => "cancel"
            };
        }
        if (action == "cancel")
            return 0;

        if (action is not ("install" or "remove" or "status"))
            return 2;
        return await RunWindowsManagerAsync(action switch
        {
            "install" => "Install",
            "remove" => "Uninstall",
            _ => "Status"
        }, preferences, "monitor");
    }

    private static async Task<int> RunWindowsScriptAsync(string scriptName, string command)
    {
        if (!IsAdministrator())
            return await RelaunchElevatedAsync([command, "--elevated"]);
        WriteLine("Проверка Roblox CDN запущена. Ожидай результат…");
        var source = EnsureWindowsSources();
        try
        {
            var protectedScript = Path.Combine(source, scriptName);
            var powershellPath = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
            return await RunProcessAsync(powershellPath, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", protectedScript, "-Quiet"]);
        }
        finally
        {
            TryRemoveWindowsSources();
        }
    }
    private static async Task<int> RunWindowsManagerAsync(string action, Preferences preferences, string command)
    {
        if (!IsAdministrator())
        {
            var elevated = new List<string>
            {
                command,
                action.Equals("Reset", StringComparison.OrdinalIgnoreCase) ? "--yes" :
                    action.Equals("Uninstall", StringComparison.OrdinalIgnoreCase) ? "remove" : action.ToLowerInvariant(),
                "--elevated"
            };
            if (action.Equals("Install", StringComparison.OrdinalIgnoreCase))
            {
                elevated.AddRange(["--cooldown", preferences.CooldownMinutes.ToString(), "--auto-repair", preferences.AutoRepair.ToString(),
                    "--process-names", string.Join(',', preferences.ProcessNames)]);
            }
            return await RelaunchElevatedAsync(elevated);
        }

        WriteLine(action switch
        {
            "Install" => "Установка / обновление автопроверки…",
            "Uninstall" => "Удаление автопроверки…",
            "Reset" => "Сброс изменений AutoFix…",
            _ => "Проверка состояния автопроверки…"
        });
        var source = EnsureWindowsSources();
        try
        {
            var manager = Path.Combine(source, TaskManager);
            var powershellPath = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
            var parameters = new List<string>
            {
                "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", manager,
                "-Action", action, "-ProtectedSource"
            };
            if (action.Equals("Install", StringComparison.OrdinalIgnoreCase))
            {
                parameters.AddRange(["-CooldownMinutes", preferences.CooldownMinutes.ToString(), "-AutoRepair", preferences.AutoRepair.ToString(),
                    "-ProcessNames", string.Join(',', preferences.ProcessNames)]);
            }
            return await RunProcessAsync(powershellPath, parameters);
        }
        finally
        {
            TryRemoveWindowsSources();
        }
    }

    private static async Task<int> RelaunchElevatedAsync(IReadOnlyList<string> arguments)
    {
        var executable = Environment.ProcessPath ?? throw new IOException("Не удалось определить путь к приложению.");
        return await RunElevatedWindowsAsync(executable, arguments);
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint clientProcessId);

    #pragma warning disable CA1416
    private static async Task<int> RunElevatedWindowsAsync(string executable, IReadOnlyList<string> arguments)
    {
        var pipeId = Guid.NewGuid().ToString("N");
        var security = new PipeSecurity();
        using var identity = WindowsIdentity.GetCurrent();
        security.SetAccessRuleProtection(true, false);
        security.AddAccessRule(new PipeAccessRule(identity.User!, PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            PipeAccessRights.ReadWrite, AccessControlType.Allow));
        using var pipe = NamedPipeServerStreamAcl.Create("RobloxCDNAutoFix-" + pipeId, PipeDirection.In, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.FirstPipeInstance, 4096, 4096, security);
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden
        };
        foreach (var argument in arguments)
            start.ArgumentList.Add(argument);
        start.ArgumentList.Add("--output-pipe");
        start.ArgumentList.Add(pipeId);
        WriteLine("Ожидание подтверждения прав администратора…");
        using var process = Process.Start(start) ?? throw new IOException("Запрос UAC не запущен.");
        var exitTask = process.WaitForExitAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var connectionTask = pipe.WaitForConnectionAsync(timeout.Token);
        if (await Task.WhenAny(connectionTask, exitTask) == exitTask && !pipe.IsConnected)
            throw new IOException($"Не удалось получить журнал операции. Код завершения: {process.ExitCode}.");
        try
        {
            await connectionTask;
        }
        catch (OperationCanceledException)
        {
            throw new IOException("Не удалось подключить журнал операции. Проверь системный Console.log приложения.");
        }
        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var clientId) || clientId != process.Id)
            throw new IOException("Не удалось подтвердить источник журнала операции.");
        using var reader = new StreamReader(pipe, Encoding.UTF8);
        while (await reader.ReadLineAsync() is { } line)
            Console.WriteLine(line);
        await exitTask;
        return process.ExitCode;
    }
    #pragma warning restore CA1416

    private static void AssertNoLink(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var current = new DirectoryInfo(Path.GetDirectoryName(fullPath)!);
        while (current is not null)
        {
            if (current.Exists && (current.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Обнаружена ссылка/junction: " + current.FullName);
            current = current.Parent;
        }
        if ((File.Exists(fullPath) || Directory.Exists(fullPath)) &&
            (File.GetAttributes(fullPath) & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Файл или каталог является ссылкой: " + fullPath);
    }

    private static Stream OpenEmbeddedScript(string fileName)
    {
        var resourceName = "RobloxCDNAutoFix." + fileName;
        return Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName)
            ?? throw new IOException("Встроенный ресурс не найден: " + fileName);
    }

    #pragma warning disable CA1416
    private static void AssertWindowsProtectedPath(string path)
    {
        if (!IsWindows)
            throw new PlatformNotSupportedException("Защищённая Windows-папка доступна только в Windows.");
        AssertNoLink(path);
        if (!Directory.Exists(path) && !File.Exists(path))
            throw new DirectoryNotFoundException(path);

        FileSystemSecurity security = Directory.Exists(path)
            ? new DirectoryInfo(path).GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner)
            : new FileInfo(path).GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner);
        var owner = security.GetOwner(typeof(SecurityIdentifier))?.Value;
        var trusted = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "S-1-5-18",
            "S-1-5-32-544",
            "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"
        };
        if (owner is null || !trusted.Contains(owner))
            throw new UnauthorizedAccessException("Недоверенный владелец защищённой папки: " + path);

        var writeMask = FileSystemRights.Write | FileSystemRights.Delete | FileSystemRights.ChangePermissions |
            FileSystemRights.TakeOwnership | FileSystemRights.DeleteSubdirectoriesAndFiles;
        foreach (var rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)).OfType<FileSystemAccessRule>())
        {
            if (rule.AccessControlType == AccessControlType.Allow && !trusted.Contains(rule.IdentityReference.Value) &&
                ((rule.FileSystemRights & writeMask) != 0 ||
                 (rule.FileSystemRights & FileSystemRights.FullControl) == FileSystemRights.FullControl))
                throw new UnauthorizedAccessException("Небезопасные права записи: " + path);
        }
    }

    private static void EnsureWindowsProtectedDirectory(string path)
    {
        AssertNoLink(path);
        if (Directory.Exists(path))
        {
            AssertWindowsProtectedPath(path);
            return;
        }

        var security = new DirectorySecurity();
        security.SetSecurityDescriptorSddlForm("O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)");
        new DirectoryInfo(path).Create(security);
        AssertWindowsProtectedPath(path);
    }

    private static string EnsureWindowsSources()
    {
        try
        {
            if (!IsWindows || !IsAdministrator())
                throw new UnauthorizedAccessException("Для Windows-операции нужны права администратора.");
            var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            if (string.IsNullOrWhiteSpace(programFiles))
                throw new IOException("Не удалось определить Program Files.");
            AssertNoLink(programFiles);
            EnsureWindowsProtectedDirectory(WindowsInstallRoot);
            EnsureWindowsProtectedDirectory(WindowsSourceDirectory);

            var expected = new HashSet<string>(EmbeddedWindowsScripts, StringComparer.OrdinalIgnoreCase);
            foreach (var existing in Directory.EnumerateFileSystemEntries(WindowsSourceDirectory))
            {
                AssertNoLink(existing);
                if (!expected.Contains(Path.GetFileName(existing)))
                    throw new IOException("В защищённой staging-папке найден неожиданный файл: " + existing);
            }

            foreach (var name in EmbeddedWindowsScripts)
            {
                var target = Path.Combine(WindowsSourceDirectory, name);
                var temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
                AssertNoLink(target);
                AssertNoLink(temporary);
                try
                {
                    using (var source = OpenEmbeddedScript(name))
                    using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        source.CopyTo(output);
                        output.Flush(true);
                    }
                    AssertWindowsProtectedPath(temporary);
                    File.Move(temporary, target, true);
                    AssertNoLink(target);
                    AssertWindowsProtectedPath(target);
                }
                finally
                {
                    if (File.Exists(temporary))
                        File.Delete(temporary);
                }
            }
            return WindowsSourceDirectory;
        }
        catch (Exception exception)
        {
            TryWriteWindowsDiagnostic("EnsureWindowsSources: " + exception.Message);
            throw;
        }
    }

    private static void TryRemoveWindowsSources()
    {
        try
        {
            if (!Directory.Exists(WindowsSourceDirectory))
                return;
            AssertWindowsProtectedPath(WindowsSourceDirectory);
            foreach (var name in EmbeddedWindowsScripts)
            {
                var file = Path.Combine(WindowsSourceDirectory, name);
                if (File.Exists(file))
                {
                    AssertWindowsProtectedPath(file);
                    File.Delete(file);
                }
            }
            if (!Directory.EnumerateFileSystemEntries(WindowsSourceDirectory).Any())
                Directory.Delete(WindowsSourceDirectory);
        }
        catch (Exception exception)
        {
            WriteLine("Не удалось удалить временную защищённую staging-папку: " + exception.Message, ConsoleColor.Yellow);
        }
    }
    #pragma warning restore CA1416

    private static async Task<int> RunProcessAsync(string executable, IReadOnlyList<string> arguments)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var argument in arguments)
            info.ArgumentList.Add(argument);
        return await RunProcessAsync(info);
    }

    private static async Task<int> RunProcessAsync(ProcessStartInfo info)
    {
        if (!info.UseShellExecute)
        {
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.StandardOutputEncoding = Encoding.UTF8;
            info.StandardErrorEncoding = Encoding.UTF8;
        }
        using var process = new Process { StartInfo = info };
        process.Start();
        var outputTask = info.RedirectStandardOutput ? ForwardOutputAsync(process.StandardOutput) : Task.CompletedTask;
        var errorTask = info.RedirectStandardError ? process.StandardError.ReadToEndAsync() : Task.FromResult(string.Empty);
        await process.WaitForExitAsync();
        await outputTask;
        var error = await errorTask;
        if (process.ExitCode != 0)
        {
            var detail = error.Trim();
            throw new IOException($"{Path.GetFileName(info.FileName)} завершился с кодом {process.ExitCode}." +
                (detail.Length == 0 ? string.Empty : " " + detail));
        }
        if (!string.IsNullOrWhiteSpace(error))
            Console.Error.Write(error);
        return process.ExitCode;
    }

    private static async Task ForwardOutputAsync(StreamReader reader)
    {
        while (await reader.ReadLineAsync() is { } line)
            Console.WriteLine(line);
    }

    private static void ApplyOverrides(Preferences preferences, string[] args)
    {
        for (var index = 1; index + 1 < args.Length; index++)
        {
            switch (args[index])
            {
                case "--cooldown" when int.TryParse(args[index + 1], out var cooldown):
                    preferences.CooldownMinutes = Math.Clamp(cooldown, 1, 1440);
                    index++;
                    break;
                case "--auto-repair" when bool.TryParse(args[index + 1], out var autoRepair):
                    preferences.AutoRepair = autoRepair;
                    index++;
                    break;
                case "--process-names":
                    preferences.ProcessNames = ValidateProcessNames(args[index + 1].Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries));
                    index++;
                    break;
            }
        }
    }

    private static Preferences LoadPreferences()
    {
        try
        {
            var path = UserSettingsPath;
            if (File.Exists(path))
            {
                var preferences = JsonSerializer.Deserialize<Preferences>(File.ReadAllText(path));
                if (preferences is not null)
                {
                    preferences.CooldownMinutes = Math.Clamp(preferences.CooldownMinutes, 1, 1440);
                    preferences.ProcessNames = ValidateProcessNames(preferences.ProcessNames);
                    return preferences;
                }
            }
        }
        catch { }
        return new Preferences();
    }

    private static string[] ValidateProcessNames(string[]? names)
    {
        var validated = (names ?? [])
            .Where(name => Regex.IsMatch(name, "^[A-Za-z0-9_.-]{1,80}$"))
            .Select(name => name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? name[..^4] : name)
            .Where(name => Regex.IsMatch(name, "^[A-Za-z0-9_.-]{1,80}$"))
            .Distinct(StringComparer.OrdinalIgnoreCase).Take(8).ToArray();
        return validated.Length > 0 ? validated : ["RobloxPlayer", "RobloxPlayerBeta", "RobloxPlayerLauncher"];
    }

    private static void SavePreferences(Preferences preferences)
    {
        Directory.CreateDirectory(UserConfigDirectory);
        var temp = UserSettingsPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            JsonSerializer.Serialize(stream, preferences, JsonOptions);
            stream.Flush(true);
        }
        File.Move(temp, UserSettingsPath, true);
    }

    private static void TryWriteWindowsDiagnostic(string message)
    {
        if (!IsWindows || !IsAdministrator())
            return;
        try
        {
            var dataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "RobloxCDNAutoFix-Secure");
            if (!Directory.Exists(dataDirectory))
                return;
            AssertWindowsProtectedPath(dataDirectory);
            var path = Path.Combine(dataDirectory, "Console.log");
            var archive = path + ".1";
            AssertNoLink(path);
            AssertNoLink(archive);
            if (File.Exists(path))
                AssertWindowsProtectedPath(path);
            if (File.Exists(archive))
                AssertWindowsProtectedPath(archive);
            if (File.Exists(path) && new FileInfo(path).Length >= 1024 * 1024)
            {
                if (File.Exists(archive))
                    File.Delete(archive);
                File.Move(path, archive);
            }
            File.AppendAllText(path, $"[{DateTime.UtcNow:O}] {message}{Environment.NewLine}", new UTF8Encoding(false));
        }
        catch { }
    }

    #pragma warning disable CA1416
    private static bool IsAdministrator()
    {
        if (IsWindows)
        {
            using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
            return new System.Security.Principal.WindowsPrincipal(identity)
                .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        }
        return false;
    }
    #pragma warning restore CA1416

    private static int ReadInt(string prompt, int current, int minimum, int maximum)
    {
        Console.Write($"  {prompt} [{current}] › ");
        if (int.TryParse(Console.ReadLine(), out var value) && value >= minimum && value <= maximum)
            return value;
        return current;
    }

    private static bool AskYesNo(string prompt)
    {
        Console.Write($"  {prompt} [y/N] › ");
        return Console.ReadLine()?.Trim().Equals("y", StringComparison.OrdinalIgnoreCase) == true;
    }

    private static void PrintHelp()
    {
        Console.WriteLine("""
            Roblox CDN AutoFix • Tempest

            Usage:
              windows-x64.exe             Open interactive console
              windows-x64.exe check      Check CDN; repair if needed
              windows-x64.exe fix        Find a working CDN address and update hosts
              windows-x64.exe reset      Remove only the managed hosts block
              windows-x64.exe monitor install  Install or update monitoring
              windows-x64.exe monitor remove   Remove monitoring
              windows-x64.exe monitor status   Show monitoring status
              windows-x64.exe status    Show monitoring status
              windows-x64.exe settings  Configure the product
              windows-x64.exe info      Browse feature descriptions and examples

            Windows releases embed the protected Task Scheduler setup scripts in the single executable.
            """);
    }

    private static void Pause()
    {
        Console.WriteLine();
        Console.Write("  Нажми Enter, чтобы продолжить…");
        Console.ReadLine();
    }

    private static void WriteLine(string text, ConsoleColor? color = null)
    {
        if (color is not null)
            Console.ForegroundColor = color.Value;
        Console.WriteLine("  " + text);
        Console.ResetColor();
    }

    private static ConsoleColor AccentColor(string theme) =>
        theme switch { "amber" => ConsoleColor.Yellow, "mono" => ConsoleColor.Gray, _ => ConsoleColor.Cyan };

    private static void SetTheme(string theme) => Console.ForegroundColor = AccentColor(theme);
}
