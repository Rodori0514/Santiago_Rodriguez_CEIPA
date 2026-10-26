# Publica este proyecto en GitHub como repositorio publico.
# Requisitos: git y GitHub CLI (gh) instalados. Ejecuta antes: gh auth login

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "=== Verificando herramientas ===" -ForegroundColor Cyan
git --version | Out-Null
gh --version | Out-Null
gh auth status

if (Test-Path .env) {
    Write-Error "Existe un archivo .env local. No lo subas; borralo o dejalo fuera del commit."
}

Write-Host "`n=== Estado de git ===" -ForegroundColor Cyan
$hasCommit = git rev-parse HEAD 2>$null
if (-not $hasCommit) {
    git add -A
    git status
    git commit -m @"
Initial commit: Prueba CEIPA data pipeline

Entrega tecnica CEIPA — extraccion, SQL y pipeline en DuckDB.
"@
} else {
    Write-Host "Ya hay commits locales."
}

$branch = git branch --show-current
if (-not $branch) {
    git checkout -b main 2>$null
    if ($LASTEXITCODE -ne 0) { git checkout -b master }
    $branch = git branch --show-current
}

Write-Host "`n=== Creando repo publico en GitHub ===" -ForegroundColor Cyan
$repoName = "Prueba_CEIPA"
$existing = git remote get-url origin 2>$null
if ($existing) {
    Write-Host "Remote origin ya configurado: $existing"
    git push -u origin $branch
} else {
    gh repo create $repoName --public --source=. --remote=origin --push --description "Prueba tecnica CEIPA - pipeline de datos"
}

Write-Host "`n=== Listo ===" -ForegroundColor Green
gh repo view --web 2>$null
gh repo view --json url -q .url
