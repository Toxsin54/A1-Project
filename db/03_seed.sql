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

-- ---------------------------------------------------------------------
-- Çocuk politikaları ve oda kapasiteleri (mevcut veritabanında tekrar çalıştırılabilir)
--   Yaşlar giriş tarihindeki tam yaştır. 0-1 yaş bebekler her otelde ücretsiz.
-- ---------------------------------------------------------------------
UPDATE hotels h SET adult_age = v.adult_age, infant_age = 2, min_guest_age = v.min_age, extra_adult_pct = v.extra
FROM (VALUES ('lara-deniz', 13, 0, 75), ('belek-green', 12, 0, 70), ('kemer-camkoru', 12, 0, 80),
             ('side-antik', 13, 0, 75), ('kaleici-taskonak', 12, 12, 100), ('konyaalti-sahil', 12, 0, 80))
     AS v(code, adult_age, min_age, extra)
WHERE h.code = v.code;

UPDATE room_types rt SET base_occupancy = v.base, max_guests = v.max_guests, max_adults = v.max_adults
FROM (VALUES ('lara-standart', 2, 2, NULL), ('lara-deluxe', 2, 3, NULL), ('lara-aile', 2, 4, 3), ('lara-suit', 2, 4, 3),
             ('belek-superior', 2, 2, NULL), ('belek-deluxe', 2, 3, NULL), ('belek-aile-suit', 2, 5, 4), ('belek-villa', 4, 6, NULL),
             ('kemer-standart', 2, 2, NULL), ('kemer-bungalov', 2, 3, NULL), ('kemer-aile', 2, 4, 3),
             ('side-standart', 2, 3, NULL), ('side-deluxe', 2, 3, NULL), ('side-aile', 2, 5, 4),
             ('kaleici-standart', 2, 2, NULL), ('kaleici-suit', 2, 2, NULL), ('kaleici-aile', 2, 3, NULL),
             ('konyaalti-ekonomik', 2, 2, NULL), ('konyaalti-deniz', 2, 2, NULL), ('konyaalti-aile', 2, 4, 3))
     AS v(code, base, max_guests, max_adults)
WHERE rt.code = v.code;

INSERT INTO hotel_child_policies (hotel_id, child_order, age_min, age_max, price_pct)
SELECT h.id, v.child_order, v.age_min, v.age_max, v.pct
FROM (VALUES
    -- Lara: 1. çocuk 12 yaşına kadar ücretsiz; 2. çocuk 2-6 ücretsiz, 7-12 %50
    ('lara-deniz', 1, 2, 12, 0), ('lara-deniz', 2, 2, 6, 0), ('lara-deniz', 2, 7, 12, 50),
    -- Belek: 1. çocuk 11 yaşına kadar ücretsiz; 2. çocuk %50
    ('belek-green', 1, 2, 11, 0), ('belek-green', 2, 2, 11, 50),
    -- Kemer: her çocuk 2-5 yaş ücretsiz, 6-11 yaş %50
    ('kemer-camkoru', NULL, 2, 5, 0), ('kemer-camkoru', NULL, 6, 11, 50),
    -- Side: 1. çocuk 2-6 ücretsiz, 7-12 %50; 2. çocuk %50
    ('side-antik', 1, 2, 6, 0), ('side-antik', 1, 7, 12, 50), ('side-antik', 2, 2, 12, 50),
    -- Konyaaltı: her çocuk 2-5 yaş ücretsiz, 6-11 yaş %30
    ('konyaalti-sahil', NULL, 2, 5, 0), ('konyaalti-sahil', NULL, 6, 11, 30)
    -- Kaleiçi Taş Konak: 12 yaş altı kabul edilmiyor (min_guest_age)
) AS v(hotel_code, child_order, age_min, age_max, pct)
JOIN hotels h ON h.code = v.hotel_code
WHERE NOT EXISTS (SELECT 1 FROM hotel_child_policies);

UPDATE reservations SET adults = guests WHERE adults IS NULL;
