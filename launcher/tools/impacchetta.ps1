#Requires -Version 7
<#
  Builds the mods' package of a release: moon-mods.zip, with mods.json and every file it names, in the same folders as
  in the repo. The launcher downloads it from the latest release. It also checks what the launcher cannot fix later:
  every "from" must exist, and two mods that put a file in the same place (ZomBotMenu.lua in Admin-Scorte and ZomBOT)
  must bring the very same file, or installing one would make the other look out of date.

    pwsh launcher/tools/impacchetta.ps1 [-Out dist]

  In GitHub Actions it also writes the launcher's version (the "launcher" field of mods.json) to GITHUB_OUTPUT.
#>
param([string]$Out = 'dist')
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$manifestPath = Join-Path $repo 'mods.json'
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
if ($manifest.launcher -notmatch '^\d+\.\d+\.\d+$') { throw "mods.json: «launcher» deve essere una versione come 1.2.3, non «$($manifest.launcher)»." }

$files = [ordered]@{}      # path in the repo -> full path
$targets = @{}             # destination -> @{ Hash; Mod }

function Add-File([string]$full, [string]$target, [string]$mod) {
    $rel = [IO.Path]::GetRelativePath($repo, $full).Replace('\', '/')
    if ($rel.StartsWith('../')) { throw "$mod prende un file da fuori dal repo: $full" }
    $files[$rel] = $full
    if (-not $target) { return }
    $key = $target.ToLowerInvariant()
    $hash = (Get-FileHash $full -Algorithm SHA256).Hash
    if ($targets.ContainsKey($key) -and $targets[$key].Hash -ne $hash) {
        throw "$target arriva sia da $($targets[$key].Mod) sia da ${mod}, ma i due file sono diversi: devono essere identici."
    }
    $targets[$key] = @{ Hash = $hash; Mod = $mod }
}

foreach ($mod in $manifest.mods) {
    foreach ($e in $mod.install) {
        $from = Join-Path $repo $e.from
        $to = $e.to.Replace('\', '/').TrimEnd('/')
        if (Test-Path $from -PathType Container) {
            foreach ($f in Get-ChildItem $from -Recurse -File) {
                Add-File $f.FullName ($to + '/' + [IO.Path]::GetRelativePath($from, $f.FullName).Replace('\', '/')) $mod.name
            }
        } elseif (Test-Path $from -PathType Leaf) {
            Add-File (Resolve-Path $from).Path $to $mod.name
        } else {
            throw "mods.json: a $($mod.name) serve «$($e.from)», che nel repo non c'è."
        }
    }
    if ($mod.image) {
        $image = Join-Path $repo $mod.image
        if (-not (Test-Path $image -PathType Leaf)) { throw "mods.json: l'immagine di $($mod.name) non c'è: $($mod.image)" }
        Add-File (Resolve-Path $image).Path $null $mod.name
    }
}

New-Item -ItemType Directory -Force $Out | Out-Null
$zip = Join-Path (Resolve-Path $Out).Path 'moon-mods.zip'
if (Test-Path $zip) { Remove-Item $zip }
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $manifestPath, 'mods.json', 'Optimal')
    foreach ($f in $files.GetEnumerator()) {
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.Value, $f.Key, 'Optimal')
    }
} finally {
    $archive.Dispose()
}
Copy-Item $manifestPath (Join-Path $Out 'mods.json') -Force

if ($env:GITHUB_OUTPUT) { "launcher=$($manifest.launcher)" | Out-File $env:GITHUB_OUTPUT -Append -Encoding utf8 }
$size = [Math]::Round((Get-Item $zip).Length / 1KB)
Write-Host "moon-mods.zip: $($manifest.mods.Count) mod, $($files.Count) file, $size KB; launcher $($manifest.launcher)"
