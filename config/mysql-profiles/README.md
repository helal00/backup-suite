# MySQL Profiles

Store one MySQL client credential file per profile in this directory.

Examples:
- default.cnf
- shop.cnf
- blog.cnf

Each database backup row in `database-backups.conf` references the profile name without the `.cnf` suffix.

Only `*.example` files should be committed. Copy them locally when preparing a real deployment.
