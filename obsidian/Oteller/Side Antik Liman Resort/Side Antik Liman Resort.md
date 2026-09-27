---
tip: otel
otel: "Side Antik Liman Resort"
bolge: "Side"
yildiz: 5
konsept: "Her Şey Dahil"
tags: [otel]
---
# Side Antik Liman Resort

Side · 5 yıldız · Her Şey Dahil

Side antik kentine 10 dakika mesafede, kumsal kenarında.

**Öne çıkanlar:** kumsal, kapalı havuz, hamam, animasyon ekibi, antik kente servis

## Odalar

| Oda | En fazla kişi | Oda sayısı | Gecelik (sezon dışı) | Özellikler |
|---|---:|---:|---:|---|
| Standart Oda | 3 | 28 | 6.800 TL | kara manzarası, balkon, klima, minibar |
| Deniz Manzaralı Deluxe Oda | 3 | 16 | 8.900 TL | deniz manzarası, balkon, kahve makinesi |
| Bağlantılı Aile Odası | 5 | 8 | 12.400 TL | ara kapılı iki oda, iki banyo, çocuk yatağı imkânı |

## Misafirler

Bu klasöre rezervasyon sisteminden otomatik düşen misafir notları. Tablo için **Dataview** eklentisi gerekir.

```dataview
TABLE WITHOUT ID file.link AS "Misafir", telefon AS "Telefon", son_rezervasyon AS "Son rez.", son_durum AS "Durum", rezervasyon_sayisi AS "Rez. sayısı", guncelleme AS "Güncelleme"
FROM "Oteller/Side Antik Liman Resort"
WHERE tip = "misafir"
SORT guncelleme DESC
```
