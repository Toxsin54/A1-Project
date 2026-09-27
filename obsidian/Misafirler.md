---
tags: [pano]
---
# Misafirler

Rezervasyon asistanının oluşturduğu, değiştirdiği veya iptal ettiği her rezervasyonda misafirin notu
`Oteller/<Otel>/<Ad Soyad>.md` olarak otomatik oluşturulur ya da güncellenir.

## Oteller

- [[Lara Deniz Palace]] (Lara)
- [[Belek Green Golf & Spa Resort]] (Belek)
- [[Kemer Çamkoru Hotel]] (Kemer)
- [[Side Antik Liman Resort]] (Side)
- [[Kaleiçi Taş Konak Butik Otel]] (Kaleiçi)
- [[Konyaaltı Sahil Otel]] (Konyaaltı)

## Son güncellenen misafirler

Tablo için **Dataview** eklentisi gerekir.

```dataview
TABLE WITHOUT ID file.link AS "Misafir", otel AS "Otel", telefon AS "Telefon", son_rezervasyon AS "Son rez.", son_durum AS "Durum", guncelleme AS "Güncelleme"
FROM "Oteller"
WHERE tip = "misafir"
SORT guncelleme DESC
LIMIT 50
```

## Aktif rezervasyonu olan misafirler

```dataview
TABLE WITHOUT ID file.link AS "Misafir", otel AS "Otel", aktif_toplam_tl AS "Aktif tutar (TL)"
FROM "Oteller"
WHERE tip = "misafir" AND aktif_toplam_tl > 0
SORT aktif_toplam_tl DESC
```
