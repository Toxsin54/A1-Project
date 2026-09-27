---
tip: otel
otel: "Lara Deniz Palace"
bolge: "Lara"
yildiz: 5
konsept: "Ultra Her Şey Dahil"
tags: [otel]
---
# Lara Deniz Palace

Lara · 5 yıldız · Ultra Her Şey Dahil

Lara sahilinde, havalimanına 15 dakika mesafede büyük tatil köyü.

**Öne çıkanlar:** özel kumsal, 5 açık havuz, aquapark, spa, çocuk kulübü

## Odalar

| Oda | En fazla kişi | Oda sayısı | Gecelik (sezon dışı) | Özellikler |
|---|---:|---:|---:|---|
| Standart Oda | 2 | 40 | 7.800 TL | bahçe manzarası, balkon, klima, minibar |
| Deluxe Deniz Manzaralı Oda | 3 | 24 | 10.500 TL | deniz manzarası, geniş balkon, kahve makinesi, minibar |
| Aile Odası | 4 | 12 | 14.500 TL | iki yatak odası, iki banyo, çocuk yatağı imkânı |
| Kral Süit | 4 | 2 | 32.000 TL | deniz manzarası, jakuzi, oturma odası, VIP transfer |

## Misafirler

Bu klasöre rezervasyon sisteminden otomatik düşen misafir notları. Tablo için **Dataview** eklentisi gerekir.

```dataview
TABLE WITHOUT ID file.link AS "Misafir", telefon AS "Telefon", son_rezervasyon AS "Son rez.", son_durum AS "Durum", rezervasyon_sayisi AS "Rez. sayısı", guncelleme AS "Güncelleme"
FROM "Oteller/Lara Deniz Palace"
WHERE tip = "misafir"
SORT guncelleme DESC
```
