
-- SKILLSWAP — ROLLBACK ATURAN TAMBAHAN
-- Menghapus trigger, kebijakan, dan batasan yang ditambahkan
-- oleh migrasi. Data messages dan skipped_profiles dipertahankan.
--
-- PERHATIAN:
-- Rollback tidak dapat menjamin pemulihan semua izin lama
-- jika kebijakan atau izin sebelum migrasi sudah berbeda.
-- Periksa hasil verifikasi sebelum menjalankan file ini.

begin;

-- Hapus trigger tambahan.
drop trigger if exists swap_before_update_trg
  on public.skill_swap_requests;
drop trigger if exists swap_before_insert_trg
  on public.skill_swap_requests;
drop trigger if exists profiles_before_update_trg
  on public.profiles;
drop trigger if exists user_skills_before_insert_trg
  on public.user_skills;
drop trigger if exists skipped_profiles_before_insert_trg
  on public.skipped_profiles;
drop trigger if exists messages_before_insert_trg
  on public.messages;

-- Hapus fungsi trigger tambahan.
drop function if exists public.swap_before_update();
drop function if exists public.swap_before_insert();
drop function if exists public.profiles_before_update();
drop function if exists public.user_skills_before_insert();
drop function if exists public.skipped_profiles_before_insert();
drop function if exists public.messages_before_insert();

-- Hapus kebijakan tambahan.
drop policy if exists swap_participant_update
  on public.skill_swap_requests;

drop policy if exists profiles_select_authenticated
  on public.profiles;

drop policy if exists skipped_profiles_select_own
  on public.skipped_profiles;
drop policy if exists skipped_profiles_insert_own
  on public.skipped_profiles;
drop policy if exists skipped_profiles_delete_own
  on public.skipped_profiles;

drop policy if exists messages_select_participants
  on public.messages;
drop policy if exists messages_insert_participants
  on public.messages;

-- Hapus batasan dan indeks tambahan yang dibuat migrasi.
alter table public.skill_swap_requests
  drop constraint if exists skillswap_status_valid;
alter table public.skill_swap_requests
  drop constraint if exists skillswap_completion_valid;

alter table public.user_skills
  drop constraint if exists user_skills_name_valid;

drop index if exists public.uniq_pending_swap_pair;
drop index if exists public.uniq_accepted_swap_pair;
drop index if exists public.uniq_user_skills_name_type;

-- Pertahankan tabel dan seluruh data pengguna.
-- Jangan menghapus messages, skipped_profiles,
-- backup_profile_avatar_urls, atau foto Storage.

notify pgrst, 'reload schema';

commit;

-- Catatan:
-- File ini tidak memulihkan seluruh kebijakan dan izin lama
-- secara otomatis. Cocokkan dengan backup/skema sebelumnya
-- sebelum menggunakannya pada database produksi.
