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
DROP FUNCTION IF EXISTS fn_create_reservation(text, text, text, text, text, text, text, text, text);
DROP FUNCTION IF EXISTS fn_create_reservation(text, text, text, text, text, text, text, text, text, text);
DROP FUNCTION IF EXISTS fn_check_availability(text, text, text, text, text);
DROP FUNCTION IF EXISTS fn_modify_reservation(text, text, text, text, text);
DROP FUNCTION IF EXISTS fn_room_options(date, date, int);

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

-- "4, 9 yaş" / "[4, 9]" / "4 ve 9" -> {4,9}
CREATE OR REPLACE FUNCTION fn_parse_ages(p text)
RETURNS int[] LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(array_agg(t.m[1]::int ORDER BY t.ord), '{}')
    FROM regexp_matches(COALESCE(p, ''), '(\d+)', 'g') WITH ORDINALITY AS t(m, ord);
$$;

-- "2 yetişkin, 2 çocuk (8 ve 4 yaş)"
CREATE OR REPLACE FUNCTION fn_party_text(p_adults int, p_ages int[])
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(p_adults::text, '?') || ' yetişkin'
        || CASE WHEN cardinality(COALESCE(p_ages, '{}')) > 0
                THEN format(', %s çocuk (%s yaş)', cardinality(p_ages),
                            regexp_replace(array_to_string(p_ages, ', '), ', ([0-9]+)$', ' ve \1'))
                ELSE '' END;
$$;

-- Otelin çocuk politikası, asistanın müşteriye anlatacağı dille
CREATE OR REPLACE FUNCTION fn_child_policy_text(p_hotel_id int)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT format('%s çocuk politikası: ', h.name)
        || CASE WHEN h.min_guest_age > 0
                THEN format('%s yaş altı misafir kabul edilmiyor.', h.min_guest_age)
                ELSE format('%s yaş altı bebekler ücretsiz; %s yaş ve üstü yetişkin sayılır', h.infant_age, h.adult_age)
                     || COALESCE('; ' || (SELECT string_agg(
                            format('%s%s-%s yaş %s',
                                   CASE WHEN cp.child_order IS NULL THEN 'her çocuk ' ELSE cp.child_order || '. çocuk ' END,
                                   cp.age_min, cp.age_max,
                                   CASE cp.price_pct WHEN 0 THEN 'ücretsiz' ELSE '%' || cp.price_pct || ' öder' END),
                            ', ' ORDER BY cp.child_order NULLS FIRST, cp.age_min)
                         FROM hotel_child_policies cp WHERE cp.hotel_id = h.id), '')
                     || '. İndirimler oda fiyatına dahil kişilerin (genelde 2 yetişkin) yanında kalan çocuklara uygulanır.'
           END
    FROM hotels h WHERE h.id = p_hotel_id;
$$;

-- Bir oda tipi için kişi dağılımına göre fiyat teklifi.
--   Oda fiyatı base_occupancy kişiyi kapsar; kişi başı fiyat = oda fiyatı / base_occupancy.
--   Fazla yetişkin: kişi başı * extra_adult_pct. Çocuklar büyükten küçüğe; önce boş kalan
--   oda fiyatı kişilerini doldurur, sonrakiler 1., 2. çocuk olarak politikaya göre ödenir.
--   Bebekler (infant_age altı) ücretsizdir ve kapasiteye sayılmaz.
-- Döner: {fits, reason, total, note}
CREATE OR REPLACE FUNCTION fn_stay_quote(p_room_type_id int, p_in date, p_out date,
                                         p_adults int, p_ages int[])
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    rt        room_types;
    h         hotels;
    v_room    numeric := fn_stay_price(p_room_type_id, p_in, p_out);
    v_adults  int;
    v_kids    int[];
    v_infants int[];
    v_rest    int[];
    v_free    int;
    v_extra   int;
    v_pct     numeric := 0;
    v_note    text[] := '{}';
    a         int;
    k         int := 0;
    v_p       int;
BEGIN
    SELECT * INTO rt FROM room_types WHERE id = p_room_type_id;
    SELECT * INTO h FROM hotels WHERE id = rt.hotel_id;

    IF p_adults IS NULL THEN   -- kişi bilgisi yok: oda fiyatı
        RETURN jsonb_build_object('fits', true, 'total', v_room, 'note', NULL);
    END IF;

    v_adults := p_adults + (SELECT count(*) FROM unnest(COALESCE(p_ages, '{}')) x WHERE x >= h.adult_age);
    SELECT COALESCE(array_agg(x ORDER BY x DESC), '{}') INTO v_kids
    FROM unnest(COALESCE(p_ages, '{}')) x WHERE x < h.adult_age;

    IF v_adults < 1 THEN
        RETURN jsonb_build_object('fits', false, 'reason', 'Rezervasyonda en az bir yetişkin olmalı.');
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(v_kids) x WHERE x < h.min_guest_age) THEN
        RETURN jsonb_build_object('fits', false,
            'reason', format('%s %s yaş altı misafir kabul etmiyor.', h.name, h.min_guest_age));
    END IF;

    SELECT COALESCE(array_agg(x ORDER BY x DESC), '{}') INTO v_infants FROM unnest(v_kids) x WHERE x < h.infant_age;
    SELECT COALESCE(array_agg(x ORDER BY x DESC), '{}') INTO v_rest    FROM unnest(v_kids) x WHERE x >= h.infant_age;

    IF v_adults + cardinality(v_rest) > rt.max_guests OR v_adults > COALESCE(rt.max_adults, rt.max_guests) THEN
        RETURN jsonb_build_object('fits', false,
            'reason', format('%s - %s en fazla %s kişi%s alıyor (bebekler hariç); %s için uygun değil.',
                             h.name, rt.name, rt.max_guests,
                             CASE WHEN rt.max_adults IS NOT NULL THEN ', en fazla ' || rt.max_adults || ' yetişkin' ELSE '' END,
                             fn_party_text(p_adults, p_ages)));
    END IF;

    v_extra := greatest(v_adults - rt.base_occupancy, 0);
    IF v_extra > 0 THEN
        v_pct := v_extra * h.extra_adult_pct;
        v_note := v_note || format('%s ek yetişkin kişi başı fiyatın %%%s''i', v_extra, h.extra_adult_pct);
    END IF;

    v_free := greatest(rt.base_occupancy - v_adults, 0);
    FOREACH a IN ARRAY v_rest LOOP
        IF v_free > 0 THEN
            v_free := v_free - 1;
            v_note := v_note || format('%s yaş çocuk oda fiyatına dahil', a);
            CONTINUE;
        END IF;
        k := k + 1;
        SELECT cp.price_pct INTO v_p
        FROM hotel_child_policies cp
        WHERE cp.hotel_id = h.id AND (cp.child_order = k OR cp.child_order IS NULL)
          AND a BETWEEN cp.age_min AND cp.age_max
        ORDER BY cp.child_order NULLS LAST, cp.price_pct
        LIMIT 1;
        v_p := COALESCE(v_p, 100);
        v_pct := v_pct + v_p;
        v_note := v_note || format('%s. çocuk (%s yaş) %s', k, a,
                                   CASE v_p WHEN 0 THEN 'ücretsiz' WHEN 100 THEN 'yetişkin fiyatı' ELSE '%' || v_p || ' öder' END);
        v_p := NULL;
    END LOOP;
    FOREACH a IN ARRAY v_infants LOOP
        v_note := v_note || format('bebek (%s yaş) ücretsiz', a);
    END LOOP;

    RETURN jsonb_build_object(
        'fits', true,
        'total', round(v_room + v_room / rt.base_occupancy * v_pct / 100),
        'note', NULLIF(array_to_string(v_note, ', '), ''));
END $$;

-- Rezervasyon özeti (asistan ve SMS için ortak)
CREATE OR REPLACE FUNCTION fn_reservation_summary(r reservations)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT format('%s (%s) - %s | Giriş: %s | Çıkış: %s (%s gece) | %s | %s | Toplam: %s',
                  h.name, h.region, rt.name, fn_tr_date(r.check_in), fn_tr_date(r.check_out), r.nights,
                  fn_party_text(COALESCE(r.adults, r.guests), r.children_ages), h.board_type,
                  fn_money(r.total_price, rt.currency))
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
CREATE OR REPLACE FUNCTION fn_room_options(p_in date, p_out date, p_adults int, p_ages int[])
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(t ORDER BY t.total_price, t.hotel_sort, t.sort_order), '[]'::jsonb)
    FROM (
        SELECT rt.id, rt.hotel_id, rt.code, rt.name, rt.category, rt.description, rt.features,
               rt.max_guests, rt.currency, rt.sort_order, h.sort_order AS hotel_sort,
               fn_hotel_label(h) AS hotel_label, h.name AS hotel_name,
               fn_rooms_left(rt.id, p_in, p_out)                          AS rooms_left,
               (q.q->>'total')::numeric                                   AS total_price,
               round((q.q->>'total')::numeric / (p_out - p_in))           AS avg_nightly,
               (q.q->>'fits')::boolean                                    AS fits_guests,
               q.q->>'reason'                                             AS fit_reason,
               q.q->>'note'                                               AS price_note
        FROM room_types rt
        JOIN hotels h ON h.id = rt.hotel_id
        CROSS JOIN LATERAL (SELECT fn_stay_quote(rt.id, p_in, p_out, p_adults, p_ages) AS q) q
        WHERE rt.active AND h.active
    ) t;
$$;

-- Asistana okunacak tek seçenek satırı
CREATE OR REPLACE FUNCTION fn_option_line(o jsonb, i int)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT format('%s) %s - %s [room_type="%s"] - en fazla %s kişi - toplam %s%s (gecelik ortalama %s) - kalan oda %s - özellikler: %s. ',
                  i, o->>'hotel_label', o->>'name', o->>'code', o->>'max_guests',
                  fn_money((o->>'total_price')::numeric, o->>'currency'),
                  COALESCE(' [' || (o->>'price_note') || ']', ''),
                  fn_money((o->>'avg_nightly')::numeric, o->>'currency'),
                  o->>'rooms_left',
                  (SELECT string_agg(f, ', ') FROM jsonb_array_elements_text(o->'features') f));
$$;

-- E-posta adresini sadeleştirir; geçersizse NULL
CREATE OR REPLACE FUNCTION fn_clean_email(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN x ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' THEN x END
    FROM (SELECT lower(regexp_replace(COALESCE(p, ''), '\s', '', 'g')) AS x) t;
$$;

CREATE OR REPLACE FUNCTION fn_html(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(replace(replace(replace(COALESCE(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
$$;

-- Asistanın okuyacağı "nereye gönderiliyor" metni
CREATE OR REPLACE FUNCTION fn_notify_text(r reservations)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT format('%s numarasına SMS ve WhatsApp ile%s', r.phone,
                  CASE WHEN r.email IS NOT NULL THEN ', ' || r.email || ' adresine e-posta ile' ELSE '' END);
$$;

-- Bilgilendirme e-postası (e-posta yoksa boş jsonb)
CREATE OR REPLACE FUNCTION fn_reservation_email(r reservations, p_action text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    h      hotels;
    rt     room_types;
    v_row  text := '<tr><td style="padding:6px 12px 6px 0;color:#55656d;white-space:nowrap">%s</td><td style="padding:6px 0">%s</td></tr>';
    v_html text;
    v_intro text;
BEGIN
    IF r.email IS NULL THEN
        RETURN '{}'::jsonb;
    END IF;
    SELECT * INTO rt FROM room_types WHERE id = r.room_type_id;
    SELECT * INTO h FROM hotels WHERE id = rt.hotel_id;

    v_intro := CASE p_action
        WHEN 'onaylandı'    THEN 'Rezervasyonunuz oluşturulmuş ve onaylanmıştır. Detaylar aşağıdadır.'
        WHEN 'güncellendi'  THEN 'Rezervasyonunuz güncellenmiştir. Güncel bilgiler aşağıdadır.'
        ELSE 'Rezervasyonunuz iptal edilmiştir. İptal edilen rezervasyonun bilgileri aşağıdadır.' END;

    v_html := '<div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#17252f;font-size:15px;line-height:1.5">'
        || format('<h2 style="color:%s;margin:0 0 16px">Rezervasyonunuz %s</h2>',
                  CASE WHEN p_action = 'iptal edildi' THEN '#a4591b' ELSE '#0d7482' END, fn_html(p_action))
        || format('<p>Sayın %s,</p><p>%s</p>', fn_html(r.customer_name), v_intro)
        || '<table style="border-collapse:collapse;margin:12px 0 20px">'
        || format(v_row, 'Rezervasyon no', '<b>' || r.code || '</b>')
        || format(v_row, 'Otel', fn_html(h.name) || ' (' || fn_html(h.region) || ')')
        || format(v_row, 'Oda', fn_html(rt.name))
        || format(v_row, 'Konsept', fn_html(h.board_type))
        || format(v_row, 'Giriş', fn_tr_date(r.check_in))
        || format(v_row, 'Çıkış', fn_tr_date(r.check_out))
        || format(v_row, 'Konaklama', r.nights || ' gece, ' || fn_party_text(COALESCE(r.adults, r.guests), r.children_ages))
        || format(v_row, 'Toplam tutar', '<b>' || fn_money(r.total_price, rt.currency) || '</b>')
        || CASE WHEN r.notes IS NOT NULL THEN format(v_row, 'Notunuz', fn_html(r.notes)) ELSE '' END
        || '</table>'
        || format('<p style="color:#55656d;font-size:13px">%s</p></div>', fn_html(fn_setting('sms_signature', '')));

    RETURN jsonb_build_object(
        'email_to', r.email,
        'email_subject', format('Rezervasyonunuz %s - No %s | %s', p_action, r.code, fn_setting('company_name', '')),
        'email_html', v_html);
END $$;


-- =====================================================================
-- TOOL: check_availability
--   p_hotel: otel adı / kısa adı ya da bölge (Lara, Belek, Kemer...). Boşsa tüm oteller.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_check_availability(p_room_type text, p_check_in text,
                                                 p_check_out text, p_guests text,
                                                 p_hotel text DEFAULT NULL,
                                                 p_adults text DEFAULT NULL, p_children text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_in      date := fn_try_date(p_check_in);
    v_out     date := fn_try_date(p_check_out);
    v_ages    int[] := fn_parse_ages(p_children);
    v_adults  int  := COALESCE(fn_try_int(p_adults), fn_try_int(p_guests) - cardinality(fn_parse_ages(p_children)));
    v_guests  int  := v_adults + cardinality(v_ages);
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
    IF v_adults IS NOT NULL AND v_adults < 1 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
                                  'message', 'En az 1 yetişkin olmalı. Müşteriden yetişkin sayısını ve çocukların yaşlarını öğren.');
    END IF;

    v_stay := format('%s - %s (%s gece%s)', fn_tr_date(v_in), fn_tr_date(v_out), v_out - v_in,
                     CASE WHEN v_adults IS NOT NULL THEN ', ' || fn_party_text(v_adults, v_ages) ELSE '' END);

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

    v_all := fn_room_options(v_in, v_out, v_adults, v_ages);
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
                IF cardinality(v_ages) > 0 THEN
                    v_msg := v_msg || (SELECT string_agg(fn_child_policy_text(hid), ' ')
                                       FROM (SELECT DISTINCT (e->>'hotel_id')::int AS hid FROM jsonb_array_elements(v_hits) e) d) || ' ';
                END IF;
                v_msg := v_msg || 'Müşteriye otel, oda özellikleri ve toplam fiyatı aktar; onay verirse ad-soyad ve telefonu alıp create_reservation aracını ilgili room_type koduyla çağır.';
                RETURN jsonb_build_object('ok', true, 'available', true, 'send_sms', false,
                                          'message', v_msg, 'options', v_hits);
            END IF;

            v_reason := CASE
                WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_all) e
                                 WHERE (e->>'id')::int = ANY (v_req) AND (e->>'fits_guests')::boolean)
                    THEN (SELECT string_agg(DISTINCT e->>'fit_reason', ' ')
                          FROM jsonb_array_elements(v_all) e WHERE (e->>'id')::int = ANY (v_req))
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
                                        THEN 'uygun oda yok (' || COALESCE((SELECT rtrim(e->>'fit_reason', '.') FROM jsonb_array_elements(v_opts) e
                                                                             WHERE e->>'fit_reason' IS NOT NULL LIMIT 1), 'kapasite') || ')'
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
    v_msg := v_msg || 'Seçenekleri otel, fiyat ve özellikleriyle müşteriye sun'
          || CASE WHEN cardinality(v_ages) > 0 THEN ' (köşeli parantezdeki çocuk fiyat bilgisini de açıkla)' ELSE '' END
          || '; birini onaylarsa create_reservation aracını ilgili room_type koduyla çağır.';

    RETURN jsonb_build_object('ok', true, 'available', v_reason IS NULL AND NOT v_widened, 'send_sms', false,
                              'message', v_msg, 'alternatives', v_alts);
END $$;


-- =====================================================================
-- TOOL: create_reservation
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_create_reservation(p_room_type text, p_customer_name text, p_phone text,
                                                 p_guests text, p_check_in text, p_check_out text,
                                                 p_notes text DEFAULT NULL, p_call_id text DEFAULT NULL,
                                                 p_hotel text DEFAULT NULL, p_email text DEFAULT NULL,
                                                 p_adults text DEFAULT NULL, p_children text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_ids    int[];
    v_email  text := fn_clean_email(p_email);
    v_in     date := fn_try_date(p_check_in);
    v_out    date := fn_try_date(p_check_out);
    v_ages   int[] := fn_parse_ages(p_children);
    v_adults int  := COALESCE(fn_try_int(p_adults), fn_try_int(p_guests) - cardinality(fn_parse_ages(p_children)));
    v_quote  jsonb;
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
    IF v_adults IS NULL OR v_adults < 1 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
                                  'message', 'Yetişkin sayısı eksik ya da geçersiz. Müşteriden yetişkin sayısını ve varsa çocukların yaşlarını öğren.');
    END IF;
    IF COALESCE(btrim(p_email), '') <> '' AND v_email IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', format('E-posta adresi geçersiz görünüyor: "%s". Rezervasyon henüz oluşturulmadı. Müşteriden e-postayı harf harf tekrar iste (ör. "a-l-i nokta v-e-l-i et gmail nokta com") ya da e-postasız devam etmek isterse email alanını boş bırakarak tekrar çağır.', p_email));
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
    v_quote := fn_stay_quote(v_rt.id, v_in, v_out, v_adults, v_ages);
    IF NOT (v_quote->>'fits')::boolean THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
                                  'message', (v_quote->>'reason') || ' check_availability ile uygun oda bul.');
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
            'message', format('Bu rezervasyon zaten oluşturulmuş. Rezervasyon numarası: %s (%s). %s. Bilgilendirme mesajları daha önce gönderildi.',
                              v_res.code, fn_spell(v_res.code), fn_reservation_summary(v_res)));
    END IF;

    v_left := fn_rooms_left(v_rt.id, v_in, v_out);
    IF v_left <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', format('Üzgünüz, %s - %s bu tarihlerde az önce doldu. check_availability ile alternatifleri kontrol et.', (SELECT name FROM hotels WHERE id = v_rt.hotel_id), v_rt.name));
    END IF;

    INSERT INTO reservations (code, customer_name, phone, room_type_id, guests, adults, children_ages,
                              check_in, check_out, total_price, notes, vapi_call_id, email)
    VALUES (fn_new_reservation_code(), v_name, btrim(p_phone), v_rt.id, v_adults + cardinality(v_ages),
            v_adults, v_ages, v_in, v_out, (v_quote->>'total')::numeric,
            NULLIF(btrim(COALESCE(p_notes, '')), ''), NULLIF(p_call_id, ''), v_email)
    RETURNING * INTO v_res;

    v_sum := fn_reservation_summary(v_res);
    RETURN jsonb_build_object(
        'ok', true,
        'reservation_code', v_res.code,
        'reservation_id', v_res.id,
        'message', format('Rezervasyon oluşturuldu ve onaylandı. Rezervasyon numarası: %s (müşteriye tek tek oku: %s). %s.%s Rezervasyon detayları %s gönderiliyor.',
                          v_res.code, fn_spell(v_res.code), v_sum,
                          COALESCE(' Fiyat detayı: ' || (v_quote->>'note') || '.', ''), fn_notify_text(v_res)),
        'send_sms', true,
        'sms_to', fn_phone_e164(v_res.phone),
        'sms_text', format('Sayın %s, rezervasyonunuz onaylandı. Rez. No: %s | %s. %s',
                           v_res.customer_name, v_res.code, v_sum, fn_setting('sms_signature', '')))
        || fn_reservation_email(v_res, 'onaylandı');
END $$;


-- =====================================================================
-- TOOL: modify_reservation (tarih ve/veya kişi sayısı)
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_modify_reservation(p_code text, p_phone text, p_check_in text,
                                                 p_check_out text, p_guests text,
                                                 p_adults text DEFAULT NULL, p_children text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_ages   int[];
    v_adults int;
    v_quote  jsonb;
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
    -- Çocuk bilgisi geldiyse (boş liste dahil, ör. "yok") onu, gelmediyse mevcut çocukları kullan
    v_ages   := CASE WHEN COALESCE(btrim(p_children), '') <> '' THEN fn_parse_ages(p_children) ELSE v_res.children_ages END;
    v_adults := COALESCE(fn_try_int(p_adults),
                         fn_try_int(p_guests) - cardinality(v_ages),
                         v_res.adults, v_res.guests);
    v_guests := v_adults + cardinality(v_ages);

    IF (NULLIF(btrim(COALESCE(p_check_in, '')), '') IS NOT NULL AND fn_try_date(p_check_in) IS NULL)
       OR (NULLIF(btrim(COALESCE(p_check_out, '')), '') IS NOT NULL AND fn_try_date(p_check_out) IS NULL) THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', 'Yeni tarihler anlaşılamadı. YYYY-AA-GG formatında tekrar gönder.');
    END IF;
    IF v_in = v_res.check_in AND v_out = v_res.check_out
       AND v_adults = COALESCE(v_res.adults, v_res.guests) AND v_ages = v_res.children_ages THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', 'Değiştirilecek bir bilgi gelmedi. Müşteriden yeni tarihleri ve/veya kişi sayısını öğren. Mevcut rezervasyon: ' || fn_reservation_summary(v_res));
    END IF;
    IF v_adults < 1 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false, 'message', 'En az 1 yetişkin olmalı.');
    END IF;
    IF v_in <> v_res.check_in OR v_out <> v_res.check_out THEN
        v_err := fn_validate_stay(v_in, v_out, v_in::text, v_out::text);
        IF v_err IS NOT NULL THEN
            RETURN jsonb_build_object('ok', false, 'message', v_err, 'send_sms', false);
        END IF;
    END IF;

    SELECT * INTO v_rt FROM room_types WHERE id = v_res.room_type_id FOR UPDATE;
    v_quote := fn_stay_quote(v_rt.id, v_in, v_out, v_adults, v_ages);
    IF NOT (v_quote->>'fits')::boolean THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', (v_quote->>'reason') || ' Oda tipi değişmeli: mevcut rezervasyonu iptal edip check_availability ile uygun odayı bulup yeni rezervasyon oluşturmayı öner.');
    END IF;
    IF fn_rooms_left(v_rt.id, v_in, v_out, v_res.id) <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'send_sms', false,
            'message', format('%s, %s - %s arasında dolu; değişiklik yapılamadı. Mevcut rezervasyon aynen geçerli. İstersen check_availability ile başka tarih/oda bak.', v_rt.name, fn_tr_date(v_in), fn_tr_date(v_out)));
    END IF;

    UPDATE reservations
       SET check_in = v_in, check_out = v_out, guests = v_guests, adults = v_adults, children_ages = v_ages,
           total_price = (v_quote->>'total')::numeric, updated_at = now()
     WHERE id = v_res.id
    RETURNING * INTO v_res;

    v_diff := v_res.total_price - v_old.total_price;
    v_sum  := fn_reservation_summary(v_res);
    RETURN jsonb_build_object(
        'ok', true,
        'reservation_code', v_res.code,
        'message', format('Rezervasyon güncellendi. Yeni bilgiler: %s.%s %s Güncel bilgiler %s gönderiliyor.',
                          v_sum, COALESCE(' Fiyat detayı: ' || (v_quote->>'note') || '.', ''),
                          CASE WHEN v_diff > 0 THEN 'Fiyat farkı: ' || fn_money(v_diff, v_rt.currency) || ' artış.'
                               WHEN v_diff < 0 THEN 'Fiyat farkı: ' || fn_money(-v_diff, v_rt.currency) || ' azalış.'
                               ELSE 'Toplam fiyat değişmedi.' END,
                          fn_notify_text(v_res)),
        'send_sms', true,
        'sms_to', fn_phone_e164(v_res.phone),
        'sms_text', format('Sayın %s, %s numaralı rezervasyonunuz güncellendi: %s. %s',
                           v_res.customer_name, v_res.code, v_sum, fn_setting('sms_signature', '')))
        || fn_reservation_email(v_res, 'güncellendi');
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
        'message', format('%s numaralı rezervasyon iptal edildi (%s). İptal bilgisi %s gönderiliyor.',
                          v_res.code, fn_reservation_summary(v_res), fn_notify_text(v_res)),
        'send_sms', true,
        'sms_to', fn_phone_e164(v_res.phone),
        'sms_text', format('Sayın %s, %s numaralı rezervasyonunuz iptal edilmiştir (%s). %s',
                           v_res.customer_name, v_res.code, fn_reservation_summary(v_res),
                           fn_setting('sms_signature', '')))
        || fn_reservation_email(v_res, 'iptal edildi');
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
