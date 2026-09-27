-- Enerji ajanı: n8n'in çağırdığı veri giriş/çıkış fonksiyonları
-- n8n sadece veriyi çeker ve JSON olarak buraya verir; eşleme, kayıt ve hata sayımı burada yapılır.
-- Tekrar çalıştırmak güvenlidir.

-- Kaynak çalışmasını kaydet (başarı ya da hata). Rapordaki data_quality bloğu buradan beslenir.
CREATE OR REPLACE FUNCTION energy.fn_record_ingest(p_source text, p_rows int, p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM energy.sources WHERE code = p_source) THEN RETURN; END IF;
  INSERT INTO energy.ingest_runs (source_code, finished_at, status, rows_in, error)
  VALUES (p_source, now(), CASE WHEN p_error IS NULL OR p_error = '' THEN 'ok' ELSE 'error' END,
          coalesce(p_rows, 0), nullif(p_error, ''));
  IF p_error IS NULL OR p_error = '' THEN
    UPDATE energy.sources SET last_success_at = now() WHERE code = p_source;
  ELSE
    UPDATE energy.sources SET last_error_at = now(), last_error = left(p_error, 500) WHERE code = p_source;
  END IF;
END $$;

-- Günlük fiyatlar: [{"instrument":"BRENT_SPOT","date":"2026-09-25","value":67.1,"source":"eia"}]
-- Katalogda olmayan enstrümanlar ve boş değerler atlanır. Dönen değer: yeni ya da değişen satır sayısı.
CREATE OR REPLACE FUNCTION energy.fn_upsert_prices(p_rows jsonb)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_count int;
BEGIN
  INSERT INTO energy.prices_daily AS p (instrument_code, trade_date, value, price_type, source_code)
  SELECT r.instrument, r.date, r.value, coalesce(r.price_type, 'settle'), r.source
  FROM jsonb_to_recordset(coalesce(p_rows, '[]')) AS r(instrument text, date date, value numeric, price_type text, source text)
  JOIN energy.instruments i ON i.code = r.instrument
  WHERE r.value IS NOT NULL AND r.date IS NOT NULL
  ON CONFLICT (instrument_code, trade_date) DO UPDATE
    SET value = EXCLUDED.value, source_code = EXCLUDED.source_code, ingested_at = now()
    WHERE p.value IS DISTINCT FROM EXCLUDED.value;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

-- Göstergeler: [{"indicator":"US_CRUDE_STOCKS","period_end":"2026-09-19","value":415000}]
-- released_at verilmezse dönem sonu + 5 gün 14:30 UTC varsayılır (EIA haftalık yayın düzeni);
-- böylece geçmiş veri yüklenirken eski haftalar "yeni açıklandı" görünmez.
CREATE OR REPLACE FUNCTION energy.fn_upsert_indicators(p_rows jsonb)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_count int;
BEGIN
  INSERT INTO energy.indicator_values AS v (indicator_code, period_end, value, consensus_change, released_at, source_code)
  SELECT r.indicator, r.period_end, r.value, r.consensus_change,
         coalesce(r.released_at, least(now(), ((r.period_end + 5) + time '14:30') AT TIME ZONE 'UTC')),
         i.source_code
  FROM jsonb_to_recordset(coalesce(p_rows, '[]'))
       AS r(indicator text, period_end date, value numeric, consensus_change numeric, released_at timestamptz)
  JOIN energy.indicators i ON i.code = r.indicator
  WHERE r.value IS NOT NULL AND r.period_end IS NOT NULL
  ON CONFLICT (indicator_code, period_end) DO UPDATE
    SET value = EXCLUDED.value,
        consensus_change = coalesce(EXCLUDED.consensus_change, v.consensus_change),
        ingested_at = now()
    WHERE v.value IS DISTINCT FROM EXCLUDED.value
       OR v.consensus_change IS DISTINCT FROM coalesce(EXCLUDED.consensus_change, v.consensus_change);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $$;

-- EPİAŞ saatlik PTF: [{"ts":"2026-09-26T00:00:00+03:00","value":2950.5}]
-- Saatlik veri TR_PTF_HOURLY'ye yazılır; 24 saati tamam olan günlerin ortalaması TR_PTF_BASE olur.
CREATE OR REPLACE FUNCTION energy.fn_upsert_ptf(p_rows jsonb)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_count int;
BEGIN
  INSERT INTO energy.prices_intraday AS p (instrument_code, ts, value, source_code)
  SELECT 'TR_PTF_HOURLY', r.ts, r.value, 'epias'
  FROM jsonb_to_recordset(coalesce(p_rows, '[]')) AS r(ts timestamptz, value numeric)
  WHERE r.ts IS NOT NULL AND r.value IS NOT NULL
  ON CONFLICT (instrument_code, ts) DO UPDATE SET value = EXCLUDED.value, ingested_at = now()
    WHERE p.value IS DISTINCT FROM EXCLUDED.value;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  INSERT INTO energy.prices_daily AS d (instrument_code, trade_date, value, price_type, source_code)
  SELECT 'TR_PTF_BASE', (h.ts AT TIME ZONE 'Europe/Istanbul')::date, round(avg(h.value), 2), 'average', 'epias'
  FROM energy.prices_intraday h
  WHERE h.instrument_code = 'TR_PTF_HOURLY'
    AND (h.ts AT TIME ZONE 'Europe/Istanbul')::date IN (
          SELECT DISTINCT (r.ts AT TIME ZONE 'Europe/Istanbul')::date
          FROM jsonb_to_recordset(coalesce(p_rows, '[]')) AS r(ts timestamptz))
  GROUP BY 1, 2
  HAVING count(*) >= 24
  ON CONFLICT (instrument_code, trade_date) DO UPDATE SET value = EXCLUDED.value, ingested_at = now()
    WHERE d.value IS DISTINCT FROM EXCLUDED.value;
  RETURN v_count;
END $$;

-- Haberler: p_items = [{"source","url","title","summary","published_at","lang","prefilter_ok"}]
--           p_status = [{"source","count","error"}]  (her beslemenin sonucu; kaynak sağlığı için)
-- Yeni haberleri ekler, ön filtreden geçenleri kümeler. 3 günden eski haberler ve kapalı kaynaklar alınmaz.
CREATE OR REPLACE FUNCTION energy.fn_ingest_news(p_items jsonb, p_status jsonb DEFAULT '[]')
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  r record;
  v_id bigint;
  v_inserted int := 0;
  v_clustered int := 0;
  v_skipped int := 0;
BEGIN
  FOR r IN
    SELECT x.*, s.code IS NOT NULL AS known
    FROM jsonb_to_recordset(coalesce(p_items, '[]'))
         AS x(source text, url text, title text, summary text, published_at timestamptz, lang text, prefilter_ok boolean)
    LEFT JOIN energy.sources s ON s.code = x.source AND s.kind = 'news' AND s.is_enabled   -- kapalı kaynak alınmaz
  LOOP
    IF NOT r.known OR coalesce(r.url, '') = '' OR coalesce(btrim(r.title), '') = ''
       OR r.published_at < now() - interval '3 days' THEN
      v_skipped := v_skipped + 1;
      CONTINUE;
    END IF;

    INSERT INTO energy.news_items (source_code, url, title, summary, lang, published_at, prefilter_ok)
    VALUES (r.source, r.url, left(btrim(r.title), 500), left(r.summary, 2000), r.lang,
            -- Gelecek tarihli ya da tarihsiz haberde toplama zamanı kullanılır
            CASE WHEN r.published_at IS NULL OR r.published_at > now() + interval '1 hour' THEN now() ELSE r.published_at END,
            coalesce(r.prefilter_ok, true))
    ON CONFLICT (url_hash) DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NOT NULL THEN
      v_inserted := v_inserted + 1;
      IF energy.fn_assign_cluster(v_id) IS NOT NULL THEN v_clustered := v_clustered + 1; END IF;
    END IF;
  END LOOP;

  PERFORM energy.fn_record_ingest(st.source, st.count, st.error)
  FROM jsonb_to_recordset(coalesce(p_status, '[]')) AS st(source text, count int, error text);

  RETURN jsonb_build_object('inserted', v_inserted, 'clustered', v_clustered, 'skipped', v_skipped);
END $$;

-- LLM'e gidecek kümeler: analiz bekleyen, 3 denemeden az başarısız olmuş, son 3 günde görülmüş.
-- Tier 1 kaynaklı kümeler önce gelir.
CREATE OR REPLACE FUNCTION energy.fn_clusters_to_analyze(p_limit int DEFAULT 20)
RETURNS TABLE (cluster_id bigint, item_count int, payload jsonb)
LANGUAGE sql STABLE AS $$
  SELECT c.id, c.item_count,
         jsonb_build_object(
           'cluster_id', c.id,
           'headline', c.headline,
           'first_seen_at', c.first_seen_at,
           'source_count', c.source_count,
           'items', (SELECT jsonb_agg(jsonb_build_object(
                              'source', s.name, 'tier', s.tier, 'title', n.title,
                              'summary', left(n.summary, 600), 'published_at', n.published_at)
                            ORDER BY s.tier, n.published_at DESC)
                     FROM (SELECT * FROM energy.news_items ni WHERE ni.cluster_id = c.id
                           ORDER BY ni.published_at DESC LIMIT 8) n
                     JOIN energy.sources s ON s.code = n.source_code),
           'previous_analysis', (SELECT jsonb_build_object('event_type', a.event_type, 'summary_tr', a.summary_tr,
                                                           'analyzed_at', a.analyzed_at)
                                 FROM energy.news_analyses a WHERE a.cluster_id = c.id
                                 ORDER BY a.analyzed_at DESC LIMIT 1))
  FROM energy.story_clusters c
  WHERE c.needs_analysis AND c.analysis_attempts < 3 AND c.last_seen_at > now() - interval '3 days'
  ORDER BY c.best_tier, c.last_seen_at DESC
  LIMIT p_limit
$$;

-- LLM çıktısını contracts/news-analysis.schema.json kurallarına göre kontrol eder; hata listesini döner.
CREATE OR REPLACE FUNCTION energy.fn_analysis_errors(p jsonb)
RETURNS text[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  e text[] := '{}';
  seg text[] := ARRAY['crude','refined_products','natural_gas','power','carbon'];
  im jsonb;
  s text;
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN ARRAY['çıktı JSON nesnesi değil']; END IF;
  IF jsonb_typeof(p->'is_relevant') IS DISTINCT FROM 'boolean' THEN e := array_append(e, 'is_relevant boolean olmalı'); END IF;
  IF NOT coalesce(p->>'event_type' = ANY (ARRAY['supply_opec_policy','supply_outage','geopolitics_conflict','sanctions_trade',
        'inventories_data','demand_macro','refining','lng_shipping','weather','power_grid','renewables',
        'policy_regulation','carbon_market','corporate','market_positioning','other']), false) THEN
    e := array_append(e, ('geçersiz event_type: ' || coalesce(p->>'event_type', 'yok')));
  END IF;
  IF jsonb_typeof(p->'segments') IS DISTINCT FROM 'array' THEN
    e := array_append(e, 'segments dizi olmalı');
  ELSE
    FOR s IN SELECT jsonb_array_elements_text(p->'segments') LOOP
      IF NOT s = ANY (seg) THEN e := array_append(e, ('geçersiz segment: ' || s)); END IF;
    END LOOP;
  END IF;
  IF jsonb_typeof(p->'regions') IS DISTINCT FROM 'array' THEN e := array_append(e, 'regions dizi olmalı'); END IF;
  IF jsonb_typeof(p->'impacts') IS DISTINCT FROM 'array' THEN
    e := array_append(e, 'impacts dizi olmalı');
  ELSE
    FOR im IN SELECT jsonb_array_elements(p->'impacts') LOOP
      IF NOT coalesce(im->>'segment' = ANY (seg), false) THEN e := array_append(e, 'impact.segment geçersiz'); END IF;
      IF NOT coalesce(im->>'price_direction' IN ('up','down','neutral','uncertain'), false) THEN e := array_append(e, 'impact.price_direction geçersiz'); END IF;
      IF NOT coalesce(im->>'horizon' IN ('intraday','short','medium','long'), false) THEN e := array_append(e, 'impact.horizon geçersiz'); END IF;
      IF jsonb_typeof(im->'magnitude') IS DISTINCT FROM 'number'
         OR (im->>'magnitude')::numeric NOT IN (0, 1, 2, 3) THEN e := array_append(e, 'impact.magnitude 0-3 tam sayı olmalı'); END IF;
    END LOOP;
  END IF;
  IF NOT coalesce(p->>'novelty' IN ('new','update','repeat'), false) THEN e := array_append(e, 'novelty geçersiz'); END IF;
  IF jsonb_typeof(p->'is_rumor') IS DISTINCT FROM 'boolean' THEN e := array_append(e, 'is_rumor boolean olmalı'); END IF;
  IF jsonb_typeof(p->'confidence') IS DISTINCT FROM 'number'
     OR (p->>'confidence')::numeric NOT BETWEEN 0 AND 1 THEN e := array_append(e, 'confidence 0-1 arası olmalı'); END IF;
  IF jsonb_typeof(p->'summary_tr') IS DISTINCT FROM 'string' THEN e := array_append(e, 'summary_tr metin olmalı'); END IF;
  RETURN e;
END $$;

-- LLM analizini kaydet. Geçersiz ya da boş çıktıda deneme sayısı artar (3 denemeden sonra küme atlanır).
-- Dönen değer: 'saved' | 'invalid: <hatalar>'
CREATE OR REPLACE FUNCTION energy.fn_save_analysis(p_cluster_id bigint, p_output jsonb, p_model text,
                                                   p_prompt_version text, p_input_tokens int DEFAULT NULL,
                                                   p_output_tokens int DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_errors text[] := energy.fn_analysis_errors(p_output);
BEGIN
  IF cardinality(v_errors) > 0 THEN
    UPDATE energy.story_clusters SET analysis_attempts = analysis_attempts + 1 WHERE id = p_cluster_id;
    RETURN 'invalid: ' || array_to_string(v_errors, '; ');
  END IF;

  INSERT INTO energy.news_analyses (cluster_id, model, prompt_version, is_relevant, event_type, segments, regions,
                                    impacts, novelty, is_rumor, confidence, summary_tr, output,
                                    cluster_item_count, input_tokens, output_tokens)
  SELECT p_cluster_id, p_model, p_prompt_version, (p_output->>'is_relevant')::boolean, p_output->>'event_type',
         ARRAY(SELECT jsonb_array_elements_text(p_output->'segments')),
         ARRAY(SELECT jsonb_array_elements_text(p_output->'regions')),
         p_output->'impacts', p_output->>'novelty', (p_output->>'is_rumor')::boolean,
         (p_output->>'confidence')::numeric, left(p_output->>'summary_tr', 400), p_output,
         c.item_count, p_input_tokens, p_output_tokens
  FROM energy.story_clusters c WHERE c.id = p_cluster_id;

  UPDATE energy.story_clusters SET analysis_attempts = 0 WHERE id = p_cluster_id;
  RETURN 'saved';
END $$;

-- Son günlerdeki olağan dışı hareketleri tespit et (rapordan hemen önce çağrılır)
CREATE OR REPLACE FUNCTION energy.fn_detect_recent_moves(p_days int DEFAULT 4)
RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int
  FROM generate_series(current_date - p_days, current_date, interval '1 day') d
  CROSS JOIN LATERAL energy.fn_detect_moves(d::date)
$$;

-- Analist ajana gönderilmeyi bekleyen raporlar. body_text imzalanan ve gönderilen metnin kendisidir.
CREATE OR REPLACE FUNCTION energy.fn_due_reports(p_limit int DEFAULT 10)
RETURNS TABLE (report_id uuid, report_type text, body_text text)
LANGUAGE sql STABLE AS $$
  SELECT r.report_id, r.report_type, r.body::text
  FROM energy.reports r
  WHERE r.delivery_status = 'pending' AND r.next_attempt_at <= now()
  ORDER BY r.as_of
  LIMIT p_limit
$$;
