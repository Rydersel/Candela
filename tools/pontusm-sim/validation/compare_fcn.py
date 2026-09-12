#!/usr/bin/env python3
"""Compare the v20 FCN reconstruction with a hash-pinned original C function.

Supply QD_burn_in.c from the official 2023 archive. Only its identified FCN
function is compiled, in a temporary directory, with register writes captured
in memory. This program does not communicate with a display.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile

from pontusm_sim.curve import FCNCurveController


SOURCE_SHA256 = "6c2e4f331ee73a203e46b068daef30e1c7c02a7a60184bc82f6a16e1714f37f4"
FIRST_LINE, LAST_LINE = 2241, 2377
PHASES = (
    ("assert-through-saturation", 18_000, True),
    ("release", 7, False),
    ("stop-before-threshold", 3_499, True),
    ("reset", 1, False),
    ("rearm", 3_500, True),
    ("clear-small-gain", 1, False),
)

PREFIX = r"""
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef uint32_t u32;
static u32 uLD_fcn_cnt = 0, uLD_fcn_gain = 0, uLD_RETENTION_PATT = 0;
static u32 FCN_CURVE_ADDR[41], captured[41], writes;
#define LD_DUMMY_06 0
#define READ_L(address) (fprintf(stderr, "Unexpected register read\n"), exit(2), 0U)
static void qd_dp_register_write(u32 address, u32 mask, u32 value) {
    if (address != writes || writes >= 41 || mask != 0x3FFF) exit(3);
    captured[writes++] = value;
}
"""

SUFFIX = r"""
int main(void) {
    unsigned input;
    for (u32 i = 0; i < 41; ++i) FCN_CURVE_ADDR[i] = i;
    while (scanf("%u", &input) == 1) {
        if (input > 1) return 4;
        uLD_RETENTION_PATT = input;
        writes = 0;
        QD_FCN_CURVE_CTRL(NULL, 0);
        if (writes != 41) return 5;
        printf("%u %u", (unsigned)uLD_fcn_cnt, (unsigned)uLD_fcn_gain);
        for (u32 i = 0; i < 41; ++i) printf(" %u", (unsigned)captured[i]);
        putchar('\n');
    }
    return ferror(stdin) ? 6 : 0;
}
"""


def compare(source_path: Path, compiler: str) -> tuple[dict, str]:
    source = source_path.read_bytes()
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError("Source SHA-256 differs from the identified v20 file")
    function = b"".join(source.splitlines(keepends=True)[FIRST_LINE - 1:LAST_LINE])
    inputs = [int(asserted) for _, calls, asserted in PHASES for _ in range(calls)]
    with tempfile.TemporaryDirectory(prefix="pontusm-fcn-") as directory:
        work = Path(directory)
        c_path, executable = work / "fcn.c", work / "fcn"
        c_path.write_bytes(PREFIX.encode() + function + SUFFIX.encode())
        subprocess.run(
            [compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-Wno-unused-parameter", str(c_path), "-o", str(executable)],
            check=True, capture_output=True, text=True,
        )
        completed = subprocess.run(
            [str(executable)], input="".join(f"{value}\n" for value in inputs),
            check=True, capture_output=True, text=True,
        )

    rows = completed.stdout.splitlines()
    if len(rows) != len(inputs):
        raise ValueError(f"C returned {len(rows)} rows for {len(inputs)} calls")
    model = FCNCurveController()
    digest = hashlib.sha256()
    checkpoints = io.StringIO(newline="")
    writer = csv.writer(checkpoints, lineterminator="\n")
    writer.writerow(("call", "phase", "phase_call", "retention", "count", "gain", "curve_40"))
    call = 0
    for phase, calls, asserted in PHASES:
        for phase_call in range(1, calls + 1):
            observed = tuple(map(int, rows[call].split()))
            gain, curve = model.step(asserted)
            expected = (model.retention_count, gain, *curve)
            call += 1
            if observed != expected:
                raise ValueError(f"C/Python mismatch at call {call}: {observed} != {expected}")
            digest.update(struct.pack(">43I", *observed))
            if phase_call in {1, calls, 3499, 3500, 3501, 17898, 17899, 17900} or not asserted:
                writer.writerow((call, phase, phase_call, int(asserted), *observed[:2], observed[-1]))

    return {
        "source_sha256": SOURCE_SHA256,
        "function": "QD_FCN_CURVE_CTRL",
        "source_lines": [FIRST_LINE, LAST_LINE],
        "function_bytes_sha256": hashlib.sha256(function).hexdigest(),
        "phases": [{"name": name, "calls": calls, "retention": asserted}
                   for name, calls, asserted in PHASES],
        "calls_compared": call,
        "curve_values_compared": call * 41,
        "state_values_compared": call * 2,
        "mismatches": 0,
        "trace_sha256": digest.hexdigest(),
        "trace_encoding": "Per call: count, gain, then 41 curve values; each unsigned 32-bit big-endian",
    }, checkpoints.getvalue()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Unmodified v20 QD_burn_in.c")
    parser.add_argument("--output", type=Path, required=True, help="New directory for results")
    parser.add_argument("--cc", default="cc", help="C compiler executable, default: cc")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output directory already exists")
    try:
        result, checkpoints = compare(args.source, args.cc)
    except subprocess.CalledProcessError as error:
        parser.exit(1, f"C comparison failed: {error.stderr}\n")
    except (OSError, ValueError) as error:
        parser.exit(1, f"C comparison failed: {error}\n")
    args.output.mkdir(parents=True)
    (args.output / "fcn-comparison.json").write_text(json.dumps(result, indent=2) + "\n")
    (args.output / "fcn-checkpoints.csv").write_text(checkpoints)
    print(f"Matched {result['calls_compared']:,} calls and all {result['curve_values_compared']:,} curve values.")


if __name__ == "__main__":
    main()
