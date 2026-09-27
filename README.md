# A1 Acente Otomasyonu: Telefonla Rezervasyon Asistanı

Müşteri telefonla arar, sesli asistan (Vapi) onunla konuşur ve şu adımları izler:

1. Tarih, kişi sayısı ve oda tipi bilgilerini alır.
2. Sistemde müsaitlik sorgular:
   - İstenen oda boşsa özelliklerini ve fiyatını söyler.
   - Oda doluysa ya da kişi sayısına uygun değilse fiyat ve özellikleriyle **alternatifler** sunar.
3. Müşteri onay verirse rezervasyonu oluşturur ve rezervasyon numarasını söyler.
4. Rezervasyon detaylarını müşteriye **SMS** olarak gönderir.

Değişiklik, iptal ve rezervasyon numarasını unutan müşteri için telefonla arama da desteklenir.

```
Müşteri ──telefon──▶ Vapi (STT + LLM + TTS)
                         │  tool call (POST, X-Vapi-Secret)
                         ▼
                 n8n  /webhook/vapi/reservations
   Vapi Tool Call ─▶ Extract Tool Call ─▶ Route Tool (Switch)
        ├─ check_availability ─▶ Query Availability ─▶ Respond Availability
        ├─ create_reservation ─▶ Create Reservation ─▶ Respond Create ─┐
        ├─ modify_reservation ─▶ Modify Reservation ─▶ Respond Modify ─┼▶ Should Send SMS? ─▶ Send SMS (Twilio)
        ├─ cancel_reservation ─▶ Cancel Reservation ─▶ Respond Cancel ─┘
        ├─ find_reservation   ─▶ Find Reservation   ─▶ Respond Find
        └─ (Unknown)          ─────────────────────▶ Respond Unknown
                         │
                         ▼
                 PostgreSQL (oda tipleri, fiyatlar, rezervasyonlar + iş mantığı)
```

## Dosyalar

| Dosya | Açıklama |
|---|---|
| `db/01_schema.sql` | Tablolar: `room_types` (oda tipi, özellikler, kapasite, stok, fiyat), `room_rates` (sezon fiyatları), `reservations`, `app_settings` |
| `db/02_functions.sql` | Tüm iş mantığı: müsaitlik, alternatifler, fiyat hesabı, rezervasyon, değişiklik, iptal, SMS metni |
| `db/03_seed.sql` | Örnek oda tipleri ve yaz sezonu fiyatı. Kendi verilerinizle değiştirin |
| `n8n/vapi-reservations-workflow.json` | n8n'e import edilecek workflow |
| `vapi/system-prompt.md` | Asistanın Türkçe talimatları |
| `vapi/tools.json` | Vapi araç (tool) tanımları |
| `vapi/deploy.mjs` | Asistanı Vapi API ile oluşturan/güncelleyen betik |
| `test/simulate_vapi.sh` | Vapi isteğini taklit ederek webhook'u test eder |
| `docker-compose.yml` | Yerel/küçük kurulum için PostgreSQL + n8n |

## Tasarım kararları

- **İş mantığı veritabanında.** Her araç tek bir SQL fonksiyonu çağırır (`fn_check_availability`, `fn_create_reservation`...). Fonksiyon, asistanın müşteriye aktaracağı Türkçe `message` metnini ve SMS bilgisini döner. n8n sadece yönlendirir. Kendi panelinizden de aynı fonksiyonları çağırabilirsiniz.
- **Doğru müsaitlik hesabı.** Konaklamanın her gecesi ayrı ayrı sayılır ve en dolu gece esas alınır: `boş oda = toplam oda - o gecedeki onaylı rezervasyon`. İptal edilen (`cancelled`) rezervasyonlar sayılmaz.
- **Çift satış (overbooking) yok.** Rezervasyon oluşturma ve değiştirme işlemleri oda tipi satırını kilitler (`FOR UPDATE`). Son odaya aynı anda iki istek gelirse ikincisi "az önce doldu" cevabı alır.
- **Mükerrer kayıt yok.** Asistan aynı rezervasyonu 15 dakika içinde tekrar gönderirse yeni kayıt açılmaz ve ikinci SMS gitmez; mevcut numara döner.
- **Güvenlik.**
  - Webhook, `X-Vapi-Secret` başlığı olmadan çalışmaz.
  - Değişiklik ve iptal için rezervasyon numarası **ve** rezervasyondaki telefon eşleşmelidir. Telefon verilmezse arayan numara kullanılır.
- **Hata toleransı.** Hatalı tarih ya da eksik bilgi gelirse fonksiyon hata fırlatmaz, asistana ne sorması gerektiğini söyler. Veritabanı hatasında Vapi'ye yine düzgün bir cevap döner, böylece görüşme askıda kalmaz.
- **SMS görüşmeyi bekletmez.** Yanıt Vapi'ye gönderildikten sonra SMS atılır. SMS hatası rezervasyonu etkilemez.
- **Fiyat.** Gecelik fiyat `room_rates` tablosundaki sezon fiyatından, yoksa `room_types.price_per_night` değerinden gelir. Toplam fiyat gece gece hesaplanır.

## Kurulum

### 1) Veritabanı

Docker ile:

```bash
cp .env.example .env      # şifreleri doldurun
docker compose up -d      # db/*.sql ilk açılışta otomatik yüklenir
```

Mevcut bir PostgreSQL'e yüklemek için:

```bash
psql "$DATABASE_URL" -f db/01_schema.sql -f db/02_functions.sql -f db/03_seed.sql
```

Oda tiplerinizi `room_types` tablosuna girin:

- `code`: asistanın kullandığı kısa kod.
- `aliases`: müşterinin söyleyebileceği eş anlamlılar, ör. "deniz manzaralı".
- `features`: odanın özellikleri.
- `max_guests`: en fazla kişi sayısı.
- `total_rooms`: o tipteki oda sayısı.
- `price_per_night`: gecelik fiyat.

Sezon fiyatlarını `room_rates` tablosuna, firma adını ve SMS imzasını `app_settings` tablosuna girin.

### 2) n8n

1. **Workflows → Import from File** ile `n8n/vapi-reservations-workflow.json` dosyasını içe aktarın.
2. Credential'ları oluşturun:
   - **Header Auth** (Vapi Tool Call düğümü): Name `X-Vapi-Secret`, Value uzun rastgele bir değer. Bu değer `.env` içindeki `VAPI_WEBHOOK_SECRET` ile aynı olmalı.
   - **Postgres**: 5 sorgu düğümünün hepsinde seçin.
   - **Twilio**: *Send SMS* düğümünde seçin ve `From` alanına Twilio numaranızı yazın.
3. Workflow'u **Active** yapın. Üretim adresi: `https://<n8n-adresiniz>/webhook/vapi/reservations`

> **Türkiye'de SMS:** Twilio yerine Netgsm, İleti Merkezi gibi yerel bir sağlayıcı kullanacaksanız *Send SMS* düğümünü o sağlayıcının API'sine istek atan bir **HTTP Request** düğümüyle değiştirin. Alıcı için `{{$json.result.sms_to}}`, metin için `{{$json.result.sms_text}}` alanlarını kullanın. SMS metni Türkçe karakter içerir; sağlayıcıda Türkçe karakter (TR encoding) seçeneğini açın.

### 3) Vapi

```bash
export $(grep -v '^#' .env | xargs)      # veya değişkenleri elle verin
node vapi/deploy.mjs --dry-run           # gönderilecek JSON'u kontrol edin
node vapi/deploy.mjs                     # asistanı oluşturur
```

Ardından Vapi panelinde telefon numaranızı bu asistana bağlayın. Model, ses ve transcriber ayarları `deploy.mjs` içinde ve ortam değişkenlerindedir:

| Ayar | Varsayılan | Değiştirmek için |
|---|---|---|
| Model | `openai / gpt-4o` | `VAPI_MODEL_PROVIDER`, `VAPI_MODEL` |
| Transcriber | Deepgram `nova-2`, dil `tr` | `deploy.mjs` |
| Ses | ElevenLabs `eleven_multilingual_v2` | `ELEVENLABS_VOICE_ID` ile Türkçe bir ses seçin |

Asistanı panelden elle kurmak isterseniz:

1. `vapi/system-prompt.md` içeriğini System Prompt alanına yapıştırın ve `__COMPANY_NAME__` yerine firma adınızı yazın.
2. `vapi/tools.json` içindeki 5 aracı **Function Tool** olarak ekleyin.
3. Her aracın Server URL'si olarak n8n adresini girin ve `X-Vapi-Secret` başlığını ekleyin.

## Vapi ↔ n8n sözleşmesi

Vapi'nin gönderdiği istek:

```json
{ "message": { "type": "tool-calls",
  "call": { "id": "...", "customer": { "number": "+905321112233" } },
  "toolCallList": [ { "id": "call_abc", "type": "function",
    "function": { "name": "check_availability",
                  "arguments": { "room_type": "deluxe", "check_in": "2026-10-05", "check_out": "2026-10-08", "guests": 2 } } } ] } }
```

n8n'in döndüğü yanıt:

```json
{ "results": [ { "toolCallId": "call_abc", "result": "MÜSAİT. Deluxe Deniz Manzaralı Oda, 5 Ekim 2026 Pazartesi - 8 Ekim 2026 Perşembe (3 gece, 2 kişi) için müsait (kalan oda: 6). Toplam fiyat: 12.000 TL ..." } ] }
```

| Araç | Parametreler |
|---|---|
| `check_availability` | `check_in`, `check_out`, `guests`, `room_type` (ops.) |
| `create_reservation` | `room_type`, `customer_name`, `guests`, `check_in`, `check_out`, `phone` (ops., yoksa arayan numara), `notes` (ops.) |
| `modify_reservation` | `reservation_id`, `phone` (ops.), `check_in` / `check_out` / `guests` (değişenler) |
| `cancel_reservation` | `reservation_id`, `phone` (ops.) |
| `find_reservation` | `phone` (ops.) |

Tarihler `YYYY-AA-GG` formatındadır. Değişiklikte sadece giriş tarihi verilirse gece sayısı korunur.

## Test

Webhook'u Vapi olmadan denemek için:

```bash
export WEBHOOK_URL=http://localhost:5678/webhook/vapi/reservations VAPI_WEBHOOK_SECRET=...
./test/simulate_vapi.sh check_availability '{"room_type":"suit","check_in":"2026-10-05","check_out":"2026-10-08","guests":2}'
./test/simulate_vapi.sh create_reservation '{"room_type":"suit","customer_name":"Ayşe Yılmaz","guests":2,"check_in":"2026-10-05","check_out":"2026-10-08"}'
./test/simulate_vapi.sh cancel_reservation '{"reservation_id":"123456"}'
```

SQL fonksiyonlarını doğrudan da deneyebilirsiniz:

```sql
SELECT fn_check_availability('deniz manzaralı', '2026-10-05', '2026-10-08', '2')->>'message';
```

## Kendi paneliniz

Rezervasyonlar `reservations` tablosunda durur. Panelinizde aynı veritabanını kullanabilir ya da panelden de aynı `fn_*` fonksiyonlarını çağırabilirsiniz; böylece telefon kanalı ile panel aynı stok ve fiyat kurallarını kullanır.

Paneliniz ayrı bir sistemse ve REST API sunuyorsa, n8n'deki Postgres düğümlerini o API'ye istek atan HTTP Request düğümleriyle değiştirin. Yanıt düğümleri `result.message` alanını beklediği için API'nin de aynı alanları dönmesi yeterlidir.
