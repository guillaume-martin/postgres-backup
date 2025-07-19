#!/bin/bash
#
# Backup a PostgreSQL database using pg_dump.
# Rotate the backup files on a weekly and monthly basis
#
# Author: Guillaume Martin (guillaume@enspyre.com)
#
# Usage:
# ./pg_backup_rotated.sh -c /path/to/pg_backup.config 2>&1 | tee /path/to/backup.log


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

echo "Configuration file: $CONFIG_FILE_PATH"
source "${CONFIG_FILE_PATH}"

### Set defaults for missing values
echo -e "\n--------------------------------------------"
if [ ! $HOSTNAME ]; then
    echo "HOSTNAME is missing. Setting to default."
    HOSTNAME="localhost"
fi;

if [ ! $PORT ]; then
    echo "PORT is missing. Setting to default."
    PORT=5432
fi;

if [ ! $USERNAME ]; then
    echo "USERNAME is missing. Setting to default."
	USERNAME="postgres"
fi;

# If the encryption settings are not set, we don't encrypt the backups
if [ ! $ENCRYPT_BACKUP_FILES ]; then
    echo "ENCRYPT_BACKUP_FILES is missing. Setting to default."
    ENCRYPT_BACKUP_FILES="no"
fi;


echo "Backup configuration:"
echo "---------------------"
echo "HOSTNAME = $HOSTNAME"
echo "PORT = $PORT"
echo "USERNAME = $USERNAME"
echo "ENCRYPT_BACKUP_FILES = $ENCRYPT_BACKUP_FILES"
echo "Backup Directory = $BACKUP_DIR"


echo -e "\n--------------------------------------------\n"

### Set global variables
START_TIME=$SECONDS
DAY_OF_MONTH=`date +%d`
DAY_OF_WEEK=`date +%u` # 1-7 (Monday-Sunday)
EXPIRED_DAYS=`expr $((($WEEKS_TO_KEEP * 7) + 1))`

echo "Date/Time variables"
echo "-------------------"
echo "START_TIME   = $START_TIME"
echo "DAY_OF_MONTH = $DAY_OF_MONTH"
echo "DAY_OF_WEEK  = $DAY_OF_WEEK"
echo "EXPIRED_DAYS = $EXPIRED_DAYS"

echo -e "\n============================================\n"

###############################################################################
##                                 FUNCTIONS                                 ##
###############################################################################

##########################################
# Draws a single line box around a string
# Arguments:
#   Text to put in a box
# Outputs:
#   A box with single border (-) containing
#   some text
##########################################
function single_border(){
    text=" $1 "
    edge=$(echo "$text" | sed 's/./-/g')
    echo "+$edge+"
    echo "|$text|"
    echo "+$edge+"
}

##########################################
# Draws a double line box around a string
# Arguments:
#   Text to put in a box
# Outputs:
#   A box with double border (=) containing
#   some text
##########################################
function double_border(){
    text=" $1 "
    edge=$(echo "$text" | sed 's/./=/g')
    echo "+$edge+"
    echo "|$text|"
    echo "+$edge+"
}


###############################################################################
##                            BACKUP PREPARATION                             ##
###############################################################################

# Make sure we're running as the required backup user
if [ "$BACKUP_USER" != "" -a "$(id -un)" != "$BACKUP_USER" ] ; then
	echo "This script must be run as $BACKUP_USER. Exiting." 1>&2
	exit 1
fi

# Create the backup folder if it doesn't exist yet
if [ ! -d $BACKUP_DIR ]; then
    echo "Creating $BACKUP_DIR"
    mkdir -p $BACKUP_DIR
else
    echo -e "$BACKUP_DIR already exits\n"
fi;

# Set the backup type depending on the day
if [ $DAY_OF_MONTH -eq 1 ]; then
    double_border "MONTHLY BACKUP"
    BACKUP_TYPE="monthly"
elif [ $DAY_OF_WEEK = $DAY_OF_WEEK_TO_KEEP ]; then
    double_border "WEEKLY BACKUP"
    BACKUP_TYPE="weekly"
else
    double_border "DAILY BACKUP"
    BACKUP_TYPE="daily"
fi;

echo "Deleting all expired $BACKUP_TYPE backup files..."
if [ BACKUP_TYPE != "daily" ]; then
    find $BAKUP_DIR -maxdepth 1 -mtime +$EXPIRED_DAYS -name "*$BACKUP_TYPE" -exec rm -rf '{}' ';'
    test $? -ne 0 && echo "ERROR: failed to delete older $BACKUP_TYPE backup files: "
else
    find $BACKUP_DIR -maxdepth 1 -mtime +$DAYS_TO_KEEP -name "*-daily" -exec rm -rf '{}' ';'
fi

# Create the subdirectory where today's backups will be saved
BACKUP_SUBDIR="$BACKUP_DIR/`date +\%Y-\%m-\%d`-$BACKUP_TYPE"
if ! mkdir -p $BACKUP_SUBDIR; then
    echo "ERROR: Cannot create backup directory in $BACKUP_SUBDIR." 1>&2
    exit 1;
else
    chmod 775 $BACKUP_SUBDIR
    echo "Backups will be saved in $BACKUP_SUBDIR."
fi;


###############################################################################
##                              DATABASE BACKUP                              ##
###############################################################################

echo "Executing $BACKUP_TYPE backup..."

# Globals backup ##########################################
echo -e "\n============================================"
if [ "$ENABLE_GLOBALS_BACKUPS" == "yes" ]; then
    echo "Performing globals backup"
    mkdir -p $BACKUP_SUBDIR/globals
    backup_file="globals.sql"
    # Dump the cluster's global data
    pg_dumpall -g \
        -h "$HOSTNAME" \
        -p "$PORT" \
        -U "$USERNAME" \
        -f "$BACKUP_SUBDIR/globals/$backup_file"
    if [ $? == 0 ]; then
        echo "Database dumped in $backup_file"
    else
        echo "ERROR: Failed to produce globals backup" 1>&2
        exit 1
    fi

    # Generate the backup file's hash
    hash_file=$backup_file.sha256
    sha256sum "$BACKUP_SUBDIR/globals/$backup_file" > "$BACKUP_SUBDIR/globals/$hash_file"

    # Encrypt the backup file
    if [ "$ENCRYPT_BACKUP_FILES" == "yes" ]; then
        # Use the --batch and --yes options to avoid prompts
        gpg --batch --yes -r $GPG_KEY_ID -e "$BACKUP_SUBDIR/globals/$backup_file"
        if [ "$SHRED_CLEAR_BACKUP_FILES" == "yes" ] && [ -f "$BACKUP_SUBDIR/globals/$backup_file" ]; then
            echo "Deleting $backup_file"
            shred -zu -n 5 "$BACKUP_SUBDIR/globals/$backup_file"
        fi
    fi

    # Archive the backup files
    tar -czvf $BACKUP_SUBDIR/globals.tar.gz -C $BACKUP_SUBDIR globals 
    rm -rf $BACKUP_SUBDIR/globals

else
    echo "Globals backup disabled"
fi

# Schema-only backups #####################################
# Backup only the schema of databases specified in SCHEMA_ONLY_LIST
echo -e "\n============================================"
if [ ${#SCHEMA_ONLY_LIST} -ne 0 ]; then
    # Generate the where clause with all the selected databases
	for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }; do
        SCHEMA_ONLY_CLAUSE="$SCHEMA_ONLY_CLAUSE OR datname ~ '$SCHEMA_ONLY_DB'"
	done

    echo "Performing schema-only backups."
    # Extract the names of all the databases that match the patterns from the schema only list
    SCHEMA_ONLY_QUERY="SELECT datname FROM pg_database WHERE false $SCHEMA_ONLY_CLAUSE ORDER BY datname;"
	SCHEMA_ONLY_DB_LIST=`psql -h "$HOSTNAME" -p $PORT -U "$USERNAME" -At -c "$SCHEMA_ONLY_QUERY" postgres`

	echo -e "The following databases were matched for schema-only backup:\n${SCHEMA_ONLY_DB_LIST}\n"

	for DATABASE in $SCHEMA_ONLY_DB_LIST; do
        echo "Schema-only backup of $DATABASE."
        mkdir -p $BACKUP_SUBDIR/$DATABASE
        backup_file=$DATABASE"_schema.sql"

        pg_dump -Fp -s \
            -h "$HOSTNAME" \
            -p "$PORT" \
            -U "$USERNAME" \
            "$DATABASE" \
            > "$BACKUP_SUBDIR/$DATABASE/$backup_file"

        if [ $? == 0 ]; then
            echo "Schema of $DATABASE dumped in $backup_file."
        else
            echo "ERROR: Failed to backup database schema of $DATABASE." 1>&2
            exit 1
        fi

        # Generate the backup file's hash
        sha256sum "$BACKUP_SUBDIR/$DATABASE/$backup_file" > "$BACKUP_SUBDIR/$DATABASE/$backup_file.sha256"

        # Encrypt the backup file
        if [ "$ENCRYPT_BACKUP_FILES" == "yes" ]; then
            # Use the --batch and --yes options to avoid prompts
            gpg --batch --yes -r $GPG_KEY_ID -e "$BACKUP_SUBDIR/$DATABASE/$backup_file"
            if [ "$SHRED_CLEAR_BACKUP_FILES" == "yes" ] && [ -f "$BACKUP_SUBDIR/$DATABASE/$backup_file" ]; then
                echo "Deleting $backup_file"
                shred -zu -n 5 "$BACKUP_SUBDIR/$DATABASE/$backup_file"
            fi
        fi
        
        # Archive all the backup files of the database
        tar -czvf $BACKUP_SUBDIR/$DATABASE.tar.gz -C $BACKUP_SUBDIR $DATABASE
        rm -rf $BACKUP_SUBDIR/$DATABASE

    done
else
    echo "No Schemas selected for backup."
fi


# Full backups ############################################
# Backup entire databases (schema + data)
echo -e "\n============================================"

# Exclude the databases that are set for schema-only backup
for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }; do
    EXCLUDE_SCHEMA_ONLY_CLAUSE="$EXCLUDE_SCHEMA_ONLY_CLAUSE AND datname !~ '$SCHEMA_ONLY_DB'"
done

# Get the list of databases to backup
FULL_BACKUP_QUERY="SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn $EXCLUDE_SCHEMA_ONLY_CLAUSE ORDER BY datname;"
FULL_BACKUP_DB_LIST=`psql -h "$HOSTNAME" -U "$USERNAME" -At -c "$FULL_BACKUP_QUERY" postgres`

for DATABASE in $FULL_BACKUP_DB_LIST; do
    mkdir -p $BACKUP_SUBDIR/$DATABASE
    echo ""
    single_border "$DATABASE"
    # Check whether the database is in the list of excluded databases
    if [[ $EXCLUDE_LIST =~ $DATABASE ]]; then
        echo "Skipping $DATABASE database."
        continue
    fi

    ## Plain text backup
    echo -e "\n--------------------------------------------"
    if [ "$ENABLE_PLAIN_BACKUPS" == "yes" ]; then
        echo "Plain text backup of $DATABASE database."
        backup_file=$DATABASE"_full.sql"

        pg_dump -Fp \
            -h "$HOSTNAME" \
            -p "$PORT" \
            -U "$USERNAME" \
            "$DATABASE" \
            > "$BACKUP_SUBDIR/$DATABASE/$backup_file"

        if [ $? == 0 ]; then
            echo "$DATABASE dumped into $backup_file."
        else
            echo "ERROR: Failed to produce plain text backup of $DATABASE." 1>&2
            exit 1
        fi

        # Generate the backup file's hash
        sha256sum "$BACKUP_SUBDIR/$DATABASE/$backup_file" > "$BACKUP_SUBDIR/$DATABASE/$backup_file.sha256"

        # Encrypt the backup file
        if [ "$ENCRYPT_BACKUP_FILES" == "yes" ]; then
            # Use the --batch and --yes options to avoid prompts
            gpg --batch --yes -r $GPG_KEY_ID -e "$BACKUP_SUBDIR/$DATABASE/$backup_file"
            if [ "$SHRED_CLEAR_BACKUP_FILES" == "yes" ] && [ -f "$BACKUP_SUBDIR/$DATABASE/$backup_file" ]; then
                echo "Deleting $backup_file"
                shred -zu -n 5 "$BACKUP_SUBDIR/$DATABASE/$backup_file"
            fi
        fi
    else
        echo "Plain text backup is disabled."
    fi

    ## Custom format backup
    echo -e "\n--------------------------------------------"
    if [ "$ENABLE_CUSTOM_BACKUPS" == "yes" ]; then
        echo "Custom format backup of $DATABASE database."
        backup_file="$DATABASE.custom"

        pg_dump -Fc \
            -h "$HOSTNAME" \
            -p "$PORT" \
            -U "$USERNAME" \
            "$DATABASE" \
            -f "$BACKUP_SUBDIR/$DATABASE/$backup_file"

        if [ $? == 0 ]; then
            echo "$DATABASE dumped into $backup_file."
        else
            echo "ERROR: Failed to produce custom format backup of $DATABASE." 1>&2
            exit 1
        fi

        # Generate the backup file's hash
        sha256sum "$BACKUP_SUBDIR/$DATABASE/$backup_file" > "$BACKUP_SUBDIR/$DATABASE/$backup_file.sha256"

        # Encrypt the backup file
        if [ "$ENCRYPT_BACKUP_FILES" == "yes" ]; then
            # Use the --batch and --yes options to avoid prompts
            gpg --batch --yes -r $GPG_KEY_ID -e "$BACKUP_SUBDIR/$DATABASE/$backup_file"
            if [ "$SHRED_CLEAR_BACKUP_FILES" == "yes" ] && [ -f "$BACKUP_SUBDIR/$DATABASE/$backup_file" ]; then
                echo "Deleting $backup_file"
                shred -zu -n 5 "$BACKUP_SUBDIR/$DATABASE/$backup_file"
            fi
        fi
    else
        echo "Custon format backup is disabled"
    fi

    # Create an archive that stores all the database backup files
    tar -czvf $BACKUP_SUBDIR/$DATABASE.tar.gz -C $BACKUP_SUBDIR $DATABASE
    rm -rf $BACKUP_SUBDIR/$DATABASE
    
done


# Finish ##################################################

echo -e "\n--------------------------------------------"
echo -e "\nAll databases backups done."

# Display the files saved in the backup directory
echo -e "\n=================================================="
echo -e "Showing files in $BACKUP_SUBDIR\n"
ls -lh $BACKUP_SUBDIR

echo -e "\n=================================================="
ELAPSED_TIME=$(($SECONDS - $START_TIME))
echo "The backup took $(($ELAPSED_TIME/60)) min $(($ELAPSED_TIME%60)) sec"
