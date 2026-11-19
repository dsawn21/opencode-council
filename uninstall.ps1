#Requires -Version 5.1
<#
    opencode-council — удаление

    Убирает только то, что поставил install.ps1:
      * файлы агентов и команд с совпадающим содержимым;
      * переопределения моделей, которые не были изменены вручную.

    Изменённые вами файлы и настройки не трогаются без -Force.

    Примеры:
        .\uninstall.ps1 -DryRun
        .\uninstall.ps1
        .\uninstall.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Target = (Join-Path $HOME ".config\opencode"),
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$SourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $SourceRoot "lib\JsonText.ps1")

$AgentFiles   = @("council.md", "architect.md", "reviewer.md", "triage.md")
$CommandFiles = @("советник.md", "plan.md", "review.md", "triage.md")

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

function Remove-One {
    param([string]$PackFile, [string]$InstalledFile)

    $name = Split-Path $InstalledFile -Leaf
    if (-not (Test-Path $InstalledFile)) { Write-Action "- $name (не установлен)"; return }

    $modified = $true
    if (Test-Path $PackFile) {
        $modified = (Get-FileHash $PackFile).Hash -ne (Get-FileHash $InstalledFile).Hash
    }
    if ($modified -and -not $Force) {
        Write-Action "! $name изменён вручную — оставлен (для удаления: -Force)" "DarkYellow"
        return
    }
    if ($DryRun) { Write-Action "- $name (будет удалён)" "Yellow"; return }
    Remove-Item $InstalledFile -Force
    Write-Action "- $name (удалён)" "Green"
}

function Update-Config {
    param([string]$ConfigDir)

    $file = Join-Path $ConfigDir "opencode.json"
    if (-not (Test-Path $file)) { $file = Join-Path $ConfigDir "opencode.jsonc" }
    if (-not (Test-Path $file)) {
        Write-Action "! конфиг не найден — нечего чистить"
        return
    }

    $raw = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    if ($raw -match '(?ms)^\s*//' -or $raw -match '/\*') {
        Write-Action "! в конфиге есть комментарии — файл не тронут" "DarkYellow"
        Write-Action "  удалите блок 'agents' вручную (README, раздел «Модели»)" "DarkYellow"
        return
    }

    try { $cfg = $raw | ConvertFrom-Json }
    catch { Write-Action "! конфиг не разбирается как JSON — пропускаю" "DarkYellow"; return }

    if (-not $cfg.PSObject.Properties["agents"]) {
        Write-Action "= models (переопределений нет)"
        return
    }

    $removed = @()
    foreach ($id in $ModelDefaults.Keys) {
        $node = $cfg.agents.PSObject.Properties[$id]
        if ($null -eq $node) { continue }
        $current = $null
        try { $current = $node.Value.model } catch { $current = $null }
        if ($null -eq $current) { continue }

        if ($current -ne $ModelDefaults[$id] -and -not $Force) {
            Write-Action "! $id.model = $current (изменён вручную) — оставлен" "DarkYellow"
            continue
        }
        $cfg.agents.PSObject.Properties.Remove($id)
        $removed += $id
    }

    if (@($cfg.agents.PSObject.Properties).Count -eq 0) {
        $cfg.PSObject.Properties.Remove("agents")
    }

    if ($removed.Count -eq 0) {
        Write-Action "= models (нечего удалять)"
        return
    }
    if ($DryRun) { Write-Action ("~ models: " + ($removed -join ", ")) "Yellow"; return }

    $backup = "$file.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $file $backup -Force

    $json = ConvertTo-JsonText -InputObject $cfg
    [IO.File]::WriteAllText($file, $json.TrimEnd() + "`n", $Utf8NoBom)
    Write-Action ("~ models: " + ($removed -join ", ")) "Yellow"
}

Write-Host ""
Write-Host "opencode-council <- $Target" -ForegroundColor Cyan
if ($DryRun) { Write-Host "режим проверки: файлы не меняются" -ForegroundColor Yellow }

foreach ($f in $AgentFiles) {
    Remove-One -PackFile (Join-Path $SourceRoot "agents\$f") -InstalledFile (Join-Path $Target "agents\$f")
}
foreach ($f in $CommandFiles) {
    Remove-One -PackFile (Join-Path $SourceRoot "commands\$f") -InstalledFile (Join-Path $Target "commands\$f")
}
Update-Config -ConfigDir $Target

Write-Host ""
if ($DryRun) {
    Write-Host "Проверка закончена, ничего не изменено." -ForegroundColor Yellow
    return
}
Write-Host "Готово. Применить: opencode reload" -ForegroundColor Green
Write-Host ""
