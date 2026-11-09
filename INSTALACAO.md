# ⚙️ Guia de Instalação Global e Variáveis de Ambiente (`INSTALACAO.md`)

Este documento detalha passo a passo como instalar o algoritmo [**`del_hist.ps1`**](./del_hist.ps1) de maneira **global** para que:
1. **O Agente de IA (Antigravity)** possa acioná-lo automaticamente em qualquer repositório ao estruturar ou manter o `.agent/`.
2. **Você ou seu parceiro de equipe** possam digitar apenas as palavras reservadas **`del_hist`** (para expurgar e subir) ou **`pull_hist`** (para puxar/sincronizar a árvore reescrita sem perder o `.agent/` local) em qualquer terminal e dentro de qualquer `git clone` do computador, sem precisar copiar o arquivo `.ps1` para dentro dos projetos.

> [!IMPORTANT]
> **Atuação Exclusiva por Branch Ativa:** Quando executado, o `del_hist` atua **apenas sobre a branch em que o terminal está posicionado no momento (`HEAD`)**, limpando a árvore de commits daquela branch e atualizando exclusivamente ela no GitHub (`git push origin --force refs/heads/<branch>:refs/heads/<branch>`), sem alterar outras branches do repositório.

---

## 📋 1. Pré-Requisitos e Necessidades do Ambiente

Antes de realizar a instalação global, garanta que os seguintes itens estejam configurados no Windows:

### 1.1. Permissão de Execução de Scripts no PowerShell (`ExecutionPolicy`)
Por padrão, o Windows pode bloquear scripts `.ps1` locais. Libere a execução para o seu usuário atual rodando uma única vez no PowerShell:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

### 1.2. Git for Windows e Git Credential Manager (Autenticação no GitHub)
Como o `del_hist` executa automaticamente o `git push origin --force` da branch atual no final do processo, o Git precisa estar autenticado na sua conta do GitHub para não travar pedindo login:
```powershell
# Verifique se o Git está instalado e com suas credenciais configuradas
git --version
git config --global credential.helper manager
```

### 1.3. PowerShell 7+ (`pwsh`) — *Recomendado*
O script funciona tanto no Windows PowerShell 5.1 nativo quanto no PowerShell 7 (`pwsh`). Caso queira instalar o PowerShell 7 via Winget:
```powershell
winget install --id Microsoft.PowerShell --source winget
```

---

## 🧠 2. Como Instalar Globalmente na Arquitetura do Agente (`~/.gemini/config/skills/`)

Para que o agente de IA reconheça a ferramenta em **todos os projetos futuros** (sem que você precise explicar os comandos Git novamente), a ferramenta deve ser instalada na pasta global de Skills do usuário:

### Estrutura de Pastas Global
```text
C:\Users\<SEU_USUARIO>\.gemini\
├── bin\                                  # Pasta global no PATH do Windows (Palavras reservadas)
│   ├── del_hist.cmd                      # Atalho para Expurgo + Push (CMD / Git Bash / VS Code)
│   ├── del_hist.ps1                      # Atalho para Expurgo + Push (PowerShell)
│   ├── pull_hist.cmd                     # Atalho para Pull/Sync Seguro preservando .agent local
│   └── pull_hist.ps1                     # Atalho para Pull/Sync Seguro (PowerShell)
└── config\
    └── skills\
        ├── bootstrap-agent-workspace\    # Skill que inicializa o .agent
        │   └── SKILL.md
        └── git-history-purge\            # Skill global do expurgo de histórico
            ├── SKILL.md                  # Instruções para o agente de IA
            └── scripts\
                └── del_hist.ps1          # Motor principal do algoritmo
```

### Passo a Passo para Copiar o Algoritmo para a Skill Global
Execute no PowerShell a partir da pasta onde está o seu `del_hist.ps1`:

```powershell
# 1. Cria a estrutura da Skill Global
$SkillDir = "$HOME\.gemini\config\skills\git-history-purge"
New-Item -ItemType Directory -Path "$SkillDir\scripts" -Force | Out-Null

# 2. Copia o algoritmo del_hist.ps1 para dentro da Skill Global
Copy-Item -LiteralPath ".\del_hist.ps1" -Destination "$SkillDir\scripts\del_hist.ps1" -Force
```

### Como Conectar ao `.agent` (`bootstrap-agent-workspace`)
No arquivo `$HOME\.gemini\config\skills\bootstrap-agent-workspace\SKILL.md`, na seção **Passo 8 (Privacidade e Git)**, mantenha a diretriz de mutualismo:
> **Mutualismo com `git-history-purge`:** Sempre que o usuário solicitar a remoção de `.agent/`, `AGENTS.md`, `GEMINI.md` ou `relatorios/` da árvore de commits e da nuvem (GitHub) mantendo-os intactos na máquina local, o agente deve acionar a skill `git-history-purge` e executar `$HOME\.gemini\config\skills\git-history-purge\scripts\del_hist.ps1 -RepoPath "<caminho>" -NoInteractive`.

---

## 🌐 3. Como Colocar as Palavras Reservadas (`del_hist` e `pull_hist`) nas Variáveis de Ambiente

Para que você ou seu parceiro possam abrir o terminal em **qualquer repositório (`git clone`)** e digitar apenas `del_hist` (para limpar e dar push) ou `pull_hist` (para puxar a árvore reescrita mantendo o `.agent/` local intacto), execute o bloco de instalação abaixo no PowerShell.

Ele realiza **3 configurações simultâneas**:
1. Cria os lançadores em `$HOME\.gemini\bin` (`del_hist.cmd`/`.ps1` e `pull_hist.cmd`/`.ps1`).
2. Adiciona `$HOME\.gemini\bin` na variável de ambiente **`Path`** permanente do seu usuário no Windows e cria as variáveis `$env:del_hist` e `$env:pull_hist`.
3. Registra as funções `del_hist` e `pull_hist` no perfil global do PowerShell (`$PROFILE.CurrentUserAllHosts`).

### Script Único de Registro das Palavras Reservadas

```powershell
# Defina aqui as palavras reservadas que deseja usar no terminal
$PalavraReservada = "del_hist"
$PalavraPull = "pull_hist"

$BinDir = "$HOME\.gemini\bin"
$ScriptOficial = "$HOME\.gemini\config\skills\git-history-purge\scripts\del_hist.ps1"

# 1. Cria a pasta bin global e os arquivos lançadores (.cmd e .ps1)
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null

# Lançadores para del_hist (Expurgo + Force-Push)
$CmdContent = @"
@echo off
where pwsh >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "$ScriptOficial" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "$ScriptOficial" %*
)
"@
Set-Content -LiteralPath "$BinDir\$PalavraReservada.cmd" -Value $CmdContent -Encoding ascii
Set-Content -LiteralPath "$BinDir\$PalavraReservada.ps1" -Value "& `"$ScriptOficial`" @args" -Encoding utf8

# Lançadores para pull_hist (Pull/Sync Seguro preservando .agent local)
$PullCmdContent = @"
@echo off
where pwsh >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "$ScriptOficial" -Pull %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "$ScriptOficial" -Pull %*
)
"@
Set-Content -LiteralPath "$BinDir\$PalavraPull.cmd" -Value $PullCmdContent -Encoding ascii
Set-Content -LiteralPath "$BinDir\$PalavraPull.ps1" -Value "& `"$ScriptOficial`" -Pull @args" -Encoding utf8

# 2. Adiciona a pasta bin ao PATH permanente do Usuário no Windows
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
$PathList = $UserPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
if ($PathList -notcontains $BinDir) {
    $NewUserPath = ($PathList + $BinDir) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
    Write-Host "[OK] '$BinDir' adicionado ao PATH permanente do Windows." -ForegroundColor Green
}

# 3. Cria as variáveis de ambiente dedicadas
[Environment]::SetEnvironmentVariable($PalavraReservada, $ScriptOficial, "User")
[Environment]::SetEnvironmentVariable($PalavraPull, "$ScriptOficial -Pull", "User")
Write-Host "[OK] Variáveis de ambiente '$PalavraReservada' e '$PalavraPull' registradas." -ForegroundColor Green

# 4. Registra no PowerShell Profile (carregamento instantâneo em qualquer sessão PowerShell)
$ProfilePath = $PROFILE.CurrentUserAllHosts
$ProfileDir = Split-Path -Parent $ProfilePath
if (-not (Test-Path -LiteralPath $ProfileDir)) {
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
}
$FunctionDel = "function $PalavraReservada { & `"$ScriptOficial`" @args }"
$FunctionPull = "function $PalavraPull { & `"$ScriptOficial`" -Pull @args }"
if (-not (Test-Path -LiteralPath $ProfilePath) -or ((Get-Content -LiteralPath $ProfilePath -Raw) -notmatch "function $PalavraReservada\b")) {
    Add-Content -LiteralPath $ProfilePath -Value "`n$FunctionDel`n" -Encoding utf8
    Write-Host "[OK] Função '$PalavraReservada' adicionada ao PowerShell Profile: $ProfilePath" -ForegroundColor Green
}
if ((Get-Content -LiteralPath $ProfilePath -Raw) -notmatch "function $PalavraPull\b") {
    Add-Content -LiteralPath $ProfilePath -Value "$FunctionPull`n" -Encoding utf8
    Write-Host "[OK] Função '$PalavraPull' adicionada ao PowerShell Profile: $ProfilePath" -ForegroundColor Green
}
```

---

## 🔍 4. Como Verificar se a Instalação Funcionou

Após executar os passos acima, abra um **novo terminal** em qualquer pasta e execute:

```powershell
# 1. Verifica se o Windows reconhece as palavras reservadas del_hist e pull_hist
Get-Command del_hist, pull_hist

# 2. Testa em modo de simulação (-DryRun) dentro de qualquer repositório Git
cd C:\caminho\de\qualquer\repositorio
del_hist -DryRun -NoInteractive
pull_hist -DryRun
```

---

## 🔄 5. Manutenção: Como Atualizar ou Trocar a Palavra Reservada

### Atualizar o Algoritmo Global
Sempre que você fizer melhorias no arquivo [`del_hist.ps1`](./del_hist.ps1), basta copiá-lo novamente para a pasta da skill global:
```powershell
Copy-Item -LiteralPath ".\del_hist.ps1" -Destination "$HOME\.gemini\config\skills\git-history-purge\scripts\del_hist.ps1" -Force
```
Todos os atalhos e variáveis de ambiente passarão a usar a nova versão imediatamente.

### Trocar a Palavra Reservada
Se no futuro quiser mudar de `del_hist` para outro nome (por exemplo, `limpargit`):
1. Altere `$PalavraReservada = "limpargit"` no script da **Seção 3** acima e execute-o novamente.
2. Remova os lançadores antigos de `$HOME\.gemini\bin\del_hist.*`.
