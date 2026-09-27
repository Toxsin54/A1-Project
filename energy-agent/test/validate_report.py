#!/usr/bin/env python3
"""Enerji raporunu yayına almadan önce doğrular.

  pip install jsonschema
  python3 energy-agent/test/validate_report.py energy-agent/contracts/example-morning-brief.json

Kontroller:
  1. JSON Schema (zarf + enerji payload'u)
  2. Atıflar: findings[].evidence_ids ve risks[].evidence_ids, evidence listesinde olmalı;
     evidence listesindeki her kayıt payload'da karşılığı olan bir id taşımalı.
  3. Sayılar: summary ve statement metinlerindeki ondalıklı sayılar ve yüzdeler payload'daki
     bir sayıyla (yuvarlama payı içinde) eşleşmeli. LLM'in sayı uydurmasını yakalar.
Çıkış kodu 0 = geçerli, 1 = hata (hatalar stdout'a JSON olarak yazılır; LLM'e düzeltme için geri verilebilir).
"""
import json
import re
import sys
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

CONTRACTS = Path(__file__).resolve().parent.parent / "contracts"


def load_validator():
    registry = Registry()
    for name in ("agent-report-envelope.schema.json", "energy-report.schema.json"):
        schema = json.loads((CONTRACTS / name).read_text(encoding="utf-8"))
        registry = registry.with_resource(schema["$id"], Resource.from_contents(schema))
    root = json.loads((CONTRACTS / "energy-report.schema.json").read_text(encoding="utf-8"))
    return Draft202012Validator(root, registry=registry, format_checker=FormatChecker())


def payload_ids(payload):
    ids = set()
    for key in ("market_snapshot", "derived_metrics", "indicators", "news"):
        ids.update(item["evidence_id"] for item in payload.get(key, []))
    return ids


def payload_numbers(obj, out):
    if isinstance(obj, bool):
        return out
    if isinstance(obj, (int, float)):
        out.add(float(obj))
    elif isinstance(obj, dict):
        for v in obj.values():
            payload_numbers(v, out)
    elif isinstance(obj, list):
        for v in obj:
            payload_numbers(v, out)
    return out


# "72,70" "%5,55" "5,55%" "-3,5" "1.234,5" — Türkçe biçim: binlik nokta, ondalık virgül
NUM_RE = re.compile(r"(%\s*)?(-?\d{1,3}(?:\.\d{3})+(?:,\d+)?|-?\d+,\d+|-?\d+)(\s*%)?")


def text_numbers(text):
    """Metindeki kontrol edilecek sayılar: ondalıklı olanlar ve yüzdeler.
    Tam sayılar (tarih, adet, '137 bin') atlanır; bunlar sezgisel kontrolün dışında kalır."""
    found = []
    for m in NUM_RE.finditer(text):
        raw = m.group(2)
        is_pct = bool(m.group(1) or m.group(3))
        if "," not in raw and not is_pct:
            continue
        decimals = len(raw.split(",")[1]) if "," in raw else 0
        found.append((m.group(0).strip(), float(raw.replace(".", "").replace(",", ".")), decimals))
    return found


def matches(value, decimals, known):
    tol = 0.5 * 10 ** -decimals + 1e-9
    return any(abs(abs(value) - abs(k)) <= max(tol, abs(k) * 0.001) for k in known)


def validate(report):
    errors = []
    for e in load_validator().iter_errors(report):
        errors.append({"check": "schema", "path": "/".join(map(str, e.absolute_path)), "error": e.message})
    if errors:
        return errors

    evidence_ids = {e["id"] for e in report["evidence"]}
    known_ids = payload_ids(report["payload"])
    for e in report["evidence"]:
        if e["kind"] in ("price", "derived", "indicator", "news") and e["id"] not in known_ids:
            errors.append({"check": "evidence", "error": f"evidence '{e['id']}' payload'da yok"})
    refs = [(f["id"], r) for f in report["findings"] for r in f["evidence_ids"]]
    refs += [("risk", r) for risk in report["payload"].get("risks", []) for r in risk.get("evidence_ids", [])]
    for owner, ref in refs:
        if ref not in evidence_ids:
            errors.append({"check": "citation", "error": f"{owner}: '{ref}' evidence listesinde yok"})

    known_numbers = payload_numbers(report["payload"], set())
    texts = [("summary", report["summary"])] + [(f["id"], f["statement"]) for f in report["findings"]]
    for owner, text in texts:
        for shown, value, decimals in text_numbers(text):
            if not matches(value, decimals, known_numbers):
                errors.append({"check": "number", "error": f"{owner}: '{shown}' verilerde bulunamadı"})
    return errors


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    errors = validate(report)
    print(json.dumps({"valid": not errors, "errors": errors}, ensure_ascii=False, indent=2))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
