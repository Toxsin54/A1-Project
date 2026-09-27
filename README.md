# A1 Acente Otomasyonu: Telefonla Rezervasyon Asistanı

Müşteri telefonla arar, sesli asistan (Vapi) onunla konuşur ve şu adımları izler:

1. Tarih, kişi sayısı ve oda tipi bilgilerini alır.
2. Sistemde müsaitlik sorgular:
   - İstenen oda boşsa özelliklerini ve fiyatını söyler.
   - Oda doluysa ya da kişi sayısına uygun değilse fiyat ve özellikleriyle **alternatifler** sunar.
3. Müşteri onay verirse rezervasyonu oluşturur ve rezervasyon numarasını söyler.
4. Rezervasyon detaylarını müşteriye **SMS**, **WhatsApp** ve (müşteri e-posta verdiyse) **e-posta** ile gönderir.

Değişiklik, iptal ve rezervasyon numarasını unutan müşteri için telefonla arama da desteklenir.

```
Müşteri ──telefon──▶ Vapi (STT + LLM + TTS)
                         │  tool call (POST, X-Vapi-Secret)
                         ▼
                 n8n  /webhook/vapi/reservations
   Vapi Tool Call ─▶ Extract Tool Call ─▶ Route Tool (Switch)
        ├─ check_availability ─▶ Query Availability ─▶ Respond Availability
        ├─ create_reservation ─▶ Create Reservation ─▶ Respond Create ─┐   ┌▶ Should Send SMS? ──┬▶ Send SMS (Twilio)
        ├─ modify_reservation ─▶ Modify Reservation ─▶ Respond Modify ─┼───┤                     └▶ Send WhatsApp (Twilio)
        ├─ cancel_reservation ─▶ Cancel Reservation ─▶ Respond Cancel ─┘   └▶ Should Send Email? ─▶ Send Email (SMTP)
        ├─ find_reservation   ─▶ Find Reservation   ─▶ Respond Find
        └─ (Unknown)          ─────────────────────▶ Respond Unknown
                         │
                         ▼
                 PostgreSQL (oda tipleri, fiyatlar, rezervasyonlar + iş mantığı)
```

## Dosyalar

| Dosya | Açıklama |
|---|---|
| `db/01_schema.sql` | Tablolar: `hotels` (otel, bölge, yıldız, konsept), `room_types` (otele bağlı oda tipi, özellikler, kapasite, stok, fiyat), `room_rates` (sezon fiyatları), `reservations`, `app_settings` |
| `db/02_functions.sql` | Tüm iş mantığı: müsaitlik, alternatifler, fiyat hesabı, rezervasyon, değişiklik, iptal, SMS metni |
| `db/03_seed.sql` | Antalya test verisi: 6 otel, 20 oda tipi, sezon fiyatları, hazır test rezervasyonları. Kendi verilerinizle değiştirin |
| `n8n/vapi-reservations-workflow.json` | n8n'e import edilecek workflow (telefon + rezervasyon araçları) |
| `n8n/messaging-workflow.json` | Mesaj asistanı: WhatsApp, Instagram DM, Facebook Messenger |
| `messaging/system-prompt.md` | Mesaj asistanının talimatı |
| `vapi/system-prompt.md` | Asistanın Türkçe talimatları |
| `vapi/tools.json` | Vapi araç (tool) tanımları |
| `vapi/deploy.mjs` | Asistanı Vapi API ile oluşturan/güncelleyen betik |
| `test/antalya-test-db.sql` | Mevcut veritabanını sıfırlayıp şema + fonksiyonlar + Antalya verisini tek seferde yükleyen dosya (`test/build_antalya_db.sh` ile üretilir) |
| `test/simulate_vapi.sh` | Vapi isteğini taklit ederek webhook'u test eder |
| `docker-compose.yml` | Yerel/küçük kurulum için PostgreSQL + n8n |

## Tasarım kararları

- **İş mantığı veritabanında.** Her araç tek bir SQL fonksiyonu çağırır (`fn_check_availability`, `fn_create_reservation`...). Fonksiyon, asistanın müşteriye aktaracağı Türkçe `message` metnini ve SMS bilgisini döner. n8n sadece yönlendirir. Kendi panelinizden de aynı fonksiyonları çağırabilirsiniz.
- **Doğru müsaitlik hesabı.** Konaklamanın her gecesi ayrı ayrı sayılır ve en dolu gece esas alınır: `boş oda = toplam oda - o gecedeki onaylı rezervasyon`. İptal edilen (`cancelled`) rezervasyonlar sayılmaz.
- **Çok otelli arama.** Müşteri otel adı ya da bölge ("Lara", "Kemer") söyleyebilir. İstenen oda doluysa önce aynı oteldeki diğer odalar, orada da yer yoksa diğer otellerdeki seçenekler önerilir. Tercih yoksa her otelin en uygun fiyatlı odası listelenir. Hiçbir oda kişi sayısına yetmiyorsa asistana iki oda önermesi söylenir.
- **Çift satış (overbooking) yok.** Rezervasyon oluşturma ve değiştirme işlemleri oda tipi satırını kilitler (`FOR UPDATE`). Son odaya aynı anda iki istek gelirse ikincisi "az önce doldu" cevabı alır.
- **Mükerrer kayıt yok.** Asistan aynı rezervasyonu 15 dakika içinde tekrar gönderirse yeni kayıt açılmaz ve ikinci SMS gitmez; mevcut numara döner.
- **Güvenlik.**
  - Webhook, `X-Vapi-Secret` başlığı olmadan çalışmaz.
  - Değişiklik ve iptal için rezervasyon numarası **ve** rezervasyondaki telefon eşleşmelidir. Telefon verilmezse arayan numara kullanılır.
- **Hata toleransı.** Hatalı tarih ya da eksik bilgi gelirse fonksiyon hata fırlatmaz, asistana ne sorması gerektiğini söyler. Veritabanı hatasında Vapi'ye yine düzgün bir cevap döner, böylece görüşme askıda kalmaz.
- **Bildirimler görüşmeyi bekletmez.** SMS, WhatsApp ve e-posta, yanıt Vapi'ye gönderildikten sonra gönderilir. Birinin başarısız olması diğerlerini ve rezervasyonu etkilemez. E-posta sadece müşteri adres verdiyse gider; asistan adresi harf harf teyit eder, geçersiz adreste rezervasyonu oluşturmadan tekrar sorar.
- **Fiyat.** Gecelik oda fiyatı `room_rates` tablosundaki sezon fiyatından, yoksa `room_types.price_per_night` değerinden gelir ve gece gece toplanır. Oda fiyatı `base_occupancy` kadar kişiyi (genelde 2) kapsar; kişi başı fiyat = oda fiyatı / `base_occupancy`.
- **Çocuk politikası.** Her otelin kuralları `hotels` (`adult_age`, `infant_age`, `min_guest_age`, `extra_adult_pct`) ve `hotel_child_policies` tablolarında durur. Hesap şöyle yapılır:
  - Çocuklar giriş tarihindeki yaşa göre büyükten küçüğe sıralanır.
  - `adult_age` ve üstü yetişkin sayılır. `infant_age` altı bebekler ücretsizdir ve kapasiteye sayılmaz.
  - Oda fiyatına dahil kişi sayısı henüz dolmadıysa çocuk oradaki boş yere yerleşir. Örneğin 1 yetişkin + 1 çocuk oda fiyatı öder.
  - Sonraki çocuklar "1. çocuk", "2. çocuk" olarak numaralanır ve kişi başı fiyatın `price_pct` yüzdesini öder (0 = ücretsiz). Kural yoksa yetişkin fiyatı öder. `child_order` boş olan kural sıradan bağımsız uygulanır (ör. "her çocuk 0-5 yaş ücretsiz").
  - Oda fiyatına dahil kişi sayısını aşan yetişkinler kişi başı fiyatın `extra_adult_pct` yüzdesini öder.

## Kurulum

### 1) Veritabanı

Docker ile:

```bash
cp .env.example .env      # şifreleri doldurun
docker compose up -d      # db/*.sql ilk açılışta otomatik yüklenir
```

Mevcut bir PostgreSQL'e yüklemek için (tekrar çalıştırmak güvenlidir; veriler silinmez, yeni alanlar ve fonksiyonlar eklenir):

```bash
psql "$DATABASE_URL" -f db/01_schema.sql -f db/02_functions.sql -f db/03_seed.sql
```

Otellerinizi `hotels`, oda tiplerini `room_types` tablosuna girin:

- `hotels.region`: bölge; müşteri "Lara'da bir otel" derse bu alanla eşleşir.
- `hotels.aliases`: otelin kısa adları, ör. "taş konak".
- `code`: asistanın kullandığı, tüm otellerde tekil kod, ör. `lara-deluxe`.
- `category`: genel oda tipi (standart, deluxe, aile, suit, villa...); "aile odası" gibi aramalar bu alanla tüm otellerde eşleşir.
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
   - **Twilio**: *Send SMS* ve *Send WhatsApp* düğümlerinde seçin.
     - *Send SMS* düğümünün `From` alanına Twilio SMS numaranızı yazın.
     - *Send WhatsApp* düğümünün `From` alanına WhatsApp göndericinizi yazın. Test için Twilio Sandbox numarası `+14155238886` kullanılabilir; bu durumda alıcının önce sandbox'a WhatsApp'tan `join <kod>` mesajı göndermesi gerekir.
   - **SMTP**: *Send Email* düğümünde seçin ve `From Email` alanını kendi adresinizle değiştirin. Gmail kullanıyorsanız host `smtp.gmail.com`, port `465`, SSL açık, şifre olarak Google hesabınızdan alınan **uygulama şifresi** girilir.
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

### 4) Mesaj asistanı: WhatsApp, Instagram DM, Facebook Messenger

Üç kanaldan yazan müşteriyle aynı kurallarla yazışarak rezervasyon yapar. Asistan, yukarıdaki rezervasyon webhook'unu araç olarak çağırır. Bu yüzden fiyat hesabı, çocuk politikası ve SMS/WhatsApp/e-posta bildirimleri telefon kanalıyla birebir aynıdır.

```
WhatsApp  ─▶ Twilio ─▶ /webhook/whatsapp/incoming?key=…  ─┐
Instagram ─▶ Meta   ─▶ /webhook/meta/messages (imzalı) ────┼─▶ kanal açık mı? ─▶ AI Agent (OpenAI + sohbet hafızası)
Messenger ─▶ Meta   ─▶ /webhook/meta/messages (imzalı) ────┘         │ 5 araç
                                                                    ▼
                                          /webhook/vapi/reservations (mevcut workflow) ─▶ Supabase
AI Agent cevabı ─▶ gelen kanala (Twilio / Instagram API / Messenger API)
```

- **Dosyalar:** Workflow `n8n/messaging-workflow.json`, asistan talimatı `messaging/system-prompt.md`. Talimat workflow'a gömülüdür; kanal, tarih ve telefon bilgisi otomatik eklenir.
- **Kanal anahtarları:** *Messaging Settings* düğümündeki `whatsapp_enabled`, `instagram_enabled`, `messenger_enabled` ile her kanal ayrı açılıp kapatılır. Varsayılan: **hepsi kapalı**. Kapalı kanaldan gelen mesaja cevap verilmez; Twilio ve Meta'ya yine 200 dönülür.
- **Telefon:** WhatsApp'ta müşterinin numarası otomatik gelir. Instagram ve Messenger'da asistan cep telefonunu sorar.
- **Kanal kaydı:** Rezervasyonun `source` alanı `whatsapp`, `instagram` veya `facebook` olur.
- **Güvenlik:**
  - WhatsApp isteklerinde URL'deki `key` kontrol edilir.
  - Meta isteklerinde `X-Hub-Signature-256` imzası App Secret ile doğrulanır.
  - Uymayan istekler 403 ile reddedilir.
- **Sohbet hafızası:** Supabase'de `chat_histories` tablosunda kanal ve kullanıcıya göre tutulur. Tabloyu n8n kendisi oluşturur.

**Ortak kurulum**
1. Workflow'u import edin (workflow ve üç kanal kapalı gelir).
2. *Messaging Settings* düğümünde `reservation_webhook_url` alanına rezervasyon workflow'unun Production URL'sini, `company_name` alanına firma adını yazın.
3. Credential'ları seçin:
   - *OpenAI Chat Model*: OpenAI API anahtarı.
   - *Chat Memory*: Postgres.
   - 5 araç düğümü: rezervasyon webhook'undaki **Header Auth**.

**WhatsApp'ı açmak**
1. `webhook_key` alanına uzun rastgele bir değer yazın. `twilio_whatsapp_from` alanına Twilio WhatsApp göndericisini yazın (Sandbox: `+14155238886`). *Reply WhatsApp* düğümünde Twilio credential'ını seçin.
2. Twilio → Messaging → Try it out → WhatsApp → Sandbox settings bölümünde **When a message comes in** alanına şunu yazıp POST seçin: `https://<n8n>/webhook/whatsapp/incoming?key=<webhook_key>`.
3. `whatsapp_enabled = true` yapın ve workflow'u **Publish** edin.

**Instagram DM ve Facebook Messenger'ı açmak**
1. **Hazırlık:** Instagram hesabı **İşletme/İçerik Üreticisi** olmalı; Messenger için bir **Facebook Sayfası** gerekir. developers.facebook.com'da bir uygulama oluşturup **Instagram** ve/veya **Messenger** ürünlerini ekleyin.
2. **App Secret:** Uygulama Ayarları → Temel bölümündeki **App Secret** değerini n8n'de bir **Crypto** credential'ına *HMAC Secret* olarak girin ve *Sign Meta Payload* düğümünde seçin.
3. **Erişim anahtarları:** Instagram ve sayfa erişim anahtarlarını birer **Header Auth** credential'ı olarak girin (Name: `Authorization`, Value: `Bearer <anahtar>`). *Reply Instagram* ve *Reply Messenger* düğümlerinde seçin.
4. **Webhook adresi:** `meta_verify_token` alanına kendi belirlediğiniz bir kelime yazın. Workflow'u Publish edin. Meta uygulamasında webhook olarak şunları girin:
   - Callback URL: `https://<n8n>/webhook/meta/messages`
   - Verify Token: `meta_verify_token` alanına yazdığınız kelime.
   - Abone olunacak alan: `messages`.
5. **Kanalı açın:** `instagram_enabled` ve/veya `messenger_enabled = true` yapıp tekrar Publish edin.
6. **Test ve yayın:** Test aşamasında sadece uygulamada rolü olan hesaplar yazabilir. Herkese açmak için Meta uygulama incelemesi gerekir: `instagram_business_manage_messages` / `pages_messaging`.

Graph API sürümü (`v23.0`) *Messaging Settings* içindeki `instagram_api_url` ve `messenger_api_url` alanlarından güncellenebilir.

## Vapi ↔ n8n sözleşmesi

Vapi'nin gönderdiği istek:

```json
{ "message": { "type": "tool-calls",
  "call": { "id": "...", "customer": { "number": "+905321112233" } },
  "toolCallList": [ { "id": "call_abc", "type": "function",
    "function": { "name": "check_availability",
                  "arguments": { "hotel": "Lara", "room_type": "deluxe", "check_in": "2026-10-12", "check_out": "2026-10-15", "guests": 2 } } } ] } }
```

n8n'in döndüğü yanıt:

```json
{ "results": [ { "toolCallId": "call_abc", "result": "MÜSAİT (12 Ekim 2026 Pazartesi - 15 Ekim 2026 Perşembe (3 gece, 2 kişi)): 1) Lara Deniz Palace (Lara, 5 yıldız, Ultra Her Şey Dahil) - Deluxe Deniz Manzaralı Oda [room_type=\"lara-deluxe\"] - toplam 31.500 TL ..." } ] }
```

| Araç | Parametreler |
|---|---|
| `check_availability` | `check_in`, `check_out`, `adults`, `children_ages` (ops., ör. "8, 4"), `hotel` (ops., otel adı ya da bölge), `room_type` (ops.) |
| `create_reservation` | `room_type` (sorgu sonucundaki kod), `customer_name`, `adults`, `children_ages` (ops.), `check_in`, `check_out`, `phone` (ops., yoksa arayan numara), `email` (ops.), `notes` (ops.), `hotel` (ops.) |
| `modify_reservation` | `reservation_id`, `phone` (ops.), `check_in` / `check_out` / `adults` / `children_ages` (değişenler; çocukları kaldırmak için "yok") |
| `cancel_reservation` | `reservation_id`, `phone` (ops.) |
| `find_reservation` | `phone` (ops.) |

Tarihler `YYYY-AA-GG` formatındadır. Eski `guests` (toplam kişi) alanı hâlâ kabul edilir; `adults` yoksa `guests - çocuk sayısı` yetişkin sayılır. Değişiklikte sadece giriş tarihi verilirse gece sayısı korunur.

## Test

### Antalya test veritabanı

`test/antalya-test-db.sql` dosyası mevcut tabloları ve `fn_*` fonksiyonlarını **silip** her şeyi yeniden kurar. Sadece test veritabanında çalıştırın:

```bash
psql "$DATABASE_URL" -f test/antalya-test-db.sql
```

Supabase gibi bir SQL editörü kullanıyorsanız dosyanın içeriğini yapıştırıp çalıştırmanız yeterli. `db/` altındaki dosyaları değiştirdikten sonra `./test/build_antalya_db.sh` ile yeniden üretin.

| Otel | Bölge | Konsept | Oda tipleri (en fazla kişi / oda sayısı / gecelik TL) |
|---|---|---|---|
| Lara Deniz Palace | Lara, 5★ | Ultra Her Şey Dahil | Standart 2/40/7.800 · Deluxe Deniz 3/24/10.500 · Aile 4/12/14.500 · Kral Süit 4/2/32.000 |
| Belek Green Golf & Spa Resort | Belek, 5★ | Ultra Her Şey Dahil | Superior 2/30/9.200 · Golf Deluxe 3/20/11.800 · Aile Süiti 5/10/17.500 · Havuzlu Villa 6/3/42.000 |
| Kemer Çamkoru Hotel | Kemer, 4★ | Her Şey Dahil | Standart 2/36/4.900 · Bungalov 3/14/6.200 · Aile 4/8/7.900 |
| Side Antik Liman Resort | Side, 5★ | Her Şey Dahil | Standart 3/28/6.800 · Deniz Deluxe 3/16/8.900 · Bağlantılı Aile 5/8/12.400 |
| Kaleiçi Taş Konak Butik Otel | Kaleiçi, butik | Oda Kahvaltı | Konak Odası 2/6/3.600 · Tarihi Süit 2/2/6.400 · Aile 3/2/5.200 |
| Konyaaltı Sahil Otel | Konyaaltı, 4★ | Yarım Pansiyon | Ekonomik 2/20/3.200 · Deniz Manzaralı 2/14/4.300 · Aile 4/6/5.600 |

Sezon fiyatları: 1 Haziran–30 Eylül arası tatil köyleri %45, şehir otelleri (Kaleiçi, Konyaaltı) %20 zamlı; 29 Aralık–2 Ocak arası şehir otelleri %60 zamlı.

Hazır test senaryoları (telefonda asistana söyleyebilirsiniz):

| Ne söyleyin | Beklenen davranış |
|---|---|
| "12-15 Ekim, 2 kişi, Lara'da kral süit" | Süit dolu → aynı oteldeki diğer odalar önerilir |
| "28-31 Ekim, 2 kişi, Kaleiçi'nde" | Otel tamamen dolu (29 Ekim) → diğer otellerden seçenek önerilir |
| "2-5 Kasım, 6 kişi, Belek'te villa" | Villalar dolu, 6 kişilik başka oda yok → iki oda önerilir |
| "6-9 Ekim, 4 kişi, Kemer'de aile odası" | Tek oda kaldı; rezervasyondan sonra aynı sorgu "dolu" döner |
| "6-9 Ekim, 4 kişi, aile odası" (otel belirtmeden) | Tüm otellerdeki aile odaları fiyata göre listelenir |
| "10-13 Kasım, 2 kişi" (hiç tercih yok) | Her otelin en uygun fiyatlı odası listelenir |
| "30 Aralık - 2 Ocak, Konyaaltı deniz manzaralı" | Yılbaşı fiyatı (gecelik 6.900 TL) uygulanır |
| "12-15 Ekim, Lara aile odası, 2 yetişkin, çocuklar 10 ve 8 yaş" | 1. çocuk ücretsiz, 2. çocuk %50: 54.375 TL |
| "12-15 Ekim, Kemer aile odası, 2 yetişkin, çocuklar 8 ve 4 yaş" | 0-5 yaş ücretsiz, 6-11 yaş %50: 29.625 TL |
| "Kaleiçi, 2 yetişkin ve 7 yaşında çocuk" | Otel 12 yaş altı kabul etmiyor → diğer oteller önerilir |
| Rezervasyon **100001**, telefon **0555 111 22 33** | Değişiklik testi (Konyaaltı, 15-18 Ekim) |
| Rezervasyon **100002**, telefon **0555 444 55 66** | İptal testi (Side, 20-25 Ekim) |

### Webhook'u Vapi olmadan denemek

```bash
export WEBHOOK_URL=http://localhost:5678/webhook/vapi/reservations VAPI_WEBHOOK_SECRET=...
./test/simulate_vapi.sh check_availability '{"hotel":"Lara","room_type":"kral süit","check_in":"2026-10-12","check_out":"2026-10-15","guests":2}'
./test/simulate_vapi.sh create_reservation '{"room_type":"lara-deluxe","customer_name":"Ayşe Yılmaz","guests":2,"check_in":"2026-10-12","check_out":"2026-10-15"}'
./test/simulate_vapi.sh cancel_reservation '{"reservation_id":"100002"}' +905554445566
```

SQL fonksiyonlarını doğrudan da deneyebilirsiniz:

```sql
SELECT fn_check_availability('aile odası', '2026-10-06', '2026-10-09', '4', 'Kemer')->>'message';
```

## Kendi paneliniz

Rezervasyonlar `reservations` tablosunda durur. Panelinizde aynı veritabanını kullanabilir ya da panelden de aynı `fn_*` fonksiyonlarını çağırabilirsiniz; böylece telefon kanalı ile panel aynı stok ve fiyat kurallarını kullanır.

Paneliniz ayrı bir sistemse ve REST API sunuyorsa, n8n'deki Postgres düğümlerini o API'ye istek atan HTTP Request düğümleriyle değiştirin. Yanıt düğümleri `result.message` alanını beklediği için API'nin de aynı alanları dönmesi yeterlidir.
