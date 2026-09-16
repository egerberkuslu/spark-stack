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

Agent Canvas'ın Docker çalışma zamanı, insansız işler içindir. Ajan konuşma başına
ayrı bir kapta çalışır; `rm -rf` yaparsa kabı siler, makineyi değil. **Ama bu davranış
varsayılan değildir, açıkça açılması gerekir** (`OH_EXECUTION_RUNTIME=docker`). Varsayılan
kurulumda ajan doğrudan makinede koşar. Otomasyon kuracaksan bu ayarı atlamamak lazım.

NemoClaw dışarıya açık işler içindir: mesaj kanalından gelen isteği, ağ politikası olan bir
kapta karşılar. Dışarıdan gelen metne güvenmemek gereken tek yer burasıdır.

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

## Agent Canvas hakkında iki not

Agent Canvas (OpenHands deposunun bugünkü hali) ACP üzerinden Claude Code'u kendi içinde
alt ajan olarak çalıştırabiliyor; belgeli ve yayınlanmış bir özellik. Bu bize şunu verir:
OpenHands üst katmanda konuşmayı, otomasyonu ve kabı yönetir, Claude Code kendi araç ve
bağlam işini yapmaya devam eder.

Ama bu zincirin son halkası, yani **Claude Code'un yerel modelimize bağlanması, OpenHands
tarafından belgelenmiş bir yol değil.** Kendi kurduğumuz `ANTHROPIC_BASE_URL` + API anahtarı
bağlantısı olur. Belgelerde açık bir uyarı da var: bu base URL'i Claude aboneliğinin OAuth
token'ıyla birlikte kullanmak, token'ın kimlik doğrulamasını sessizce bozuyor. Yani ya
abonelik ya yerel kapı; ikisi bir arada değil.
