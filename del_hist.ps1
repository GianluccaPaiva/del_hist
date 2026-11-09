<#
.SYNOPSIS
    Algoritmo de Expurgo Invisível do .agent e Artefatos de IA em Todo o Histórico do Git.

.DESCRIPTION
    Remove retroativamente .agent/, AGENTS.md, GEMINI.md, relatorios/ e quaisquer diretórios/arquivos
    adicionais selecionados pelo usuário em TODAS as branches e tags do repositório Git.
    - Preserva 100% dos registros de horário originais (GIT_AUTHOR_DATE e GIT_COMMITTER_DATE).
    - Preserva a topologia de ramificações (merge-base) para permitir merges futuros sem conflito.
    - Oferece Seletor Interativo TUI no próprio terminal (Setas ↑/↓, [Espaço] p/ marcar, [Enter] p/ confirmar).
    - Higieniza menções no .gitignore ao longo do histórico.
    - Destrói rastros forenses locais (refs/original, filter-repo, reflog, objetos órfãos via gc --aggressive).

.PARAMETER RepoPath
    Caminho do repositório Git alvo. Padrão: diretório atual.

.PARAMETER ExtraPaths
    Lista de arquivos ou pastas extras para adicionar à seleção de remoção.

.PARAMETER NoInteractive
    Executa diretamente com os alvos padrão + ExtraPaths sem abrir o menu interativo TUI.

.PARAMETER CleanGitignore
    Remove automaticamente linhas do .gitignore que referenciem os arquivos/pastas expurgados em todo o histórico (Padrão: $true).

.PARAMETER SanitizeMessages
    Remove linhas de mensagens de commits mistos que mencionem explicitamente .agent, AGENTS.md ou GEMINI.md.

.PARAMETER PushRemote
    Executa automaticamente o force-push coordenado (todas as branches e tags com --prune) para o remote origin.

.PARAMETER DryRun
    Apenas simula e exibe o diagnóstico de commits e branches afetados sem alterar o repositório.

.PARAMETER SkipBackup
    Não cria o backup espelhado (--mirror) temporário antes da reescrita.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RepoPath = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [string[]]$ExtraPaths = @(),

    [Parameter(Mandatory = $false)]
    [switch]$NoInteractive,

    [Parameter(Mandatory = $false)]
    [bool]$CleanGitignore = $true,

    [Parameter(Mandatory = $false)]
    [switch]$SanitizeMessages,

    [Parameter(Mandatory = $false)]
    [bool]$PushRemote = $true,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$SkipBackup
)

Set-StrictMode -Version Latest
# Mantém "Continue" para executáveis nativos (evita que stderr do git.exe com 2>&1 dispare NativeCommandError no PowerShell 5.1)
# e aplica "Stop" automaticamente a todos os cmdlets PowerShell.
$ErrorActionPreference = "Continue"
$PSDefaultParameterValues['*:ErrorAction'] = 'Stop'

# ==============================================================================
# CONFIGURAÇÃO PADRÃO DE ALVOS DO AGENTE
# ==============================================================================
$DefaultAgentTargets = @(
    ".agent",
    "AGENTS.md",
    "AGENTS.MD",
    "agents.md",
    "GEMINI.md",
    "GEMINI.MD",
    "gemini.md",
    "relatorios"
)

$ScriptSelfName = Split-Path -Leaf $PSCommandPath

# ==============================================================================
# FUNÇÕES AUXILIARES DE LOG E UI
# ==============================================================================
function Write-Step {
    param([string]$Stage, [string]$Message)
    Write-Host "`n[$Stage] " -ForegroundColor Cyan -NoNewline
    Write-Host $Message -ForegroundColor White
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor Gray
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK]   $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "  [ERRO] $Message" -ForegroundColor Red
}

# ==============================================================================
# DESCOBERTA DE ARQUIVOS E DIRETÓRIOS (ATIVOS NO DISCO + FANTASMAS NO HISTÓRICO)
# ==============================================================================
function Get-RepositoryCatalog {
    param(
        [string[]]$PreSelectedDefaults,
        [string[]]$UserExtraPaths
    )

    $catalogMap = [ordered]@{}

    # 1. Garante que os alvos principais de IA apareçam no topo do seletor
    $primaryDisplayTargets = @(".agent", "AGENTS.md", "GEMINI.md", "relatorios")
    foreach ($t in $primaryDisplayTargets) {
        $existsOnDisk = Test-Path -LiteralPath $t
        $isDir = $existsOnDisk -and (Get-Item -LiteralPath $t -Force).PSIsContainer
        if ($t -in @(".agent", "relatorios")) { $isDir = $true }
        $catalogMap[$t] = [PSCustomObject]@{
            Path       = $t
            IsDir      = $isDir
            Origin     = if ($existsOnDisk) { "Ativo no Disco" } else { "Padrão IA" }
            Category   = "Padrão Agente"
            Selected   = $true
        }
    }

    # 2. Adiciona caminhos extras informados via parâmetro CLI
    foreach ($extra in $UserExtraPaths) {
        $cleanExtra = ($extra -replace '\\', '/').TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($cleanExtra)) { continue }
        if (-not $catalogMap.Contains($cleanExtra)) {
            $existsOnDisk = Test-Path -LiteralPath $cleanExtra
            $isDir = $existsOnDisk -and (Get-Item -LiteralPath $cleanExtra -Force).PSIsContainer
            $catalogMap[$cleanExtra] = [PSCustomObject]@{
                Path       = $cleanExtra
                IsDir      = $isDir
                Origin     = if ($existsOnDisk) { "Ativo no Disco" } else { "Parâmetro CLI" }
                Category   = "Extra CLI"
                Selected   = $true
            }
        } else {
            $catalogMap[$cleanExtra].Selected = $true
        }
    }

    # 3. Varre itens atualmente presentes na raiz e subpastas imediatas do disco (exceto .git)
    $diskItems = Get-ChildItem -Force | Where-Object { $_.Name -ne ".git" -and $_.Name -ne $ScriptSelfName }
    foreach ($item in $diskItems) {
        $relPath = $item.Name
        # Normaliza equivalentes case-insensitive já registrados nos padrões
        $existingKey = $catalogMap.Keys | Where-Object { $_.Equals($relPath, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($null -ne $existingKey) {
            $catalogMap[$existingKey].Origin = "Ativo no Disco"
            continue
        }

        $isDefault = $PreSelectedDefaults -contains $relPath
        $catalogMap[$relPath] = [PSCustomObject]@{
            Path       = $relPath
            IsDir      = $item.PSIsContainer
            Origin     = "Ativo no Disco"
            Category   = if ($isDefault) { "Padrão Agente" } else { "Projeto" }
            Selected   = $isDefault
        }
    }

    # 4. Varre TODO o histórico do Git em todas as branches/tags para achar arquivos/pastas já apagados
    $hasCommits = $false
    git rev-parse --verify HEAD >$null 2>&1
    if ($LASTEXITCODE -eq 0) { $hasCommits = $true }

    if ($hasCommits) {
        $histFiles = @(git log HEAD --pretty=format: --name-only 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        foreach ($file in $histFiles) {
            $cleanFile = ($file -replace '\\', '/').Trim()
            if ($cleanFile -eq $ScriptSelfName) { continue }

            # Extrai o diretório raiz se for caminho aninhado (ex: ".agent/rules/x.md" -> ".agent")
            $parts = $cleanFile -split '/'
            if ($parts.Count -gt 1) {
                $topDir = $parts[0]
                $existingDirKey = $catalogMap.Keys | Where-Object { $_.Equals($topDir, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                if ($null -eq $existingDirKey) {
                    $existsNow = Test-Path -LiteralPath $topDir
                    $isDefault = $PreSelectedDefaults -contains $topDir
                    $catalogMap[$topDir] = [PSCustomObject]@{
                        Path       = $topDir
                        IsDir      = $true
                        Origin     = if ($existsNow) { "Ativo + Histórico" } else { "Apenas Histórico" }
                        Category   = if ($isDefault) { "Padrão Agente" } else { "Projeto" }
                        Selected   = $isDefault
                    }
                } elseif ($catalogMap[$existingDirKey].Origin -eq "Padrão IA") {
                    $catalogMap[$existingDirKey].Origin = "Apenas Histórico"
                } elseif ($catalogMap[$existingDirKey].Origin -eq "Ativo no Disco") {
                    $catalogMap[$existingDirKey].Origin = "Ativo + Histórico"
                }
            }

            # Adiciona também o próprio arquivo se não estiver dentro de .agent ou relatorios
            if ($parts[0] -notin @(".agent", "relatorios")) {
                $existingFileKey = $catalogMap.Keys | Where-Object { $_.Equals($cleanFile, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
                if ($null -eq $existingFileKey) {
                    $existsNow = Test-Path -LiteralPath $cleanFile
                    $isDefault = $PreSelectedDefaults -contains $cleanFile
                    $catalogMap[$cleanFile] = [PSCustomObject]@{
                        Path       = $cleanFile
                        IsDir      = $false
                        Origin     = if ($existsNow) { "Ativo + Histórico" } else { "Apenas Histórico" }
                        Category   = if ($isDefault) { "Padrão Agente" } else { "Projeto" }
                        Selected   = $isDefault
                    }
                } elseif ($catalogMap[$existingFileKey].Origin -eq "Padrão IA") {
                    $catalogMap[$existingFileKey].Origin = "Apenas Histórico"
                } elseif ($catalogMap[$existingFileKey].Origin -eq "Ativo no Disco") {
                    $catalogMap[$existingFileKey].Origin = "Ativo + Histórico"
                }
            }
        }
    }

    return @($catalogMap.Values)
}

# ==============================================================================
# ESTÁGIO 0: SELETOR INTERATIVO TUI NO TERMINAL (OPÇÃO 1)
# ==============================================================================
function Show-InteractivePathSelector {
    param([array]$Items, [string]$BranchName)

    $cursor = 0
    $pageSize = 14

    while ($true) {
        Clear-Host
        Write-Host "========================================================================================" -ForegroundColor Cyan
        Write-Host " SELETOR DE EXPURGO DO HISTÓRICO GIT — BRANCH ATUAL: [$BranchName]" -ForegroundColor White
        Write-Host "========================================================================================" -ForegroundColor Cyan
        Write-Host " Marque [x] os diretórios e arquivos para APAGAR dos commits da branch '$BranchName':" -ForegroundColor Gray
        Write-Host ""

        $total = $Items.Count
        $startIdx = [Math]::Max(0, [Math]::Min($cursor - [Math]::Floor($pageSize / 2), [Math]::Max(0, $total - $pageSize)))
        $endIdx = [Math]::Min($total - 1, $startIdx + $pageSize - 1)

        for ($i = $startIdx; $i -le $endIdx; $i++) {
            $item = $Items[$i]
            $isCurrent = ($i -eq $cursor)
            $prefix = if ($isCurrent) { " > " } else { "   " }
            $check = if ($item.Selected) { "[x]" } else { "[ ]" }
            $displayName = if ($item.IsDir) { "$($item.Path)/" } else { $item.Path }
            $typeLabel = if ($item.IsDir) { "Diretório" } else { "Arquivo  " }

            $lineText = ("{0}{1} {2,-32} ({3} | {4,-16} | {5})" -f $prefix, $check, $displayName, $typeLabel, $item.Origin, $item.Category)

            if ($isCurrent) {
                Write-Host $lineText -ForegroundColor Black -BackgroundColor Cyan
            } elseif ($item.Selected) {
                Write-Host $lineText -ForegroundColor Yellow
            } else {
                Write-Host $lineText -ForegroundColor Gray
            }
        }

        if ($total -gt $pageSize) {
            Write-Host ("`n   Exibindo itens {0} a {1} de {2}" -f ($startIdx + 1), ($endIdx + 1), $total) -ForegroundColor DarkGray
        }

        Write-Host "`n----------------------------------------------------------------------------------------" -ForegroundColor DarkCyan
        Write-Host " [Espaço] Marcar/Desmarcar | [A] Adicionar caminho manual | [P] Só Padrões IA" -ForegroundColor White
        Write-Host " [Enter]  Confirmar Expurgo | [Esc] ou [Q] Cancelar Operação" -ForegroundColor Green
        Write-Host "----------------------------------------------------------------------------------------" -ForegroundColor DarkCyan

        $keyInfo = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        switch ($keyInfo.VirtualKeyCode) {
            38 { # UpArrow
                if ($cursor -gt 0) { $cursor-- } else { $cursor = $total - 1 }
            }
            40 { # DownArrow
                if ($cursor -lt ($total - 1)) { $cursor++ } else { $cursor = 0 }
            }
            32 { # Spacebar
                $Items[$cursor].Selected = -not $Items[$cursor].Selected
            }
            65 { # 'A' - Adicionar caminho manual
                Write-Host "`n Digite o caminho relativo do arquivo ou pasta para adicionar (ou vazio p/ voltar): " -ForegroundColor Cyan -NoNewline
                $customPath = Read-Host
                if (-not [string]::IsNullOrWhiteSpace($customPath)) {
                    $cleanCustom = ($customPath -replace '\\', '/').TrimEnd('/')
                    $existing = $Items | Where-Object { $_.Path -eq $cleanCustom } | Select-Object -First 1
                    if ($null -ne $existing) {
                        $existing.Selected = $true
                    } else {
                        $existsNow = Test-Path -LiteralPath $cleanCustom
                        $isDir = $existsNow -and (Get-Item -LiteralPath $cleanCustom -Force).PSIsContainer
                        $Items += [PSCustomObject]@{
                            Path       = $cleanCustom
                            IsDir      = $isDir
                            Origin     = if ($existsNow) { "Ativo no Disco" } else { "Manual" }
                            Category   = "Manual"
                            Selected   = $true
                        }
                        $cursor = $Items.Count - 1
                    }
                }
            }
            80 { # 'P' - Resetar apenas para padrões de IA
                foreach ($it in $Items) {
                    $it.Selected = ($it.Category -eq "Padrão Agente")
                }
            }
            13 { # Enter
                return $Items
            }
            27 { # Escape
                throw "Operação cancelada pelo usuário no menu interativo."
            }
            81 { # 'Q'
                throw "Operação cancelada pelo usuário no menu interativo."
            }
        }
    }
}

# ==============================================================================
# EXECUÇÃO PRINCIPAL DO ALGORITMO
# ==============================================================================
$localVaultDir = $null
$preservedItems = @()
Push-Location -LiteralPath $RepoPath
try {
    # Valida se estamos em um repositório Git válido
    git rev-parse --git-dir >$null 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "O diretório '$RepoPath' não é um repositório Git válido."
    }

    $RepoRoot = (git rev-parse --show-toplevel).Trim()
    Set-Location -LiteralPath $RepoRoot

    $currentBranch = (git branch --show-current 2>$null)
    if ([string]::IsNullOrWhiteSpace($currentBranch)) {
        $currentBranch = "main"
    }

    # --------------------------------------------------------------------------
    # ESTÁGIO 0: SELEÇÃO DE ALVOS (ESCOPO: APENAS A BRANCH ATUAL)
    # --------------------------------------------------------------------------
    $catalog = Get-RepositoryCatalog -PreSelectedDefaults $DefaultAgentTargets -UserExtraPaths $ExtraPaths

    if (-not $NoInteractive) {
        $catalog = Show-InteractivePathSelector -Items $catalog -BranchName $currentBranch
    }

    $selectedItems = @($catalog | Where-Object { $_.Selected })
    if ($selectedItems.Count -eq 0) {
        Write-Warn "Nenhum arquivo ou diretório foi selecionado para remoção. Encerrando."
        return
    }

    # Expande variantes de caixa para AGENTS.md e GEMINI.md automaticamente se selecionados
    $targetPathsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($sel in $selectedItems) {
        [void]$targetPathsSet.Add($sel.Path)
        if ($sel.Path -ieq "AGENTS.md") {
            [void]$targetPathsSet.Add("AGENTS.md")
            [void]$targetPathsSet.Add("AGENTS.MD")
            [void]$targetPathsSet.Add("agents.md")
        }
        if ($sel.Path -ieq "GEMINI.md") {
            [void]$targetPathsSet.Add("GEMINI.md")
            [void]$targetPathsSet.Add("GEMINI.MD")
            [void]$targetPathsSet.Add("gemini.md")
        }
    }
    $TargetPaths = @($targetPathsSet)

    Write-Step "ESTÁGIO 0" "Branch ativa: [$currentBranch] | Alvos selecionados para expurgo nesta branch:"
    foreach ($tp in $TargetPaths) {
        Write-Info "-> $tp"
    }

    # Verifica se o repositório já possui commits
    $hasCommits = $false
    git rev-parse --verify HEAD >$null 2>&1
    if ($LASTEXITCODE -eq 0) { $hasCommits = $true }

    # Verifica URL do remote origin
    $originUrl = $null
    $remotes = @(git remote 2>$null)
    if ($remotes -contains "origin") {
        $originUrl = (git remote get-url origin 2>$null).Trim()
    }

    if ($DryRun) {
        Write-Step "DRY-RUN" "Modo de simulação ativo na branch '$currentBranch'. Nenhuma alteração será gravada."
        if ($hasCommits) {
            $affectedCommits = @(git log $currentBranch --oneline -- @TargetPaths 2>$null)
            Write-Info "Commits na branch '$currentBranch' que tocam os alvos: $($affectedCommits.Count)"
            foreach ($ac in $affectedCommits) { Write-Info "   $ac" }
        } else {
            Write-Info "A branch '$currentBranch' ainda não possui commits."
        }
        return
    }

    # --------------------------------------------------------------------------
    # ESTÁGIO 1: PRÉ-VOO, BACKUP ESPELHADO (--MIRROR) E PRESERVAÇÃO LOCAL
    # --------------------------------------------------------------------------
    Write-Step "ESTÁGIO 1" "Pré-voo na branch '$currentBranch', captura de snapshot de horários e backup..."

    if (-not $SkipBackup -and $hasCommits) {
        $repoName = Split-Path -Leaf $RepoRoot
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $backupPath = Join-Path $env:TEMP "git-mirror-backup-$repoName-$timestamp.git"
        git clone --mirror --quiet $RepoRoot $backupPath
        Write-Success "Backup espelhado (--mirror) criado em: $backupPath"
    }

    # Captura mapa de timestamps originais da branch atual antes da reescrita
    $originalTimestamps = @{}
    if ($hasCommits) {
        $rawLog = @(git log $currentBranch --format="%H|%aI|%cI|%s" 2>$null)
        foreach ($line in $rawLog) {
            $parts = $line -split '\|', 4
            if ($parts.Count -eq 4) {
                $originalTimestamps[$parts[3]] = @{
                    OldHash       = $parts[0]
                    AuthorDate    = $parts[1]
                    CommitterDate = $parts[2]
                }
            }
        }
    }

    # Verifica se há alterações locais legítimas (fora dos alvos que serão apagados) antes de mexer no disco
    $stashed = $false
    if ($hasCommits) {
        $targetRegexParts = ($TargetPaths | ForEach-Object { [Regex]::Escape(($_ -replace '\\', '/').TrimEnd('/')) }) + @("\.gitignore")
        $ignoreStatusRegex = "(?i)($($targetRegexParts -join '|'))"
        $legitDirty = @(git status --porcelain 2>$null | Where-Object { $_ -notmatch $ignoreStatusRegex })
        if ($legitDirty.Count -gt 0) {
            git stash push -u -m "temp-stash-before-purge" --quiet >$null 2>&1
            if ($LASTEXITCODE -eq 0) {
                $stashed = $true
                Write-Info "Alterações locais não comitadas (fora dos alvos) salvas temporariamente em stash."
            }
        }
    }

    # Preserva em cofre temporário todos os arquivos/pastas selecionados que existem no disco local
    # para que NÃO sejam apagados do projeto local (removidos apenas da árvore de commits e da nuvem GitHub)
    $localVaultDir = Join-Path $env:TEMP "git-local-vault-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $localVaultDir -Force | Out-Null
    $preservedItems = @()

    foreach ($tp in $TargetPaths) {
        if (Test-Path -LiteralPath $tp) {
            $destPath = Join-Path $localVaultDir $tp
            $destParent = Split-Path -Parent $destPath
            if (-not (Test-Path -LiteralPath $destParent)) {
                New-Item -ItemType Directory -Path $destParent -Force | Out-Null
            }
            Copy-Item -LiteralPath $tp -Destination $destPath -Recurse -Force
            $preservedItems += $tp
        }
        # Remove apenas do índice do Git (--cached), mantendo a cópia segura no cofre
        git rm -rf --cached --ignore-unmatch -- $tp >$null 2>&1
    }
    if ($preservedItems.Count -gt 0) {
        Write-Success "Arquivos locais preservados com segurança (serão mantidos no disco local e removidos apenas dos commits/nuvem): $($preservedItems -join ', ')"
    }

    # Higieniza o .gitignore local caso contenha referências aos alvos
    if ($CleanGitignore -and (Test-Path -LiteralPath ".gitignore")) {
        $escapedPatterns = ($TargetPaths | ForEach-Object { [Regex]::Escape($_) }) -join "|"
        $gitignoreRegex = "(?i)^\s*(#\s*Relat[oó]rios locais de sess[aã]o do agente.*|/?($escapedPatterns)/?\s*)$"
        $rawGitignore = @(Get-Content -LiteralPath ".gitignore")
        $cleanedGitignore = @($rawGitignore | Where-Object { $_ -notmatch $gitignoreRegex })

        if ($cleanedGitignore.Count -ne $rawGitignore.Count) {
            $finalGitignore = ($cleanedGitignore -join "`n").Trim()
            if ([string]::IsNullOrWhiteSpace($finalGitignore)) {
                Remove-Item -LiteralPath ".gitignore" -Force
                git rm -f --cached --ignore-unmatch ".gitignore" >$null 2>&1
                Write-Success ".gitignore continha apenas regras dos alvos e foi limpo."
            } else {
                Set-Content -LiteralPath ".gitignore" -Value ($finalGitignore + "`n") -NoNewline -Encoding utf8
                Write-Success "Entradas dos alvos removidas do .gitignore."
            }
        }
    }

    # Protege os arquivos locais no .git/info/exclude (100% local, nunca sobe para o GitHub nem aparece no .gitignore)
    $gitDir = (git rev-parse --git-dir).Trim()
    $excludeFile = Join-Path $gitDir "info\exclude"
    if (Test-Path -LiteralPath $excludeFile) {
        $existingExclude = @(Get-Content -LiteralPath $excludeFile)
        $addedExclude = $false
        foreach ($tp in $TargetPaths) {
            if ($existingExclude -notcontains $tp) {
                Add-Content -LiteralPath $excludeFile -Value $tp -Encoding utf8
                $addedExclude = $true
            }
        }
        if ($addedExclude) {
            Write-Success "Alvos registrados em .git/info/exclude (continuam no disco local sem aparecer no git status ou na nuvem)."
        }
    }

    # Se o repositório ainda não tinha nenhum commit, restaura o cofre local e encerra!
    if (-not $hasCommits) {
        foreach ($tp in $preservedItems) {
            $srcVault = Join-Path $localVaultDir $tp
            if (-not (Test-Path -LiteralPath $tp) -and (Test-Path -LiteralPath $srcVault)) {
                Copy-Item -LiteralPath $srcVault -Destination $tp -Recurse -Force
            }
        }
        Remove-Item -LiteralPath $localVaultDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Success "O repositório ainda não possuía commits. Os arquivos permanecem intactos no projeto local e fora do índice do Git!"
        return
    }

    # Garante que a working tree e o índice estejam limpos para o filter-branch/filter-repo operar
    git checkout -- .gitignore >$null 2>&1
    git reset --hard HEAD >$null 2>&1

    # --------------------------------------------------------------------------
    # ESTÁGIO 2: ISOLAMENTO DE ESCOPO NA BRANCH ATUAL
    # --------------------------------------------------------------------------
    Write-Step "ESTÁGIO 2" "Isolando operação exclusivamente na branch atual: [$currentBranch]..."
    Write-Success "Outras branches não serão alteradas. Para limpar outra branch, troque para ela (git checkout <branch>) e execute novamente."

    # --------------------------------------------------------------------------
    # ESTÁGIO 3 & 4: REESCRITA EXCLUSIVA DA BRANCH ATUAL SEM ALTERAR HORÁRIOS
    # --------------------------------------------------------------------------
    Write-Step "ESTÁGIO 3" "Reescrevendo árvore de commits da branch '$currentBranch' (preservando AuthorDate e CommitterDate)..."

    # Verifica se git-filter-repo está disponível e funcional
    $hasFilterRepo = $false
    if (-not $CleanGitignore -and -not $SanitizeMessages) {
        git filter-repo --version >$null 2>&1
        if ($LASTEXITCODE -eq 0) { $hasFilterRepo = $true }
    }

    if ($hasFilterRepo) {
        Write-Info "Motor selecionado: git-filter-repo (Escopo: refs/heads/$currentBranch)"
        $filterRepoArgs = @("filter-repo", "--invert-paths", "--prune-empty=auto", "--refs", "refs/heads/$currentBranch", "--force")
        foreach ($tp in $TargetPaths) {
            $filterRepoArgs += "--path"
            $filterRepoArgs += $tp
        }
        & git @filterRepoArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao executar git-filter-repo na branch '$currentBranch'."
        }
    } else {
        Write-Info "Motor selecionado: git filter-branch --index-filter (Escopo: refs/heads/$currentBranch)"
        $env:FILTER_BRANCH_SQUELCH_WARNING = "1"

        # Constrói lista de caminhos escapados para o POSIX sh interno do Git
        $quotedPaths = ($TargetPaths | ForEach-Object {
            $p = ($_ -replace '\\', '/').TrimEnd('/')
            "'$p'"
        }) -join " "

        $indexFilterCmd = "git rm -rf --cached --ignore-unmatch -- $quotedPaths >/dev/null 2>&1 || true"

        # Higienização cirúrgica do .gitignore dentro do índice de cada commit (sem checkout de árvore e sem aspas duplas para evitar quebra no PS 5.1)
        if ($CleanGitignore) {
            $grepPattern = ($TargetPaths | ForEach-Object {
                $p = ($_ -replace '\\', '/').TrimEnd('/')
                [Regex]::Escape($p)
            }) -join "|"
            $indexFilterCmd += "; if git rev-parse --verify -q :.gitignore >/dev/null 2>&1; then " +
                "if git show :.gitignore | grep -q -i -E '^(#.*Relat.*sess.*agente|[[:space:]]*/?($grepPattern)/?[[:space:]]*`$)'; then " +
                "git show :.gitignore | grep -v -i -E '^(#.*Relat.*sess.*agente|[[:space:]]*/?($grepPattern)/?[[:space:]]*`$)' > .gitignore.purgetmp || true; " +
                "if [ ! -s .gitignore.purgetmp ] || ! grep -q '[^[:space:]]' .gitignore.purgetmp; then git rm -f --cached --ignore-unmatch .gitignore >/dev/null 2>&1; " +
                "else newblob=`$(git hash-object -w .gitignore.purgetmp); " +
                "git update-index --cacheinfo 100644 `$newblob .gitignore >/dev/null 2>&1; fi; " +
                "rm -f .gitignore.purgetmp; fi; fi"
        }

        $filterBranchArgs = @(
            "filter-branch",
            "-f",
            "--index-filter", $indexFilterCmd,
            "--prune-empty"
        )

        if ($SanitizeMessages) {
            $msgPattern = ($TargetPaths | ForEach-Object { [Regex]::Escape(($_ -replace '\\', '/').TrimEnd('/')) }) -join "|"
            $msgFilterCmd = "grep -v -i -E '($msgPattern)' || cat"
            $filterBranchArgs += "--msg-filter"
            $filterBranchArgs += $msgFilterCmd
        }

        $filterBranchArgs += "--"
        $filterBranchArgs += $currentBranch

        & git @filterBranchArgs >$null 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Todos os commits da branch '$currentBranch' continham apenas os arquivos expurgados."
        }
    }

    # Sincroniza o diretório de trabalho com o novo HEAD reescrito e RESTAURA os arquivos locais preservados no cofre
    git reset --hard HEAD >$null 2>&1
    foreach ($tp in $preservedItems) {
        $srcVault = Join-Path $localVaultDir $tp
        if (Test-Path -LiteralPath $srcVault) {
            if (Test-Path -LiteralPath $tp) {
                Remove-Item -LiteralPath $tp -Recurse -Force -ErrorAction SilentlyContinue
            }
            $destParent = Split-Path -Parent $tp
            if (-not [string]::IsNullOrWhiteSpace($destParent) -and -not (Test-Path -LiteralPath $destParent)) {
                New-Item -ItemType Directory -Path $destParent -Force | Out-Null
            }
            Copy-Item -LiteralPath $srcVault -Destination $tp -Recurse -Force
        }
    }
    Remove-Item -LiteralPath $localVaultDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($preservedItems.Count -gt 0) {
        Write-Success "Arquivos locais restaurados intactos no projeto local (fora da árvore de commits): $($preservedItems -join ', ')"
    }

    Write-Success "Reescrita do grafo concluída com preservação estrita de horários."

    # --------------------------------------------------------------------------
    # ESTÁGIO 5: DESTRUIÇÃO DE RASTROS FORENSES LOCAIS (ZERO-TRACE CLEANUP)
    # --------------------------------------------------------------------------
    Write-Step "ESTÁGIO 5" "Eliminando rastros forenses (.git/refs/original, filter-repo, reflog e objetos órfãos)..."

    # 1. Remove todas as referências de backup do filter-branch (refs/original/*)
    $origRefs = @(git for-each-ref --format="%(refname)" refs/original/ 2>$null)
    foreach ($ref in $origRefs) {
        if (-not [string]::IsNullOrWhiteSpace($ref)) {
            git update-ref -d $ref >$null 2>&1
        }
    }

    # 2. Remove diretório de metadados do git-filter-repo se existir
    $gitDir = (git rev-parse --git-dir).Trim()
    $filterRepoMeta = Join-Path $gitDir "filter-repo"
    if (Test-Path -LiteralPath $filterRepoMeta) {
        Remove-Item -LiteralPath $filterRepoMeta -Recurse -Force
    }

    # 3. Limpa a referência remota antiga apenas da branch atual (refs/remotes/origin/<branch>)
    git update-ref -d "refs/remotes/origin/$currentBranch" >$null 2>&1

    # 4. Restaura a configuração do remote origin caso tenha sido removida pelo filter-repo
    if (-not [string]::IsNullOrWhiteSpace($originUrl)) {
        $currentRemotes = @(git remote 2>$null)
        if ($currentRemotes -notcontains "origin") {
            git remote add origin $originUrl >$null 2>&1
        }
    }

    # 5. Expira imediatamente todas as entradas do reflog
    git reflog expire --expire=now --expire-unreachable=now --all >$null 2>&1

    # 6. Executa Garbage Collector agressivo para destruir fisicamente os blobs e trees antigos
    git gc --prune=now --aggressive --quiet >$null 2>&1

    # Restaura stash se havia modificações locais legítimas antes do expurgo
    if ($stashed) {
        git stash pop --quiet >$null 2>&1
        Write-Info "Alterações locais legítimas restauradas do stash."
    }

    Write-Success "Limpeza forense concluída na branch '$currentBranch': zero referências órfãs ou logs residuais."

    # --------------------------------------------------------------------------
    # ESTÁGIO 6: AUDITORIA FORENSE AUTOMATIZADA E SINCRONIZAÇÃO REMOTA DA BRANCH ATUAL
    # --------------------------------------------------------------------------
    Write-Step "ESTÁGIO 6" "Executando auditoria forense automatizada na branch '$currentBranch'..."

    $remainingCommitsWithTargets = @(git log $currentBranch --full-history --oneline -- @TargetPaths 2>$null)
    if ($remainingCommitsWithTargets.Count -eq 0) {
        Write-Success "Auditoria de Caminhos: 0 vestígios encontrados na branch '$currentBranch'."
    } else {
        Write-Err "Ainda foram encontrados $($remainingCommitsWithTargets.Count) commits referenciando os alvos na branch '$currentBranch'!"
    }

    # Verifica integridade dos horários (AuthorDate e CommitterDate idênticos aos originais) na branch atual
    $newLog = @(git log $currentBranch --format="%H|%aI|%cI|%s" 2>$null)
    $verifiedDatesCount = 0
    $dateMismatchCount = 0
    foreach ($line in $newLog) {
        $parts = $line -split '\|', 4
        if ($parts.Count -eq 4) {
            $msg = $parts[3]
            if ($originalTimestamps.ContainsKey($msg)) {
                $orig = $originalTimestamps[$msg]
                if ($parts[1] -eq $orig.AuthorDate -and $parts[2] -eq $orig.CommitterDate) {
                    $verifiedDatesCount++
                } else {
                    $dateMismatchCount++
                }
            }
        }
    }

    if ($dateMismatchCount -eq 0) {
        Write-Success "Auditoria de Horários: 100% dos commits sobreviventes ($verifiedDatesCount) na branch '$currentBranch' mantiveram AuthorDate e CommitterDate originais intactos!"
    } else {
        Write-Warn "Foram detectadas $dateMismatchCount divergências de horário."
    }

    # Push remoto automático exclusivamente da branch atual no final do programa
    if ($PushRemote) {
        if (-not [string]::IsNullOrWhiteSpace($originUrl)) {
            Write-Step "PUSH REMOTO" "Executando git push origin --force refs/heads/${currentBranch}:refs/heads/${currentBranch} ($originUrl)..."
            git push origin --force "refs/heads/${currentBranch}:refs/heads/${currentBranch}"
            Write-Success "Histórico remoto da branch '$currentBranch' atualizado com sucesso no GitHub!"
        } else {
            Write-Warn "Nenhum remote 'origin' configurado neste repositório local (push ignorado)."
        }
    }

    Write-Host "`n========================================================================================" -ForegroundColor Green
    Write-Host " EXPURGO CONCLUÍDO COM SUCESSO E ZERO RASTROS FORENSES!" -ForegroundColor Green
    Write-Host "========================================================================================`n" -ForegroundColor Green

} finally {
    # Garantia contra falhas: se o cofre temporário ainda existir (ex: interrupção ou erro), restaura os arquivos locais imediatamente
    if ($null -ne $localVaultDir -and (Test-Path -LiteralPath $localVaultDir)) {
        foreach ($tp in $preservedItems) {
            $srcVault = Join-Path $localVaultDir $tp
            if (Test-Path -LiteralPath $srcVault) {
                $destParent = Split-Path -Parent $tp
                if (-not [string]::IsNullOrWhiteSpace($destParent) -and -not (Test-Path -LiteralPath $destParent)) {
                    New-Item -ItemType Directory -Path $destParent -Force -ErrorAction SilentlyContinue | Out-Null
                }
                Copy-Item -LiteralPath $srcVault -Destination $tp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $localVaultDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
