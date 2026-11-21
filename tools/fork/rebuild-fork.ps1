# Rebuilds the fork's integration branch from scratch: upstream/main, then every branch of this fork
# that has an open pull request upstream, then every origin/pr/* and origin/fork/* branch, merged in that order.
#
# Branches:
#   main      a copy of upstream/main; never committed to
#   pr/*      one change for one upstream pull request, cut from upstream/main
#   fork/*    changes kept on this fork only (this script lives on fork/tools)
#   chad      the integration branch this script writes; never edited by hand
#
# A pull request that upstream merges or closes drops out on the next rebuild: delete its branch afterwards.
# A merge conflict stops the script. Resolve it, run `git commit --no-edit`, then run the script again:
# rerere (enabled below) replays that resolution on every later rebuild. Generated files such as parity/
# are better regenerated than merged by hand.
#
# Usage: .\tools\fork\rebuild-fork.ps1 [-NoPush] [-Branch chad] [-Upstream srlegrand/Aztek]

param(
    [string]$Branch = 'chad',
    [string]$Upstream = 'srlegrand/Aztek',
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed" }
}

function Get-OpenPrBranches {
    $me = gh api user --jq .login
    if ($LASTEXITCODE -ne 0) { throw 'gh is not signed in' }
    $json = gh pr list --repo $Upstream --author '@me' --state open --limit 200 --json headRefName,headRepositoryOwner
    if ($LASTEXITCODE -ne 0) { throw "could not list pull requests on $Upstream" }
    $prs = $json | ConvertFrom-Json
    $prs | Where-Object { $_.headRepositoryOwner.login -eq $me } | ForEach-Object { "origin/$($_.headRefName)" }
}

function Get-TopicBranches {
    git for-each-ref --format='%(refname:short)' refs/remotes/origin/pr/ refs/remotes/origin/fork/
}

function Merge-Topic([string]$ref) {
    Write-Host "== merging $ref"
    git merge --no-edit --no-ff $ref
    if ($LASTEXITCODE -eq 0) { return }
    $unmerged = git diff --name-only --diff-filter=U
    if (-not $unmerged) {
        Write-Host "   rerere resolved the conflicts"
        Invoke-Git commit --no-edit
        return
    }
    Write-Host "Conflicts merging ${ref}:" -ForegroundColor Red
    $unmerged | ForEach-Object { Write-Host "   $_" }
    Write-Host "Resolve them, run 'git commit --no-edit', then run this script again." -ForegroundColor Red
    exit 1
}

if (git status --porcelain --untracked-files=no) { throw 'The working tree has uncommitted changes' }

Invoke-Git config rerere.enabled true
Invoke-Git config rerere.autoupdate true
Invoke-Git fetch upstream
Invoke-Git fetch origin --prune

$topics = @(Get-OpenPrBranches) + @(Get-TopicBranches) | Select-Object -Unique
Invoke-Git switch --no-track -C $Branch upstream/main
foreach ($ref in $topics) {
    git rev-parse --verify --quiet "$ref^{commit}" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "== skipping $ref (not on origin)"; continue }
    Merge-Topic $ref
}

if (-not $NoPush) { Invoke-Git push --force-with-lease origin $Branch }
Write-Host "$Branch rebuilt from upstream/main with $($topics.Count) branches"
