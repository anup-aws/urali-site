# urali update 003

Upload these files to the top level of `anup-aws/urali-site` (replace `index.html`):

- `003_urali_protection_analytics.sql`: spam limits, IP and device capture, analytics events, admin views
- `update-urali-003.sh`: applies the database update, tightens the Nginx API routes, runs QA, then updates the live page only if QA passes
- `qa-urali.sh`: 25 automatic checks. It uses a hidden far-future batch and cancels every test order.
- `index.html`: page with a honeypot field, submit timing, visit details and funnel events

Then run in the VPS web console:

    curl -fsSL https://raw.githubusercontent.com/anup-aws/urali-site/main/update-urali-003.sh -o /root/update-urali-003.sh && bash /root/update-urali-003.sh 2>&1 | tee /root/urali-update-003.log

Useful queries afterwards:

    runuser -u postgres -- psql -d urali -c "select * from admin_orders limit 20;"
    runuser -u postgres -- psql -d urali -c "select * from admin_funnel_daily limit 14;"
