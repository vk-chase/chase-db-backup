# 🗄️ Chase DB Backups
--[[
1- my discord https://discord.gg/9fK6cBByvs
2- support / edits not guaranteed 
]]
This little FiveM resource automatically **backs up your MySQL database** and shoots it into a Discord channel.  
No more forgetting to dump your DB and crying later. It even deletes the temp `.sql` file so your server doesn’t fill up with junk.

---

## ✨ Features
- ✅ Runs a backup **on resource start** (so you instantly know it works).  
- ✅ Then runs **every 30 minutes** (at `:00` and `:30`).  
- ✅ Sends the `.sql` file straight to your Discord webhook.  
- ✅ Deletes the backup file after sending (keeps server clean).  
- ✅ Super lightweight — doesn’t lag your server.  

---

## 📂 Installation
1. Drop the `chase-db-backups` folder into your `resources/` folder.  
2. Run `npm install` inside the folder to install dependencies:
   ```sh
   cd resources/chase-db-backups
   npm install
