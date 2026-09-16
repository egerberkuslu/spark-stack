# Commit ve PR kuralları

## Commit

Türkçe, emir kipi, küçük harfle başlar: `kullanıcı girişini doğrula`. Nokta konmaz.
İlk satır 60 karakteri geçmez.

Bir commit tek bir değişiklik taşır. Biçimlendirme ile davranış değişikliği aynı commit'te
olmaz — inceleyen ikisini ayırt edemez.

Commit mesajı **ne** yapıldığını değil **neden** yapıldığını anlatır; ne yapıldığı zaten
diff'te görünür.

## Dal

`main` üzerinde çalışılmaz. Dal adı işi anlatır: `fix/token-yenileme`, `feat/toplu-indirme`.

Gönderilmiş commit yeniden yazılmaz (`amend`, `rebase` yok).

## PR açıklaması

Üç başlık, bu sırayla:

**Ne değişti** — tek paragraf, teknik olmayan biri de anlasın.

**Neden** — hangi sorun, hangi karar. İlgili karar vault'ta yazılıysa bağlantısı verilir.

**Nasıl test edildi** — çalıştırılan komut ve çıktısı. "Test ettim" yeterli değildir.

## İnceleme

İnceleyen ajan üç kategoriye ayırır: **engelleyici** (birleşemez), **düzeltilmeli**
(birleşebilir ama iş kartı açılır), **öneri** (yazarın tercihi).

Engelleyici bulgu gerekçesiz yazılmaz; hangi kuralın hangi satırda çiğnendiği gösterilir.

Ajan PR açar, **birleştirmez**. Birleştirme kararı insanındır.
