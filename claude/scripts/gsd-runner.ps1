# gsd-runner.ps1 — Global GSD Phase Runner
#
# Generic runner for any GSD project. Auto-detects project root by walking up
# the directory tree looking for .planning/ROADMAP.md. Works from any subdirectory.
#
# Architecture:
#   1. PREPARATION (parallel per phase):
#      Per-phase pipeline: research (if needed) -> plan (if needed)
#      Research and plan run sequentially WITHIN each phase (plan needs research)
#      All phases run their pipelines in PARALLEL with each other
#
#   2. EXECUTION (sequential across phases):
#      Execute one phase at a time via /gsd:batch-execute (headless-safe)
#
#   3. CONTINUOUS IMPROVEMENT (-ContinuousImprovement):
#      After all phases complete, enters a review-remediate loop:
#        a. Run /gsd:code-review to assess quality
#        b. Parse health score from docs/review/EXECUTIVE-SUMMARY.md
#        c. If score >= target (default 90) with 0 blockers -> stop (success)
#        d. Create remediation phases from PRIORITIZED-TASKS.md findings
#        e. Prepare (research -> plan) and execute remediation phases
#        f. Repeat until target reached or max iterations exhausted
#
# GSD skills used:
#   /gsd:research-phase <N> — Researches how to implement a phase, creates RESEARCH.md
#   /gsd:plan-phase <N>     — Creates PLAN.md files with task breakdown and verification
#   /gsd:batch-execute <N>  — Executes all plans in a phase sequentially (headless-safe)
#   /gsd:execute-phase <N>  — Executes with wave-based parallelization (alternative)
#
# Installation:
#   Lives at: ~/.claude/scripts/gsd-runner.ps1
#   Add to PowerShell profile:
#     function gsd-run { & "$env:USERPROFILE\.claude\scripts\gsd-runner.ps1" @args }
#
# Usage:
#   gsd-run                                    # Auto-detect project + pending phases
#   gsd-run -DryRun                            # Preview execution plan
#   gsd-run -ProjectPath C:\myproject          # Target a specific project
#   gsd-run -StartPhase 17                     # Start from phase 17
#   gsd-run -StartPhase 18 -EndPhase 19        # Only phases 18-19
#   gsd-run -SkipResearch                      # Skip research (go straight to planning)
#   gsd-run -SkipPlanning                      # Skip research+planning (plans exist)
#   gsd-run -PrepareOnly                       # Only research+plan, don't execute
#   gsd-run -UseWaveParallel                   # Use /gsd:execute-phase for intra-phase parallelism
#   gsd-run -ContinuousImprovement             # Run phases then review-remediate loop
#   gsd-run -ContinuousImprovement -TargetScore 95 -MaxIterations 5
#   gsd-run -ContinuousImprovement -StopOnNoImprovement  # Stop if score stagnates

param(
    [string]$ProjectPath = "",     # Project root (auto-detect if empty)
    [int]$StartPhase = 0,          # 0 = auto-detect from ROADMAP.md
    [int]$EndPhase = 0,            # 0 = auto-detect from ROADMAP.md
    [int]$MaxTurns = 200,          # Max API turns per Claude invocation
    [int]$PrepTimeout = 45,        # Minutes before a preparation pipeline is killed
    [int]$ExecuteTimeout = 45,     # Minutes before an execution agent is killed
    [switch]$SkipResearch,         # Skip research step (plan only)
    [switch]$SkipPlanning,         # Skip entire preparation (research + planning)
    [switch]$PrepareOnly,          # Only prepare (research + plan), don't execute
    [switch]$UseWaveParallel,      # Use /gsd:execute-phase instead of /gsd:batch-execute
    [switch]$DryRun,
    # Continuous Improvement loop (Step 3)
    [switch]$ContinuousImprovement,  # Enable review -> remediate -> re-review loop
    [int]$TargetScore = 90,          # Stop when health score >= this AND blockers == 0
    [int]$MaxIterations = 3,         # Max remediation cycles before stopping
    [int]$ReviewTimeout = 30,        # Minutes for code review agent
    [switch]$StopOnNoImprovement     # Stop if score doesn't improve between iterations
)

$ErrorActionPreference = "Continue"
$startTime = Get-Date

# ============================================================
#  Project root detection
# ============================================================
function Find-GsdProjectRoot {
    param([string]$StartDir)
    $current = if ($StartDir) { (Resolve-Path $StartDir -ErrorAction SilentlyContinue).Path } else { (Get-Location).Path }
    if (-not $current) { return $null }

    # Walk up the directory tree looking for .planning/ROADMAP.md
    while ($current) {
        $roadmap = Join-Path $current ".planning\ROADMAP.md"
        if (Test-Path $roadmap) { return $current }

        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }  # Reached filesystem root
        $current = $parent
    }
    return $null
}

# Find project root
$projectRoot = Find-GsdProjectRoot $ProjectPath
if (-not $projectRoot) {
    $searchStart = if ($ProjectPath) { $ProjectPath } else { (Get-Location).Path }
    Write-Host "ERROR: No GSD project found." -ForegroundColor Red
    Write-Host "  Searched from: $searchStart" -ForegroundColor Red
    Write-Host "  Looking for:   .planning/ROADMAP.md" -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    Write-Host "  Either:" -ForegroundColor Yellow
    Write-Host "    1. cd into a GSD project directory" -ForegroundColor Yellow
    Write-Host "    2. Use -ProjectPath C:\path\to\project" -ForegroundColor Yellow
    Write-Host "    3. Run /gsd:new-project to initialize a new project" -ForegroundColor Yellow
    exit 1
}

# Resolve project name from directory
$projectName = Split-Path $projectRoot -Leaf
$logFile = Join-Path $projectRoot ".planning\execution-log.txt"

# ============================================================
#  Helper functions
# ============================================================
function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $Message"
    Write-Host $entry -ForegroundColor $Color
    Add-Content -Path $logFile -Value $entry
}

function Write-Banner {
    param([string]$Text, [string]$Color = "Cyan")
    $line = "=" * 60
    Write-Host ""
    Write-Host $line -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host $line -ForegroundColor $Color
    Write-Host ""
}

function Get-CurrentPhase {
    $statePath = Join-Path $projectRoot ".planning\STATE.md"
    if (-not (Test-Path $statePath)) { return $null }
    $state = Get-Content $statePath -Raw
    if ($state -match "Phase:\s*(\d+)\s+of\s+(\d+)") {
        return @{ Current = [int]$Matches[1]; Total = [int]$Matches[2] }
    }
    return $null
}

# ---- Phase detection from ROADMAP.md ----
function Get-PendingPhases {
    $roadmapPath = Join-Path $projectRoot ".planning\ROADMAP.md"
    $roadmap = Get-Content $roadmapPath -Raw
    $pending = @()
    $found = [regex]::Matches($roadmap, '- \[ \] \*\*Phase (\d+)')
    foreach ($m in $found) {
        $pending += [int]$m.Groups[1].Value
    }
    return ($pending | Sort-Object)
}

function Get-AllPhases {
    $roadmapPath = Join-Path $projectRoot ".planning\ROADMAP.md"
    $roadmap = Get-Content $roadmapPath -Raw
    $all = @()
    $found = [regex]::Matches($roadmap, '- \[.\] \*\*Phase (\d+)')
    foreach ($m in $found) {
        $all += [int]$m.Groups[1].Value
    }
    return ($all | Sort-Object)
}

# ---- Phase filesystem helpers ----
function Get-PhaseDir {
    param([int]$PhaseNum)
    $padded = $PhaseNum.ToString("00")
    $phasesDir = Join-Path $projectRoot ".planning\phases"
    $dirs = Get-ChildItem -Path $phasesDir -Directory -Filter "${padded}-*" -ErrorAction SilentlyContinue
    if ($dirs) { return $dirs[0].Name }
    return $null
}

function Test-PhaseHasResearch {
    param([int]$PhaseNum)
    $dir = Get-PhaseDir $PhaseNum
    if (-not $dir) { return $false }
    $researchPath = Join-Path $projectRoot ".planning\phases\$dir\RESEARCH.md"
    return (Test-Path $researchPath)
}

function Test-PhaseHasPlans {
    param([int]$PhaseNum)
    $dir = Get-PhaseDir $PhaseNum
    if (-not $dir) { return $false }
    $phasePath = Join-Path $projectRoot ".planning\phases\$dir"
    $plans = Get-ChildItem -Path $phasePath -Filter "*-PLAN.md" -ErrorAction SilentlyContinue
    return ($plans -and $plans.Count -gt 0)
}

function Get-PhasePlanCount {
    param([int]$PhaseNum)
    $dir = Get-PhaseDir $PhaseNum
    if (-not $dir) { return 0 }
    $phasePath = Join-Path $projectRoot ".planning\phases\$dir"
    $plans = Get-ChildItem -Path $phasePath -Filter "*-PLAN.md" -ErrorAction SilentlyContinue
    if ($plans) { return $plans.Count }
    return 0
}

function Get-PhaseSummaryCount {
    param([int]$PhaseNum)
    $dir = Get-PhaseDir $PhaseNum
    if (-not $dir) { return 0 }
    $phasePath = Join-Path $projectRoot ".planning\phases\$dir"
    $summaries = Get-ChildItem -Path $phasePath -Filter "*-SUMMARY.md" -ErrorAction SilentlyContinue
    if ($summaries) { return $summaries.Count }
    return 0
}

function Test-PhaseComplete {
    param([int]$PhaseNum)
    $planCount = Get-PhasePlanCount $PhaseNum
    if ($planCount -eq 0) { return $false }
    $summaryCount = Get-PhaseSummaryCount $PhaseNum
    return ($summaryCount -ge $planCount)
}

function Get-PhaseStatus {
    param([int]$PhaseNum)
    if (Test-PhaseComplete $PhaseNum)    { return "complete" }
    if (Test-PhaseHasPlans $PhaseNum)    { return "planned" }
    if (Test-PhaseHasResearch $PhaseNum) { return "researched" }
    $dir = Get-PhaseDir $PhaseNum
    if ($dir) { return "pending" }
    return "unknown"
}

function Get-PhaseStatusIcon {
    param([string]$Status)
    switch ($Status) {
        "complete"   { return "[OK]" }
        "planned"    { return "[PL]" }
        "researched" { return "[RS]" }
        "pending"    { return "[..]" }
        default      { return "[??]" }
    }
}

# ============================================================
#  Continuous Improvement helpers
# ============================================================
function Get-ReviewHealthScore {
    <#
    .SYNOPSIS
        Parses docs/review/EXECUTIVE-SUMMARY.md OR raw output for health score and finding counts.
    .PARAMETER Content
        Optional raw output content to parse instead of reading from file.
    .OUTPUTS
        Hashtable with Score, Grade, Blockers, High, Medium, Low, Total or $null on failure.
    #>
    param(
        [string]$Content = $null
    )

    # If no content provided, try to read from file
    if (-not $Content) {
        $summaryPath = Join-Path $projectRoot "docs\review\EXECUTIVE-SUMMARY.md"
        if (-not (Test-Path $summaryPath)) {
            Write-Log "    [CI] EXECUTIVE-SUMMARY.md not found at $summaryPath" "Red"
            return $null
        }
        $Content = Get-Content $summaryPath -Raw
    }

    # Parse health score line: "Health: 85/100 (Grade: B)" or "Health: 0/100"
    $score = $null; $grade = "?"
    if ($Content -match 'Health[:\s]+(\d+)\s*/\s*100\s*\(Grade[:\s]+([A-F][+-]?)\)') {
        $score = [int]$Matches[1]
        $grade = $Matches[2]
    } elseif ($Content -match 'Health[:\s]+(\d+)\s*/\s*100') {
        $score = [int]$Matches[1]
        if ($Content -match 'Grade[:\s]+([A-F][+-]?)') {
            $grade = $Matches[1]
        }
    } elseif ($Content -match '(\d+)\s*/\s*100') {
        $score = [int]$Matches[1]
    }

    if ($null -eq $score) {
        Write-Log "    [CI] Could not parse health score from review output" "Red"
        return $null
    }

    # Parse severity counts from findings tables
    $blockers = 0; $high = 0; $medium = 0; $low = 0
    if ($Content -match 'BLOCKER\s*\|\s*(\d+)') { $blockers = [int]$Matches[1] }
    if ($Content -match 'HIGH\s*\|\s*(\d+)')    { $high = [int]$Matches[1] }
    if ($Content -match 'MEDIUM\s*\|\s*(\d+)')  { $medium = [int]$Matches[1] }
    if ($Content -match 'LOW\s*\|\s*(\d+)')     { $low = [int]$Matches[1] }

    # Alternative table label casing / markdown bold variants
    if ($blockers -eq 0 -and $Content -match '\| Blocker \| (\d+) \|') { $blockers = [int]$Matches[1] }
    if ($high -eq 0 -and $Content -match '\| High \| (\d+) \|') { $high = [int]$Matches[1] }
    if ($medium -eq 0 -and $Content -match '\| Medium \| (\d+) \|') { $medium = [int]$Matches[1] }
    if ($low -eq 0 -and $Content -match '\| Low \| (\d+) \|') { $low = [int]$Matches[1] }
    if ($blockers -eq 0 -and $Content -match '(?i)\|\s*\*{0,2}BLOCKER\*{0,2}\s*\|\s*(\d+)\s*\|') { $blockers = [int]$Matches[1] }
    if ($high -eq 0 -and $Content -match '(?i)\|\s*\*{0,2}HIGH\*{0,2}\s*\|\s*(\d+)\s*\|') { $high = [int]$Matches[1] }
    if ($medium -eq 0 -and $Content -match '(?i)\|\s*\*{0,2}MEDIUM\*{0,2}\s*\|\s*(\d+)\s*\|') { $medium = [int]$Matches[1] }
    if ($low -eq 0 -and $Content -match '(?i)\|\s*\*{0,2}LOW\*{0,2}\s*\|\s*(\d+)\s*\|') { $low = [int]$Matches[1] }

    # Executive summary format: "Severity Totals: Blocker=1 | High=2 | Medium=2 | Low=0"
    if (($blockers + $high + $medium + $low) -eq 0) {
        if ($Content -match '(?is)Severity\s+Totals\s*:\s*.*?Blocker\s*=\s*(\d+).*?High\s*=\s*(\d+).*?Medium\s*=\s*(\d+).*?Low\s*=\s*(\d+)') {
            $blockers = [int]$Matches[1]
            $high = [int]$Matches[2]
            $medium = [int]$Matches[3]
            $low = [int]$Matches[4]
        }
    }

    $total = $blockers + $high + $medium + $low

    return @{
        Score    = $score
        Grade    = $grade
        Blockers = $blockers
        High     = $high
        Medium   = $medium
        Low      = $low
        Total    = $total
    }
}

function Write-IterationHeader {
    param(
        [int]$Iteration,
        [int]$MaxIter,
        [hashtable]$PreviousHealth  # $null on first iteration
    )

    $line = "-" * 60
    Write-Host ""
    Write-Host $line -ForegroundColor Magenta
    Write-Host "  CONTINUOUS IMPROVEMENT - Iteration $Iteration / $MaxIter" -ForegroundColor Magenta
    if ($PreviousHealth) {
        Write-Host "  Previous score: $($PreviousHealth.Score)/100 (Grade: $($PreviousHealth.Grade)) | Blockers: $($PreviousHealth.Blockers) High: $($PreviousHealth.High) Med: $($PreviousHealth.Medium) Low: $($PreviousHealth.Low)" -ForegroundColor DarkMagenta
    } else {
        Write-Host "  First iteration - establishing baseline health score" -ForegroundColor DarkMagenta
    }
    Write-Host $line -ForegroundColor Magenta
    Write-Host ""
}

function Write-HealthImprovement {
    param(
        [hashtable]$Previous,
        [hashtable]$Current
    )

    if (-not $Previous -or -not $Current) { return }

    $delta = $Current.Score - $Previous.Score
    $arrow = if ($delta -gt 0) { "+" } elseif ($delta -lt 0) { "" } else { "=" }
    $color = if ($delta -gt 0) { "Green" } elseif ($delta -lt 0) { "Red" } else { "Yellow" }

    Write-Host ""
    Write-Host "  Health Score Change:" -ForegroundColor Cyan
    Write-Host "    $($Previous.Score)/100 ($($Previous.Grade)) -> $($Current.Score)/100 ($($Current.Grade))  [${arrow}${delta}]" -ForegroundColor $color

    $findingsDelta = $Current.Total - $Previous.Total
    $fArrow = if ($findingsDelta -lt 0) { "" } elseif ($findingsDelta -gt 0) { "+" } else { "=" }
    $fColor = if ($findingsDelta -lt 0) { "Green" } elseif ($findingsDelta -gt 0) { "Red" } else { "Yellow" }
    Write-Host "    Findings: $($Previous.Total) -> $($Current.Total)  [${fArrow}${findingsDelta}]" -ForegroundColor $fColor

    if ($Current.Blockers -ne $Previous.Blockers) {
        $bDelta = $Current.Blockers - $Previous.Blockers
        $bColor = if ($bDelta -lt 0) { "Green" } else { "Red" }
        Write-Host "    Blockers: $($Previous.Blockers) -> $($Current.Blockers)" -ForegroundColor $bColor
    }
    Write-Host ""
}

function Test-ShouldStopIteration {
    <#
    .SYNOPSIS
        Evaluates stopping conditions for the continuous improvement loop.
    .OUTPUTS
        Hashtable with ShouldStop (bool) and Reason (string).
    #>
    param(
        [hashtable]$Health,          # Current health (can be $null)
        [hashtable]$PreviousHealth,  # Previous iteration health (can be $null)
        [int]$Target,
        [switch]$CheckNoImprovement
    )

    if ($null -eq $Health) {
        return @{ ShouldStop = $true; Reason = "Could not parse health score from review output" }
    }

    if ($Health.Score -ge $Target -and $Health.Blockers -eq 0) {
        return @{ ShouldStop = $true; Reason = "Target reached: $($Health.Score)/100 >= $Target AND 0 blockers (Grade: $($Health.Grade))" }
    }

    if ($CheckNoImprovement -and $PreviousHealth) {
        if ($Health.Score -le $PreviousHealth.Score) {
            return @{ ShouldStop = $true; Reason = "No improvement: $($PreviousHealth.Score) -> $($Health.Score) (-StopOnNoImprovement)" }
        }
    }

    return @{ ShouldStop = $false; Reason = "Continue: $($Health.Score)/100 < $Target (Blockers: $($Health.Blockers), High: $($Health.High))" }
}

# ============================================================
#  Claude execution: direct process with watchdog timeout
# ============================================================
function Invoke-ClaudeWithTimeout {
    param(
        [string]$Prompt,
        [int]$TimeoutMinutes,
        [int]$Turns,
        [string]$Label = "agent"
    )

    Write-Log "    [WATCHDOG] $Label - timeout ${TimeoutMinutes}m, max-turns $Turns" "DarkCyan"

    $escapedPrompt = $Prompt -replace '"', '\"'
    $procStart = Get-Date

    # Create temp output files in project directory
    $outputFile = Join-Path $projectRoot ".planning\agent-output\$Label.stdout"
    $outputDir = Split-Path $outputFile -Parent
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

    # Use cmd /c with set CLAUDECODE= to unset the env var for nested Claude sessions
    # Redirect stdout to file so Claude can write review files to project directory
    $cmd = "set CLAUDECODE=&& claude -p `"$escapedPrompt`" --dangerously-skip-permissions --max-turns $Turns 2>&1 | tee `"$outputFile`""
    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c", $cmd `
        -NoNewWindow -PassThru -WorkingDirectory $projectRoot

    $deadline = $procStart.AddMinutes($TimeoutMinutes)
    $lastReport = $procStart
    $lastSize = 0

    while (-not $proc.HasExited) {
        if ((Get-Date) -gt $deadline) {
            Write-Log "    [WATCHDOG] TIMEOUT: $Label exceeded ${TimeoutMinutes}m - killing" "Red"
            try { $proc.Kill(); $proc.WaitForExit(5000) } catch {}
            $elapsed = [math]::Round(((Get-Date) - $procStart).TotalMinutes, 1)
            return @{ Success = $false; TimedOut = $true; ExitCode = -1; Duration = $elapsed; OutputFile = $outputFile }
        }
        # Check for progress (output file growing)
        if (Test-Path $outputFile) {
            $currentSize = (Get-Item $outputFile).Length
            if ($currentSize -gt $lastSize) {
                $lastReport = Get-Date
                $lastSize = $currentSize
            }
        }
        if (((Get-Date) - $lastReport).TotalSeconds -ge 60) {
            $elapsed = [math]::Round(((Get-Date) - $procStart).TotalMinutes, 1)
            Write-Host "    ... $Label running (${elapsed}m / ${TimeoutMinutes}m)" -ForegroundColor DarkGray
            $lastReport = Get-Date
        }
        Start-Sleep -Seconds 5
    }

    $duration = [math]::Round(((Get-Date) - $procStart).TotalMinutes, 1)
    $exitCode = $proc.ExitCode

    # Read output file content
    $outputContent = ""
    if (Test-Path $outputFile) {
        try { $outputContent = Get-Content $outputFile -Raw -ErrorAction SilentlyContinue } catch {}
    }

    # If exit code is null/empty but process exited, treat as success (Claude may have run)
    $success = if ($null -eq $exitCode -or $exitCode -eq "" -or $exitCode -eq 0) { $true } else { $false }
    return @{ Success = $success; TimedOut = $false; ExitCode = $exitCode; Duration = $duration; OutputFile = $outputFile; Output = $outputContent }
}

# ============================================================
#  Build per-phase preparation command (research -> plan)
# ============================================================
function Get-PrepCommands {
    param([int]$PhaseNum)
    $cmds = @()

    if (-not $SkipResearch -and -not (Test-PhaseHasResearch $PhaseNum)) {
        $cmds += "claude -p `"/gsd:research-phase $PhaseNum`" --dangerously-skip-permissions --max-turns $MaxTurns"
    }
    if (-not (Test-PhaseHasPlans $PhaseNum)) {
        $cmds += "claude -p `"/gsd:plan-phase $PhaseNum`" --dangerously-skip-permissions --max-turns $MaxTurns"
    }

    return $cmds
}

function Get-PrepSteps {
    param([int]$PhaseNum)
    $steps = @()
    if (-not $SkipResearch -and -not (Test-PhaseHasResearch $PhaseNum)) { $steps += "research" }
    if (-not (Test-PhaseHasPlans $PhaseNum)) { $steps += "plan" }
    return $steps
}

# ============================================================
#  Dry run preview
# ============================================================
function Show-ExecutionPlan {
    param([int[]]$Phases)

    Write-Banner "Execution Plan Preview" "Yellow"

    $prepPhases = @()
    $execPhases = @()

    foreach ($phase in $Phases) {
        $status = Get-PhaseStatus $phase
        $dir = Get-PhaseDir $phase
        $dirLabel = if ($dir) { $dir } else { "(no directory)" }

        if ($status -eq "complete") {
            Write-Host "  Phase $phase ($dirLabel) - COMPLETE (skip)" -ForegroundColor DarkGray
            continue
        }

        if (-not $SkipPlanning) {
            $steps = Get-PrepSteps $phase
            if ($steps.Count -gt 0) {
                $prepPhases += $phase
            } else {
                Write-Host "  Phase $phase ($dirLabel) - already prepared" -ForegroundColor DarkGray
            }
        }

        if (-not $PrepareOnly) {
            $execPhases += $phase
        }
    }

    # Step 1: Preparation
    Write-Host ""
    if ($SkipPlanning) {
        Write-Host "  STEP 1: PREPARATION - SKIPPED (-SkipPlanning)" -ForegroundColor DarkGray
    } elseif ($prepPhases.Count -eq 0) {
        Write-Host "  STEP 1: PREPARATION - SKIPPED (all phases already prepared)" -ForegroundColor DarkGray
    } else {
        Write-Host "  STEP 1: PARALLEL PREPARATION (research -> plan per phase)" -ForegroundColor Yellow
        Write-Host "  $($prepPhases.Count) phase pipelines run in parallel:" -ForegroundColor Gray
        Write-Host ""
        foreach ($phase in $prepPhases) {
            $steps = Get-PrepSteps $phase
            $dir = Get-PhaseDir $phase
            $dirLabel = if ($dir) { $dir } else { "(dir TBD)" }
            $pipeline = $steps -join " -> "
            Write-Host "    Phase $phase ($dirLabel): $pipeline" -ForegroundColor White
        }
        Write-Host ""
        Write-Host "  Timeout: ${PrepTimeout}m per pipeline | Max turns: $MaxTurns" -ForegroundColor Gray
    }

    # Step 2: Execution
    Write-Host ""
    $execCmd = if ($UseWaveParallel) { "/gsd:execute-phase" } else { "/gsd:batch-execute" }
    if ($PrepareOnly) {
        Write-Host "  STEP 2: EXECUTION - SKIPPED (-PrepareOnly)" -ForegroundColor DarkGray
    } elseif ($execPhases.Count -eq 0) {
        Write-Host "  STEP 2: EXECUTION - SKIPPED (no phases to execute)" -ForegroundColor DarkGray
    } else {
        Write-Host "  STEP 2: SEQUENTIAL EXECUTION (one phase at a time)" -ForegroundColor Yellow
        foreach ($phase in $execPhases) {
            $dir = Get-PhaseDir $phase
            $dirLabel = if ($dir) { $dir } else { "(dir TBD)" }
            Write-Host "    Phase $phase ($dirLabel) -> $execCmd $phase" -ForegroundColor White
        }
        Write-Host ""
        Write-Host "  Skill: $execCmd | Timeout: ${ExecuteTimeout}m | Max turns: $MaxTurns" -ForegroundColor Gray
    }

    # Step 3: Continuous Improvement
    Write-Host ""
    if ($ContinuousImprovement) {
        Write-Host "  STEP 3: CONTINUOUS IMPROVEMENT LOOP" -ForegroundColor Magenta
        Write-Host "    After execution, enters review-remediate cycle:" -ForegroundColor Gray
        Write-Host "      1. Run /gsd:code-review (timeout: ${ReviewTimeout}m)" -ForegroundColor White
        Write-Host "      2. Parse health score from docs/review/EXECUTIVE-SUMMARY.md" -ForegroundColor White
        Write-Host "      3. Stop if score >= $TargetScore with 0 blockers" -ForegroundColor White
        Write-Host "      4. Create remediation phases from findings" -ForegroundColor White
        Write-Host "      5. Research -> Plan -> Execute remediation phases" -ForegroundColor White
        Write-Host "      6. Repeat (max $MaxIterations iterations)" -ForegroundColor White
        if ($StopOnNoImprovement) {
            Write-Host "    Early stop: YES (if score doesn't improve)" -ForegroundColor Yellow
        }
        Write-Host ""
    } else {
        Write-Host "  STEP 3: CONTINUOUS IMPROVEMENT - DISABLED (use -ContinuousImprovement)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "  Summary: $($prepPhases.Count) to prepare (parallel), $($execPhases.Count) to execute (sequential)" -ForegroundColor Cyan
    if ($ContinuousImprovement) {
        Write-Host "           + up to $MaxIterations review-remediate iterations (target: ${TargetScore}/100)" -ForegroundColor Magenta
    }
}

# ============================================================
#  Main execution
# ============================================================
Write-Banner "GSD Phase Runner"

Write-Host "  Project:          $projectName" -ForegroundColor White
Write-Host "  Root:             $projectRoot" -ForegroundColor DarkGray

# Auto-detect phases if not specified
if ($StartPhase -eq 0 -or $EndPhase -eq 0) {
    $pendingPhases = Get-PendingPhases
    if ($pendingPhases.Count -eq 0) {
        $allPhases = Get-AllPhases
        Write-Host ""
        Write-Host "  All $($allPhases.Count) phases are complete. Nothing to do." -ForegroundColor Green
        exit 0
    }
    if ($StartPhase -eq 0) { $StartPhase = $pendingPhases[0] }
    if ($EndPhase -eq 0)   { $EndPhase = $pendingPhases[-1] }
    Write-Host "  Detection:        Auto (from ROADMAP.md)" -ForegroundColor DarkCyan
}

$targetPhases = @($StartPhase..$EndPhase)
$initialPhase = Get-CurrentPhase
$executeSkill = if ($UseWaveParallel) { "/gsd:execute-phase (wave parallel)" } else { "/gsd:batch-execute (headless-safe)" }

Write-Host "  Current state:    $(if ($initialPhase) { "Phase $($initialPhase.Current) of $($initialPhase.Total)" } else { "Unknown" })" -ForegroundColor White
Write-Host "  Target range:     Phases $StartPhase - $EndPhase ($($targetPhases.Count) phases)" -ForegroundColor White
Write-Host "  Max turns/agent:  $MaxTurns" -ForegroundColor Gray
Write-Host "  Prep pipeline:    research -> plan (per phase, in parallel)" -ForegroundColor Gray
Write-Host "  Execute skill:    $executeSkill" -ForegroundColor Gray
Write-Host "  Timeouts:         prep=${PrepTimeout}m  execute=${ExecuteTimeout}m" -ForegroundColor Gray
if ($SkipResearch) { Write-Host "  Research:         SKIPPED" -ForegroundColor Yellow }
if ($SkipPlanning) { Write-Host "  Preparation:      SKIPPED (research + planning)" -ForegroundColor Yellow }
if ($PrepareOnly)  { Write-Host "  Execution:        SKIPPED (prepare only)" -ForegroundColor Yellow }
if ($ContinuousImprovement) {
    Write-Host "  CI loop:          ENABLED (target ${TargetScore}/100, max ${MaxIterations} iterations)" -ForegroundColor Magenta
}
if ($DryRun)       { Write-Host "  Mode:             DRY RUN" -ForegroundColor Yellow }
Write-Host ""

# Phase status overview
Write-Host "  Phase Status:" -ForegroundColor DarkCyan
foreach ($phase in $targetPhases) {
    $status = Get-PhaseStatus $phase
    $icon = Get-PhaseStatusIcon $status
    $dir = Get-PhaseDir $phase
    $dirLabel = if ($dir) { $dir } else { "?" }
    $planCount = Get-PhasePlanCount $phase
    $summaryCount = Get-PhaseSummaryCount $phase
    $progress = if ($planCount -gt 0) { "$summaryCount/$planCount" } else { "-" }
    $color = switch ($status) {
        "complete"   { "Green" }
        "planned"    { "Cyan" }
        "researched" { "Yellow" }
        "pending"    { "White" }
        default      { "DarkGray" }
    }
    Write-Host "    $icon Phase ${phase}: $($status.ToUpper().PadRight(12)) plans: $($progress.PadRight(5)) ($dirLabel)" -ForegroundColor $color
}
Write-Host ""

if ($DryRun) {
    Show-ExecutionPlan $targetPhases
    Write-Host ""
    Write-Host "  Re-run without -DryRun to execute." -ForegroundColor Yellow
    exit 0
}

Add-Content -Path $logFile -Value "`n--- Run started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | project=$projectName | phases $StartPhase-$EndPhase | skipResearch=$SkipResearch | skipPlan=$SkipPlanning | prepOnly=$PrepareOnly ---"

$stats = @{
    PhasesPrepared = 0; PhasesExecuted = 0
    PrepFailed = 0; ExecutionsFailed = 0
}

# ============================================================
#  STEP 1: Prepare all phases in PARALLEL (research -> plan)
# ============================================================
if (-not $SkipPlanning) {
    Write-Banner "Step 1: Parallel Preparation (research -> plan)" "Yellow"

    # Build per-phase preparation pipelines
    $phasesToPrep = @()
    foreach ($phase in $targetPhases) {
        if (Test-PhaseComplete $phase) {
            Write-Log "  Phase ${phase}: already complete, skipping" "DarkGray"
            continue
        }
        $cmds = Get-PrepCommands $phase
        if ($cmds.Count -eq 0) {
            Write-Log "  Phase ${phase}: already prepared, skipping" "DarkGray"
            continue
        }
        $steps = Get-PrepSteps $phase
        $phasesToPrep += @{ Phase = $phase; Commands = $cmds; Steps = $steps }
    }

    if ($phasesToPrep.Count -eq 0) {
        Write-Log "  All phases already prepared. Skipping." "Green"
    } else {
        Write-Log "  Preparing $($phasesToPrep.Count) phases in parallel" "Yellow"

        # Launch all preparation pipelines in parallel
        # Each pipeline chains research -> plan with && (plan only runs if research succeeds)
        $prepProcs = @()
        foreach ($entry in $phasesToPrep) {
            $phase = $entry.Phase
            $cmds = $entry.Commands
            $steps = $entry.Steps
            $chainedCmd = $cmds -join " && "

            Write-Log "    [PREP] Phase ${phase}: launching ($($steps -join ' -> '))" "White"

            # Use cmd /c with set CLAUDECODE= to unset the env var for nested Claude sessions
            $cmd = "set CLAUDECODE=&& " + $chainedCmd
            $proc = Start-Process -FilePath "cmd.exe" `
                -ArgumentList "/c", $cmd `
                -NoNewWindow -PassThru -WorkingDirectory $projectRoot
            $prepProcs += @{
                Process = $proc
                Phase = $phase
                Start = Get-Date
                Steps = $steps
            }
        }

        # Watchdog: poll all preparation processes with timeout
        $deadline = (Get-Date).AddMinutes($PrepTimeout)
        $lastReport = Get-Date
        Write-Log "    [PREP] Waiting for $($prepProcs.Count) pipelines (timeout ${PrepTimeout}m)..." "Gray"

        while ($prepProcs | Where-Object { -not $_.Process.HasExited }) {
            if ((Get-Date) -gt $deadline) {
                Write-Log "    [WATCHDOG] TIMEOUT: prep deadline ${PrepTimeout}m reached - killing remaining" "Red"
                foreach ($entry in ($prepProcs | Where-Object { -not $_.Process.HasExited })) {
                    Write-Log "    [WATCHDOG] Killing prep for phase $($entry.Phase)" "Red"
                    try { $entry.Process.Kill() } catch {}
                }
                break
            }
            if (((Get-Date) - $lastReport).TotalSeconds -ge 30) {
                $running = @($prepProcs | Where-Object { -not $_.Process.HasExited }).Count
                $done = $prepProcs.Count - $running
                $elapsed = [math]::Round(((Get-Date) - $prepProcs[0].Start).TotalMinutes, 1)
                Write-Host "    ... [PREP] $done/$($prepProcs.Count) done (${elapsed}m elapsed, $running running)" -ForegroundColor DarkGray
                $lastReport = Get-Date
            }
            Start-Sleep -Seconds 5
        }

        # Collect preparation results
        Write-Log "" "White"
        Write-Log "  Preparation Results:" "Cyan"
        foreach ($entry in $prepProcs) {
            $duration = [math]::Round(((Get-Date) - $entry.Start).TotalMinutes, 1)
            $pipeline = $entry.Steps -join " -> "
            if (-not $entry.Process.HasExited) {
                Write-Log "    Phase $($entry.Phase) ($pipeline): TIMED OUT after ${duration}m" "Red"
                $stats.PrepFailed++
            } elseif ($entry.Process.ExitCode -eq 0) {
                $stats.PhasesPrepared++
                Write-Log "    Phase $($entry.Phase) ($pipeline): DONE in ${duration}m" "Green"
            } else {
                Write-Log "    Phase $($entry.Phase) ($pipeline): FAILED (exit $($entry.Process.ExitCode)) after ${duration}m" "Red"
                $stats.PrepFailed++
            }
        }

        Write-Log "" "White"
        $prepColor = if ($stats.PrepFailed -gt 0) { "Yellow" } else { "Green" }
        Write-Log "  Preparation complete: $($stats.PhasesPrepared) succeeded, $($stats.PrepFailed) failed" $prepColor

        if ($stats.PrepFailed -gt 0 -and -not $PrepareOnly) {
            Write-Log "  WARNING: $($stats.PrepFailed) phase(s) failed. Execution will skip them." "Yellow"
        }

        Start-Sleep -Seconds 5
    }
} else {
    Write-Log "  Preparation skipped (-SkipPlanning flag)" "DarkGray"
}

# ============================================================
#  STEP 2: Execute phases ONE AT A TIME (sequential)
# ============================================================
if (-not $PrepareOnly) {
    Write-Banner "Step 2: Sequential Execution" "Cyan"

    $execSkill = if ($UseWaveParallel) { "/gsd:execute-phase" } else { "/gsd:batch-execute" }
    Write-Log "  Execution skill: $execSkill" "Gray"
    Write-Log "" "White"

    foreach ($phase in $targetPhases) {
        if (Test-PhaseComplete $phase) {
            Write-Log "  Phase ${phase}: already complete, skipping" "DarkGray"
            continue
        }

        if (-not (Test-PhaseHasPlans $phase)) {
            Write-Log "  Phase ${phase}: no plans found, skipping (preparation may have failed)" "Yellow"
            $stats.ExecutionsFailed++
            continue
        }

        $dir = Get-PhaseDir $phase
        Write-Banner "Executing Phase $phase ($dir)" "White"

        $prompt = "$execSkill $phase"
        Write-Log "    [EXECUTOR] Running: $prompt" "White"
        Write-Log "    [EXECUTOR] Timeout: ${ExecuteTimeout}m | max-turns: $MaxTurns" "DarkGray"

        $result = Invoke-ClaudeWithTimeout -Prompt $prompt -TimeoutMinutes $ExecuteTimeout -Turns $MaxTurns -Label "execute-phase-$phase"

        if ($result.TimedOut) {
            Write-Log "    [EXECUTOR] Phase $phase TIMED OUT after $($result.Duration)m" "Red"
            $stats.ExecutionsFailed++
            Write-Log "    Continuing to next phase..." "Yellow"
        } elseif ($result.Success) {
            $stats.PhasesExecuted++
            Write-Log "    [EXECUTOR] Phase $phase COMPLETE in $($result.Duration)m" "Green"
        } else {
            Write-Log "    [EXECUTOR] Phase $phase FAILED (exit $($result.ExitCode)) after $($result.Duration)m" "Red"
            $stats.ExecutionsFailed++
            Write-Log "    Continuing to next phase..." "Yellow"
        }

        Start-Sleep -Seconds 5
    }
} else {
    Write-Log "  Execution skipped (-PrepareOnly flag)" "DarkGray"
}

# ============================================================
#  STEP 3: Continuous Improvement Loop (review -> remediate -> repeat)
# ============================================================
$ciStats = @{
    Iterations = 0; ReviewsRun = 0
    RemediationPhasesCreated = 0; RemediationPhasesExecuted = 0
    InitialScore = $null; FinalScore = $null; StopReason = "Not started"
    IterationHistory = @()
}

if ($ContinuousImprovement -and -not $PrepareOnly -and -not $DryRun) {
    Write-Banner "Step 3: Continuous Improvement Loop" "Magenta"
    Write-Log "  Target score: ${TargetScore}/100 with 0 blockers" "White"
    Write-Log "  Max iterations: $MaxIterations" "White"
    Write-Log "  Review timeout: ${ReviewTimeout}m" "White"
    if ($StopOnNoImprovement) { Write-Log "  Stop on no improvement: YES" "Yellow" }
    Write-Log "" "White"

    $previousHealth = $null

    for ($iteration = 1; $iteration -le $MaxIterations; $iteration++) {
        Write-IterationHeader -Iteration $iteration -MaxIter $MaxIterations -PreviousHealth $previousHealth

        $iterStart = Get-Date
        $iterRecord = @{ Iteration = $iteration; Score = $null; PhasesCreated = 0; PhasesExecuted = 0; StopReason = "" }

        # ---- 3a. Run code review ----
        Write-Log "  [CI] Running code review (iteration $iteration)..." "Cyan"
        $reviewResult = Invoke-ClaudeWithTimeout `
            -Prompt "/gsd:code-review" `
            -TimeoutMinutes $ReviewTimeout `
            -Turns $MaxTurns `
            -Label "code-review-iter-$iteration"
        $ciStats.ReviewsRun++

        if ($reviewResult.TimedOut) {
            Write-Log "  [CI] Code review TIMED OUT after $($reviewResult.Duration)m" "Red"
            $ciStats.StopReason = "Code review timed out on iteration $iteration"
            $iterRecord.StopReason = "review-timeout"
            $ciStats.IterationHistory += $iterRecord
            break
        }
        if (-not $reviewResult.Success) {
            Write-Log "  [CI] Code review FAILED (exit $($reviewResult.ExitCode)) after $($reviewResult.Duration)m" "Red"
            $ciStats.StopReason = "Code review failed on iteration $iteration (exit $($reviewResult.ExitCode))"
            $iterRecord.StopReason = "review-failed"
            $ciStats.IterationHistory += $iterRecord
            break
        }
        Write-Log "  [CI] Code review completed in $($reviewResult.Duration)m" "Green"

        # ---- 3b. Parse health score from captured output ----
        Start-Sleep -Seconds 3  # Let file writes settle
        # Try to parse from captured output first, then fall back to file
        $reviewOutput = $reviewResult.Output
        if ($reviewOutput) {
            $health = Get-ReviewHealthScore -Content $reviewOutput
        }
        if (-not $health) {
            $health = Get-ReviewHealthScore  # Try file as fallback
        }
        if ($health) {
            $iterRecord.Score = $health.Score
            Write-Log "  [CI] Health: $($health.Score)/100 (Grade: $($health.Grade)) | Blockers: $($health.Blockers) High: $($health.High) Med: $($health.Medium) Low: $($health.Low)" "White"
            if ($null -eq $ciStats.InitialScore) { $ciStats.InitialScore = $health.Score }
            $ciStats.FinalScore = $health.Score
        }

        # ---- 3c. Show improvement and check stopping conditions ----
        if ($previousHealth -and $health) {
            Write-HealthImprovement -Previous $previousHealth -Current $health
        }

        $stopCheck = Test-ShouldStopIteration `
            -Health $health `
            -PreviousHealth $previousHealth `
            -Target $TargetScore `
            -CheckNoImprovement:$StopOnNoImprovement

        if ($stopCheck.ShouldStop) {
            Write-Log "  [CI] STOPPING: $($stopCheck.Reason)" "Green"
            $ciStats.StopReason = $stopCheck.Reason
            $iterRecord.StopReason = $stopCheck.Reason
            $ciStats.Iterations = $iteration
            $ciStats.IterationHistory += $iterRecord
            break
        }
        Write-Log "  [CI] $($stopCheck.Reason)" "Yellow"

        # ---- 3d. Create remediation phases from findings ----
        Write-Log "  [CI] Creating remediation phases from review findings..." "Cyan"

        # Direct approach: parse PRIORITIZED-TASKS.md and add phases to ROADMAP.md
        $tasksPath = Join-Path $projectRoot "docs\review\PRIORITIZED-TASKS.md"
        $roadmapPath = Join-Path $projectRoot ".planning\ROADMAP.md"

        if (-not (Test-Path $tasksPath)) {
            Write-Log "  [CI] PRIORITIZED-TASKS.md not found at $tasksPath" "Red"
            $ciStats.StopReason = "PRIORITIZED-TASKS.md not found"
            $iterRecord.StopReason = "no-tasks-file"
            $ciStats.IterationHistory += $iterRecord
            break
        }

        $tasksContent = Get-Content $tasksPath -Raw

        # Extract BLOCKER and HIGH findings
        $blockerFindings = @()
        $highFindings = @()

        # Parse lines like: "1. **[BLOCKER] Fix Database TenantId Type Mismatch** -"
        # Use simpler string operations instead of complex regex
        $lines = $tasksContent -split "`r?`n"
        foreach ($line in $lines) {
            $line = $line.Trim()
            if ($line.StartsWith("1. ") -or $line.StartsWith("2. ") -or $line.StartsWith("3. ") -or $line.StartsWith("4. ") -or $line.StartsWith("5. ")) {
                # Check for BLOCKER
                if ($line -match 'BLOCKER') {
                    # Extract title between **[BLOCKER] and **
                    if ($line -match '\[BLOCKER\]\s+(.+?)\*\*') {
                        $title = $Matches[1].Trim()
                        $blockerFindings += $title
                        Write-Log "    [DEBUG] Found BLOCKER: $title" "DarkGray"
                    }
                }
                # Check for HIGH
                if ($line -match 'HIGH' -and $line -notmatch 'BLOCKER') {
                    if ($line -match '\[HIGH\]\s+(.+?)\*\*') {
                        $title = $Matches[1].Trim()
                        $highFindings += $title
                        Write-Log "    [DEBUG] Found HIGH: $title" "DarkGray"
                    }
                }
            }
        }

        Write-Log "  [CI] Found $($blockerFindings.Count) BLOCKER and $($highFindings.Count) HIGH findings" "White"

        if ($blockerFindings.Count -eq 0 -and $highFindings.Count -eq 0) {
            Write-Log "  [CI] No BLOCKER or HIGH findings to remediate" "Green"
            $ciStats.StopReason = "No critical findings to remediate"
            $iterRecord.StopReason = "no-critical-findings"
            $ciStats.IterationHistory += $iterRecord
            break
        }

        # Create phases
        $phaseNum = 20  # Start after existing phases
        $roadmap = Get-Content $roadmapPath -Raw

        # Find next phase number
        if ($roadmap -match 'Phase (\d+):') {
            $existingPhases = [regex]::Matches($roadmap, 'Phase (\d+):')
            $maxPhase = 0
            foreach ($m in $existingPhases) {
                if ([int]$m.Groups[1].Value -gt $maxPhase) {
                    $maxPhase = [int]$m.Groups[1].Value
                }
            }
            $phaseNum = $maxPhase + 1
        }

        $newPhases = @()

        # Phase 1: Fix BLOCKERs
        if ($blockerFindings.Count -gt 0) {
            $phaseName = "20-fix-blockers"
            $description = "Fix BLOCKER findings: " + ($blockerFindings[0..[Math]::Min(2, $blockerFindings.Count-1)] -join ", ")
            if ($blockerFindings.Count -gt 3) {
                $description += " and $($blockerFindings.Count - 3) more"
            }

            $phaseDir = "$($phaseNum.ToString('00'))-$phaseName"
            $phaseDirPath = Join-Path $projectRoot ".planning\phases\$phaseDir"
            if (-not (Test-Path $phaseDirPath)) {
                New-Item -ItemType Directory -Path $phaseDirPath -Force | Out-Null
            }

            # Add to ROADMAP.md before Progress section
            $phaseEntry = @"

- [ ] **Phase ${phaseNum}: ${phaseName}** — $description
  - **Goal:** Fix $($blockerFindings.Count) BLOCKER issues identified in code review
  - **Plans:** 1 plan
  Plans:
  - [ ] $phaseNum-01-PLAN.md — Fix all BLOCKER findings: $($blockerFindings -join "; ")

"@
            $roadmap = $roadmap -replace '(?=## Progress)', $phaseEntry
            $newPhases += $phaseNum
            Write-Log "  [CI] Created Phase ${phaseNum}: ${phaseName}" "Green"
            $phaseNum++
        }

        # Phase 2: Fix HIGHs
        if ($highFindings.Count -gt 0) {
            $phaseName = "21-fix-high"
            $description = "Fix HIGH findings: " + ($highFindings[0..[Math]::Min(2, $highFindings.Count-1)] -join ", ")
            if ($highFindings.Count -gt 3) {
                $description += " and $($highFindings.Count - 3) more"
            }

            $phaseDir = "$($phaseNum.ToString('00'))-$phaseName"
            $phaseDirPath = Join-Path $projectRoot ".planning\phases\$phaseDir"
            if (-not (Test-Path $phaseDirPath)) {
                New-Item -ItemType Directory -Path $phaseDirPath -Force | Out-Null
            }

            $phaseEntry = @"

- [ ] **Phase ${phaseNum}: ${phaseName}** — $description
  - **Goal:** Fix $($highFindings.Count) HIGH issues identified in code review
  - **Plans:** 1 plan
  Plans:
  - [ ] $phaseNum-01-PLAN.md — Fix all HIGH findings: $($highFindings -join "; ")

"@
            $roadmap = $roadmap -replace '(?=## Progress)', $phaseEntry
            $newPhases += $phaseNum
            Write-Log "  [CI] Created Phase ${phaseNum}: ${phaseName}" "Green"
            $phaseNum++
        }

        # Save ROADMAP
        Set-Content -Path $roadmapPath -Value $roadmap -NoNewline
        Write-Log "  [CI] Added $($newPhases.Count) remediation phases to ROADMAP.md" "Green"

        # Create PLAN files for new phases
        $phase20Findings = $blockerFindings
        $phase21Findings = $highFindings

        foreach ($phase in $newPhases) {
            $phaseDir = Get-PhaseDir $phase
            if ($phaseDir) {
                $planFile = Join-Path $projectRoot ".planning\phases\$phaseDir\$phase-01-PLAN.md"
                if (-not (Test-Path $planFile)) {
                    # Determine which findings to include
                    $findings = $null
                    if ($phase -eq 20 -and $phase20Findings.Count -gt 0) {
                        $findings = $phase20Findings
                    }
                    elseif ($phase -ge 21 -and $phase21Findings.Count -gt 0) {
                        $findings = $phase21Findings
                    }

                    if ($findings -and $findings.Count -gt 0) {
                        $tasksList = ($findings | ForEach-Object { "  - [ ] $_" }) -join "`n"
                        $planContent = @"
# Plan: Phase $phase Remediation

## Tasks

$tasksList

## Verification

- [ ] All findings addressed
- [ ] Code compiles without errors
- [ ] Tests pass
"@
                        Set-Content -Path $planFile -Value $planContent -NoNewline
                        Write-Log "  [CI] Created $planFile" "Green"
                    }
                }
            }
        }

        # ---- 3e. Detect new pending phases ----
        Start-Sleep -Seconds 3
        $newPending = Get-PendingPhases
        if ($newPending.Count -eq 0) {
            Write-Log "  [CI] No new pending phases found after remediation. Nothing to execute." "Yellow"
            $ciStats.StopReason = "No new phases created on iteration $iteration"
            $iterRecord.StopReason = "no-new-phases"
            $ciStats.Iterations = $iteration
            $ciStats.IterationHistory += $iterRecord
            break
        }

        $iterRecord.PhasesCreated = $newPending.Count
        $ciStats.RemediationPhasesCreated += $newPending.Count
        Write-Log "  [CI] Found $($newPending.Count) new pending phases: $($newPending -join ', ')" "Cyan"

        # ---- 3f. Prepare new phases (parallel research -> plan) ----
        $needsPrep = @()
        foreach ($phase in $newPending) {
            $cmds = Get-PrepCommands $phase
            if ($cmds.Count -gt 0) {
                $steps = Get-PrepSteps $phase
                $needsPrep += @{ Phase = $phase; Commands = $cmds; Steps = $steps }
            }
        }

        if ($needsPrep.Count -gt 0) {
            Write-Log "  [CI] Preparing $($needsPrep.Count) remediation phases in parallel..." "Yellow"

            $prepProcs = @()
            foreach ($entry in $needsPrep) {
                $phase = $entry.Phase
                $cmds = $entry.Commands
                $steps = $entry.Steps
                $chainedCmd = $cmds -join " && "

                Write-Log "    [PREP] Phase ${phase}: launching ($($steps -join ' -> '))" "White"

                # Use cmd /c with set CLAUDECODE= to unset the env var for nested Claude sessions
                $cmd = "set CLAUDECODE=&& " + $chainedCmd
                $proc = Start-Process -FilePath "cmd.exe" `
                    -ArgumentList "/c", $cmd `
                    -NoNewWindow -PassThru -WorkingDirectory $projectRoot
                $prepProcs += @{ Process = $proc; Phase = $phase; Start = Get-Date; Steps = $steps }
            }

            # Watchdog for prep
            $prepDeadline = (Get-Date).AddMinutes($PrepTimeout)
            $lastPrepReport = Get-Date
            while ($prepProcs | Where-Object { -not $_.Process.HasExited }) {
                if ((Get-Date) -gt $prepDeadline) {
                    Write-Log "    [WATCHDOG] TIMEOUT: remediation prep deadline reached - killing" "Red"
                    foreach ($entry in ($prepProcs | Where-Object { -not $_.Process.HasExited })) {
                        try { $entry.Process.Kill() } catch {}
                    }
                    break
                }
                if (((Get-Date) - $lastPrepReport).TotalSeconds -ge 30) {
                    $running = @($prepProcs | Where-Object { -not $_.Process.HasExited }).Count
                    Write-Host "    ... [CI-PREP] $($prepProcs.Count - $running)/$($prepProcs.Count) done ($running running)" -ForegroundColor DarkGray
                    $lastPrepReport = Get-Date
                }
                Start-Sleep -Seconds 5
            }

            foreach ($entry in $prepProcs) {
                $duration = [math]::Round(((Get-Date) - $entry.Start).TotalMinutes, 1)
                if ($entry.Process.HasExited -and $entry.Process.ExitCode -eq 0) {
                    Write-Log "    [CI-PREP] Phase $($entry.Phase): DONE in ${duration}m" "Green"
                } else {
                    Write-Log "    [CI-PREP] Phase $($entry.Phase): FAILED/TIMEOUT after ${duration}m" "Red"
                }
            }
        }

        # ---- 3g. Execute remediation phases sequentially ----
        $execSkill = if ($UseWaveParallel) { "/gsd:execute-phase" } else { "/gsd:batch-execute" }
        $phasesExecutedThisIter = 0

        foreach ($phase in $newPending) {
            if (Test-PhaseComplete $phase) {
                Write-Log "    [CI-EXEC] Phase ${phase}: already complete" "DarkGray"
                continue
            }
            if (-not (Test-PhaseHasPlans $phase)) {
                Write-Log "    [CI-EXEC] Phase ${phase}: no plans, skipping" "Yellow"
                continue
            }

            $dir = Get-PhaseDir $phase
            Write-Log "    [CI-EXEC] Executing Phase $phase ($dir)..." "White"

            $execResult = Invoke-ClaudeWithTimeout `
                -Prompt "$execSkill $phase" `
                -TimeoutMinutes $ExecuteTimeout `
                -Turns $MaxTurns `
                -Label "ci-execute-phase-$phase"

            if ($execResult.Success) {
                $phasesExecutedThisIter++
                $ciStats.RemediationPhasesExecuted++
                Write-Log "    [CI-EXEC] Phase $phase COMPLETE in $($execResult.Duration)m" "Green"
            } else {
                $status = if ($execResult.TimedOut) { "TIMED OUT" } else { "FAILED" }
                Write-Log "    [CI-EXEC] Phase $phase $status after $($execResult.Duration)m" "Red"
            }

            Start-Sleep -Seconds 3
        }

        $iterRecord.PhasesExecuted = $phasesExecutedThisIter
        Write-Log "  [CI] Iteration $iteration complete: $phasesExecutedThisIter phases executed" "Cyan"

        # ---- 3h. Track iteration ----
        $ciStats.Iterations = $iteration
        $previousHealth = $health
        $ciStats.IterationHistory += $iterRecord

        $iterDuration = [math]::Round(((Get-Date) - $iterStart).TotalMinutes, 1)
        Write-Log "  [CI] Iteration $iteration duration: ${iterDuration}m" "Gray"

        Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] CI iteration ${iteration}: score=$($health.Score) blockers=$($health.Blockers) phases_created=$($iterRecord.PhasesCreated) phases_executed=${phasesExecutedThisIter} duration=${iterDuration}m"

        Start-Sleep -Seconds 5
    }

    # Check if we exhausted max iterations without reaching target
    if ($ciStats.Iterations -ge $MaxIterations -and $ciStats.StopReason -eq "Not started") {
        $ciStats.StopReason = "Max iterations ($MaxIterations) reached"
    }
}

# ============================================================
#  Final summary
# ============================================================
$totalDuration = (Get-Date) - $startTime
$totalFailed = $stats.PrepFailed + $stats.ExecutionsFailed

Write-Banner "Run Complete"
Write-Host "  Project:             $projectName" -ForegroundColor White
Write-Host "  Phases prepared:     $($stats.PhasesPrepared) (parallel: research -> plan)" -ForegroundColor White
Write-Host "  Phases executed:     $($stats.PhasesExecuted) (sequential)" -ForegroundColor White
Write-Host "  Prep failures:       $($stats.PrepFailed)" -ForegroundColor $(if ($stats.PrepFailed -gt 0) { "Yellow" } else { "Green" })
Write-Host "  Execution failures:  $($stats.ExecutionsFailed)" -ForegroundColor $(if ($stats.ExecutionsFailed -gt 0) { "Yellow" } else { "Green" })

# Continuous Improvement summary
if ($ContinuousImprovement -and $ciStats.ReviewsRun -gt 0) {
    Write-Host "" -ForegroundColor White
    Write-Host "  --- Continuous Improvement ---" -ForegroundColor Magenta
    Write-Host "  CI iterations:       $($ciStats.Iterations) / $MaxIterations" -ForegroundColor White
    Write-Host "  Code reviews run:    $($ciStats.ReviewsRun)" -ForegroundColor White
    Write-Host "  Remediation created: $($ciStats.RemediationPhasesCreated) phases" -ForegroundColor White
    Write-Host "  Remediation executed:$($ciStats.RemediationPhasesExecuted) phases" -ForegroundColor White

    if ($ciStats.InitialScore -and $ciStats.FinalScore) {
        $scoreDelta = $ciStats.FinalScore - $ciStats.InitialScore
        $scoreArrow = if ($scoreDelta -gt 0) { "+$scoreDelta" } elseif ($scoreDelta -lt 0) { "$scoreDelta" } else { "no change" }
        $scoreColor = if ($ciStats.FinalScore -ge $TargetScore) { "Green" } elseif ($ciStats.FinalScore -ge 70) { "Yellow" } else { "Red" }
        Write-Host "  Initial score:       $($ciStats.InitialScore)/100" -ForegroundColor Gray
        Write-Host "  Final score:         $($ciStats.FinalScore)/100 ($scoreArrow)" -ForegroundColor $scoreColor
    }

    $stopColor = if ($ciStats.StopReason -match "Target reached") { "Green" } else { "Yellow" }
    Write-Host "  Stop reason:         $($ciStats.StopReason)" -ForegroundColor $stopColor

    # Iteration history table
    if ($ciStats.IterationHistory.Count -gt 0) {
        Write-Host "" -ForegroundColor White
        Write-Host "  Iteration History:" -ForegroundColor DarkMagenta
        foreach ($iter in $ciStats.IterationHistory) {
            $scoreStr = if ($iter.Score) { "$($iter.Score)/100" } else { "N/A" }
            Write-Host "    [$($iter.Iteration)] Score: $scoreStr | Created: $($iter.PhasesCreated) | Executed: $($iter.PhasesExecuted)" -ForegroundColor DarkGray
        }
    }
} elseif ($ContinuousImprovement) {
    Write-Host "" -ForegroundColor White
    Write-Host "  --- Continuous Improvement ---" -ForegroundColor Magenta
    Write-Host "  CI loop: did not run (PrepareOnly or DryRun)" -ForegroundColor DarkGray
}

Write-Host "" -ForegroundColor White
Write-Host "  Total duration:      $([math]::Round($totalDuration.TotalMinutes,1)) minutes" -ForegroundColor White
Write-Host "  Log file:            $logFile" -ForegroundColor Gray
Write-Host ""

$ciLogSuffix = ""
if ($ContinuousImprovement -and $ciStats.ReviewsRun -gt 0) {
    $ciLogSuffix = " | ci_iterations=$($ciStats.Iterations) reviews=$($ciStats.ReviewsRun) remediation_created=$($ciStats.RemediationPhasesCreated) remediation_executed=$($ciStats.RemediationPhasesExecuted) initial_score=$($ciStats.InitialScore) final_score=$($ciStats.FinalScore) stop_reason='$($ciStats.StopReason)'"
}
$completionMsg = "--- Run completed $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | project=$projectName | prepared=$($stats.PhasesPrepared) executed=$($stats.PhasesExecuted) failed=$totalFailed | $([math]::Round($totalDuration.TotalMinutes,1)) min${ciLogSuffix} ---"
Add-Content -Path $logFile -Value $completionMsg
