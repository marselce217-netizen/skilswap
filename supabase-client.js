// Konfigurasi koneksi Supabase — dipakai bersama oleh index.html dan login.html

const SUPABASE_URL = "https://zztdytaiunmpbsukbbhw.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_xVfQXVdoNt8AXm-g94gRBQ_XZMbJVKR";

const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
