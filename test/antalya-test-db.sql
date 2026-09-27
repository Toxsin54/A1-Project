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


-- >>> db/01_schema.sql
-- =====================================================================
-- A1 Acente Otomasyonu - Veritabanı şeması (PostgreSQL 13+)
-- =====================================================================

-- Genel ayarlar (firma adı, SMS imzası vb.)
CREATE TABLE IF NOT EXISTS app_settings (
    key   text PRIMARY KEY,
    value text NOT NULL
);

-- Oteller
CREATE TABLE IF NOT EXISTS hotels (
    id          serial PRIMARY KEY,
    code        text    NOT NULL UNIQUE,                   -- kısa kod: lara-deniz
    name        text    NOT NULL,                          -- müşteriye söylenecek ad
    region      text    NOT NULL,                          -- bölge: Lara, Belek, Kemer...
    stars       int     CHECK (stars BETWEEN 1 AND 5),     -- butik otellerde boş olabilir
    board_type  text    NOT NULL,                          -- konsept: Ultra Her Şey Dahil, Oda Kahvaltı...
    description text,
    features    text[]  NOT NULL DEFAULT '{}',             -- "özel plaj", "aquapark" ...
    aliases     text[]  NOT NULL DEFAULT '{}',             -- müşterinin kullanabileceği kısa adlar
    active      boolean NOT NULL DEFAULT true,
    sort_order  int     NOT NULL DEFAULT 0
);

-- Oda tipleri ve stok (her tipten kaç oda satılabilir)
CREATE TABLE IF NOT EXISTS room_types (
    id              serial PRIMARY KEY,
    hotel_id        int         NOT NULL REFERENCES hotels(id),
    code            text        NOT NULL UNIQUE,           -- tüm otellerde tekil kod: lara-deniz-deluxe
    category        text        NOT NULL,                  -- genel tip: standart, deluxe, aile, suit, villa...
    name            text        NOT NULL,                  -- müşteriye söylenecek ad
    description     text,
    features        text[]      NOT NULL DEFAULT '{}',     -- "deniz manzarası", "balkon" ...
    aliases         text[]      NOT NULL DEFAULT '{}',     -- müşterinin kullanabileceği eş anlamlılar
    max_guests      int         NOT NULL CHECK (max_guests > 0),
    total_rooms     int         NOT NULL CHECK (total_rooms >= 0),
    price_per_night numeric(12,2) NOT NULL CHECK (price_per_night >= 0),
    currency        text        NOT NULL DEFAULT 'TL',
    active          boolean     NOT NULL DEFAULT true,
    sort_order      int         NOT NULL DEFAULT 0
);

-- Sezonluk / özel fiyatlar. Bir gece için birden fazla kayıt eşleşirse
-- priority'si en yüksek olan kullanılır; eşleşme yoksa room_types.price_per_night.
CREATE TABLE IF NOT EXISTS room_rates (
    id              serial PRIMARY KEY,
    room_type_id    int  NOT NULL REFERENCES room_types(id) ON DELETE CASCADE,
    date_from       date NOT NULL,
    date_to         date NOT NULL,                         -- dahil
    price_per_night numeric(12,2) NOT NULL CHECK (price_per_night >= 0),
    priority        int  NOT NULL DEFAULT 0,
    label           text,
    CHECK (date_to >= date_from)
);
CREATE INDEX IF NOT EXISTS room_rates_lookup ON room_rates (room_type_id, date_from, date_to);

-- Rezervasyonlar
CREATE TABLE IF NOT EXISTS reservations (
    id             bigserial PRIMARY KEY,
    code           text        NOT NULL UNIQUE,           -- müşteriye verilen 6 haneli numara
    customer_name  text        NOT NULL,
    phone          text        NOT NULL,
    room_type_id   int         NOT NULL REFERENCES room_types(id),
    guests         int         NOT NULL CHECK (guests > 0),
    check_in       date        NOT NULL,
    check_out      date        NOT NULL,
    nights         int GENERATED ALWAYS AS (check_out - check_in) STORED,
    total_price    numeric(12,2) NOT NULL,
    notes          text,
    status         text        NOT NULL DEFAULT 'confirmed' CHECK (status IN ('confirmed', 'cancelled')),
    source         text        NOT NULL DEFAULT 'vapi',
    vapi_call_id   text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    cancelled_at   timestamptz,
    CHECK (check_out > check_in)
);
CREATE INDEX IF NOT EXISTS reservations_active_stay
    ON reservations (room_type_id, check_in, check_out) WHERE status = 'confirmed';
CREATE INDEX IF NOT EXISTS reservations_phone
    ON reservations ((right(regexp_replace(phone, '\D', '', 'g'), 10)));

-- >>> db/02_functions.sql
-- =====================================================================
-- A1 Acente Otomasyonu - İş mantığı fonksiyonları
--
-- n8n her araç (tool) için tek bir fonksiyon çağırır. Her fonksiyon
-- tek bir jsonb döner:
--   ok        : işlem başarılı mı
--   message   : sesli asistana (Vapi) aktarılacak Türkçe metin
--   send_sms  : müşteriye SMS gönderilmeli mi
--   sms_to    : E.164 formatında telefon (+905xxxxxxxxx)
--   sms_text  : SMS içeriği
-- Parametreler metin olarak alınır; hatalı tarih/sayı gelirse fonksiyon
-- hata fırlatmak yerine açıklayıcı bir mesaj döner (asistan takılmasın).
-- =====================================================================

-- Parametre sayısı değişen eski sürümler (tek otelli ilk sürüm) overload olarak kalmasın
DROP FUNCTION IF EXISTS fn_find_room_type(text);
DROP FUNCTION IF EXISTS fn_check_availability(text, text, text, text);
DROP FUNCTION IF EXISTS fn_create_reservation(text, text, text, text, text, text, text, text);

-- ---------------------------------------------------------------------
-- Yardımcılar
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_setting(p_key text, p_default text DEFAULT '')
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT value FROM app_settings WHERE key = p_key), p_default);
$$;

CREATE OR REPLACE FUNCTION fn_today()
RETURNS date LANGUAGE sql STABLE AS $$
    SELECT (now() AT TIME ZONE fn_setting('timezone', 'Europe/Istanbul'))::date;
$$;

CREATE OR REPLACE FUNCTION fn_try_date(p text)
RETURNS date LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p IS NULL OR btrim(p) = '' THEN RETURN NULL; END IF;
    IF btrim(p) !~ '^\d{4}-\d{1,2}-\d{1,2}$' THEN RETURN NULL; END IF;
    RETURN btrim(p)::date;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION fn_try_int(p text)
RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p IS NULL OR btrim(p) = '' THEN RETURN NULL; END IF;
    RETURN round(btrim(p)::numeric)::int;
EXCEPTION WHEN others THEN
    RETURN NULL;
END $$;

-- Türkçe karakterleri sadeleştirip küçük harfe çevirir (eşleştirme için)
CREATE OR REPLACE FUNCTION fn_norm(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT lower(btrim(translate(COALESCE(p, ''), 'İIıŞşĞğÜüÖöÇçÂâÎîÛû', 'iiissgguuooccaaiiuu')));
$$;

-- 5 Ekim 2026 Pazartesi
CREATE OR REPLACE FUNCTION fn_tr_date(d date)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT extract(day FROM d)::int || ' '
        || (ARRAY['Ocak','Şubat','Mart','Nisan','Mayıs','Haziran','Temmuz',
                  'Ağustos','Eylül','Ekim','Kasım','Aralık'])[extract(month FROM d)::int]
        || ' ' || extract(year FROM d)::int || ' '
        || (ARRAY['Pazartesi','Salı','Çarşamba','Perşembe','Cuma','Cumartesi','Pazar'])[extract(isodow FROM d)::int];
$$;

-- 12500 -> "12.500 TL"
CREATE OR REPLACE FUNCTION fn_money(n numeric, cur text DEFAULT 'TL')
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(to_char(round(n), 'FM999,999,999,990'), ',', '.') || ' ' || cur;
$$;

-- Telefon karşılaştırma anahtarı: son 10 hane
CREATE OR REPLACE FUNCTION fn_phone_key(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT right(regexp_replace(COALESCE(p, ''), '\D', '', 'g'), 10);
$$;

-- SMS için E.164 (Türkiye varsayılan)
CREATE OR REPLACE FUNCTION fn_phone_e164(p text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    d text := regexp_replace(COALESCE(p, ''), '\D', '', 'g');
BEGIN
    IF btrim(COALESCE(p, '')) LIKE '+%' THEN RETURN '+' || d; END IF;
    IF length(d) = 10 THEN RETURN '+90' || d; END IF;                          -- 5xxxxxxxxx
    IF length(d) = 11 AND left(d, 1) = '0' THEN RETURN '+90' || substr(d, 2); END IF; -- 05xxxxxxxxx
    IF left(d, 2) = '00' THEN RETURN '+' || substr(d, 3); END IF;
    RETURN '+' || d;
END $$;

-- Müşterinin söylediği otel adı, kısa adı ya da bölgesiyle eşleşen oteller.
-- En iyi eşleşme seviyesindeki tüm oteller döner (ör. "Lara" -> Lara bölgesindeki oteller).
CREATE OR REPLACE FUNCTION fn_match_hotels(p text)
RETURNS int[] LANGUAGE sql STABLE AS $$
    WITH s AS (
        SELECT h.id,
               CASE
                   WHEN fn_norm(h.code) = fn_norm(p) OR fn_norm(h.name) = fn_norm(p)
                     OR EXISTS (SELECT 1 FROM unnest(h.aliases) a WHERE fn_norm(a) = fn_norm(p)) THEN 3
                   WHEN fn_norm(h.region) = fn_norm(p) THEN 2
                   WHEN fn_norm(h.name) LIKE '%' || fn_norm(p) || '%'
                     OR EXISTS (SELECT 1 FROM unnest(h.aliases) a WHERE fn_norm(p) LIKE '%' || fn_norm(a) || '%')
                     OR fn_norm(p) LIKE '%' || fn_norm(h.region) || '%' THEN 1
                   ELSE 0
               END AS score
        FROM hotels h
        WHERE h.active AND fn_norm(p) <> ''
    )
    SELECT COALESCE(array_agg(id ORDER BY id), '{}')
    FROM s
    WHERE score > 0 AND score = (SELECT max(score) FROM s);
$$;

-- Müşterinin söylediği oda tipini (kod, ad, kategori veya eş anlamlı) eşleştirir.
-- p_hotels verilirse sadece o otellerde arar (tam kod eşleşmesi her zaman geçerlidir).
CREATE OR REPLACE FUNCTION fn_match_room_types(p text, p_hotels int[] DEFAULT NULL)
RETURNS int[] LANGUAGE sql STABLE AS $$
    WITH s AS (
        SELECT rt.id,
               CASE
                   WHEN fn_norm(rt.code) = fn_norm(p) THEN 4
                   WHEN fn_norm(rt.name) = fn_norm(p) OR fn_norm(rt.category) = fn_norm(p)
                     OR EXISTS (SELECT 1 FROM unnest(rt.aliases) a WHERE fn_norm(a) = fn_norm(p)) THEN 3
                   WHEN fn_norm(rt.name) LIKE '%' || fn_norm(p) || '%'
                     OR fn_norm(p) LIKE '%' || fn_norm(rt.category) || '%'
                     OR EXISTS (SELECT 1 FROM unnest(rt.aliases) a WHERE fn_norm(p) LIKE '%' || fn_norm(a) || '%') THEN 1
                   ELSE 0
               END AS score
        FROM room_types rt
        JOIN hotels h ON h.id = rt.hotel_id
        WHERE rt.active AND h.active AND fn_norm(p) <> ''
          AND (p_hotels IS NULL OR rt.hotel_id = ANY (p_hotels) OR fn_norm(rt.code) = fn_norm(p))
    )
    SELECT COALESCE(array_agg(id ORDER BY id), '{}')
    FROM s
    WHERE score > 0 AND score = (SELECT max(score) FROM s);
$$;

-- "Lara Deniz Palace (Lara, 5 yıldız, Ultra Her Şey Dahil)"
CREATE OR REPLACE FUNCTION fn_hotel_label(h hotels)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT format('%s (%s%s, %s)', h.name, h.region,
                  CASE WHEN h.stars IS NOT NULL THEN ', ' || h.stars || ' yıldız' ELSE ', butik otel' END,
                  h.board_type);
$$;

-- Konaklama boyunca en dolu gecedeki boş oda sayısı
CREATE OR REPLACE FUNCTION fn_rooms_left(p_room_type_id int, p_in date, p_out date,
                                         p_exclude_reservation bigint DEFAULT NULL)
RETURNS int LANGUAGE sql STABLE AS $$
    SELECT (SELECT total_rooms FROM room_types WHERE id = p_room_type_id)
         - COALESCE(max(x.cnt), 0)::int
    FROM (
        SELECT n.night, count(r.id) AS cnt
        FROM generate_series(p_in, p_out - 1, interval '1 day') AS n(night)
        LEFT JOIN reservations r
               ON r.room_type_id = p_room_type_id
              AND r.status = 'confirmed'
              AND r.check_in <= n.night::date
              AND r.check_out > n.night::date
              AND (p_exclude_reservation IS NULL OR r.id <> p_exclude_reservation)
        GROUP BY n.night
    ) x;
$$;

-- Konaklamanın toplam fiyatı (sezon fiyatları dahil)
CREATE OR REPLACE FUNCTION fn_stay_price(p_room_type_id int, p_in date, p_out date)
RETURNS numeric LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(
        COALESCE(
            (SELECT rr.price_per_night FROM room_rates rr
              WHERE rr.room_type_id = p_room_type_id
                AND n.night::date BETWEEN rr.date_from AND rr.date_to
              ORDER BY rr.priority DESC, rr.id DESC
              LIMIT 1),
            rt.price_per_night)), 0)
    FROM generate_series(p_in, p_out - 1, interval '1 day') AS n(night)
    CROSS JOIN room_types rt
    WHERE rt.id = p_room_type_id;
$$;

-- Ortak tarih doğrulaması. Hata varsa mesajı, yoksa NULL döner.
CREATE OR REPLACE FUNCTION fn_validate_stay(p_in date, p_out date, p_raw_in text, p_raw_out text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_max_nights int := fn_setting('max_nights', '30')::int;
BEGIN
    IF p_in IS NULL OR p_out IS NULL THEN
        RETURN format('Tarihler anlaşılamadı (giriş: %s, çıkış: %s). Giriş ve çıkış tarihlerini YYYY-AA-GG formatında tekrar gönder.',
                      COALESCE(NULLIF(p_raw_in, ''), 'yok'), COALESCE(NULLIF(p_raw_out, ''), 'yok'));
    END IF;
    IF p_out <= p_in THEN
        RETURN 'Çıkış tarihi giriş tarihinden sonra olmalı. Müşteriden tarihleri teyit et.';
    END IF;
    IF p_in < fn_today() THEN
        RETURN format('Giriş tarihi (%s) geçmiş bir tarih. Bugün %s. Müşteriden tarihi teyit et.',
                      fn_tr_date(p_in), fn_tr_date(fn_today()));
    END IF;
    IF p_out - p_in > v_max_nights THEN
        RETURN format('Telefonla en fazla %s gecelik rezervasyon alınabiliyor. Daha uzun konaklamalar için müşteriyi rezervasyon ekibine yönlendir.', v_max_nights);
    END IF;
    RETURN NULL;
END $$;

-- Rezervasyon özeti (asistan ve SMS için ortak)
CREATE OR REPLACE FUNCTION fn_reservation_summary(r reservations)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT format('%s (%s) - %s | Giriş: %s | Çıkış: %s (%s gece) | %s kişi | %s | Toplam: %s',
                  h.name, h.region, rt.name, fn_tr_date(r.check_in), fn_tr_date(r.check_out), r.nights,
                  r.guests, h.board_type, fn_money(r.total_price, rt.currency))
    FROM room_types rt
    JOIN hotels h ON h.id = rt.hotel_id
    WHERE rt.id = r.room_type_id;
$$;

CREATE OR REPLACE FUNCTION fn_new_reservation_code()
RETURNS text LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_code text;
BEGIN
    LOOP
        v_code := lpad((100000 + floor(random() * 900000))::int::text, 6, '0');
        EXIT WHEN NOT EXISTS (SELECT 1 FROM reservations WHERE code = v_code);
    END LOOP;
    RETURN v_code;
END $$;

-- Rezervasyon numarasını sesli okunabilir yapar: 482913 -> "4 8 2 9 1 3"
CREATE OR REPLACE FUNCTION fn_spell(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT array_to_string(regexp_split_to_array(p, ''), ' ');
$$;


-- Belirtilen tarihlerde tüm aktif oda tiplerinin durumu (jsonb dizi)
CREATE OR REPLACE FUNCTION fn_room_options(p_in date, p_out date, p_guests int)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(t ORDER BY t.total_price, t.hotel_sort, t.sort_order), '[]'::jsonb)
    FROM (
        SELECT rt.id, rt.hotel_id, rt.code, rt.name, rt.category, rt.description, rt.features,
               rt.max_guests, rt.currency, rt.sort_order, h.sort_order AS hotel_sort,
               fn_hotel_label(h) AS hotel_label, h.name AS hotel_name,
               fn_rooms_left(rt.id, p_in, p_out)                          AS rooms_left,
               fn_stay_price(rt.id, p_in, p_out)                          AS total_price,
               round(fn_stay_price(rt.id, p_in, p_out) / (p_out - p_in))  AS avg_nightly,
               (p_guests IS NULL OR rt.max_guests >= p_guests)            AS fits_guests
        FROM room_types rt
        JOIN hotels h ON h.id = rt.hotel_id
        WHERE rt.active AND h.active
    ) t;
$$;

-- Asistana okunacak tek seçenek satırı
CREATE OR REPLACE FUNCTION fn_option_line(o jsonb, i int)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT format('%s) %s - %s [room_type="%s"] - en fazla %s kişi - toplam %s (gecelik ortalama %s) - kalan oda %s - özellikler: %s. ',
                  i, o->>'hotel_label', o->>'name', o->>'code', o->>'max_guests',
                  fn_money((o->>'total_price')::numeric, o->>'currency'),
                  fn_money((o->>'avg_nightly')::numeric, o->>'currency'),
                  o->>'rooms_left',
                  (SELECT string_agg(f, ', ') FROM jsonb_array_elements_text(o->'features') f));
$$;

-- =====================================================================
-- TOOL: check_availability
--   p_hotel: otel adı / kısa adı ya da bölge (Lara, Belek, Kemer...). Boşsa tüm oteller.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_check_availability(p_room_type text, p_check_in text,
                                                 p_check_out text, p_guests text,
                                                 p_hotel text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_in      date := fn_try_date(p_check_in);
    v_out     date := fn_try_date(p_check_out);
    v_guests  int  := fn_try_int(p_guests);
    v_err     text;
    v_scope   int[];          -- NULL = tüm oteller
    v_scope_label text;
    v_all     jsonb;
    v_opts    jsonb;
    v_req     int[];
    v_req_hotels int[];
    v_hits    jsonb;
    v_alts    jsonb := '[]'::jsonb;
    v_reason  text;
    v_widened boolean := false;
    v_msg     text;
    v_stay    text;
    o         jsonb;
    i         int := 0;
BEGIN
    v_err := fn_validate_stay(v_in, v_out, p_check_in, p_check_out);
    IF v_err IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'message', v_err, 'send_sms', false);
    END IF;
    IF v_guests IS NOT NULL AND v_guests < 1 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
                                  'message', 'Kişi sayısı en az 1 olmalı. Müşteriden kişi sayısını öğren.');
    END IF;

    v_stay := format('%s - %s (%s gece%s)', fn_tr_date(v_in), fn_tr_date(v_out), v_out - v_in,
                     CASE WHEN v_guests IS NOT NULL THEN ', ' || v_guests || ' kişi' ELSE '' END);

    -- Otel / bölge filtresi
    IF COALESCE(btrim(p_hotel), '') <> '' THEN
        v_scope := fn_match_hotels(p_hotel);
        IF cardinality(v_scope) = 0 THEN
            RETURN jsonb_build_object('ok', false, 'send_sms', false,
                'message', format('"%s" adında bir otel ya da bölge bulunamadı. Çalıştığımız oteller: %s. Müşteriye bunları sor ya da hotel alanını boş bırakıp tüm otellerde ara.',
                                  p_hotel,
                                  (SELECT string_agg(h.name || ' (' || h.region || ')', ', ' ORDER BY h.sort_order, h.id)
                                   FROM hotels h WHERE h.active)));
        END IF;
        SELECT string_agg(h.name, ', ' ORDER BY h.sort_order, h.id) INTO v_scope_label
        FROM hotels h WHERE h.id = ANY (v_scope);
    END IF;

    v_all := fn_room_options(v_in, v_out, v_guests);
    SELECT COALESCE(jsonb_agg(e ORDER BY (e->>'total_price')::numeric), '[]'::jsonb) INTO v_opts
    FROM jsonb_array_elements(v_all) e
    WHERE v_scope IS NULL OR (e->>'hotel_id')::int = ANY (v_scope);

    IF COALESCE(btrim(p_room_type), '') <> '' THEN
        v_req := fn_match_room_types(p_room_type, v_scope);

        IF cardinality(v_req) = 0 THEN
            v_reason := format('"%s" oda tipi%s bulunamadı.', p_room_type,
                               CASE WHEN v_scope IS NOT NULL THEN ' ' || v_scope_label || ' için' ELSE '' END);
        ELSE
            SELECT array_agg(DISTINCT rt.hotel_id) INTO v_req_hotels FROM room_types rt WHERE rt.id = ANY (v_req);

            -- İstenen oda tipinin müsait ve kişi sayısına uygun olanları (en ucuz 4)
            SELECT COALESCE(jsonb_agg(e ORDER BY (e->>'total_price')::numeric), '[]'::jsonb) INTO v_hits
            FROM (SELECT e FROM jsonb_array_elements(v_all) e
                  WHERE (e->>'id')::int = ANY (v_req)
                    AND (e->>'rooms_left')::int > 0 AND (e->>'fits_guests')::boolean
                  ORDER BY (e->>'total_price')::numeric LIMIT 4) x;

            IF jsonb_array_length(v_hits) > 0 THEN
                v_msg := 'MÜSAİT (' || v_stay || '): ';
                FOR o IN SELECT * FROM jsonb_array_elements(v_hits) LOOP
                    i := i + 1;
                    v_msg := v_msg || fn_option_line(o, i)
                          || CASE WHEN jsonb_array_length(v_hits) = 1 THEN COALESCE(o->>'description', '') || ' ' ELSE '' END;
                END LOOP;
                v_msg := v_msg || 'Müşteriye otel, oda özellikleri ve toplam fiyatı aktar; onay verirse ad-soyad ve telefonu alıp create_reservation aracını ilgili room_type koduyla çağır.';
                RETURN jsonb_build_object('ok', true, 'available', true, 'send_sms', false,
                                          'message', v_msg, 'options', v_hits);
            END IF;

            v_reason := CASE
                WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_all) e
                                 WHERE (e->>'id')::int = ANY (v_req) AND (e->>'fits_guests')::boolean)
                    THEN format('İstenen oda (%s) en fazla %s kişi alıyor; %s kişi için uygun değil.',
                                (SELECT string_agg(DISTINCT e->>'hotel_name' || ' - ' || (e->>'name'), ', ')
                                 FROM jsonb_array_elements(v_all) e WHERE (e->>'id')::int = ANY (v_req)),
                                (SELECT max((e->>'max_guests')::int)
                                 FROM jsonb_array_elements(v_all) e WHERE (e->>'id')::int = ANY (v_req)),
                                v_guests)
                ELSE format('İstenen oda (%s), %s için DOLU.',
                            (SELECT string_agg(DISTINCT e->>'hotel_name' || ' - ' || (e->>'name'), ', ')
                             FROM jsonb_array_elements(v_all) e WHERE (e->>'id')::int = ANY (v_req)),
                            v_stay)
            END;
        END IF;

        -- Alternatifler: aynı otel(ler)deki diğer odalar önce, sonra fiyat
        SELECT COALESCE(jsonb_agg(e ORDER BY rk, (e->>'total_price')::numeric), '[]'::jsonb) INTO v_alts
        FROM (SELECT e, CASE WHEN (e->>'hotel_id')::int = ANY (COALESCE(v_req_hotels, '{}')) THEN 0 ELSE 1 END AS rk
              FROM jsonb_array_elements(v_opts) e
              WHERE (e->>'rooms_left')::int > 0 AND (e->>'fits_guests')::boolean
                AND NOT ((e->>'id')::int = ANY (COALESCE(v_req, '{}')))
              ORDER BY rk, (e->>'total_price')::numeric
              LIMIT 3) x;
    ELSIF v_scope IS NOT NULL THEN
        -- Otel/bölge belli, oda tipi belli değil: oradaki müsait odalar
        SELECT COALESCE(jsonb_agg(e ORDER BY (e->>'total_price')::numeric), '[]'::jsonb) INTO v_alts
        FROM (SELECT e FROM jsonb_array_elements(v_opts) e
              WHERE (e->>'rooms_left')::int > 0 AND (e->>'fits_guests')::boolean
              ORDER BY (e->>'total_price')::numeric LIMIT 5) x;
    ELSE
        -- Hiçbir tercih yok: her otelin en uygun fiyatlı müsait odası
        SELECT COALESCE(jsonb_agg(e ORDER BY (e->>'total_price')::numeric), '[]'::jsonb) INTO v_alts
        FROM (SELECT DISTINCT ON ((e->>'hotel_id')::int) e
              FROM jsonb_array_elements(v_opts) e
              WHERE (e->>'rooms_left')::int > 0 AND (e->>'fits_guests')::boolean
              ORDER BY (e->>'hotel_id')::int, (e->>'total_price')::numeric) x;
    END IF;

    -- Seçilen otel/bölgede hiç uygun oda yoksa diğer otellere bak
    IF jsonb_array_length(v_alts) = 0 AND v_scope IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(e ORDER BY (e->>'total_price')::numeric), '[]'::jsonb) INTO v_alts
        FROM (SELECT e FROM (
                  SELECT DISTINCT ON ((e->>'hotel_id')::int) e
                  FROM jsonb_array_elements(v_all) e
                  WHERE NOT ((e->>'hotel_id')::int = ANY (v_scope))
                    AND (e->>'rooms_left')::int > 0 AND (e->>'fits_guests')::boolean
                  ORDER BY (e->>'hotel_id')::int, (e->>'total_price')::numeric) y
              ORDER BY (e->>'total_price')::numeric LIMIT 3) x;
        v_widened := jsonb_array_length(v_alts) > 0;
    END IF;

    IF jsonb_array_length(v_alts) = 0 THEN
        v_msg := COALESCE(v_reason || ' ', '')
              || format('%s için hiçbir otelimizde uygun boş oda bulunmuyor. ', v_stay)
              || CASE WHEN v_guests > (SELECT max((e->>'max_guests')::int) FROM jsonb_array_elements(v_all) e
                                        WHERE (e->>'rooms_left')::int > 0)
                      THEN format('Bu tarihlerde müsait odalarda en fazla %s kişi kalabiliyor; %s kişi için iki ayrı oda önerebilirsin (kişi sayısını bölerek tekrar sorgula, her oda ayrı rezervasyon olur).',
                                  (SELECT max((e->>'max_guests')::int) FROM jsonb_array_elements(v_all) e
                                   WHERE (e->>'rooms_left')::int > 0), v_guests)
                      ELSE 'Müşteriye farklı tarih önerebilirsin.' END;
        RETURN jsonb_build_object('ok', true, 'available', false, 'send_sms', false,
                                  'message', v_msg, 'alternatives', v_alts);
    END IF;

    v_msg := COALESCE(v_reason || ' ', '') || CASE
        WHEN v_widened THEN format('%s tarafında %s. DİĞER OTELLERDEKİ SEÇENEKLER (%s): ', v_scope_label,
                                   CASE WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_opts) e WHERE (e->>'fits_guests')::boolean)
                                        THEN v_guests || ' kişiye uygun oda tipi yok'
                                        ELSE 'bu tarihlerde uygun oda yok' END,
                                   v_stay)
        WHEN v_reason IS NOT NULL THEN 'ALTERNATİFLER (' || v_stay || '): '
        WHEN v_scope IS NOT NULL THEN 'MÜSAİT ODALAR (' || v_scope_label || ', ' || v_stay || '): '
        ELSE 'MÜSAİT SEÇENEKLER (' || v_stay || ', her otelin en uygun fiyatlı odası): '
    END;
    FOR o IN SELECT * FROM jsonb_array_elements(v_alts) LOOP
        i := i + 1;
        v_msg := v_msg || fn_option_line(o, i);
    END LOOP;
    v_msg := v_msg || 'Seçenekleri otel, fiyat ve özellikleriyle müşteriye sun; birini onaylarsa create_reservation aracını ilgili room_type koduyla çağır.';

    RETURN jsonb_build_object('ok', true, 'available', v_reason IS NULL AND NOT v_widened, 'send_sms', false,
                              'message', v_msg, 'alternatives', v_alts);
END $$;


-- =====================================================================
-- TOOL: create_reservation
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_create_reservation(p_room_type text, p_customer_name text, p_phone text,
                                                 p_guests text, p_check_in text, p_check_out text,
                                                 p_notes text DEFAULT NULL, p_call_id text DEFAULT NULL,
                                                 p_hotel text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_ids    int[];
    v_in     date := fn_try_date(p_check_in);
    v_out    date := fn_try_date(p_check_out);
    v_guests int  := fn_try_int(p_guests);
    v_name   text := btrim(COALESCE(p_customer_name, ''));
    v_err    text;
    v_rt     room_types;
    v_left   int;
    v_res    reservations;
    v_sum    text;
BEGIN
    IF v_name = '' THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
                                  'message', 'Müşterinin adı soyadı eksik. Ad soyadı sorup tekrar dene.');
    END IF;
    IF length(fn_phone_key(p_phone)) < 10 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
                                  'message', 'Geçerli bir cep telefonu numarası gerekli (SMS gönderilecek). Müşteriden numarasını iste.');
    END IF;
    IF v_guests IS NULL OR v_guests < 1 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
                                  'message', 'Kişi sayısı eksik ya da geçersiz. Müşteriden kişi sayısını öğren.');
    END IF;
    v_err := fn_validate_stay(v_in, v_out, p_check_in, p_check_out);
    IF v_err IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'message', v_err, 'send_sms', false);
    END IF;

    v_ids := fn_match_room_types(p_room_type,
                 CASE WHEN COALESCE(btrim(p_hotel), '') <> '' THEN NULLIF(fn_match_hotels(p_hotel), '{}') END);
    IF cardinality(v_ids) = 0 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
                                  'message', format('"%s" oda tipi bulunamadı. Önce check_availability ile uygun oda tipini belirle.', COALESCE(p_room_type, '')));
    END IF;
    IF cardinality(v_ids) > 1 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', format('"%s" birden fazla otelde/odada var: %s. Müşterinin seçtiği odanın room_type kodunu (check_availability sonucundaki) kullanarak tekrar çağır.',
                              p_room_type,
                              (SELECT string_agg(format('%s - %s [room_type="%s"]', h.name, rt.name, rt.code), ', ')
                               FROM room_types rt JOIN hotels h ON h.id = rt.hotel_id WHERE rt.id = ANY (v_ids))));
    END IF;
    SELECT * INTO v_rt FROM room_types WHERE id = v_ids[1];
    IF v_rt.max_guests < v_guests THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
                                  'message', format('%s en fazla %s kişi alıyor; %s kişi için uygun değil. check_availability ile alternatif bul.', v_rt.name, v_rt.max_guests, v_guests));
    END IF;

    -- Aynı oda tipine eşzamanlı rezervasyonları sıraya sok (overbooking önlemi)
    PERFORM 1 FROM room_types WHERE id = v_rt.id FOR UPDATE;

    -- Aynı çağrıda asistan aracı iki kez çağırırsa mükerrer kayıt açma
    SELECT * INTO v_res FROM reservations r
    WHERE r.status = 'confirmed'
      AND r.room_type_id = v_rt.id
      AND r.check_in = v_in AND r.check_out = v_out
      AND fn_phone_key(r.phone) = fn_phone_key(p_phone)
      AND r.created_at > now() - interval '15 minutes'
    ORDER BY r.id DESC LIMIT 1;
    IF v_res.id IS NOT NULL THEN
        RETURN jsonb_build_object('ok', true, 'duplicate', true, 'send_sms', false,
            'reservation_code', v_res.code,
            'message', format('Bu rezervasyon zaten oluşturulmuş. Rezervasyon numarası: %s (%s). %s. SMS daha önce gönderildi.',
                              v_res.code, fn_spell(v_res.code), fn_reservation_summary(v_res)));
    END IF;

    v_left := fn_rooms_left(v_rt.id, v_in, v_out);
    IF v_left <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', format('Üzgünüz, %s - %s bu tarihlerde az önce doldu. check_availability ile alternatifleri kontrol et.', (SELECT name FROM hotels WHERE id = v_rt.hotel_id), v_rt.name));
    END IF;

    INSERT INTO reservations (code, customer_name, phone, room_type_id, guests, check_in, check_out,
                              total_price, notes, vapi_call_id)
    VALUES (fn_new_reservation_code(), v_name, btrim(p_phone), v_rt.id, v_guests, v_in, v_out,
            fn_stay_price(v_rt.id, v_in, v_out), NULLIF(btrim(COALESCE(p_notes, '')), ''),
            NULLIF(p_call_id, ''))
    RETURNING * INTO v_res;

    v_sum := fn_reservation_summary(v_res);
    RETURN jsonb_build_object(
        'ok', true,
        'reservation_code', v_res.code,
        'reservation_id', v_res.id,
        'message', format('Rezervasyon oluşturuldu ve onaylandı. Rezervasyon numarası: %s (müşteriye tek tek oku: %s). %s. Rezervasyon detayları %s numarasına SMS ile gönderiliyor.',
                          v_res.code, fn_spell(v_res.code), v_sum, v_res.phone),
        'send_sms', true,
        'sms_to', fn_phone_e164(v_res.phone),
        'sms_text', format('Sayın %s, rezervasyonunuz onaylandı. Rez. No: %s | %s. %s',
                           v_res.customer_name, v_res.code, v_sum, fn_setting('sms_signature', '')))
        || fn_guest_note(v_res.id, 'oluşturuldu');
END $$;


-- =====================================================================
-- TOOL: modify_reservation (tarih ve/veya kişi sayısı)
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_modify_reservation(p_code text, p_phone text, p_check_in text,
                                                 p_check_out text, p_guests text)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_code   text := regexp_replace(COALESCE(p_code, ''), '\D', '', 'g');
    v_res    reservations;
    v_old    reservations;
    v_rt     room_types;
    v_in     date;
    v_out    date;
    v_guests int;
    v_err    text;
    v_diff   numeric;
    v_sum    text;
BEGIN
    SELECT * INTO v_res FROM reservations WHERE code = v_code FOR UPDATE;
    IF v_res.id IS NULL OR fn_phone_key(v_res.phone) <> fn_phone_key(p_phone) THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', format('%s numaralı ve bu telefona kayıtlı bir rezervasyon bulunamadı. Numarayı ve rezervasyonda kullanılan telefonu teyit et.', COALESCE(NULLIF(v_code, ''), '(boş)')));
    END IF;
    IF v_res.status <> 'confirmed' THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', format('%s numaralı rezervasyon iptal edilmiş, değiştirilemez. İsterse yeni rezervasyon oluşturulabilir.', v_res.code));
    END IF;
    IF v_res.check_out <= fn_today() THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', 'Bu rezervasyonun konaklaması tamamlanmış, değiştirilemez.');
    END IF;

    v_old    := v_res;
    v_in     := COALESCE(fn_try_date(p_check_in), v_res.check_in);
    -- Sadece giriş tarihi değiştiyse gece sayısını koru
    v_out    := COALESCE(fn_try_date(p_check_out),
                         CASE WHEN fn_try_date(p_check_in) IS NOT NULL
                              THEN v_in + v_res.nights ELSE v_res.check_out END);
    v_guests := COALESCE(fn_try_int(p_guests), v_res.guests);

    IF (NULLIF(btrim(COALESCE(p_check_in, '')), '') IS NOT NULL AND fn_try_date(p_check_in) IS NULL)
       OR (NULLIF(btrim(COALESCE(p_check_out, '')), '') IS NOT NULL AND fn_try_date(p_check_out) IS NULL) THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', 'Yeni tarihler anlaşılamadı. YYYY-AA-GG formatında tekrar gönder.');
    END IF;
    IF v_in = v_res.check_in AND v_out = v_res.check_out AND v_guests = v_res.guests THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', 'Değiştirilecek bir bilgi gelmedi. Müşteriden yeni tarihleri ve/veya kişi sayısını öğren. Mevcut rezervasyon: ' || fn_reservation_summary(v_res));
    END IF;
    IF v_guests < 1 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false, 'message', 'Kişi sayısı en az 1 olmalı.');
    END IF;
    IF v_in <> v_res.check_in OR v_out <> v_res.check_out THEN
        v_err := fn_validate_stay(v_in, v_out, v_in::text, v_out::text);
        IF v_err IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'message', v_err, 'send_sms', false);
        END IF;
    END IF;

    SELECT * INTO v_rt FROM room_types WHERE id = v_res.room_type_id FOR UPDATE;
    IF v_rt.max_guests < v_guests THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', format('%s en fazla %s kişi alıyor. %s kişi için oda tipi değişmeli: mevcut rezervasyonu iptal edip check_availability ile uygun odayı bulup yeni rezervasyon oluşturmayı öner.', v_rt.name, v_rt.max_guests, v_guests));
    END IF;
    IF fn_rooms_left(v_rt.id, v_in, v_out, v_res.id) <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', format('%s, %s - %s arasında dolu; değişiklik yapılamadı. Mevcut rezervasyon aynen geçerli. İstersen check_availability ile başka tarih/oda bak.', v_rt.name, fn_tr_date(v_in), fn_tr_date(v_out)));
    END IF;

    UPDATE reservations
       SET check_in = v_in, check_out = v_out, guests = v_guests,
           total_price = fn_stay_price(v_rt.id, v_in, v_out), updated_at = now()
     WHERE id = v_res.id
    RETURNING * INTO v_res;

    v_diff := v_res.total_price - v_old.total_price;
    v_sum  := fn_reservation_summary(v_res);
    RETURN jsonb_build_object(
        'ok', true,
        'reservation_code', v_res.code,
        'message', format('Rezervasyon güncellendi. Yeni bilgiler: %s. %s Güncel bilgiler SMS ile gönderiliyor.',
                          v_sum,
                          CASE WHEN v_diff > 0 THEN 'Fiyat farkı: ' || fn_money(v_diff, v_rt.currency) || ' artış.'
                               WHEN v_diff < 0 THEN 'Fiyat farkı: ' || fn_money(-v_diff, v_rt.currency) || ' azalış.'
                               ELSE 'Toplam fiyat değişmedi.' END),
        'send_sms', true,
        'sms_to', fn_phone_e164(v_res.phone),
        'sms_text', format('Sayın %s, %s numaralı rezervasyonunuz güncellendi: %s. %s',
                           v_res.customer_name, v_res.code, v_sum, fn_setting('sms_signature', '')))
        || fn_guest_note(v_res.id, 'güncellendi');
END $$;


-- =====================================================================
-- TOOL: cancel_reservation
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_cancel_reservation(p_code text, p_phone text)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_code text := regexp_replace(COALESCE(p_code, ''), '\D', '', 'g');
    v_res  reservations;
BEGIN
    SELECT * INTO v_res FROM reservations WHERE code = v_code FOR UPDATE;
    IF v_res.id IS NULL OR fn_phone_key(v_res.phone) <> fn_phone_key(p_phone) THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', format('%s numaralı ve bu telefona kayıtlı bir rezervasyon bulunamadı. Numarayı ve rezervasyonda kullanılan telefonu teyit et.', COALESCE(NULLIF(v_code, ''), '(boş)')));
    END IF;
    IF v_res.status <> 'confirmed' THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', format('%s numaralı rezervasyon zaten iptal edilmiş; aktif bir rezervasyon yok.', v_res.code));
    END IF;
    IF v_res.check_out <= fn_today() THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', 'Bu rezervasyonun konaklaması tamamlanmış, iptal edilemez.');
    END IF;

    UPDATE reservations SET status = 'cancelled', cancelled_at = now(), updated_at = now()
     WHERE id = v_res.id
    RETURNING * INTO v_res;

    RETURN jsonb_build_object(
        'ok', true,
        'reservation_code', v_res.code,
        'message', format('%s numaralı rezervasyon iptal edildi (%s). İptal bilgisi SMS ile gönderiliyor.',
                          v_res.code, fn_reservation_summary(v_res)),
        'send_sms', true,
        'sms_to', fn_phone_e164(v_res.phone),
        'sms_text', format('Sayın %s, %s numaralı rezervasyonunuz iptal edilmiştir (%s). %s',
                           v_res.customer_name, v_res.code, fn_reservation_summary(v_res),
                           fn_setting('sms_signature', '')))
        || fn_guest_note(v_res.id, 'iptal edildi');
END $$;


-- =====================================================================
-- TOOL: find_reservation (numarasını unutan müşteri için telefonla arama)
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_find_reservation(p_phone text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_list jsonb;
    v_msg  text;
    r      reservations;
BEGIN
    IF length(fn_phone_key(p_phone)) < 10 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', 'Arama için rezervasyonda kullanılan telefon numarası gerekli.');
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object('code', x.code, 'check_in', x.check_in,
                                                 'check_out', x.check_out) ORDER BY x.check_in), '[]')
      INTO v_list
    FROM reservations x
    WHERE fn_phone_key(x.phone) = fn_phone_key(p_phone)
      AND x.status = 'confirmed' AND x.check_out > fn_today();

    IF jsonb_array_length(v_list) = 0 THEN
        RETURN jsonb_build_object('ok', true, 'send_sms', false, 'reservations', v_list,
            'message', 'Bu telefona kayıtlı aktif (gelecek tarihli) rezervasyon bulunamadı.');
    END IF;

    v_msg := 'Bu telefona kayıtlı aktif rezervasyonlar: ';
    FOR r IN SELECT * FROM reservations x
             WHERE fn_phone_key(x.phone) = fn_phone_key(p_phone)
               AND x.status = 'confirmed' AND x.check_out > fn_today()
             ORDER BY x.check_in
    LOOP
        v_msg := v_msg || format('[No: %s (%s) - %s adına - %s] ', r.code, fn_spell(r.code),
                                 r.customer_name, fn_reservation_summary(r));
    END LOOP;
    RETURN jsonb_build_object('ok', true, 'send_sms', false, 'reservations', v_list, 'message', v_msg);
END $$;


-- =====================================================================
-- Obsidian misafir notu
--   create / modify / cancel başarılı olduğunda sonuca note_path,
--   note_content ve note_message eklenir. n8n bu notu GitHub'daki
--   Obsidian vault deposuna "Oteller/<Otel>/<Misafir>.md" olarak yazar.
--   Not, aynı telefonla aynı oteldeki TÜM rezervasyonları listeler.
--   "%% manuel-notlar %%" işaretinin altı n8n tarafından korunur.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_safe_filename(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(NULLIF(btrim(regexp_replace(regexp_replace(COALESCE(p, ''), '[\\/:*?"<>|#^\[\]]', ' ', 'g'),
                                                '\s+', ' ', 'g'), ' .-'), ''), 'isimsiz');
$$;

CREATE OR REPLACE FUNCTION fn_md_cell(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(regexp_replace(COALESCE(p, ''), '\s+', ' ', 'g'), '|', '\|');
$$;

CREATE OR REPLACE FUNCTION fn_yaml(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT '"' || replace(replace(COALESCE(p, ''), '\', '\\'), '"', '\"') || '"';
$$;

CREATE OR REPLACE FUNCTION fn_guest_note(p_reservation_id bigint, p_action text DEFAULT 'güncellendi')
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    r        reservations;
    h        hotels;
    x        record;
    v_rows   text := '';
    v_count  int;
    v_total  numeric;
    v_now    text := to_char(now() AT TIME ZONE fn_setting('timezone', 'Europe/Istanbul'), 'YYYY-MM-DD HH24:MI');
    v_status text;
    v_md     text;
BEGIN
    SELECT * INTO r FROM reservations WHERE id = p_reservation_id;
    IF r.id IS NULL THEN
        RETURN '{}'::jsonb;
    END IF;
    SELECT hh.* INTO h FROM hotels hh JOIN room_types rt ON rt.hotel_id = hh.id WHERE rt.id = r.room_type_id;

    FOR x IN SELECT res.code, res.check_in, res.check_out, res.nights, res.guests, res.total_price,
                    res.status, res.notes, rt.name AS room_name, rt.currency
             FROM reservations res
             JOIN room_types rt ON rt.id = res.room_type_id
             WHERE rt.hotel_id = h.id AND fn_phone_key(res.phone) = fn_phone_key(r.phone)
             ORDER BY res.check_in DESC, res.id DESC
    LOOP
        v_rows := v_rows || format(E'| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n',
            x.code, fn_md_cell(x.room_name), to_char(x.check_in, 'DD.MM.YYYY'), to_char(x.check_out, 'DD.MM.YYYY'),
            x.nights, x.guests, fn_money(x.total_price, x.currency),
            CASE x.status WHEN 'confirmed' THEN '✅ Onaylı' ELSE '❌ İptal' END,
            fn_md_cell(x.notes));
    END LOOP;

    SELECT count(*), COALESCE(sum(res.total_price) FILTER (WHERE res.status = 'confirmed'), 0)
      INTO v_count, v_total
    FROM reservations res JOIN room_types rt ON rt.id = res.room_type_id
    WHERE rt.hotel_id = h.id AND fn_phone_key(res.phone) = fn_phone_key(r.phone);

    v_status := CASE r.status WHEN 'confirmed' THEN 'Onaylı' ELSE 'İptal' END;

    v_md := E'---\n'
        || E'tip: misafir\n'
        || 'ad_soyad: ' || fn_yaml(r.customer_name) || E'\n'
        || 'telefon: ' || fn_yaml(fn_phone_e164(r.phone)) || E'\n'
        || 'otel: ' || fn_yaml(h.name) || E'\n'
        || 'bolge: ' || fn_yaml(h.region) || E'\n'
        || 'son_rezervasyon: ' || fn_yaml(r.code) || E'\n'
        || 'son_durum: ' || fn_yaml(v_status) || E'\n'
        || 'rezervasyon_sayisi: ' || v_count || E'\n'
        || 'aktif_toplam_tl: ' || round(v_total) || E'\n'
        || 'guncelleme: ' || v_now || E'\n'
        || E'tags: [misafir]\n'
        || E'---\n'
        || '# ' || r.customer_name || E'\n\n'
        || '- **Otel:** [[' || h.name || ']] (' || h.region || ', ' || h.board_type || E')\n'
        || '- **Telefon:** ' || fn_phone_e164(r.phone) || E'\n'
        || '- **Son işlem:** ' || r.code || ' numaralı rezervasyon ' || p_action || ' (' || v_now || E')\n\n'
        || E'## Rezervasyonlar\n\n'
        || E'| No | Oda | Giriş | Çıkış | Gece | Kişi | Tutar | Durum | Not |\n'
        || E'|---|---|---|---|---:|---:|---:|---|---|\n'
        || v_rows
        || E'\n> [!info] Bu notun üst kısmı rezervasyon sisteminden otomatik güncellenir. Kendi notlarınızı **Notlarım** başlığının altına yazın; onlar korunur.\n\n'
        || E'## Notlarım\n'
        || '%% manuel-notlar %%';

    RETURN jsonb_build_object(
        'note_path', 'Oteller/' || fn_safe_filename(h.name) || '/' || fn_safe_filename(r.customer_name) || '.md',
        'note_content', v_md,
        'note_message', format('%s: %s numaralı rezervasyon %s', r.customer_name, r.code, p_action));
END $$;

-- >>> db/03_seed.sql
-- =====================================================================
-- Antalya test verisi: 6 otel, 20 oda tipi, sezon fiyatları ve
-- "dolu" senaryoları için hazır rezervasyonlar.
-- Otel adları hayalîdir; fiyat ve kontenjanlar test amaçlıdır.
-- Fiyatlar oda başı / gecelik TL'dir.
-- =====================================================================
INSERT INTO app_settings (key, value) VALUES
    ('company_name',  'A1 Tur'),
    ('sms_signature', 'İyi tatiller dileriz - A1 Tur'),
    ('timezone',      'Europe/Istanbul'),
    ('max_nights',    '30')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- Oteller
-- ---------------------------------------------------------------------
INSERT INTO hotels (code, name, region, stars, board_type, description, features, aliases, sort_order) VALUES
    ('lara-deniz', 'Lara Deniz Palace', 'Lara', 5, 'Ultra Her Şey Dahil',
        'Lara sahilinde, havalimanına 15 dakika mesafede büyük tatil köyü.',
        ARRAY['özel kumsal', '5 açık havuz', 'aquapark', 'spa', 'çocuk kulübü'],
        ARRAY['lara deniz', 'deniz palace', 'lara palace'], 1),
    ('belek-green', 'Belek Green Golf & Spa Resort', 'Belek', 5, 'Ultra Her Şey Dahil',
        'Golf sahası içinde, çam ağaçlarıyla çevrili resort.',
        ARRAY['18 delikli golf sahası', 'mavi bayraklı plaj', 'termal spa', 'tenis kortları'],
        ARRAY['belek green', 'green golf', 'golf otel', 'green resort'], 2),
    ('kemer-camkoru', 'Kemer Çamkoru Hotel', 'Kemer', 4, 'Her Şey Dahil',
        'Toros eteklerinde, çam ormanı içinde sakin bir otel.',
        ARRAY['çam ormanı içinde', 'çakıl plaj', 'dalış merkezi', 'ücretsiz Wi-Fi'],
        ARRAY['camkoru', 'cam koru', 'kemer camkoru'], 3),
    ('side-antik', 'Side Antik Liman Resort', 'Side', 5, 'Her Şey Dahil',
        'Side antik kentine 10 dakika mesafede, kumsal kenarında.',
        ARRAY['kumsal', 'kapalı havuz', 'hamam', 'animasyon ekibi', 'antik kente servis'],
        ARRAY['antik liman', 'side antik', 'liman resort'], 4),
    ('kaleici-taskonak', 'Kaleiçi Taş Konak Butik Otel', 'Kaleiçi', NULL, 'Oda Kahvaltı',
        'Restore edilmiş tarihi taş konak, yalnızca 10 oda. 12 yaş üstü misafir kabul edilir.',
        ARRAY['tarihi taş konak', 'avlu bahçesi', 'Hadrian Kapısı''na 5 dakika yürüme', 'yetişkinlere uygun (12+)'],
        ARRAY['tas konak', 'kaleici butik', 'taskonak', 'konak otel'], 5),
    ('konyaalti-sahil', 'Konyaaltı Sahil Otel', 'Konyaaltı', 4, 'Yarım Pansiyon',
        'Şehir merkezinde, Konyaaltı plajına sıfır.',
        ARRAY['sahile sıfır', 'çatı havuzu', 'Antalya Müzesi''ne yakın', 'ücretsiz otopark'],
        ARRAY['sahil otel', 'konyaalti sahil'], 6)
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------
-- Oda tipleri (kod tüm otellerde tekil)
-- ---------------------------------------------------------------------
INSERT INTO room_types (hotel_id, code, category, name, description, features, aliases,
                        max_guests, total_rooms, price_per_night, sort_order)
SELECT h.id, v.code, v.category, v.name, v.description, v.features, v.aliases,
       v.max_guests, v.total_rooms, v.price, v.sort_order
FROM (VALUES
    -- Lara Deniz Palace
    ('lara-deniz', 'lara-standart', 'standart', 'Standart Oda', 'Bahçe manzaralı, 28 metrekare.',
        ARRAY['bahçe manzarası', 'balkon', 'klima', 'minibar'], ARRAY['standard', 'bahce manzarali'], 2, 40, 7800, 1),
    ('lara-deniz', 'lara-deluxe', 'deluxe', 'Deluxe Deniz Manzaralı Oda', 'Deniz manzaralı, 34 metrekare.',
        ARRAY['deniz manzarası', 'geniş balkon', 'kahve makinesi', 'minibar'], ARRAY['deniz manzarali', 'manzarali'], 3, 24, 10500, 2),
    ('lara-deniz', 'lara-aile', 'aile', 'Aile Odası', 'İki ayrı yatak odası, 48 metrekare.',
        ARRAY['iki yatak odası', 'iki banyo', 'çocuk yatağı imkânı'], ARRAY['family', 'cocuklu'], 4, 12, 14500, 3),
    ('lara-deniz', 'lara-suit', 'suit', 'Kral Süit', 'Jakuzili, oturma odalı, 85 metrekare.',
        ARRAY['deniz manzarası', 'jakuzi', 'oturma odası', 'VIP transfer'], ARRAY['kral suit', 'suite', 'vip'], 4, 2, 32000, 4),
    -- Belek Green Golf & Spa Resort
    ('belek-green', 'belek-superior', 'standart', 'Superior Oda', 'Orman manzaralı, 32 metrekare.',
        ARRAY['orman manzarası', 'balkon', 'klima', 'minibar'], ARRAY['superior', 'standart'], 2, 30, 9200, 1),
    ('belek-green', 'belek-deluxe', 'deluxe', 'Golf Manzaralı Deluxe Oda', 'Golf sahası manzaralı, 38 metrekare.',
        ARRAY['golf manzarası', 'geniş teras', 'kahve makinesi'], ARRAY['golf manzarali', 'manzarali'], 3, 20, 11800, 2),
    ('belek-green', 'belek-aile-suit', 'aile', 'Aile Süiti', 'İki yatak odalı süit, 60 metrekare.',
        ARRAY['iki yatak odası', 'oturma alanı', 'çocuk yatağı imkânı'], ARRAY['aile suiti', 'family suite'], 5, 10, 17500, 3),
    ('belek-green', 'belek-villa', 'villa', 'Özel Havuzlu Villa', 'Müstakil villa, 140 metrekare.',
        ARRAY['özel havuz', 'üç yatak odası', 'bahçe', 'butler hizmeti'], ARRAY['havuzlu villa', 'villa'], 6, 3, 42000, 4),
    -- Kemer Çamkoru Hotel
    ('kemer-camkoru', 'kemer-standart', 'standart', 'Standart Oda', 'Orman manzaralı, 24 metrekare.',
        ARRAY['orman manzarası', 'balkon', 'klima'], ARRAY['standard'], 2, 36, 4900, 1),
    ('kemer-camkoru', 'kemer-bungalov', 'bungalov', 'Bahçe Bungalovu', 'Ahşap bungalov, bahçe içinde, 30 metrekare.',
        ARRAY['müstakil giriş', 'bahçe', 'veranda', 'klima'], ARRAY['bungalow', 'bahce'], 3, 14, 6200, 2),
    ('kemer-camkoru', 'kemer-aile', 'aile', 'Aile Odası', 'Ara kapılı iki oda, 40 metrekare.',
        ARRAY['ara kapılı iki oda', 'çocuk yatağı imkânı', 'balkon'], ARRAY['family', 'cocuklu'], 4, 8, 7900, 3),
    -- Side Antik Liman Resort
    ('side-antik', 'side-standart', 'standart', 'Standart Oda', 'Kara manzaralı, 30 metrekare.',
        ARRAY['kara manzarası', 'balkon', 'klima', 'minibar'], ARRAY['standard'], 3, 28, 6800, 1),
    ('side-antik', 'side-deluxe', 'deluxe', 'Deniz Manzaralı Deluxe Oda', 'Deniz manzaralı, 34 metrekare.',
        ARRAY['deniz manzarası', 'balkon', 'kahve makinesi'], ARRAY['deniz manzarali', 'manzarali'], 3, 16, 8900, 2),
    ('side-antik', 'side-aile', 'aile', 'Bağlantılı Aile Odası', 'Ara kapılı iki oda, 55 metrekare.',
        ARRAY['ara kapılı iki oda', 'iki banyo', 'çocuk yatağı imkânı'], ARRAY['family', 'baglantili', 'cocuklu'], 5, 8, 12400, 3),
    -- Kaleiçi Taş Konak Butik Otel (toplam 10 oda)
    ('kaleici-taskonak', 'kaleici-standart', 'standart', 'Konak Odası', 'Avlu manzaralı, taş duvarlı, 20 metrekare.',
        ARRAY['avlu manzarası', 'tarihi dekor', 'klima'], ARRAY['standard', 'konak odasi'], 2, 6, 3600, 1),
    ('kaleici-taskonak', 'kaleici-suit', 'suit', 'Tarihi Süit', 'Ahşap tavanlı, şömineli, 35 metrekare.',
        ARRAY['şömine', 'ahşap tavan', 'marina manzarası', 'jakuzi'], ARRAY['tarihi suit', 'suite'], 2, 2, 6400, 2),
    ('kaleici-taskonak', 'kaleici-aile', 'aile', 'Aile Odası', 'Çatı katında, 30 metrekare.',
        ARRAY['çatı katı', 'üç tek yatak', 'klima'], ARRAY['family', 'uc kisilik'], 3, 2, 5200, 3),
    -- Konyaaltı Sahil Otel
    ('konyaalti-sahil', 'konyaalti-ekonomik', 'standart', 'Ekonomik Oda', 'Şehir manzaralı, 20 metrekare.',
        ARRAY['şehir manzarası', 'klima', 'ücretsiz Wi-Fi'], ARRAY['ekonomik', 'standard', 'standart'], 2, 20, 3200, 1),
    ('konyaalti-sahil', 'konyaalti-deniz', 'deluxe', 'Deniz Manzaralı Oda', 'Deniz manzaralı, balkonlu, 24 metrekare.',
        ARRAY['deniz manzarası', 'balkon', 'klima'], ARRAY['deniz manzarali', 'manzarali'], 2, 14, 4300, 2),
    ('konyaalti-sahil', 'konyaalti-aile', 'aile', 'Aile Odası', 'Ara kapılı iki oda, 36 metrekare.',
        ARRAY['ara kapılı iki oda', 'çocuk yatağı imkânı', 'klima'], ARRAY['family', 'cocuklu'], 4, 6, 5600, 3)
) AS v(hotel_code, code, category, name, description, features, aliases, max_guests, total_rooms, price, sort_order)
JOIN hotels h ON h.code = v.hotel_code
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------
-- Sezon fiyatları
--   Yaz sezonu (1 Haziran - 30 Eylül): tatil köyleri %45, şehir otelleri %20 zamlı
--   Yılbaşı (29 Aralık - 2 Ocak): şehir otelleri %60 zamlı
-- ---------------------------------------------------------------------
INSERT INTO room_rates (room_type_id, date_from, date_to, price_per_night, priority, label)
SELECT rt.id, make_date(y, 6, 1), make_date(y, 9, 30),
       round(rt.price_per_night * CASE WHEN h.region IN ('Kaleiçi', 'Konyaaltı') THEN 1.20 ELSE 1.45 END, -2),
       10, 'Yaz sezonu ' || y
FROM room_types rt
JOIN hotels h ON h.id = rt.hotel_id
CROSS JOIN (VALUES (2026), (2027)) AS years(y)
WHERE NOT EXISTS (SELECT 1 FROM room_rates);

INSERT INTO room_rates (room_type_id, date_from, date_to, price_per_night, priority, label)
SELECT rt.id, DATE '2026-12-29', DATE '2027-01-02', round(rt.price_per_night * 1.60, -2), 20, 'Yılbaşı'
FROM room_types rt
JOIN hotels h ON h.id = rt.hotel_id
WHERE h.region IN ('Kaleiçi', 'Konyaaltı')
  AND NOT EXISTS (SELECT 1 FROM room_rates WHERE label = 'Yılbaşı');

-- ---------------------------------------------------------------------
-- Hazır test rezervasyonları (dolu / az kalan senaryoları)
-- Telefonlar sahte test numaralarıdır.
-- ---------------------------------------------------------------------
INSERT INTO reservations (code, customer_name, phone, room_type_id, guests, check_in, check_out,
                          total_price, notes, source)
SELECT v.code, v.name, v.phone, rt.id, v.guests, v.cin, v.cout,
       fn_stay_price(rt.id, v.cin, v.cout), 'Test verisi', 'test'
FROM (
    -- Senaryo 1: Lara Kral Süit (2 oda) 10-17 Ekim tamamen dolu
    VALUES ('900101', 'Test Misafir Lara 1', '+905550000101', 'lara-suit', 2, DATE '2026-10-10', DATE '2026-10-17'),
           ('900102', 'Test Misafir Lara 2', '+905550000102', 'lara-suit', 3, DATE '2026-10-10', DATE '2026-10-17'),
    -- Senaryo 3: Belek Havuzlu Villa (3 villa) 1-8 Kasım tamamen dolu
           ('900301', 'Test Misafir Belek 1', '+905550000301', 'belek-villa', 6, DATE '2026-11-01', DATE '2026-11-08'),
           ('900302', 'Test Misafir Belek 2', '+905550000302', 'belek-villa', 4, DATE '2026-11-01', DATE '2026-11-08'),
           ('900303', 'Test Misafir Belek 3', '+905550000303', 'belek-villa', 5, DATE '2026-11-01', DATE '2026-11-08'),
    -- Değiştirme / iptal testi için
           ('100001', 'Ayşe Test', '+905551112233', 'konyaalti-deniz', 2, DATE '2026-10-15', DATE '2026-10-18'),
           ('100002', 'Mehmet Test', '+905554445566', 'side-deluxe', 2, DATE '2026-10-20', DATE '2026-10-25')
) AS v(code, name, phone, room_code, guests, cin, cout)
JOIN room_types rt ON rt.code = v.room_code
ON CONFLICT (code) DO NOTHING;

-- Senaryo 2: Kaleiçi Taş Konak 28-31 Ekim (Cumhuriyet Bayramı) tamamen dolu: 10 odanın hepsi
INSERT INTO reservations (code, customer_name, phone, room_type_id, guests, check_in, check_out,
                          total_price, notes, source)
SELECT '9002' || lpad(row_number() OVER ()::text, 2, '0'), 'Test Misafir Kaleiçi ' || row_number() OVER (),
       '+9055500002' || lpad(row_number() OVER ()::text, 2, '0'), rt.id, 2,
       DATE '2026-10-28', DATE '2026-10-31',
       fn_stay_price(rt.id, DATE '2026-10-28', DATE '2026-10-31'), 'Test verisi', 'test'
FROM room_types rt
CROSS JOIN LATERAL generate_series(1, rt.total_rooms)
WHERE rt.code LIKE 'kaleici-%'
  AND NOT EXISTS (SELECT 1 FROM reservations WHERE code = '900201');

-- Senaryo 4: Kemer aile odası (8 oda) 5-12 Ekim'de 7'si dolu, 1 oda kaldı
INSERT INTO reservations (code, customer_name, phone, room_type_id, guests, check_in, check_out,
                          total_price, notes, source)
SELECT '9004' || lpad(n::text, 2, '0'), 'Test Misafir Kemer ' || n, '+9055500004' || lpad(n::text, 2, '0'),
       rt.id, 4, DATE '2026-10-05', DATE '2026-10-12',
       fn_stay_price(rt.id, DATE '2026-10-05', DATE '2026-10-12'), 'Test verisi', 'test'
FROM room_types rt
CROSS JOIN generate_series(1, 7) AS n
WHERE rt.code = 'kemer-aile'
  AND NOT EXISTS (SELECT 1 FROM reservations WHERE code = '900401');

COMMIT;
