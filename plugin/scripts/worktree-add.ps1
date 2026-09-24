# agents-kit: завести рабочую копию проекта рядом с репозиторием — git worktree на новой
# ветке под названным или случайным именем.
#   pwsh -NoProfile -File scripts\worktree-add.ps1 [-Name <имя>] [-Path <копия>]
#
# Связь с базой копия наследует через общий git config, поэтому link.ps1 здесь
# не зовётся; заводится копия только от связанной, иначе она унаследовала бы разрыв.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Name,
    [string]$Path
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
. (Join-Path $PSScriptRoot 'link-state.ps1')

# Слова отобраны так, чтобы имя читалось в проводнике и не выглядело ни состоянием
# задачи, ни служебной веткой git.
$adjectives = @(
    'amber', 'brave', 'bright', 'calm', 'clever', 'cosmic', 'crisp', 'dusty', 'eager', 'fancy',
    'gentle', 'golden', 'happy', 'hidden', 'humble', 'jolly', 'keen', 'lively', 'lucky', 'mellow',
    'misty', 'noble', 'polite', 'proud', 'quiet', 'rapid', 'rustic', 'shiny', 'silent', 'silver',
    'sleepy', 'snowy', 'sunny', 'swift', 'tidy', 'velvet', 'vivid', 'witty', 'young', 'zesty')
$nouns = @(
    'badger', 'beacon', 'birch', 'canyon', 'cedar', 'comet', 'coral', 'crane', 'dune', 'falcon',
    'fern', 'fjord', 'glacier', 'harbor', 'heron', 'island', 'lagoon', 'lantern', 'maple', 'meadow',
    'meteor', 'orchid', 'otter', 'panda', 'pebble', 'pine', 'prairie', 'raven', 'reef', 'river',
    'robin', 'sparrow', 'summit', 'tiger', 'tulip', 'valley', 'walrus', 'willow', 'wolf', 'zebra')

if (-not $Path) { $Path = (Get-Location).Path }
$state = Get-KitLinkState $Path
switch ($state.status) {
    'NotGit'    { throw "«$Path» не под git — заводить копию не от чего" }
    'NoPointer' { throw "каталог «$($state.workspace)» под китом не числится — сначала взять его под кит скиллом /onboard" }
    'Linked'    { }
    default     { throw "связь копии «$($state.workspace)» с базой разорвана — link.ps1 без аргументов покажет, что именно" }
}

# От корня репозитория и рядом с ним, а не со связанным каталогом и не с текущим worktree:
# копия связанного подкаталога легла бы внутрь рабочего дерева, а копии заводились бы
# друг от друга и расползались по разным родителям.
$workspace = $state.repo
$parent = Split-Path $workspace -Parent

function Test-NameTaken([string]$Candidate) {
    if (Test-Path -LiteralPath (Join-Path $parent $Candidate)) { return "каталог «$(Join-Path $parent $Candidate)» уже существует" }
    & git -C $workspace show-ref --verify --quiet "refs/heads/$Candidate" 2>$null
    if ($LASTEXITCODE -eq 0) { return "ветка «$Candidate» уже существует" }
    return $null
}

if ($Name) {
    if ($Name -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
        throw "имя «$Name» не в kebab-case — строчная латиница и цифры через дефис, например quiet-cedar"
    }
    $taken = Test-NameTaken $Name
    if ($taken) { throw "$taken — назвать копию иначе" }
}
else {
    for ($i = 0; $i -lt 20 -and -not $Name; $i++) {
        $pair = Get-Random -InputObject $adjectives -Count 2
        $candidate = '{0}-{1}-{2}' -f $pair[0], $pair[1], (Get-Random -InputObject $nouns)
        if (-not (Test-NameTaken $candidate)) { $Name = $candidate }
    }
    if (-not $Name) { throw "за 20 попыток не нашлось свободного случайного имени рядом с «$workspace» — назвать копию явно" }
}

$target = Join-Path $parent $Name
if ($PSCmdlet.ShouldProcess($target, "git worktree add на новой ветке $Name")) {
    $out = & git -C $workspace worktree add -q $target -b $Name 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git не завёл worktree «$target»: $(($out | Out-String).Trim())" }
}

Write-Host "Рабочая копия заведена: $target"
Write-Host "Ветка:                  $Name"
# Под китом каталог, а не всё дерево: сессию открывают в нём, иначе кит промолчит.
if ($state.scope) {
    Write-Host "Сессию открывать в:     $(Join-KitScope $target $state.scope)"
}
Write-Host "Связь с базой общая с основной копией «$($state.workspace)» — link.ps1 не нужен."

# Субагенты базы довозятся сразу: до этого этап звал бы в новой копии исполнителя, которого
# в ней нет. Не вышло — копия всё равно заведена, и сказать об этом важнее, чем упасть.
$copy = Join-KitScope $target $state.scope
if (Test-Path -LiteralPath $copy -PathType Container) {
    Write-Host ''
    try { & (Join-Path $PSScriptRoot 'agents-deploy.ps1') -Path $copy }
    catch { Write-Host "Субагентов базы довезти не удалось: $($_.Exception.Message) — прогнать agents-deploy.ps1 в копии" -ForegroundColor Yellow }
}
