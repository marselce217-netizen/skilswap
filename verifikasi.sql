
-- SKILLSWAP — VERIFIKASI DATABASE
-- Hanya membaca informasi. Tidak mengubah data.

-- 1. Status RLS seluruh tabel public.
select
  'RLS' as kategori,
  n.nspname || '.' || c.relname as objek,
  case
    when c.relrowsecurity then 'AKTIF'
    else 'TIDAK AKTIF'
  end as detail
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind in ('r', 'p')

union all

-- 2. Kebijakan akses public.
select
  'POLICY' as kategori,
  schemaname || '.' || tablename as objek,
  policyname || ' | ' || cmd || ' | roles='
    || array_to_string(roles, ',') as detail
from pg_policies
where schemaname = 'public'

union all

-- 3. Kebijakan Storage.
select
  'STORAGE POLICY' as kategori,
  schemaname || '.' || tablename as objek,
  policyname || ' | ' || cmd || ' | roles='
    || array_to_string(roles, ',') as detail
from pg_policies
where schemaname = 'storage'
  and tablename = 'objects'
  and policyname like 'avatars_%'

union all

-- 4. Trigger pada tabel public.
select
  'TRIGGER' as kategori,
  event_object_schema || '.' || event_object_table as objek,
  trigger_name || ' | ' || event_manipulation as detail
from information_schema.triggers
where event_object_schema = 'public'

union all

-- 5. Indeks terkait migrasi.
select
  'INDEX' as kategori,
  schemaname || '.' || tablename as objek,
  indexname as detail
from pg_indexes
where schemaname = 'public'
  and indexname like 'uniq_%'

union all

-- 6. Izin akses tabel.
select
  'TABLE GRANT' as kategori,
  table_schema || '.' || table_name as objek,
  grantee || ' | ' || string_agg(
    privilege_type, ', ' order by privilege_type
  ) as detail
from information_schema.role_table_grants
where table_schema = 'public'
  and grantee in ('anon', 'authenticated')
group by table_schema, table_name, grantee

union all

-- 7. Izin update tingkat kolom.
select
  'COLUMN UPDATE' as kategori,
  table_schema || '.' || table_name as objek,
  grantee || ' | ' || string_agg(
    column_name, ', ' order by column_name
  ) as detail
from information_schema.column_privileges
where table_schema = 'public'
  and grantee = 'authenticated'
  and privilege_type = 'UPDATE'
group by table_schema, table_name, grantee

union all

-- 8. Pengaturan bucket foto.
select
  'BUCKET' as kategori,
  b.id as objek,
  'public=' || b.public::text
    || ' | batas=' || coalesce(b.file_size_limit::text, '-')
    || ' | mime=' || coalesce(b.allowed_mime_types::text, '-') as detail
from storage.buckets b
where b.id = 'avatars'

order by kategori, objek, detail;
