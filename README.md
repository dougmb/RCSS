# RcloneCloudSimpleScripts(RCSS) - Sincronização de Backups

Sistema automatizado para gestão de backups multi-projeto integrando armazenamento local e Google Drive via **rclone**.

## 📂 Resumo da Estrutura

- **`uploadBackup.sh`**: Faz o backup para a nuvem de todas as pastas dentro do `BACKUP_ROOT`.
- **`restoreBackup.sh`**: Faz o download interativo de um backup selecionado da nuvem para o servidor local.
- **`cleanRemoteBackups.sh`**: Faz a limpeza remota dos backups mais antigos do que `REMOTE_RETENTION_DAYS`.
- **`backup.env`**: Arquivo de configuração com os settings do ambiente.
- **`sync.log`**: Contém os logs históricos das execuções dos scripts.

---

## 🛠️ Conhecendo os Scripts

### 1. `uploadBackup.sh` (Sincronização Principal)

**O que faz:** Percorre o diretório de backups local e sobe arquivos novos/alterados para a nuvem.

- **Detecção Automática:** Identifica subpastas em `/opt/backups/` como projetos independentes.
- **Upload Eficiente:** Usa `rclone copy --update` para economizar banda.
- **Faxina Local:** Remove arquivos do servidor local que excederam o `RETENTION_DAYS` (somente após upload bem-sucedido).
- **Segurança:** Ignora pastas administrativas (scripts, logs, etc.).

### 2. `cleanRemoteBackups.sh` (Manutenção da Nuvem)

**O que faz:** Gerencia o espaço no Google Drive removendo backups antigos.

- **Independente:** Roda separado do upload para maior controle.
- **Trava de Segurança:** **NUNCA** apaga arquivos se detectar que os backups pararam de ser feitos (baseado em `REMOTE_CLEANUP_SAFETY_DAYS`).
- **Simulação:** Permite rodar com a flag `-d` (dry-run) para ver o que seria apagado sem deletar nada.

### 3. `restoreBackup.sh` (Download de Backups)

**O que faz:** Interface interativa para baixar backups da nuvem para o servidor local.

- **Navegação:** Lista projetos e arquivos diretamente do Google Drive.
- **Download Seletivo:** Permite escolher exatamente qual projeto e arquivo restaurar.

---

## 🚀 Configuração Passo a Passo

### 1. Instalar o rclone

Certifique-se de que o rclone está instalado no servidor:

```bash
sudo apt install rclone  # Debian/Ubuntu
```

### 2. Configurar o Remote com Pasta Específica

Para garantir que os arquivos caiam exatamente na pasta desejada, siga estes passos:

1. No terminal, execute: `rclone config`
2. Digite `n` para um novo remote e nomeie como `douglas`.
3. Escolha o tipo `drive` (Google Drive).
4. Deixe `client_id` e `client_secret` em branco.
5. No escopo (`scope`), escolha `1` (Full access).
6. **Importante:** Quando perguntar `root_folder_id`, cole o ID da sua pasta.
7. Em `service_account_file`, deixe em branco.
8. Em `Edit advanced config`, digite `n`.
9. Em `Use auto config`, digite `y` se estiver no seu PC local ou `n` se estiver num servidor remoto (via SSH).
10. Confirme se está tudo certo com `y`.

### 3. Configurar o arquivo `backup.env`

Edite o arquivo `backup.env` na mesma pasta do script para definir:

- `BACKUP_ROOT`: Onde estão seus backups locais.
- `RCLONE_REMOTE`: O nome que você configurou (ex: `douglas:`).
- `DRIVE_DESTINATION`: Nome da subpasta no Drive.
- `RETENTION_DAYS`: Retenção no servidor local.
- `REMOTE_RETENTION_DAYS`: Retenção na nuvem.
- `REMOTE_CLEANUP_SAFETY_DAYS`: Janela de segurança para limpeza remota.

---

## 📅 Agendamento (Cron)

Para automatizar o sistema, recomendamos agendar o Upload e a Limpeza em horários distintos.

Edite seu crontab:

```bash
crontab -e
```

Adicione as linhas abaixo (ajuste os caminhos conforme sua instalação):

```bash
# 1. Sincronizar backups para a nuvem (Todos os dias às 03:00)
0 3 * * * /opt/backup/uploadBackup.sh >> /opt/backup/sync.log 2>&1

# 2. Limpar backups antigos na nuvem (Todos os domingos às 05:00)
0 5 * * 0 /opt/backup/cleanRemoteBackups.sh >> /opt/backup/sync.log 2>&1
```

---

## 📋 Comandos Úteis

- **Rodar upload com barra de progresso:**

  ```bash
  ./uploadBackup.sh -p -v
  ```

- **Restaurar um backup interativamente:**

  ```bash
  ./restoreBackup.sh -p -v
  ```

- **Simular limpeza na nuvem (ver o que seria apagado):**

  ```bash
  ./cleanRemoteBackups.sh -d -v
  ```

- **Verificar os logs:**
  ```bash
  tail -f sync.log
  ```

---

## 🔒 Segurança

O script possui uma lista de exclusão para não mexer em pastas administrativas como `scripts`, `logs`, `config`, etc. Você pode guardar os scripts dentro de `/opt/backups/scripts/` com segurança.
