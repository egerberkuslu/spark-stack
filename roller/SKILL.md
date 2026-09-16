---
name: sirket-kurallari
description: Şirketin kod, test, PR ve yazım kuralları. Kod yazarken, test eklerken, commit mesajı veya PR açıklaması hazırlarken, doküman veya rapor yazarken kullan.
---

# Şirket kuralları

Kurallar tek yerde durur: bilgi tabanındaki `kurallar/` klasörü. Bu skill kuralların
metnini taşımaz, yerini söyler. Sebebi basit: kopyalanan kural eskir, tek kaynak eskimez.
Bir kural değişecekse vault'ta değişir ve o an bütün ajanlar için değişmiş olur.

## Önce oku

Çalıştığın ortama göre yol değişir, içerik aynıdır:

| Ortam | Kurallar nerede |
|---|---|
| Makinede Claude Code | `__KURALLAR__/` |
| Agent Canvas kabı | `/vault/kurallar/` |

Hangi dosya, ne zaman:

| Dosya | Ne zaman okunur |
|---|---|
| `kod-standartlari.md` | kod yazarken ya da değiştirirken |
| `test-kurallari.md` | test yazarken ya da çalıştırırken |
| `pr-kurallari.md` | commit mesajı ya da PR açıklaması hazırlarken |
| `yazim-kurallari.md` | doküman, README, yorum ya da rapor yazarken |

## Kural

İşe başlamadan önce ilgili dosyayı oku; hafızandaki sürüme güvenme. Bir kural belirsizse
bilgi tabanında ara, uydurma — bulamadığını raporunda söyle.

Kural değişikliğini vault'a yazarsın, bu dosyaya değil.

## Roller

İş birden fazla adım içeriyorsa rollere böl. Roller de aynı kuralları okur:

| Rol | Ne yapar | Ne yapmaz |
|---|---|---|
| `spark-kod` | kod yazar, değiştirir | test yazmaz, kendini onaylamaz |
| `spark-test` | test yazar ve çalıştırır | kodu düzeltmez |
| `spark-denetci` | denetler, PR açıklaması hazırlar | kod yazmaz, birleştirmez |
