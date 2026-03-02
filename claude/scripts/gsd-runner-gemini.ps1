# gsd-runner-gemini.ps1 — Fixed & Auth Ready
param(
    [string]$ProjectPath = "",
    [switch]$SkipResearch, [switch]$SkipPlanning, [switch]$PrepareOnly,
    [switch]$ContinuousImprovement,
    [string]$GeminiModel = "gemini-1.5-pro", 
    [int]$TimeoutMinutes = 10
)
$ErrorActionPreference = "Continue"
$GsdHome = Join-Path $env:USERPROFILE ".claude"

function Expand-FileContext {
    param([string]$Text, [string]$Root)
    $pattern = "@(?<filepath>[\w\-.\\/:]+)"
    return [regex]::Replace($Text, $pattern, {
        param($match)
        $fullPath = Join-Path $Root $match.Groups['filepath'].Value
        if (Test-Path $fullPath) { return "`n--- FILE: $($match.Groups['filepath'].Value) ---`n$(Get-Content $fullPath -Raw)`n--- END ---`n" }
        return $match.Value
    })
}

function Resolve-GsdSkill {
    param([string]$CommandString)
    if ($CommandString -match "/gsd:([\w\-]+)") {
        $n = $Matches[1]
        $p = Join-Path $GsdHome "commands\gsd\$n.md"
        if (Test-Path $p) { return Get-Content $p -Raw }
    }
    return $null
}

function Invoke-Gemini {
    param([string]$Prompt, [string]$Label, [string]$ModelOverride = "")
    $model = if ($ModelOverride) { $ModelOverride } else { $GeminiModel }
    Write-Host "    [GEMINI] Processing: $Label ($model)" -ForegroundColor Cyan
    
    $sys = Resolve-GsdSkill -CommandString $Prompt
    $final = if ($sys) { "SYSTEM:`n$sys`n`nUSER:`n$Prompt" } else { $Prompt }
    $final = Expand-FileContext -Text $final -Root $ProjectPath
    
    $tf = "$env:TEMP\gemini_in_$(Get-Random).txt"
    $of = "$env:TEMP\gemini_out_$(Get-Random).md"
    Set-Content -Path $tf -Value $final -Encoding UTF8
    
    $cmd = "/c type `"$tf`" | gemini chat --model $model --yolo > `"$of`""
    $p = Start-Process "cmd.exe" -ArgumentList $cmd -PassThru -NoNewWindow
    
    $end = (Get-Date).AddMinutes($TimeoutMinutes)
    $spin = @("|", "/", "-", "\"); $i=0
    Write-Host "    " -NoNewline
    while (-not $p.HasExited) {
        if ((Get-Date) -gt $end) { $p.Kill(); Write-Host "`n    [TIMEOUT]" -ForegroundColor Red; return @{Success=$false} }
        Write-Host "`r    [$($spin[$i%4])] Working... " -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 100; $i++
    }

    if (Test-Path $of) { 
        Write-Host "`r    [✓] Done.        " -ForegroundColor Green
        return @{Success=$true; Output=(Get-Content $of -Raw)} 
    }
    return @{Success=$false}
}

$ProjectPath = Get-Location
Write-Host "🚀 GSD Gemini Active: $ProjectPath" -ForegroundColor Green

# 1. SDLC REVIEW
$StartPhase=1; $EndPhase=1
if ($ContinuousImprovement) {
    Write-Host "`n[1/3] 🛡️  Phase 1: Technijian SDLC Analysis..." -ForegroundColor Magenta
    $issues = Invoke-Gemini -Prompt "/gsd:sdlc-review @git-diff" -Label "Identifying Issues" -ModelOverride "gemini-1.5-pro"
    if ($issues.Success) {
        Write-Host "`n    [INFO] Issues Identified. Planning Phases..." -ForegroundColor DarkGray
        $plan = Invoke-Gemini -Prompt "/gsd:scoping Here are the issues. Plan phases:`n`n$($issues.Output)" -Label "Scoping Project" -ModelOverride "gemini-1.5-pro"
        if ($plan.Success -and $plan.Output -match "\{.*\}") {
            try { 
                $j = $matches[0] | ConvertFrom-Json
                $StartPhase=$j.start_phase; $EndPhase=$j.end_phase
                Write-Host "    [PLAN] Phases $StartPhase to $EndPhase Detected" -ForegroundColor Green
            } catch { Write-Warning "Could not parse JSON plan. Defaulting to Phase 1." }
        }
    }
}

# 2. EXECUTION
if ($EndPhase -ge $StartPhase) {
    Write-Host "`n[2/3] 🔨 Phase 2: Execution Loop..." -ForegroundColor Magenta
    for ($i = $StartPhase; $i -le $EndPhase; $i++) {
        Write-Host "`n  --- PROCESSING PHASE $i ---" -ForegroundColor Yellow
        if (-not $SkipResearch) { Invoke-Gemini -Prompt "/gsd:research-phase $i" -Label "Research" }
        if (-not $SkipPlanning) { Invoke-Gemini -Prompt "/gsd:plan-phase $i" -Label "Planning" }
        if (-not $PrepareOnly) { 
             Invoke-Gemini -Prompt "/gsd:batch-execute $i" -Label "Coding"
             Invoke-Gemini -Prompt "/gsd:code-review @git-diff" -Label "Verifying"
        }
    }
}

if ($ContinuousImprovement) { 
    Write-Host "`n[3/3] 🏁 Phase 3: Final Validation..." -ForegroundColor Magenta
    Invoke-Gemini -Prompt "/gsd:code-review" -Label "Final Check" -ModelOverride "gemini-1.5-pro"
}
Write-Host "`n✅ Workflow Complete." -ForegroundColor Green
