#!/bin/bash

# Backup a PostgreSQL database using pg_dump.
# Rotate the backup files on a weekly and monthly basis
# 
# Author: Guillaume Martin (guillaume@enspyre.com)
# 


START_TIME=$SECONDS

echo "##################################################"
echo -e "##          BACKUP LOG FOR `date +\%Y-\%m-\%d`           ##"
echo -e "##################################################\n"

echo -e "Start time: `date +\%H:\%M:\%S`\n"


###########################
#       LOAD CONFIG       #
###########################

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


###########################
#    PRE-BACKUP CHECKS    #
###########################

# Make sure we're running as the required backup user
if [ "$BACKUP_USER" != "" -a "$(id -un)" != "$BACKUP_USER" ] ; then
	echo "This script must be run as $BACKUP_USER. Exiting." 1>&2
	exit 1
fi


#######################################
#   SET DEFAULTS FOR MISSING VALUES   #
#######################################

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

echo -e "\n============================================\n"

###########################
#    HELPERS FUNCTIONS    #
###########################


# Draws a single line box around a string
function single_border(){
    text=" $1 "
    edge=$(echo "$text" | sed 's/./-/g')
    echo "+$edge+"
    echo "|$text|"
    echo "+$edge+"
}

function double_border(){
    text=" $1 "
    edge=$(echo "$text" | sed 's/./=/g')
    echo "+$edge+"
    echo "|$text|"
    echo "+$edge+"
}

# The encrypt function takes a file name as a paremeter, then it encrypts the
# file and eventually delete the unencrypted version.
function encrypt()
{
    filename=$1

    echo "Encrypting $filename..."
    # Encrypt the file. 
    # User the --batch and --yes options to avoid prompts
    gpg --batch --yes -r $GPG_KEY_ID -e $filename 

    if [ "$SHRED_CLEAR_BACKUP_FILES" == "yes" ] && [ -f $filename ]; then
        echo "Deleting $filename"
        shred -zu -n 5 $filename
    fi
}


###########################
#    START THE BACKUPS    #
###########################

function perform_backups()
{
	SUFFIX=$1
	FINAL_BACKUP_DIR=$BACKUP_DIR"`date +\%Y-\%m-\%d`$SUFFIX/"

	echo "Making backup directory in $FINAL_BACKUP_DIR..."

	if ! mkdir -p $FINAL_BACKUP_DIR; then
		echo "Cannot create backup directory in $FINAL_BACKUP_DIR. Go and fix it!" 1>&2
		exit 1;
    else
        chmod 775 $FINAL_BACKUP_DIR
        echo "Ok"
    fi;

	#######################
	#   GLOBALS BACKUPS   #
	#######################

    echo -e "\n============================================"

	if [ "$ENABLE_GLOBALS_BACKUPS" == "yes" ]; then
		    echo "Performing globals backup."
            bckp_filename=$FINAL_BACKUP_DIR"globals".sql.gz 
		    if ! pg_dumpall -g -h "$HOSTNAME" -p $PORT -U "$USERNAME" | gzip > $FINAL_BACKUP_DIR"globals".sql.gz.in_progress; then
		            echo "[!!ERROR!!] Failed to produce globals backup" 1>&2
		    else
		        mv $FINAL_BACKUP_DIR"globals".sql.gz.in_progress $bckp_filename
                echo "Database dumped in $bckp_filename"
		    fi
        # Encrypt the backup
        if [ "$ENCRYPT_BACKUP_FILES" = "yes" ] && [ -f $bckp_filename ]; then
            encrypt $bckp_filename            
        fi
	else
		echo "Global backups disabled."
	fi

	###########################
	#   SCHEMA-ONLY BACKUPS   #
	###########################

	for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }
	do
	        SCHEMA_ONLY_CLAUSE="$SCHEMA_ONLY_CLAUSE or datname ~ '$SCHEMA_ONLY_DB'"
	done

	SCHEMA_ONLY_QUERY="select datname from pg_database where false $SCHEMA_ONLY_CLAUSE order by datname;"
    
    echo -e "\n============================================"
	echo "Performing schema-only backups."

	SCHEMA_ONLY_DB_LIST=`psql -h "$HOSTNAME" -p $PORT -U "$USERNAME" -At -c "$SCHEMA_ONLY_QUERY" postgres`

	echo -e "The following databases were matched for schema-only backup:\n${SCHEMA_ONLY_DB_LIST}\n"

	for DATABASE in $SCHEMA_ONLY_DB_LIST
	do
	    echo "Schema-only backup of $DATABASE."

        bckp_filename=FINAL_BACKUP_DIR"$DATABASE"_SCHEMA.sql.gz

	    if ! pg_dump -Fp -s -h "$HOSTNAME" -p $PORT -U "$USERNAME" "$DATABASE" | gzip > $FINAL_BACKUP_DIR"$DATABASE"_SCHEMA.sql.gz.in_progress; then
	        echo "[!!ERROR!!] Failed to backup database schema of $DATABASE." 1>&2
	    else
	        mv $FINAL_BACKUP_DIR"$DATABASE"_SCHEMA.sql.gz.in_progress $bckp_filename
            echo "Database $DATABASE dumped in $bckp_filename."
        fi
        
        # Encrypt the backup
        if [ "$ENCRYPT_BACKUP_FILES" == "yes" ] && [ -f $bckp_filename ]; then
            encrypt $bckp_filename
        fi

	done

	###########################
	#      FULL BACKUPS       #
	###########################

	for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }
	do
		EXCLUDE_SCHEMA_ONLY_CLAUSE="$EXCLUDE_SCHEMA_ONLY_CLAUSE and datname !~ '$SCHEMA_ONLY_DB'"
	done

	FULL_BACKUP_QUERY="SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn $EXCLUDE_SCHEMA_ONLY_CLAUSE ORDER BY datname;"

    echo -e "\n============================================"
	echo "Performing full backups."

	for DATABASE in `psql -h "$HOSTNAME" -U "$USERNAME" -At -c "$FULL_BACKUP_QUERY" postgres`
	do
        echo -e "\n"
        single_border "$DATABASE"
		if [[ $EXCLUDE_LIST =~ $DATABASE ]]; then 
			echo "Skipping $DATABASE database."
			continue
		fi
    
        echo -e "\n--------------------------------------------"
		if [ "$ENABLE_PLAIN_BACKUPS" == "yes" ]; then
			echo "Plain text backup of $DATABASE database."
            bckp_filename=$FINAL_BACKUP_DIR"$DATABASE".sql.gz 

			if ! pg_dump -Fp -h "$HOSTNAME" -p $PORT -U "$USERNAME" "$DATABASE" | gzip > $FINAL_BACKUP_DIR"$DATABASE".sql.gz.in_progress; then
				echo "[!!ERROR!!] Failed to produce plain backup database $DATABASE." 1>&2
			else
				mv $FINAL_BACKUP_DIR"$DATABASE".sql.gz.in_progress $bckp_filename 
                echo "$DATABASE dumped into $bckp_filename."
			fi
            # Encrypt the backup
            if [ $ENCRYPT_BACKUP_FILES == "yes" ] && [ -f $bckp_filename ]; then
                encrypt $bckp_filename
            fi
        else
            echo "Plain text backup is disabled."
        fi

        echo -e "\n--------------------------------------------"
		if [ "$ENABLE_CUSTOM_BACKUPS" == "yes" ]; then
			echo "Custom backup of $DATABASE database."
            bckp_filename=$FINAL_BACKUP_DIR"$DATABASE".custom

			if ! pg_dump -Fc -h "$HOSTNAME" -p $PORT -U "$USERNAME" "$DATABASE" -f $FINAL_BACKUP_DIR"$DATABASE".custom.in_progress; then
				echo "[!!ERROR!!] Failed to produce custom backup database $DATABASE."
			else
				mv $FINAL_BACKUP_DIR"$DATABASE".custom.in_progress $bckp_filename 
                echo "$DATABASE dumped into $bckp_filename."
			fi

            # Encrypt the backup
            if [ "$ENCRYPT_BACKUP_FILES" == "yes" ] && [ -f $bckp_filename ]; then
                encrypt $bckp_filename
            fi
        else
            echo -e "Custom backup is disabled."
		fi
	done

    echo -e "\n--------------------------------------------"
	echo -e "\nAll databases backups done."

	# Display the files saved in the backup directory
    echo -e "\n=================================================="
	echo -e "Showing files in $FINAL_BACKUP_DIR\n"
	ls -lh $FINAL_BACKUP_DIR

}


# MONTHLY BACKUPS

DAY_OF_MONTH=`date +%d`

if [ $DAY_OF_MONTH -eq 1 ];
then
    double_border "MONTHLY BACKUP"

	# Delete all expired monthly directories
    echo "Deleting all expired monthly directories"
	find $BACKUP_DIR -maxdepth 1 -name "*-monthly" -exec rm -rf '{}' ';'

	perform_backups "-monthly"

	exit 0;
fi

# WEEKLY BACKUPS

DAY_OF_WEEK=`date +%u` #1-7 (Monday-Sunday)
EXPIRED_DAYS=`expr $((($WEEKS_TO_KEEP * 7) + 1))`

if [ $DAY_OF_WEEK = $DAY_OF_WEEK_TO_KEEP ];
then
    double_border "WEEKLY BACKUP"
    
    # Delete all expired weekly directories 
    echo "Deleting all expired weekly directories"
    find $BACKUP_DIR -maxdepth 1 -mtime +$EXPIRED_DAYS -name "*-weekly" -exec rm -rf '{}' ';'

	perform_backups "-weekly"

	exit 0;
fi

# DAILY BACKUPS
double_border "DAILY BACKUP"

# Delete daily backups 7 days old or more
echo "Deleting all the backups older than $DAYS_TO_KEEP day(s)"
find $BACKUP_DIR -maxdepth 1 -mtime +$DAYS_TO_KEEP -name "*-daily" -exec rm -rf '{}' ';'

perform_backups "-daily"

echo -e "\n=================================================="
ELAPSED_TIME=$(($SECONDS - $START_TIME))
echo "The backup took $(($ELAPSED_TIME/60)) min $(($ELAPSED_TIME%60)) sec"

