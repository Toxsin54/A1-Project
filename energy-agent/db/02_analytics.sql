-- Enerji ajanı: deterministik hesaplar (LLM'siz)
-- Rapordaki her sayı buradan gelir; LLM sayı üretmez, sadece yorumlar.
-- Tekrar çalıştırmak güvenlidir.

-- Kaynak ağırlıkları ve skor ayarları
CREATE OR REPLACE FUNCTION energy.fn_tier_weight(p_tier smallint) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_tier WHEN 1 THEN 1.0 WHEN 2 THEN 0.8 ELSE 0.5 END
$$;

-- 1) Günlük değişimler ve z-skor
-- zscore_1d: bugünkü getirinin önceki 60 gözlemin getiri oynaklığına oranı (bugün hariç)
CREATE OR REPLACE VIEW energy.v_daily_changes AS
WITH r AS (
  SELECT p.instrument_code, p.trade_date, p.value,
         lag(p.value)     OVER w AS prev_value,
         lag(p.value, 5)  OVER w AS value_5d,
         lag(p.value, 20) OVER w AS value_20d
  FROM energy.prices_daily p
  WINDOW w AS (PARTITION BY p.instrument_code ORDER BY p.trade_date)
), c AS (
  SELECT r.*,
         -- Fiyat sıfıra yakın ya da negatif olabilen serilerde (elektrik, spread) yüzde değişim anlamsızdır
         CASE WHEN r.prev_value > 0 THEN (r.value / r.prev_value - 1) * 100 END AS change_1d_pct,
         CASE WHEN r.value_5d  > 0 THEN (r.value / r.value_5d  - 1) * 100 END AS change_5d_pct,
         CASE WHEN r.value_20d > 0 THEN (r.value / r.value_20d - 1) * 100 END AS change_20d_pct,
         r.value - r.prev_value AS change_1d
  FROM r
)
SELECT c.*,
       stddev_samp(c.change_1d_pct) OVER (PARTITION BY c.instrument_code ORDER BY c.trade_date
                                          ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING) AS vol_60,
       count(c.change_1d_pct) OVER (PARTITION BY c.instrument_code ORDER BY c.trade_date
                                    ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING) AS n_60
FROM c;

-- 2) Belirli bir tarih itibarıyla anlık görüntü (her aktif enstrümanın son değeri)
CREATE OR REPLACE FUNCTION energy.fn_snapshot(p_as_of date)
RETURNS TABLE (instrument text, name text, segment text, unit text, region text, value numeric,
               as_of date, change_1d numeric, change_1d_pct numeric, change_5d_pct numeric,
               change_20d_pct numeric, zscore_1d numeric, is_stale boolean, source text)
LANGUAGE sql STABLE AS $$
  SELECT i.code, i.name, i.segment, i.unit, i.region, round(d.value, 4), d.trade_date,
         round(d.change_1d, 4), round(d.change_1d_pct, 2), round(d.change_5d_pct, 2), round(d.change_20d_pct, 2),
         CASE WHEN d.n_60 >= 20 AND d.vol_60 > 0 THEN round(d.change_1d_pct / d.vol_60, 2) END,
         d.trade_date IS NULL OR d.trade_date < p_as_of - i.max_staleness,
         i.source_code
  FROM energy.instruments i
  LEFT JOIN LATERAL (
    SELECT * FROM energy.v_daily_changes v
    WHERE v.instrument_code = i.code AND v.trade_date <= p_as_of
    ORDER BY v.trade_date DESC LIMIT 1
  ) d ON true
  -- Kaynağı kapalı olan seriler (ör. lisans alınmamış) rapora girmez ve "bayat" sayılmaz
  WHERE i.is_active
    AND EXISTS (SELECT 1 FROM energy.sources s WHERE s.code = i.source_code AND s.is_enabled)
  ORDER BY i.segment, i.code
$$;

-- 3) Türetilmiş metrikler (spread, crack, spark spread...)
-- Her bacak için p_date itibarıyla en fazla 7 gün eski son fiyat kullanılır; eksik bacak varsa NULL döner.
CREATE OR REPLACE FUNCTION energy.fn_price_on(p_code text, p_date date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT value FROM energy.prices_daily
  WHERE instrument_code = p_code AND trade_date <= p_date AND trade_date > p_date - 7
  ORDER BY trade_date DESC LIMIT 1
$$;

CREATE OR REPLACE FUNCTION energy.fn_derived_value(p_code text, p_date date) RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_total numeric := 0;
  v_leg   numeric;
  l       jsonb;
BEGIN
  FOR l IN SELECT jsonb_array_elements(legs) FROM energy.derived_metrics WHERE code = p_code LOOP
    v_leg := (l->>'c')::numeric * energy.fn_price_on(l->>'i', p_date);
    IF l ? 'mul' THEN v_leg := v_leg * energy.fn_price_on(l->>'mul', p_date); END IF;
    IF l ? 'div' THEN v_leg := v_leg / nullif(energy.fn_price_on(l->>'div', p_date), 0); END IF;
    IF v_leg IS NULL THEN RETURN NULL; END IF;
    v_total := v_total + v_leg;
  END LOOP;
  RETURN round(v_total, 4);
END $$;

-- Son değer ve bir önceki işlem gününe göre değişim.
-- "Tarih" olarak ilk bacağın p_as_of itibarıyla son işlem günü alınır.
CREATE OR REPLACE FUNCTION energy.fn_derived_snapshot(p_as_of date)
RETURNS TABLE (code text, name text, segment text, unit text, as_of date, value numeric, change_1d numeric)
LANGUAGE sql STABLE AS $$
  WITH d AS (
    SELECT m.*,
           (SELECT max(trade_date) FROM energy.prices_daily
             WHERE instrument_code = m.legs->0->>'i' AND trade_date <= p_as_of) AS d0
    FROM energy.derived_metrics m WHERE m.is_active
  ), d1 AS (
    SELECT d.*,
           (SELECT max(trade_date) FROM energy.prices_daily
             WHERE instrument_code = d.legs->0->>'i' AND trade_date < d.d0) AS d_prev
    FROM d
  )
  SELECT d1.code, d1.name, d1.segment, d1.unit, d1.d0,
         energy.fn_derived_value(d1.code, d1.d0),
         energy.fn_derived_value(d1.code, d1.d0) - energy.fn_derived_value(d1.code, d1.d_prev)
  FROM d1
  WHERE d1.d0 IS NOT NULL
  ORDER BY d1.segment, d1.code
$$;

-- 4) Gösterge sürprizi
-- Önce piyasa beklentisi (consensus_change) kullanılır; yoksa son 5 yılın aynı haftasındaki ortalama değişim.
CREATE OR REPLACE VIEW energy.v_indicator_changes AS
WITH c AS (
  SELECT v.*, i.name, i.segment, i.unit, i.frequency, i.price_sign,
         v.value - lag(v.value) OVER (PARTITION BY v.indicator_code ORDER BY v.period_end) AS change
  FROM energy.indicator_values v
  JOIN energy.indicators i ON i.code = v.indicator_code
)
SELECT c.*,
       s.seasonal_change,
       CASE WHEN c.consensus_change IS NOT NULL THEN c.change - c.consensus_change
            WHEN s.seasonal_change  IS NOT NULL THEN c.change - s.seasonal_change END AS surprise,
       CASE WHEN c.consensus_change IS NOT NULL THEN 'consensus'
            WHEN s.seasonal_change  IS NOT NULL THEN 'seasonal_5y' ELSE 'none' END AS surprise_basis
FROM c
LEFT JOIN LATERAL (
  SELECT avg(h.change) AS seasonal_change
  FROM c h
  WHERE c.frequency = 'weekly'
    AND h.indicator_code = c.indicator_code
    AND h.period_end <  c.period_end - 300
    AND h.period_end >= c.period_end - interval '5 years 7 days'
    AND extract(week FROM h.period_end) = extract(week FROM c.period_end)
) s ON true;

-- 5) Haber kümeleme
-- Son 48 saatte başlığı yeterince benzeyen bir küme varsa haberi ona ekler, yoksa yeni küme açar.
-- Kümeye daha iyi bir kaynak (düşük tier) katılırsa ya da küme 2 kattan fazla büyürse yeniden analiz istenir.
-- Farklı dillerdeki aynı haberler bu yöntemle birleşmez; bunun için 3. fazda embedding (pgvector) eklenecek.
CREATE OR REPLACE FUNCTION energy.fn_assign_cluster(p_news_id bigint, p_threshold real DEFAULT 0.45)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  n       record;
  v_tier  smallint;
  v_id    bigint;
  v_seen  timestamptz;
BEGIN
  SELECT * INTO n FROM energy.news_items WHERE id = p_news_id;
  IF n.id IS NULL OR NOT n.prefilter_ok THEN RETURN NULL; END IF;
  IF n.cluster_id IS NOT NULL THEN RETURN n.cluster_id; END IF;

  SELECT tier INTO v_tier FROM energy.sources WHERE code = n.source_code;
  v_seen := coalesce(n.published_at, n.fetched_at);

  SELECT c.id INTO v_id
  FROM energy.story_clusters c
  WHERE c.last_seen_at > v_seen - interval '48 hours'
    AND similarity(c.headline, n.title) >= p_threshold
  ORDER BY similarity(c.headline, n.title) DESC
  LIMIT 1
  FOR UPDATE;

  IF v_id IS NULL THEN
    INSERT INTO energy.story_clusters (headline, first_seen_at, last_seen_at, best_tier)
    VALUES (n.title, v_seen, v_seen, v_tier)
    RETURNING id INTO v_id;
  ELSE
    UPDATE energy.story_clusters c SET
      last_seen_at = greatest(c.last_seen_at, v_seen),
      first_seen_at = least(c.first_seen_at, v_seen),
      item_count   = c.item_count + 1,
      source_count = (SELECT count(DISTINCT source_code) + CASE WHEN bool_or(source_code = n.source_code) THEN 0 ELSE 1 END
                        FROM energy.news_items WHERE cluster_id = c.id),
      headline     = CASE WHEN v_tier < c.best_tier THEN n.title ELSE c.headline END,
      best_tier    = least(c.best_tier, v_tier),
      needs_analysis = c.needs_analysis OR v_tier < c.best_tier
                       OR (c.item_count + 1) > 2 * coalesce((
                            SELECT a.cluster_item_count FROM energy.news_analyses a
                            WHERE a.cluster_id = c.id ORDER BY a.analyzed_at DESC LIMIT 1), c.item_count)
    WHERE c.id = v_id;
  END IF;

  UPDATE energy.news_items SET cluster_id = v_id WHERE id = p_news_id;
  RETURN v_id;
END $$;

-- Analiz kaydedilince küme "analiz bekliyor" listesinden çıkar
CREATE OR REPLACE FUNCTION energy.trg_analysis_done() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE energy.story_clusters SET needs_analysis = false WHERE id = NEW.cluster_id;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS analysis_done ON energy.news_analyses;
CREATE TRIGGER analysis_done AFTER INSERT ON energy.news_analyses
  FOR EACH ROW EXECUTE FUNCTION energy.trg_analysis_done();

-- 6) Küme skoru: etkinin büyüklüğü x güven x kaynak ağırlığı x yenilik x kaynak sayısı x zaman aşımı
-- En güncel analiz kullanılır. Skor 0-3 aralığındadır; zaman aşımı yarılanma süresi 24 saat.
CREATE OR REPLACE FUNCTION energy.fn_cluster_scores(p_as_of timestamptz, p_lookback interval DEFAULT '24 hours')
RETURNS TABLE (cluster_id bigint, headline text, first_seen_at timestamptz, best_tier smallint,
               source_count int, event_type text, segments text[], regions text[], impacts jsonb,
               novelty text, is_rumor boolean, confidence numeric, summary_tr text, score numeric)
LANGUAGE sql STABLE AS $$
  SELECT c.id, c.headline, c.first_seen_at, c.best_tier, c.source_count,
         a.event_type, a.segments, a.regions, a.impacts, a.novelty, a.is_rumor, a.confidence, a.summary_tr,
         round((
           coalesce((SELECT max((x->>'magnitude')::numeric) FROM jsonb_array_elements(a.impacts) x), 0)
           * coalesce(a.confidence, 0.5)
           * energy.fn_tier_weight(c.best_tier)
           * CASE a.novelty WHEN 'new' THEN 1.0 WHEN 'update' THEN 0.7 ELSE 0.3 END
           * CASE WHEN a.is_rumor THEN 0.5 ELSE 1.0 END
           * (1 + 0.1 * least(c.source_count - 1, 5))
           * power(0.5, greatest(extract(epoch FROM p_as_of - c.first_seen_at), 0) / 86400.0)
         )::numeric, 3)
  FROM energy.story_clusters c
  JOIN LATERAL (
    SELECT * FROM energy.news_analyses x WHERE x.cluster_id = c.id ORDER BY x.analyzed_at DESC LIMIT 1
  ) a ON true
  WHERE a.is_relevant
    AND c.first_seen_at <= p_as_of
    AND c.last_seen_at  >  p_as_of - p_lookback
$$;

-- 7) Olağan dışı fiyat hareketlerini bul ve aynı segmentteki haberlerle eşleştir
-- Eşleştirme penceresi: işlem gününden bir gün önce başlayıp işlem günü sonunda biter (UTC).
-- Uygun haber yoksa hareket 'unexplained' kalır; bu da ayrı bir sinyaldir (haber henüz düşmemiş olabilir).
CREATE OR REPLACE FUNCTION energy.fn_detect_moves(p_date date)
RETURNS SETOF energy.market_moves LANGUAGE sql AS $$
  INSERT INTO energy.market_moves AS m (instrument_code, trade_date, change_pct, zscore, explained_by, status)
  SELECT s.instrument, s.as_of, s.change_1d_pct, s.zscore_1d,
         coalesce(e.ids, '{}'),
         CASE WHEN e.ids IS NULL THEN 'unexplained' ELSE 'explained' END
  FROM energy.fn_snapshot(p_date) s
  JOIN energy.instruments i ON i.code = s.instrument
  LEFT JOIN LATERAL (
    SELECT array_agg(cs.cluster_id ORDER BY cs.score DESC) AS ids
    FROM (
      SELECT * FROM energy.fn_cluster_scores((s.as_of + 1)::timestamp AT TIME ZONE 'UTC', interval '48 hours') x
      WHERE x.score > 0
        -- Haber aynı segmentte ve hareketle aynı yönde (ya da yönü belirsiz) bir etki öngörmeli
        AND EXISTS (SELECT 1 FROM jsonb_array_elements(x.impacts) im
                    WHERE im->>'segment' = s.segment
                      AND im->>'price_direction' IN (CASE WHEN s.change_1d > 0 THEN 'up' ELSE 'down' END, 'uncertain'))
      ORDER BY x.score DESC LIMIT 3
    ) cs
  ) e ON true
  WHERE s.as_of = p_date
    AND i.segment <> 'fx'
    AND (abs(s.zscore_1d) >= i.alert_zscore OR abs(s.change_1d_pct) >= i.alert_move_pct)
  ON CONFLICT (instrument_code, trade_date) DO UPDATE
    SET change_pct = EXCLUDED.change_pct, zscore = EXCLUDED.zscore,
        explained_by = EXCLUDED.explained_by, status = EXCLUDED.status
  RETURNING m.*
$$;

-- 8) Kaynak sağlığı
CREATE OR REPLACE VIEW energy.v_source_health AS
SELECT s.code, s.name, s.kind, s.tier, s.is_enabled, s.poll_interval,
       s.last_success_at, s.last_error_at, s.last_error,
       s.is_enabled AND (
         s.last_success_at IS NULL
         OR s.last_success_at < now() - greatest(coalesce(s.poll_interval, interval '1 day') * 3, interval '30 minutes')
         OR coalesce(s.last_error_at > s.last_success_at, false)
       ) AS is_failing
FROM energy.sources s;

-- 9) Rapor bağlam paketi: rapor yazan LLM'e verilen tek girdi.
-- LLM sadece bu paketteki evidence id'lerine atıf yapabilir; doğrulayıcı bunu kontrol eder.
CREATE OR REPLACE FUNCTION energy.fn_build_context(p_as_of timestamptz, p_lookback interval DEFAULT '24 hours',
                                                   p_news_limit int DEFAULT 15)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH d AS (SELECT (p_as_of AT TIME ZONE 'UTC')::date AS day)
  SELECT jsonb_build_object(
    'as_of', p_as_of,
    'lookback', p_lookback::text,
    'market_snapshot', coalesce((
      SELECT jsonb_agg(to_jsonb(s) || jsonb_build_object('evidence_id', 'px:' || s.instrument || ':' || s.as_of))
      FROM energy.fn_snapshot((SELECT day FROM d)) s WHERE s.value IS NOT NULL), '[]'),
    'derived_metrics', coalesce((
      SELECT jsonb_agg(to_jsonb(m) || jsonb_build_object('evidence_id', 'dm:' || m.code || ':' || m.as_of))
      FROM energy.fn_derived_snapshot((SELECT day FROM d)) m WHERE m.value IS NOT NULL), '[]'),
    'indicators', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'code', v.indicator_code, 'name', v.name, 'segment', v.segment, 'unit', v.unit,
               'value', v.value, 'period_end', v.period_end, 'released_at', v.released_at,
               'change', v.change, 'consensus_change', v.consensus_change,
               'surprise', round(v.surprise, 3), 'surprise_basis', v.surprise_basis,
               'price_sign', v.price_sign,
               'evidence_id', 'ind:' || v.indicator_code || ':' || v.period_end) ORDER BY v.released_at DESC)
      FROM energy.v_indicator_changes v
      WHERE v.released_at >  p_as_of - greatest(p_lookback, interval '7 days')
        AND v.released_at <= p_as_of), '[]'),
    'news', coalesce((
      SELECT jsonb_agg(to_jsonb(n) || jsonb_build_object(
               'evidence_id', 'news:' || n.cluster_id,
               'sources', (SELECT jsonb_agg(DISTINCT jsonb_build_object('source', ni.source_code, 'url', ni.url))
                             FROM energy.news_items ni WHERE ni.cluster_id = n.cluster_id)) ORDER BY n.score DESC)
      FROM (SELECT * FROM energy.fn_cluster_scores(p_as_of, p_lookback) ORDER BY score DESC LIMIT p_news_limit) n), '[]'),
    'market_moves', coalesce((
      SELECT jsonb_agg(to_jsonb(m) ORDER BY abs(m.zscore) DESC NULLS LAST)
      FROM energy.market_moves m
      WHERE m.trade_date > (SELECT day FROM d) - 3 AND m.trade_date <= (SELECT day FROM d)), '[]'),
    'calendar', coalesce((
      SELECT jsonb_agg(jsonb_build_object('code', e.code, 'name', e.name, 'segment', e.segment,
                                          'scheduled_at', e.scheduled_at, 'importance', e.importance)
                       ORDER BY e.scheduled_at)
      FROM energy.calendar_events e
      WHERE e.status = 'scheduled' AND e.scheduled_at > p_as_of AND e.scheduled_at <= p_as_of + interval '7 days'), '[]'),
    'data_quality', jsonb_build_object(
      'stale_inputs', coalesce((
        SELECT jsonb_agg(s.instrument) FROM energy.fn_snapshot((SELECT day FROM d)) s WHERE s.is_stale), '[]'),
      'failed_sources', coalesce((
        SELECT jsonb_agg(h.code) FROM energy.v_source_health h WHERE h.is_failing), '[]'))
  )
$$;

-- 10) Raporu outbox'a yaz. Aynı dedup_key ile ikinci kez çağrılırsa mevcut rapor döner.
CREATE OR REPLACE FUNCTION energy.fn_save_report(p_body jsonb, p_dedup_key text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO energy.reports (report_id, report_type, schema_version, as_of, priority, dedup_key, body)
  VALUES ((p_body->>'report_id')::uuid, p_body->>'report_type', p_body->>'schema_version',
          (p_body->>'as_of')::timestamptz, p_body->>'priority', p_dedup_key, p_body)
  ON CONFLICT (dedup_key) DO NOTHING
  RETURNING report_id INTO v_id;

  IF v_id IS NULL THEN
    SELECT report_id INTO v_id FROM energy.reports WHERE dedup_key = p_dedup_key;
  END IF;
  RETURN v_id;
END $$;

-- Gönderim sonucu: başarısızsa 1, 5, 15, 60 dakika sonra tekrar denenir; 5. denemeden sonra 'failed'.
CREATE OR REPLACE FUNCTION energy.fn_mark_delivery(p_report_id uuid, p_ok boolean, p_error text DEFAULT NULL)
RETURNS text LANGUAGE sql AS $$
  UPDATE energy.reports SET
    delivery_attempts = delivery_attempts + 1,
    delivery_status = CASE WHEN p_ok THEN 'delivered' WHEN delivery_attempts + 1 >= 5 THEN 'failed' ELSE 'pending' END,
    delivered_at    = CASE WHEN p_ok THEN now() END,
    last_error      = CASE WHEN p_ok THEN NULL ELSE p_error END,
    next_attempt_at = now() + (ARRAY[interval '1 minute', interval '5 minutes', interval '15 minutes', interval '60 minutes', interval '60 minutes'])[least(delivery_attempts + 1, 5)]
  WHERE report_id = p_report_id
  RETURNING delivery_status
$$;

-- Analist ajan için salt okunur rol (pull modu)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'energy_reader') THEN
    CREATE ROLE energy_reader NOLOGIN;
  END IF;
END $$;
GRANT USAGE ON SCHEMA energy TO energy_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA energy TO energy_reader;
GRANT EXECUTE ON FUNCTION energy.fn_snapshot(date), energy.fn_derived_snapshot(date),
                          energy.fn_cluster_scores(timestamptz, interval),
                          energy.fn_build_context(timestamptz, interval, int) TO energy_reader;
