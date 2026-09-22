# urali update 005 — automatic batches and an admin page

Upload these four files to the top level of `anup-aws/urali-site`, replacing `index.html`:

- `005_urali_rollover_admin.sql`
- `update-urali-005.sh`
- `admin.html`
- `index.html`

Then run in the VPS web console:

    curl -fsSL "https://raw.githubusercontent.com/anup-aws/urali-site/main/update-urali-005.sh?r=$RANDOM" -o /root/update-urali-005.sh && bash /root/update-urali-005.sh 2>&1 | tee /root/urali-update-005.log

It prints the admin address, username and a generated password at the end. Save the password
somewhere safe — it is shown once and nowhere else. Don't paste it into a chat.

To change the password later: `bash /root/update-urali-005.sh --reset-password`

## What changes

**Batches run themselves.** A maintenance job runs every ten minutes as a systemd timer, so it
does not depend on pg_cron. Each run creates new Wednesday batches, releases expired payment
holds, marks past batches as fried, and rolls unfilled batches forward.

**Rollover.** When a batch's cutoff passes without reaching its target, every live reservation
moves to the next batch that has room. Counts on both batches update, so the boxes are never
counted twice. A reservation carries `rollover_count` and `original_batch_id`, and after three
moves it stops and the batch is marked "needs attention" instead.

**The page shows one batch.** `batchesShown` is now 1, so customers see only the batch that is
open. Set it back to 3 in `CONFIG` if you want the three-week view again.

**Admin page** at `https://uralichips.com/admin/`, behind a login:

- Batches, with progress to target and time to cutoff
- Orders, with search and filters, and buttons to mark paid, mark delivered, move or cancel
- Kitchen sheet per batch, with kilos to fry, copyable as text
- Delivery run grouped by area, copyable as text
- Traffic: visitors, funnel and where orders came from

The admin API is a second PostgREST on localhost, reachable only through Nginx behind the
login. The public API cannot see any admin view.
