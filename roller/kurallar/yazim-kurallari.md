# Yazım kuralları

Doküman, README, kod yorumu, PR açıklaması ve ajan raporu bu kurallara uyar.

## Ton

Akan cümlelerle yaz. Madde imi, ancak gerçekten liste olan şey için kullanılır; üç
paragrafı üç maddeye bölmek liste yapmaz, paragrafı sakatlar.

Tek cümlelik bilgi tek cümleyle verilir. "Şunu belirtmek gerekir ki" diye başlayan cümle
kısaltılır.

Okuyucuya ne yapacağını söyle, ne düşüneceğini değil. "Bu çok önemli" yerine neden önemli
olduğunu yaz.

## Biçim

Uzun tire (—) ve parantez içi araya girmeler kullanılmaz; cümleyi böl ya da bağlaçla bağla.

Başlıklar betimleyicidir, soru ya da slogan değil: "Bellek yönetimi", "Bellek nasıl yönetilir?"
değil.

Sayı verirken kaynağını bil. Ölçülmemiş bir sayı yazılmaz; tahminse tahmin olduğu söylenir.

## Türkçe

Teknik terimin yerleşik Türkçesi varsa o kullanılır: kap (container), kapı (gateway),
katman (tier), bilgi tabanı (knowledge base). Yerleşmemişse İngilizcesi olduğu gibi yazılır,
uydurma karşılık üretilmez.

Komut, dosya yolu, değişken adı ve kod her zaman İngilizce ve olduğu gibi yazılır.

## Ajan raporu

İş bittiğinde ne yapıldığı, neyin doğrulandığı ve neyin doğrulanmadığı ayrı ayrı söylenir.
Doğrulanmamış bir şey "tamam" diye raporlanmaz.

Bir iş yarım kaldıysa nerede kaldığı ve devam etmek için gereken komut yazılır.

## Mekanik denetim

| Kural | Nasıl denetlenir | Kim |
|---|---|---|
| Uzun tire yok | eklenen satırlarda U+2014 taranır: belge, kod yorumu, kabuk | kapı |
| Başlık soru değil | `?` ile biten `.md` başlığı durur | kapı |
| Ton, madde imi, sayı kaynağı, Türkçe terim, ajan raporu | okunarak | spark-denetci |
