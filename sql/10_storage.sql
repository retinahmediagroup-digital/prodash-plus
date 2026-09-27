/* ============================================================
   ProDash+ | 10_storage.sql
   Private bucket for original CSV drops (SSOT §10.1, §13). Files
   are uploaded through signed upload URLs issued by the backend,
   so no storage.objects policies are granted to users.
   Path convention: <client_id>/<branch_id|ALL>/<yyyy-mm-dd>/<sha256>.csv
   Safe to re-run.
   ============================================================ */

do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('raw-uploads', 'raw-uploads', false, 52428800,
            array['text/csv','application/vnd.ms-excel','text/plain'])
    on conflict (id) do update
      set public             = false,
          file_size_limit    = excluded.file_size_limit,
          allowed_mime_types = excluded.allowed_mime_types;
  end if;
end $$;
