#!/usr/bin/env bash
# db/01..03 dosyalarını, başına sıfırlama bloğu ekleyerek tek bir dosyada birleştirir:
#   test/antalya-test-db.sql
# Bu dosya mevcut tabloları ve fn_* fonksiyonlarını SİLER; sadece test veritabanında kullanın.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=test/antalya-test-db.sql
{
  cat <<'SQL'
-- =====================================================================
-- A1 Acente Otomasyonu - Antalya test veritabanı (TEK DOSYA)
--
-- DİKKAT: Mevcut rezervasyon tabloları ve fn_* fonksiyonları silinip
-- yeniden oluşturulur. Sadece test veritabanında çalıştırın.
--
-- Bu dosya test/build_antalya_db.sh ile db/01_schema.sql,
-- db/02_functions.sql ve db/03_seed.sql dosyalarından üretilir;
-- elle düzenlemeyin.
-- =====================================================================
BEGIN;

DROP TABLE IF EXISTS reservations, room_rates, room_types, hotels, app_settings CASCADE;
DO $$
DECLARE
    f record;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = current_schema() AND p.proname LIKE 'fn\_%'
    LOOP
        EXECUTE 'DROP FUNCTION ' || f.sig || ' CASCADE';
    END LOOP;
END $$;

SQL
  for f in db/01_schema.sql db/02_functions.sql db/03_seed.sql; do
    printf '\n-- >>> %s\n' "$f"
    cat "$f"
  done
  printf '\nCOMMIT;\n'
} > "$OUT"
echo "$OUT yazıldı"
