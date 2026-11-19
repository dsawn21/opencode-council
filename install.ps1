#Requires -Version 5.1
<#
    opencode-council — установщик

    Копирует агентов (council / architect / reviewer / triage) и команды
    в глобальный конфиг OpenCode V2 и добавляет переопределения моделей
    для служебных агентов.

    Примеры:
        .\install.ps1
        .\install.ps1 -DryRun
        .\install.ps1 -SkipModelOverrides
        .\install.ps1 -Target C:\path\to\.config\opencode
#>
[CmdletBinding()]
param(
    [string]$Target = (Join-Path $HOME ".config\opencode"),
    [switch]$SkipModelOverrides,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$SourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $SourceRoot "lib\JsonText.ps1")

$AgentFiles   = @("council.md", "architect.md", "reviewer.md", "triage.md")
$CommandFiles = @("советник.md", "plan.md", "review.md", "triage.md")

# Агент -> модель. Добавляется только если у агента ещё нет своей модели.
$ModelDefaults = [ordered]@{
    explore    = "opencode-go/gpt-6-luna"
    general    = "opencode-go/deepseek-v4-pro"
    title      = "opencode-go/deepseek-v4.1-flash"
    summary    = "opencode-go/deepseek-v4.1-flash"
    compaction = "opencode-go/deepseek-v4-pro"
}

function Write-Action([string]$Text, [string]$Color = "Gray") {
    Write-Host "  $Text" -ForegroundColor $Color
}

function Copy-One {
    param([string]$From, [string]$To)

    $name = Split-Path $To -Leaf
    if (Test-Path $To) {
        if ((Get-FileHash $From).Hash -eq (Get-FileHash $To).Hash) {
            Write-Action "= $name (без изменений)"
            return
        }
        if ($DryRun) { Write-Action "~ $name (будет обновлён)" "Yellow"; return }
        $backup = "$To.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $To $backup -Force
        Copy-Item $From $To -Force
        Write-Action "~ $name (обновлён, бэкап: $(Split-Path $backup -Leaf))" "Yellow"
    }
    else {
        if ($DryRun) { Write-Action "+ $name (будет создан)" "Yellow"; return }
        Copy-Item $From $To -Force
        Write-Action "+ $name (создан)" "Green"
    }
}

function Update-Config {
    param([string]$ConfigDir)

    $file = Join-Path $ConfigDir "opencode.json"
    if (-not (Test-Path $file)) {
        $file = Join-Path $ConfigDir "opencode.jsonc"
    }
    if (-not (Test-Path $file)) {
        $file = Join-Path $ConfigDir "opencode.json"
        if ($DryRun) { Write-Action "+ opencode.json (будет создан с блоком agents)" "Yellow"; return }
        $fresh = [pscustomobject]@{ '$schema' = 'https://opencode.ai/config.json' }
        $fresh | Add-Member -NotePropertyName "agents" -NotePropertyValue ([pscustomobject]@{}) -Force
        foreach ($id in $ModelDefaults.Keys) {
            $fresh.agents | Add-Member -NotePropertyName $id `
                -NotePropertyValue ([pscustomobject]@{ model = $ModelDefaults[$id] }) -Force
        }
        [IO.File]::WriteAllText($file, (ConvertTo-JsonText -InputObject $fresh).TrimEnd() + "`n", $Utf8NoBom)
        Write-Action "+ opencode.json (создан с блоком agents)" "Green"
        return
    }

    $raw = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)

    # JSONC с комментариями не переписываем: сериализатор их потеряет.
    if ($raw -match '(?ms)^\s*//' -or $raw -match '/\*') {
        Write-Action "! в $(Split-Path $file -Leaf) есть комментарии — файл не тронут" "DarkYellow"
        Write-Action "  блок 'agents' добавьте вручную (README, раздел «Модели»)" "DarkYellow"
        return
    }

    try { $cfg = $raw | ConvertFrom-Json }
    catch {
        Write-Action "! $(Split-Path $file -Leaf) не разбирается как JSON — пропускаю" "DarkYellow"
        return
    }

    if (-not $cfg.PSObject.Properties["agents"]) {
        $cfg | Add-Member -NotePropertyName "agents" -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $added = @()
    foreach ($id in $ModelDefaults.Keys) {
        $node = $cfg.agents.PSObject.Properties[$id]
        if ($null -eq $node) {
            $cfg.agents | Add-Member -NotePropertyName $id `
                -NotePropertyValue ([pscustomobject]@{ model = $ModelDefaults[$id] }) -Force
            $added += "$id = $($ModelDefaults[$id])"
            continue
        }
        $hasModel = $false
        try { $hasModel = $null -ne $node.Value.PSObject.Properties["model"] } catch { $hasModel = $false }
        if (-not $hasModel) {
            if ($null -eq $node.Value -or $node.Value -isnot [pscustomobject]) {
                $cfg.agents.PSObject.Properties[$id].Value = [pscustomobject]@{}
            }
            $node.Value | Add-Member -NotePropertyName "model" -NotePropertyValue $ModelDefaults[$id] -Force
            $added += "$id = $($ModelDefaults[$id])"
        }
    }

    if ($added.Count -eq 0) {
        Write-Action "= models (переопределения уже на месте)"
        return
    }
    if ($DryRun) {
        Write-Action ("~ models: " + ($added -join ", ")) "Yellow"
        return
    }

    $backup = "$file.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $file $backup -Force

    $json = ConvertTo-JsonText -InputObject $cfg
    [IO.File]::WriteAllText($file, $json.TrimEnd() + "`n", $Utf8NoBom)
    Write-Action ("~ models: " + ($added -join ", ")) "Yellow"
    Write-Action ("  бэкап конфига: " + (Split-Path $backup -Leaf)) "DarkGray"
}

# --- проверка пакета -------------------------------------------------------
foreach ($f in $AgentFiles) {
    if (-not (Test-Path (Join-Path $SourceRoot "agents\$f"))) {
        throw "Пакет неполный: нет agents\$f"
    }
}
foreach ($f in $CommandFiles) {
    if (-not (Test-Path (Join-Path $SourceRoot "commands\$f"))) {
        throw "Пакет неполный: нет commands\$f"
    }
}

Write-Host ""
Write-Host "opencode-council -> $Target" -ForegroundColor Cyan
if ($DryRun) { Write-Host "режим проверки: файлы не меняются" -ForegroundColor Yellow }

# --- папки -----------------------------------------------------------------
foreach ($sub in @("agents", "commands")) {
    $dir = Join-Path $Target $sub
    if (Test-Path $dir) { continue }
    if ($DryRun) { Write-Action "+ $sub\ (папка)" "Yellow"; continue }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-Action "+ $sub\ (папка)" "Green"
}

# --- агенты и команды ------------------------------------------------------
foreach ($f in $AgentFiles) {
    Copy-One -From (Join-Path $SourceRoot "agents\$f") -To (Join-Path $Target "agents\$f")
}
foreach ($f in $CommandFiles) {
    Copy-One -From (Join-Path $SourceRoot "commands\$f") -To (Join-Path $Target "commands\$f")
}

# --- модели ----------------------------------------------------------------
if ($SkipModelOverrides) {
    Write-Action "= models (пропущено по -SkipModelOverrides)"
}
else {
    Update-Config -ConfigDir $Target
}

Write-Host ""
if ($DryRun) {
    Write-Host "Проверка закончена, ничего не изменено." -ForegroundColor Yellow
    return
}

Write-Host "Готово." -ForegroundColor Green
Write-Host ""
Write-Host "Проверить:   opencode debug agents" -ForegroundColor Gray
Write-Host "Применить:   opencode reload" -ForegroundColor Gray
Write-Host "Запустить:   /советник <задача>   или Shift+Tab до council" -ForegroundColor Gray
Write-Host ""
