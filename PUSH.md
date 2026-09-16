# GitHub'a yükleme

Bu dosya yalnızca ilk yükleme içindir; sonrasında silinebilir.

```bash
cd spark-stack

git init -b main
git add -A
git commit -m "spark-stack: DGX Spark üzerinde yerel kod asistanı"

git remote add origin https://github.com/egerberkuslu/spark-stack.git
git push -u origin main
```

Depo GitHub'da henüz oluşturulmadıysa önce oluştur (README/lisans ekleme seçeneklerini
işaretleme — bu depoda zaten var), sonra yukarıdaki komutları çalıştır.

`gh` CLI kuruluysa tek adımda:

```bash
gh repo create egerberkuslu/spark-stack --public --source=. --push \
  --description "NVIDIA DGX Spark üzerinde tamamen yerel kod asistanı: dört model katmanı, vLLM + LiteLLM, Claude Code"
```

## Depo ayarları

- **Description:** NVIDIA DGX Spark üzerinde tamamen yerel kod asistanı: dört model katmanı, vLLM + LiteLLM, Claude Code
- **Topics:** `dgx-spark`, `gb10`, `vllm`, `litellm`, `claude-code`, `local-llm`, `nvfp4`, `qwen`, `self-hosted`, `mcp`, `agent-skills`, `obsidian`

## Yüklenmeyecekler

`.gitignore` şunları dışarıda tutar: `.env` (HuggingFace anahtarın burada), `*.bak`, `install.log`, `dist/`.

Yüklemeden önce doğrula:

```bash
git status --short
grep -r "hf_" . --exclude-dir=.git || echo "anahtar sızıntısı yok"
```
