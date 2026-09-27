-- =====================================================================
-- Örnek veriler - kendi oda tiplerinizle / fiyatlarınızla değiştirin
-- =====================================================================
INSERT INTO app_settings (key, value) VALUES
    ('company_name',  'A1 Tur'),
    ('sms_signature', 'İyi tatiller dileriz - A1 Tur'),
    ('timezone',      'Europe/Istanbul'),
    ('max_nights',    '30')
ON CONFLICT (key) DO NOTHING;

INSERT INTO room_types (code, name, description, features, aliases, max_guests, total_rooms, price_per_night, sort_order) VALUES
    ('standart', 'Standart Oda', 'Bahçe manzaralı, 22 metrekare.',
        ARRAY['çift kişilik veya iki tek yatak', 'klima', 'minibar', 'ücretsiz Wi-Fi', 'açık büfe kahvaltı dahil'],
        ARRAY['standard', 'ekonomik', 'normal oda', 'iki kisilik'], 2, 10, 2500, 1),
    ('deluxe', 'Deluxe Deniz Manzaralı Oda', 'Deniz manzaralı, balkonlu, 30 metrekare.',
        ARRAY['deniz manzarası', 'balkon', 'klima', 'minibar', 'ücretsiz Wi-Fi', 'açık büfe kahvaltı dahil'],
        ARRAY['deniz manzarali', 'manzarali', 'balkonlu', 'delux'], 3, 6, 4000, 2),
    ('aile', 'Aile Odası', 'İki ayrı yatak odalı, 45 metrekare.',
        ARRAY['iki yatak odası', 'çocuk yatağı imkânı', 'klima', 'ücretsiz Wi-Fi', 'açık büfe kahvaltı dahil'],
        ARRAY['family', 'aile odasi', 'cocuklu', 'dort kisilik'], 4, 4, 5500, 3),
    ('suit', 'Kral Süit', 'Jakuzili, oturma alanlı, 70 metrekare, deniz manzaralı.',
        ARRAY['deniz manzarası', 'jakuzi', 'oturma odası', 'geniş teras', 'VIP transfer', 'açık büfe kahvaltı dahil'],
        ARRAY['suite', 'kral suit', 'vip', 'jakuzili'], 4, 2, 9000, 4)
ON CONFLICT (code) DO NOTHING;

-- Örnek sezon fiyatı: Temmuz-Ağustos %40 zamlı
INSERT INTO room_rates (room_type_id, date_from, date_to, price_per_night, priority, label)
SELECT id, make_date(extract(year FROM now())::int + 1, 7, 1), make_date(extract(year FROM now())::int + 1, 8, 31),
       round(price_per_night * 1.4), 10, 'Yaz sezonu'
FROM room_types
WHERE NOT EXISTS (SELECT 1 FROM room_rates);
