#!/usr/bin/env python3
"""Refresh the bundled Korean company-name lookup from KRX KIND."""

from datetime import date
from html.parser import HTMLParser
from pathlib import Path
from urllib.request import urlopen
import re

SOURCE = "https://kind.krx.co.kr/corpgeneral/corpList.do?method=download"
OUTPUT = Path(__file__).resolve().parents[1] / "Sources/Resources/krx-listed-companies.tsv"


class ListedCompanies(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows = []
        self.row = []
        self.cell = None

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.row = []
        elif tag == "td":
            self.cell = []

    def handle_data(self, data):
        if self.cell is not None:
            self.cell.append(data)

    def handle_endtag(self, tag):
        if tag == "td" and self.cell is not None:
            self.row.append("".join(self.cell).strip())
            self.cell = None
        elif tag == "tr" and len(self.row) >= 3:
            self.rows.append(self.row)


def main():
    with urlopen(SOURCE, timeout=30) as response:
        page = response.read().decode("euc-kr")
    parser = ListedCompanies()
    parser.feed(page)
    companies = {}
    for name, market, code, *_ in parser.rows:
        if market not in {"유가", "코스닥", "코넥스"} or not re.fullmatch(r"[0-9A-Z]{6}", code):
            continue
        if not name or any(c in name for c in "\t\r\n"):
            continue
        if code in companies and companies[code] != (name, market):
            raise ValueError(f"conflicting KRX code: {code}")
        companies[code] = name, market
    if len(companies) < 2000:
        raise ValueError(f"incomplete KRX listing: {len(companies)} entries")
    lines = [f"# KRX KIND listed companies; retrieved {date.today().isoformat()}",
             f"# {SOURCE}", "code\tname\tmarket"]
    lines += [f"{code}\t{name}\t{market}" for code, (name, market) in sorted(companies.items())]
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {len(companies)} companies to {OUTPUT}")


if __name__ == "__main__":
    main()
