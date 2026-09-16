# Bu depoda çalışan ajanlar için

Bu dosya projenin köküne konur ve **hem Claude Code hem Agent Canvas tarafından
kendiliğinden okunur**: içeriği tam metin olarak sistem istemine girer, tetikleyici
gerekmez. Yani hangi ajan çalışırsa çalışsın aynı sözleşmeye bağlanır.

Adı bilerek `AGENTS.md`: `CLAUDE.md` de okunuyor ama yalnız Anthropic ailesinden bir model
kullanılıyorsa; `AGENTS.md` hiçbir modele göre elenmiyor.

## Kurallar bilgi tabanında

Kuralların metni burada değil, bilgi tabanında durur. Kod yazmadan, test eklemeden ya da PR
hazırlamadan önce oku:

| Ortam | Yol |
|---|---|
| Agent Canvas kabı | `/vault/kurallar/` |
| Makinede Claude Code | `~/vault/kurallar/` |

| Dosya | Ne zaman |
|---|---|
| `kod-standartlari.md` | kod yazarken |
| `test-kurallari.md` | test yazarken |
| `pr-kurallari.md` | commit ve PR hazırlarken |
| `yazim-kurallari.md` | doküman, yorum, rapor yazarken |

Bilgi tabanı salt okunurdur. Oraya yazman gerekiyorsa yazma, raporunda belirt.

## İş bölümü

Tek bir ajan hem yazıp hem kendi işini onaylamaz. İş şu sırayla ilerler:

Kodu yazan, ne test edilmesi gerektiğini söyleyerek devreder. Test eden testi yazar,
**çalıştırır** ve çıktısını rapora koyar; kırılan testi kendisi düzeltmez, geri devreder.
Denetleyen değişikliğin tamamını okur, bulgularını engelleyici / düzeltilmeli / öneri diye
ayırır ve PR açıklamasını hazırlar.

PR açılır, **birleştirilmez**. Birleştirme kararı insanındır.

## Model seçimi

Kapı tek adrestir ve katman ada göre seçilir. Hızlı ve ucuz işler (özet, etiketleme, commit
mesajı) `haiku` ya da `sonnet`; kod üreten ve denetleyen işler `opus`.

`fable` otomasyondan çağrılmaz: açıldığında diğer üç katman kapanır, yani eş zamanlı çalışan
başka bir ajanın modelini altından çeker. O katman insanın bilerek seçtiği bir yerdir.
