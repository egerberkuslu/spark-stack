#!/usr/bin/env python3
"""Kural kapısı: kurallar/*.md dosyalarının mekanik karşılığı.

Kural metni bilgi tabanında durur; bu betik o metnin ölçülebilir kısmını
git kancası, PR kapısı ve CI olarak zorlar. Her bulgu hangi kural dosyasının
hangi bölümüne dayandığını söyler; gerekçesiz bulgu yazılmaz (pr-kurallari.md).

Ölçülemeyen kurallar (kısaltma kullanma, commit "neden" anlatır, ton) burada
değil, spark-denetci rolünde kalır. Hangi kuralın nerede denetlendiği her kural
dosyasının sonundaki "Mekanik denetim" tablosunda yazar.

Kipler:
  commit-msg <dosya>   commit-msg kancası: mesaj biçimi
  commit               pre-commit kancası: dal, .env, sır, değişen dosyalar
  push                 pre-push kancası: zorla itme (amend/rebase) tespiti
  pr [--base DAL]      tam kapı: dal farkı + testler + PR açıklaması
  dosya <yol>...       verilen dosyaları denetle

Ortam:
  SPARK_KURALLAR       kurallar dizini (varsayılan ~/vault/kurallar ya da /vault/kurallar)
  SPARK_DENETIM_BIN    ruff/shellcheck ikili dizini
  KURAL_KAPISI_ATLA=1  kancayı bir kerelik atla; atlama kayda geçer
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

# ── Bulgu → kural bölümü eşlemesi ─────────────────────────────────────────
RULE_SECTIONS: dict[str, tuple[str, str]] = {
    "error": ("kod-standartlari.md", "Hata yönetimi"),
    "boundary": ("kod-standartlari.md", "Sınırlar"),
    "structure": ("kod-standartlari.md", "Yapı"),
    "python": ("kod-standartlari.md", "Python"),
    "naming": ("kod-standartlari.md", "Dil ve isimlendirme"),
    "what-to-test": ("test-kurallari.md", "Ne test edilir"),
    "not-to-test": ("test-kurallari.md", "Ne test edilmez"),
    "test-form": ("test-kurallari.md", "Biçim"),
    "passing": ("test-kurallari.md", "Geçme ölçütü"),
    "commit": ("pr-kurallari.md", "Commit"),
    "branch": ("pr-kurallari.md", "Dal"),
    "pr-body": ("pr-kurallari.md", "PR açıklaması"),
    "writing": ("yazim-kurallari.md", "Biçim"),
}

# ruff kodu → kural anahtarı. Ön ek eşlemesi RUFF_PREFIXES ile tamamlanır.
RUFF_CODES: dict[str, str] = {
    "E722": "error",
    "B904": "error",
    "BLE001": "error",
    "S110": "error",
    "S105": "boundary",
    "S106": "boundary",
    "S107": "boundary",
    "PLR0915": "structure",
    "PLR1702": "structure",
    "C901": "structure",
    "E741": "naming",
}
RUFF_PREFIXES: tuple[tuple[str, str], ...] = (
    ("ANN", "python"),
    ("I", "python"),
    ("N", "naming"),
)

SECRET_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("AWS anahtarı", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("API anahtarı", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}")),
    ("GitHub belirteci", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}")),
    ("HuggingFace belirteci", re.compile(r"\bhf_[A-Za-z0-9]{30,}")),
    ("özel anahtar", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("düz parola", re.compile(r"(?i)\bpassword\s*[=:]\s*['\"][^'\"]{4,}['\"]")),
)
REAL_IO_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("gerçek saat", re.compile(r"\b(datetime\.(now|utcnow)|time\.time)\s*\(")),
    (
        "gerçek ağ",
        re.compile(r"\b(requests|httpx)\.(get|post|put|delete|request)\s*\("),
    ),
    ("gerçek ağ", re.compile(r"\burllib\.request\.urlopen\s*\(")),
    ("gerçek ağ", re.compile(r"\bsocket\.(create_connection|socket)\s*\(")),
)
MOCK_HINT = re.compile(
    r"\b(mock|monkeypatch|responses|respx|freezegun|time_machine|aioresponses)\b"
)
BRANCH_PATTERN = re.compile(r"^[a-z][a-z0-9-]*/[a-z0-9][a-z0-9._-]*$")
TEXT_SUFFIXES = {".md", ".py", ".sh", ".txt", ".rst", ".yml", ".yaml", ".toml"}
PR_HEADINGS = ("ne değişti", "neden", "nasıl test edildi")


@dataclass
class Finding:
    key: str
    message: str
    location: str = ""
    source: str = ""
    warning: bool = False

    def rule(self) -> tuple[str, str]:
        return RULE_SECTIONS[self.key]


@dataclass
class Context:
    repo: Path
    rules_dir: Path | None
    light: bool
    findings: list[Finding] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def add(
        self,
        key: str,
        message: str,
        location: str = "",
        source: str = "",
        warning: bool = False,
    ) -> None:
        self.findings.append(Finding(key, message, location, source, warning))

    def blocking(self) -> list[Finding]:
        return [f for f in self.findings if not f.warning]


# ── yardımcılar ───────────────────────────────────────────────────────────
def run(
    cmd: list[str], cwd: Path | None = None, stdin: str | None = None
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd, cwd=cwd, input=stdin, capture_output=True, text=True, check=False
    )


def git(repo: Path, *args: str) -> str:
    result = run(["git", *args], cwd=repo)
    return result.stdout.strip()


def repo_root() -> Path:
    result = run(["git", "rev-parse", "--show-toplevel"])
    if result.returncode != 0:
        print(
            "git deposu değil: kural kapısı yalnız bir depo içinde çalışır",
            file=sys.stderr,
        )
        sys.exit(2)
    return Path(result.stdout.strip())


def ai_root() -> Path:
    return Path(os.environ.get("AI_ROOT", "/srv/ai"))


def tool(name: str) -> str | None:
    candidates = [
        os.environ.get("SPARK_DENETIM_BIN"),
        str(ai_root() / "denetim/.venv/bin"),
        str(ai_root() / "denetim/bin"),
        "/opt/spark-denetim/.venv/bin",
        "/opt/spark-denetim/bin",
    ]
    for directory in candidates:
        if directory and (Path(directory) / name).exists():
            return str(Path(directory) / name)
    return shutil.which(name)


def find_rules_dir(explicit: str | None, repo: Path) -> Path | None:
    candidates = [
        explicit,
        os.environ.get("SPARK_KURALLAR"),
        str(Path.home() / "vault/kurallar"),
        "/vault/kurallar",
        str(repo / ".kural"),
    ]
    for candidate in candidates:
        if candidate and (Path(candidate) / "kod-standartlari.md").exists():
            return Path(candidate)
    return None


def rules_digest(rules_dir: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(rules_dir.rglob("*")):
        if path.is_file() and path.suffix in {".md", ".toml"}:
            digest.update(path.relative_to(rules_dir).as_posix().encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()[:12]


def is_test_file(path: Path) -> bool:
    name = path.name
    return (
        name.startswith("test_") or name.endswith("_test.py") or "tests" in path.parts
    )


def is_shell(path: Path) -> bool:
    if path.suffix == ".sh":
        return True
    try:
        with path.open("rb") as handle:
            head = handle.read(64)
    except OSError:
        return False
    return head.startswith(b"#!") and b"sh" in head.split(b"\n", 1)[0]


# ── commit mesajı ─────────────────────────────────────────────────────────
def check_subject(ctx: Context, subject: str, where: str) -> None:
    if not subject.strip():
        ctx.add("commit", "commit mesajı boş", where)
        return
    if subject.startswith(("Merge ", "Revert ")):
        return  # git'in kendi ürettiği mesajlar
    if len(subject) > 60:
        ctx.add("commit", f"ilk satır {len(subject)} karakter, sınır 60", where)
    if not re.match(r"^[a-zçğıöşü]", subject):
        ctx.add("commit", "ilk satır küçük harfle başlamalı", where, subject)
    if subject.rstrip().endswith("."):
        ctx.add("commit", "ilk satırın sonuna nokta konmaz", where, subject)


def mode_commit_msg(ctx: Context, path: Path) -> None:
    lines = [
        line
        for line in path.read_text(encoding="utf-8").splitlines()
        if not line.startswith("#")
    ]
    subject = lines[0] if lines else ""
    check_subject(ctx, subject, "commit mesajı")


# ── dal ve itme ───────────────────────────────────────────────────────────
def check_branch(ctx: Context) -> None:
    branch = git(ctx.repo, "rev-parse", "--abbrev-ref", "HEAD")
    if branch == "HEAD":
        return  # ayrık HEAD: CI ya da rebase; dal adı yok
    if branch in ("main", "master"):
        ctx.add(
            "branch",
            f"'{branch}' üzerinde çalışılmaz; dal aç: git switch -c fix/<iş>",
            "dal",
        )
    elif not BRANCH_PATTERN.match(branch):
        ctx.add(
            "branch",
            f"dal adı işi anlatmıyor: '{branch}' (örnek: fix/token-yenileme)",
            "dal",
        )


def mode_push(ctx: Context, stdin_text: str) -> None:
    zero = "0" * 40
    for line in stdin_text.splitlines():
        parts = line.split()
        if len(parts) != 4:
            continue
        _local_ref, local_sha, remote_ref, remote_sha = parts
        if remote_sha == zero or local_sha == zero:
            continue  # yeni dal ya da silme
        ancestor = run(
            ["git", "merge-base", "--is-ancestor", remote_sha, local_sha], cwd=ctx.repo
        )
        if ancestor.returncode != 0:
            ctx.add(
                "branch",
                f"gönderilmiş commit yeniden yazılmış (amend/rebase): {remote_ref}",
                "itme",
            )


# ── değişen satırlar: sır, .env, uzun tire ────────────────────────────────
def added_lines(ctx: Context, diff_args: list[str]) -> dict[str, list[tuple[int, str]]]:
    """git diff çıktısından eklenen satırları dosya → [(satır, metin)] olarak döndürür."""
    output = git(ctx.repo, "diff", "-U0", "--no-color", *diff_args)
    result: dict[str, list[tuple[int, str]]] = {}
    current, line_no = "", 0
    for line in output.splitlines():
        if line.startswith("+++ "):
            current = line[4:].removeprefix("b/")
            result.setdefault(current, [])
        elif line.startswith("@@"):
            match = re.search(r"\+(\d+)", line)
            line_no = int(match.group(1)) if match else 0
        elif line.startswith("+") and not line.startswith("+++"):
            result.setdefault(current, []).append((line_no, line[1:]))
            line_no += 1
    return result


def check_added_lines(ctx: Context, added: dict[str, list[tuple[int, str]]]) -> None:
    for file_name, lines in added.items():
        path = Path(file_name)
        base = path.name
        if base == ".env" or (base.startswith(".env.") and base != ".env.example"):
            ctx.add(
                "boundary",
                f"{base} depoya girmez; sır ortam değişkeninde durur",
                file_name,
            )
            continue
        textual = path.suffix in TEXT_SUFFIXES or is_shell(ctx.repo / path)
        for line_no, text in lines:
            for label, pattern in SECRET_PATTERNS:
                if pattern.search(text):
                    ctx.add(
                        "boundary",
                        f"kodda sır görünüyor ({label})",
                        f"{file_name}:{line_no}",
                    )
            # Kural belge ve kod yorumunu kapsar: .md/.txt/.rst tümüyle, kodda yalnız yorum satırı
            is_doc = path.suffix in {".md", ".txt", ".rst"}
            is_comment = textual and text.lstrip().startswith("#")
            if (
                (is_doc or is_comment)
                and "\u2014" in text
                and "kurallar" not in path.parts
            ):
                ctx.add(
                    "writing",
                    "uzun tire (U+2014) kullanılmaz; cümleyi böl ya da bağlaçla bağla",
                    f"{file_name}:{line_no}",
                )
            if path.suffix == ".md" and re.match(r"^#{1,6}\s.*\?\s*$", text):
                ctx.add(
                    "writing",
                    "başlık soru olmaz, betimleyici olur",
                    f"{file_name}:{line_no}",
                    text.strip(),
                )


# ── Python: ruff ──────────────────────────────────────────────────────────
def ruff_key(code: str) -> str | None:
    if code in RUFF_CODES:
        return RUFF_CODES[code]
    for prefix, key in RUFF_PREFIXES:
        if code.startswith(prefix):
            return key
    return None


def check_ruff(ctx: Context, py_files: list[Path]) -> None:
    if not py_files:
        return
    ruff = tool("ruff")
    if not ruff:
        message = "ruff bulunamadı; Python denetimi yapılamadı"
        ctx.add("python", message, "araç", warning=ctx.light)
        return
    config: list[str] = []
    if ctx.rules_dir and (ctx.rules_dir / "denetim/ruff.toml").exists():
        config = ["--config", str(ctx.rules_dir / "denetim/ruff.toml")]
    files = [str(p) for p in py_files]
    lint = run(
        [
            ruff,
            "check",
            "--no-cache",
            "--output-format",
            "json",
            "--exit-zero",
            *config,
            *files,
        ],
        cwd=ctx.repo,
    )
    if lint.returncode not in (0, 1):
        ctx.add("python", f"ruff çalışmadı: {lint.stderr.strip()[:200]}", "araç")
        return
    try:
        items = json.loads(lint.stdout or "[]")
    except json.JSONDecodeError:
        ctx.add(
            "python", f"ruff çıktısı okunamadı: {lint.stderr.strip()[:200]}", "araç"
        )
        items = []
    for item in items:
        key = ruff_key(item.get("code", ""))
        if key is None:
            continue
        name = Path(item["filename"])
        shown = (
            name.relative_to(ctx.repo).as_posix() if name.is_absolute() else str(name)
        )
        ctx.add(
            key,
            item.get("message", ""),
            f"{shown}:{item['location']['row']}",
            item.get("code", ""),
        )
    check_ruff_format(ctx, ruff, config, files)


def check_ruff_format(
    ctx: Context, ruff: str, config: list[str], files: list[str]
) -> None:
    # ruff sürümüne göre iki çıktı biçimi var: "Would reformat: yol" ya da diff başlığı "--> yol:1:1"
    fmt = run([ruff, "format", "--check", "--no-cache", *config, *files], cwd=ctx.repo)
    unformatted: list[str] = []
    for line in fmt.stdout.splitlines() + fmt.stderr.splitlines():
        if line.startswith("Would reformat: "):
            unformatted.append(line.split(": ", 1)[1])
        match = re.match(r"^\s*-->\s+(.+?):\d+:\d+\s*$", line)
        if match:
            unformatted.append(match.group(1))
    if fmt.returncode == 1 and not unformatted:
        unformatted = ["(dosya adı okunamadı)"]
    for name in dict.fromkeys(unformatted):
        ctx.add(
            "python",
            "biçim black standardında değil; ruff format ya da black çalıştır",
            name,
            "format",
        )


# ── Python: test dosyaları ────────────────────────────────────────────────
def assert_count(node: ast.AST) -> int:
    count = 0
    for child in ast.walk(node):
        if isinstance(child, ast.Assert):
            count += 1
        elif isinstance(child, ast.Call) and isinstance(child.func, ast.Attribute):
            if child.func.attr.startswith("assert"):
                count += 1
    return count


def skip_without_reason(decorator: ast.expr) -> bool:
    target = decorator.func if isinstance(decorator, ast.Call) else decorator
    name = ast.unparse(target)
    if not name.endswith((
        "mark.skip",
        "mark.skipif",
        "unittest.skip",
        "unittest.skipIf",
    )):
        return False
    if isinstance(decorator, ast.Call):
        if any(keyword.arg == "reason" for keyword in decorator.keywords):
            return False
        if name.endswith("unittest.skip") and decorator.args:
            return False
    return True


def check_test_file(ctx: Context, path: Path) -> None:
    rel = path.relative_to(ctx.repo).as_posix()
    text = path.read_text(encoding="utf-8")
    try:
        tree = ast.parse(text)
    except SyntaxError as exc:
        ctx.add(
            "test-form",
            f"test dosyası ayrıştırılamadı: {exc.msg}",
            f"{rel}:{exc.lineno}",
        )
        return
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        where = f"{rel}:{node.lineno}"
        if node.name.startswith("test_"):
            words = node.name.split("_")
            if (
                re.fullmatch(r"test_\d+", node.name)
                or node.name.startswith("test_case_")
                or len(words) < 3
            ):
                ctx.add(
                    "test-form", f"test adı ne yaptığını söylemiyor: {node.name}", where
                )
            asserts = assert_count(node)
            if asserts >= 3:
                ctx.add(
                    "test-form",
                    f"{node.name} {asserts} iddia içeriyor; bir test tek şey doğrular",
                    where,
                )
        for decorator in node.decorator_list:
            if skip_without_reason(decorator):
                ctx.add(
                    "passing",
                    f"atlanan test gerekçesiz: {node.name} (reason= yaz)",
                    where,
                )
    mocked = bool(MOCK_HINT.search(text))
    for line_no, line in enumerate(text.splitlines(), 1):
        for label, pattern in REAL_IO_PATTERNS:
            if pattern.search(line):
                ctx.add(
                    "not-to-test",
                    f"testte {label} kullanılıyor; enjekte et ya da taklit et",
                    f"{rel}:{line_no}",
                    warning=mocked,
                )


def check_test_presence(ctx: Context, path: Path, status: str) -> None:
    if path.name in ("__init__.py", "conftest.py", "setup.py") or path.suffix != ".py":
        return
    stem = path.stem
    matches = list(ctx.repo.glob(f"**/test_{stem}.py")) + list(
        ctx.repo.glob(f"**/{stem}_test.py")
    )
    if matches:
        return
    rel = path.relative_to(ctx.repo).as_posix()
    if status == "A":
        ctx.add(
            "what-to-test", f"yeni modülün testi yok: test_{stem}.py bekleniyor", rel
        )
    else:
        ctx.add(
            "what-to-test",
            f"değişen modülün eşleşen test dosyası yok: test_{stem}.py",
            rel,
            warning=True,
        )


# ── kabuk ─────────────────────────────────────────────────────────────────
def check_shell(ctx: Context, sh_files: list[Path]) -> None:
    if not sh_files:
        return
    shellcheck = tool("shellcheck")
    if not shellcheck:
        ctx.add(
            "structure",
            "shellcheck bulunamadı; kabuk denetimi yapılamadı",
            "araç",
            warning=ctx.light,
        )
        return
    # Varsayılan "warning": gerçek hatalar. Tırnak/stil için KURAL_KAPISI_SHELLCHECK=info
    severity = os.environ.get("KURAL_KAPISI_SHELLCHECK", "warning")
    result = run(
        [shellcheck, "-f", "json", "-S", severity, *[str(p) for p in sh_files]],
        cwd=ctx.repo,
    )
    try:
        items = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        items = []
    for item in items:
        ctx.add(
            "structure",
            item.get("message", ""),
            f"{item.get('file')}:{item.get('line')}",
            f"SC{item.get('code')}",
        )


# ── dosya kümesi ──────────────────────────────────────────────────────────
def check_files(ctx: Context, files: dict[str, str]) -> None:
    """files: yol → git durumu (A/M/D/…). Silinen dosyalar atlanır."""
    py_files: list[Path] = []
    sh_files: list[Path] = []
    for name, status in files.items():
        path = ctx.repo / name
        if status.startswith("D") or not path.exists():
            continue
        if path.suffix == ".py":
            py_files.append(path)
            if is_test_file(path):
                check_test_file(ctx, path)
            else:
                check_test_presence(ctx, path, status)
        elif is_shell(path):
            sh_files.append(path)
    check_ruff(ctx, py_files)
    check_shell(ctx, sh_files)


def name_status(ctx: Context, *diff_args: str) -> dict[str, str]:
    output = git(ctx.repo, "diff", "--name-status", "--no-renames", *diff_args)
    files: dict[str, str] = {}
    for line in output.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            files[parts[-1]] = parts[0]
    return files


def mode_commit(ctx: Context) -> None:
    check_branch(ctx)
    files = name_status(ctx, "--cached")
    check_added_lines(ctx, added_lines(ctx, ["--cached"]))
    check_files(ctx, files)


# ── PR kapısı ─────────────────────────────────────────────────────────────
def resolve_base(ctx: Context, base: str) -> str:
    for candidate in (base, f"origin/{base}"):
        if (
            run(
                ["git", "rev-parse", "--verify", "-q", candidate], cwd=ctx.repo
            ).returncode
            == 0
        ):
            return candidate
    print(f"taban dal bulunamadı: {base}", file=sys.stderr)
    sys.exit(2)


def run_tests(ctx: Context, changed_py: bool) -> None:
    has_tests = any(ctx.repo.glob("**/test_*.py")) or any(ctx.repo.glob("**/*_test.py"))
    if not has_tests:
        if changed_py:
            ctx.add(
                "passing",
                "depoda hiç test yok; Python değişikliği testsiz birleşmez",
                "testler",
            )
        return
    venv_python = ctx.repo / ".venv/bin/python"
    if venv_python.exists():
        command = [str(venv_python), "-m", "pytest"]
    elif tool("pytest"):
        command = [str(tool("pytest"))]
    else:
        command = [sys.executable, "-m", "pytest"]
    result = run([*command, "-q", "-p", "no:cacheprovider"], cwd=ctx.repo)
    tail = "\n".join(result.stdout.strip().splitlines()[-3:])
    if result.returncode == 5:
        ctx.add("passing", "pytest test bulamadı", "testler", tail)
    elif result.returncode != 0:
        ctx.add(
            "passing",
            f"test takımı yeşil değil (çıkış {result.returncode})",
            "testler",
            tail,
        )
    else:
        ctx.notes.append(
            f"testler yeşil: {tail.splitlines()[-1] if tail else 'pytest'}"
        )


def pr_body(ctx: Context, body_file: str | None) -> str | None:
    if body_file:
        return Path(body_file).read_text(encoding="utf-8")
    if os.environ.get("PR_BODY"):
        return os.environ["PR_BODY"]
    if shutil.which("gh"):
        result = run(
            ["gh", "pr", "view", "--json", "body", "-q", ".body"], cwd=ctx.repo
        )
        if result.returncode == 0:
            return result.stdout
    return None


def check_pr_body(ctx: Context, body: str | None) -> None:
    if body is None:
        ctx.notes.append(
            "PR açıklaması bulunamadı (gh yok ya da PR açılmamış); üç başlığı elle kontrol et"
        )
        return
    lowered = body.lower()
    for heading in PR_HEADINGS:
        if heading not in lowered:
            ctx.add("pr-body", f"'{heading.capitalize()}' başlığı yok", "PR açıklaması")
    tested = lowered.split("nasıl test edildi", 1)
    if (
        len(tested) == 2
        and "```" not in tested[1]
        and not re.search(r"^\s*\$ ", tested[1], re.M)
    ):
        ctx.add(
            "pr-body",
            "'Nasıl test edildi' altında çalıştırılan komut ve çıktısı yok",
            "PR açıklaması",
        )


def mode_pr(ctx: Context, base: str, body_file: str | None) -> None:
    check_branch(ctx)
    base_ref = resolve_base(ctx, base)
    for line in git(
        ctx.repo, "log", "--format=%h %s", f"{base_ref}..HEAD"
    ).splitlines():
        sha, _, subject = line.partition(" ")
        check_subject(ctx, subject, f"commit {sha}")
    files = name_status(ctx, f"{base_ref}...HEAD")
    check_added_lines(ctx, added_lines(ctx, [f"{base_ref}...HEAD"]))
    check_files(ctx, files)
    run_tests(ctx, any(name.endswith(".py") for name in files))
    check_pr_body(ctx, pr_body(ctx, body_file))


def mode_files(ctx: Context, paths: list[str]) -> None:
    files = {str(Path(p).resolve().relative_to(ctx.repo)): "M" for p in paths}
    check_files(ctx, files)
    for name in files:
        path = ctx.repo / name
        if path.suffix in TEXT_SUFFIXES and path.exists():
            lines = list(
                enumerate(
                    path.read_text(encoding="utf-8", errors="replace").splitlines(), 1
                )
            )
            check_added_lines(ctx, {name: lines})


# ── raporlama ─────────────────────────────────────────────────────────────
def report(ctx: Context, as_json: bool) -> int:
    blocking = ctx.blocking()
    if as_json:
        print(
            json.dumps(
                {
                    "kapi": "kapali" if blocking else "acik",
                    "bulgular": [
                        {
                            "kural": f.rule()[0],
                            "bolum": f.rule()[1],
                            "yer": f.location,
                            "mesaj": f.message,
                            "kaynak": f.source,
                            "uyari": f.warning,
                        }
                        for f in ctx.findings
                    ],
                    "notlar": ctx.notes,
                },
                ensure_ascii=False,
                indent=1,
            )
        )
        return 1 if blocking else 0
    state = "KAPALI" if blocking else "AÇIK"
    print(
        f"kural kapısı: {len(blocking)} engelleyici, {len(ctx.findings) - len(blocking)} uyarı → kapı {state}"
    )
    for finding in ctx.findings:
        mark = "!" if finding.warning else "✗"
        rule_file, section = finding.rule()
        source = f"  ({finding.source})" if finding.source else ""
        print(
            f"  {mark} {rule_file} › {section:<20} {finding.location:<34} {finding.message}{source}"
        )
    for note in ctx.notes:
        print(f"  · {note}")
    if blocking:
        print(
            "  kural metni: kurallar/<dosya>.md · zorunlu atlama kayda geçer: KURAL_KAPISI_ATLA=1"
        )
    return 1 if blocking else 0


def log_bypass(repo: Path, mode: str) -> None:
    log_dir = ai_root() / "denetim"
    target = (
        log_dir / "atlama.log"
        if os.access(log_dir, os.W_OK)
        else Path.home() / ".kural-kapisi-atlama.log"
    )
    branch = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with target.open("a", encoding="utf-8") as handle:
        handle.write(
            f"{stamp}\t{os.environ.get('USER', '?')}\t{repo}\t{branch}\t{mode}\n"
        )
    print(f"kural kapısı ATLANDI ({mode}); kayıt: {target}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("mode", choices=["commit-msg", "commit", "push", "pr", "dosya"])
    parser.add_argument("args", nargs="*")
    parser.add_argument("--kurallar", help="kurallar dizini")
    parser.add_argument("--base", default="main", help="pr kipi için taban dal")
    parser.add_argument("--pr-body-file", help="pr kipi için açıklama dosyası")
    parser.add_argument(
        "--hafif", action="store_true", help="araç yoksa uyar, engelleme (kap içi)"
    )
    parser.add_argument("--json", action="store_true")
    options = parser.parse_args()

    repo = repo_root()
    if (
        options.mode in ("commit-msg", "commit", "push")
        and os.environ.get("KURAL_KAPISI_ATLA") == "1"
    ):
        log_bypass(repo, options.mode)
        return 0
    light = options.hafif or os.environ.get("KURAL_KAPISI_HAFIF") == "1"
    ctx = Context(repo, find_rules_dir(options.kurallar, repo), light)
    if ctx.rules_dir is None:
        ctx.notes.append(
            "kurallar dizini bulunamadı; ruff varsayılan ayarla koşar (SPARK_KURALLAR ver)"
        )
    vendored = repo / ".kural"
    if ctx.rules_dir and vendored.exists() and vendored != ctx.rules_dir:
        if rules_digest(vendored) != rules_digest(ctx.rules_dir):
            ctx.notes.append(
                "depodaki .kural kopyası vault'tan farklı: spark kural kur <proje> ile tazele"
            )

    if options.mode == "commit-msg":
        mode_commit_msg(ctx, Path(options.args[0]))
    elif options.mode == "commit":
        mode_commit(ctx)
    elif options.mode == "push":
        mode_push(ctx, sys.stdin.read())
    elif options.mode == "pr":
        mode_pr(ctx, options.base, options.pr_body_file)
    else:
        mode_files(ctx, options.args)
    return report(ctx, options.json)


if __name__ == "__main__":
    sys.exit(main())
