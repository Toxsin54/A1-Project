# Enerji Haber ve Piyasa Takip Ajanı: Mimari

Ajan beş segmenti izler: **ham petrol**, **işlenmiş petrol ürünleri**, **doğal gaz**, **elektrik** ve **karbon kredileri**. Fiyat ve temel gösterge verisini toplar, enerji haberlerini okuyup sınıflandırır, fiyat hareketlerini haberlerle eşleştirir. Sonuçları, diğer ajanların raporlarıyla birlikte değerlendiren **Veri Analiz Ajanı**na standart bir rapor olarak gönderir.

Kuruluş repodaki diğer projelerle aynıdır: zamanlama ve entegrasyonlar **n8n**'de, hesaplar ve iş mantığı **PostgreSQL**'de. LLM iki yerde kullanılır: haberi sınıflandırmak ve raporu yazmak. Sayıların hepsi SQL'den gelir.

```
      ┌──────────────────────── n8n Schedule (kaynak takvimine göre) ────────────────────────┐
      ▼                        ▼                           ▼                                  ▼
 Piyasa verisi          Temel göstergeler               Haberler                         Olay takvimi
 EIA, EPİAŞ, ENTSO-E,   EIA stokları, AGSI+, CFTC,      resmî kurumlar (tier 1),         EIA, OPEC+, EEX,
 EEX, TCMB/ECB,         Baker Hughes                    ajanslar (2), toplayıcılar (3)   EPİAŞ, AB
 lisanslı akış
      │                        │                           │ URL temizle, ön filtre           │
      └──────────── normalize + upsert (ingest_runs'a kayıt) ─┴──────────────────────────────────┘
                                             ▼
                              PostgreSQL  ·  şema: energy
   prices_daily · indicator_values · news_items → story_clusters → news_analyses · calendar_events
                                             │
        ┌────────────────────────────────────┼──────────────────────────────────────┐
        ▼                                    ▼                                      ▼
 Nicel analiz (SQL)                 Haber hattı                             Fiyat ↔ haber
 değişim, z-skor, bayatlık,         kümeleme (pg_trgm) →                    fn_detect_moves:
 spread/crack/spark spread,         Sınıflandırıcı LLM (araçsız,            olağan dışı hareket +
 stok sürprizi                      JSON Schema çıktı) → küme skoru         aynı yönlü haber
        └────────────────────────────────────┼──────────────────────────────────────┘
                                             ▼
                          fn_build_context  →  bağlam paketi (JSON)
                                             ▼
                        Rapor yazarı LLM (araçsız)  →  validate_report
                                             ▼          (şema · atıf · sayı kontrolü)
                                  reports (outbox)
                                     │                        ▲
                     push: POST + HMAC imza         pull: salt okunur SQL rolü / araçlar
                                     ▼                        │
                            ┌───────────────── Veri Analiz Ajanı ─────────────────┐
                            │  enerji + diğer ajanların raporları (aynı zarf)    │
                            └─────────────────────────────────────────────────────┘
```

## Dosyalar

| Dosya | Açıklama |
|---|---|
| `db/01_schema.sql` | Tablolar: kaynaklar, enstrümanlar, fiyatlar, göstergeler, haberler, kümeler, LLM analizleri, fiyat hareketleri, takvim, rapor outbox'ı |
| `db/02_analytics.sql` | Deterministik hesaplar: `fn_snapshot`, `fn_derived_snapshot`, `v_indicator_changes`, `fn_assign_cluster`, `fn_cluster_scores`, `fn_detect_moves`, `fn_build_context`, `fn_save_report`, `fn_mark_delivery`; analist için `energy_reader` rolü |
| `db/03_seed.sql` | Başlangıç kataloğu: 25 kaynak, 22 enstrüman, 11 türetilmiş metrik, 10 gösterge. n8n workflow'unun bağladığı 7 kaynak açık, diğerleri kapalı gelir |
| `db/04_ingest.sql` | n8n'in çağırdığı fonksiyonlar: fiyat/gösterge/PTF kaydı, haber ekleme ve kümeleme, LLM analizini doğrulayıp kaydetme, teslim listesi |
| `../n8n/energy-agent-workflow.json` | n8n'e içe aktarılacak workflow (bkz. **n8n kurulumu**) |
| `contracts/agent-report-envelope.schema.json` | **Tüm ajanlar için** önerilen ortak rapor zarfı |
| `contracts/energy-report.schema.json` | Zarf + enerji payload'u. Analist ajana giden raporun sözleşmesi |
| `contracts/news-analysis.schema.json` | Sınıflandırıcı LLM'in haber kümesi başına döndüğü yapı |
| `contracts/example-morning-brief.json` | Sentetik veriden `fn_build_context` ile üretilmiş, doğrulamadan geçen örnek rapor |
| `test/validate_report.py` | Rapor doğrulayıcı: şema, atıf ve sayı kontrolü |
| `test/smoke_test.sql` | Veritabanı testi. Sentetik veri yükler, kontrolleri çalıştırır ve sonunda geri alır |

## 1. Veri kaynakları

### Piyasa verisi

| Segment | Seri | Ücretsiz kaynak | Not |
|---|---|---|---|
| Ham petrol | Brent, WTI spot | EIA API (`RBRTE`, `RWTC`) | EIA günlük spot fiyatları **haftalık** yayımlar. Gün içi ve vadeli (ICE Brent M1/M2, NYMEX WTI) için lisanslı akış gerekir |
| Ürünler | NY Harbor ULSD, benzin, ABD Körfezi jet spot | EIA API | ICE Gasoil, RBOB, HO vadelileri lisanslı |
| Doğal gaz | Henry Hub spot | EIA API (`RNGWHHD`) | TTF, JKM için ücretsiz resmî API yok, lisanslı akış gerekir |
| Elektrik | Türkiye PTF (saatlik ve günlük ortalama) | EPİAŞ Şeffaflık Platformu (ücretsiz hesap) | Ertesi günün PTF'si GÖP sonucu olarak öğleden sonra yayımlanır |
| Elektrik | Almanya-Lüksemburg gün öncesi | ENTSO-E Transparency (ücretsiz token) | Türkiye-Avrupa fiyat farkı ve spark spread için |
| Karbon | EUA birincil ihale takas fiyatı | EEX ihale sonuçları | Günlük, ücretsiz. EUA Aralık vadelisi lisanslı |
| Döviz | EUR/USD, USD/TRY, EUR/TRY | ECB, TCMB | Birim çevrimleri için |

Seed dosyasında lisanslı enstrümanlar (`source_code = 'licensed'`) **kapalı** gelir. Lisans alındığında sadece `is_active = true` yapılır ve toplayıcı eklenir; analiz ve rapor tarafında değişiklik gerekmez.

### Temel göstergeler ve takvim

| Gösterge | Kaynak | Yayın (ABD saati; TSİ yaz saatinde +7, kışın +8) |
|---|---|---|
| API haftalık stok (sektör tahmini) | American Petroleum Institute | Salı 16:30 ET |
| ABD ham petrol / benzin / distilat stokları, rafineri kullanımı, üretim | EIA Weekly Petroleum Status Report | Çarşamba 10:30 ET |
| ABD doğal gaz depolama | EIA Weekly Natural Gas Storage Report | Perşembe 10:30 ET |
| Petrol sondaj kulesi sayısı | Baker Hughes | Cuma 13:00 ET |
| Fon pozisyonları (COT) | CFTC | Cuma 15:30 ET |
| AB gaz depolama doluluğu | GIE AGSI+ | Günlük |
| OPEC MOMR, IEA OMR, EIA STEO | aylık raporlar | Ayın ortası; tarihler takvime elle girilir |
| OPEC+ toplantıları, EEX ihale takvimi | kurum duyuruları | `calendar_events` tablosu |

Stok sürprizi (`v_indicator_changes`) önce piyasa beklentisiyle (`consensus_change`) hesaplanır. Beklenti verisi yoksa son 5 yılın aynı haftasındaki ortalama değişim kullanılır (`surprise_basis = seasonal_5y`). Beklenti verisi genelde ücretli olduğundan bu yedek önemlidir.

### Haber kaynakları

| Tier | Ağırlık | Örnekler | Kullanım |
|---|---|---|---|
| 1: birincil / resmî | 1.0 | OPEC, IEA, EIA, ETKB, EPDK, EPİAŞ, Resmî Gazete, Avrupa Komisyonu, NHC (Meksika Körfezi kasırgaları) | Kararın kendisi. Kümeye katılırsa başlık bu kaynaktan alınır |
| 2: ajans / uzman yayın | 0.8 | AA Enerji, Rigzone, LNG Prime; lisansla Reuters, Bloomberg, Argus, Platts | Hızlı haber |
| 3: toplayıcı | 0.5 | GDELT, Google News RSS sorguları (TR/EN) | Geniş kapsama. Tek başına düşük skor alır |

**Telif:** `sources.store_body = false` olan kaynaklarda sadece başlık, özet ve bağlantı saklanır. Tam metin, lisansın izin verdiği kaynaklarda tutulur. Kazıma (`access = 'scrape'`) yapılan sitelerin kullanım şartları kurulumda kontrol edilmelidir.

## 2. Nicel analiz (SQL, LLM'siz)

| Fonksiyon | Ne yapar |
|---|---|
| `fn_snapshot(tarih)` | Her aktif serinin son değeri, 1/5/20 günlük değişim, **z-skor** (günlük getiri ÷ önceki 60 gözlemin oynaklığı) ve **bayatlık**. Son veri `max_staleness`'tan eskiyse `is_stale` olur ve rapora yansır |
| `fn_derived_snapshot(tarih)` | Spread, crack ve spark spread'ler. `derived_metrics.legs` ile tanımlanır; birim ve döviz çevrimi katsayıdadır. Eksik bacak varsa metrik üretilmez |
| `v_indicator_changes` | Gösterge değişimi ve sürpriz |
| `fn_detect_moves(tarih)` | z-skoru `alert_zscore` ya da değişimi `alert_move_pct` eşiğini aşan hareketleri `market_moves`'a yazar ve açıklayan haberleri arar |

Türetilmiş metrikler (`db/03_seed.sql`):

| Metrik | Formül | Ne söyler |
|---|---|---|
| `BRENT_WTI_SPOT` | Brent − WTI | Atlantik arbitrajı, ABD ihracat iştahı |
| `BRENT_M1_M2` | 1. vade − 2. vade | Pozitifse backwardation (sıkı arz), negatifse contango |
| `ULSD_CRACK_NYH`, `GASOLINE_CRACK_NYH` | 42 × ürün (USD/gal) − Brent | Rafineri marjı (ücretsiz verilerle) |
| `GASOIL_CRACK` | Gasoil (USD/t) ÷ 7,45 − Brent | Avrupa dizel marjı. Türkiye motorin fiyatının öncü göstergesi |
| `CRACK_321` | 28 × RBOB + 14 × HO − WTI | ABD 3-2-1 marjı |
| `TTF_HH`, `JKM_TTF` | TTF × EURUSD ÷ 3,412 ile USD/MMBtu'ya çevrilir | LNG arbitrajı: kargo Avrupa'ya mı Asya'ya mı gider |
| `TR_PTF_EUR`, `TR_DE_POWER` | PTF ÷ EURTRY; PTF(EUR) − Almanya | Türkiye elektriğinin Avrupa'ya göre konumu |
| `DE_CLEAN_SPARK` | Elektrik − 2,035 × TTF − 0,411 × EUA | Gaz santrali marjı (verim %49,13) |

## 3. Haber hattı

1. **Toplama** (her 5-15 dk). RSS, API ve kazıma kullanılır. URL'den `utm_*` gibi parametreler temizlenir. `url_hash` tekil olduğu için aynı haber iki kez girmez.
2. **Ön filtre** (LLM'siz). TR/EN anahtar kelime listesi uygulanır: Brent, OPEC, ham petrol, rafineri, motorin, LNG, TTF, doğal gaz, BOTAŞ, PTF, EPİAŞ, ETS, CBAM, karbon... Tier 1 enerji kurumlarından gelen her şey geçer. Geçmeyen haber `prefilter_ok = false` olur, kümelenmez ve LLM'e gitmez. Maliyetin büyük kısmı bu adımda düşer.
3. **Kümeleme** (`fn_assign_cluster`). Başlık son 48 saatteki bir kümeye `pg_trgm` benzerliğiyle (varsayılan 0,45) atanır; uyan küme yoksa yeni küme açılır. Kümeye daha iyi bir kaynak katılırsa ya da küme iki katından fazla büyürse yeniden analiz istenir (`needs_analysis`). Böylece aynı olayı anlatan 10 haber için LLM **bir kez** çalışır.
4. **Sınıflandırma** (LLM, küçük ve ucuz model). Girdi: kümedeki başlıklar, özetler, kaynak tier'ları ve enstrüman kod listesi. Çıktı: `contracts/news-analysis.schema.json`, yani ilgili mi, olay türü, segmentler, bölgeler, varlıklar ve her segment için etki (`price_direction`, `magnitude` 0-3, `horizon`). Buna ek olarak yenilik (`new`/`update`/`repeat`), söylenti işareti, güven ve Türkçe özet döner. Şemaya uymayan çıktı kaydedilmez; bir kez hata mesajıyla tekrar istenir.
5. **Skor** (`fn_cluster_scores`, SQL):

   ```
   skor = max(etki büyüklüğü) × güven × tier ağırlığı × yenilik (1 / 0,7 / 0,3)
          × söylenti (0,5) × (1 + 0,1 × ek kaynak sayısı, en fazla 5) × 0,5^(geçen saat / 24)
   ```

6. **Fiyat ↔ haber eşleştirme** (`fn_detect_moves`). Olağan dışı bir hareket ancak **aynı segmentte ve aynı yönde** (ya da yönü belirsiz) etki öngören bir haberle "açıklandı" sayılır. OPEC+ artış kararı Brent'in yükselişini açıklamaz. Açıklanamayan hareket de rapora ayrı bir sinyal olarak girer: haber henüz düşmemiş olabilir ya da piyasa teknik nedenlerle hareket ediyor olabilir.

Olay türleri: `supply_opec_policy`, `supply_outage`, `geopolitics_conflict`, `sanctions_trade`, `inventories_data`, `demand_macro`, `refining`, `lng_shipping`, `weather`, `power_grid`, `renewables`, `policy_regulation`, `carbon_market`, `corporate`, `market_positioning`, `other`.

## 4. Rapor üretimi

**Bağlam paketi, serbest ajan değil.** `fn_build_context(as_of, lookback)` raporun ihtiyaç duyduğu her şeyi tek bir JSON'da toplar: snapshot, türetilmiş metrikler, göstergeler, en yüksek skorlu haber kümeleri, fiyat hareketleri, önümüzdeki 7 günün takvimi ve veri kalitesi. Her kaydın bir `evidence_id`'si vardır (`px:BRENT_SPOT:2026-09-25`, `news:1234`). Rapor yazarı LLM **araç kullanmaz**; sadece bu paketi yorumlar, bulgular ve özet yazar.

Bu yaklaşımın gerekçeleri şunlar: rapor her seferinde aynı veriyle, öngörülebilir maliyetle üretilir, denetlenebilir kalır ve haber metnindeki bir prompt injection girişiminin tetikleyebileceği bir araç bulunmaz. Serbest keşif (drill-down) analist ajanın işidir (bkz. bölüm 5).

**Doğrulama** (`test/validate_report.py`; n8n'de aynı kontroller Code düğümünde yapılır):
1. JSON Schema uyumu.
2. Her bulgunun `evidence_ids` alanı, paketteki gerçek bir kayda işaret etmeli.
3. Özet ve bulgulardaki ondalıklı sayılar ve yüzdeler, paketteki bir sayıyla yuvarlama payı içinde eşleşmeli. Böylece LLM'in uydurduğu sayı yayına çıkmaz.

Doğrulama başarısız olursa hatalar LLM'e verilip bir kez düzelttirilir. Yine geçmezse sadece veri bloklarından oluşan, şablon özetli bir rapor yayımlanır ve `data_quality.notes` alanına not düşülür. Rapor hiçbir zaman sessizce kaybolmaz.

**Rapor türleri** (TSİ):

| Tür | Zaman | İçerik |
|---|---|---|
| `morning_brief` | 08:00 | Gece Asya ve ABD kapanışları, gece haberleri, bugünün PTF'si, günün takvimi |
| `daily_close` | ~23:00 | Avrupa ve ABD uzlaşma fiyatlarından sonra günün özeti, hareketler ve nedenleri |
| `weekly_outlook` | Cumartesi 10:00 | COT, sondaj kulesi, haftalık stoklar, önümüzdeki haftanın riskleri |
| `event_note` | Planlı veri geldiğinde | EIA stok raporu, OPEC+ kararı vb. Değer, beklenti, sürpriz ve ilk fiyat tepkisi |
| `alert` | Olay anında | Eşik aşan hareket ya da tier 1 kaynaktan gelen yüksek etkili haber (büyüklük ≥ 2, güven ≥ 0,7). Saatte en fazla 3 uyarı; `dedup_key` ile tekrar engellenir |

Tüm raporlar `fn_save_report` ile `reports` tablosuna yazılır. Aynı `dedup_key` ile ikinci çağrıda (ör. `daily_close:2026-09-26`) yeni kayıt açılmaz, mevcut rapor döner.

## 5. Veri Analiz Ajanına bağlantı

### Ortak zarf

`contracts/agent-report-envelope.schema.json`, **diğer ajanlar için de** önerilen formattır. Analist ajan, enerji raporunu makro, döviz ya da başka bir ajanın raporuyla aynı alanlar üzerinden karşılaştırır:

| Alan | Amaç |
|---|---|
| `report_id`, `supersedes` | Alıcı tarafta idempotency. Düzeltme raporu eskisini işaret eder |
| `agent.id`, `report_type`, `as_of`, `period` | Kim, ne zaman, hangi veri kesimiyle |
| `summary` | Kısa Türkçe anlatı |
| `findings[]` | Tek tek çıkarımlar: `topic`, `direction`, `strength` 0-3, `confidence` 0-1, `horizon`, `evidence_ids` |
| `findings[].tags` | Ajanlar arası birleştirme anahtarı: `commodity:brent`, `region:TR`, `fx:USDTRY`, `macro:TR_CPI`, `event:supply_outage`. Tüm ajanlar aynı sözlüğü kullanmalı |
| `evidence[]` | Her iddianın dayandığı veri ya da haber (değer, birim, zaman, URL) |
| `data_quality` | `ok` / `degraded` / `poor`, bayat seriler, çalışmayan kaynaklar. Analist bayat veriyle çıkarım yapmamalı |
| `payload` | Ajana özgü ayrıntı. Enerji için snapshot, metrikler, göstergeler, haberler, hareketler, takvim, riskler |

Örnek: `contracts/example-morning-brief.json`.

### Push (varsayılan)

Outbox iş akışı `reports` tablosundan `delivery_status = 'pending'` ve `next_attempt_at <= now()` olan raporları alır ve analist ajanın webhook'una gönderir:

```
POST {ANALYST_WEBHOOK_URL}
Content-Type: application/json
X-Agent-Id: energy-news
Idempotency-Key: <report_id>
X-Signature-256: sha256=<HMAC-SHA256(gövde, ortak gizli anahtar)>
```

2xx yanıt teslim edildi sayılır. Hata olursa `fn_mark_delivery` 1, 5, 15 ve 60 dakika sonra tekrar dener; 5. denemeden sonra rapor `failed` olur ve uyarı üretilir. Analist ajan aynı `report_id`'yi ikinci kez alırsa yok saymalıdır. İmza, mesajlaşma iş akışındaki Meta doğrulamasıyla aynı yöntemle (Crypto düğümü, HMAC) kontrol edilir.

### Pull ve araçlar (analistin ayrıntıya inmesi için)

Analist bir bulguyu derinleştirmek isterse şu araçları çağırır. Araçlar n8n'de webhook ya da **MCP Server Trigger** ile sunulur ve arkada salt okunur `energy_reader` rolüyle çalışır:

| Araç | Arkasındaki sorgu |
|---|---|
| `get_latest_report(report_type)` | `reports` |
| `get_snapshot(as_of)` | `fn_snapshot`, `fn_derived_snapshot` |
| `get_price_series(instrument, from, to)` | `prices_daily` |
| `search_energy_news(query, segment, since, min_score)` | `fn_cluster_scores` + başlıkta trigram arama |
| `get_calendar(from, to)` | `calendar_events` |

Analist aynı PostgreSQL'e erişebiliyorsa `energy_reader` rolünü kullanan bir kullanıcıyla doğrudan SQL de çalıştırabilir.

## 6. n8n workflow'u

Tek dosya: `n8n/energy-agent-workflow.json`. Beş zamanlayıcı aynı *Enerji Ayarları* düğümünden geçer, *Akışa Göre* düğümü her birini kendi koluna yollar. Ayarlar tek yerde durur.

| Kol | Zaman (TSİ) | Adımlar |
|---|---|---|
| Piyasa | 3 saatte bir (x:10) | *EIA Serileri* → *EIA API* → *EIA Kaydet* · *EPİAŞ Giriş* → *EPİAŞ PTF* → *PTF Kaydet* (ayarlardan açılır) · *TCMB Kurlar* → *Kurları Kaydet* |
| Haber | 15 dakikada bir | *RSS Beslemeleri* → *RSS Oku* → *RSS Hazırla* · *GDELT* → *GDELT Hazırla* → *Haberleri Kaydet* (`fn_ingest_news`: ekleme + kümeleme) |
| Analiz | 15 dakikada bir (x:07) | *Analiz Bekleyen Kümeler* (en fazla 20) → *Sınıflandır (OpenAI)* (yapılandırılmış çıktı) → *Analizi Kaydet* (`fn_save_analysis` doğrular) |
| Rapor | 08:00 ve 23:00 | *Rapor Türü* → *Hareketleri Tespit Et* → *Bağlam Paketi* → *Raporu Yaz (OpenAI)* → *Raporu Birleştir* (doğrulama) → gerekirse *Raporu Düzelt* → *Raporu Kaydet* |
| Teslim | Rapor kaydedilince ve 15 dakikada bir (x:03) | *Analist Açık mı?* → *Gönderilecek Raporlar* → *Raporu İmzala* (HMAC) → *Analiste Gönder* → *Gönderimi İşaretle* |

Henüz yapılmayanlar (faz 2): `weekly_outlook`, `event_note` ve `alert` raporları, olay takvimini dolduran akış, analist için araçlar (MCP).

**Model seçimi.** Sınıflandırma çok sayıda kısa çağrıdan oluşur; küçük ve hızlı bir model yeterlidir. Rapor yazımı günde birkaç çağrıdır; güçlü bir model kullanılmalıdır. Model adı `news_analyses.model` alanına, prompt sürümü `prompt_version` alanına kaydedilir. Böylece model değişikliğinin etkisi ölçülebilir.

## 7. Tasarım kararları

- **Sayılar SQL'den, yorum LLM'den.** LLM hiçbir fiyat, değişim ya da sürpriz hesaplamaz. Doğrulayıcı, metindeki sayıları veriyle karşılaştırır.
- **Her iddianın kanıtı var.** Bulgular `evidence_ids` taşır; analist ajan her iddiayı kaynağına kadar izleyebilir.
- **Haber değil olay analiz edilir.** Kümeleme, maliyeti düşürür ve aynı olayın 10 kez sayılmasını önler. Kaynak sayısı güveni artırır.
- **Tarih ve saat disiplini.** Her değer kendi `as_of` tarihini taşır. Bayat seri rapordan çıkarılmaz, işaretlenir. EIA spot verisinin haftalık gecikmesi gibi durumlar `max_staleness` ile seri bazında ayarlanır.
- **Lisanssız başlar, lisansla büyür.** Ücretsiz kaynaklarla çalışır. Lisanslı akış eklendiğinde sadece enstrüman açılır.
- **Rapor kaybolmaz.** Outbox, tekrar deneme ve `dedup_key` sayesinde analist ajan geçici olarak kapalı olsa da raporlar sırayla ulaşır.
- **Güvenlik.**
  - Haber metni güvenilmeyen girdidir. Sınıflandırıcı ve rapor yazarı LLM'lerin aracı yoktur ve çıktıları şemayla doğrulanır.
  - API anahtarları n8n credential'larında durur.
  - Analist ajanın erişimi salt okunurdur.
  - Rapor gönderimi HMAC ile imzalanır.

## 8. Kalite ve izleme

- **Kaynak sağlığı.** `v_source_health` görünümü, beklenen sürenin 3 katı boyunca başarılı çalışmayan ya da son çalışması hatalı biten kaynakları işaretler. Bu liste rapordaki `data_quality.failed_sources` alanına girer.
- **Sınıflandırma doğruluğu.** Elle etiketlenmiş 200 haberlik bir değerlendirme seti hazırlanır. Prompt ya da model her değiştiğinde olay türü, segment ve yön doğruluğu bu sette ölçülür.
- **Yön isabeti (backtest).** Aylık olarak `news_analyses.impacts` içindeki yön tahminleri, sonraki 1 ve 5 günlük fiyat değişimiyle karşılaştırılır. Güven skorunun kalibrasyonu da kontrol edilir: 0,8 güvenle verilen tahminler gerçekten yaklaşık %80 isabet ediyor mu?
- **Maliyet.** Günlük LLM token toplamı `news_analyses.input_tokens` ve `output_tokens` alanlarından izlenir.

## 9. Yol haritası

| Faz | Kapsam |
|---|---|
| 1: MVP (workflow hazır) | EIA, EPİAŞ, TCMB · RSS (EIA, Rigzone, Google News TR/EN) ve GDELT · kümeleme + sınıflandırma · fiyat ↔ haber eşleştirme · `morning_brief` ve `daily_close` · analiste push |
| 2 | ENTSO-E, AGSI+, EEX, CFTC, Baker Hughes toplayıcıları · resmî kurum duyuruları (OPEC, EPDK, EPİAŞ, Resmî Gazete) · `weekly_outlook`, `event_note`, `alert` · olay takvimi · analist için araçlar (MCP) · değerlendirme seti |
| 3 | Lisanslı vadeli akış (ICE Brent, Gasoil, TTF, JKM, EUA) ve vadeli eğri · çok dilli kümeleme için embedding (pgvector) · backtest ve kalibrasyon raporu · Türkiye pompa fiyatları ve BOTAŞ tarifeleri |

## n8n kurulumu

### 1) Veritabanı

Dört dosyayı sırayla yükleyin. Tekrar çalıştırmak güvenlidir; veriler silinmez.

```bash
psql "$DATABASE_URL" -f energy-agent/db/01_schema.sql -f energy-agent/db/02_analytics.sql \
                     -f energy-agent/db/03_seed.sql -f energy-agent/db/04_ingest.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f energy-agent/test/smoke_test.sql   # "smoke test OK" yazar, veri bırakmaz
```

Supabase kullanıyorsanız SQL Editor'e dört dosyanın içeriğini sırayla yapıştırıp çalıştırın. Tablolar ayrı bir `energy` şemasında durur; rezervasyon tablolarıyla aynı veritabanında çakışmadan çalışır. Başlık kümelemesi için gereken `pg_trgm` eklentisi PostgreSQL ve Supabase'de hazırdır.

### 2) Workflow'u içe aktarın

n8n'de **Workflows → Import from File** ile `n8n/energy-agent-workflow.json` dosyasını seçin. Workflow kapalı gelir.

### 3) Credential'lar

| Düğümler | Credential | Not |
|---|---|---|
| Tüm Postgres düğümleri (13) | **A1 Postgres** (mevcut) | `energy` şemasının olduğu veritabanı |
| *EIA API* | Yeni **Query Auth**: Name `api_key`, Value EIA anahtarınız | Anahtar ücretsizdir: eia.gov/opendata üzerinden e-postayla alınır |
| *Sınıflandır (OpenAI)*, *Raporu Yaz (OpenAI)*, *Raporu Düzelt (OpenAI)* | **OpenAI** (mevcut) | Mesaj asistanının kullandığı credential |
| *Raporu İmzala* | Yeni **Crypto**: HMAC Secret = analist ajanla paylaşılan uzun rastgele değer | Teslim kapalı olsa da oluşturun; n8n credential'ı eksik düğüm varsa workflow'u yayınlamaz |

### 4) *Enerji Ayarları* düğümü

| Alan | Varsayılan | Açıklama |
|---|---|---|
| `openai_classify_model` | `gpt-4o-mini` | Haber sınıflandırma (çok sayıda kısa çağrı) |
| `openai_report_model` | `gpt-4o` | Rapor yazımı (günde 2-4 çağrı) |
| `prompt_version` | `news-v1` | Sınıflandırma talimatını değiştirdiğinizde artırın; analizlere kaydedilir |
| `news_batch_size` | 20 | Bir çalıştırmada analiz edilecek en fazla küme |
| `morning_lookback_hours`, `daily_lookback_hours` | 16, 24 | Raporun kapsadığı haber süresi |
| `epias_enabled`, `epias_username`, `epias_password` | kapalı | EPİAŞ Şeffaflık Platformu hesabı (ücretsiz). Şifre bu düğümde durduğu için sadece bu iş için açılmış bir hesap kullanın |
| `analyst_enabled`, `analyst_webhook_url` | kapalı | Veri Analiz Ajanı'nın rapor alacağı adres |

### 5) İlk çalıştırma

Birden fazla tetikleyici olduğu için her kolu ayrı çalıştırın: ilgili **Zamanlayıcı** düğümünü seçip ▶ **Execute step** (ya da *Execute workflow* menüsünden o tetikleyiciyi) seçin. Sırayla:

1. **Zamanlayıcı: Piyasa.** İlk çalıştırmada EIA'dan 6 yıllık geçmiş gelir (z-skor ve mevsimsellik için), EPİAŞ açıksa 120 günlük PTF.
   `SELECT instrument_code, count(*), max(trade_date) FROM energy.prices_daily GROUP BY 1;`
2. **Zamanlayıcı: Haber.**
   `SELECT source_code, count(*), count(*) FILTER (WHERE prefilter_ok) AS enerji FROM energy.news_items GROUP BY 1;`
3. **Zamanlayıcı: Analiz.** Kuyruk bitene kadar birkaç kez çalıştırabilirsiniz.
   `SELECT event_type, count(*) FROM energy.news_analyses GROUP BY 1;`
4. **Zamanlayıcı: Rapor.** Öğleden önce sabah bülteni, sonra gün sonu raporu üretir.
   `SELECT report_type, body->>'summary', body->'data_quality' FROM energy.reports ORDER BY generated_at DESC LIMIT 1;`
5. Sonuçlar doğruysa workflow'u **Publish** (ya da **Active**) yapın.

Aynı gün aynı tür rapor bir kez üretilir. Test için yeniden üretmek isterseniz: `DELETE FROM energy.reports WHERE dedup_key = 'daily_close:2026-09-27';` (tarihi değiştirin).

### Sorun giderme

| Belirti | Neden / çözüm |
|---|---|
| `SELECT * FROM energy.v_source_health WHERE is_failing;` bir kaynak gösteriyor | `last_error` sütununda hata metni var |
| *EIA API* 403 | Query Auth credential'ında Name tam olarak `api_key` olmalı |
| *EPİAŞ PTF* 401 | Kullanıcı adı/şifre hatalı ya da hesap Şeffaflık Platformu'na kayıtlı değil |
| Bir RSS beslemesi 404 | Adres değişmiş olabilir; *RSS Beslemeleri* düğümündeki listeden çıkarın ya da güncelleyin |
| Raporda `data_quality.notes` içinde "LLM yorumu doğrulamadan geçmedi" | LLM iki denemede de pakette olmayan sayı ya da kanıt kullandı; şablon rapor kaydedildi. *Raporu Birleştir* çıktısındaki `errors` alanına bakın |
| Hiç haber analiz edilmiyor | `SELECT count(*) FROM energy.story_clusters WHERE needs_analysis AND analysis_attempts >= 3;` sıfırdan büyükse OpenAI yanıtları hatalı; *Sınıflandır (OpenAI)* çıktısına bakın |

Yeni bir kaynak eklemek için önce toplayıcısını workflow'a ekleyin, sonra kaynağı açın: `UPDATE energy.sources SET is_enabled = true WHERE code = '...';`. Kapalı kaynakların serileri rapora girmez ve "bayat" sayılmaz.

## Test

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f energy-agent/test/smoke_test.sql
pip install jsonschema
python3 energy-agent/test/validate_report.py energy-agent/contracts/example-morning-brief.json
```
