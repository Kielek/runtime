[CmdletBinding()]
param(
    [string]$TraceContextPath,
    [string]$TraceContextSha = "34b10ac5af7f0caeb28efe35fe51cd4763ec5771",
    [string]$Configuration = "Debug",
    [string]$Framework = "net11.0",
    [int]$Port = 5000,
    [int]$HarnessPort = 7777,
    [switch]$SkipDiagnosticSourceBuild,
    [switch]$RestoreDiagnosticSource,
    [string[]]$Pattern
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..\..\..")
$workDir = Join-Path $repoRoot "artifacts\W3CTraceContextCompliance"
$venvDir = Join-Path $workDir ".venv"
$venvPython = Join-Path $venvDir "Scripts\python.exe"
$requirements = Join-Path $scriptDir "requirements.txt"
$project = Join-Path $scriptDir "W3CTraceContextCompliance.csproj"
$diagProject = Join-Path $repoRoot "src\libraries\System.Diagnostics.DiagnosticSource\src\System.Diagnostics.DiagnosticSource.csproj"
$diagDll = Join-Path $repoRoot "artifacts\bin\System.Diagnostics.DiagnosticSource\$Configuration\$Framework\System.Diagnostics.DiagnosticSource.dll"
$serverOut = Join-Path $workDir "server.out.log"
$serverErr = Join-Path $workDir "server.err.log"

New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$dotnet = Join-Path $repoRoot "dotnet.cmd"
if (-not (Test-Path -LiteralPath $dotnet)) {
    $dotnet = "dotnet"
}

$dotnetExe = Join-Path $repoRoot ".dotnet\dotnet.exe"
if (-not (Test-Path -LiteralPath $dotnetExe)) {
    $dotnetCommand = Get-Command dotnet -ErrorAction Stop
    $dotnetExe = $dotnetCommand.Source
}

if (-not $SkipDiagnosticSourceBuild) {
    $buildArgs = @("build", $diagProject, "-c", $Configuration, "-f", $Framework)
    if (-not $RestoreDiagnosticSource) {
        $buildArgs += "--no-restore"
    }

    & $dotnet @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "DiagnosticSource build failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path -LiteralPath $diagDll)) {
    throw "DiagnosticSource assembly was not found at '$diagDll'. Build it first or rerun without -SkipDiagnosticSourceBuild."
}

$serverBuildArgs = @(
    "build",
    $project,
    "-c", $Configuration,
    "-f", $Framework,
    "/p:ImportDirectoryBuildProps=false",
    "/p:ImportDirectoryBuildTargets=false",
    "/p:DiagnosticSourcePath=$diagDll"
)

& $dotnet @serverBuildArgs
if ($LASTEXITCODE -ne 0) {
    throw "W3C repro server build failed with exit code $LASTEXITCODE."
}

$serverDll = Join-Path $scriptDir "bin\$Configuration\$Framework\W3CTraceContextCompliance.dll"
if (-not (Test-Path -LiteralPath $serverDll)) {
    throw "W3C repro server assembly was not found at '$serverDll'."
}

if (-not (Test-Path -LiteralPath $venvPython)) {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        & $py.Source -3.11 -m venv $venvDir
    }
    else {
        $python = Get-Command python -ErrorAction Stop
        & $python.Source -m venv $venvDir
    }
}

& $venvPython -m pip install --disable-pip-version-check --requirement $requirements --require-hashes
if ($LASTEXITCODE -ne 0) {
    throw "Python dependency installation failed with exit code $LASTEXITCODE."
}

$managedTraceContext = $false
if ([string]::IsNullOrWhiteSpace($TraceContextPath)) {
    $embeddedTraceContext = Join-Path $scriptDir "w3c-trace-context"
    if (Test-Path -LiteralPath (Join-Path $embeddedTraceContext "test\test.py")) {
        $TraceContextPath = $embeddedTraceContext
    }
    else {
        $managedTraceContext = $true
        $TraceContextPath = Join-Path $workDir "trace-context"
    }
}

if ($managedTraceContext) {
    if (-not (Test-Path -LiteralPath $TraceContextPath)) {
        git init $TraceContextPath | Out-Null
        git -C $TraceContextPath remote add origin https://github.com/w3c/trace-context.git
    }

    git -C $TraceContextPath fetch --depth 1 origin $TraceContextSha
    if ($LASTEXITCODE -ne 0) {
        throw "Fetching W3C trace-context commit failed with exit code $LASTEXITCODE."
    }

    git -C $TraceContextPath checkout --detach FETCH_HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "Checking out W3C trace-context commit failed with exit code $LASTEXITCODE."
    }
}

$w3cTestDir = Join-Path $TraceContextPath "test"
$w3cTest = Join-Path $w3cTestDir "test.py"
if (-not (Test-Path -LiteralPath $w3cTest)) {
    throw "W3C test.py was not found at '$w3cTest'. Pass -TraceContextPath pointing to a w3c/trace-context checkout."
}

Remove-Item -LiteralPath $serverOut, $serverErr -ErrorAction SilentlyContinue

$serverArgs = @(
    $serverDll,
    "server",
    "--port", "$Port"
)

$suiteExit = 1
$server = Start-Process -FilePath $dotnetExe -ArgumentList $serverArgs -WorkingDirectory $repoRoot -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr -WindowStyle Hidden -PassThru

try {
    $listening = $false
    for ($i = 0; $i -lt 90; $i++) {
        if ($server.HasExited) {
            $stdout = Get-Content -LiteralPath $serverOut -Raw -ErrorAction SilentlyContinue
            $stderr = Get-Content -LiteralPath $serverErr -Raw -ErrorAction SilentlyContinue
            throw "Server exited early with code $($server.ExitCode). stdout=$stdout stderr=$stderr"
        }

        try {
            $tcp = [Net.Sockets.TcpClient]::new()
            $connect = $tcp.BeginConnect("127.0.0.1", $Port, $null, $null)
            if ($connect.AsyncWaitHandle.WaitOne(500) -and $tcp.Connected) {
                $tcp.EndConnect($connect)
                $listening = $true
                $tcp.Dispose()
                break
            }

            $tcp.Dispose()
        }
        catch {
        }

        Start-Sleep -Milliseconds 500
    }

    if (-not $listening) {
        $stdout = Get-Content -LiteralPath $serverOut -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $serverErr -Raw -ErrorAction SilentlyContinue
        throw "Server did not listen on 127.0.0.1:$Port. stdout=$stdout stderr=$stderr"
    }

    Push-Location $w3cTestDir
    try {
        $env:SPEC_LEVEL = "2"
        $env:STRICT_LEVEL = "2"
        $env:HARNESS_PORT = "$HarnessPort"
        $env:HARNESS_BIND_PORT = "$HarnessPort"

        $testArgs = @("-W", "ignore", "test.py", "http://127.0.0.1:$Port/")
        if ($Pattern) {
            $testArgs += $Pattern
        }

        & $venvPython @testArgs
        $suiteExit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    Write-Host "W3C suite exit code: $suiteExit"
    Write-Host "Server stdout: $serverOut"
    Write-Host "Server stderr: $serverErr"
}
finally {
    if ($server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $server.Id -Timeout 10 -ErrorAction SilentlyContinue
    }

    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        Get-CimInstance Win32_Process -Filter "name = 'dotnet.exe'" |
            Where-Object { $_.CommandLine -like "*W3CTraceContextCompliance.dll*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

exit $suiteExit
