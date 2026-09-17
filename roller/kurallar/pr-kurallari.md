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

## Mekanik denetim

| Kural | Nasıl denetlenir | Kim |
|---|---|---|
| Küçük harf, sonda nokta yok, 60 karakter | commit-msg kancası | kapı |
| `main` üzerinde çalışılmaz, dal adı `tür/iş` biçiminde | pre-commit kancası | kapı |
| Gönderilmiş commit yeniden yazılmaz | pre-push: uzaktaki commit yerelin atası değilse itme durur | kapı |
| Üç başlık ve çalıştırılan komut | PR kapısı açıklamayı okur (`gh` ya da CI) | kapı |
| Tek değişiklik, "neden" anlatımı, inceleme sınıfları | okunarak | spark-denetci |
| Birleştirme insanındır | `spark kural pr` çıktısı yeşil olmadan birleştirme yapılmaz | insan |

Kapı bir kerelik `KURAL_KAPISI_ATLA=1` ile atlanabilir; her atlama tarih, kullanıcı ve dalla
`denetim/atlama.log` dosyasına yazılır ve raporda söylenir. `git --no-verify` kancaları geçer ama
PR kapısı ve CI aynı denetimi yeniden koşturur; kaçış yolu değildir.
