# Şirket mimarisi

Bu belge, spark-stack'in tek geliştiricinin asistanı olmaktan çıkıp bir yazılım şirketinin
işlerini yürüten ajan altyapısına dönüşürken izlenecek tasarımı anlatır. Kurulumun nasıl
yapıldığı [SETUP.md](../SETUP.md) içinde; burada **neyin neden öyle kurulduğu** var.

Çıkış noktası şu: amaç "bana kod yaz" demek değil. Amaç, şirketin tekrar eden işlerini
ajanlara devretmek. Bir ajan PR inceler, biri görev kartını alıp dalda çalışır, biri depoyu
izler, biri ekibin sorularını cevaplar. Hepsi aynı yerel model havuzundan beslenir ve hepsi
aynı kapıdan geçer.

---

## Dört katman

![Şirket mimarisi](figures/spark-sirket-mimarisi.png)

**Giriş noktaları.** İş nereden geliyor: geliştiricinin terminali, görev panosu, depoya
düşen PR, mesaj kanalı, ya da zamanlayıcı. Mimarinin tamamı bu beş kapıdan birinden başlar.

**Ajan çalışma zamanları.** İş nerede koşuyor. Üç ayrı kap, üç ayrı yetki seviyesi:
geliştiricinin yanında çalışan Claude Code host'ta, otomasyonlar Agent Canvas'ın tek
kullanımlık Docker kabında, dışarıya açık işler NemoClaw'ın ağ politikalı OpenShell kabında.

**Kapı.** Kim, neyi, ne kadar. Bütün model trafiği LiteLLM'den geçer; ajan başına anahtar,
anahtar başına bütçe ve model izni buradadır.

**Model havuzu.** llama-swap'in yönettiği dört katman ve 128 GB birleşik bellek. Bu katman
mimarinin tavanıdır: aşağıda anlatılan her şey bu belleğin sınırına çarpar.

---

## Ajan rolleri

![Ajan rolleri](figures/spark-ajan-rolleri.png)

Tablodaki katman seçimleri öneridir, kural değil. Mantık şu: bir işin ajan döngüsü ne kadar
uzunsa model o kadar hızlı olmalı. Depo gözcüsü günde yüzlerce kez çalışır, haiku ile
çalışır; PR incelemesi bağlam ister ama hız da ister, sonnet'e oturur; kod üreten işler
opus'a gider. fable bu tabloda bilerek yalnız bir satırda: aşağıdaki nedenle.

---

## Yönetişim: kim, neyi, ne kadar

Tek bir `master_key` ile çalışan bir kapı, tek geliştirici için yeterlidir; beş ajan için
değildir. Şirket kurulumunda kapının bir veritabanı olmalı ve her ajan kendi anahtarıyla
bağlanmalı. Bunun üç karşılığı var:

**Kimlik.** Kapı logunda "sk-spark 4.2M token harcadı" değil, "PR inceleme ajanı 4.2M token
harcadı" yazar. Bir ajan çığırından çıktığında hangisi olduğunu görürsün.

**Bütçe.** Her anahtara bir tavan konur. Döngüye giren bir otomasyon, makineyi bütün gün
meşgul etmek yerine bütçesi bitince durur.

**Model izni.** Bu en önemlisi ve doğrudan donanımla ilgili: **otomasyon anahtarlarına
fable verilmez.** Nedeni şu — llama-swap'in grup kuralında fable dışlayıcıdır, açıldığında
haiku, sonnet ve opus düşer. Tek geliştirici için bu sadece bir bekleme; eş zamanlı çalışan
beş ajan için, birinin fable istemesi diğer dördünün modelini altından çeker. Bu yüzden
fable insan tarafından bilerek seçilen bir katman olarak kalmalı, bir otomasyonun
erişebileceği yerde durmamalı.

Pratikte: `SWAP_TTL_FABLE` kısa tutulur, fable yalnız geliştiricinin anahtarında açık olur.

---

## Yalıtım: bir ajan yanlış yaptığında ne olur

Üç çalışma zamanının üç ayrı hasar yarıçapı var ve bu bilinçli bir seçimdir.

Claude Code host'ta çalışır, geliştiricinin dosyalarına doğrudan erişir. Bu bir kusur değil,
eşli programlamanın gereği — ama yanında insan olduğu için kabul edilebilir.

Agent Canvas insansız işler içindir ve burada iki ayrı yalıtım seviyesi var, karıştırmamak
gerekiyor. Konteyner olarak kurduğumuzda ajan zaten Canvas kabının içinde koşar; makinenin
dosya sistemine erişemez, yalnızca kaba bağladığımız proje klasörünü görür. `rm -rf` yaparsa
kabı ve o klasörü vurur, makineyi değil. Bunun üstünde bir de **konuşma başına ayrı kap**
seçeneği var (`OH_CONVERSATION_RUNTIME=docker`); varsayılan olarak kapalıdır ve açmak için
Canvas'a docker soketini vermek gerekir. Biz kapalı bırakıyoruz: kap sınırı zaten var,
soketi vermek yalıtımı güçlendirmek yerine zayıflatırdı.

Agent Canvas'ı `npm install -g` ile doğrudan makineye kurmak ise bambaşka bir şeydir; kendi
belgelerinde "the agent will have full access to your filesystem!" uyarısı var. Biz o yolu
kullanmıyoruz.

NemoClaw dışarıya açık işler içindir: mesaj kanalından gelen isteği, ağ politikası olan bir
kapta karşılar. Dışarıdan gelen metne güvenmemek gereken tek yer burasıdır.

---

## Kim neyi görüyor

Parçalar birbirine bağlanırken asıl soru "hangi ajan neye erişebiliyor" olur. Tablo bugünkü
gerçeği gösterir; boş hücre eksiklik değil, bilinçli sınırdır.

| Ajan | Nerede koşar | Modele nasıl bağlanır | Dosya erişimi | Bilgi tabanı | MCP sunucuları |
|---|---|---|---|---|---|
| Claude Code | host | `ANTHROPIC_BASE_URL` → :4000 | senin bütün home'un | vault, okuma-yazma | yedisi de var |
| Agent Canvas yerleşik ajanı | canvas kabı | `litellm_proxy/...` → `litellm:4000` | yalnız `/projects` | `/vault`, salt okunur | yok |
| Claude Code (Canvas içinde, ACP) | canvas kabı | `ANTHROPIC_BASE_URL` → `litellm:4000` | yalnız `/projects` | `/vault`, salt okunur | yok |
| NemoClaw ajanı | OpenShell kabı | `inference.local` → :4000 | kabın kendi alanı | yok | yok |

Üç şeyi açıklamak gerekiyor.

**Vault neden salt okunur.** Bilgi tabanı ortak bir varlık: kararlar, tasarım notları,
kaynaklar. Bir otomasyonun yanlışlıkla silebileceği yerde durmamalı. Ajanlar notlara
bakabilir, arayabilir, alıntılayabilir; yazma işi insanın onayladığı `wiki` akışında kalır
(claude-obsidian zaten iki aşamalı onay istiyor: önce plan, sonra planın sha256'sıyla uygula).

**Kaplarda neden MCP yok.** Kurduğumuz yedi MCP sunucusunun hepsi `docker run` ile çalışıyor.
Canvas kabının içinde docker yok, olması da istenmez. Ama orada ajanın zaten yerleşik dosya ve
kabuk araçları var ve bunlar kabın sınırında duruyor — yani MCP'nin sağladığı erişimi, daha dar
bir yetkiyle, kabın kendisi veriyor. Eksik olan tek şey `context7` ve `playwright` gibi dış
servisler; onlara ihtiyaç duyan işi host'taki Claude Code'a bırakmak doğru olur.

**NemoClaw kabı vault'u görmüyor.** Bu bir eksiklik ve bilinçli: NemoClaw dışarıdan gelen
isteği karşılayan kap, yani en az güvenilen giriş noktası. Gerekirse `nemoclaw onboard` komutunun
`--host-mount <host-yolu:/kap-yolu>` seçeneği salt okunur bağlama yapıyor; ama varsayılanda
kapalı bırakıldı.

---

## Portlar tek makinede nasıl paylaşılıyor

Hepsi `127.0.0.1`'e bağlı. İki tanesi bilerek kaydırıldı: Agent Canvas kendi içinde 8000
dinliyor ama o portu `sonnet` tuttuğu için dışarı 8300'den açılıyor, llama-swap da 8081'e
alındı çünkü 8080 NemoClaw'ın OpenShell gateway'inin varsayılanı. Tam liste
[README'nin Portlar bölümünde](../README.md#portlar).

---

## Tek makinenin gerçeği

Bu mimarinin en dürüst kısmı: **ajan sayısını artırmak iş gücünü artırmaz.** Dört katman da
aynı 128 GB'yi paylaşır. İki ajan aynı anda opus isterse ikisi de aynı vLLM örneğine düşer
ve sıraya girer; işler paralelleşmez, kuyruk uzar.

Buradan çıkan üç kural:

Otomasyonları haiku ve sonnet'e yasla. Ucuz ve hızlı katmanlar aynı anda açık durabildiği
için, eş zamanlı iki otomasyon birbirini beklemez.

Soğuk başlatmayı iş akışının içine koyma. Bir katman kapalıysa ilk istek 3-4 dakika bekler.
Zamanlayıcıyla çalışan bir otomasyon bunu her seferinde ödemesin diye, o katmanın
`SWAP_TTL` değeri otomasyonun periyodundan uzun olmalı.

Gerçekten paralel iş gerekiyorsa çözüm ikinci bir Spark'tır, daha fazla ajan değil. Kapı
zaten birden çok arka ucu tek adres altında toplayabilir; mimaride değişecek tek şey model
havuzunun makine sayısıdır.

---

## İleride: görsel ve video modelleri

Medya üretimi mimaride yeri ayrılmış ama bugün kurulu olmayan bir katmandır. İki şeyi
şimdiden bilerek tasarlıyoruz.

Birincisi, aynı belleği paylaşacak. Bir video modeli açıldığında metin katmanlarının
düşmesi gerekecek; bu llama-swap'in grup kuralına yeni bir dışlayıcı grup eklemek demek,
mimari değişikliği değil.

İkincisi, kapıdan geçecek. Görsel üretimi sohbet tamamlama değildir, ama LiteLLM'in kendi
görsel uçları var; ajanların medya isteklerini de aynı anahtar ve bütçe defterinden geçirmek,
ayrı bir kapı açmaktan iyidir.

---

## Bugün ne var, ne yok

| Parça | Durum |
|---|---|
| Dört katman + kapı + llama-swap | Kurulu |
| Claude Code (host) | Kurulu |
| NemoClaw kabı | Kurulu — `--with-nemoclaw` |
| Obsidian bilgi tabanı | Kurulu — `--with-wiki` |
| Agent Canvas + otomasyonlar | Bu belgeyle tasarlandı, kurulum eklenecek |
| Kapı veritabanı + ajan başına anahtar | Tasarlandı, henüz kurulu değil |
| Medya havuzu | Mimaride yer ayrıldı, bugün yok |

---

## Canvas → Claude Code → yerel model

Agent Canvas, Claude Code'u ACP üzerinden kendi içinde alt ajan olarak çalıştırabiliyor;
belgeli ve yayınlanmış bir özellik, sarmalayıcı imajın içinde hazır geliyor. Üst katmanda
Canvas konuşmayı, otomasyonu ve kabı yönetir; Claude Code kendi araç, bağlam ve model
işini yapmaya devam eder. Zincirin son halkası bizim kurduğumuz kısım:

```
Agent Canvas  →  Claude Code (ACP alt ajanı)  →  LiteLLM :4000  →  yerel katman
```

Bunu `ANTHROPIC_BASE_URL=http://litellm:4000` ve `ANTHROPIC_API_KEY` ile kuruyoruz; ikisi de
compose'da Canvas kabına veriliyor. Kapımız Anthropic uyumlu `/v1/messages` ucunu zaten
sunduğu için Claude Code'un kendi protokolü bozulmadan yerel modele iner. Gelen model adı
`claude-sonnet-4-5` gibi bir şey olsa bile `litellm.yaml` içindeki `claude-*` kuralı onu ana
katmana düşürür.

**Abonelik token'ı verilmez.** OpenHands belgelerinde açık uyarı var: `ANTHROPIC_BASE_URL`
ile `CLAUDE_CODE_OAUTH_TOKEN` birlikte kullanıldığında token'ın kimlik doğrulaması sessizce
bozuluyor, çünkü bearer başka bir uca yönleniyor. Kaynak kodda da bu ikisi çakışan çift
olarak işaretli. Yani ya abonelik ya yerel kapı; bu kurulumda tercih yerel kapıdır ve
`CLAUDE_CODE_OAUTH_TOKEN` bilerek boş bırakılır.

Bilinen pürüzler, bugünkü hâliyle: ACP üzerinden çalışan Claude Code, Canvas'ın yerleşik
skill'lerini göremiyor; ACP konuşmaları için duraklat/iptal yok; aynı sağlayıcıyla eş
zamanlı iki konuşma kap içinde aynı HOME'u paylaşıp yarışabiliyor. Üçü de üst akışta açık
kayıt. Tek ajanla çalışırken sorun çıkarmıyor.
