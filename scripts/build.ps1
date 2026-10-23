# Windows build commands: current local Gradle outputs, or a saved build from CI.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$buildArguments = @($args)
$projectRoot = Split-Path $PSScriptRoot -Parent

function Show-BuildHelp {
    @'
Usage: .\build COMMAND

Local builds (current local files; requires the Android/JDK toolchain):
  apk                                   Signed release APK
  aab                                   Signed release AAB
  both                                  Both local outputs

CI build (pushed main; requires authenticated GitHub CLI):
  ci                                    Check/build signed AAB and save an Actions artifact

  help | --help | -h                     Show this command list

Builds do not publish. No local Ruby or npm is required.
For release preparation, publishing or promotion, run .\release --help.
'@ | Write-Output
}

try {
    if ($buildArguments.Count -eq 0) {
        Show-BuildHelp
        exit 0
    }
    $command = [string]$buildArguments[0]
    if ($buildArguments.Count -ne 1) { throw '.\build accepts one command: apk, aab, both or ci.' }
    $task = $null
    switch -CaseSensitive ($command) {
        { $_ -cin @('help', '--help', '-h') } { Show-BuildHelp; exit 0 }
        'apk' { $task = 'buildLocalApk' }
        'aab' { $task = 'buildLocalAab' }
        'both' { $task = 'buildLocalBoth' }
        'ci' { }
        default { throw "Unknown build command '$command'. Run .\build --help." }
    }

    $previousPromptSetting = $env:GH_PROMPT_DISABLED
    Push-Location -LiteralPath $projectRoot
    try {
        if ($command -ceq 'ci') {
            . (Join-Path $PSScriptRoot 'dispatch.ps1')
            $env:GH_PROMPT_DISABLED = '1'
            $commandExitCode = Invoke-MessengerWorkflow -Fields @('action=build')
        } else {
            & (Join-Path $projectRoot 'gradlew.bat') $task
        }
        if ($command -cne 'ci') { $commandExitCode = $LASTEXITCODE }
    } finally {
        $env:GH_PROMPT_DISABLED = $previousPromptSetting
        Pop-Location
    }
    exit $commandExitCode
} catch {
    [Console]::Error.WriteLine("Build command failed: $($_.Exception.Message)")
    exit 1
}
