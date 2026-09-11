# urali server files

Upload everything in this folder to the root of `anup-aws/urali-site`, keeping the `server/` folder:

- `index.html`: the landing page, pointed at `https://urali.anups.cloud/api`
- `server/setup-urali-api.sh`: installs Postgres 16, PostgREST, the Nginx `/api` route, and daily backups
- `server/db/*.sql`: database roles, schema, reserve function, security rules, and scheduled jobs

No passwords or keys are stored in these files. The database password is generated on the server during setup.
