-- Enerji ajanı veritabanı smoke testi. Sentetik veri yükler, hesapları kontrol eder, sonunda her şeyi geri alır.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f energy-agent/test/smoke_test.sql
-- Önce db/01..03 yüklenmiş olmalı. Başarısız kontrol hata fırlatır.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL TIME ZONE 'UTC';

-- Fiyatlar: 2026-04-01..2026-09-25 iş günleri; Brent son gün +4 USD sıçrar
INSERT INTO energy.prices_daily (instrument_code, trade_date, value, source_code)
SELECT i.code, d::date,
       CASE i.code WHEN 'BRENT_SPOT'    THEN 70 + sin(n / 5.0) * 1.5 + CASE WHEN d::date = '2026-09-25' THEN 4 ELSE 0 END
                   WHEN 'WTI_SPOT'      THEN 66 + sin(n / 5.0) * 1.4
                   WHEN 'ULSD_NYH_SPOT' THEN 2.30 + sin(n / 7.0) * 0.05
                   WHEN 'TR_PTF_BASE'   THEN 2800 + sin(n / 3.0) * 150
                   WHEN 'EURTRY'        THEN 47 + n * 0.01 END,
       i.source_code
FROM generate_series('2026-04-01'::date, '2026-09-25'::date, '1 day') WITH ORDINALITY g(d, n)
CROSS JOIN (SELECT code, source_code FROM energy.instruments
            WHERE code IN ('BRENT_SPOT','WTI_SPOT','ULSD_NYH_SPOT','TR_PTF_BASE','EURTRY')) i
WHERE extract(isodow FROM d) < 6;

-- Haftalık stok: 2026-09-18 haftasında beklenti -1.500 iken +6.000 civarı artış
INSERT INTO energy.indicator_values (indicator_code, period_end, value, released_at, source_code)
SELECT 'US_CRUDE_STOCKS', d::date,
       430000 + sin(extract(week FROM d) / 8.0) * 15000 + CASE WHEN d::date = '2026-09-18' THEN 6000 ELSE 0 END,
       (d::date + 5) + time '14:30', 'eia'
FROM generate_series('2020-09-18'::date, '2026-09-18'::date, '7 days') d;
UPDATE energy.indicator_values SET consensus_change = -1500
WHERE indicator_code = 'US_CRUDE_STOCKS' AND period_end = '2026-09-18';

-- Haberler: üç kaynak aynı OPEC+ haberini verir (tek küme), Libya kesintisi ayrı küme
INSERT INTO energy.news_items (source_code, url, title, published_at) VALUES
  ('aa_energy', 'https://example.test/1', 'OPEC+ ekim ayında üretimi günlük 137 bin varil artırma kararı aldı', '2026-09-25 09:00+00'),
  ('rigzone',   'https://example.test/2', 'OPEC+ ekim ayında üretimi günlük 137 bin varil artırma kararı aldı - detaylar', '2026-09-25 09:30+00'),
  ('opec',      'https://example.test/3', 'OPEC+ ekim ayında üretimi günlük 137 bin varil artırma kararı', '2026-09-25 10:00+00'),
  ('aa_energy', 'https://example.test/4', 'Libya''da petrol sahası saldırı nedeniyle üretimi durdurdu', '2026-09-25 13:00+00');
SELECT energy.fn_assign_cluster(id) FROM energy.news_items WHERE url LIKE 'https://example.test/%' ORDER BY id;

DO $$
DECLARE c record;
BEGIN
  SELECT * INTO c FROM energy.story_clusters WHERE headline LIKE 'OPEC+%' AND first_seen_at = '2026-09-25 09:00+00';
  ASSERT c.item_count = 3 AND c.source_count = 3, 'OPEC+ haberleri tek kümede olmalı';
  ASSERT c.best_tier = 1 AND c.headline NOT LIKE '%aldı', 'başlık tier 1 kaynaktan (OPEC) alınmalı';
  ASSERT (SELECT count(*) FROM energy.story_clusters WHERE first_seen_at >= '2026-09-25' AND first_seen_at < '2026-09-26') = 2,
         'iki küme beklenir';
END $$;

-- Önce sadece OPEC+ (aşağı yönlü) analizi: Brent'in yükselişini açıklamamalı
INSERT INTO energy.news_analyses (cluster_id, model, prompt_version, is_relevant, event_type, segments, impacts, novelty, confidence, output, cluster_item_count)
SELECT id, 'test', 'v1', true, 'supply_opec_policy', '{crude}',
       '[{"segment":"crude","instruments":["BRENT_M1"],"price_direction":"down","magnitude":2,"horizon":"short"}]', 'new', 0.8, '{}', 3
FROM energy.story_clusters WHERE headline LIKE 'OPEC+%' AND first_seen_at = '2026-09-25 09:00+00';

DO $$
DECLARE s record; m record; v numeric;
BEGIN
  ASSERT NOT (SELECT needs_analysis FROM energy.story_clusters WHERE headline LIKE 'OPEC+%' AND first_seen_at = '2026-09-25 09:00+00'),
         'analiz sonrası needs_analysis false olmalı';

  SELECT * INTO s FROM energy.fn_snapshot('2026-09-27') WHERE instrument = 'BRENT_SPOT';
  ASSERT s.as_of = '2026-09-25' AND NOT s.is_stale, 'Brent son değeri 25 Eylül olmalı';
  ASSERT s.zscore_1d > 3, format('Brent z-skoru yüksek olmalı: %s', s.zscore_1d);
  ASSERT (SELECT is_stale FROM energy.fn_snapshot('2026-09-27') WHERE instrument = 'GASOLINE_NYH_SPOT'), 'verisiz seri bayat görünmeli';
  ASSERT NOT EXISTS (SELECT 1 FROM energy.fn_snapshot('2026-09-27') WHERE instrument = 'DE_DA_BASE')
         OR (SELECT is_enabled FROM energy.sources WHERE code = 'entsoe'), 'kaynağı kapalı seri snapshot''a girmemeli';

  SELECT * INTO m FROM energy.fn_detect_moves('2026-09-25') WHERE instrument_code = 'BRENT_SPOT';
  ASSERT m.status = 'unexplained', 'ters yönlü haber hareketi açıklamamalı';

  v := energy.fn_derived_value('BRENT_WTI_SPOT', '2026-09-25');
  ASSERT abs(v - (energy.fn_price_on('BRENT_SPOT', '2026-09-25') - energy.fn_price_on('WTI_SPOT', '2026-09-25'))) < 0.001, 'Brent-WTI farkı';
  v := energy.fn_derived_value('TR_PTF_EUR', '2026-09-25');
  ASSERT abs(v - energy.fn_price_on('TR_PTF_BASE', '2026-09-25') / energy.fn_price_on('EURTRY', '2026-09-25')) < 0.001, 'PTF EUR çevrimi';
  ASSERT energy.fn_derived_value('TR_DE_POWER', '2026-09-25') IS NULL, 'eksik bacakta NULL dönmeli';

  ASSERT (SELECT surprise_basis = 'consensus' AND round(surprise) = round(change + 1500)
          FROM energy.v_indicator_changes WHERE indicator_code = 'US_CRUDE_STOCKS' AND period_end = '2026-09-18'),
         'stok sürprizi beklentiye göre hesaplanmalı';
  ASSERT (SELECT surprise_basis FROM energy.v_indicator_changes
          WHERE indicator_code = 'US_CRUDE_STOCKS' AND period_end = '2026-09-11') = 'seasonal_5y',
         'beklenti yoksa 5 yıllık mevsimsel ortalama kullanılmalı';
END $$;

-- Libya (yukarı yönlü) analizi eklenince hareket açıklanmalı
INSERT INTO energy.news_analyses (cluster_id, model, prompt_version, is_relevant, event_type, segments, impacts, novelty, confidence, output)
SELECT id, 'test', 'v1', true, 'supply_outage', '{crude}',
       '[{"segment":"crude","instruments":["BRENT_M1"],"price_direction":"up","magnitude":3,"horizon":"short"}]', 'new', 0.9, '{}'
FROM energy.story_clusters WHERE headline LIKE 'Libya%';

DO $$
DECLARE m record; ctx jsonb; rid uuid;
BEGIN
  SELECT * INTO m FROM energy.fn_detect_moves('2026-09-25') WHERE instrument_code = 'BRENT_SPOT';
  ASSERT m.status = 'explained' AND m.explained_by = ARRAY[(SELECT id FROM energy.story_clusters WHERE headline LIKE 'Libya%')],
         'Libya haberi Brent hareketini açıklamalı';

  ctx := energy.fn_build_context('2026-09-26 08:00+00', '48 hours');
  ASSERT jsonb_array_length(ctx->'news') = 2, 'bağlamda iki haber kümesi olmalı';
  ASSERT ctx->'news'->0->>'headline' LIKE 'Libya%', 'en yüksek skor Libya haberinde olmalı';
  ASSERT ctx->'market_snapshot' @> '[{"instrument":"BRENT_SPOT"}]', 'snapshot Brent içermeli';
  ASSERT ctx->'indicators' @> '[{"code":"US_CRUDE_STOCKS","surprise_basis":"consensus"}]', 'gösterge bağlamda olmalı';

  -- Outbox: aynı dedup_key ile ikinci kayıt açılmaz; hatalı gönderim yeniden denenir
  rid := energy.fn_save_report(jsonb_build_object(
           'report_id', 'aaaaaaaa-0000-4000-8000-000000000001', 'schema_version', '1.0', 'agent', jsonb_build_object('id','energy-news'),
           'report_type', 'daily_close', 'as_of', '2026-09-25T21:00:00Z', 'priority', 'normal', 'summary', '',
           'findings', '[]'::jsonb, 'evidence', '[]'::jsonb, 'data_quality', '{}'::jsonb, 'payload', '{}'::jsonb), 'smoke:daily_close');
  ASSERT energy.fn_save_report(jsonb_build_object(
           'report_id', 'aaaaaaaa-0000-4000-8000-000000000002', 'schema_version', '1.0', 'agent', jsonb_build_object('id','energy-news'),
           'report_type', 'daily_close', 'as_of', '2026-09-25T21:00:00Z', 'priority', 'normal', 'summary', '',
           'findings', '[]'::jsonb, 'evidence', '[]'::jsonb, 'data_quality', '{}'::jsonb, 'payload', '{}'::jsonb), 'smoke:daily_close') = rid,
         'aynı dedup_key mevcut raporu döndürmeli';
  ASSERT energy.fn_mark_delivery(rid, false, 'timeout') = 'pending', 'ilk hatada tekrar denenmeli';
  ASSERT energy.fn_mark_delivery(rid, true) = 'delivered', 'başarılı gönderim';
END $$;

-- n8n giriş fonksiyonları (db/04_ingest.sql)
DO $$
DECLARE r jsonb; cid bigint;
BEGIN
  r := energy.fn_ingest_news(jsonb_build_array(
         jsonb_build_object('source','gnews_rss','url','https://example.test/n1','title','Kerkük-Ceyhan boru hattında akış durdu','published_at', now(),'prefilter_ok',true),
         jsonb_build_object('source','rigzone','url','https://example.test/n2','title','Kerkük-Ceyhan boru hattında akış durdu, fiyatlar yükseldi','published_at', now(),'prefilter_ok',true),
         jsonb_build_object('source','gnews_rss','url','https://example.test/n1','title','tekrar','published_at', now(),'prefilter_ok',true),
         jsonb_build_object('source','lng_prime','url','https://example.test/n3','title','kapalı kaynak','published_at', now(),'prefilter_ok',true)),
       '[{"source":"rigzone","count":1,"error":null},{"source":"eia_news","count":0,"error":"HTTP 503"}]');
  ASSERT r = '{"inserted": 2, "clustered": 2, "skipped": 1}'::jsonb, format('fn_ingest_news: %s', r);
  ASSERT (SELECT is_failing FROM energy.v_source_health WHERE code = 'eia_news'), 'hata veren kaynak işaretlenmeli';

  SELECT cluster_id INTO cid FROM energy.fn_clusters_to_analyze(20) WHERE payload->>'headline' LIKE 'Kerkük%';
  ASSERT cid IS NOT NULL, 'yeni küme analiz listesinde olmalı';
  ASSERT energy.fn_save_analysis(cid, '{"is_relevant":true,"event_type":"bogus"}', 'm', 'v1') LIKE 'invalid:%', 'geçersiz çıktı reddedilmeli';
  ASSERT energy.fn_save_analysis(cid, '{"is_relevant":true,"event_type":"supply_outage","segments":["crude"],"regions":["IQ"],"impacts":[{"segment":"crude","instruments":["BRENT_SPOT"],"price_direction":"up","magnitude":2,"horizon":"short","rationale":"r"}],"novelty":"new","is_rumor":false,"confidence":0.8,"summary_tr":"Akış durdu."}', 'm', 'v1') = 'saved', 'geçerli çıktı kaydedilmeli';
  ASSERT NOT EXISTS (SELECT 1 FROM energy.fn_clusters_to_analyze(20) WHERE cluster_id = cid), 'analiz edilen küme listeden çıkmalı';

  ASSERT energy.fn_upsert_ptf((SELECT jsonb_agg(jsonb_build_object('ts', '2026-09-20T00:00:00+03:00'::timestamptz + make_interval(hours => h), 'value', 2000 + h)) FROM generate_series(0, 23) h)) = 24, 'saatlik PTF';
  ASSERT energy.fn_price_on('TR_PTF_BASE', '2026-09-20') = 2011.5, 'PTF günlük ortalaması';
  ASSERT energy.fn_upsert_indicators('[{"indicator":"US_NG_STORAGE","period_end":"2026-09-18","value":3500}]') = 1, 'gösterge';
  ASSERT (SELECT released_at FROM energy.indicator_values WHERE indicator_code = 'US_NG_STORAGE') = '2026-09-23 14:30+00', 'varsayılan yayın zamanı';
END $$;

\echo 'smoke test OK'
ROLLBACK;
