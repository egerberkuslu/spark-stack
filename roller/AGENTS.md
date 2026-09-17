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


## Bilgi tabanında araştır

Şirketin hafızası `__VAULT__` altında ve salt okunur bağlı. Geçmiş bir karar, tasarım notu ya da
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
yok" de, varmış gibi konuşma.

## İş bölümü

Tek bir ajan hem yazıp hem kendi işini onaylamaz. İş şu sırayla ilerler:

Kodu yazan, ne test edilmesi gerektiğini söyleyerek devreder. Test eden testi yazar,
**çalıştırır** ve çıktısını rapora koyar; kırılan testi kendisi düzeltmez, geri devreder.
Denetleyen değişikliğin tamamını okur, bulgularını engelleyici / düzeltilmeli / öneri diye
ayırır ve PR açıklamasını hazırlar.

PR açılır, **birleştirilmez**. Birleştirme kararı insanındır.

Kurallar yalnız okunmaz, mekanik olarak da zorlanır: commit, itme ve PR bir kural kapısından
geçer (`kurallar/*.md` dosyalarının "Mekanik denetim" bölümü). Kapı kapalıysa iş bitmiş
sayılmaz; `spark kural pr` çıktısı rapora girer.

## Model seçimi

Kapı tek adrestir ve katman ada göre seçilir. Hızlı ve ucuz işler (özet, etiketleme, commit
mesajı) `haiku` ya da `sonnet`; kod üreten ve denetleyen işler `opus`.

`fable` otomasyondan çağrılmaz: açıldığında diğer üç katman kapanır, yani eş zamanlı çalışan
başka bir ajanın modelini altından çeker. O katman insanın bilerek seçtiği bir yerdir.
