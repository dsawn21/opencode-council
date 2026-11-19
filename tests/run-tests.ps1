#Requires -Version 5.1
<#
    Тесты пакета opencode-council.

    Каждый сценарий работает в отдельной песочнице во временной папке,
    поэтому реальный ~/.config/opencode не затрагивается.

    Запуск:
        .\tests\run-tests.ps1
        .\tests\run-tests.ps1 -KeepSandbox

    Скрипт возвращает 0, если всё прошло, и 1, если хоть одна проверка
    упала — этого достаточно для GitHub Actions.

    Дочерние процессы запускаются тем же хостом, в котором работает
    сам тест: под powershell.exe проверяется Windows PowerShell 5.1,
    под pwsh — PowerShell 7. Так один и тот же файл покрывает обе среды.
#>
[CmdletBinding()]
param(
    [string]$Pack = "",
    [switch]$KeepSandbox
)

$ErrorActionPreference = "Stop"

# В Windows PowerShell 5.1 $PSScriptRoot пуст внутри блока param(),
# поэтому путь к пакету вычисляется уже здесь.
if (-not $Pack) { $Pack = Split-Path -Parent $PSScriptRoot }
if (-not $Pack -or -not (Test-Path (Join-Path $Pack "install.ps1"))) {
    throw "Не найден пакет: укажите -Pack <путь к opencode-council>"
}
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
$HostExe    = (Get-Process -Id $PID).Path

$script:Passed = 0
$script:Failed = 0

$Sandbox = Join-Path ([IO.Path]::GetTempPath()) ("council-tests-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))

function Test-That {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Detail = ""
    )
    if ($Condition) {
        $script:Passed++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
    else {
        $script:Failed++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) {
            Write-Host ("        " + ($Detail.Trim() -replace "`r?`n", "`n        ")) -ForegroundColor DarkGray
        }
    }
}

function New-Sandbox {
    param(
        [string]$Name,
        [string]$ConfigJson = ""
    )
    $dir = Join-Path $Sandbox $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ($ConfigJson) {
        [IO.File]::WriteAllText((Join-Path $dir "opencode.json"), $ConfigJson, $Utf8NoBom)
    }
    return $dir
}

function Invoke-Script {
    param(
        [string]$Script,
        [string]$Target,
        [string[]]$Extra = @()
    )
    $childArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $Pack $Script),
        "-Target", $Target
    ) + $Extra

    $output = & $HostExe @childArgs 2>&1 | Out-String
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Count-Backups {
    param([string]$Dir)
    return @(Get-ChildItem $Dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*.bak-*" }).Count
}

$BaseConfig = @"
{
  "`$schema": "https://opencode.ai/config.json",
  "providers": {
    "vyce": { "name": "Vyce AI" }
  },
  "permission": {
    "skill": { "*": "allow" }
  },
  "agents": {
    "build": {
      "permissions": [
        { "action": "shell", "resource": "git push *", "effect": "ask" }
      ]
    }
  }
}
"@

$JsoncConfig = @"
{
  // комментарий, который нельзя потерять
  "`$schema": "https://opencode.ai/config.json",
  "permission": { "skill": { "*": "allow" } }
}
"@

Write-Host ""
Write-Host "opencode-council: тесты" -ForegroundColor Cyan
Write-Host ("пакет:  " + $Pack) -ForegroundColor Gray
Write-Host ("хост:   " + $HostExe) -ForegroundColor Gray
Write-Host ("версия: " + $PSVersionTable.PSVersion.ToString()) -ForegroundColor Gray
Write-Host ("песок:  " + $Sandbox) -ForegroundColor DarkGray
Write-Host ""

New-Item -ItemType Directory -Force -Path $Sandbox | Out-Null

# ---------------------------------------------------------------- 1. состав
Write-Host "1. Состав пакета" -ForegroundColor Cyan

$required = @(
    "install.ps1"
    "uninstall.ps1"
    "lib\JsonText.ps1"
    "README.md"
    "LICENSE"
    "agents\council.md"
    "agents\architect.md"
    "agents\reviewer.md"
    "agents\triage.md"
    "commands\советник.md"
    "commands\plan.md"
    "commands\review.md"
    "commands\triage.md"
)
$missing = @($required | Where-Object { -not (Test-Path (Join-Path $Pack $_)) })
Test-That "все файлы на месте" ($missing.Count -eq 0) ("нет: " + ($missing -join ", "))

# ------------------------------------------------------------- 2. кодировка
Write-Host "2. Кодировка скриптов" -ForegroundColor Cyan

$badBom = @()
Get-ChildItem $Pack -Recurse -File -Include *.ps1 | ForEach-Object {
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    $hasBom = ($bytes.Count -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
    if (-not $hasBom) { $badBom += $_.FullName.Replace($Pack, "").TrimStart("\") }
}
Test-That "все .ps1 сохранены в UTF-8 с BOM" ($badBom.Count -eq 0) ("без BOM: " + ($badBom -join ", "))

# ---------------------------------------------------------- 3. шапки файлов
Write-Host "3. Шапки агентов и команд" -ForegroundColor Cyan

foreach ($id in @("council", "architect", "reviewer", "triage")) {
    $path = Join-Path $Pack "agents\$id.md"
    $text = ""
    if (Test-Path $path) { $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }

    Test-That "agents\$id.md имеет mode" ($text -match "(?m)^mode:\s*(primary|subagent)\s*$") ""
    Test-That "agents\$id.md имеет model вида провайдер/модель" ($text -match "(?m)^model:\s*[\w.\-]+/[\w.\-]+\s*$") ""
    Test-That "agents\$id.md имеет description" ($text -match "(?m)^description:\s*\S") ""
}

$commandAgents = [ordered]@{
    "советник.md" = "council"
    "plan.md"     = "architect"
    "review.md"   = "reviewer"
    "triage.md"   = "triage"
}
foreach ($file in $commandAgents.Keys) {
    $path = Join-Path $Pack "commands\$file"
    $text = ""
    if (Test-Path $path) { $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }

    $agent = $commandAgents[$file]
    $refsKnownAgent = ($text -match ("(?m)^agent:\s*" + [regex]::Escape($agent) + "\s*$")) -and
                      (Test-Path (Join-Path $Pack "agents\$agent.md"))
    Test-That "commands\$file ссылается на существующего агента $agent" $refsKnownAgent ""
}

# ------------------------------------------------- 4. установка с нуля
Write-Host "4. Установка в пустую папку" -ForegroundColor Cyan

$fresh = New-Sandbox -Name "fresh"
$run = Invoke-Script -Script "install.ps1" -Target $fresh
Test-That "install.ps1 завершился успешно" ($run.ExitCode -eq 0) $run.Output

$freshConfig = Join-Path $fresh "opencode.json"
Test-That "opencode.json создан" (Test-Path $freshConfig) ""
Test-That "файлы агентов скопированы" (Test-Path (Join-Path $fresh "agents\council.md")) ""
Test-That "файлы команд скопированы" (Test-Path (Join-Path $fresh "commands\советник.md")) ""

$cfg = Read-JsonFile $freshConfig
$modelCount = 0
if ($null -ne $cfg -and $null -ne $cfg.PSObject.Properties["agents"]) {
    $modelCount = @($cfg.agents.PSObject.Properties).Count
}
Test-That "в конфиг добавлены 5 переопределений моделей" ($modelCount -eq 5) ("найдено: " + $modelCount)

# ------------------------------------------------------- 5. идемпотентность
Write-Host "5. Повторная установка" -ForegroundColor Cyan

$hashBefore = (Get-FileHash $freshConfig).Hash
$backupsBefore = Count-Backups $fresh
$run = Invoke-Script -Script "install.ps1" -Target $fresh

Test-That "повторный запуск успешен" ($run.ExitCode -eq 0) $run.Output
Test-That "конфиг не изменился" ((Get-FileHash $freshConfig).Hash -eq $hashBefore) ""
Test-That "лишних бэкапов не появилось" ((Count-Backups $fresh) -eq $backupsBefore) ""

# --------------------------- 6. удаление возвращает исходный вид (регрессия)
Write-Host "6. Удаление на конфиге, созданном установщиком" -ForegroundColor Cyan

$run = Invoke-Script -Script "uninstall.ps1" -Target $fresh
Test-That "uninstall.ps1 завершился успешно" ($run.ExitCode -eq 0) $run.Output
Test-That "файлы агентов удалены" (-not (Test-Path (Join-Path $fresh "agents\council.md"))) ""

$rawAfter = ""
if (Test-Path $freshConfig) { $rawAfter = [IO.File]::ReadAllText($freshConfig, [Text.Encoding]::UTF8) }
Test-That "пустой блок agents убран целиком" (-not ($rawAfter -match '"agents"')) $rawAfter
Test-That "schema в конфиге сохранён" ($rawAfter -match '\$schema') $rawAfter

# ------------------------------------- 7. чужая настройка не перезаписывается
Write-Host "7. Ручная правка модели" -ForegroundColor Cyan

$base = New-Sandbox -Name "base" -ConfigJson $BaseConfig
$run = Invoke-Script -Script "install.ps1" -Target $base
Test-That "установка поверх своего конфига успешна" ($run.ExitCode -eq 0) $run.Output

$baseConfig = Join-Path $base "opencode.json"
$raw = [IO.File]::ReadAllText($baseConfig, [Text.Encoding]::UTF8)
$raw = $raw.Replace('"opencode-go/gpt-6-luna"', '"vyce/deepseek-v4.1"')
[IO.File]::WriteAllText($baseConfig, $raw, $Utf8NoBom)

$run = Invoke-Script -Script "install.ps1" -Target $base
$raw = [IO.File]::ReadAllText($baseConfig, [Text.Encoding]::UTF8)
Test-That "своя модель explore не перезаписана" ($raw -match '"vyce/deepseek-v4\.1"') ""
Test-That "чужая модель не заменена на дефолтную" (-not ($raw -match '"explore"[\s\S]{0,60}gpt-6-luna')) ""

# ---------------------------------------------- 8. правки в файлах остаются
Write-Host "8. Изменённый агент при удалении" -ForegroundColor Cyan

$council = Join-Path $base "agents\council.md"
[IO.File]::AppendAllText($council, "`nМоя правка.`n", [Text.Encoding]::UTF8)

$run = Invoke-Script -Script "uninstall.ps1" -Target $base
Test-That "изменённый файл оставлен без -Force" (Test-Path $council) $run.Output

$run = Invoke-Script -Script "uninstall.ps1" -Target $base -Extra @("-Force")
Test-That "изменённый файл удалён с -Force" (-not (Test-Path $council)) $run.Output

$raw = [IO.File]::ReadAllText($baseConfig, [Text.Encoding]::UTF8)
Test-That "чужой агент build не тронут" ($raw -match '"build"') ""
Test-That "неизменённые модели удалены" (-not ($raw -match '"compaction"')) ""

# --------------------------------------------------- 9. JSONC с комментариями
Write-Host "9. Конфиг с комментариями" -ForegroundColor Cyan

$jsonc = New-Sandbox -Name "jsonc" -ConfigJson $JsoncConfig
$jsoncConfig = Join-Path $jsonc "opencode.json"
$jsoncBefore = (Get-FileHash $jsoncConfig).Hash

$run = Invoke-Script -Script "install.ps1" -Target $jsonc
Test-That "установка не падает на JSONC" ($run.ExitCode -eq 0) $run.Output
Test-That "JSONC не перезаписан" ((Get-FileHash $jsoncConfig).Hash -eq $jsoncBefore) ""
Test-That "агенты при этом скопированы" (Test-Path (Join-Path $jsonc "agents\architect.md")) ""
Test-That "пользователь предупреждён про ручной шаг" ($run.Output -match "комментари") $run.Output

# ------------------------------------------------------------- 10. -DryRun
Write-Host "10. Режим -DryRun" -ForegroundColor Cyan

$dry = New-Sandbox -Name "dryrun"
$run = Invoke-Script -Script "install.ps1" -Target $dry -Extra @("-DryRun")
Test-That "dry-run успешен" ($run.ExitCode -eq 0) $run.Output
Test-That "в dry-run конфиг не создан" (-not (Test-Path (Join-Path $dry "opencode.json"))) ""
Test-That "в dry-run папка agents не создана" (-not (Test-Path (Join-Path $dry "agents"))) ""

# ------------------------------------------------------------------ итог
Write-Host ""
$total = $script:Passed + $script:Failed
if ($script:Failed -eq 0) {
    Write-Host ("Итог: $($script:Passed) из $total проверок пройдено") -ForegroundColor Green
}
else {
    Write-Host ("Итог: провалено $($script:Failed) из $total проверок") -ForegroundColor Red
}

if ($KeepSandbox) {
    Write-Host ("Песочница сохранена: " + $Sandbox) -ForegroundColor DarkGray
}
else {
    Remove-Item $Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failed -gt 0) { exit 1 }
exit 0
