
-- SKILLSWAP — MIGRASI STORAGE FOTO PROFIL
-- Bucket privat: avatars
-- Batas unggahan: 1 MB
-- Format: JPEG
-- Jalankan hanya setelah migrasi database utama berhasil diperiksa.

begin;

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'avatars',
  'avatars',
  false,
  1048576,
  array['image/jpeg']::text[]
)
on conflict (id) do update
set
  name = excluded.name,
  public = false,
  file_size_limit = 1048576,
  allowed_mime_types = array['image/jpeg']::text[];

drop policy if exists avatars_select_own
  on storage.objects;
drop policy if exists avatars_insert_own
  on storage.objects;
drop policy if exists avatars_update_own
  on storage.objects;
drop policy if exists avatars_delete_own
  on storage.objects;
drop policy if exists avatars_select_authenticated
  on storage.objects;
drop policy if exists avatars_insert_own_folder
  on storage.objects;
drop policy if exists avatars_delete_own_folder
  on storage.objects;

create policy avatars_select_authenticated
on storage.objects
for select
to authenticated
using (
  bucket_id = 'avatars'
);

create policy avatars_insert_own_folder
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'avatars'
  and name ~ (
    '^'
    || (select auth.uid())::text
    || '/[0-9]{10,16}\.jpg$'
  )
);

create policy avatars_delete_own_folder
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1]
      = (select auth.uid())::text
);

commit;
