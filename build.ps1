# Build do projeto Atari 2600 (Windows). Uso: .\build.ps1 [build|run|clean]
param([ValidateSet("build", "run", "clean")][string]$Task = "build")

$root = $PSScriptRoot
$dasm = Join-Path $root "tools\dasm.exe"
$out  = Join-Path $root "build\game.bin"

function Find-Stella {
    $cmd = Get-Command Stella.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($d in "$env:ProgramFiles\Stella", "${env:ProgramFiles(x86)}\Stella", "$env:LOCALAPPDATA\Programs\Stella") {
        $exe = Join-Path $d "Stella.exe"
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

function Invoke-Build {
    if (-not (Test-Path $dasm)) { throw "dasm.exe nao encontrado em tools\. Veja docs\DEVELOPMENT.md secao 2." }
    New-Item -ItemType Directory -Force (Join-Path $root "build") | Out-Null
    Push-Location $root
    try {
        # Array evita o parsing do PowerShell sobre os flags colados (-o..., -I...)
        $dasmArgs = @("src\main.asm", "-f3", "-obuild\game.bin", "-Iinclude", "-lbuild\game.lst", "-sbuild\game.sym")
        & $dasm @dasmArgs
        if ($LASTEXITCODE -ne 0) { throw "DASM falhou (codigo $LASTEXITCODE)." }
    } finally { Pop-Location }
    Write-Host "OK: $out ($((Get-Item $out).Length) bytes)"
}

switch ($Task) {
    "build" { Invoke-Build }
    "run" {
        Invoke-Build
        $stella = Find-Stella
        if (-not $stella) { throw "Stella.exe nao encontrado. Instale: winget install TheStellaTeam.Stella" }
        & $stella $out
    }
    "clean" { Remove-Item -Recurse -Force (Join-Path $root "build") -ErrorAction SilentlyContinue }
}
