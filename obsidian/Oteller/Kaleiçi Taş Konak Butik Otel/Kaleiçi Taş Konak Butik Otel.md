---
tip: otel
otel: "Kaleiçi Taş Konak Butik Otel"
bolge: "Kaleiçi"
yildiz: null
konsept: "Oda Kahvaltı"
tags: [otel]
---
# Kaleiçi Taş Konak Butik Otel

Kaleiçi · butik otel · Oda Kahvaltı

Restore edilmiş tarihi taş konak, yalnızca 10 oda. 12 yaş üstü misafir kabul edilir.

**Öne çıkanlar:** tarihi taş konak, avlu bahçesi, Hadrian Kapısı'na 5 dakika yürüme, yetişkinlere uygun (12+)

## Odalar

| Oda | En fazla kişi | Oda sayısı | Gecelik (sezon dışı) | Özellikler |
|---|---:|---:|---:|---|
| Konak Odası | 2 | 6 | 3.600 TL | avlu manzarası, tarihi dekor, klima |
| Tarihi Süit | 2 | 2 | 6.400 TL | şömine, ahşap tavan, marina manzarası, jakuzi |
| Aile Odası | 3 | 2 | 5.200 TL | çatı katı, üç tek yatak, klima |

## Misafirler

Bu klasöre rezervasyon sisteminden otomatik düşen misafir notları. Tablo için **Dataview** eklentisi gerekir.

```dataview
TABLE WITHOUT ID file.link AS "Misafir", telefon AS "Telefon", son_rezervasyon AS "Son rez.", son_durum AS "Durum", rezervasyon_sayisi AS "Rez. sayısı", guncelleme AS "Güncelleme"
FROM "Oteller/Kaleiçi Taş Konak Butik Otel"
WHERE tip = "misafir"
SORT guncelleme DESC
```
