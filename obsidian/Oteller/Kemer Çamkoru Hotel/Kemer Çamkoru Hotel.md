---
tip: otel
otel: "Kemer Çamkoru Hotel"
bolge: "Kemer"
yildiz: 4
konsept: "Her Şey Dahil"
tags: [otel]
---
# Kemer Çamkoru Hotel

Kemer · 4 yıldız · Her Şey Dahil

Toros eteklerinde, çam ormanı içinde sakin bir otel.

**Öne çıkanlar:** çam ormanı içinde, çakıl plaj, dalış merkezi, ücretsiz Wi-Fi

## Odalar

| Oda | En fazla kişi | Oda sayısı | Gecelik (sezon dışı) | Özellikler |
|---|---:|---:|---:|---|
| Standart Oda | 2 | 36 | 4.900 TL | orman manzarası, balkon, klima |
| Bahçe Bungalovu | 3 | 14 | 6.200 TL | müstakil giriş, bahçe, veranda, klima |
| Aile Odası | 4 | 8 | 7.900 TL | ara kapılı iki oda, çocuk yatağı imkânı, balkon |

## Misafirler

Bu klasöre rezervasyon sisteminden otomatik düşen misafir notları. Tablo için **Dataview** eklentisi gerekir.

```dataview
TABLE WITHOUT ID file.link AS "Misafir", telefon AS "Telefon", son_rezervasyon AS "Son rez.", son_durum AS "Durum", rezervasyon_sayisi AS "Rez. sayısı", guncelleme AS "Güncelleme"
FROM "Oteller/Kemer Çamkoru Hotel"
WHERE tip = "misafir"
SORT guncelleme DESC
```
