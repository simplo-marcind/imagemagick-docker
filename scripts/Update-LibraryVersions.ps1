<#
.SYNOPSIS
    Automatycznie podmienia wersje bibliotek (ARG ...) w plikach Dockerfile.* na najnowsze wydania.

.DESCRIPTION
    Każdy Dockerfile.* definiuje instrukcje ARG z wersją (tagiem git) ImageMagick oraz bibliotek:
    libheif, libaom, libwebp, libjxl. Skrypt pobiera listę tagów z repozytoriów źródłowych
    (git ls-remote --tags), wybiera najnowszą stabilną wersję (pomija -rc, -beta, snapshoty itp.),
    porównuje ją z wersją aktualnie wpisaną w Dockerfile i w razie potrzeby podmienia wartość ARG.

    Wymagania: zainstalowany git (w PATH) oraz dostęp do internetu.

.PARAMETER Path
    Ścieżki do plików Dockerfile lub katalogów zawierających pliki Dockerfile.*.
    Domyślnie: katalog nadrzędny względem skryptu (korzeń repozytorium).

.PARAMETER Library
    Ogranicza aktualizację do wybranych bibliotek.
    Dozwolone: IM, LIB_HEIF, LIB_AOM, LIB_WEBP, LIBJXL.

.PARAMETER CheckOnly
    Tylko sprawdza dostępność nowszych wersji i wyświetla raport - nie zapisuje zmian.
    (Alternatywnie można użyć standardowego przełącznika -WhatIf).

.EXAMPLE
    .\Update-LibraryVersions.ps1
    Aktualizuje wszystkie biblioteki we wszystkich Dockerfile.* w repozytorium.

.EXAMPLE
    .\Update-LibraryVersions.ps1 -CheckOnly
    Tylko pokazuje, co można zaktualizować.

.EXAMPLE
    .\Update-LibraryVersions.ps1 -Library LIB_HEIF, LIBJXL -Path ..\Dockerfile.trixie
    Aktualizuje tylko libheif i libjxl w jednym pliku.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string[]]$Path = (Split-Path -Parent $PSScriptRoot),

    [ValidateSet('IM', 'LIB_HEIF', 'LIB_AOM', 'LIB_WEBP', 'LIBJXL')]
    [string[]]$Library,

    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

# Nazwa ARG -> repozytorium, prefiks tagu (np. "v" dla v1.2.3) i wzorzec stabilnej wersji.
# Wzorzec bez sufiksów -rc/-beta; ImageMagick używa formatu X.Y.Z-N (bez prefiksu).
$AllLibraries = [ordered]@{
    'IM_VERSION'       = @{ Repo = 'https://github.com/ImageMagick/ImageMagick.git';      Prefix = '';  Pattern = '^\d+\.\d+\.\d+-\d+$' }
    'LIB_HEIF_VERSION' = @{ Repo = 'https://github.com/strukturag/libheif.git';           Prefix = 'v'; Pattern = '^\d+\.\d+\.\d+$' }
    'LIB_AOM_VERSION'  = @{ Repo = 'https://aomedia.googlesource.com/aom';                Prefix = 'v'; Pattern = '^\d+\.\d+\.\d+$' }
    'LIB_WEBP_VERSION' = @{ Repo = 'https://chromium.googlesource.com/webm/libwebp';      Prefix = 'v'; Pattern = '^\d+\.\d+\.\d+$' }
    'LIBJXL_VERSION'   = @{ Repo = 'https://github.com/libjxl/libjxl.git';                Prefix = 'v'; Pattern = '^\d+\.\d+\.\d+$' }
}

$Libraries = $AllLibraries
if ($Library) {
    $Libraries = [ordered]@{}
    foreach ($name in $Library) {
        $key = "${name}_VERSION"
        $Libraries[$key] = $AllLibraries[$key]
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Nie znaleziono polecenia "git" w PATH. Zainstaluj git i spróbuj ponownie.'
}

function Get-LatestVersion {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$Prefix,
        [Parameter(Mandatory)][string]$Pattern
    )

    $lines = & git ls-remote --tags $Repo 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-remote nie powiódł się dla $Repo`: $lines"
    }

    $versions = foreach ($line in $lines) {
        if ("$line" -notmatch 'refs/tags/(?<tag>\S+)$') { continue }
        $tag = $Matches['tag'] -replace '\^\{\}$', ''   # usuń znacznik "peeled" (^{})

        if ($Prefix) {
            if (-not $tag.StartsWith($Prefix)) { continue }
            $tag = $tag.Substring($Prefix.Length)
        }
        if ($tag -match $Pattern) { $tag }
    }

    $versions = @($versions | Select-Object -Unique)
    if ($versions.Count -eq 0) {
        throw "Nie znaleziono tagów pasujących do wzorca '$Pattern' w $Repo."
    }

    # Sortowanie numeryczne: "X.Y.Z" (jako [version]) a następnie numer buildu po myślniku (ImageMagick).
    $latest = $versions |
        Sort-Object -Descending `
            -Property @{ Expression = { [version]($_ -split '-', 2)[0] } },
                      @{ Expression = { $p = $_ -split '-', 2; if ($p.Count -gt 1) { [int]$p[1] } else { 0 } } } |
        Select-Object -First 1

    return $latest
}

# Zbierz pliki Dockerfile
$files = foreach ($p in $Path) {
    if (Test-Path -LiteralPath $p -PathType Container) {
        Get-ChildItem -LiteralPath $p -Filter 'Dockerfile*' -File
    }
    elseif (Test-Path -LiteralPath $p -PathType Leaf) {
        Get-Item -LiteralPath $p
    }
    else {
        Write-Warning "Pominięto - ścieżka nie istnieje: $p"
    }
}
$files = @($files)
if ($files.Count -eq 0) {
    throw 'Nie znaleziono żadnych plików Dockerfile.'
}

# Pobierz najnowsze wersje (raz na bibliotekę, wspólnie dla wszystkich plików)
$latest = @{}
foreach ($argName in $Libraries.Keys) {
    $info = $Libraries[$argName]
    try {
        Write-Host "Sprawdzam $argName ($($info.Repo))..." -ForegroundColor DarkGray
        $latest[$argName] = Get-LatestVersion -Repo $info.Repo -Prefix $info.Prefix -Pattern $info.Pattern
    }
    catch {
        Write-Warning "[$argName] $($_.Exception.Message)"
    }
}

$report = [System.Collections.Generic.List[object]]::new()
$dryRun = $CheckOnly.IsPresent

foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    $changed = $false

    foreach ($argName in $Libraries.Keys) {
        if (-not $latest.ContainsKey($argName)) { continue }

        $regex = "(?m)^(ARG\s+$argName=)(\S+)"
        $match = [regex]::Match($content, $regex)
        if (-not $match.Success) { continue }

        $current = $match.Groups[2].Value
        $new = $latest[$argName]

        if ($current -eq $new) {
            $status = 'aktualna'
        }
        elseif ($dryRun) {
            $status = 'dostępna aktualizacja'
        }
        elseif ($PSCmdlet.ShouldProcess($file.Name, "$argName`: $current -> $new")) {
            $content = [regex]::Replace($content, $regex, "`${1}$new")
            $changed = $true
            $status = 'zaktualizowano'
        }
        else {
            $status = 'dostępna aktualizacja'
        }

        $report.Add([pscustomobject]@{
            Plik      = $file.Name
            ARG       = $argName
            Obecna    = $current
            Najnowsza = $new
            Status    = $status
        })
    }

    if ($changed) {
        [System.IO.File]::WriteAllText($file.FullName, $content, (New-Object System.Text.UTF8Encoding($false)))
    }
}

Write-Host ''
$report | Format-Table -AutoSize

$updated = @($report | Where-Object Status -eq 'zaktualizowano').Count
$pending = @($report | Where-Object Status -eq 'dostępna aktualizacja').Count
Write-Host "Zaktualizowano: $updated; oczekujące (nie zapisano): $pending." -ForegroundColor Cyan
