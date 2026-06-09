# RCSS TUI — Plano de Implementação

## Stack

- **Linguagem**: Go
- **Framework TUI**: [Bubbletea](https://github.com/charmbracelet/bubbletea) (Charm)
- **Estilos**: [Lipgloss](https://github.com/charmbracelet/lipgloss)
- **Componentes**: [Bubbles](https://github.com/charmbracelet/bubbles) (spinner, progress, viewport, list)

## Estratégia Git

```
main (scripts bash atuais - estável)
  └── feature/tui (nova branch)
        ├── tui/           ← código Go da TUI
        ├── *.sh           ← scripts bash (herdados da main, inalterados)
        └── backup.env     ← compartilhado
```

- Branch `feature/tui` criada a partir de `main`
- Scripts bash permanecem na raiz e são chamados como subprocessos pela TUI
- Quando a TUI estiver estável, merge de volta para `main`
- Se no futuro quiser separar: a TUI pode virar o "entrypoint" principal e os scripts ficam como backend

## Estrutura do Projeto Go

```
RCSS/
├── tui/
│   ├── main.go           ← entrypoint
│   ├── go.mod
│   ├── styles.go         ← tema/cores
│   ├── models/
│   │   ├── dashboard.go  ← tela principal (menu)
│   │   ├── upload.go     ← tela de upload (progress, seleção)
│   │   ├── restore.go    ← tela de restore (seleção projeto/arquivo)
│   │   ├── clean.go      ← tela de cleanup remoto
│   │   └── logs.go       ← visualizador de logs
│   └── runner/
│       └── exec.go       ← wrapper para exec.Command() dos scripts
├── uploadBackup.sh       ← existente
├── restoreBackup.sh      ← existente
├── cleanRemoteBackups.sh ← existente
├── backup.env            ← existente
└── sync.log              ← existente
```

## Integração com Scripts Bash

A TUI chama os scripts bash via `exec.Command()`:

- **Upload**: `exec.Command("./uploadBackup.sh", "-p", "-v")` — captura stdout/stderr em tempo real via `cmd.StdoutPipe()`
- **Restore**: O `restoreBackup.sh` tem menu interativo próprio (`select_from_list`). A TUI reimplementa a seleção em Go, chamando `rclone lsf` diretamente para listar projetos/arquivos e `rclone copy` para download — sem passar pelo script
- **Clean**: `exec.Command("./cleanRemoteBackups.sh", "-d", "-v")` para dry-run, depois sem `-d` para execução

## Componentes da TUI (Dashboard)

| Tela | Descrição |
|---|---|
| **Menu Principal** | Opções: Upload, Restore, Clean Remote, View Logs, Settings, Quit |
| **Upload** | Mostra progresso em tempo real, lista projetos sendo processados, flags (-D, -s, -p) |
| **Restore** | Seleção de projeto → seleção de arquivo → destino → download com progresso |
| **Clean Remote** | Confirmação, dry-run preview, execução |
| **Logs** | Visualizador do sync.log com scroll e destaque de erros |
| **Settings** | Exibe/valida config do backup.env |

## Passos de Implementação

1. **Setup**: Criar branch `feature/tui`, inicializar módulo Go em `tui/`
2. **Runner**: Implementar `runner/exec.go` com captura de output em tempo real
3. **Dashboard/Menu**: Tela principal com navegação
4. **Upload screen**: Chamar uploadBackup.sh com progresso
5. **Restore screen**: Listar projetos/arquivos via `rclone lsf`, download via `rclone copy`
6. **Clean screen**: Dry-run + execução do cleanRemoteBackups.sh
7. **Logs viewer**: Leitor do sync.log com bubbletea viewport
8. **Polish**: Estilos, tratamento de erros, loading states

## Dependências Go

```
github.com/charmbracelet/bubbletea    ← framework TUI
github.com/charmbracelet/lipgloss     ← estilos
github.com/charmbracelet/bubbles      ← componentes (spinner, progress, viewport, list)
```
