-- Scheduled jobs (pg_cron runs in UTC; 19:30 UTC = 01:00 IST)
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname like 'urali-%';
select cron.schedule('urali-ensure-batches', '30 19 * * *',  $$select public.ensure_batches()$$);
select cron.schedule('urali-close-unfilled', '*/15 * * * *', $$select public.close_unfilled_batches()$$);
select cron.schedule('urali-expire-unpaid',  '5 * * * *',    $$select public.expire_unpaid()$$);
