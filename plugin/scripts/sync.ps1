# agents-kit: свести базу знаний или личный репозиторий оператора с их remote — забрать, отдать
# или доделать сведение, вставшее на конфликте.
#   pwsh -NoProfile -File scripts\sync.ps1 -Path <рабочая копия> -Repo Base|Personal -Action Pull|Push|Continue
#        [-Keep <файл конфликта>=Remote|Local ...]
#
# Remote — origin репозитория; нет его — сводить не с чем, и репозиторий живёт на этой машине.
# Pull забирает, Push забирает и отдаёт, Continue доделывает сведение после конфликта, а базу
# ещё и отдаёт: личный репозиторий отдаётся только на закрытии задачи и по слову оператора.
# -Keep берёт у Continue файл конфликта целиком с одной стороны — для файла, куда ответ
# оператора текстом не записать.
# Конфликт остаётся идущим сведением: его видят хук и гейт, и работа со знанием стоит до разрешения.
# Коды: 0 — сведено или сводить не с чем; 1 — не сведено, что делать — в выводе; 2 — remote недоступен.
[CmdletBinding()]
param(
    [string]$Path,
    [Parameter(Mandatory = $true)][ValidateSet('Base', 'Personal')][string]$Repo,
    [Parameter(Mandatory = $true)][ValidateSet('Pull', 'Push', 'Continue')][string]$Action,
    [string[]]$Keep = @()
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
. (Join-Path $PSScriptRoot 'link-state.ps1')

# Логина git спросил бы в терминале, которого у сессии нет, и скрипт повис бы.
$env:GIT_TERMINAL_PROMPT = '0'

if (-not $Path) { $Path = (Get-Location).Path }
$state = Get-KitLinkState $Path

# Базу сводят, как только она опознана: скилл onboard забирает её до вопроса об имени оператора,
# перевод — до перевода, её могли перевести с другой машины. Личный репозиторий есть только
# у связанной копии.
$ready = @('Linked')
if ($Repo -eq 'Base') { $ready = @('Outdated', 'Newer', 'Unlisted', 'Unnamed', 'NoPersonal', 'Linked') }
$continuing = $false
if ($Action -eq 'Continue' -and $state.status -eq 'Unmerged') {
    $target = $state.base
    if ($Repo -eq 'Personal') { $target = Get-KitPersonalDir $state.base }
    $continuing = $state.unmerged -ieq $target
}
if (-not $continuing) {
    switch ($state.status) {
        'Unmerged' { Write-Host (Get-KitUnmergedProblem $state); exit 1 }
        { $_ -in $ready } { }
        default {
            Write-Host "копия «$Path» с базой не связана или связь разорвана — сводить нечего; link.ps1 без аргументов покажет, что именно"
            exit 1
        }
    }
}

if ($Repo -eq 'Base') {
    $dir = $state.base
    $gen = 'базы'
    $loc = 'базе'
}
else {
    $dir = Get-KitPersonalDir $state.base
    $gen = 'личного репозитория'
    $loc = 'личном репозитории'
}

# Вывод git нужен целиком — его строка уходит оператору; отказ git здесь не исключение, а ответ.
function Invoke-SyncGit([string[]]$GitArgs) {
    $ErrorActionPreference = 'Continue'
    $out = & git -C $dir @GitArgs 2>&1
    $code = $LASTEXITCODE
    $lines = @($out | ForEach-Object { $_.ToString().TrimEnd() } | Where-Object { $_ })
    return [pscustomobject]@{ ok = ($code -eq 0); lines = $lines; text = ($lines -join '; ') }
}

function Stop-Unmerged {
    Write-Host "Работа со знанием остановлена до разрешения: $(Get-KitUnmergedProblem (Get-KitLinkState $Path))"
    exit 1
}

function Get-SyncBranch {
    $r = Invoke-SyncGit @('symbolic-ref', '--quiet', '--short', 'HEAD')
    if (-not $r.ok -or -not $r.lines.Count) {
        Write-Host "HEAD $gen «$dir» отсоединён от ветки — сводить нечего, решает оператор"
        exit 1
    }
    return $r.lines[0]
}

# Нет origin — выход с нулём: репозиторий без remote живёт на машине, и это не ошибка.
function Assert-SyncRemote {
    $r = Invoke-SyncGit @('remote', 'get-url', 'origin')
    if ($r.ok) { return }
    Write-Host "у $gen нет origin — сводить не с чем"
    exit 0
}

function Invoke-SyncFetch {
    $r = Invoke-SyncGit @('fetch', '-q', 'origin')
    if ($r.ok) { return }
    Write-Host "remote $gen недоступен: $($r.text) — работа идёт с локальным, отдастся при следующем сведении"
    exit 2
}

# Кто закоммитит незакоммиченную правку, мешающую забору. У базы прежнего формата гейт не пустит
# коммит ни одной сессии, и забор ждал бы вечно.
function Get-SyncDirtyHint {
    if ($state.status -eq 'Outdated') {
        return 'Сессии её не закоммитят, пока база прежнего формата: закоммитить её git из терминала решает оператор, затем забрать снова'
    }
    return 'Её закоммитит сессия, которая её ведёт; забрать при следующем сведении'
}

function Test-SyncRemoteBranch([string]$Branch) {
    return (Invoke-SyncGit @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$Branch")).ok
}

# Забрать: своего неотданного нет — перемотка, она идёт и при незакоммиченной правке соседней
# сессии в других файлах; есть — rebase, ему нужна чистая работа в отслеживаемых файлах.
function Invoke-SyncPull([string]$Branch) {
    Invoke-SyncFetch
    if (-not (Test-SyncRemoteBranch $Branch)) { Write-Host "на remote $gen ветки $Branch ещё нет — забирать нечего"; return }
    $counts = (Invoke-SyncGit @('rev-list', '--left-right', '--count', "HEAD...origin/$Branch")).lines[0] -split '\s+'
    $ahead = [int]$counts[0]
    $behind = [int]$counts[1]
    if ($behind -eq 0) { Write-Host "с remote $gen забирать нечего"; return }
    $fork = (Invoke-SyncGit @('merge-base', 'HEAD', "origin/$Branch")).lines[0]

    if ($ahead -eq 0) {
        $r = Invoke-SyncGit @('merge', '--ff-only', '-q', "origin/$Branch")
        if (-not $r.ok) {
            Write-Host "с remote $gen не забрано — git не перемотал: $($r.text). Незакоммиченная правка в этих файлах мешает. $(Get-SyncDirtyHint)"
            exit 1
        }
    }
    else {
        $dirty = @((Invoke-SyncGit @('status', '--porcelain', '--untracked-files=no')).lines | ForEach-Object { $_.Substring(3) })
        if ($dirty.Count) {
            Write-Host "с remote $gen не забрано — в $loc незакоммиченная правка: $($dirty -join ', '). $(Get-SyncDirtyHint)"
            exit 1
        }
        $r = Invoke-SyncGit @('-c', 'core.editor=true', 'rebase', '-q', "origin/$Branch")
        if (-not $r.ok) {
            if (Test-KitUnmerged $dir) { Stop-Unmerged }
            Write-Host "с remote $gen не забрано — git: $($r.text)"
            exit 1
        }
    }
    $files = @((Invoke-SyncGit @('diff', '--name-only', $fork, "origin/$Branch")).lines)
    Write-Host "с remote $gen забрано коммитов: $behind; пришли файлы: $($files -join ', ')"
}

# Отдать: сначала забрать; отказ remote — кто-то отдал раньше: забрать ещё раз и отдать снова.
function Invoke-SyncPush([string]$Branch) {
    for ($try = 1; $try -le 2; $try++) {
        Invoke-SyncPull $Branch
        $range = 'HEAD'
        if (Test-SyncRemoteBranch $Branch) { $range = "origin/$Branch..HEAD" }
        $ahead = [int](Invoke-SyncGit @('rev-list', '--count', $range)).lines[0]
        if ($ahead -eq 0) { Write-Host "на remote $gen отдавать нечего"; return }
        $r = Invoke-SyncGit @('push', '-q', '-u', 'origin', $Branch)
        if ($r.ok) { Write-Host "на remote $gen отдано коммитов: $ahead"; return }
    }
    Write-Host "на remote $gen не отдано — git: $($r.text); отдастся при следующем сведении"
    exit 1
}

# Метки конфликта в сведённом файле значат, что оператора не спросили или ответ не записан.
function Invoke-SyncContinue {
    if (-not (Test-KitUnmerged $dir)) { Write-Host "в $loc сведение не идёт — доделывать нечего"; return }
    $files = @((Invoke-SyncGit @('diff', '--name-only', '--diff-filter=U')).lines)
    $rebasing = (Test-Path -LiteralPath (Join-Path $dir '.git\rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $dir '.git\rebase-apply'))
    $kept = @{}
    foreach ($pair in $Keep) {
        $cut = $pair.LastIndexOf('=')
        $file = ''
        $side = ''
        if ($cut -gt 0) { $file = $pair.Substring(0, $cut).Replace('\', '/'); $side = $pair.Substring($cut + 1) }
        if ($side -notin 'Remote', 'Local' -or $files -notcontains $file) {
            Write-Host "-Keep «$pair»: нужен файл конфликта и сторона Remote или Local; файлы конфликта: $($files -join ', ')"
            exit 1
        }
        # В rebase «ours» — remote, на который кладутся коммиты этой машины; в merge — наоборот.
        $flag = '--theirs'
        if (($side -eq 'Remote') -eq $rebasing) { $flag = '--ours' }
        $r = Invoke-SyncGit @('checkout', $flag, '--', $file)
        if (-not $r.ok) { Write-Host "git не взял «$file» со стороны $side`: $($r.text)"; exit 1 }
        $kept[$file] = $true
    }
    foreach ($file in $files) {
        if ($kept.ContainsKey($file)) { continue }
        $full = Join-Path $dir $file
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $text = Get-Content -LiteralPath $full -Raw
        if ($text -match '(?m)^(<{7}|={7}|>{7})( |\r?$)') {
            Write-Host "в ``$file`` $gen остались метки конфликта — свести файл и повторить"
            exit 1
        }
    }
    if ($files.Count) {
        $r = Invoke-SyncGit (@('add', '--') + $files)
        if (-not $r.ok) { Write-Host "git не принял сведённые файлы: $($r.text)"; exit 1 }
    }
    if ($rebasing) { $r = Invoke-SyncGit @('-c', 'core.editor=true', 'rebase', '--continue') }
    else { $r = Invoke-SyncGit @('commit', '-q', '--no-edit') }
    if (Test-KitUnmerged $dir) { Stop-Unmerged }
    if (-not $r.ok) { Write-Host "сведение $gen не доделано — git: $($r.text)"; exit 1 }
    Write-Host "сведение $gen доделано"
}

Assert-SyncRemote
switch ($Action) {
    'Continue' {
        Invoke-SyncContinue
        if ($Repo -eq 'Base') { Invoke-SyncPush (Get-SyncBranch) }
    }
    'Pull' { Invoke-SyncPull (Get-SyncBranch) }
    'Push' { Invoke-SyncPush (Get-SyncBranch) }
}

# Забранное могло принести базу другого формата — её перевели с машины, где кит новее или старше.
$after = Get-KitLinkState $Path
$problem = Get-KitFormatProblem $after
if ($Repo -eq 'Base' -and $problem -and $problem -ne (Get-KitFormatProblem $state)) {
    Write-Host "Работа со знанием остановлена: $problem"
    exit 1
}
exit 0
