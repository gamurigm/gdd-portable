param(
    [switch]$NoBuild,
    [switch]$Portable,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/-]*$')]
    [ValidateNotNullOrEmpty()]
    [string]$ImageTag = "gdd:portable"
)

# ==============================================================================
# LEVANTAR ENTORNO PROD TEMPORALMENTE CONECTADO
# Levanta Backend, Worker, Redis, MinIO y PostgreSQL de forma local.
# ==============================================================================
$ErrorActionPreference = "Stop"
if ($Portable) {
    if ($PSBoundParameters.ContainsKey('ImageTag') -and $ImageTag -ne 'gdd:portable') {
        throw "El modo -Portable usa la imagen 'gdd:portable'."
    }
    $NoBuild = $true
}
$projectRoot = $PSScriptRoot
$projectName = "gdd-prod"
$composeFile = Join-Path $projectRoot "docker-compose.yml"

$envFile = Join-Path $projectRoot ".env"
$envExampleFile = Join-Path $projectRoot ".env.example"
if (-not (Test-Path $envFile)) {
    if (Test-Path $envExampleFile) {
        Write-Host "--> No se encontro '.env'. Creando uno nuevo a partir de '.env.example'..." -ForegroundColor Yellow
        Copy-Item -Path $envExampleFile -Destination $envFile
    } else {
        Write-Error "No se encontro '.env' ni '.env.example'."
        exit 1
    }
}

$envContent = [IO.File]::ReadAllText($envFile)
$secretKeyPattern = '(?m)^(?<prefix>[ \t]*DJANGO_SECRET_KEY[ \t]*=[ \t]*)(?<value>[^\r\n]*)'
$secretKeyMatch = [regex]::Match($envContent, $secretKeyPattern)
$secretKey = if ($secretKeyMatch.Success) {
    $secretKeyMatch.Groups['value'].Value.Trim().Trim([char[]]@('"', "'"))
} else {
    ''
}

if ([string]::IsNullOrWhiteSpace($secretKey) -or
    $secretKey.StartsWith('REEMPLAZAR_', [StringComparison]::Ordinal) -or
    $secretKey -eq 'unsafe-development-key') {
    $randomBytes = [byte[]]::new(48)
    $randomGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $randomGenerator.GetBytes($randomBytes)
    }
    finally {
        $randomGenerator.Dispose()
    }
    $secretKey = [Convert]::ToBase64String($randomBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')

    if ($secretKeyMatch.Success) {
        $envContent = $envContent.Remove($secretKeyMatch.Index, $secretKeyMatch.Length).Insert(
            $secretKeyMatch.Index,
            $secretKeyMatch.Groups['prefix'].Value + $secretKey
        )
    } else {
        if ($envContent.Length -gt 0 -and $envContent -notmatch '[\r\n]$') {
            $envContent += [Environment]::NewLine
        }
        $envContent += "DJANGO_SECRET_KEY=$secretKey$([Environment]::NewLine)"
    }
    [IO.File]::WriteAllText($envFile, $envContent, [Text.UTF8Encoding]::new($false))
    Write-Host "--> DJANGO_SECRET_KEY se generó y guardó en .env." -ForegroundColor Green
}

$composeArgs = @("--project-name", $projectName, "--file", $composeFile, "--env-file", $envFile)
$buildArgument = if ($NoBuild) { "--no-build" } else { "--build" }
Write-Host "--> Levantando modo PROD (proyecto $projectName, imagen $ImageTag, Postgres externo; backend por defecto en 8011 y MinIO en 9100/9101) con $([IO.Path]::GetFileName($envFile))..." -ForegroundColor Green
$previousDjangoSecretKey = [Environment]::GetEnvironmentVariable('DJANGO_SECRET_KEY', 'Process')
$previousGdeBackendImage = [Environment]::GetEnvironmentVariable('GDE_BACKEND_IMAGE', 'Process')
Push-Location $projectRoot
try {
    $env:DJANGO_SECRET_KEY = $secretKey
    $env:GDE_BACKEND_IMAGE = $ImageTag
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        $programFiles = $env:ProgramFiles
        if ([string]::IsNullOrWhiteSpace($programFiles)) {
            $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
        }
        if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
            $dockerBin = Join-Path $programFiles "Docker\Docker\resources\bin"
            if (Test-Path $dockerBin) {
                $env:Path = "$dockerBin;$env:Path"
            }
        }
    }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Error "Docker CLI no esta disponible en PATH. Abre Docker Desktop o reinicia la terminal."
        exit 1
    }
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        & docker info *> $null
        if ($LASTEXITCODE -eq 0) { break }
        if ($attempt -eq 12) {
            Write-Error "Docker Desktop no esta listo despues de 60 segundos. Abre Docker Desktop y espera a que el motor Linux termine de iniciar."
            exit 1
        }
        Write-Host "--> Esperando a Docker Desktop ($($attempt * 5)/60 s)..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }

    if ($Portable) {
        $portableTarPath = Join-Path $projectRoot "gdd-portable.tar"
        if (-not (Test-Path -LiteralPath $portableTarPath -PathType Leaf)) {
            throw "No se encontró el paquete portable '$portableTarPath'."
        }
        Write-Host "--> Cargando paquete portable gdd-portable.tar..." -ForegroundColor Yellow
        & docker image load --input $portableTarPath
        if ($LASTEXITCODE -ne 0) { throw "Docker no pudo cargar gdd-portable.tar." }
    }

    if ($NoBuild) {
        & docker image inspect $ImageTag *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "No se encontró la imagen '$ImageTag'. Cárgala con 'docker image load' antes de usar -NoBuild."
        }
    }

    $runningServices = @(& docker compose @composeArgs ps --status running --services)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $workerServices = @("worker", "worker-services")
    $activeWorkers = @($workerServices | Where-Object { $runningServices -contains $_ })
    if ($activeWorkers.Count -gt 0) {
        Write-Host "--> Drenando los workers antes de actualizar (máximo 10 minutos)..." -ForegroundColor Yellow
        & docker compose @composeArgs stop --timeout 600 @activeWorkers
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    docker compose @composeArgs up -d $buildArgument --remove-orphans --wait @args
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $backendBinding = (& docker compose @composeArgs port backend 8000 2>$null).Trim()
    $minioConsoleBinding = (& docker compose @composeArgs port minio 9001 2>$null).Trim()
    if ($backendBinding -match ':(\d+)$') {
        Write-Host "--> Dashboard disponible en http://localhost:$($Matches[1])" -ForegroundColor Green
    }
    if ($minioConsoleBinding -match ':(\d+)$') {
        Write-Host "--> Consola MinIO disponible en http://localhost:$($Matches[1])" -ForegroundColor Green
    }
}
finally {
    if ($null -eq $previousDjangoSecretKey) {
        Remove-Item Env:DJANGO_SECRET_KEY -ErrorAction SilentlyContinue
    } else {
        $env:DJANGO_SECRET_KEY = $previousDjangoSecretKey
    }
    if ($null -eq $previousGdeBackendImage) {
        Remove-Item Env:GDE_BACKEND_IMAGE -ErrorAction SilentlyContinue
    } else {
        $env:GDE_BACKEND_IMAGE = $previousGdeBackendImage
    }
    Pop-Location
}
