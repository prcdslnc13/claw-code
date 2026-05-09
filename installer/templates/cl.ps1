#!/usr/bin/env pwsh
# claw wrapper: injects LMStudio (OpenAI-compat) defaults. Override either
# variable from the environment to point at a different backend.
if (-not $env:OPENAI_BASE_URL) { $env:OPENAI_BASE_URL = '__LMSTUDIO_URL__' }
if (-not $env:OPENAI_API_KEY)  { $env:OPENAI_API_KEY  = 'unused' }
& claw.exe @args
exit $LASTEXITCODE
