---
tip: otel
otel: "Belek Green Golf & Spa Resort"
bolge: "Belek"
yildiz: 5
konsept: "Ultra Her Şey Dahil"
tags: [otel]
---
# Belek Green Golf & Spa Resort

Belek · 5 yıldız · Ultra Her Şey Dahil

Golf sahası içinde, çam ağaçlarıyla çevrili resort.

**Öne çıkanlar:** 18 delikli golf sahası, mavi bayraklı plaj, termal spa, tenis kortları

## Odalar

| Oda | En fazla kişi | Oda sayısı | Gecelik (sezon dışı) | Özellikler |
|---|---:|---:|---:|---|
| Superior Oda | 2 | 30 | 9.200 TL | orman manzarası, balkon, klima, minibar |
| Golf Manzaralı Deluxe Oda | 3 | 20 | 11.800 TL | golf manzarası, geniş teras, kahve makinesi |
| Aile Süiti | 5 | 10 | 17.500 TL | iki yatak odası, oturma alanı, çocuk yatağı imkânı |
| Özel Havuzlu Villa | 6 | 3 | 42.000 TL | özel havuz, üç yatak odası, bahçe, butler hizmeti |

## Misafirler

Bu klasöre rezervasyon sisteminden otomatik düşen misafir notları. Tablo için **Dataview** eklentisi gerekir.

```dataview
TABLE WITHOUT ID file.link AS "Misafir", telefon AS "Telefon", son_rezervasyon AS "Son rez.", son_durum AS "Durum", rezervasyon_sayisi AS "Rez. sayısı", guncelleme AS "Güncelleme"
FROM "Oteller/Belek Green Golf & Spa Resort"
WHERE tip = "misafir"
SORT guncelleme DESC
```
