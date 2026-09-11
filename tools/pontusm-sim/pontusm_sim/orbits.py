"""Strict, non-executing parser for PontusM C orbit-table initializers."""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Mapping

from .types import AlgorithmVersion


Point = tuple[int, int]


@dataclass(frozen=True)
class OrbitInventory:
    normal: tuple[Point, ...]
    engineering: tuple[Point, ...]
    rotated: tuple[Point, ...] | None = None
    unused_24x16: tuple[Point, ...] | None = None

    @property
    def counts(self) -> dict[str, int]:
        counts = {
            "orbit_table": len(self.normal),
            "orbit_table_ew": len(self.engineering),
        }
        if self.rotated is not None:
            counts["orbit_table_32x16"] = len(self.rotated)
        if self.unused_24x16 is not None:
            counts["orbit_table_24x16"] = len(self.unused_24x16)
        return counts


_ARRAY = re.compile(
    r"(?:static\s+)?struct\s+ORBIT\s+"
    r"(orbit_table(?:_24x16|_32x16|_ew)?)\s*\[\s*\]\s*=\s*\{(.*?)\}\s*;",
    re.DOTALL,
)
_PAIR_TEXT = r"\{\s*[+-]?\d+\s*,\s*[+-]?\d+\s*\}"
_BODY = re.compile(rf"\s*{_PAIR_TEXT}(?:\s*,\s*{_PAIR_TEXT})*\s*,?\s*")
_PAIR = re.compile(r"\{\s*([+-]?\d+)\s*,\s*([+-]?\d+)\s*\}")


def _without_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//[^\r\n]*", "", text)


def parse_orbit_tables(
    source_text: str,
    version: AlgorithmVersion,
    *,
    expected_counts: Mapping[str, int] | None = None,
    coordinate_limit: int = 64,
) -> OrbitInventory:
    """Parse only literal signed-decimal pairs from recognized arrays.

    The input is treated purely as text. Preprocessor expressions, macros, designated
    initializers, and all other C syntax are rejected rather than interpreted.
    """

    AlgorithmVersion(version)
    arrays: dict[str, tuple[Point, ...]] = {}
    for match in _ARRAY.finditer(source_text):
        name, unparsed_body = match.groups()
        if name in arrays:
            raise ValueError(f"duplicate orbit table: {name}")
        body = _without_comments(unparsed_body)
        if not _BODY.fullmatch(body):
            raise ValueError(f"malformed initializer in {name}")
        points = tuple((int(horizontal), int(vertical)) for horizontal, vertical in _PAIR.findall(body))
        if any(
            abs(horizontal) > coordinate_limit or abs(vertical) > coordinate_limit
            for horizontal, vertical in points
        ):
            raise ValueError(
                f"{name} contains a coordinate outside -{coordinate_limit}...{coordinate_limit}"
            )
        arrays[name] = points

    if not arrays:
        raise ValueError("no recognized orbit tables")
    if "orbit_table" not in arrays:
        raise ValueError("missing orbit_table")

    for name, count in (expected_counts or {}).items():
        actual = len(arrays.get(name, ()))
        if actual != count:
            raise ValueError(f"{name} expected {count} points, found {actual}")

    return OrbitInventory(
        normal=arrays["orbit_table"],
        engineering=arrays.get("orbit_table_ew", ()),
        rotated=arrays.get("orbit_table_32x16"),
        unused_24x16=arrays.get("orbit_table_24x16"),
    )
