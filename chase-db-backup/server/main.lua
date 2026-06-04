local RESOURCE = GetCurrentResourceName()
local RESOURCE_PATH = GetResourcePath(RESOURCE)
local SQL_DIR = RESOURCE_PATH .. '/sql'
local BACKUP_INDEX = SQL_DIR .. '/backup-index.json'

local state = {
    running = false,
    lastRunKey = nil
}

local function log(msg)
    print(('[%s] %s'):format(RESOURCE, msg))
end

local function warn(msg)
    print(('^3[%s] %s^7'):format(RESOURCE, msg))
end

local function err(msg)
    print(('^1[%s] %s^7'):format(RESOURCE, msg))
end

local function getBool(name, default)
    local fallback = default and '1' or '0'
    local value = tostring(GetConvar(name, fallback)):lower()
    return value == '1' or value == 'true' or value == 'yes' or value == 'on'
end

local function getNumber(name, default)
    local value = tonumber(GetConvar(name, tostring(default)))
    if value == nil then return default end
    return value
end

local function getString(name, default)
    local value = GetConvar(name, default or '')
    if value == nil then return default or '' end
    return value
end

local function parseNumberList(raw)
    raw = tostring(raw or 'all'):lower():gsub('%s+', '')
    if raw == '' or raw == 'all' or raw == '*' then return 'all' end

    local list = {}
    for part in raw:gmatch('[^,]+') do
        local value = tonumber(part)
        if value ~= nil then
            list[#list + 1] = value
        end
    end

    return list
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
    local dbName = getString('chase_db_database', '')
    if dbName == '' then
        dbName = getString('chase_db_name', '')
    end

    return {
        database = dbName,
        webhook = getString('chase_db_webhook', ''),
        color = tonumber((getString('chase_db_color', '0'):gsub('#', '')), 16) or 0,
        footer = getString('chase_db_footer', 'Chase DB Backup'),
        runOnStart = getBool('chase_db_run_on_start', true),
        keepLocal = getBool('chase_db_keep_local', false),
        keepLocalOnFail = getBool('chase_db_keep_local_on_fail', true),
        includeDropTable = getBool('chase_db_drop_table', true),
        includeData = getBool('chase_db_include_data', true),
        chunkSize = math.max(50, math.floor(getNumber('chase_db_chunk_size', 500))),
        checkIntervalMs = math.max(5000, math.floor(getNumber('chase_db_check_interval_ms', 15000))),
        maxDiscordBytes = math.max(1, math.floor(getNumber('chase_db_max_discord_bytes', 25000000))),
        maxLocalBackups = math.max(0, math.floor(getNumber('chase_db_max_local_backups', 10))),
        startupDelaySeconds = math.max(0, math.floor(getNumber('chase_db_startup_delay', 60))),
        schedule = {
            days = parseNumberList(getString('chase_db_days', 'all')),
            hours = parseNumberList(getString('chase_db_hours', 'all')),
            minutes = parseNumberList(getString('chase_db_minutes', '0,30'))
        }
    }
end

local function escapeIdentifier(value)
    value = tostring(value or '')
    return '`' .. value:gsub('`', '``') .. '`'
end

local function escapeSqlString(value)
    local s = tostring(value)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('\0', '\\0')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\026', '\\Z')
    s = s:gsub("'", "''")
    return "'" .. s .. "'"
end

local function sqlValue(value)
    local valueType = type(value)

    if value == nil then
        return 'NULL'
    end

    if valueType == 'number' then
        return tostring(value)
    end

    if valueType == 'boolean' then
        return value and '1' or '0'
    end

    return escapeSqlString(value)
end

local function formatDateForFile(t)
    return ('%04d-%02d-%02d_%02d-%02d-%02d'):format(t.year, t.month, t.day, t.hour, t.min, t.sec)
end

local function formatRunKey(t)
    return ('%04d-%02d-%02d_%02d-%02d'):format(t.year, t.month, t.day, t.hour, t.min)
end

local function getFileNameOnly(path)
    return tostring(path):match('([^/\\]+)$') or tostring(path)
end

local function fileSize(path)
    local file = io.open(path, 'rb')
    if not file then return 0 end

    local size = file:seek('end') or 0
    file:close()
    return size
end

local function fileExists(path)
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close()
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

local function safeRemove(path)
    if not path or path == '' then return false end
    local ok, removeErr = os.remove(path)
    if not ok and removeErr then
        warn(('Could not remove %s: %s'):format(path, removeErr))
        return false
    end
    return true
end

local function loadBackupIndex()
    local file = io.open(BACKUP_INDEX, 'rb')
    if not file then return {} end

    local raw = file:read('*a')
    file:close()

    if not raw or raw == '' then return {} end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        warn('backup-index.json is invalid. Rebuilding index from new backups only.')
        return {}
    end

    return decoded
end

local function saveBackupIndex(index)
    local file = io.open(BACKUP_INDEX, 'wb')
    if not file then
        warn('Could not write backup-index.json.')
        return
    end

    file:write(json.encode(index))
    file:close()
end

local function trimBackupIndex(index)
    local kept = {}
    local seen = {}

    for _, entry in ipairs(index or {}) do
        if type(entry) == 'table' and entry.path and not seen[entry.path] and fileExists(entry.path) then
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
            log(('Removed old local backup: %s'):format(entry.filename or getFileNameOnly(entry.path)))
        end
    end

    saveBackupIndex(index)

    if removed > 0 then
        log(('Local backup rotation complete. Removed %s old backup(s). Limit: %s.'):format(removed, maxBackups))
    end
end

local function readFile(path)
    local file = io.open(path, 'rb')
    if not file then return nil end

    local data = file:read('*a')
    file:close()
    return data
end

local function request(url, method, body, headers)
    local p = promise.new()

    PerformHttpRequest(url, function(statusCode, responseBody, responseHeaders)
        p:resolve({
            status = statusCode or 0,
            body = responseBody or '',
            headers = responseHeaders or {}
        })
    end, method or 'GET', body or '', headers or {})

    return Citizen.Await(p)
end

local function discordJson(webhook, payload)
    if webhook == '' then return false, 'Webhook convar is empty.' end

    local response = request(webhook, 'POST', json.encode(payload), {
        ['Content-Type'] = 'application/json'
    })

    if response.status >= 200 and response.status < 300 then
        return true
    end

    return false, ('Discord JSON request failed with HTTP %s: %s'):format(response.status, response.body)
end

local function discordFile(webhook, filePath, fileName, content, color, footer)
    if webhook == '' then return false, 'Webhook convar is empty.' end

    local data = readFile(filePath)
    if not data then
        return false, 'Could not read SQL file for Discord upload.'
    end

    local boundary = ('----ChaseDbBackup%s%s'):format(os.time(), math.random(100000, 999999))
    local payload = json.encode({
        content = content or '',
        embeds = {
            {
                title = 'Database Backup Complete',
                description = ('Attached file: `%s`'):format(fileName),
                color = color or 0,
                footer = { text = footer or 'Chase DB Backup' }
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

    local response = request(webhook, 'POST', body, {
        ['Content-Type'] = 'multipart/form-data; boundary=' .. boundary
    })

    if response.status >= 200 and response.status < 300 then
        return true
    end

    return false, ('Discord file upload failed with HTTP %s: %s'):format(response.status, response.body)
end

local function getActiveDatabase(config)
    if config.database ~= '' then
        return config.database
    end

    local db = MySQL.scalar.await('SELECT DATABASE()')
    if not db or db == '' then
        error('Unable to detect active database. Set chase_db_database or chase_db_name in server.cfg.')
    end

    return db
end

local function escapeQualified(database, tableName)
    return escapeIdentifier(database) .. '.' .. escapeIdentifier(tableName)
end

local function getCreateStatement(database, tableName)
    local result = MySQL.query.await(('SHOW CREATE TABLE %s'):format(escapeQualified(database, tableName)))
    local row = result and result[1]
    if not row then return nil end

    for key, value in pairs(row) do
        if tostring(key):lower():find('create table', 1, true) then
            return tostring(value)
        end
    end

    return nil
end

local function getColumns(database, tableName)
    local rows = MySQL.query.await([[ 
        SELECT COLUMN_NAME
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        ORDER BY ORDINAL_POSITION
    ]], { database, tableName }) or {}

    local columns = {}
    for _, row in ipairs(rows) do
        columns[#columns + 1] = row.COLUMN_NAME or row.column_name
    end

    return columns
end

local function writeInsertRows(file, tableName, columns, rows)
    if #rows == 0 or #columns == 0 then return end

    local columnSql = {}
    for i = 1, #columns do
        columnSql[i] = escapeIdentifier(columns[i])
    end

    file:write(('INSERT INTO %s (%s) VALUES\n'):format(escapeIdentifier(tableName), table.concat(columnSql, ', ')))

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

local function dumpTable(file, database, tableInfo, config)
    local tableName = tableInfo.TABLE_NAME or tableInfo.table_name
    if not tableName then return end

    log(('Dumping table: %s'):format(tableName))

    file:write('\n-- --------------------------------------------------------\n')
    file:write(('-- Table structure for `%s`\n'):format(tableName))
    file:write('-- --------------------------------------------------------\n\n')

    if config.includeDropTable then
        file:write(('DROP TABLE IF EXISTS %s;\n'):format(escapeIdentifier(tableName)))
    end

    local createStatement = getCreateStatement(database, tableName)
    if createStatement then
        file:write(createStatement .. ';\n\n')
    else
        warn(('Could not read CREATE TABLE statement for %s.'):format(tableName))
    end

    if not config.includeData then return end

    local countRow = MySQL.single.await(('SELECT COUNT(*) AS row_count FROM %s'):format(escapeQualified(database, tableName)))
    local rowCount = tonumber(countRow and (countRow.row_count or countRow.count or countRow['COUNT(*)'])) or 0

    if rowCount <= 0 then
        return
    end

    file:write(('-- Data for `%s` (%s rows)\n\n'):format(tableName, rowCount))

    local columns = getColumns(database, tableName)
    if #columns == 0 then
        warn(('Could not read column list for %s. Data skipped.'):format(tableName))
        return
    end

    local offset = 0
    while offset < rowCount do
        local rows = MySQL.query.await(('SELECT * FROM %s LIMIT ? OFFSET ?'):format(escapeQualified(database, tableName)), {
            config.chunkSize,
            offset
        }) or {}

        if #rows == 0 then
            break
        end

        writeInsertRows(file, tableName, columns, rows)
        offset = offset + #rows
        Wait(0)
    end
end

local function shouldRun(config, now)
    return listContains(config.schedule.days, now.day)
        and listContains(config.schedule.hours, now.hour)
        and listContains(config.schedule.minutes, now.min)
end

local function buildBackup(config)
    local database = getActiveDatabase(config)
    local now = os.date('*t')
    local filename = ('%s-%s.sql'):format(database, formatDateForFile(now))
    local filePath = SQL_DIR .. '/' .. filename

    local file = io.open(filePath, 'wb')
    if not file then
        error(('Could not open backup file for writing: %s'):format(filePath))
    end

    file:write('-- Chase DB Backup\n')
    file:write(('-- Database: %s\n'):format(database))
    file:write(('-- Created: %04d-%02d-%02d %02d:%02d:%02d\n\n'):format(now.year, now.month, now.day, now.hour, now.min, now.sec))
    file:write('SET FOREIGN_KEY_CHECKS=0;\n')
    file:write(('CREATE DATABASE IF NOT EXISTS %s;\n'):format(escapeIdentifier(database)))
    file:write(('USE %s;\n\n'):format(escapeIdentifier(database)))

    local tables = MySQL.query.await([[ 
        SELECT TABLE_NAME, TABLE_TYPE
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = ? AND TABLE_TYPE = 'BASE TABLE'
        ORDER BY TABLE_NAME
    ]], { database }) or {}

    if #tables == 0 then
        file:close()
        error(('No base tables found for database `%s`.'):format(database))
    end

    for _, tableInfo in ipairs(tables) do
        dumpTable(file, database, tableInfo, config)
    end

    file:write('SET FOREIGN_KEY_CHECKS=1;\n')
    file:close()

    return filePath, filename, database, #tables
end

local function sendBackup(config, filePath, filename, database, tableCount)
    if config.webhook == '' then
        warn('chase_db_webhook is empty. Backup saved locally only.')
        return false, 'missing webhook'
    end

    local size = fileSize(filePath)
    if size > config.maxDiscordBytes then
        local ok, messageErr = discordJson(config.webhook, {
            embeds = {
                {
                    title = 'Database Backup Saved Locally',
                    description = table.concat({
                        ('`%s` was created, but it is larger than the configured Discord upload limit.'):format(filename),
                        ('Size: `%s`'):format(formatBytes(size)),
                        ('Limit: `%s`'):format(formatBytes(config.maxDiscordBytes)),
                        'The local SQL file was kept on the server.'
                    }, '\n'),
                    color = config.color,
                    footer = { text = config.footer }
                }
            }
        })

        if not ok then warn(messageErr) end
        return false, 'file too large for Discord'
    end

    local content = ('Database `%s` backed up. Tables: `%s`. Size: `%s`.'):format(database, tableCount, formatBytes(size))
    return discordFile(config.webhook, filePath, filename, content, config.color, config.footer)
end

local function runBackup(reason)
    if state.running then
        warn(('Backup skipped%s. Previous backup is still running.'):format(reason and (' (' .. reason .. ')') or ''))
        return
    end

    state.running = true

    local ok, resultOrErr = pcall(function()
        local config = loadConfig()
        local filePath, filename, database, tableCount = buildBackup(config)
        local uploaded, uploadErr = sendBackup(config, filePath, filename, database, tableCount)

        local keepFile = false

        if uploaded then
            log(('Backup complete and uploaded: %s'):format(filename))
            keepFile = config.keepLocal
        else
            warn(('Backup created but not uploaded: %s (%s)'):format(filename, uploadErr or 'unknown upload error'))
            keepFile = config.keepLocal or config.keepLocalOnFail or uploadErr == 'file too large for Discord'
        end

        if keepFile then
            rememberLocalBackup(filePath, filename, database)
            pruneLocalBackups(config)
        else
            safeRemove(filePath)
            forgetLocalBackup(filePath)
        end
    end)

    if not ok then
        err(('Backup failed: %s'):format(resultOrErr))
    end

    state.running = false
end

local function schedulerLoop()
    local config = loadConfig()

    while true do
        Wait(config.checkIntervalMs)
        config = loadConfig()

        local now = os.date('*t')
        if shouldRun(config, now) then
            local runKey = formatRunKey(now)
            if state.lastRunKey ~= runKey then
                state.lastRunKey = runKey
                runBackup('scheduled')
            end
        end
    end
end

CreateThread(function()
    Wait(3000)

    local config = loadConfig()
    if config.runOnStart then
        if config.startupDelaySeconds > 0 then
            log(('Startup backup scheduled in %s second(s).'):format(config.startupDelaySeconds))
            Wait(config.startupDelaySeconds * 1000)
        end

        runBackup('startup')
    end

    schedulerLoop()
end)

RegisterCommand('chasebackup', function(source)
    if source ~= 0 then
        warn('chasebackup can only be run from server console.')
        return
    end

    CreateThread(function()
        runBackup('manual')
    end)
end, false)
