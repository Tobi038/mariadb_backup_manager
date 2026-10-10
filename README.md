# MariaDB Backup Manager

Gerenciador de backups e restauração de bancos MariaDB para Windows, com menu interativo em português. Permite selecionar bancos diretamente no servidor, exportar arquivos SQL e restaurá-los em um banco existente ou novo.

## Funcionalidades

- Testar a conexão e consultar a versão do servidor.
- Listar bancos de usuário com charset e collation; bancos internos ficam ocultos.
- Fazer backup de um banco ou de todos os bancos de usuário, em arquivos separados.
- Incluir tabelas, dados, triggers, rotinas e eventos nos backups.
- Listar backups por data, com nome e tamanho.
- Importar SQL da pasta de backups ou de outro caminho.
- Criar um banco novo antes da importação.
- Restaurar um banco existente com backup de segurança obrigatório antes de removê-lo.

## Requisitos

- Windows com Windows PowerShell 5.1.
- Cliente MariaDB instalado: `mariadb.exe` e `mariadb-dump.exe`. O script também procura os nomes alternativos `mysql.exe` e `mysqldump.exe`.
- Acesso a um servidor MariaDB e um usuário com permissões para as operações escolhidas. Exportar rotinas/eventos e criar ou remover bancos podem exigir privilégios adicionais.

## Instalação e configuração

1. Baixe o projeto ou clone o repositório.
2. Copie `config.example.txt` para `config.txt`.
3. Ajuste o caminho dos clientes, servidor, porta, usuário e senha.
4. Execute `iniciar.bat` e use a opção **Testar conexão**.

```ini
MARIADB_BIN=C:\Program Files\MariaDB 10.5\bin
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=backup_user
DB_PASSWORD=COLOQUE_SUA_SENHA_AQUI
BACKUP_DIR=backups
```

Substitua a senha de exemplo antes de executar. `BACKUP_DIR` aceita um caminho absoluto ou relativo à pasta do programa. A pasta é criada automaticamente. Não é necessário configurar `DB_NAME`: o banco é escolhido pelo menu.

## Menu

| Opção | Operação |
| --- | --- |
| 1 | Testar conexão |
| 2 | Listar bancos de dados |
| 3 | Fazer backup de um banco ou de todos os bancos de usuário |
| 4 | Carregar ou restaurar um arquivo SQL |
| 5 | Listar backups |
| 0 | Sair |

O backup de todos os bancos exige digitar `BACKUP`. Cada banco gera um arquivo como `meu_banco_2026-10-10_15-30-00.sql`; falhas individuais aparecem no resumo da operação.

## Restauração

**Banco novo:** o programa solicita o nome e a confirmação `RESTAURAR`, cria o banco com `utf8mb4` / `utf8mb4_unicode_ci` e importa o SQL.

**Restauração limpa de um banco existente:** após a confirmação `RESTAURAR`, cria um arquivo `pre_restore_*.sql`, remove o banco, recria-o e importa o arquivo escolhido. Se o backup de segurança falhar, o banco não é removido. O charset e a collation atuais são preservados quando identificados; caso contrário, utiliza os valores padrão.

**Importação sobre um banco existente:** exige a confirmação `IMPORTAR` e executa o SQL sem remover previamente o banco. O próprio arquivo pode substituir tabelas; tabelas ausentes no SQL podem permanecer.

Se uma importação falhar, o banco pode ficar parcialmente restaurado. Na restauração limpa, o backup de segurança permanece disponível, mas não há recuperação automática.

## Como o código funciona

O arquivo `iniciar.bat` abre o script com o Windows PowerShell. `mariadb_manager.ps1` carrega a configuração, localiza os executáveis, resolve a pasta de backups e inicia o menu.

| Parte do script | Responsabilidade |
| --- | --- |
| `Load-Config` | Lê os pares `CHAVE=VALOR` e verifica os campos obrigatórios. |
| `Get-MariaDbTools` | Localiza os clientes e os executáveis de dump. |
| `Invoke-MariaDbQuery` | Executa consultas pelo cliente, verifica o código de saída e limpa a senha temporária. |
| `Get-UserDatabases` / `Show-Databases` | Consultam `INFORMATION_SCHEMA` e filtram bancos internos. |
| `New-DatabaseBackup` | Executa o dump com `--single-transaction`, `--quick`, rotinas, eventos, triggers e dados binários. |
| `Select-SqlFile` / `Select-RestoreTargetDatabase` | Recebem a origem do SQL e o banco de destino. |
| `Import-SqlFile` | Coordena confirmações, backup de segurança e criação ou recriação do banco. |
| `Invoke-SqlImport` | Envia o arquivo SQL para a entrada padrão do cliente MariaDB. |

Os identificadores SQL recebem escape de crases; nomes de novos bancos aceitam letras, números, `_` e `-`. A senha é passada aos processos pela variável de ambiente `MYSQL_PWD`, removida nos blocos `finally`, sem colocá-la nos argumentos da linha de comando.

## Cuidados e limitações

- `config.txt` guarda a senha em texto simples. Restrinja o acesso ao arquivo e use um usuário com as permissões necessárias.
- `config.txt`, backups e arquivos SQL são ignorados pelo Git. Este repositório contém apenas um modelo sem credenciais reais.
- Importe apenas arquivos SQL confiáveis: o cliente executa os comandos presentes no arquivo, inclusive eventuais `USE`, `DROP` e `CREATE`.
- `--single-transaction` favorece consistência em tabelas transacionais como InnoDB. Não garante um snapshot consistente de tabelas não transacionais nem protege contra alterações simultâneas de estrutura.
- Os bancos são exportados separadamente; o conjunto não representa um único snapshot sincronizado entre bancos.
- O programa não implementa agendamento, criptografia, compressão ou política de retenção.
- Faça uma restauração de teste em ambiente separado antes de depender dos backups em produção.

## Arquivos

```text
mariadb_backup_manager/
├── iniciar.bat
├── mariadb_manager.ps1
├── config.example.txt
├── .gitignore
└── README.md
```

`config.txt` e `backups/` são locais e não devem ser publicados.

## Validação

A sintaxe do script foi verificada com o parser do PowerShell. Esta publicação não executou backups ou restaurações contra um servidor MariaDB real.
