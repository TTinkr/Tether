"""WER scoring for the Tokens speech bench.

Normalizer: OpenAI Whisper's EnglishTextNormalizer, vendored byte-for-byte in whisper_normalizer/
from openai/whisper tag v20250625 (commit 31243bad24cc746f07d4c8bfdd2d974872cb1803), MIT licence
in whisper_normalizer/LICENSE. The Open ASR Leaderboard normalizes references and hypotheses with
this normalizer before scoring.

Counts: jiwer 3.0.5 (the library under Hugging Face `evaluate`'s "wer" metric, which the Open ASR
Leaderboard uses) gives substitutions, deletions and insertions per clip; an independent word-level
Levenshtein in this file must agree on the total, or scoring stops. Corpus WER = (S + D + I) / N
summed over clips, N = normalized reference words.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import jiwer  # noqa: E402
from whisper_normalizer import EnglishTextNormalizer  # noqa: E402

_normalizer = EnglishTextNormalizer()


def normalize(text):
    return " ".join(_normalizer(text).split())


def edit_distance(ref, hyp):
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h))
        prev = cur
    return prev[-1]


def counts(ref_text, hyp_text):
    """Return dict with normalized texts and S/D/I/N for one clip."""
    ref = normalize(ref_text)
    hyp = normalize(hyp_text)
    rw, hw = ref.split(), hyp.split()
    if not rw:
        raise ValueError("empty normalized reference")
    if not hw:
        s, d, i = 0, len(rw), 0
    else:
        out = jiwer.process_words(ref, hyp)
        s, d, i = out.substitutions, out.deletions, out.insertions
    if s + d + i != edit_distance(rw, hw):
        raise AssertionError("jiwer and Levenshtein disagree on %r / %r" % (ref, hyp))
    return {"ref_norm": ref, "hyp_norm": hyp, "n": len(rw), "s": s, "d": d, "i": i}


def provenance():
    from importlib.metadata import version
    return {"normalizer": "openai/whisper EnglishTextNormalizer, vendored from tag v20250625 "
                          "(31243bad24cc746f07d4c8bfdd2d974872cb1803), MIT",
            "packages": {p: version(p) for p in ("jiwer", "rapidfuzz", "regex", "more-itertools")},
            "python": sys.version.split()[0]}
