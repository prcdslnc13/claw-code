#!/usr/bin/env pwsh
# claw wrapper: injects LMStudio (OpenAI-compat) defaults. Override either
# variable from the environment to point at a different backend.
#
# Also injects a default --model when the caller didn't pass one. The
# default also lives in %USERPROFILE%\.claw\settings.json (`"model": ...`)
# but `claw status` and `claw prompt` resolve the model on different paths
# on the current build — prompt mode doesn't honor the config-resolved
# model for provider routing — so we inject explicitly. Mirrors the POSIX
# `cl` wrapper.
if (-not $env:OPENAI_BASE_URL) { $env:OPENAI_BASE_URL = '__LMSTUDIO_URL__' }
if (-not $env:OPENAI_API_KEY)  { $env:OPENAI_API_KEY  = 'unused' }

$DefaultModel = '__DEFAULT_MODEL__'

$hasModel = $false
foreach ($a in $args) {
    if ($a -eq '--model' -or ($a -is [string] -and $a -like '--model=*')) {
        $hasModel = $true
        break
    }
}

if (-not $hasModel) {
    $args = @('--model', $DefaultModel) + $args
}

& claw.exe @args
exit $LASTEXITCODE
