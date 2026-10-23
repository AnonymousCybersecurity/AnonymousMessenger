# Shared CLI dispatch. Validate arguments in the caller before doing even read-only discovery.
function Invoke-MessengerWorkflow {
    param([string[]]$Fields)
    $ghCommand = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ghCommand) { throw 'GitHub CLI (gh) is required. Install it and run gh auth login.' }
    $remote = & git remote get-url origin
    if ($LASTEXITCODE -ne 0 -or $remote -cnotmatch '^(?:https://github\.com/|git@github\.com:)AnonymousCybersecurity/AnonymousMessenger(?:\.git)?$') {
        throw 'origin must be AnonymousCybersecurity/AnonymousMessenger on github.com.'
    }
    $repositoryJson = & $ghCommand.Source repo view AnonymousCybersecurity/AnonymousMessenger --json nameWithOwner,defaultBranchRef
    if ($LASTEXITCODE -ne 0) { return $LASTEXITCODE }
    $repository = ($repositoryJson -join "`n") | ConvertFrom-Json
    if ($repository.nameWithOwner -cne 'AnonymousCybersecurity/AnonymousMessenger' -or $repository.defaultBranchRef.name -cne 'main') {
        throw 'Repository/default branch changed. Review workflow identity guards before dispatching.'
    }
    $dispatchArguments = @('workflow', 'run', 'android-play.yml', '--repo', $repository.nameWithOwner, '--ref', $repository.defaultBranchRef.name)
    foreach ($field in $Fields) { $dispatchArguments += @('-f', $field) }
    Write-Host "Requesting $($Fields -join ', ') from pushed $($repository.nameWithOwner)/$($repository.defaultBranchRef.name)."
    & $ghCommand.Source @dispatchArguments | Out-Host
    return $LASTEXITCODE
}
