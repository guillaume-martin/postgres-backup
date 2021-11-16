# Installation

```sh
git clone
```

# Configuration

## Backup config

```sh
cp pg_backup.config.template pg_backup.config
```

Setup the variables

## .pgpass
`~/.pgpass` is the file where the PostgreSQL credentials are saved.

For each server and user, add the following line:
```
<host>:5432:*:<username>:<password>
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


# More details

To get more details on how to backup your database, read my blog post [PostgreSQL database backup in Linux](https://guillaume-martin.github.io/postgresql-backup.html)

