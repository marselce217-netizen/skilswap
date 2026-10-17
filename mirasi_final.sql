
-- SKILLSWAP — MIGRASI DATABASE UTAMA
-- File: migrasi_final.sql
-- Pengganti seluruh isi file lama.
--
-- PERINGATAN:
-- 1. Jangan jalankan sebelum struktur tabel lama diperiksa.
-- 2. Jangan jalankan rollback untuk mencoba-coba.
-- 3. Migrasi ini sengaja memakai pemeriksaan awal agar berhenti
--    jika struktur inti tidak cocok.

begin;

-- =========================================================
-- M00 — PEMERIKSAAN AWAL
-- =========================================================

do $$
declare
  missing_items text := '';
begin
  if to_regclass('public.profiles') is null then
    missing_items := missing_items || ' public.profiles;';
  end if;

  if to_regclass('public.user_skills') is null then
    missing_items := missing_items || ' public.user_skills;';
  end if;

  if to_regclass('public.skill_swap_requests') is null then
    missing_items := missing_items || ' public.skill_swap_requests;';
  end if;

  if missing_items <> '' then
    raise exception
      'Migrasi dibatalkan. Tabel inti tidak ditemukan:%',
      missing_items;
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'profiles'
      and column_name = 'id'
  ) then
    raise exception 'Kolom profiles.id tidak ditemukan.';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'user_skills'
      and column_name = 'user_id'
  ) then
    raise exception 'Kolom user_skills.user_id tidak ditemukan.';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'user_skills'
      and column_name = 'skill_name'
  ) then
    raise exception 'Kolom user_skills.skill_name tidak ditemukan.';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'user_skills'
      and column_name = 'skill_type'
  ) then
    raise exception 'Kolom user_skills.skill_type tidak ditemukan.';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'skill_swap_requests'
      and column_name = 'sender_id'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'skill_swap_requests'
      and column_name = 'receiver_id'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'skill_swap_requests'
      and column_name = 'status'
  ) then
    raise exception
      'Struktur skill_swap_requests tidak cocok. Migrasi dibatalkan.';
  end if;

  if exists (
    select 1 from public.skill_swap_requests
    where sender_id = receiver_id
  ) then
    raise exception
      'Ditemukan permintaan Swap kepada diri sendiri. Periksa data terlebih dahulu.';
  end if;

  if exists (
    select 1
    from public.user_skills
    group by user_id, lower(trim(skill_name)), skill_type
    having count(*) > 1
  ) then
    raise exception
      'Ada skill duplikat. Bersihkan duplikat sebelum migrasi.';
  end if;

  if exists (
    select 1
    from public.skill_swap_requests
    where status = 'accepted'
    group by least(sender_id::text, receiver_id::text),
             greatest(sender_id::text, receiver_id::text)
    having count(*) > 1
  ) then
    raise exception
      'Ada lebih dari satu Swap accepted untuk pasangan pengguna yang sama.';
  end if;

  if not exists (
    select 1 from pg_class
    where oid = 'public.profiles'::regclass
      and relrowsecurity
  ) then
    raise exception 'RLS profiles belum aktif.';
  end if;

  if not exists (
    select 1 from pg_class
    where oid = 'public.user_skills'::regclass
      and relrowsecurity
  ) then
    raise exception 'RLS user_skills belum aktif.';
  end if;

  if not exists (
    select 1 from pg_class
    where oid = 'public.skill_swap_requests'::regclass
      and relrowsecurity
  ) then
    raise exception 'RLS skill_swap_requests belum aktif.';
  end if;
end;
$$;

-- =========================================================
-- M01 — STATUS DAN PENYELESAIAN SWAP
-- =========================================================

alter table public.skill_swap_requests
  add column if not exists completion_requested_by uuid;

alter table public.skill_swap_requests
  add column if not exists completed_at timestamptz;

-- Hapus hanya constraint CHECK lama yang definisinya
-- berkaitan dengan kolom status, agar status completed
-- tidak bertentangan dengan aturan lama.
do $$
declare
  item record;
begin
  for item in
    select conname
    from pg_constraint
    where conrelid = 'public.skill_swap_requests'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute format(
      'alter table public.skill_swap_requests drop constraint %I',
      item.conname
    );
  end loop;
end;
$$;

alter table public.skill_swap_requests
  add constraint skillswap_status_valid
  check (
    status in (
      'pending',
      'accepted',
      'rejected',
      'cancelled',
      'completed'
    )
  );

alter table public.skill_swap_requests
  add constraint skillswap_completion_valid
  check (
    (
      status = 'completed'
      and completed_at is not null
      and completion_requested_by is not null
    )
    or
    (
      status <> 'completed'
      and completed_at is null
    )
  );

-- Mencegah lebih dari satu Swap aktif untuk pasangan sama.
create unique index if not exists uniq_pending_swap_pair
on public.skill_swap_requests (
  (least(sender_id::text, receiver_id::text)),
  (greatest(sender_id::text, receiver_id::text))
)
where status = 'pending';

create unique index if not exists uniq_accepted_swap_pair
on public.skill_swap_requests (
  (least(sender_id::text, receiver_id::text)),
  (greatest(sender_id::text, receiver_id::text))
)
where status = 'accepted';

-- =========================================================
-- M02 — VALIDASI PERUBAHAN STATUS SWAP
-- =========================================================

create or replace function public.swap_before_insert()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  pending_count integer;
begin
  if actor is null or actor <> new.sender_id then
    raise exception 'SWAP_PENGIRIM_TIDAK_VALID';
  end if;

  if new.sender_id = new.receiver_id then
    raise exception 'SWAP_TIDAK_BOLEH_KE_DIRI_SENDIRI';
  end if;

  if new.status <> 'pending' then
    raise exception 'SWAP_HARUS_DIMULAI_DENGAN_PENDING';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(actor::text, 731)
  );

  perform pg_advisory_xact_lock(
    hashtextextended(
      least(new.sender_id::text, new.receiver_id::text)
      || ':'
      || greatest(new.sender_id::text, new.receiver_id::text),
      732
    )
  );

  if exists (
    select 1
    from public.skill_swap_requests s
    where least(s.sender_id::text, s.receiver_id::text)
        = least(new.sender_id::text, new.receiver_id::text)
      and greatest(s.sender_id::text, s.receiver_id::text)
        = greatest(new.sender_id::text, new.receiver_id::text)
      and s.status = 'accepted'
  ) then
    raise exception 'SWAP_PASANGAN_SUDAH_AKTIF';
  end if;

  select count(*)
  into pending_count
  from public.skill_swap_requests s
  where s.sender_id = actor
    and s.status = 'pending';

  if pending_count >= 20 then
    raise exception 'BATAS_SWAP_PENDING_TERCAPAI';
  end if;

  new.completion_requested_by := null;
  new.completed_at := null;

  return new;
end;
$$;

create or replace function public.swap_before_update()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
begin
  if new.id is distinct from old.id
     or new.sender_id is distinct from old.sender_id
     or new.receiver_id is distinct from old.receiver_id
     or new.created_at is distinct from old.created_at
  then
    raise exception 'SWAP_IDENTITAS_TIDAK_BOLEH_DIUBAH';
  end if;

  if old.status in ('completed', 'rejected', 'cancelled') then
    raise exception 'SWAP_SUDAH_FINAL';
  end if;

  if old.status = 'pending' then
    if actor = old.receiver_id
       and new.status in ('accepted', 'rejected')
       and new.completion_requested_by is not distinct from old.completion_requested_by
    then
      new.completed_at := null;
      return new;
    elsif actor = old.sender_id
       and new.status = 'cancelled'
       and new.completion_requested_by is not distinct from old.completion_requested_by
    then
      new.completed_at := null;
      return new;
    else
      raise exception 'AKSI_SWAP_PENDING_TIDAK_DIIZINKAN';
    end if;
  end if;

  if old.status = 'accepted' then
    if new.status <> 'accepted' then
      raise exception 'STATUS_SWAP_ACCEPTED_TIDAK_BOLEH_DIUBAH_LANGSUNG';
    end if;

    if new.completion_requested_by is not distinct from old.completion_requested_by then
      new.completed_at := old.completed_at;
      return new;
    end if;

    if old.completion_requested_by is null
       and new.completion_requested_by = actor
       and actor in (old.sender_id, old.receiver_id)
    then
      new.completed_at := null;
      return new;
    end if;

    if old.completion_requested_by = actor
       and new.completion_requested_by is null
       and actor in (old.sender_id, old.receiver_id)
    then
      new.completed_at := null;
      return new;
    end if;

    if old.completion_requested_by is not null
       and new.completion_requested_by is null
       and actor in (old.sender_id, old.receiver_id)
       and actor <> old.completion_requested_by
    then
      new.completed_at := null;
      return new;
    end if;

    if old.completion_requested_by is not null
       and new.status = 'completed'
       and new.completion_requested_by = old.completion_requested_by
       and actor in (old.sender_id, old.receiver_id)
       and actor <> old.completion_requested_by
    then
      new.completed_at := now();
      return new;
    end if;

    raise exception 'AKSI_PENYELESAIAN_SWAP_TIDAK_DIIZINKAN';
  end if;

  raise exception 'TRANSISI_STATUS_TIDAK_VALID';
end;
$$;

drop trigger if exists swap_before_insert_trg
  on public.skill_swap_requests;

create trigger swap_before_insert_trg
before insert on public.skill_swap_requests
for each row execute function public.swap_before_insert();

drop trigger if exists swap_before_update_trg
  on public.skill_swap_requests;

create trigger swap_before_update_trg
before update on public.skill_swap_requests
for each row execute function public.swap_before_update();

drop policy if exists swap_participant_update
  on public.skill_swap_requests;

create policy swap_participant_update
on public.skill_swap_requests
for update to authenticated
using (
  auth.uid() in (sender_id, receiver_id)
  and status in ('pending', 'accepted')
)
with check (
  auth.uid() in (sender_id, receiver_id)
);

-- =========================================================
-- M03 — VALIDASI PROFIL
-- =========================================================

create table if not exists public.backup_profile_avatar_urls (
  id uuid,
  avatar_url text,
  backed_up_at timestamptz not null default now()
);

alter table public.backup_profile_avatar_urls
  enable row level security;

revoke all on public.backup_profile_avatar_urls
  from anon, authenticated;

-- Simpan URL lama sebelum migrasi. Tidak menghapus data profil.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'profiles'
      and column_name = 'avatar_url'
  ) then
    execute $sql$
      insert into public.backup_profile_avatar_urls (
        id, avatar_url
      )
      select p.id, p.avatar_url
      from public.profiles p
      where p.avatar_url is not null
        and not exists (
          select 1
          from public.backup_profile_avatar_urls b
          where b.id = p.id
            and b.avatar_url = p.avatar_url
        )
    $sql$;
  end if;
end;
$$;

create or replace function public.profiles_before_update()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.id is distinct from old.id then
    raise exception 'ID_PROFIL_TIDAK_BOLEH_DIUBAH';
  end if;

  if new.created_at is distinct from old.created_at then
    raise exception 'WAKTU_PROFIL_TIDAK_BOLEH_DIUBAH';
  end if;

  if new.updated_at is not distinct from old.updated_at then
    new.updated_at := now();
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_before_update_trg
  on public.profiles;

create trigger profiles_before_update_trg
before update on public.profiles
for each row execute function public.profiles_before_update();

-- =========================================================
-- M04 — VALIDASI SKILL
-- =========================================================

alter table public.user_skills
  drop constraint if exists user_skills_name_valid;

alter table public.user_skills
  add constraint user_skills_name_valid
  check (
    char_length(trim(skill_name)) between 1 and 60
    and skill_type in ('offered', 'wanted')
  );

create unique index if not exists uniq_user_skills_name_type
on public.user_skills (
  user_id,
  lower(trim(skill_name)),
  skill_type
);

create or replace function public.user_skills_before_insert()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  skill_count integer;
begin
  if auth.uid() is null or auth.uid() <> new.user_id then
    raise exception 'SKILL_HANYA_BOLEH_DITAMBAHKAN_KE_AKUN_SENDIRI';
  end if;

  new.skill_name := trim(new.skill_name);

  if char_length(new.skill_name) < 1
     or char_length(new.skill_name) > 60 then
    raise exception 'PANJANG_NAMA_SKILL_TIDAK_VALID';
  end if;

  if new.skill_type not in ('offered', 'wanted') then
    raise exception 'JENIS_SKILL_TIDAK_VALID';
  end if;

  select count(*)
  into skill_count
  from public.user_skills s
  where s.user_id = new.user_id
    and s.skill_type = new.skill_type;

  if skill_count >= 30 then
    raise exception 'BATAS_SKILL_TERCAPAI';
  end if;

  return new;
end;
$$;

drop trigger if exists user_skills_before_insert_trg
  on public.user_skills;

create trigger user_skills_before_insert_trg
before insert on public.user_skills
for each row execute function public.user_skills_before_insert();

drop policy if exists "Users can update own skills"
  on public.user_skills;

-- =========================================================
-- M05 — PROFIL YANG DILEWATI
-- =========================================================

create table if not exists public.skipped_profiles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  skipped_user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint skipped_profiles_no_self
    check (user_id <> skipped_user_id),
  constraint skipped_profiles_unique
    unique (user_id, skipped_user_id)
);

alter table public.skipped_profiles enable row level security;

drop policy if exists skipped_profiles_select_own
  on public.skipped_profiles;
drop policy if exists skipped_profiles_insert_own
  on public.skipped_profiles;
drop policy if exists skipped_profiles_delete_own
  on public.skipped_profiles;

create policy skipped_profiles_select_own
on public.skipped_profiles
for select to authenticated
using (auth.uid() = user_id);

create policy skipped_profiles_insert_own
on public.skipped_profiles
for insert to authenticated
with check (auth.uid() = user_id);

create policy skipped_profiles_delete_own
on public.skipped_profiles
for delete to authenticated
using (auth.uid() = user_id);

create or replace function public.skipped_profiles_before_insert()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  skip_count integer;
begin
  if auth.uid() is null or auth.uid() <> new.user_id then
    raise exception 'SKIP_HANYA_BOLEH_DILAKUKAN_PENGGUNA_SENDIRI';
  end if;

  select count(*)
  into skip_count
  from public.skipped_profiles s
  where s.user_id = new.user_id;

  if skip_count >= 1000 then
    raise exception 'BATAS_SKIP_TERCAPAI';
  end if;

  return new;
end;
$$;

drop trigger if exists skipped_profiles_before_insert_trg
  on public.skipped_profiles;

create trigger skipped_profiles_before_insert_trg
before insert on public.skipped_profiles
for each row execute function public.skipped_profiles_before_insert();

-- =========================================================
-- M06 — PESAN CHAT
-- =========================================================

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  swap_request_id uuid not null
    references public.skill_swap_requests(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now()
);

alter table public.messages enable row level security;

drop policy if exists messages_select_participants
  on public.messages;
drop policy if exists messages_insert_participants
  on public.messages;

create policy messages_select_participants
on public.messages
for select to authenticated
using (
  exists (
    select 1
    from public.skill_swap_requests s
    where s.id = messages.swap_request_id
      and s.status = 'accepted'
      and auth.uid() in (s.sender_id, s.receiver_id)
  )
);

create policy messages_insert_participants
on public.messages
for insert to authenticated
with check (
  auth.uid() = sender_id
  and char_length(trim(body)) between 1 and 2000
  and exists (
    select 1
    from public.skill_swap_requests s
    where s.id = messages.swap_request_id
      and s.status = 'accepted'
      and auth.uid() in (s.sender_id, s.receiver_id)
  )
);

create or replace function public.messages_before_insert()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  recent_count integer;
begin
  if actor is null or actor <> new.sender_id then
    raise exception 'PENGIRIM_PESAN_TIDAK_VALID';
  end if;

  new.body := trim(new.body);

  if char_length(new.body) < 1
     or char_length(new.body) > 2000 then
    raise exception 'PANJANG_PESAN_TIDAK_VALID';
  end if;

  if not exists (
    select 1
    from public.skill_swap_requests s
    where s.id = new.swap_request_id
      and s.status = 'accepted'
      and actor in (s.sender_id, s.receiver_id)
  ) then
    raise exception 'CHAT_MEMERLUKAN_SWAP_ACCEPTED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(actor::text, 733)
  );

  select count(*)
  into recent_count
  from public.messages m
  where m.sender_id = actor
    and m.created_at > now() - interval '1 minute';

  if recent_count >= 30 then
    raise exception 'BATAS_PESAN_PER_MENIT_TERCAPAI';
  end if;

  return new;
end;
$$;

drop trigger if exists messages_before_insert_trg
  on public.messages;

create trigger messages_before_insert_trg
before insert on public.messages
for each row execute function public.messages_before_insert();

-- =========================================================
-- M07 — RLS DAN IZIN AKSES
-- =========================================================

alter table public.skipped_profiles
  enable row level security;

alter table public.messages
  enable row level security;

-- Tidak memberikan akses API kepada anon pada tabel ini.
revoke all on public.profiles from anon;
revoke all on public.user_skills from anon;
revoke all on public.skill_swap_requests from anon;
revoke all on public.skipped_profiles from anon;
revoke all on public.messages from anon;
revoke all on public.backup_profile_avatar_urls from anon;

-- Hapus izin tabel luas sebelum memberi izin yang diperlukan.
revoke all on public.profiles from authenticated;
revoke all on public.user_skills from authenticated;
revoke all on public.skill_swap_requests from authenticated;
revoke all on public.skipped_profiles from authenticated;
revoke all on public.messages from authenticated;

-- Profil: baca oleh pengguna login.
grant select on public.profiles to authenticated;

-- Hanya izinkan pembaruan kolom profil yang biasa dipakai.
do $$
declare
  allowed_columns text;
begin
  select string_agg(format('%I', column_name), ', ')
  into allowed_columns
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'profiles'
    and column_name in (
      'display_name',
      'username',
      'bio',
      'country',
      'avatar_url',
      'updated_at'
    );

  if allowed_columns is not null then
    execute 'grant update (' || allowed_columns
      || ') on public.profiles to authenticated';
  end if;
end;
$$;

grant select, insert, delete
on public.user_skills to authenticated;

grant select, insert
on public.skill_swap_requests to authenticated;

grant update (status, completion_requested_by, completed_at)
on public.skill_swap_requests to authenticated;

grant select, insert, delete
on public.skipped_profiles to authenticated;

grant select, insert
on public.messages to authenticated;

-- Fungsi trigger tidak boleh dipanggil langsung oleh pengguna.
revoke execute on function public.swap_before_insert()
  from public, anon, authenticated;
revoke execute on function public.swap_before_update()
  from public, anon, authenticated;
revoke execute on function public.profiles_before_update()
  from public, anon, authenticated;
revoke execute on function public.user_skills_before_insert()
  from public, anon, authenticated;
revoke execute on function public.skipped_profiles_before_insert()
  from public, anon, authenticated;
revoke execute on function public.messages_before_insert()
  from public, anon, authenticated;

notify pgrst, 'reload schema';

commit;
