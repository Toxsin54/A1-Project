-- Enerji haber ve piyasa takip ajanı: tablolar
-- Tekrar çalıştırmak güvenlidir; veriler silinmez.
-- Tüm zamanlar timestamptz (UTC saklanır). Günlük fiyatlar işlem gününe (trade_date) göre tutulur.

CREATE EXTENSION IF NOT EXISTS pg_trgm;      -- haber başlıklarını kümelemek için
CREATE SCHEMA IF NOT EXISTS energy;

-- Veri kaynakları: piyasa verisi, temel göstergeler, haber, takvim
CREATE TABLE IF NOT EXISTS energy.sources (
  code            text PRIMARY KEY,                 -- 'eia', 'epias', 'rss_aa_energy'
  name            text NOT NULL,
  kind            text NOT NULL CHECK (kind IN ('market_data','fundamental','news','calendar')),
  access          text NOT NULL CHECK (access IN ('api','rss','scrape','file','manual')),
  -- 1: birincil/resmî kaynak (OPEC, EIA, EPDK...), 2: haber ajansı / uzman yayın, 3: toplayıcı, blog, sosyal medya
  tier            smallint NOT NULL CHECK (tier BETWEEN 1 AND 3),
  base_url        text,
  license         text NOT NULL DEFAULT 'free',      -- free | free-key | paid | delayed
  store_body      boolean NOT NULL DEFAULT false,    -- lisans izin veriyorsa haber metninin tamamı saklanır
  poll_interval   interval,
  is_enabled      boolean NOT NULL DEFAULT true,
  last_success_at timestamptz,
  last_error_at   timestamptz,
  last_error      text
);

-- Her toplama çalışmasının kaydı (kaynak sağlığı ve rapordaki data_quality bloğu buradan beslenir)
CREATE TABLE IF NOT EXISTS energy.ingest_runs (
  id          bigserial PRIMARY KEY,
  source_code text NOT NULL REFERENCES energy.sources(code),
  started_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  status      text NOT NULL DEFAULT 'running' CHECK (status IN ('running','ok','partial','error')),
  rows_in     int NOT NULL DEFAULT 0,
  error       text
);
CREATE INDEX IF NOT EXISTS ingest_runs_source_idx ON energy.ingest_runs (source_code, started_at DESC);

-- Fiyat serileri (vadeli, spot, endeks, döviz)
CREATE TABLE IF NOT EXISTS energy.instruments (
  code          text PRIMARY KEY,                    -- 'BRENT_SPOT', 'TTF_M1', 'TR_PTF_BASE', 'EURTRY'
  name          text NOT NULL,
  segment       text NOT NULL CHECK (segment IN ('crude','refined_products','natural_gas','power','carbon','fx')),
  unit          text NOT NULL,                       -- 'USD/bbl', 'USD/gal', 'USD/t', 'EUR/MWh', 'TRY/MWh', 'EUR/t'
  region        text,                                -- 'GLOBAL', 'US', 'EU', 'DE', 'TR', 'ASIA'
  exchange      text,
  source_code   text REFERENCES energy.sources(code),
  source_symbol text,                                -- sağlayıcıdaki seri kodu (ör. EIA 'RBRTE')
  max_staleness interval NOT NULL DEFAULT '4 days',  -- son veri bundan eskiyse rapor "bayat" işaretler
  alert_zscore  numeric NOT NULL DEFAULT 2.5,        -- günlük değişimin z-skoru bu eşiği aşarsa hareket kaydı açılır
  alert_move_pct numeric,                            -- ya da yüzde değişim bu eşiği aşarsa
  is_active     boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS energy.prices_daily (
  instrument_code text NOT NULL REFERENCES energy.instruments(code),
  trade_date      date NOT NULL,
  value           numeric NOT NULL,
  price_type      text NOT NULL DEFAULT 'settle' CHECK (price_type IN ('settle','close','spot','index','average')),
  source_code     text REFERENCES energy.sources(code),
  ingested_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (instrument_code, trade_date)
);

-- Gün içi / saatlik veri (ör. saatlik PTF). Günlük özet ayrıca prices_daily'e yazılır (TR_PTF_BASE).
CREATE TABLE IF NOT EXISTS energy.prices_intraday (
  instrument_code text NOT NULL REFERENCES energy.instruments(code),
  ts              timestamptz NOT NULL,
  value           numeric NOT NULL,
  source_code     text REFERENCES energy.sources(code),
  ingested_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (instrument_code, ts)
);

-- Türetilmiş metrikler: bacakların doğrusal toplamı.
-- legs: [{"i": "TTF_M1", "c": 0.29307, "mul": "EURUSD"}, {"i": "HH_SPOT", "c": -1}]
--   bacak değeri = c * fiyat(i) [* fiyat(mul)] [/ fiyat(div)]; birim çevrimi c katsayısının içindedir.
CREATE TABLE IF NOT EXISTS energy.derived_metrics (
  code        text PRIMARY KEY,
  name        text NOT NULL,
  segment     text NOT NULL CHECK (segment IN ('crude','refined_products','natural_gas','power','carbon','cross_market')),
  unit        text NOT NULL,
  legs        jsonb NOT NULL CHECK (jsonb_typeof(legs) = 'array' AND jsonb_array_length(legs) > 0),
  description text,
  is_active   boolean NOT NULL DEFAULT true
);

-- Temel göstergeler: stoklar, üretim, depolama doluluğu, sondaj kulesi, pozisyon verisi
CREATE TABLE IF NOT EXISTS energy.indicators (
  code          text PRIMARY KEY,                    -- 'US_CRUDE_STOCKS', 'EU_GAS_STORAGE_PCT'
  name          text NOT NULL,
  segment       text NOT NULL CHECK (segment IN ('crude','refined_products','natural_gas','power','carbon')),
  unit          text NOT NULL,
  frequency     text NOT NULL CHECK (frequency IN ('daily','weekly','monthly')),
  source_code   text REFERENCES energy.sources(code),
  source_symbol text,
  -- Değerin artması fiyat için ne demek? (stok artışı genelde fiyat için aşağı yönlü: -1)
  price_sign    smallint NOT NULL DEFAULT 0 CHECK (price_sign IN (-1, 0, 1))
);

CREATE TABLE IF NOT EXISTS energy.indicator_values (
  indicator_code   text NOT NULL REFERENCES energy.indicators(code),
  period_end       date NOT NULL,                    -- verinin ait olduğu dönemin son günü
  value            numeric NOT NULL,
  consensus_change numeric,                          -- piyasa beklentisi (değişim olarak), varsa
  released_at      timestamptz,
  source_code      text REFERENCES energy.sources(code),
  ingested_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (indicator_code, period_end)           -- revizyon gelirse üzerine yazılır
);

-- Aynı olayı anlatan haberler tek kümede toplanır; LLM analizi küme başına bir kez yapılır.
CREATE TABLE IF NOT EXISTS energy.story_clusters (
  id            bigserial PRIMARY KEY,
  headline      text NOT NULL,                       -- en iyi kaynaktan gelen başlık
  first_seen_at timestamptz NOT NULL,
  last_seen_at  timestamptz NOT NULL,
  item_count    int NOT NULL DEFAULT 1,
  source_count  int NOT NULL DEFAULT 1,
  best_tier     smallint NOT NULL,
  needs_analysis boolean NOT NULL DEFAULT true       -- yeni küme, daha iyi kaynak ya da belirgin büyüme
);
CREATE INDEX IF NOT EXISTS story_clusters_seen_idx ON energy.story_clusters (last_seen_at DESC);
CREATE INDEX IF NOT EXISTS story_clusters_headline_trgm ON energy.story_clusters USING gin (headline gin_trgm_ops);

CREATE TABLE IF NOT EXISTS energy.news_items (
  id           bigserial PRIMARY KEY,
  source_code  text NOT NULL REFERENCES energy.sources(code),
  url          text NOT NULL,                        -- utm_* vb. parametreleri temizlenmiş adres
  url_hash     text GENERATED ALWAYS AS (md5(url)) STORED,
  title        text NOT NULL,
  summary      text,
  body         text,                                 -- sadece sources.store_body = true ise
  lang         text,
  published_at timestamptz,
  fetched_at   timestamptz NOT NULL DEFAULT now(),
  -- Anahtar kelime ön filtresinden geçti mi? Geçmeyenler kümelenmez ve LLM'e gitmez.
  prefilter_ok boolean NOT NULL DEFAULT true,
  cluster_id   bigint REFERENCES energy.story_clusters(id),
  CONSTRAINT news_items_url_hash_key UNIQUE (url_hash)
);
CREATE INDEX IF NOT EXISTS news_items_published_idx ON energy.news_items (published_at DESC);
CREATE INDEX IF NOT EXISTS news_items_cluster_idx ON energy.news_items (cluster_id);

-- LLM çıktısı (contracts/news-analysis.schema.json ile doğrulanmış). Küme başına en güncel kayıt geçerlidir.
CREATE TABLE IF NOT EXISTS energy.news_analyses (
  id             bigserial PRIMARY KEY,
  cluster_id     bigint NOT NULL REFERENCES energy.story_clusters(id),
  analyzed_at    timestamptz NOT NULL DEFAULT now(),
  model          text NOT NULL,
  prompt_version text NOT NULL,
  is_relevant    boolean NOT NULL,
  event_type     text,
  segments       text[] NOT NULL DEFAULT '{}',
  regions        text[] NOT NULL DEFAULT '{}',
  impacts        jsonb NOT NULL DEFAULT '[]',        -- [{segment, instruments, price_direction, magnitude, horizon}]
  novelty        text CHECK (novelty IN ('new','update','repeat')),
  is_rumor       boolean NOT NULL DEFAULT false,
  confidence     numeric CHECK (confidence BETWEEN 0 AND 1),
  summary_tr     text,
  output         jsonb NOT NULL,                     -- doğrulanmış ham çıktı (denetim için)
  cluster_item_count int NOT NULL DEFAULT 1,         -- analiz anında kümedeki haber sayısı
  input_tokens   int,
  output_tokens  int
);
CREATE INDEX IF NOT EXISTS news_analyses_cluster_idx ON energy.news_analyses (cluster_id, analyzed_at DESC);

-- Olağan dışı fiyat hareketleri ve (varsa) onları açıklayan haber kümeleri
CREATE TABLE IF NOT EXISTS energy.market_moves (
  id              bigserial PRIMARY KEY,
  instrument_code text NOT NULL REFERENCES energy.instruments(code),
  trade_date      date NOT NULL,
  change_pct      numeric,
  zscore          numeric,
  explained_by    bigint[] NOT NULL DEFAULT '{}',    -- story_clusters.id
  status          text NOT NULL DEFAULT 'unexplained' CHECK (status IN ('explained','unexplained')),
  detected_at     timestamptz NOT NULL DEFAULT now(),
  alerted_at      timestamptz,
  UNIQUE (instrument_code, trade_date)
);

-- Planlı veri açıklamaları ve toplantılar (EIA stok raporu, OPEC+ toplantısı, EEX ihaleleri...)
CREATE TABLE IF NOT EXISTS energy.calendar_events (
  id             bigserial PRIMARY KEY,
  code           text NOT NULL,                      -- 'EIA_WPSR', 'OPEC_PLUS_MEETING'
  name           text NOT NULL,
  segment        text NOT NULL CHECK (segment IN ('crude','refined_products','natural_gas','power','carbon','cross_market')),
  scheduled_at   timestamptz NOT NULL,
  importance     smallint NOT NULL DEFAULT 2 CHECK (importance BETWEEN 1 AND 3),
  indicator_code text REFERENCES energy.indicators(code),
  status         text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','released','cancelled')),
  UNIQUE (code, scheduled_at)
);

-- Raporlar = outbox. Analist ajana gönderim buradan yapılır; gönderilemeyen rapor kaybolmaz.
CREATE TABLE IF NOT EXISTS energy.reports (
  report_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_type       text NOT NULL CHECK (report_type IN ('morning_brief','daily_close','weekly_outlook','event_note','alert')),
  schema_version    text NOT NULL,
  as_of             timestamptz NOT NULL,
  generated_at      timestamptz NOT NULL DEFAULT now(),
  priority          text NOT NULL CHECK (priority IN ('low','normal','high','critical')),
  -- Aynı raporun iki kez üretilmesini engeller: 'daily_close:2026-09-26', 'alert:BRENT_M1:2026-09-26'
  dedup_key         text NOT NULL UNIQUE,
  body              jsonb NOT NULL CHECK (body ?& ARRAY['report_id','agent','report_type','as_of','summary','findings','evidence','data_quality','payload']),
  delivery_status   text NOT NULL DEFAULT 'pending' CHECK (delivery_status IN ('pending','delivered','failed','disabled')),
  delivery_attempts int NOT NULL DEFAULT 0,
  next_attempt_at   timestamptz NOT NULL DEFAULT now(),
  delivered_at      timestamptz,
  last_error        text
);
CREATE INDEX IF NOT EXISTS reports_outbox_idx ON energy.reports (next_attempt_at) WHERE delivery_status = 'pending';
CREATE INDEX IF NOT EXISTS reports_type_idx ON energy.reports (report_type, as_of DESC);
