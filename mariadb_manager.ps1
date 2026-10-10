$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$FallbackCharset = 'utf8mb4'
$FallbackCollation = 'utf8mb4_unicode_ci'

function Write-Title {
    Clear-Host
    Write-Host '============================================================'
    Write-Host '              MariaDB Multi-Database Manager'
    Write-Host '============================================================'
    Write-Host
}

function Pause-Script {
    Write-Host
    [void](Read-Host 'Pressione ENTER para continuar')
}

function Load-Config {
    $configPath = Join-Path $PSScriptRoot 'config.txt'

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Arquivo config.txt nao encontrado em: $configPath"
    }

    $cfg = @{}

    foreach ($rawLine in Get-Content -LiteralPath $configPath -Encoding UTF8) {
        $line = $rawLine.Trim()

        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        $parts = $line -split '=', 2
        if ($parts.Count -ne 2) {
            continue
        }

        $cfg[$parts[0].Trim()] = $parts[1].Trim()
    }

    $required = @(
        'MARIADB_BIN',
        'DB_HOST',
        'DB_PORT',
        'DB_USER',
        'DB_PASSWORD',
        'BACKUP_DIR'
    )

    foreach ($key in $required) {
        if (-not $cfg.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($cfg[$key])) {
            throw "Configuracao obrigatoria ausente: $key"
        }
    }

    if ($cfg['DB_PASSWORD'] -eq 'COLOQUE_SUA_SENHA_AQUI') {
        throw 'Edite o config.txt e informe a senha do MariaDB antes de executar.'
    }

    return $cfg
}

function Resolve-BackupDirectory {
    param([hashtable]$Config)

    $configuredPath = $Config['BACKUP_DIR']

    if ([System.IO.Path]::IsPathRooted($configuredPath)) {
        $path = $configuredPath
    }
    else {
        $path = Join-Path $PSScriptRoot $configuredPath
    }

    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    return (Resolve-Path -LiteralPath $path).Path
}

function Get-MariaDbTools {
    param([hashtable]$Config)

    $bin = $Config['MARIADB_BIN']
    $client = Join-Path $bin 'mariadb.exe'

    if (-not (Test-Path -LiteralPath $client)) {
        $client = Join-Path $bin 'mysql.exe'
    }

    if (-not (Test-Path -LiteralPath $client)) {
        throw "Cliente mariadb.exe/mysql.exe nao encontrado em: $bin"
    }

    $dump = Join-Path $bin 'mariadb-dump.exe'
    if (-not (Test-Path -LiteralPath $dump)) {
        $dump = Join-Path $bin 'mysqldump.exe'
    }

    if (-not (Test-Path -LiteralPath $dump)) {
        throw "mariadb-dump.exe/mysqldump.exe nao encontrado em: $bin"
    }

    return @{
        Client = $client
        Dump   = $dump
    }
}

function Set-TemporaryPassword {
    param([hashtable]$Config)
    $env:MYSQL_PWD = $Config['DB_PASSWORD']
}

function Clear-TemporaryPassword {
    Remove-Item Env:MYSQL_PWD -ErrorAction SilentlyContinue
}

function ConvertTo-SqlLiteral {
    param([string]$Value)
    return "'$(($Value).Replace("'", "''"))'"
}

function ConvertTo-SqlIdentifier {
    param([string]$Value)
    $escaped = $Value.Replace('`', '``')
    return ('`{0}`' -f $escaped)
}

function Invoke-MariaDbQuery {
    param(
        [hashtable]$Config,
        [hashtable]$Tools,
        [string]$Query,
        [string]$Database = ''
    )

    Set-TemporaryPassword $Config

    try {
        $args = @(
            "--host=$($Config['DB_HOST'])",
            "--port=$($Config['DB_PORT'])",
            "--user=$($Config['DB_USER'])",
            '--protocol=tcp',
            '--batch',
            '--skip-column-names',
            '--default-character-set=utf8mb4',
            '-e',
            $Query
        )

        if (-not [string]::IsNullOrWhiteSpace($Database)) {
            $args += $Database
        }

        $output = & $Tools.Client @args 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw ($output -join [Environment]::NewLine)
        }

        return @($output)
    }
    finally {
        Clear-TemporaryPassword
    }
}

function Get-UserDatabases {
    param(
        [hashtable]$Config,
        [hashtable]$Tools
    )

    $query = "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys') ORDER BY SCHEMA_NAME;"
    $result = @(Invoke-MariaDbQuery -Config $Config -Tools $Tools -Query $query)

    return @(
        $result |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Show-Databases {
    param(
        [hashtable]$Config,
        [hashtable]$Tools
    )

    $query = "SELECT CONCAT(SCHEMA_NAME, '|', DEFAULT_CHARACTER_SET_NAME, '|', DEFAULT_COLLATION_NAME) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys') ORDER BY SCHEMA_NAME;"
    $rows = @(Invoke-MariaDbQuery -Config $Config -Tools $Tools -Query $query)

    if ($rows.Count -eq 0) {
        Write-Host 'Nenhum banco de usuario encontrado.'
        return
    }

    Write-Host 'Bancos de dados disponiveis:'
    Write-Host

    for ($i = 0; $i -lt $rows.Count; $i++) {
        $parts = $rows[$i].ToString().Trim() -split '\|', 3

        if ($parts.Count -eq 3) {
            Write-Host ('[{0}] {1}' -f ($i + 1), $parts[0])
            Write-Host ('    Charset: {0} | Collation: {1}' -f $parts[1], $parts[2])
        }
        else {
            Write-Host ('[{0}] {1}' -f ($i + 1), $rows[$i].ToString().Trim())
        }
    }

    Write-Host
    Write-Host 'Obs.: bancos internos do MariaDB ficam ocultos por seguranca.'
}

function Select-ExistingDatabase {
    param(
        [hashtable]$Config,
        [hashtable]$Tools,
        [string]$Prompt = 'Selecione o banco'
    )

    $databases = @(Get-UserDatabases -Config $Config -Tools $Tools)

    if ($databases.Count -eq 0) {
        Write-Host 'Nenhum banco de usuario encontrado.'
        return $null
    }

    for ($i = 0; $i -lt $databases.Count; $i++) {
        Write-Host ('[{0}] {1}' -f ($i + 1), $databases[$i])
    }

    Write-Host '[0] Cancelar'
    Write-Host

    $selection = Read-Host $Prompt
    $index = 0

    if (-not [int]::TryParse($selection, [ref]$index)) {
        Write-Host 'Selecao invalida.'
        return $null
    }

    if ($index -eq 0) {
        return $null
    }

    if ($index -lt 1 -or $index -gt $databases.Count) {
        Write-Host 'Selecao invalida.'
        return $null
    }

    return $databases[$index - 1]
}

function Select-RestoreTargetDatabase {
    param(
        [hashtable]$Config,
        [hashtable]$Tools
    )

    $databases = @(Get-UserDatabases -Config $Config -Tools $Tools)

    Write-Host 'Escolha o banco de destino:'
    Write-Host

    for ($i = 0; $i -lt $databases.Count; $i++) {
        Write-Host ('[{0}] {1}' -f ($i + 1), $databases[$i])
    }

    $newOption = $databases.Count + 1
    Write-Host ('[{0}] Criar um novo banco' -f $newOption)
    Write-Host '[0] Cancelar'
    Write-Host

    $selection = Read-Host 'Opcao'
    $index = 0

    if (-not [int]::TryParse($selection, [ref]$index)) {
        Write-Host 'Selecao invalida.'
        return $null
    }

    if ($index -eq 0) {
        return $null
    }

    if ($index -ge 1 -and $index -le $databases.Count) {
        return @{
            Name   = $databases[$index - 1]
            Exists = $true
        }
    }

    if ($index -eq $newOption) {
        Write-Host
        $name = (Read-Host 'Nome do novo banco').Trim()

        if ([string]::IsNullOrWhiteSpace($name)) {
            Write-Host 'Nome do banco nao pode ficar vazio.'
            return $null
        }

        # Mantem nomes simples e seguros para evitar erros de shell/SQL.
        if ($name -notmatch '^[A-Za-z0-9_-]+$') {
            Write-Host 'Nome invalido. Use apenas letras, numeros, _ e -.'
            return $null
        }

        $exists = Test-DatabaseExists -Config $Config -Tools $Tools -Database $name

        return @{
            Name   = $name
            Exists = $exists
        }
    }

    Write-Host 'Selecao invalida.'
    return $null
}

function Test-DatabaseExists {
    param(
        [hashtable]$Config,
        [hashtable]$Tools,
        [string]$Database
    )

    $dbLiteral = ConvertTo-SqlLiteral $Database
    $result = @(Invoke-MariaDbQuery -Config $Config -Tools $Tools -Query "SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = $dbLiteral;")

    if ($result.Count -eq 0) {
        return $false
    }

    return (($result[0].ToString().Trim()) -eq '1')
}

function Get-DatabaseDefinition {
    param(
        [hashtable]$Config,
        [hashtable]$Tools,
        [string]$Database
    )

    $dbLiteral = ConvertTo-SqlLiteral $Database
    $query = "SELECT CONCAT(DEFAULT_CHARACTER_SET_NAME, '|', DEFAULT_COLLATION_NAME) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = $dbLiteral LIMIT 1;"
    $result = @(Invoke-MariaDbQuery -Config $Config -Tools $Tools -Query $query)

    if ($result.Count -eq 0) {
        return $null
    }

    $line = $result[0].ToString().Trim()
    $parts = $line -split '\|', 2

    if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        return $null
    }

    return @{
        Charset   = $parts[0].Trim()
        Collation = $parts[1].Trim()
    }
}

function New-EmptyDatabase {
    param(
        [hashtable]$Config,
        [hashtable]$Tools,
        [string]$Database,
        [string]$Charset = 'utf8mb4',
        [string]$Collation = 'utf8mb4_unicode_ci'
    )

    if ($Charset -notmatch '^[A-Za-z0-9_]+$' -or $Collation -notmatch '^[A-Za-z0-9_]+$') {
        throw 'Charset/collation invalido retornado pelo servidor.'
    }

    $dbIdentifier = ConvertTo-SqlIdentifier $Database
    $query = "CREATE DATABASE $dbIdentifier CHARACTER SET $Charset COLLATE $Collation;"
    [void](Invoke-MariaDbQuery -Config $Config -Tools $Tools -Query $query)
}

function Invoke-ConnectionTest {
    param(
        [hashtable]$Config,
        [hashtable]$Tools
    )

    Write-Host 'Testando conexao com o servidor...'
    $output = @(Invoke-MariaDbQuery -Config $Config -Tools $Tools -Query "SELECT CONCAT('MariaDB ', VERSION(), ' | Servidor: ', @@hostname);")

    Write-Host
    Write-Host 'Conexao realizada com sucesso.'
    Write-Host ($output -join [Environment]::NewLine)

    $databases = @(Get-UserDatabases -Config $Config -Tools $Tools)
    Write-Host "Bancos de usuario encontrados: $($databases.Count)"
}

function New-DatabaseBackup {
    param(
        [hashtable]$Config,
        [hashtable]$Tools,
        [string]$BackupDirectory,
        [string]$Database,
        [string]$Prefix = ''
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $safeDbName = $Database -replace '[^a-zA-Z0-9_.-]', '_'

    if ([string]::IsNullOrWhiteSpace($Prefix)) {
        $fileName = "${safeDbName}_${timestamp}.sql"
    }
    else {
        $safePrefix = $Prefix -replace '[^a-zA-Z0-9_.-]', '_'
        $fileName = "${safePrefix}_${safeDbName}_${timestamp}.sql"
    }

    $backupFile = Join-Path $BackupDirectory $fileName

    Write-Host "Gerando backup de '$Database'..."
    Set-TemporaryPassword $Config

    try {
        $args = @(
            "--host=$($Config['DB_HOST'])",
            "--port=$($Config['DB_PORT'])",
            "--user=$($Config['DB_USER'])",
            '--protocol=tcp',
            '--default-character-set=utf8mb4',
            '--single-transaction',
            '--quick',
            '--routines',
            '--events',
            '--triggers',
            '--hex-blob',
            '--add-drop-table',
            "--result-file=$backupFile",
            $Database
        )

        $output = & $Tools.Dump @args 2>&1

        if ($LASTEXITCODE -ne 0) {
            if (Test-Path -LiteralPath $backupFile) {
                Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
            }
            throw ($output -join [Environment]::NewLine)
        }

        $sizeMb = [math]::Round((Get-Item -LiteralPath $backupFile).Length / 1MB, 2)

        Write-Host 'Backup concluido com sucesso.'
        Write-Host "Arquivo: $backupFile"
        Write-Host "Tamanho: $sizeMb MB"

        return $backupFile
    }
    finally {
        Clear-TemporaryPassword
    }
}

function Start-BackupMenu {
    param(
        [hashtable]$Config,
        [hashtable]$Tools,
        [string]$BackupDirectory
    )

    Write-Host 'Como deseja fazer o backup?'
    Write-Host
    Write-Host '[1] Selecionar um banco'
    Write-Host '[2] Fazer backup de todos os bancos de usuario'
    Write-Host '[0] Cancelar'
    Write-Host

    $option = Read-Host 'Opcao'

    switch ($option) {
        '1' {
            Write-Host
            $database = Select-ExistingDatabase -Config $Config -Tools $Tools -Prompt 'Numero do banco'

            if ([string]::IsNullOrWhiteSpace($database)) {
                Write-Host 'Operacao cancelada.'
                return
            }

            Write-Host
            [void](New-DatabaseBackup -Config $Config -Tools $Tools -BackupDirectory $BackupDirectory -Database $database)
        }
        '2' {
            $databases = @(Get-UserDatabases -Config $Config -Tools $Tools)

            if ($databases.Count -eq 0) {
                Write-Host 'Nenhum banco de usuario encontrado.'
                return
            }

            Write-Host
            Write-Host "Sera criado um arquivo .sql para cada um dos $($databases.Count) bancos encontrados."
            $confirmation = Read-Host 'Digite BACKUP para continuar'

            if ($confirmation -cne 'BACKUP') {
                Write-Host 'Operacao cancelada.'
                return
            }

            $success = 0
            $failed = @()

            foreach ($database in $databases) {
                Write-Host
                try {
                    [void](New-DatabaseBackup -Config $Config -Tools $Tools -BackupDirectory $BackupDirectory -Database $database)
                    $success++
                }
                catch {
                    Write-Host "ERRO no banco '$database': $($_.Exception.Message)"
                    $failed += $database
                }
            }

            Write-Host
            Write-Host "Backups concluidos: $success de $($databases.Count)."

            if ($failed.Count -gt 0) {
                Write-Host "Falharam: $($failed -join ', ')"
            }
        }
        default {
            Write-Host 'Operacao cancelada.'
        }
    }
}

function Get-BackupFiles {
    param([string]$BackupDirectory)

    return @(
        Get-ChildItem -LiteralPath $BackupDirectory -Filter '*.sql' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    )
}

function Show-Backups {
    param([string]$BackupDirectory)

    $files = Get-BackupFiles $BackupDirectory

    if ($files.Count -eq 0) {
        Write-Host 'Nenhum arquivo .sql encontrado na pasta de backups.'
        return
    }

    Write-Host 'Backups disponiveis:'
    Write-Host

    for ($i = 0; $i -lt $files.Count; $i++) {
        $sizeMb = [math]::Round($files[$i].Length / 1MB, 2)
        Write-Host ('[{0}] {1}  ({2} MB)  {3}' -f ($i + 1), $files[$i].Name, $sizeMb, $files[$i].LastWriteTime.ToString('dd/MM/yyyy HH:mm:ss'))
    }
}

function Select-SqlFile {
    param([string]$BackupDirectory)

    $files = Get-BackupFiles $BackupDirectory

    Write-Host 'Escolha a origem do SQL:'
    Write-Host '  [1] Selecionar um backup da pasta de backups'
    Write-Host '  [2] Informar o caminho de outro arquivo .sql'
    Write-Host '  [0] Cancelar'
    Write-Host

    $sourceOption = Read-Host 'Opcao'

    switch ($sourceOption) {
        '1' {
            if ($files.Count -eq 0) {
                Write-Host 'Nenhum backup encontrado.'
                return $null
            }

            Write-Host
            for ($i = 0; $i -lt $files.Count; $i++) {
                $sizeMb = [math]::Round($files[$i].Length / 1MB, 2)
                Write-Host ('[{0}] {1} ({2} MB)' -f ($i + 1), $files[$i].Name, $sizeMb)
            }

            Write-Host
            $selection = Read-Host 'Numero do backup'
            $index = 0

            if (-not [int]::TryParse($selection, [ref]$index)) {
                Write-Host 'Selecao invalida.'
                return $null
            }

            if ($index -lt 1 -or $index -gt $files.Count) {
                Write-Host 'Selecao invalida.'
                return $null
            }

            return $files[$index - 1].FullName
        }
        '2' {
            $path = Read-Host 'Caminho completo do arquivo .sql'
            $path = $path.Trim().Trim('"')

            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Write-Host 'Arquivo nao encontrado.'
                return $null
            }

            if ([System.IO.Path]::GetExtension($path) -ine '.sql') {
                Write-Host 'O arquivo selecionado nao possui extensao .sql.'
                return $null
            }

            return (Resolve-Path -LiteralPath $path).Path
        }
        default {
            return $null
        }
    }
}

function Invoke-SqlImport {
    param(
        [hashtable]$Config,
        [hashtable]$Tools,
        [string]$SqlFile,
        [string]$Database
    )

    Set-TemporaryPassword $Config

    try {
        $argumentList = @(
            "--host=$($Config['DB_HOST'])",
            "--port=$($Config['DB_PORT'])",
            "--user=$($Config['DB_USER'])",
            '--protocol=tcp',
            '--default-character-set=utf8mb4',
            $Database
        )

        $process = Start-Process `
            -FilePath $Tools.Client `
            -ArgumentList $argumentList `
            -RedirectStandardInput $SqlFile `
            -NoNewWindow `
            -Wait `
            -PassThru

        if ($process.ExitCode -ne 0) {
            throw "O cliente MariaDB encerrou com codigo $($process.ExitCode)."
        }
    }
    finally {
        Clear-TemporaryPassword
    }
}

function Import-SqlFile {
    param(
        [hashtable]$Config,
        [hashtable]$Tools,
        [string]$BackupDirectory
    )

    $sqlFile = Select-SqlFile $BackupDirectory
    if ([string]::IsNullOrWhiteSpace($sqlFile)) {
        Write-Host 'Operacao cancelada.'
        return
    }

    Write-Host
    $target = Select-RestoreTargetDatabase -Config $Config -Tools $Tools

    if ($null -eq $target) {
        Write-Host 'Operacao cancelada.'
        return
    }

    $database = $target.Name
    $databaseExists = [bool]$target.Exists

    Write-Host
    Write-Host '============================================================'
    Write-Host '                  RESTAURAR BANCO DE DADOS'
    Write-Host '============================================================'
    Write-Host
    Write-Host "Banco de destino: $database"
    Write-Host "Arquivo:          $sqlFile"
    Write-Host

    if (-not $databaseExists) {
        Write-Host "O banco '$database' nao existe."
        Write-Host 'Ele sera criado automaticamente e o SQL sera importado.'
        Write-Host "Charset padrao:   $FallbackCharset"
        Write-Host "Collation padrao: $FallbackCollation"
        Write-Host

        $confirmation = Read-Host 'Digite RESTAURAR para continuar'
        if ($confirmation -cne 'RESTAURAR') {
            Write-Host 'Restauracao cancelada.'
            return
        }

        Write-Host
        Write-Host '[1/2] Criando banco vazio...'
        New-EmptyDatabase -Config $Config -Tools $Tools -Database $database -Charset $FallbackCharset -Collation $FallbackCollation
        Write-Host 'OK'

        Write-Host '[2/2] Importando backup...'
        try {
            Invoke-SqlImport -Config $Config -Tools $Tools -SqlFile $sqlFile -Database $database
        }
        catch {
            Write-Host
            Write-Host "ERRO: o banco '$database' foi criado, mas a importacao nao foi concluida."
            throw
        }
        Write-Host 'OK'
        Write-Host
        Write-Host 'Restauracao concluida com sucesso.'
        return
    }

    Write-Host "O banco '$database' ja existe."
    Write-Host
    Write-Host 'Como deseja continuar?'
    Write-Host
    Write-Host '[1] Restauracao limpa (RECOMENDADO)'
    Write-Host '    Cria backup de seguranca, apaga o banco atual,'
    Write-Host '    recria o banco vazio e importa o arquivo SQL.'
    Write-Host
    Write-Host '[2] Importar sobre o banco atual'
    Write-Host '    Nao remove tabelas que nao estejam no backup.'
    Write-Host
    Write-Host '[0] Cancelar'
    Write-Host

    $restoreMode = Read-Host 'Opcao'

    switch ($restoreMode) {
        '1' {
            $databaseDefinition = Get-DatabaseDefinition -Config $Config -Tools $Tools -Database $database
            if ($null -eq $databaseDefinition) {
                $databaseDefinition = @{
                    Charset   = $FallbackCharset
                    Collation = $FallbackCollation
                }

                Write-Host
                Write-Host 'AVISO: nao foi possivel identificar charset/collation do banco atual.'
                Write-Host "Sera usado: $FallbackCharset / $FallbackCollation."
            }

            Write-Host
            Write-Host 'ATENCAO: RESTAURACAO LIMPA'
            Write-Host 'Antes de apagar o banco, sera criado OBRIGATORIAMENTE um'
            Write-Host 'backup de seguranca do estado atual.'
            Write-Host
            Write-Host "Charset atual:   $($databaseDefinition.Charset)"
            Write-Host "Collation atual: $($databaseDefinition.Collation)"
            Write-Host

            $confirmation = Read-Host 'Digite RESTAURAR para confirmar'
            if ($confirmation -cne 'RESTAURAR') {
                Write-Host 'Restauracao cancelada.'
                return
            }

            Write-Host
            Write-Host '[1/4] Criando backup de seguranca...'
            try {
                $safetyBackup = New-DatabaseBackup -Config $Config -Tools $Tools -BackupDirectory $BackupDirectory -Database $database -Prefix 'pre_restore'
            }
            catch {
                Write-Host
                Write-Host "Falha ao criar backup de seguranca: $($_.Exception.Message)"
                Write-Host 'O banco atual NAO foi apagado. Restauracao cancelada.'
                return
            }
            Write-Host 'OK'
            Write-Host "Backup de seguranca: $safetyBackup"

            Write-Host '[2/4] Removendo banco atual...'
            $dbIdentifier = ConvertTo-SqlIdentifier $database
            [void](Invoke-MariaDbQuery -Config $Config -Tools $Tools -Query "DROP DATABASE $dbIdentifier;")
            Write-Host 'OK'

            Write-Host '[3/4] Criando banco vazio...'
            New-EmptyDatabase -Config $Config -Tools $Tools -Database $database -Charset $databaseDefinition.Charset -Collation $databaseDefinition.Collation
            Write-Host 'OK'

            Write-Host '[4/4] Importando backup...'
            try {
                Invoke-SqlImport -Config $Config -Tools $Tools -SqlFile $sqlFile -Database $database
            }
            catch {
                Write-Host
                Write-Host 'ERRO DURANTE A IMPORTACAO.'
                Write-Host "O backup de seguranca foi preservado em: $safetyBackup"
                throw
            }
            Write-Host 'OK'
            Write-Host
            Write-Host 'Restauracao limpa concluida com sucesso.'
            Write-Host "Banco restaurado: $database"
        }
        '2' {
            Write-Host
            Write-Host 'ATENCAO: o SQL sera importado sobre o banco atual.'
            Write-Host 'Tabelas que nao existirem no arquivo SQL poderao permanecer no banco.'
            Write-Host

            $confirmation = Read-Host 'Digite IMPORTAR para confirmar'
            if ($confirmation -cne 'IMPORTAR') {
                Write-Host 'Importacao cancelada.'
                return
            }

            Write-Host
            Write-Host 'Importando SQL sobre o banco atual...'
            Invoke-SqlImport -Config $Config -Tools $Tools -SqlFile $sqlFile -Database $database
            Write-Host
            Write-Host 'Importacao concluida com sucesso.'
        }
        default {
            Write-Host 'Operacao cancelada.'
        }
    }
}

try {
    $config = Load-Config
    $tools = Get-MariaDbTools -Config $config
    $backupDirectory = Resolve-BackupDirectory -Config $config
}
catch {
    Write-Title
    Write-Host 'ERRO DE CONFIGURACAO:'
    Write-Host $_.Exception.Message
    Pause-Script
    exit 1
}

while ($true) {
    Write-Title
    Write-Host "Servidor:          $($config['DB_HOST']):$($config['DB_PORT'])"
    Write-Host "Usuario:           $($config['DB_USER'])"
    Write-Host 'Banco configurado: nenhum - selecao feita pelo menu'
    Write-Host "Pasta de backups:  $backupDirectory"
    Write-Host
    Write-Host '[1] Testar conexao'
    Write-Host '[2] Listar bancos de dados'
    Write-Host '[3] Fazer backup (.sql)'
    Write-Host '[4] Carregar / restaurar arquivo .sql'
    Write-Host '[5] Listar backups'
    Write-Host '[0] Sair'
    Write-Host

    $option = Read-Host 'Escolha uma opcao'

    try {
        switch ($option) {
            '1' {
                Write-Title
                Invoke-ConnectionTest -Config $config -Tools $tools
                Pause-Script
            }
            '2' {
                Write-Title
                Show-Databases -Config $config -Tools $tools
                Pause-Script
            }
            '3' {
                Write-Title
                Start-BackupMenu -Config $config -Tools $tools -BackupDirectory $backupDirectory
                Pause-Script
            }
            '4' {
                Write-Title
                Import-SqlFile -Config $config -Tools $tools -BackupDirectory $backupDirectory
                Pause-Script
            }
            '5' {
                Write-Title
                Show-Backups -BackupDirectory $backupDirectory
                Pause-Script
            }
            '0' {
                Clear-TemporaryPassword
                exit 0
            }
            default {
                Write-Host 'Opcao invalida.'
                Start-Sleep -Seconds 1
            }
        }
    }
    catch {
        Clear-TemporaryPassword
        Write-Host
        Write-Host 'ERRO:'
        Write-Host $_.Exception.Message
        Pause-Script
    }
}
