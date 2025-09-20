# synchronized FRA and backup server


## Requirements
- Oracle Database with FRA configured
- SSH access to backup server
- Root access on production server

## Run script:
```bash
chmod +x FRA-backup.sh
sudo ./FRA-backup.sh
```

## Script tasks: 
- Daily Oracle RMAN backups at 5AM
- Encrypts and syncs to remote server (rclone encyrption not AES256-GCM )
- Keeps multiple backup versions
- Verifies restore backups
- Logs everything

## Files created
- `/usr/local/bin/rman-backup.sh` - RMAN backup
- `/usr/local/bin/oracle-backup.sh` - Remote sync
- `/usr/local/bin/oracle-verify.sh` - Restore test
- `/etc/oracle-backup.conf` - Configuration

## Logs
- `/var/log/oracle-backup.log`
- `/var/log/oracle-restore.log`

## Check status
```bash
systemctl status oracle-backup.timer
tail -f /var/log/oracle-backup.log
```
