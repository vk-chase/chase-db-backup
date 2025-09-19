const mysqldump = require('mysqldump');
const { Webhook, MessageBuilder } = require('discord-webhook-node');
const { promises: fs } = require('fs');
const path = require('path');

// 🔹 Config
const config = {
  database_info: {
    host: "localhost",
    user: "root",
    password: "",
    database: "xxxxxxxxx" // The name of your database I.E.  QBCore42847  etc. 
  },
  discord: {
    enable: true,
    webhook: "https://discord.com/api/webhooks/",
    color: "#000000",
    footer: "Chase DB Backup"
  },
  schedule: {
    days: "all",
    hours: "all",
    minutes: [0, 30] // run at :00 and :30   ((BACKUP TIMER , DONE EVERY RESTART AND 30 min AFTER))
  }
};

const root = GetResourcePath(GetCurrentResourceName());
const hook = config.discord.enable && config.discord.webhook ? new Webhook(config.discord.webhook) : null;

let lastRunMinute = null;

// 🔹 Ensure sql folder exists
const sqlFolder = path.join(root, 'sql');
fs.mkdir(sqlFolder, { recursive: true }).catch(() => {});

// 🔹 Run once immediately on resource start
backup(new Date());

// 🔹 Check every second to catch exact minute
setInterval(() => checkBackup(new Date()), 1000);

async function checkBackup(now) {
  if (!shouldBackup(now)) return;

  // prevent duplicate runs in same minute
  if (lastRunMinute === now.getMinutes()) return;
  lastRunMinute = now.getMinutes();

  await backup(now);
}

async function backup(now) {
  const file = `${sqlFolder}/${config.database_info.database}-${formatDate(now)}.sql`;

  try {
    await mysqldump({ connection: { ...config.database_info }, dumpToFile: file });

    if (hook) {
      const embed = new MessageBuilder()
        .setAuthor("Chase DB Backup")
        .setColor(config.discord.color)
        .setFooter(config.discord.footer)
        .setTimestamp()
        .addField("Database", config.database_info.database)
        .addField("Date", now.toString());

      await hook.send(embed);
      await hook.sendFile(file);
    }

    console.log(`✅ Backup complete & sent: ${file}`);
  } catch (err) {
    console.error("❌ Backup failed:", err);
  } finally {
    try { await fs.unlink(file); } 
    catch (err) { console.error("⚠️ Cleanup failed:", err); }
  }
}

function shouldBackup(now) {
  const { days, hours, minutes } = config.schedule;
  return (days === "all" || days.includes(now.getDate())) &&
         (hours === "all" || hours.includes(now.getHours())) &&
         minutes.includes(now.getMinutes());
}

function formatDate(d) {
  return [d.getDate(), d.getMonth() + 1, d.getFullYear(), d.getHours(), d.getMinutes()]
    .map(n => String(n).padStart(2, '0')).join('-');
}
