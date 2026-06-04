fx_version 'cerulean'
games { 'gta5' }

author 'Chase Development'
description 'Chase DB Backup - Dependency-free oxmysql SQL backups to Discord'
version '1.1.2'

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua'
}

dependency 'oxmysql'
