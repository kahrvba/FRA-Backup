# synchronized FRA and backup server


## Requirements
- Oracle Database with FRA configured
- SSH access to backup server
- Root access on production server

## Run script:
```bash
curl -fsSL https://raw.githubusercontent.com/kahrvba/FRA-Backup/main/FRA-backup.sh -o FRA-backup.sh
chmod +x FRA-backup.sh
sudo ./FRA-backup.sh
```

## Script tasks: 
- Daily Oracle RMAN backups at 5AM
- Encrypts and syncs to remote server (rclone encryption, not AES256-GCM)
- Keeps multiple backup versions
- Verifies restore backups
- Logs everything

## Files created
- `/usr/local/bin/rman-backup.sh` - RMAN backup
- `/usr/local/bin/oracle-backup.sh` - Remote sync
- `/usr/local/bin/oracle-verify.sh` - Restore test
- `/etc/oracle-backup.conf` - Configuration
 - `/etc/systemd/system/oracle-backup.service` - Backup service unit
 - `/etc/systemd/system/oracle-backup.timer` - Daily backup timer
 - `/etc/systemd/system/oracle-verify.timer` - Restore verification timer
 - `/etc/logrotate.d/oracle-backup` - Logrotate configuration
 - `/root/.config/rclone/rclone.conf` - rclone remotes configuration
 - `/root/.rclone_keys` - rclone crypt keys

## Logs
- `/var/log/oracle-backup.log`
- `/var/log/oracle-restore.log`
 - `/var/log/rman-backup.log`

## Check status
```bash
systemctl status oracle-backup.timer
systemctl status oracle-verify.timer
tail -f /var/log/oracle-backup.log
```
