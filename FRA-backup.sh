#!/bin/bash
set -euo pipefail

echo "FRA Backup Script"

# cli inputs
while true; do
  read -rp "FRA production path: " FRA_PATH
  if [[ -z "$FRA_PATH" ]]; then
    echo "FRA production path is required"
    continue
  fi
  if [[ ! -d "$FRA_PATH" ]]; then
    echo "FRA path $FRA_PATH does not exist"
    continue
  fi
  break
done

while true; do
  read -rp "Oracle User: " ORACLE_USER
  if [[ -z "$ORACLE_USER" ]]; then
    echo "oracle user is required"
    continue
  fi
  if ! id "$ORACLE_USER" &>/dev/null; then
    echo "oracle user $ORACLE_USER does not exist"
    continue
  fi
  if ! su - "$ORACLE_USER" -c "which rman" &>/dev/null; then
    echo "RMAN not found for oracle user $ORACLE_USER"
    continue
  fi
  if ! su - "$ORACLE_USER" -c "which sqlplus" &>/dev/null; then
    echo "SQLPlus not found for oracle user $ORACLE_USER"
    continue
  fi
  if ! su - "$ORACLE_USER" -c "sqlplus -s / as sysdba <<< 'select 1 from dual; exit;'" &>/dev/null; then
    echo "Cannot connect to oracle database as $ORACLE_USER"
    continue
  fi
  echo "oracle environment validated successfully"
  break
done

while true; do
  read -rp "backup VPS IP: " BACKUP_IP
  if [[ -z "$BACKUP_IP" ]]; then
    echo "backup VPS IP is required"
    continue
  fi
  if ! ping -c 1 -W 3 "$BACKUP_IP" &>/dev/null; then
    echo "Cannot ping $BACKUP_IP, Continue anyway? (y/n): "
    read -rp "" confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      break
    else
      continue
    fi
  else
    break
  fi
done

while true; do
  read -rp "backup VPS username: " BACKUP_USER
  if [[ -z "$BACKUP_USER" ]]; then
    echo "backup VPS username is required"
    continue
  fi
  break
done

BACKUP_REMOTE_PATH="/home/${BACKUP_USER}/oracle_backups"

while true; do
  read -rp "restore test directory: " RESTORE_DIR
  if [[ -z "$RESTORE_DIR" ]]; then
    RESTORE_DIR="/root/restore_test"
  fi
  if [[ ! -d "$RESTORE_DIR" ]]; then
    echo "creating restore directory: $RESTORE_DIR"
    mkdir -p "$RESTORE_DIR"
  fi
  break
done

while true; do
  read -rp "retention (versions to keep): " RETENTION
  if [[ -z "$RETENTION" ]]; then
    echo "retention is required"
    continue
  fi
  if ! [[ "$RETENTION" =~ ^[0-9]+$ ]]; then
    echo "retention must be a positive number"
    continue
  fi
  if [[ "$RETENTION" -lt 1 ]]; then
    echo "retention must be at least 1"
    continue
  fi
  break
done

while true; do
  read -rp "restore verification frequency(hours): " RESTORE_FREQ
  if [[ -z "$RESTORE_FREQ" ]]; then
    RESTORE_FREQ="12"
  fi
  if ! [[ "$RESTORE_FREQ" =~ ^[0-9]+$ ]]; then
    echo "frequency must be a positive number"
    continue
  fi
  if [[ "$RESTORE_FREQ" -lt 1 ]]; then
    echo "frequency must be at least 1 hour"
    continue
  fi
  if [[ "$RESTORE_FREQ" -gt 168 ]]; then
    echo "frequency is more than 1 week, continue anyway? (y/n): "
    read -rp "" confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      break
    else
      continue
    fi
  else
    break
  fi
done

#ssh test
SSH_KEY="/root/.ssh/id_rsa"
echo "testing ssh connection to ${BACKUP_USER}@${BACKUP_IP}..."
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${BACKUP_USER}@${BACKUP_IP}" "echo 'ssh connection successful'" &>/dev/null; then
  echo "connection failed to backup server "
  exit 1
fi
echo "ssh connected"


# config file
cat > /etc/oracle-backup.conf <<EOF
FRA_PATH="$FRA_PATH"
RESTORE_DIR="$RESTORE_DIR"
RETENTION=$RETENTION
# ALERT_EMAIL removed
# PUSHGATEWAY removed
ORACLE_USER="$ORACLE_USER"
BACKUP_REMOTE_PATH="$BACKUP_REMOTE_PATH"
BACKUP_IP="$BACKUP_IP"
BACKUP_USER="$BACKUP_USER"
EOF

echo "→ Creating directories..."
mkdir -p "$FRA_PATH" "$RESTORE_DIR" /var/log
chown "$ORACLE_USER":"$ORACLE_USER" "$FRA_PATH"

echo "→ installing dependencies..."
apt-get update -y
apt-get install -y rclone jq curl openssl

# Configure rclone
echo "→ Configuring rclone..."
mkdir -p /root/.config/rclone
if [[ ! -f /root/.rclone_keys ]]; then
  KEY1=$(rclone obscure "$(openssl rand -base64 32)")
  KEY2=$(rclone obscure "$(openssl rand -base64 32)")
  echo "KEY1=$KEY1" > /root/.rclone_keys
  echo "KEY2=$KEY2" >> /root/.rclone_keys
else
  source /root/.rclone_keys
fi

cat > /root/.config/rclone/rclone.conf <<EOF
[backupserver]
type = sftp
host = ${BACKUP_IP}
user = ${BACKUP_USER}
key_file = ${SSH_KEY}

[backup-crypt]
type = crypt
remote = backupserver:${BACKUP_REMOTE_PATH}
filename_encryption = standard
directory_name_encryption = true
password = ${KEY1}
password2 = ${KEY2}
EOF
chmod 600 /root/.config/rclone/rclone.conf

echo "→ ensuring backup vps path exists on ${BACKUP_IP}..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${BACKUP_USER}@${BACKUP_IP}" "mkdir -p '${BACKUP_REMOTE_PATH}' && chmod 700 '${BACKUP_REMOTE_PATH}'"

#RMAN
echo "→ installing RMAN backup script..."
cat > /usr/local/bin/rman-backup.sh <<'EOS'
#!/bin/bash
set -euo pipefail
source /etc/oracle-backup.conf
LOGFILE="/var/log/rman-backup.log"

su - "$ORACLE_USER" -c "rman target / <<EOR
RUN {
  BACKUP DATABASE PLUS ARCHIVELOG FORMAT '${FRA_PATH}/full_%d_%T_%U.bkp';
  CROSSCHECK BACKUP;
  DELETE NOPROMPT OBSOLETE;
}
EXIT
EOR" | tee -a "$LOGFILE"
EOS
chmod +x /usr/local/bin/rman-backup.sh

# Rclone sync script
echo "→ Installing rclone sync script..."
cat > /usr/local/bin/oracle-backup.sh <<'EOS'
#!/bin/bash
set -euo pipefail
source /etc/oracle-backup.conf
DEST="backup-crypt:/oracle_backups"
LOGFILE="/var/log/oracle-backup.log"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOGFILE"; }
alert_fail() {
  echo "$(date '+%F %T') BACKUP FAILED: $1" | tee -a "$LOGFILE"
}
success_metric() {
  echo "$(date '+%F %T') BACKUP COMPLETED SUCCESSFULLY" | tee -a "$LOGFILE"
}

backup_file() {
  local f="$1"
  local fname=$(basename "$f")
  local timestamp=$(date "+%F %H:%M")

  src_size=$(stat -c %s "$f")
  dest_size=$(rclone lsjson "$DEST" --files-only 2>/dev/null | jq -r \
    --arg name "$fname" '.[] | select(.Name | startswith($name)) | .Size' | tail -n1 || true)
  [[ -z "$dest_size" ]] && dest_size=0

  if [[ "$src_size" -ne "$dest_size" ]]; then
    log "Backing up $fname (src=$src_size, dst=$dest_size)"
    if ! rclone copyto "$f" "$DEST/${fname}-${timestamp}" \
      --transfers=4 --checkers=8 --multi-thread-streams=4 --bwlimit=50M >>"$LOGFILE" 2>&1; then
      alert_fail "$fname"
      return 1
    fi
  else
    log "$fname unchanged, skipping"
  fi

  versions=( $(rclone lsjson "$DEST" --files-only --no-modtime | jq -r \
               --arg name "$fname" '.[] | select(.Name | startswith($name)) | .Name' | sort) )
  while [[ ${#versions[@]} -gt $RETENTION ]]; do
    old=${versions[0]}
    log "Pruning $old"
    rclone delete "$DEST/$old" >>"$LOGFILE" 2>&1 || true
    versions=( "${versions[@]:1}" )
  done
}

log "  Backup started  "
for f in "$FRA_PATH"/*; do [[ -f "$f" ]] && backup_file "$f"; done
log " Backup completed "
success_metric
EOS
chmod +x /usr/local/bin/oracle-backup.sh

# --- Restore verification script ---
echo "→ Installing restore verification script..."
cat > /usr/local/bin/oracle-verify.sh <<'EOS'
#!/bin/bash
set -euo pipefail
source /etc/oracle-backup.conf
LOGFILE="/var/log/oracle-restore.log"

log() { echo "$(date '+%F %T') $*" | tee -a "$LOGFILE"; }
alert_fail() {
  echo "$(date '+%F %T') RESTORE FAILED: $1" | tee -a "$LOGFILE"
}
success_metric() {
  echo "$(date '+%F %T') RESTORE COMPLETED SUCCESSFULLY" | tee -a "$LOGFILE"
}

log " Restore verification started "
latest=$(rclone lsjson backup-crypt:/oracle_backups --files-only | jq -r '.[].Name' | sort | tail -n1)
if [[ -z "$latest" ]]; then
  alert_fail "No backup found"
  exit 1
fi

rclone copy "backup-crypt:/oracle_backups/$latest" "$RESTORE_DIR/" >>"$LOGFILE" 2>&1 || { alert_fail "$latest"; exit 1; }

orig="$FRA_PATH/${latest%%-*}"
restored="$RESTORE_DIR/$latest"
if [[ -f "$orig" && -f "$restored" ]]; then
  if [[ $(sha256sum "$orig" | cut -d' ' -f1) == $(sha256sum "$restored" | cut -d' ' -f1) ]]; then
    log "Restore verified OK: $latest"
    success_metric
  else
    alert_fail "Checksum mismatch: $latest"
  fi
else
  alert_fail "Missing files during verify"
fi
log " Restore verification completed "
EOS
chmod +x /usr/local/bin/oracle-verify.sh

#Systemd units 
echo "→ setting up systemd timers..."
cat > /etc/systemd/system/oracle-backup.service <<'EOF'
[Unit]
Description=Oracle RMAN + Rclone Backup
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rman-backup.sh
ExecStartPost=/usr/local/bin/oracle-backup.sh
EOF

cat > /etc/systemd/system/oracle-backup.timer <<'EOF'
[Unit]
Description=Daily Oracle Backup
[Timer]
OnCalendar=*-*-* 05:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/oracle-verify.timer <<EOF
[Unit]
Description=Restore verification every ${RESTORE_FREQ}h
[Timer]
OnUnitActiveSec=${RESTORE_FREQ}h
Persistent=true
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now oracle-backup.timer oracle-verify.timer

# --- Logrotate ---
cat > /etc/logrotate.d/oracle-backup <<'EOF'
/var/log/oracle-*.log {
  weekly
  rotate 8
  compress
  missingok
  notifempty
  create 640 root adm
}
EOF

echo "  installation Complete  "
echo "Backups: daily 5AM"
echo "Restore tests: every ${RESTORE_FREQ}h"
echo "Logs: /var/log/oracle-backup.log, /var/log/oracle-restore.log"
