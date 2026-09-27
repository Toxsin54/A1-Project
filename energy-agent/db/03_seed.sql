-- Enerji ajanı: başlangıç kataloğu (kaynaklar, enstrümanlar, türetilmiş metrikler, göstergeler)
-- Tekrar çalıştırmak güvenlidir: kayıtlar koda göre güncellenir.
-- Seri kodlarını ve RSS adreslerini kurulumda sağlayıcının güncel dokümantasyonundan doğrulayın.
-- Açık gelen kaynaklar n8n/energy-agent-workflow.json'un bağladıklarıdır (EIA, EPİAŞ, TCMB, EIA/Rigzone RSS,
-- Google News, GDELT). Diğerleri toplayıcısı eklenince ya da lisans alınınca açılır:
--   UPDATE energy.sources SET is_enabled = true WHERE code = '...';
-- Tekrar çalıştırmak is_enabled değerini değiştirmez.

INSERT INTO energy.sources (code, name, kind, access, tier, base_url, license, store_body, poll_interval, is_enabled) VALUES
  -- Piyasa verisi
  ('eia',        'ABD Enerji Bilgi İdaresi (EIA) API v2',           'market_data', 'api',  1, 'https://api.eia.gov/v2/',                      'free-key', false, '6 hours',  true),
  ('epias',      'EPİAŞ Şeffaflık Platformu',                        'market_data', 'api',  1, 'https://seffaflik.epias.com.tr/',              'free-key', false, '1 hour',   true),
  ('entsoe',     'ENTSO-E Transparency Platform',                    'market_data', 'api',  1, 'https://web-api.tp.entsoe.eu/api',             'free-key', false, '6 hours',  false),
  ('eex_auction','EEX birincil EUA ihale sonuçları',                 'market_data', 'file', 1, 'https://www.eex.com/',                         'free',     false, '1 day',    false),
  ('tcmb',       'TCMB gösterge döviz kurları',                      'market_data', 'api',  1, 'https://www.tcmb.gov.tr/kurlar/today.xml',     'free',     false, '1 day',    true),
  ('ecb',        'ECB referans döviz kurları',                       'market_data', 'api',  1, 'https://www.ecb.europa.eu/stats/eurofxref/',   'free',     false, '1 day',    false),
  ('licensed',   'Lisanslı vadeli fiyat sağlayıcısı (ICE/NYMEX/JKM)', 'market_data', 'api',  1, NULL,                                           'paid',     false, '15 minutes', false),
  -- Temel göstergeler
  ('gie_agsi',   'GIE AGSI+ (AB gaz depolama)',                      'fundamental', 'api',  1, 'https://agsi.gie.eu/api',                      'free-key', false, '12 hours', false),
  ('cftc',       'CFTC Commitments of Traders',                      'fundamental', 'api',  1, 'https://publicreporting.cftc.gov/',            'free',     false, '1 day',    false),
  ('baker_hughes','Baker Hughes sondaj kulesi sayısı',                'fundamental', 'file', 1, 'https://rigcount.bakerhughes.com/',            'free',     false, '1 day',    false),
  -- Haber: birincil / resmî (tier 1)
  ('opec',       'OPEC basın bültenleri',                            'news',        'scrape', 1, 'https://www.opec.org/',                      'free',     false, '30 minutes', false),
  ('iea',        'IEA haberler',                                     'news',        'rss',  1, 'https://www.iea.org/',                         'free',     false, '30 minutes', false),
  ('eia_news',   'EIA Today in Energy / basın',                      'news',        'rss',  1, 'https://www.eia.gov/',                         'free',     true,  '30 minutes', true),
  ('etkb',       'T.C. Enerji ve Tabii Kaynaklar Bakanlığı',         'news',        'scrape', 1, 'https://enerji.gov.tr/',                     'free',     false, '30 minutes', false),
  ('epdk',       'EPDK duyuru ve kurul kararları',                   'news',        'scrape', 1, 'https://www.epdk.gov.tr/',                   'free',     false, '30 minutes', false),
  ('epias_news', 'EPİAŞ duyuruları',                                 'news',        'scrape', 1, 'https://www.epias.com.tr/',                  'free',     false, '30 minutes', false),
  ('resmi_gazete','Resmî Gazete (enerji ile ilgili kararlar)',        'news',        'scrape', 1, 'https://www.resmigazete.gov.tr/',            'free',     true,  '1 hour',   false),
  ('ec_energy',  'Avrupa Komisyonu enerji/iklim basın',              'news',        'rss',  1, 'https://ec.europa.eu/commission/presscorner/', 'free',     false, '1 hour',   false),
  ('nhc',        'ABD Ulusal Kasırga Merkezi (Meksika Körfezi)',     'news',        'rss',  1, 'https://www.nhc.noaa.gov/',                    'free',     true,  '1 hour',   false),
  -- Haber: ajans / uzman yayın (tier 2)
  ('aa_energy',  'Anadolu Ajansı Enerji',                            'news',        'rss',  2, 'https://www.aa.com.tr/tr/enerji',              'free',     false, '10 minutes', false),
  ('wire_licensed','Lisanslı haber ajansı akışı (Reuters/Bloomberg/Argus/Platts)', 'news', 'api', 2, NULL,                           'paid',     false, '5 minutes', false),
  ('rigzone',    'Rigzone',                                          'news',        'rss',  2, 'https://www.rigzone.com/',                     'free',     false, '15 minutes', true),
  ('lng_prime',  'LNG Prime',                                        'news',        'rss',  2, 'https://lngprime.com/',                        'free',     false, '30 minutes', false),
  -- Haber: toplayıcılar (tier 3) — geniş kapsama, düşük ağırlık
  ('gdelt',      'GDELT DOC API (enerji sorguları)',                 'news',        'api',  3, 'https://api.gdeltproject.org/api/v2/doc/doc',  'free',     false, '15 minutes', true),
  ('gnews_rss',  'Google News RSS sorguları (TR/EN)',                'news',        'rss',  3, 'https://news.google.com/rss/search',           'free',     false, '15 minutes', true)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name, kind = EXCLUDED.kind, access = EXCLUDED.access, tier = EXCLUDED.tier,
  base_url = EXCLUDED.base_url, license = EXCLUDED.license, store_body = EXCLUDED.store_body,
  poll_interval = EXCLUDED.poll_interval;

INSERT INTO energy.instruments (code, name, segment, unit, region, exchange, source_code, source_symbol, max_staleness, alert_zscore, alert_move_pct) VALUES
  -- Ham petrol
  ('BRENT_SPOT',   'Brent spot (Europe Brent)',           'crude',            'USD/bbl', 'GLOBAL', NULL,        'eia',      'RBRTE',   '10 days', 2.5, 4),
  ('WTI_SPOT',     'WTI Cushing spot',                    'crude',            'USD/bbl', 'US',     NULL,        'eia',      'RWTC',    '10 days', 2.5, 4),
  ('BRENT_M1',     'ICE Brent 1. vade',                   'crude',            'USD/bbl', 'GLOBAL', 'ICE',       'licensed', NULL,      '4 days',  2.5, 3),
  ('BRENT_M2',     'ICE Brent 2. vade',                   'crude',            'USD/bbl', 'GLOBAL', 'ICE',       'licensed', NULL,      '4 days',  2.5, 3),
  ('WTI_M1',       'NYMEX WTI 1. vade',                   'crude',            'USD/bbl', 'US',     'NYMEX',     'licensed', NULL,      '4 days',  2.5, 3),
  -- İşlenmiş ürünler
  ('ULSD_NYH_SPOT','ULSD New York Harbor spot',            'refined_products', 'USD/gal', 'US',     NULL,        'eia',      'EER_EPD2DXL0_PF4_Y35NY_DPG', '10 days', 2.5, 5),
  ('GASOLINE_NYH_SPOT','Benzin (konvansiyonel) NY Harbor spot','refined_products','USD/gal','US',   NULL,        'eia',      'EER_EPMRU_PF4_Y35NY_DPG',    '10 days', 2.5, 5),
  ('JET_USGC_SPOT','Jet yakıtı ABD Körfez spot',            'refined_products', 'USD/gal', 'US',     NULL,        'eia',      'EER_EPJK_PF4_RGC_DPG',       '10 days', 2.5, 5),
  ('GASOIL_M1',    'ICE Low Sulphur Gasoil 1. vade',      'refined_products', 'USD/t',   'EU',     'ICE',       'licensed', NULL,      '4 days',  2.5, 4),
  ('RBOB_M1',      'NYMEX RBOB benzin 1. vade',           'refined_products', 'USD/gal', 'US',     'NYMEX',     'licensed', NULL,      '4 days',  2.5, 4),
  ('HO_M1',        'NYMEX ULSD (NY Harbor) 1. vade',      'refined_products', 'USD/gal', 'US',     'NYMEX',     'licensed', NULL,      '4 days',  2.5, 4),
  -- Doğal gaz
  ('HH_SPOT',      'Henry Hub spot',                      'natural_gas',      'USD/MMBtu','US',    NULL,        'eia',      'RNGWHHD', '10 days', 2.5, 8),
  ('TTF_M1',       'TTF 1. ay vadeli',                    'natural_gas',      'EUR/MWh', 'EU',     'ICE Endex', 'licensed', NULL,      '4 days',  2.5, 6),
  ('JKM_M1',       'JKM LNG 1. ay',                       'natural_gas',      'USD/MMBtu','ASIA',  NULL,        'licensed', NULL,      '4 days',  2.5, 6),
  -- Elektrik
  ('TR_PTF_BASE',  'Türkiye PTF günlük ortalama (baz yük)','power',            'TRY/MWh', 'TR',     'EPİAŞ GÖP', 'epias',    'dam/mcp', '3 days',  2.5, NULL),
  ('TR_PTF_HOURLY','Türkiye PTF saatlik',                 'power',            'TRY/MWh', 'TR',     'EPİAŞ GÖP', 'epias',    'dam/mcp', '3 days',  2.5, NULL),
  ('DE_DA_BASE',   'Almanya-Lüksemburg gün öncesi baz yük','power',            'EUR/MWh', 'DE',     'EPEX',      'entsoe',   '10Y1001A1001A82H', '3 days', 2.5, NULL),
  -- Karbon
  ('EUA_AUCTION',  'EUA birincil ihale takas fiyatı',      'carbon',           'EUR/t',   'EU',     'EEX',       'eex_auction', NULL,   '5 days',  2.5, 5),
  ('EUA_DEC',      'EUA Aralık vadeli',                   'carbon',           'EUR/t',   'EU',     'ICE Endex', 'licensed', NULL,      '4 days',  2.5, 5),
  -- Döviz (çevrim için; hareket alarmı üretmez)
  ('EURUSD',       'EUR/USD (TCMB çapraz kur)',           'fx',               'USD/EUR', 'EU',     NULL,        'tcmb',     'EUR/USD', '5 days',  99, NULL),
  ('USDTRY',       'USD/TRY (TCMB döviz alış)',           'fx',               'TRY/USD', 'TR',     NULL,        'tcmb',     'USD',     '5 days',  99, NULL),
  ('EURTRY',       'EUR/TRY (TCMB döviz alış)',           'fx',               'TRY/EUR', 'TR',     NULL,        'tcmb',     'EUR',     '5 days',  99, NULL)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name, segment = EXCLUDED.segment, unit = EXCLUDED.unit, region = EXCLUDED.region,
  exchange = EXCLUDED.exchange, source_code = EXCLUDED.source_code, source_symbol = EXCLUDED.source_symbol,
  max_staleness = EXCLUDED.max_staleness, alert_zscore = EXCLUDED.alert_zscore, alert_move_pct = EXCLUDED.alert_move_pct;

-- Lisanslı veri gelene kadar lisanslı enstrümanlar kapalı
UPDATE energy.instruments SET is_active = false WHERE source_code = 'licensed';
-- Saatlik seri günlük analize girmez (günlük özeti TR_PTF_BASE)
UPDATE energy.instruments SET is_active = false WHERE code = 'TR_PTF_HOURLY';

-- Birim çevrimleri: 1 bbl = 42 gal; gasoil 1 t ≈ 7,45 bbl; 1 MWh = 3,412 MMBtu
INSERT INTO energy.derived_metrics (code, name, segment, unit, legs, description) VALUES
  ('BRENT_WTI_SPOT', 'Brent-WTI spot farkı', 'crude', 'USD/bbl',
   '[{"i":"BRENT_SPOT","c":1},{"i":"WTI_SPOT","c":-1}]',
   'Atlantik arbitrajı; genişlemesi ABD ham petrol ihracatını cazip kılar'),
  ('BRENT_M1_M2', 'Brent 1-2. vade farkı', 'crude', 'USD/bbl',
   '[{"i":"BRENT_M1","c":1},{"i":"BRENT_M2","c":-1}]',
   'Pozitif = backwardation (sıkı arz), negatif = contango (bol arz)'),
  ('ULSD_CRACK_NYH', 'ULSD crack (NY Harbor spot - Brent spot)', 'refined_products', 'USD/bbl',
   '[{"i":"ULSD_NYH_SPOT","c":42},{"i":"BRENT_SPOT","c":-1}]',
   'Dizel rafineri marjı göstergesi'),
  ('GASOLINE_CRACK_NYH', 'Benzin crack (NY Harbor spot - Brent spot)', 'refined_products', 'USD/bbl',
   '[{"i":"GASOLINE_NYH_SPOT","c":42},{"i":"BRENT_SPOT","c":-1}]',
   'Benzin rafineri marjı göstergesi'),
  ('GASOIL_CRACK', 'ICE Gasoil crack', 'refined_products', 'USD/bbl',
   '[{"i":"GASOIL_M1","c":0.134228},{"i":"BRENT_M1","c":-1}]',
   'Avrupa dizel marjı; Türkiye motorin fiyatlarının öncü göstergesi'),
  ('CRACK_321', '3-2-1 crack (NYMEX)', 'refined_products', 'USD/bbl',
   '[{"i":"RBOB_M1","c":28},{"i":"HO_M1","c":14},{"i":"WTI_M1","c":-1}]',
   '(2 x benzin + 1 x dizel) / 3 - ham petrol; ABD rafineri marjı'),
  ('TTF_HH', 'TTF - Henry Hub farkı', 'natural_gas', 'USD/MMBtu',
   '[{"i":"TTF_M1","c":0.29307,"mul":"EURUSD"},{"i":"HH_SPOT","c":-1}]',
   'ABD LNG ihracat arbitrajı'),
  ('JKM_TTF', 'JKM - TTF farkı', 'natural_gas', 'USD/MMBtu',
   '[{"i":"JKM_M1","c":1},{"i":"TTF_M1","c":-0.29307,"mul":"EURUSD"}]',
   'Pozitifse LNG kargoları Asya''ya, negatifse Avrupa''ya yönelir'),
  ('TR_PTF_EUR', 'Türkiye PTF (EUR)', 'power', 'EUR/MWh',
   '[{"i":"TR_PTF_BASE","c":1,"div":"EURTRY"}]',
   'Avrupa fiyatlarıyla karşılaştırma için'),
  ('TR_DE_POWER', 'Türkiye PTF - Almanya gün öncesi', 'power', 'EUR/MWh',
   '[{"i":"TR_PTF_BASE","c":1,"div":"EURTRY"},{"i":"DE_DA_BASE","c":-1}]',
   'Bölgesel elektrik fiyat farkı'),
  ('DE_CLEAN_SPARK', 'Almanya temiz spark spread (verim %49,13)', 'cross_market', 'EUR/MWh',
   '[{"i":"DE_DA_BASE","c":1},{"i":"TTF_M1","c":-2.0354},{"i":"EUA_DEC","c":-0.4112}]',
   'Gaz santrali marjı: elektrik - gaz/verim - karbon (0,202 tCO2/MWh yakıt)')
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name, segment = EXCLUDED.segment, unit = EXCLUDED.unit, legs = EXCLUDED.legs, description = EXCLUDED.description;

INSERT INTO energy.indicators (code, name, segment, unit, frequency, source_code, source_symbol, price_sign) VALUES
  ('US_CRUDE_STOCKS',     'ABD ticari ham petrol stokları (SPR hariç)', 'crude',            'Mbbl', 'weekly',  'eia',   'WCESTUS1', -1),
  ('US_GASOLINE_STOCKS',  'ABD toplam benzin stokları',                'refined_products', 'Mbbl', 'weekly',  'eia',   'WGTSTUS1', -1),
  ('US_DISTILLATE_STOCKS','ABD distilat stokları',                     'refined_products', 'Mbbl', 'weekly',  'eia',   'WDISTUS1', -1),
  ('US_REFINERY_UTIL',    'ABD rafineri kapasite kullanımı',           'refined_products', '%',    'weekly',  'eia',   'WPULEUS3',  0),
  ('US_CRUDE_PROD',       'ABD ham petrol üretimi',                    'crude',            'Mb/d', 'weekly',  'eia',   'WCRFPUS2', -1),
  ('US_NG_STORAGE',       'ABD çalışan gaz stoku (Lower 48)',          'natural_gas',      'Bcf',  'weekly',  'eia',   'NW2_EPG0_SWO_R48_BCF', -1),
  ('EU_GAS_STORAGE_PCT',  'AB gaz depolama doluluk oranı',             'natural_gas',      '%',    'daily',   'gie_agsi', 'EU', -1),
  ('US_OIL_RIGS',         'ABD petrol sondaj kulesi sayısı',           'crude',            'adet', 'weekly',  'baker_hughes', 'US Oil', -1),
  ('CFTC_WTI_MM_NET',     'WTI yönetilen para net pozisyonu',          'crude',            'kontrat', 'weekly', 'cftc', '067651',  1),
  ('TR_ELEC_CONSUMPTION', 'Türkiye günlük elektrik tüketimi',          'power',            'MWh',  'daily',   'epias', 'consumption/real-time', 1)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name, segment = EXCLUDED.segment, unit = EXCLUDED.unit, frequency = EXCLUDED.frequency,
  source_code = EXCLUDED.source_code, source_symbol = EXCLUDED.source_symbol, price_sign = EXCLUDED.price_sign;
