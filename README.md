# PostgreSQL Backup

This PosgtreSQL backup script is a simple script built using `pg_dump` and `pg_dumpall` to generate backups of a PostgreSQL cluster.  
Features:
- Can backup globals (users, roles, etc...).
- Backup of schema only for selected databases.
- Option to encrypt the backup files with GPG.
- All the backup files of each database are stored in a compressed tar archive.
- A SHA256 hash of the backup file is generated to control the backup file integrity after extracting and decrypting it.

# Installation

```sh
git clone git@github.com:guillaume-martin/postgres-backup.git
```

# Configuration

## Backup config

Create a `pg_backup.config` file from the template.
```sh
cp pg_backup.config.template pg_backup.config
```

Setup the variables in the config file.


## .pgpass

`~/.pgpass` is the file where the PostgreSQL credentials are saved.

For each server and user, add the following line:
```
<host>:5432:<database>:<username>:<password>
```

Example:
```
localhost:5432:*:postgres:password123
```

## Cronjob

Create a cronjob to run the backup script on a regular basis.
```sh
crontab -e
```

Ex: 
Backing up every day at 23:00
```
00 23 * * * /path/to/pg_backup_rotated.sh -c /path/to/pg_backup.config
```

Check https://crontab.cronhub.io/ if you need help setting the scheduling of the cronjob.


## Save output to a log file

To have the script's output saved to a file, add `2>&1 | tee /path/to/file.log` to the cron job's command:
```
00 23 * * * /path/to/pg_backup_rotated.sh -c /path/to/pg_backup.config 2>&1 | tee /path/to/logs/file.log
```

## Send the backup log by email

It is possible to have the content of the log file sent by email. It requires that `mailutils` be installed on the server.
To send the logs by email, add `| mailx -s "Email's subject" alice@example.com`.
```
00 23 * * * /path/to/pg_backup_rotated.sh -c /path/to/pg_backup.config 2>&1 | tee /path/to/file.log | mailx -s "Email's subject" alice@example.com`
```


# More details

To get more details on how to backup your database, read my blog post [PostgreSQL database backup in Linux](https://guillaume-martin.github.io/postgresql-backup.html)

