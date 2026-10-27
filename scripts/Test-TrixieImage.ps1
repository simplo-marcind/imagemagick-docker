<#
.SYNOPSIS
    Buduje obraz z Dockerfile.trixie, uruchamia kontener i testuje serwer konwersji do JPG po HTTP.

.DESCRIPTION
    Kroki:
      1. docker build -f Dockerfile.trixie (można pominąć przez -SkipBuild),
      2. docker run - start kontenera z serwerem (port 80 w kontenerze mapowany na -HostPort),
      3. oczekiwanie na gotowość serwera (GET /),
      4. dla każdego pliku z katalogu testowego: POST multipart na /convert,
         a następnie sprawdzenie, że odpowiedź to 200, Content-Type image/jpeg,
         dane zaczynają się od sygnatury JPEG (FF D8 FF) i - po skopiowaniu do kontenera -
         `magick identify` rozpoznaje je jako JPEG,
      5. testy negatywne (plik niebędący obrazem -> 415, nieprawidłowy parametr quality -> 400),
      6. sprzątanie (zatrzymanie i usunięcie kontenera; można zostawić przez -KeepContainer).

    Skrypt kończy się kodem 0, gdy wszystkie testy przeszły, w przeciwnym razie kodem 1.

    Wymagania: Docker (działający daemon). Działa w Windows PowerShell 5.1 i PowerShell 7+.

.PARAMETER ImageName
    Nazwa (tag) budowanego obrazu. Domyślnie: imagemagick-trixie-test.

.PARAMETER ContainerName
    Nazwa uruchamianego kontenera. Domyślnie: imagemagick-trixie-test.

.PARAMETER HostPort
    Port na hoście mapowany na port 80 w kontenerze. Domyślnie: 18080.

.PARAMETER TestImagesPath
    Katalog z plikami testowymi. Domyślnie: test-images w korzeniu repozytorium.

.PARAMETER OutputPath
    Katalog, do którego zapisywane są wyniki konwersji (JPG). Domyślnie: katalog tymczasowy.

.PARAMETER SkipBuild
    Pomija docker build i używa istniejącego obrazu -ImageName.

.PARAMETER NoCache
    Przekazuje --no-cache do docker build.

.PARAMETER KeepContainer
    Nie zatrzymuje ani nie usuwa kontenera po testach.

.PARAMETER StartupTimeoutSec
    Maksymalny czas oczekiwania na start serwera (sekundy). Domyślnie: 30.

.EXAMPLE
    .\Test-TrixieImage.ps1
    Buduje obraz, uruchamia kontener i testuje wszystkie pliki z test-images.

.EXAMPLE
    .\Test-TrixieImage.ps1 -SkipBuild -HostPort 8080 -KeepContainer
    Używa istniejącego obrazu, wystawia serwer na porcie 8080 i zostawia kontener po testach.
#>

[CmdletBinding()]
param(
    [string]$ImageName = 'imagemagick-trixie-test',
    [string]$ContainerName = 'imagemagick-trixie-test',
    [ValidateRange(1, 65535)]
    [int]$HostPort = 18080,
    [string]$TestImagesPath,
    [string]$OutputPath,
    [switch]$SkipBuild,
    [switch]$NoCache,
    [switch]$KeepContainer,
    [ValidateRange(1, 600)]
    [int]$StartupTimeoutSec = 30
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $TestImagesPath) { $TestImagesPath = Join-Path $repoRoot 'test-images' }
if (-not $OutputPath) { $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) 'imagemagick-trixie-test' }

Add-Type -AssemblyName System.Net.Http

$baseUrl = "http://localhost:$HostPort"
$script:passed = 0
$script:failed = 0

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Result([bool]$Ok, [string]$Name, [string]$Details) {
    if ($Ok) {
        $script:passed++
        Write-Host ("  [PASS] {0,-26} {1}" -f $Name, $Details) -ForegroundColor Green
    }
    else {
        $script:failed++
        Write-Host ("  [FAIL] {0,-26} {1}" -f $Name, $Details) -ForegroundColor Red
    }
}

function Invoke-Docker {
    # Uruchamia docker i rzuca wyjątek przy niezerowym kodzie wyjścia.
    & docker @args
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($args -join ' ') zakończone kodem $LASTEXITCODE"
    }
}

function Invoke-DockerQuiet {
    # Uruchamia docker bez wypisywania wyjścia i bez wyjątków (Windows PowerShell 5.1
    # traktuje stderr programów natywnych jako błąd przy $ErrorActionPreference = 'Stop').
    # Zwraca kod wyjścia.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker @args 2>&1 | Out-Null
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
}

function Send-Upload {
    # Wysyła plik jako multipart/form-data (pole "file") na /convert.
    # Zwraca obiekt: StatusCode, ContentType, Body (bajty).
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$FileName,
        [hashtable]$Fields = @{}
    )

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(180)
    $form = [System.Net.Http.MultipartFormDataContent]::new()
    try {
        $form.Add([System.Net.Http.ByteArrayContent]::new($Bytes), 'file', $FileName)
        foreach ($key in $Fields.Keys) {
            $form.Add([System.Net.Http.StringContent]::new([string]$Fields[$key]), $key)
        }
        $response = $client.PostAsync("$baseUrl/convert", $form).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $contentType = ''
        if ($response.Content.Headers.ContentType) {
            $contentType = $response.Content.Headers.ContentType.MediaType
        }
        [pscustomobject]@{
            StatusCode  = [int]$response.StatusCode
            ContentType = $contentType
            Body        = $body
        }
    }
    finally {
        $form.Dispose()
        $client.Dispose()
    }
}

function Wait-ForServer {
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $running = (& docker inspect -f '{{.State.Running}}' $ContainerName)
        if ($running -ne 'true') {
            throw 'Kontener zakończył działanie przed startem serwera.'
        }
        try {
            $client = [System.Net.Http.HttpClient]::new()
            $client.Timeout = [TimeSpan]::FromSeconds(2)
            try {
                $status = [int]$client.GetAsync("$baseUrl/").GetAwaiter().GetResult().StatusCode
            }
            finally { $client.Dispose() }
            if ($status -eq 200) { return }
        }
        catch { }
        Start-Sleep -Milliseconds 500
    }
    throw "Serwer nie odpowiedział w ciągu $StartupTimeoutSec s."
}

function Test-ConvertedFile([System.IO.FileInfo]$File) {
    $name = $File.Name
    try {
        $result = Send-Upload -Bytes ([System.IO.File]::ReadAllBytes($File.FullName)) -FileName $name
    }
    catch {
        Write-Result $false $name "błąd żądania HTTP: $($_.Exception.Message)"
        return
    }

    if ($result.StatusCode -ne 200) {
        $msg = [System.Text.Encoding]::UTF8.GetString($result.Body)
        Write-Result $false $name "HTTP $($result.StatusCode): $msg"
        return
    }
    if ($result.ContentType -ne 'image/jpeg') {
        Write-Result $false $name "Content-Type '$($result.ContentType)' zamiast image/jpeg"
        return
    }

    $b = $result.Body
    if ($b.Length -lt 3 -or $b[0] -ne 0xFF -or $b[1] -ne 0xD8 -or $b[2] -ne 0xFF) {
        Write-Result $false $name 'odpowiedź nie ma sygnatury JPEG (FF D8 FF)'
        return
    }

    $outFile = Join-Path $OutputPath ([System.IO.Path]::GetFileNameWithoutExtension($name) + '-' + $File.Extension.TrimStart('.') + '.jpg')
    [System.IO.File]::WriteAllBytes($outFile, $b)

    # Niezależna weryfikacja formatu i wymiarów przez ImageMagick w kontenerze.
    $remote = '/tmp/check.jpg'
    Invoke-Docker cp $outFile "${ContainerName}:$remote" | Out-Null
    $identify = (& docker exec $ContainerName magick identify -format '%m %w %h' $remote)
    if ($LASTEXITCODE -ne 0 -or $identify -notmatch '^JPEG (\d+) (\d+)$') {
        Write-Result $false $name "magick identify nie rozpoznał JPEG: '$identify'"
        return
    }

    Write-Result $true $name ("-> {0}x{1} JPEG, {2:N0} B" -f $Matches[1], $Matches[2], $b.Length)
}

$containerStarted = $false
try {
    if ((Invoke-DockerQuiet version --format '{{.Server.Version}}') -ne 0) {
        throw 'Docker daemon jest niedostępny.'
    }

    if (-not (Test-Path -LiteralPath $TestImagesPath -PathType Container)) {
        throw "Brak katalogu z plikami testowymi: $TestImagesPath"
    }
    $testFiles = @(Get-ChildItem -LiteralPath $TestImagesPath -File | Sort-Object Name)
    if ($testFiles.Count -eq 0) { throw "Katalog $TestImagesPath nie zawiera plików." }

    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Recurse -Force }
    New-Item -ItemType Directory -Path $OutputPath | Out-Null

    # --- 1. Build ---
    if ($SkipBuild) {
        Write-Step "Pomijam build, używam obrazu '$ImageName'"
        if ((Invoke-DockerQuiet image inspect $ImageName) -ne 0) { throw "Obraz '$ImageName' nie istnieje - uruchom bez -SkipBuild." }
    }
    else {
        Write-Step "Budowanie obrazu '$ImageName' (Dockerfile.trixie)"
        $buildArgs = @('build', '-f', (Join-Path $repoRoot 'Dockerfile.trixie'), '-t', $ImageName)
        if ($NoCache) { $buildArgs += '--no-cache' }
        $buildArgs += $repoRoot
        Invoke-Docker @buildArgs
    }

    # --- 2. Run ---
    Write-Step "Start kontenera '$ContainerName' na porcie $HostPort"
    Invoke-DockerQuiet rm -f $ContainerName | Out-Null
    Invoke-Docker run -d --name $ContainerName -p "${HostPort}:80" $ImageName | Out-Null
    $containerStarted = $true

    Write-Step 'Oczekiwanie na gotowość serwera'
    Wait-ForServer
    Write-Host "  Serwer odpowiada na $baseUrl/" -ForegroundColor Green

    # --- 3. Testy konwersji ---
    Write-Step "Konwersja plików z '$TestImagesPath' do JPG"
    foreach ($file in $testFiles) { Test-ConvertedFile $file }

    # --- 4. Testy negatywne ---
    Write-Step 'Testy negatywne'
    $garbage = [System.Text.Encoding]::UTF8.GetBytes('to nie jest obraz')
    $r = Send-Upload -Bytes $garbage -FileName 'garbage.png'
    Write-Result ($r.StatusCode -eq 415) 'plik niebędący obrazem' "HTTP $($r.StatusCode) (oczekiwano 415)"

    $first = $testFiles | Where-Object { $_.Extension -in '.png', '.jpg' } | Select-Object -First 1
    if ($first) {
        $r = Send-Upload -Bytes ([System.IO.File]::ReadAllBytes($first.FullName)) -FileName $first.Name -Fields @{ quality = 'abc' }
        Write-Result ($r.StatusCode -eq 400) 'nieprawidłowe quality' "HTTP $($r.StatusCode) (oczekiwano 400)"

        $low = Send-Upload -Bytes ([System.IO.File]::ReadAllBytes($first.FullName)) -FileName $first.Name -Fields @{ quality = 5 }
        $high = Send-Upload -Bytes ([System.IO.File]::ReadAllBytes($first.FullName)) -FileName $first.Name -Fields @{ quality = 100 }
        $okQuality = ($low.StatusCode -eq 200 -and $high.StatusCode -eq 200 -and $low.Body.Length -lt $high.Body.Length)
        Write-Result $okQuality 'parametr quality' ("q5={0} B, q100={1} B" -f $low.Body.Length, $high.Body.Length)
    }
}
catch {
    $script:failed++
    Write-Host ''
    Write-Host "BŁĄD: $($_.Exception.Message)" -ForegroundColor Red
    if ($containerStarted) {
        Write-Host '--- logi kontenera ---' -ForegroundColor Yellow
        & docker logs --tail 50 $ContainerName
    }
}
finally {
    if ($containerStarted -and -not $KeepContainer) {
        Write-Step "Usuwanie kontenera '$ContainerName'"
        Invoke-DockerQuiet rm -f $ContainerName | Out-Null
    }
}

Write-Host ''
Write-Host "Wyniki: $script:passed OK, $script:failed błędów. Pliki JPG: $OutputPath"
if ($script:failed -gt 0) { exit 1 }
exit 0
