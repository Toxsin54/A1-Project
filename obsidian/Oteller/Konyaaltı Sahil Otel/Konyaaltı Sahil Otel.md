---
tip: otel
otel: "Konyaaltı Sahil Otel"
bolge: "Konyaaltı"
yildiz: 4
konsept: "Yarım Pansiyon"
tags: [otel]
---
# Konyaaltı Sahil Otel

Konyaaltı · 4 yıldız · Yarım Pansiyon

Şehir merkezinde, Konyaaltı plajına sıfır.

**Öne çıkanlar:** sahile sıfır, çatı havuzu, Antalya Müzesi'ne yakın, ücretsiz otopark

## Odalar

| Oda | En fazla kişi | Oda sayısı | Gecelik (sezon dışı) | Özellikler |
|---|---:|---:|---:|---|
| Ekonomik Oda | 2 | 20 | 3.200 TL | şehir manzarası, klima, ücretsiz Wi-Fi |
| Deniz Manzaralı Oda | 2 | 14 | 4.300 TL | deniz manzarası, balkon, klima |
| Aile Odası | 4 | 6 | 5.600 TL | ara kapılı iki oda, çocuk yatağı imkânı, klima |

## Misafirler

Bu klasöre rezervasyon sisteminden otomatik düşen misafir notları. Tablo için **Dataview** eklentisi gerekir.

```dataview
TABLE WITHOUT ID file.link AS "Misafir", telefon AS "Telefon", son_rezervasyon AS "Son rez.", son_durum AS "Durum", rezervasyon_sayisi AS "Rez. sayısı", guncelleme AS "Güncelleme"
FROM "Oteller/Konyaaltı Sahil Otel"
WHERE tip = "misafir"
SORT guncelleme DESC
```
