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
    source         text        NOT NULL DEFAULT 'telefon',  -- telefon, whatsapp, instagram, test
    vapi_call_id   text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    cancelled_at   timestamptz,
    CHECK (check_out > check_in)
);
-- Sonradan eklenen alanlar (mevcut veritabanlarında da çalışır)
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS email text;   -- bilgilendirme e-postası (isteğe bağlı)

-- Çocuk politikası
ALTER TABLE hotels ADD COLUMN IF NOT EXISTS adult_age       int NOT NULL DEFAULT 12;  -- bu yaş ve üstü yetişkin sayılır
ALTER TABLE hotels ADD COLUMN IF NOT EXISTS infant_age      int NOT NULL DEFAULT 2;   -- bu yaşın altı bebek: ücretsiz, kapasiteye sayılmaz
ALTER TABLE hotels ADD COLUMN IF NOT EXISTS min_guest_age   int NOT NULL DEFAULT 0;   -- kabul edilen en küçük yaş (yetişkin otelleri)
ALTER TABLE hotels ADD COLUMN IF NOT EXISTS extra_adult_pct int NOT NULL DEFAULT 75;  -- oda fiyatına dahil kişi sayısını aşan her yetişkin,
                                                                                       -- kişi başı fiyatın yüzde kaçını öder
ALTER TABLE room_types ADD COLUMN IF NOT EXISTS base_occupancy int NOT NULL DEFAULT 2; -- oda fiyatına dahil kişi sayısı
ALTER TABLE room_types ADD COLUMN IF NOT EXISTS max_adults     int;                    -- boşsa max_guests kadar yetişkin

-- Çocuk fiyat kuralları. Çocuklar yaşa göre büyükten küçüğe sıralanır; oda fiyatına dahil
-- kişi sayısı dolduktan sonraki ilk çocuk "1. çocuk" olur. Kural yoksa çocuk yetişkin fiyatı öder.
CREATE TABLE IF NOT EXISTS hotel_child_policies (
    id          serial PRIMARY KEY,
    hotel_id    int NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
    child_order int,                              -- 1 = 1. çocuk, 2 = 2. çocuk; boş = sıradan bağımsız
    age_min     int NOT NULL,                     -- dahil, tam yaş (giriş tarihindeki yaş)
    age_max     int NOT NULL,                     -- dahil
    price_pct   int NOT NULL CHECK (price_pct BETWEEN 0 AND 100),  -- kişi başı yetişkin fiyatının yüzdesi, 0 = ücretsiz
    CHECK (age_max >= age_min)
);

ALTER TABLE reservations ADD COLUMN IF NOT EXISTS adults        int;
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS children_ages int[] NOT NULL DEFAULT '{}';
UPDATE reservations SET adults = guests WHERE adults IS NULL;

CREATE INDEX IF NOT EXISTS reservations_active_stay
    ON reservations (room_type_id, check_in, check_out) WHERE status = 'confirmed';
CREATE INDEX IF NOT EXISTS reservations_phone
    ON reservations ((right(regexp_replace(phone, '\D', '', 'g'), 10)));
