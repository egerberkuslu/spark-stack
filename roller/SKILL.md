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


## Bilgi tabanında araştır

Şirketin hafızası `__VAULT__` altında ve **salt okunur** bağlı. Geçmiş bir karar, tasarım notu ya da
kaynak gerektiren her soruda önce oraya bak; hafızandan cevap verme.

| Nerede | Ne var |
|---|---|
| `__VAULT__/wiki/index.md` | başlangıç noktası, konu haritası |
| `__VAULT__/wiki/overview.md` | sistemin bugünkü hâli |
| `__VAULT__/wiki/log.md` | kararlar ve ne zaman alındıkları |
| `__VAULT__/wiki/` | konu sayfaları |
| `__VAULT__/inbox/` | henüz işlenmemiş kaynaklar |
| `__VAULT__/kurallar/` | bağlayıcı kurallar |

Aramak için `grep -ril "konu" __VAULT__/wiki` ile başla, bulduğun sayfayı oku. Bir karar vault'ta
yazılıysa ona uy ve raporunda hangi sayfaya dayandığını söyle. Yazılı değilse "vault'ta kayıt
yok" de — varmış gibi konuşma.

## Roller

İş birden fazla adım içeriyorsa rollere böl. Roller de aynı kuralları okur:

| Rol | Ne yapar | Ne yapmaz |
|---|---|---|
| `spark-kod` | kod yazar, değiştirir | test yazmaz, kendini onaylamaz |
| `spark-test` | test yazar ve çalıştırır | kodu düzeltmez |
| `spark-denetci` | denetler, PR açıklaması hazırlar | kod yazmaz, birleştirmez |
