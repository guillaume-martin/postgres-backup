#!/bin/bash
#
# Backup a PostgreSQL database using pg_dump.
# Rotate the backup files on a weekly and monthly basis
#
# Author: Guillaume Martin (guillaume@enspyre.com)
#
# Usage:
# ./pg_backup_rotated.sh -c /path/to/pg_backup.config 2>&1 | tee /path/to/backup.log


set -o errtrace
trap "echo ERROR: There was an error in ${FUNCNAME-main context}, details to follow" ERR


###############################################################################
##                             GLOBAL VARIABLES                              ##
###############################################################################

### Load configuration file
echo "Loading configurations"

while [ $# -gt 0 ]; do
    case $1 in
        -c)
            CONFIG_FILE_PATH="$2"
            shift 2
            ;;
        *)
            echo "Unknown Option \"$1\"" 1>&2
            exit 2
            ;;
    esac
done

if [ -z $CONFIG_FILE_PATH ] ; then
    SCRIPTPATH=$(cd ${0%/*} && pwd -P)
    CONFIG_FILE_PATH="${SCRIPTPATH}/pg_backup.config"
fi

if [ ! -r ${CONFIG_FILE_PATH} ] ; then
    echo "Could not load config file from ${CONFIG_FILE_PATH}" 1>&2
    exit 1
fi

echo "Configurations file: $CONFIG_FILE_PATH"
source "${CONFIG_FILE_PATH}"


### Set global vairables 
START_TIME=$SECONDS
DAY_OF_MONTH=`date +%d`
DAY_OF_WEEK=`date +%u` # 1-7 (Monday-Sunday)
EXPIRED_DAYS=`expr $((($WEEKS_TO_KEEP * 7) + 1))`


###############################################################################
##                                 FUNCTIONS                                 ##
###############################################################################

function cleanup_old_backups {
    if [ BACKUP_TYPE != "daily" ]; then
        find $BAKUP_DIR -maxdepth 1 -name "*$BACKUP_TYPE" -exec rm -rf '{}' ';'
        test $! -ne 0 && echo "ERROR: failed to delete older $BACKUP_TYPE backup files: "
    else
        find $BACKUP_DIR -maxdepth 1 -mtime +$DAYS_TO_KEEP -name "*-daily" -exec rm -rf '{}' ';'
    fi
}



###############################################################################
##                            BACKUP PREPARATION                             ##
###############################################################################

if [ $DAY_OF_MONTH -eq 1 ]; then
    double_border "MONTHLY BACKUP"
    BACKUP_TYPE="monthly"
elif [ $DAY_OF_WEEK = $DAY_OF_WEEK_TO_KEEP ]; then
    double_border "WEEKLY BACKUP"
    BACKUP_TYPE="weekly"
else
    double_border "DAILY BACKUP"
    BACKUP_TYPE="daily"
fi

echo "Deleting all expired $BACKUP_TYPE backup files..."
cleanup_old_backups

echo "Executing $backup_type backup..."



###############################################################################
##                              DATABASE BACKUP                              ##
###############################################################################



