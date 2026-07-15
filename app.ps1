#Requires -Version 5.1

<#
.SYNOPSIS
    Менеджер СУБД в трее — запуск и остановка локальных служб СУБД из системного трея.

.DESCRIPTION
    Резидентное приложение без главного окна: живёт только как иконка в системном трее
    Windows. По правой кнопке мыши открывается вложенное меню, построенное по справочнику
    СУБД: для каждой СУБД — «Запустить», «Остановить» и строка-индикатор состояния.

    Один файл, четыре режима работы:
      * без параметров             — резидентная иконка в трее;
      * -Action Start|Stop|StopAll — выполнение команды в отдельном окне PowerShell (§5.3);
      * -InstallAutostart          — регистрация автозапуска в Планировщике задач (§7);
      * -CreateShortcut            — ярлык на рабочем столе для запуска двойным щелчком.

    Внешних зависимостей и установщика нет.

    Консоли пользователь не видит никогда: трей всегда уезжает в собственный
    скрытый процесс, а окно консоли этого процесса прячется через ShowWindow.

.PARAMETER Action
    Служебный режим. Приложение вызывает само себя с этим параметром, чтобы выполнить
    команду в новом окне PowerShell — окно и есть канал обратной связи для пользователя.

.PARAMETER Database
    Имя СУБД из справочника (для -Action Start|Stop).

.PARAMETER InstallAutostart
    Регистрирует задачу в Планировщике: «При входе в систему» + «Выполнять с наивысшими
    правами», то есть автозапуск с правами администратора и без запроса UAC.

.PARAMETER UninstallAutostart
    Удаляет задачу автозапуска.

.PARAMETER CreateShortcut
    Создаёт на рабочем столе ярлык для запуска двойным щелчком: сам файл .ps1
    по двойному клику Windows не запускает, а открывает в редакторе.

.EXAMPLE
    powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Program Files\TrayDB\app.ps1"
    Штатный запуск: иконка появляется в трее, окон не создаётся.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\TrayDB\app.ps1" -InstallAutostart
    Разовая настройка автозапуска при входе в Windows.
#>

[CmdletBinding()]
param(
    [ValidateSet('Start', 'Stop', 'StopAll')]
    [string] $Action,

    # Имя параметра не сокращаем: -Db конфликтует с алиасом общего параметра -Debug.
    [string] $Database,

    [switch] $InstallAutostart,

    [switch] $UninstallAutostart,

    [switch] $CreateShortcut
)

Set-StrictMode -Version 3.0


# =============================================================================
#  СПРАВОЧНИК СУБД (§4)
#
#  Формат: 'Имя в меню' = @(службы в порядке запуска)
#
#  Добавление новой СУБД — дописать одну строку. Меню, индикаторы, кнопки и
#  «Остановить всё» перестраиваются автоматически; остановка всегда выполняется
#  в обратном порядке относительно запуска.
# =============================================================================
$Script:Databases = [ordered]@{
    'SQL Server' = @('MSSQLSERVER')
    'Oracle' = @('OracleOraDB21Home1TNSListener', 'OracleServiceORCL')
    'PostgreSQL' = @('postgresql-x64-17')
}


# =============================================================================
#  ПАРАМЕТРЫ ПРИЛОЖЕНИЯ
# =============================================================================
$Script:AppTitle       = 'Менеджер СУБД'
$Script:TaskName       = 'TrayDB.DatabaseServiceManager'
$Script:LegacyTaskName = 'TrayDB'
$Script:PollIntervalMs = 2500                                    # §5.5: опрос ~2–3 с
$Script:ScriptPath     = $PSCommandPath
$Script:CurrentUser    = [Security.Principal.WindowsIdentity]::GetCurrent().Name


# =============================================================================
#  ОБЩИЕ ФУНКЦИИ
# =============================================================================

function Test-Administrator {
    <# Запущен ли текущий процесс с правами администратора (§3). #>
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $identity
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Reversed {
    <# Копия списка в обратном порядке (§4: остановка — обратный порядок запуска). #>
    param([object[]] $Items)

    $reversed = [object[]] $Items.Clone()
    [array]::Reverse($reversed)
    , $reversed
}

function Wait-ServiceStatus {
    <#
        Ждёт конечного состояния службы с ограничением по времени.
        Возвращает $true при успехе и $false при тайм-ауте или исчезновении службы.
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Running', 'Stopped')] [string] $DesiredStatus,
        [int] $TimeoutSeconds = 60
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $service) { return $false }
        if ([string] $service.Status -eq $DesiredStatus) { return $true }
        Start-Sleep -Milliseconds 500
    }
    while ([DateTime]::UtcNow -lt $deadline)

    return $false
}

function New-AppIcon {
    <#
        Иконка приложения: цилиндр базы данных. Рисуется кодом — §6, без внешних
        файлов и библиотек. Используется и иконкой в трее, и ярлыком.
    #>
    Add-Type -AssemblyName System.Drawing                          # идемпотентно

    $bitmap   = New-Object System.Drawing.Bitmap -ArgumentList 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $body = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb( 64, 156, 219))
    $top  = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(126, 200, 245))
    $edge = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(24, 92, 138)), 1.6

    $graphics.FillRectangle($body, 4, 8, 24, 14)                   # боковина
    $graphics.FillEllipse($body, 4, 18, 24, 9)                     # донышко
    $graphics.FillEllipse($top,  4,  4, 24, 9)                     # крышка

    $graphics.DrawArc($edge, 4, 18, 24, 9, 0, 180)
    $graphics.DrawArc($edge, 4, 11, 24, 9, 0, 180)                 # средняя «полка»
    $graphics.DrawLine($edge, 4, 8, 4, 22)
    $graphics.DrawLine($edge, 28, 8, 28, 22)
    $graphics.DrawEllipse($edge, 4, 4, 24, 9)

    $icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())

    $edge.Dispose(); $top.Dispose(); $body.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    $icon
}

function Get-DbState {
    <#
        Сводное состояние СУБД по её службам (§5.4):
          Running — все службы Running;
          Partial — часть Running, часть нет;
          Stopped — ни одна не Running;
          Failed  — служба не найдена в системе или в сбойном состоянии.
    #>
    param([string[]] $ServiceNames)

    $running = 0
    foreach ($name in $ServiceNames) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $service) { return 'Failed' }                    # службы нет в системе

        $status = [string] $service.Status
        if ($status -like 'Paused*' -or $status -eq 'ContinuePending') { return 'Failed' }
        if ($status -eq 'Running') { $running++ }
    }

    if ($running -eq $ServiceNames.Count) { return 'Running' }
    if ($running -eq 0)                   { return 'Stopped' }
    return 'Partial'
}


# =============================================================================
#  РЕЖИМ «ДЕЙСТВИЕ» (§5.3)
#
#  Выполняется в отдельном окне PowerShell, открытом с флагом -NoExit: окно
#  остаётся на экране и показывает пользователю сами команды, их вывод и итог.
#  Права администратора наследуются от процесса-родителя, UAC не запрашивается.
# =============================================================================

function Disable-ConsoleQuickEdit {
    <#
        Выключает QuickEdit в этом окне.

        По умолчанию в консоли Windows он включён: клик внутрь окна переводит её
        в режим выделения («Выбрать» в заголовке) и БЛОКИРУЕТ вывод процесса.
        Для окна §5.3 это опасно — случайный клик замораживает скрипт между
        двумя Start-Service, и СУБД остаётся поднятой наполовину.
    #>
    if (-not ('TrayDb.ConsoleMode' -as [type])) {
        Add-Type -Namespace 'TrayDb' -Name 'ConsoleMode' -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern IntPtr GetStdHandle(int nStdHandle);

[DllImport("kernel32.dll")]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

[DllImport("kernel32.dll")]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
    }

    $QUICK_EDIT    = 0x0040
    $EXTENDED_FLAG = 0x0080                                       # без него QuickEdit не снять
    $STD_INPUT     = -10

    $handle = [TrayDb.ConsoleMode]::GetStdHandle($STD_INPUT)
    [uint32] $mode = 0
    if ([TrayDb.ConsoleMode]::GetConsoleMode($handle, [ref] $mode)) {
        $updated = [uint32] ((($mode -band (-bnot $QUICK_EDIT)) -bor $EXTENDED_FLAG) -band 0xFFFF)
        [void] [TrayDb.ConsoleMode]::SetConsoleMode($handle, $updated)
    }
}

function Invoke-DbAction {
    param(
        [ValidateSet('Start', 'Stop', 'StopAll')] [string] $Mode,
        [string] $DbName
    )

    # Иначе случайный клик в окно заморозит запуск на середине.
    Disable-ConsoleQuickEdit

    $isStop = $Mode -ne 'Start'

    if ($Mode -eq 'StopAll') {
        $targets = Get-Reversed -Items @($Script:Databases.Keys)  # §4: обратный порядок
    }
    else {
        if (-not $Script:Databases.Contains($DbName)) {
            Write-Host "Неизвестная СУБД: '$DbName'" -ForegroundColor Red
            return
        }
        $targets = @($DbName)
    }

    $title = if ($Mode -eq 'StopAll') { 'остановить всё' }
             elseif ($isStop)         { "остановить $DbName" }
             else                     { "запустить $DbName" }
    $Host.UI.RawUI.WindowTitle = '{0} — {1}' -f $Script:AppTitle, $title

    foreach ($name in $targets) {
        $services = @($Script:Databases[$name])
        if ($isStop) { $services = Get-Reversed -Items $services }

        Write-Host ''
        Write-Host ('=== {0}: {1} ===' -f $name, $(if ($isStop) { 'остановка' } else { 'запуск' })) -ForegroundColor Cyan

        foreach ($service in $services) {
            $current = Get-Service -Name $service -ErrorAction SilentlyContinue
            if (-not $current) {
                Write-Host "  Служба '$service' не найдена в системе." -ForegroundColor Red
                continue
            }

            $desiredStatus = if ($isStop) { 'Stopped' } else { 'Running' }
            if ([string] $current.Status -eq $desiredStatus) {
                Write-Host "  $service уже имеет состояние $desiredStatus." -ForegroundColor DarkGray
                continue
            }

            try {
                if ($isStop) {
                    Write-Host "> Stop-Service -Name '$service' -Force" -ForegroundColor DarkGray
                    Stop-Service -Name $service -Force -ErrorAction Stop
                }
                else {
                    Write-Host "> Start-Service -Name '$service'" -ForegroundColor DarkGray
                    Start-Service -Name $service -ErrorAction Stop
                }

                Write-Host "  Ожидание состояния $desiredStatus, не более 60 секунд..." -ForegroundColor DarkGray
                if (Wait-ServiceStatus -Name $service -DesiredStatus $desiredStatus -TimeoutSeconds 60) {
                    Write-Host "  ${service}: $desiredStatus" -ForegroundColor Green
                }
                else {
                    $latest = Get-Service -Name $service -ErrorAction SilentlyContinue
                    $latestStatus = if ($latest) { [string] $latest.Status } else { 'не найдена' }
                    Write-Host "  Тайм-аут: ожидалось $desiredStatus, текущее состояние: $latestStatus." -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "  Ошибка управления службой '$service': $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # Итог по каждой службе: пользователь видит успех или проблему (§5.3)
    Write-Host ''
    Write-Host 'Итоговое состояние служб:' -ForegroundColor Cyan
    foreach ($name in $targets) {
        foreach ($service in @($Script:Databases[$name])) {
            $current = Get-Service -Name $service -ErrorAction SilentlyContinue
            if ($current) {
                $color = if ([string] $current.Status -eq 'Running') { 'Green' } else { 'Yellow' }
                Write-Host ('  {0,-38} {1}' -f $service, $current.Status) -ForegroundColor $color
            }
            else {
                Write-Host ('  {0,-38} НЕ НАЙДЕНА В СИСТЕМЕ' -f $service) -ForegroundColor Red
            }
        }
    }
    Write-Host ''
}

if ($Action) {
    Invoke-DbAction -Mode $Action -DbName $Database
    return
}


# =============================================================================
#  РЕЖИМ «АВТОЗАПУСК» (§7)
#
#  Задача Планировщика: триггер «При входе в систему», опция «Выполнять с
#  наивысшими правами» — права администратора без запроса UAC при каждом входе.
# =============================================================================

function Install-Autostart {
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Script:ScriptPath

    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
    $trigger    = New-ScheduledTaskTrigger -AtLogOn -User $Script:CurrentUser
    $principal  = New-ScheduledTaskPrincipal -UserId $Script:CurrentUser `
                                             -LogonType Interactive `
                                             -RunLevel Highest
    $settings   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                               -DontStopIfGoingOnBatteries `
                                               -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $Script:TaskName `
                           -Description $Script:AppTitle `
                           -Action $taskAction `
                           -Trigger $trigger `
                           -Principal $principal `
                           -Settings $settings `
                           -Force | Out-Null

    # Удаляем задачу со старым общим именем, если она осталась от предыдущей версии.
    Get-ScheduledTask -TaskName $Script:LegacyTaskName -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

    Write-Host "Задача автозапуска '$($Script:TaskName)' зарегистрирована." -ForegroundColor Green
    Write-Host "  Скрипт:  $($Script:ScriptPath)"
    Write-Host "  Триггер: при входе пользователя $($Script:CurrentUser), с наивысшими правами."
}

function Uninstall-Autostart {
    $removed = $false
    foreach ($name in @($Script:TaskName, $Script:LegacyTaskName)) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "Задача автозапуска '$name' удалена." -ForegroundColor Green
            $removed = $true
        }
    }

    if (-not $removed) {
        Write-Host 'Задача автозапуска не найдена - удалять нечего.' -ForegroundColor Yellow
    }
}

if ($InstallAutostart -or $UninstallAutostart) {
    if (-not (Test-Administrator)) {
        Write-Host 'Нужны права администратора: запустите PowerShell «от имени администратора».' -ForegroundColor Red
        return
    }
    if ($InstallAutostart) { Install-Autostart } else { Uninstall-Autostart }
    return
}


# =============================================================================
#  РЕЖИМ «ЯРЛЫК»
#
#  Windows не запускает .ps1 по двойному щелчку — открывает его в редакторе.
#  Ярлык на powershell.exe с нужными флагами эту дырку закрывает.
# =============================================================================

function New-DesktopShortcut {
    # Иконка рядом со скриптом: иначе ярлык выглядит как консоль PowerShell.
    # Папка может быть недоступна на запись (например, Program Files) — тогда
    # просто оставим иконку PowerShell, это не повод падать.
    $iconPath = Join-Path (Split-Path -Parent $Script:ScriptPath) 'app.ico'
    if (-not (Test-Path $iconPath)) {
        try {
            $icon   = New-AppIcon
            $stream = [System.IO.File]::Create($iconPath)
            $icon.Save($stream)
            $stream.Close()
            $icon.Dispose()
        }
        catch {
            Write-Host "Иконку сохранить не удалось ($($_.Exception.Message))." -ForegroundColor Yellow
            Write-Host 'Ярлык будет с иконкой PowerShell.' -ForegroundColor Yellow
            $iconPath = $null
        }
    }

    $linkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ('{0}.lnk' -f $Script:AppTitle)
    $shell    = New-Object -ComObject WScript.Shell
    $link     = $shell.CreateShortcut($linkPath)

    $link.TargetPath       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $link.Arguments        = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Script:ScriptPath
    $link.WorkingDirectory = Split-Path -Parent $Script:ScriptPath
    $link.Description      = $Script:AppTitle
    $link.WindowStyle      = 7                                     # 7 = свёрнутое окно
    if ($iconPath) { $link.IconLocation = $iconPath }
    $link.Save()

    Write-Host "Ярлык создан: $linkPath" -ForegroundColor Green
    Write-Host 'Двойной щелчок по нему — приложение уходит в трей. Ярлык можно перетащить куда угодно.'
}

if ($CreateShortcut) {
    New-DesktopShortcut
    return
}


# =============================================================================
#  РЕЖИМ «ТРЕЙ» — основной (§5)
# =============================================================================

function Test-DedicatedHost {
    <#
        Проверяет, был ли текущий powershell.exe запущен именно с этим app.ps1
        через параметр -File. Сравнивается полный нормализованный путь, поэтому
        другой файл с таким же именем не будет ошибочно принят за наш процесс.
    #>
    try {
        $commandLine = [Environment]::CommandLine
        $escapedPath = [Regex]::Escape([IO.Path]::GetFullPath($Script:ScriptPath))
        return $commandLine -match ('(?i)(?:-File\s+)(?:"{0}"|{0})(?:\s|$)' -f $escapedPath)
    }
    catch {
        return $false
    }
}

function Hide-ConsoleWindow {
    <#
        Прячет окно консоли текущего процесса.

        Application.Run() держит процесс живым до «Выхода», а вместе с ним на
        экране висела бы и консоль. Одного -WindowStyle Hidden мало: при запуске
        двойным кликом окно создаётся раньше, чем флаг успевает сработать.
    #>
    if (-not ('TrayDb.Native' -as [type])) {
        Add-Type -Namespace 'TrayDb' -Name 'Native' -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern IntPtr GetConsoleWindow();

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    }

    $console = [TrayDb.Native]::GetConsoleWindow()
    if ($console -ne [IntPtr]::Zero) {
        [void] [TrayDb.Native]::ShowWindow($console, 0)               # 0 = SW_HIDE
    }
}

# Трею нужен собственный скрытый процесс с правами администратора:
#   * нет прав (§3)         — перезапуск с повышением, один запрос UAC;
#   * процесс не наш        — перезапуск, иначе Application.Run() заблокирует
#                             чужую консоль и она повиснет на экране до «Выхода».
# Дочерний процесс получает -File, поэтому проверку проходит и зациклиться не может.
if (-not (Test-Administrator) -or -not (Test-DedicatedHost)) {
    $launch = @{
        FilePath     = 'powershell.exe'
        ArgumentList = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script:ScriptPath`"")
    }
    if (-not (Test-Administrator)) { $launch.Verb = 'RunAs' }         # иначе права наследуются

    try {
        Start-Process @launch
    }
    catch [System.ComponentModel.Win32Exception] {
        # 1223 = ERROR_CANCELLED: пользователь отклонил UAC. Это осознанный выбор,
        # молчим. Всё остальное — настоящая поломка, и молчать о ней нельзя:
        # консоли у нас нет, поэтому говорим единственным доступным способом.
        if ($_.Exception.NativeErrorCode -ne 1223) {
            Add-Type -AssemblyName System.Windows.Forms
            [void] [System.Windows.Forms.MessageBox]::Show(
                "Не удалось запустить с правами администратора:`n`n$($_.Exception.Message)",
                $Script:AppTitle,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }
    catch {
        Add-Type -AssemblyName System.Windows.Forms
        [void] [System.Windows.Forms.MessageBox]::Show(
            "Не удалось запустить приложение:`n`n$($_.Exception.Message)",
            $Script:AppTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    return
}

# Защита от повторного запуска: один экземпляр TrayDB на пользователя.
$createdNew = $false
$userSid    = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutexName  = 'Local\TrayDB-{0}' -f $userSid
$Script:InstanceMutex = [System.Threading.Mutex]::new($true, $mutexName, [ref] $createdNew)
if (-not $createdNew) {
    $Script:InstanceMutex.Dispose()
    return
}

Hide-ConsoleWindow

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()


# -----------------------------------------------------------------------------
#  Таблица состояний: цвет точки и подпись (§5.4) + активность кнопок (§5.6)
# -----------------------------------------------------------------------------
$Script:States = @{
    Running = @{ Label = 'работает';                Color = [System.Drawing.Color]::FromArgb( 46, 160,  67); CanStart = $false; CanStop = $true  }
    Partial = @{ Label = 'частично запущена';       Color = [System.Drawing.Color]::FromArgb(230, 170,  30); CanStart = $true;  CanStop = $true  }
    Stopped = @{ Label = 'остановлена';             Color = [System.Drawing.Color]::FromArgb(150, 150, 150); CanStart = $true;  CanStop = $false }
    Failed  = @{ Label = 'ошибка / не установлена'; Color = [System.Drawing.Color]::FromArgb(215,  58,  73); CanStart = $false; CanStop = $false }
}

$Script:AutostartStates = @{
    Enabled  = @{ Label = 'включён';  Color = [System.Drawing.Color]::FromArgb( 46, 160,  67); CanEnable = $false; CanDisable = $true  }
    Disabled = @{ Label = 'выключен'; Color = [System.Drawing.Color]::FromArgb(150, 150, 150); CanEnable = $true;  CanDisable = $false }
    Failed   = @{ Label = 'ошибка';   Color = [System.Drawing.Color]::FromArgb(215,  58,  73); CanEnable = $true;  CanDisable = $true  }
}


# -----------------------------------------------------------------------------
#  Графика: рисуется кодом — §6, без внешних файлов и библиотек
# -----------------------------------------------------------------------------

function New-StatusDot {
    <# Цветная точка 16×16 для строки-индикатора (§5.4). #>
    param([System.Drawing.Color] $Color)

    $bitmap   = New-Object System.Drawing.Bitmap -ArgumentList 16, 16
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $fill    = New-Object System.Drawing.SolidBrush -ArgumentList $Color
    $outline = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(70, 0, 0, 0)), 1
    $graphics.FillEllipse($fill, 3, 3, 10, 10)
    $graphics.DrawEllipse($outline, 3, 3, 10, 10)

    $outline.Dispose(); $fill.Dispose(); $graphics.Dispose()
    $bitmap
}

foreach ($key in @($Script:States.Keys)) {
    $Script:States[$key].Dot = New-StatusDot -Color $Script:States[$key].Color
}

foreach ($key in @($Script:AutostartStates.Keys)) {
    $Script:AutostartStates[$key].Dot = New-StatusDot -Color $Script:AutostartStates[$key].Color
}


# -----------------------------------------------------------------------------
#  Опрос состояния: ленивый и «живой» (§5.5)
# -----------------------------------------------------------------------------

$Script:Ui        = @{}      # имя СУБД -> @{ Start; Stop; Status }
$Script:LastState = @{}      # имя СУБД -> последнее показанное состояние
$Script:ActiveDb  = $null    # СУБД, чьё подменю открыто прямо сейчас

function Update-DbStatus {
    <# Перерисовка только при смене состояния — без мерцания (§5.5). #>
    param([string] $DbName, [switch] $Force)

    if (-not $DbName) { return }

    $state = Get-DbState -ServiceNames $Script:Databases[$DbName]
    if (-not $Force -and $Script:LastState[$DbName] -eq $state) { return }
    $Script:LastState[$DbName] = $state

    $info = $Script:States[$state]
    $ui   = $Script:Ui[$DbName]

    $ui.Status.Image  = $info.Dot                                # §5.4
    $ui.Status.Text   = $info.Label
    $ui.Start.Enabled = $info.CanStart                           # §5.6
    $ui.Stop.Enabled  = $info.CanStop
}

function Start-Watch {
    <# Подменю открылось: сразу показать состояние и включить таймер. #>
    param([string] $DbName)

    $Script:ActiveDb = $DbName
    Update-DbStatus -DbName $DbName -Force
    $Script:Timer.Start()
}

function Stop-Watch {
    <# Подменю закрылось / курсор ушёл: опрос прекращается — нулевая нагрузка. #>
    param([string] $DbName)

    if ($Script:ActiveDb -eq $DbName) {
        $Script:Timer.Stop()
        $Script:ActiveDb = $null
    }
}

$Script:Timer          = New-Object System.Windows.Forms.Timer
$Script:Timer.Interval = $Script:PollIntervalMs
$Script:Timer.Add_Tick({ Update-DbStatus -DbName $Script:ActiveDb })


# -----------------------------------------------------------------------------
#  Запуск команды в отдельном окне PowerShell (§5.3)
# -----------------------------------------------------------------------------

function Start-DbWindow {
    param(
        [ValidateSet('Start', 'Stop', 'StopAll')] [string] $Mode,
        [string] $DbName
    )

    # -NoExit: окно остаётся открытым, пользователь видит команду и её вывод.
    # Права администратора новое окно наследует от этого процесса — UAC не появится.
    $arguments = @('-NoProfile', '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script:ScriptPath`"", '-Action', $Mode)
    if ($DbName) { $arguments += @('-Database', "`"$DbName`"") }

    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments
}


# -----------------------------------------------------------------------------
#  Автозапуск в меню
# -----------------------------------------------------------------------------

function Get-AutostartState {
    try {
        foreach ($name in @($Script:TaskName, $Script:LegacyTaskName)) {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            if ($task -and [string] $task.State -ne 'Disabled') { return 'Enabled' }
        }
        return 'Disabled'
    }
    catch {
        return 'Failed'
    }
}

function Update-AutostartStatus {
    $state = Get-AutostartState
    $info  = $Script:AutostartStates[$state]

    $Script:AutostartUi.Status.Image  = $info.Dot
    $Script:AutostartUi.Status.Text   = $info.Label
    $Script:AutostartUi.Enable.Enabled  = $info.CanEnable
    $Script:AutostartUi.Disable.Enabled = $info.CanDisable
}

function Start-AutostartWindow {
    param([ValidateSet('Install', 'Uninstall')] [string] $Mode)

    $switchName = if ($Mode -eq 'Install') { '-InstallAutostart' } else { '-UninstallAutostart' }
    $arguments = @(
        '-NoProfile',
        '-NoExit',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$Script:ScriptPath`"",
        $switchName
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments
}

# -----------------------------------------------------------------------------
#  Меню: строится из справочника (§5.2)
# -----------------------------------------------------------------------------

$Script:Menu = New-Object System.Windows.Forms.ContextMenuStrip

foreach ($dbName in $Script:Databases.Keys) {

    $startItem = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Запустить'
    $startItem.Tag = $dbName
    $startItem.Add_Click({ Start-DbWindow -Mode 'Start' -DbName $this.Tag })

    $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Остановить'
    $stopItem.Tag = $dbName
    $stopItem.Add_Click({ Start-DbWindow -Mode 'Stop' -DbName $this.Tag })

    # §5.2: строка-индикатор — только информация, не кнопка.
    # ToolStripLabel не подсвечивается, не нажимается и не закрывает меню.
    $statusItem = New-Object System.Windows.Forms.ToolStripLabel
    $statusItem.ImageScaling = [System.Windows.Forms.ToolStripItemImageScaling]::None

    $rootItem = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList $dbName
    [void] $rootItem.DropDownItems.Add($startItem)
    [void] $rootItem.DropDownItems.Add($stopItem)
    [void] $rootItem.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void] $rootItem.DropDownItems.Add($statusItem)

    # §5.5: опрос живёт ровно столько, сколько открыто подменю
    $rootItem.Tag = $dbName
    $rootItem.Add_DropDownOpened({ Start-Watch -DbName $this.Tag })
    $rootItem.Add_DropDownClosed({ Stop-Watch  -DbName $this.Tag })

    $Script:Ui[$dbName] = @{ Start = $startItem; Stop = $stopItem; Status = $statusItem }
    [void] $Script:Menu.Items.Add($rootItem)
}

[void] $Script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$stopAllItem = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Остановить всё'
$stopAllItem.Add_Click({ Start-DbWindow -Mode 'StopAll' })
[void] $Script:Menu.Items.Add($stopAllItem)

$autostartEnableItem = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Включить'
$autostartEnableItem.Add_Click({ Start-AutostartWindow -Mode 'Install' })

$autostartDisableItem = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Выключить'
$autostartDisableItem.Add_Click({ Start-AutostartWindow -Mode 'Uninstall' })

$autostartStatusItem = New-Object System.Windows.Forms.ToolStripLabel
$autostartStatusItem.ImageScaling = [System.Windows.Forms.ToolStripItemImageScaling]::None

$autostartRootItem = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Автозапуск'
[void] $autostartRootItem.DropDownItems.Add($autostartEnableItem)
[void] $autostartRootItem.DropDownItems.Add($autostartDisableItem)
[void] $autostartRootItem.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void] $autostartRootItem.DropDownItems.Add($autostartStatusItem)
$autostartRootItem.Add_DropDownOpened({ Update-AutostartStatus })

$Script:AutostartUi = @{
    Enable  = $autostartEnableItem
    Disable = $autostartDisableItem
    Status  = $autostartStatusItem
}
[void] $Script:Menu.Items.Add($autostartRootItem)

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem -ArgumentList 'Выход'
$exitItem.Add_Click({
    $Script:Timer.Stop()
    $Script:Notify.Visible = $false                              # §5.2: убрать иконку
    $Script:Notify.Dispose()
    $Script:Notify = $null
    if ($Script:InstanceMutex) {
        $Script:InstanceMutex.Dispose()
        $Script:InstanceMutex = $null
    }
    [System.Windows.Forms.Application]::Exit()
})
[void] $Script:Menu.Items.Add($exitItem)

# Страховка: меню закрылось целиком — гарантированно нулевая нагрузка (§5.5, §6)
$Script:Menu.Add_Closed({
    $Script:Timer.Stop()
    $Script:ActiveDb = $null
})


# -----------------------------------------------------------------------------
#  Иконка в трее (§5.1)
# -----------------------------------------------------------------------------

$Script:Notify                  = New-Object System.Windows.Forms.NotifyIcon
$Script:Notify.Icon             = New-AppIcon
$Script:Notify.Text             = $Script:AppTitle                # всплывающая подпись
$Script:Notify.ContextMenuStrip = $Script:Menu
$Script:Notify.Visible          = $true

# §5.1/§6: главного окна нет — только событийный цикл WinForms.
# В простое приложение спит на очереди сообщений: ~0% CPU.
try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    if ($Script:Notify) { $Script:Notify.Dispose() }
    if ($Script:InstanceMutex) { $Script:InstanceMutex.Dispose() }
    foreach ($key in @($Script:States.Keys)) {
        if ($Script:States[$key].Dot) { $Script:States[$key].Dot.Dispose() }
    }
    foreach ($key in @($Script:AutostartStates.Keys)) {
        if ($Script:AutostartStates[$key].Dot) { $Script:AutostartStates[$key].Dot.Dispose() }
    }
}
