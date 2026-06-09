local RESOURCE = GetCurrentResourceName()
local RESOURCE_PATH = GetResourcePath(RESOURCE)
local SQL_DIR = RESOURCE_PATH .. '/sql'
local BACKUP_INDEX_PATH = SQL_DIR .. '/backup-index.json'

local state = {
    running = false,
    lastScheduleKey = nil
}

local function log(message)
    print(('[%s] %s'):format(RESOURCE, tostring(message)))
end

local function warn(message)
    print(('^3[%s] %s^7'):format(RESOURCE, tostring(message)))
end

local function fail(message)
    print(('^1[%s] %s^7'):format(RESOURCE, tostring(message)))
end

local function trim(value)
    return tostring(value or ''):match('^%s*(.-)%s*$') or ''
end

local function getString(name, fallback)
    local value = GetConvar(name, fallback or '')
    if value == nil then return fallback or '' end
    return trim(value)
end

local function getBool(name, fallback)
    local raw = GetConvar(name, fallback and '1' or '0')
    raw = tostring(raw or ''):lower():gsub('%s+', '')

    if raw == '1' or raw == 'true' or raw == 'yes' or raw == 'on' then return true end
    if raw == '0' or raw == 'false' or raw == 'no' or raw == 'off' then return false end

    return fallback == true
end

local function getBoolWithAliases(names, fallback)
    for _, name in ipairs(names) do
        local raw = GetConvar(name, '')
        if raw ~= nil and tostring(raw) ~= '' then
            return getBool(name, fallback)
        end
    end

    return fallback == true
end

local function getNumber(name, fallback)
    local value = tonumber(GetConvar(name, tostring(fallback)))
    if value == nil then return fallback end
    return value
end

local function parseNumberList(raw, minimum, maximum, fallback)
    raw = trim(raw or fallback or ''):lower():gsub('%s+', '')

    if raw == '' then
        raw = trim(fallback or ''):lower():gsub('%s+', '')
    end

    if raw == 'all' or raw == '*' then
        return 'all'
    end

    local output = {}
    local seen = {}

    for part in raw:gmatch('[^,]+') do
        local value = tonumber(part)
        if value and value >= minimum and value <= maximum and not seen[value] then
            seen[value] = true
            output[#output + 1] = value
        end
    end

    table.sort(output)
    return output
end

local function listContains(list, value)
    if list == 'all' then return true end
    if type(list) ~= 'table' then return false end

    for _, item in ipairs(list) do
        if item == value then return true end
    end

    return false
end

local function loadConfig()
    local database = getString('chase_db_database', '')
    if database == '' then
        database = getString('chase_db_name', '')
    end

    local colorRaw = getString('chase_db_color', '0')
    colorRaw = colorRaw:gsub('#', '')

    return {
        database = database,
        webhook = getString('chase_db_webhook', ''),
        username = getString('chase_db_username', 'Chase DB Backup'),
        footer = getString('chase_db_footer', 'Chase DB Backup'),
        color = tonumber(colorRaw, 16) or 0,

        runOnStart = getBool('chase_db_run_on_start', true),
        startupDelaySeconds = math.max(0, math.floor(getNumber('chase_db_startup_delay', 60))),
        checkIntervalMs = math.max(5000, math.floor(getNumber('chase_db_check_interval_ms', 15000))),

        keepLocal = getBool('chase_db_keep_local', false),
        keepLocalOnFail = getBool('chase_db_keep_local_on_fail', true),
        maxLocalBackups = math.max(0, math.floor(getNumber('chase_db_max_local_backups', 10))),
        maxDiscordBytes = math.max(1, math.floor(getNumber('chase_db_max_discord_bytes', 25000000))),

        includeDropTable = getBool('chase_db_drop_table', true),
        includeData = getBool('chase_db_include_data', true),
        chunkSize = math.max(50, math.floor(getNumber('chase_db_chunk_size', 500))),
        consoleLogs = getBoolWithAliases({ 'chase_db_console_logs', 'zbd_backup_console_logs' }, false),

        schedule = {
            days = parseNumberList(getString('chase_db_days', 'all'), 1, 31, 'all'),
            hours = parseNumberList(getString('chase_db_hours', 'all'), 0, 23, 'all'),
            minutes = parseNumberList(getString('chase_db_minutes', '0,30'), 0, 59, '0,30')
        }
    }
end

local function verbose(config, message)
    if config and config.consoleLogs then
        log(message)
    end
end

local function quoteIdentifier(value)
    return '`' .. tostring(value or ''):gsub('`', '``') .. '`'
end

local function quoteQualified(database, tableName)
    return quoteIdentifier(database) .. '.' .. quoteIdentifier(tableName)
end

local function escapeSqlString(value)
    local output = tostring(value)
    output = output:gsub('\\', '\\\\')
    output = output:gsub('\0', '\\0')
    output = output:gsub('\n', '\\n')
    output = output:gsub('\r', '\\r')
    output = output:gsub('\026', '\\Z')
    output = output:gsub("'", "''")
    return "'" .. output .. "'"
end

local function sqlValue(value)
    local valueType = type(value)

    if value == nil then
        return 'NULL'
    end

    if valueType == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then
            return 'NULL'
        end
        return tostring(value)
    end

    if valueType == 'boolean' then
        return value and '1' or '0'
    end

    if valueType == 'table' then
        return escapeSqlString(json.encode(value))
    end

    return escapeSqlString(value)
end

local function formatDateForFile(t)
    return ('%04d-%02d-%02d_%02d-%02d-%02d'):format(t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function formatRunKey(t)
    return ('%04d-%02d-%02d_%02d-%02d'):format(t.year, t.month, t.day, t.hour, t.min)
end

local function fileExists(path)
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close()
    return true
end

local function fileSize(path)
    local file = io.open(path, 'rb')
    if not file then return 0 end
    local size = file:seek('end') or 0
    file:close()
    return size
end

local function readFile(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local data = file:read('*a')
    file:close()
    return data
end

local function safeRemove(path)
    if not path or path == '' then return false end

    local ok, removeErr = os.remove(path)
    if not ok and removeErr then
        warn(('Could not remove `%s`: %s'):format(path, removeErr))
        return false
    end

    return true
end

local function formatBytes(bytes)
    bytes = tonumber(bytes) or 0

    if bytes >= 1073741824 then
        return ('%.2f GB'):format(bytes / 1073741824)
    end

    if bytes >= 1048576 then
        return ('%.2f MB'):format(bytes / 1048576)
    end

    if bytes >= 1024 then
        return ('%.2f KB'):format(bytes / 1024)
    end

    return ('%d bytes'):format(bytes)
end

local function loadBackupIndex()
    local raw = readFile(BACKUP_INDEX_PATH)
    if not raw or raw == '' then return {} end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        warn('backup-index.json is invalid. A clean index will be written on the next kept local backup.')
        return {}
    end

    return decoded
end

local function saveBackupIndex(index)
    local file = io.open(BACKUP_INDEX_PATH, 'wb')
    if not file then
        warn(('Could not write backup index. Make sure `%s` exists and is writable.'):format(SQL_DIR))
        return false
    end

    file:write(json.encode(index or {}))
    file:close()
    return true
end

local function trimBackupIndex(index)
    local kept = {}
    local seen = {}

    for _, entry in ipairs(index or {}) do
        if type(entry) == 'table' and entry.path and fileExists(entry.path) and not seen[entry.path] then
            seen[entry.path] = true
            kept[#kept + 1] = entry
        end
    end

    table.sort(kept, function(a, b)
        return tonumber(a.createdAt or 0) < tonumber(b.createdAt or 0)
    end)

    return kept
end

local function rememberLocalBackup(filePath, filename, database)
    local index = trimBackupIndex(loadBackupIndex())

    index[#index + 1] = {
        path = filePath,
        filename = filename,
        database = database,
        size = fileSize(filePath),
        createdAt = os.time()
    }

    saveBackupIndex(trimBackupIndex(index))
end

local function forgetLocalBackup(filePath)
    local index = trimBackupIndex(loadBackupIndex())
    local kept = {}

    for _, entry in ipairs(index) do
        if entry.path ~= filePath then
            kept[#kept + 1] = entry
        end
    end

    saveBackupIndex(kept)
end

local function pruneLocalBackups(config)
    local maxBackups = tonumber(config.maxLocalBackups) or 0
    if maxBackups <= 0 then return end

    local index = trimBackupIndex(loadBackupIndex())
    local removed = 0

    while #index > maxBackups do
        local entry = table.remove(index, 1)
        if entry and entry.path and safeRemove(entry.path) then
            removed = removed + 1
        end
    end

    saveBackupIndex(index)

    if removed > 0 then
        log(('Local backup rotation removed %s old backup(s). Limit: %s.'):format(removed, maxBackups))
    end
end

local function httpRequest(url, method, body, headers)
    local p = promise.new()

    PerformHttpRequest(url, function(statusCode, responseBody, responseHeaders)
        p:resolve({
            status = tonumber(statusCode) or 0,
            body = responseBody or '',
            headers = responseHeaders or {}
        })
    end, method or 'GET', body or '', headers or {})

    return Citizen.Await(p)
end

local function sendDiscordJson(config, payload)
    if not config.webhook or config.webhook == '' then
        return false, 'Webhook convar is empty.'
    end

    payload.username = payload.username or config.username

    local response = httpRequest(config.webhook, 'POST', json.encode(payload), {
        ['Content-Type'] = 'application/json'
    })

    if response.status >= 200 and response.status < 300 then
        return true
    end

    return false, ('Discord JSON request failed with HTTP %s: %s'):format(response.status, response.body)
end

local function sendDiscordFile(config, filePath, fileName, content)
    if not config.webhook or config.webhook == '' then
        return false, 'missing webhook'
    end

    local data = readFile(filePath)
    if not data then
        return false, 'could not read SQL file for upload'
    end

    local boundary = ('----ChaseDbBackup%s%s'):format(os.time(), math.random(100000, 999999))
    local payload = json.encode({
        username = config.username,
        content = content or '',
        embeds = {
            {
                title = 'Database Backup Complete',
                description = ('Attached file: `%s`'):format(fileName),
                color = config.color,
                footer = { text = config.footer }
            }
        }
    })

    local body = table.concat({
        '--' .. boundary,
        'Content-Disposition: form-data; name="payload_json"',
        'Content-Type: application/json',
        '',
        payload,
        '--' .. boundary,
        ('Content-Disposition: form-data; name="files[0]"; filename="%s"'):format(fileName),
        'Content-Type: application/sql',
        '',
        data,
        '--' .. boundary .. '--',
        ''
    }, '\r\n')

    local response = httpRequest(config.webhook, 'POST', body, {
        ['Content-Type'] = 'multipart/form-data; boundary=' .. boundary
    })

    if response.status >= 200 and response.status < 300 then
        return true
    end

    return false, ('Discord file upload failed with HTTP %s: %s'):format(response.status, response.body)
end

local function getActiveDatabase(config)
    if config.database and config.database ~= '' then
        return config.database
    end

    local database = MySQL.scalar.await('SELECT DATABASE()')
    if not database or database == '' then
        error('Unable to detect active database. Set chase_db_name "zombodia" in server.cfg.')
    end

    return tostring(database)
end

local function getCreateStatement(database, tableName)
    local rows = MySQL.query.await(('SHOW CREATE TABLE %s'):format(quoteQualified(database, tableName))) or {}
    local row = rows[1]
    if not row then return nil end

    for key, value in pairs(row) do
        if tostring(key):lower():find('create table', 1, true) then
            return tostring(value)
        end
    end

    return nil
end

local function getTables(database)
    local rows = MySQL.query.await([[
        SELECT TABLE_NAME, TABLE_TYPE
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = ? AND TABLE_TYPE = 'BASE TABLE'
        ORDER BY TABLE_NAME
    ]], { database }) or {}

    local tables = {}

    for _, row in ipairs(rows) do
        local name = row.TABLE_NAME or row.table_name
        if name and name ~= '' then
            tables[#tables + 1] = tostring(name)
        end
    end

    table.sort(tables)
    return tables
end

local function getColumns(database, tableName)
    local rows = MySQL.query.await([[
        SELECT COLUMN_NAME
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = ?
          AND TABLE_NAME = ?
          AND (EXTRA IS NULL OR EXTRA NOT LIKE '%GENERATED%')
        ORDER BY ORDINAL_POSITION
    ]], { database, tableName }) or {}

    local columns = {}

    for _, row in ipairs(rows) do
        local name = row.COLUMN_NAME or row.column_name
        if name and name ~= '' then
            columns[#columns + 1] = tostring(name)
        end
    end

    return columns
end

local function writeInsertRows(file, tableName, columns, rows)
    if #rows == 0 or #columns == 0 then return end

    local escapedColumns = {}
    for index, columnName in ipairs(columns) do
        escapedColumns[index] = quoteIdentifier(columnName)
    end

    file:write(('INSERT INTO %s (%s) VALUES\n'):format(quoteIdentifier(tableName), table.concat(escapedColumns, ', ')))

    for rowIndex, row in ipairs(rows) do
        local values = {}

        for columnIndex, columnName in ipairs(columns) do
            values[columnIndex] = sqlValue(row[columnName])
        end

        file:write('(' .. table.concat(values, ', ') .. ')')

        if rowIndex < #rows then
            file:write(',\n')
        else
            file:write(';\n')
        end
    end

    file:write('\n')
end

local function dumpTable(file, database, tableName, config)
    verbose(config, ('Dumping table `%s`.'):format(tableName))

    file:write('\n-- --------------------------------------------------------\n')
    file:write(('-- Table structure for `%s`\n'):format(tableName))
    file:write('-- --------------------------------------------------------\n\n')

    if config.includeDropTable then
        file:write(('DROP TABLE IF EXISTS %s;\n'):format(quoteIdentifier(tableName)))
    end

    local createStatement = getCreateStatement(database, tableName)
    if createStatement then
        file:write(createStatement .. ';\n\n')
    else
        warn(('Could not read CREATE TABLE statement for `%s`.'):format(tableName))
    end

    if not config.includeData then return end

    local countRow = MySQL.single.await(('SELECT COUNT(*) AS row_count FROM %s'):format(quoteQualified(database, tableName)))
    local rowCount = tonumber(countRow and (countRow.row_count or countRow.ROW_COUNT or countRow['COUNT(*)'])) or 0

    if rowCount <= 0 then return end

    local columns = getColumns(database, tableName)
    if #columns == 0 then
        warn(('Could not read column list for `%s`. Table data skipped.'):format(tableName))
        return
    end

    file:write(('-- Data for `%s` (%s rows)\n\n'):format(tableName, rowCount))

    local offset = 0
    local chunkSize = math.max(50, tonumber(config.chunkSize) or 500)

    while offset < rowCount do
        local sql = ('SELECT * FROM %s LIMIT %d OFFSET %d'):format(quoteQualified(database, tableName), chunkSize, offset)
        local rows = MySQL.query.await(sql) or {}

        if #rows == 0 then break end

        writeInsertRows(file, tableName, columns, rows)
        offset = offset + #rows
        Wait(0)
    end
end

local function buildBackup(config)
    local database = getActiveDatabase(config)
    local now = os.date('*t')
    local filename = ('%s-%s.sql'):format(database, formatDateForFile(now))
    local filePath = SQL_DIR .. '/' .. filename

    local file = io.open(filePath, 'wb')
    if not file then
        error(('Could not write backup file. Make sure this folder exists and is writable: %s'):format(SQL_DIR))
    end

    file:write('-- Chase DB Backup\n')
    file:write(('-- Resource: %s\n'):format(RESOURCE))
    file:write(('-- Database: %s\n'):format(database))
    file:write(('-- Created: %04d-%02d-%02d %02d:%02d:%02d server time\n\n'):format(now.year, now.month, now.day, now.hour, now.min, now.sec))
    file:write('SET FOREIGN_KEY_CHECKS=0;\n')
    file:write('SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";\n')
    file:write(('CREATE DATABASE IF NOT EXISTS %s;\n'):format(quoteIdentifier(database)))
    file:write(('USE %s;\n\n'):format(quoteIdentifier(database)))

    local tables = getTables(database)
    if #tables == 0 then
        file:close()
        safeRemove(filePath)
        error(('No base tables found for database `%s`.'):format(database))
    end

    for _, tableName in ipairs(tables) do
        dumpTable(file, database, tableName, config)
    end

    file:write('SET FOREIGN_KEY_CHECKS=1;\n')
    file:close()

    return filePath, filename, database, #tables
end

local function uploadBackup(config, filePath, filename, database, tableCount)
    if config.webhook == '' then
        return false, 'missing webhook'
    end

    local size = fileSize(filePath)

    if size > config.maxDiscordBytes then
        local ok, messageErr = sendDiscordJson(config, {
            embeds = {
                {
                    title = 'Database Backup Saved Locally',
                    description = table.concat({
                        ('`%s` was created but was not uploaded because it is larger than the configured Discord limit.'):format(filename),
                        ('Database: `%s`'):format(database),
                        ('Tables: `%s`'):format(tableCount),
                        ('Size: `%s`'):format(formatBytes(size)),
                        ('Limit: `%s`'):format(formatBytes(config.maxDiscordBytes)),
                        'The SQL file was kept locally on the server.'
                    }, '\n'),
                    color = config.color,
                    footer = { text = config.footer }
                }
            }
        })

        if not ok then
            warn(messageErr)
        end

        return false, 'file too large for Discord'
    end

    local content = ('Database `%s` backed up. Tables: `%s`. Size: `%s`.'):format(database, tableCount, formatBytes(size))
    return sendDiscordFile(config, filePath, filename, content)
end

local function shouldKeepLocal(uploaded, uploadErr, config)
    if uploaded then
        return config.keepLocal == true
    end

    if uploadErr == 'missing webhook' then return true end
    if uploadErr == 'file too large for Discord' then return true end

    return config.keepLocal == true or config.keepLocalOnFail == true
end

local function runBackup(reason)
    if state.running then
        warn(('Backup skipped%s. Previous backup is still running.'):format(reason and (' (' .. reason .. ')') or ''))
        return false
    end

    state.running = true

    local ok, errText = pcall(function()
        local config = loadConfig()
        local started = os.time()

        log(('Starting database backup%s.'):format(reason and (' (' .. reason .. ')') or ''))

        local filePath, filename, database, tableCount = buildBackup(config)
        local backupSize = fileSize(filePath)
        local uploaded, uploadErr = uploadBackup(config, filePath, filename, database, tableCount)
        local keepLocal = shouldKeepLocal(uploaded, uploadErr, config)

        if keepLocal then
            rememberLocalBackup(filePath, filename, database)
            pruneLocalBackups(config)
        else
            safeRemove(filePath)
            forgetLocalBackup(filePath)
        end

        local elapsed = os.time() - started

        if uploaded then
            log(('Backup complete and uploaded: %s (%s, %ss)'):format(filename, formatBytes(backupSize), elapsed))
        else
            warn(('Backup created but not uploaded: %s (%s, %s, %ss)'):format(filename, uploadErr or 'unknown upload error', formatBytes(backupSize), elapsed))
        end
    end)

    if not ok then
        fail(('Backup failed: %s'):format(errText))
    end

    state.running = false
    return ok
end

local function shouldRunNow(config, now)
    return listContains(config.schedule.days, now.day)
        and listContains(config.schedule.hours, now.hour)
        and listContains(config.schedule.minutes, now.min)
end

local function schedulerLoop()
    while true do
        local config = loadConfig()
        Wait(config.checkIntervalMs)

        local now = os.date('*t')
        if shouldRunNow(config, now) then
            local runKey = formatRunKey(now)

            if state.lastScheduleKey ~= runKey then
                state.lastScheduleKey = runKey
                runBackup('scheduled')
            end
        end
    end
end

CreateThread(function()
    Wait(3000)

    local config = loadConfig()

    log(('Loaded. Database convar: `%s`. Schedule days=`%s`, hours=`%s`, minutes=`%s`.'):format(
        config.database ~= '' and config.database or 'auto-detect',
        type(config.schedule.days) == 'table' and table.concat(config.schedule.days, ',') or 'all',
        type(config.schedule.hours) == 'table' and table.concat(config.schedule.hours, ',') or 'all',
        type(config.schedule.minutes) == 'table' and table.concat(config.schedule.minutes, ',') or 'all'
    ))

    if config.runOnStart then
        if config.startupDelaySeconds > 0 then
            log(('Startup backup will run after %s second(s).'):format(config.startupDelaySeconds))
            Wait(config.startupDelaySeconds * 1000)
        end

        state.lastScheduleKey = formatRunKey(os.date('*t'))
        runBackup('startup')
    end

    schedulerLoop()
end)

RegisterCommand('chasebackup', function(source)
    if source ~= 0 then
        warn('chasebackup can only be run from the server console.')
        return
    end

    CreateThread(function()
        runBackup('manual')
    end)
end, false)

RegisterCommand('chasebackupstatus', function(source)
    if source ~= 0 then
        warn('chasebackupstatus can only be run from the server console.')
        return
    end

    local config = loadConfig()
    local status = state.running and 'running' or 'idle'
    local webhookStatus = config.webhook ~= '' and 'set' or 'missing'

    log(('Status: %s | database=%s | webhook=%s | run_on_start=%s | keep_local=%s | keep_local_on_fail=%s | max_local=%s | max_discord=%s'):format(
        status,
        config.database ~= '' and config.database or 'auto-detect',
        webhookStatus,
        tostring(config.runOnStart),
        tostring(config.keepLocal),
        tostring(config.keepLocalOnFail),
        tostring(config.maxLocalBackups),
        formatBytes(config.maxDiscordBytes)
    ))
end, false)
