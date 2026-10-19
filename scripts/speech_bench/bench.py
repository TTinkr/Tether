#!/usr/bin/env python3
"""Run the preregistered speech bench against the frozen Tokens workers, one model at a time.

The workers are launched exactly as the app launches them (OrukeetWorker.swift):
  <worker> --model /abs/model.gguf --gpu 0
  env GGML_BACKEND_DL_PATH=<Orukeet/lib> (orukeet-worker) or <Transcribe> (transcribe-worker), OMP_NUM_THREADS=2
and spoken to over the ORK1 stdin/stdout protocol. No .app bundle is launched; nothing is written
to ~/Library or the Tokens defaults; no microphone or permission is used.

Per model:
  cold load  x3: new process, time from spawn to the "ready" line, then stdin EOF.
  warm decode:   one long-lived process; per clip one untimed warm-up request, then 3 timed
                 requests of the same clip, each timed from the end of writing the request frame
                 to the result line's newline: worker decode time for complete audio, not key
                 release, capture or paste. The timed requests repeat audio the worker has just
                 decoded; the untimed first decode of each clip is kept in the receipts.
  RSS:           ru_maxrss of the warm process from wait4() (bytes on macOS), no admin needed.
WER uses timed request 1's text; the 4 texts per clip are compared and mismatches counted.

Usage:
  bench.py --dry-run                      2 clips (1 per set), 1 model (first in models.json)
  bench.py --out results/2026-10-16-m5    full run, all models
  options: --models id,id  --runtime-root <Resources dir>  --cache DIR  --repeats 3 --cold-loads 3
  --models / --clips / --dry-run are recorded in summary.json > selection; to_swift.py refuses them.
  Output files are written whole (temp file, then rename); a model that fails ends its receipt
  with a "failed" line, and its worker is always reaped.
"""
import argparse
import csv
import hashlib
import json
import os
import platform
import select
import statistics
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score  # noqa: E402

DEFAULT_CACHE = os.path.expanduser("~/.cache/tether-speech-bench")
READY_TIMEOUT = 60.0
REQUEST_TIMEOUT = 60.0


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_text(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception as e:  # recorded, never fatal
        return "unavailable: %s" % e


def utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def percentile(values, q):
    """Linear interpolation between closest ranks (numpy's default 'linear' method)."""
    v = sorted(values)
    if not v:
        return None
    k = (len(v) - 1) * q
    lo = int(k)
    hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


class Worker:
    """One worker process speaking ORK1. Timing uses time.perf_counter()."""

    def __init__(self, exe, model, libdir, stderr_path):
        env = dict(os.environ)
        env["GGML_BACKEND_DL_PATH"] = libdir
        env["OMP_NUM_THREADS"] = "2"
        self.stderr = open(stderr_path, "ab")
        self.t_spawn = time.perf_counter()
        try:
            self.proc = subprocess.Popen([exe, "--model", model, "--gpu", "0"], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=self.stderr, env=env, bufsize=0)
        except BaseException:
            self.stderr.close()
            raise
        self.out = self.proc.stdout.fileno()
        self.inp = self.proc.stdin.fileno()
        self.buf = b""
        self.next_id = 0
        self.rusage = None
        self.status = None

    def read_line(self, timeout):
        deadline = time.perf_counter() + timeout
        while b"\n" not in self.buf:
            left = deadline - time.perf_counter()
            if left <= 0:
                raise TimeoutError("worker line timeout")
            r, _, _ = select.select([self.out], [], [], left)
            if not r:
                continue
            chunk = os.read(self.out, 1 << 16)
            if not chunk:
                raise EOFError("worker closed stdout")
            self.buf += chunk
        t = time.perf_counter()
        line, self.buf = self.buf.split(b"\n", 1)
        return line, t

    def wait_ready(self):
        line, t = self.read_line(READY_TIMEOUT)
        obj = json.loads(line)
        ok = (obj.get("type") == "ready" and obj.get("protocol") == "ORK1" and obj.get("mode") == "offline_retained"
              and obj.get("sample_format") == "mono_f32le" and obj.get("max_seconds") == 30
              and obj.get("backend_requested") == "metal")
        if not ok:
            raise RuntimeError("unexpected ready line: %s" % line[:300])
        return obj, line.decode("utf-8"), t - self.t_spawn

    def request(self, payload, samples):
        self.next_id += 1
        frame = struct.pack("<4sQII", b"ORK1", self.next_id, 16000, samples) + payload
        view = memoryview(frame)
        while view:
            n = os.write(self.inp, view)
            view = view[n:]
        t_written = time.perf_counter()
        line, t_line = self.read_line(REQUEST_TIMEOUT)
        obj = json.loads(line)
        if not (obj.get("type") == "result" and obj.get("request_id") == str(self.next_id)
                and obj.get("sample_rate") == 16000 and obj.get("sample_count") == samples
                and obj.get("mode") == "offline" and obj.get("is_final") is True and isinstance(obj.get("text"), str)):
            raise RuntimeError("unexpected result line: %s" % line[:300])
        self.t_last_line = t_line
        return obj, line.decode("utf-8"), t_line - t_written

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        deadline = time.time() + 30
        while True:
            pid, status, rusage = os.wait4(self.proc.pid, os.WNOHANG)
            if pid:
                self.status, self.rusage = status, rusage
                self.proc.returncode = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else status
                break
            if time.time() > deadline:
                self.proc.kill()
                deadline = time.time() + 5
            time.sleep(0.01)
        tail = b""
        try:
            tail = self.buf + self.proc.stdout.read()
        except Exception:
            pass
        self.stderr.close()
        return tail.decode("utf-8", "replace").strip()


NORMALIZER_DIR = "whisper_normalizer"


def harness_files():
    """Top-level harness files, plus every vendored normalizer file (they set every WER)."""
    top = [f for f in os.listdir(HERE) if f.endswith((".py", ".json", ".md", ".txt")) and f != "manifest.json"]
    vendored = [os.path.join(NORMALIZER_DIR, f) for f in os.listdir(os.path.join(HERE, NORMALIZER_DIR))
                if os.path.isfile(os.path.join(HERE, NORMALIZER_DIR, f)) and not f.endswith(".pyc")]
    return sorted(top + vendored)


def write_atomic(path, write, newline=None):
    """Write a whole file or nothing: a temp file in the same folder, then rename."""
    tmp = "%s.tmp-%d" % (path, os.getpid())
    try:
        with open(tmp, "w", newline=newline) as f:
            write(f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)  # our own unfinished temp file, never the receipt it would replace
        raise


def environment(runtime_root, workers):
    git = lambda *a: run_text(["/usr/bin/git", "-C", HERE] + list(a))  # noqa: E731
    return {
        "date_utc": utc(),
        "chip": run_text(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"]),
        "hw_model": run_text(["/usr/sbin/sysctl", "-n", "hw.model"]),
        "memory_bytes": int(run_text(["/usr/sbin/sysctl", "-n", "hw.memsize"]) or 0),
        "cpu_cores": {"total": run_text(["/usr/sbin/sysctl", "-n", "hw.ncpu"]),
                      "perf": run_text(["/usr/sbin/sysctl", "-n", "hw.perflevel0.physicalcpu"]),
                      "efficiency": run_text(["/usr/sbin/sysctl", "-n", "hw.perflevel1.physicalcpu"])},
        "sw_vers": run_text(["/usr/bin/sw_vers"]).replace("\t", " ").splitlines(),
        "power": run_text(["/usr/bin/pmset", "-g", "batt"]).splitlines(),
        "harness_git": {"commit": git("rev-parse", "HEAD"), "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
                        "dirty": bool(git("status", "--porcelain", "--", ".")),
                        "status_porcelain": git("status", "--porcelain", "--", ".").splitlines()},
        "harness_files_sha256": {f: sha256_file(os.path.join(HERE, f)) for f in harness_files()},
        "runtime_root": runtime_root,
        "workers": workers,
        "python": platform.python_version(),
        "scoring": score.provenance(),
    }


def snapshot():
    return {"utc": utc(), "load": run_text(["/usr/bin/uptime"]),
            "therm": run_text(["/usr/bin/pmset", "-g", "therm"]).splitlines()[-3:]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--models", default="")
    ap.add_argument("--clips", type=int, default=0, help="limit clips per set (0 = all)")
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--cold-loads", type=int, default=3)
    ap.add_argument("--cache", default=DEFAULT_CACHE)
    ap.add_argument("--manifest", default=os.path.join(HERE, "manifest.json"))
    ap.add_argument("--runtime-root", required=True, help="Reviewed app Contents/Resources directory containing staged workers")
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    spec = json.load(open(os.path.join(HERE, "models.json")))
    manifest_sha = sha256_file(a.manifest)
    manifest = json.load(open(a.manifest))
    models = spec["models"]
    catalogue = [m["id"] for m in models]
    want = None
    if a.models:
        want = a.models.split(",")
        unknown = sorted(set(want) - set(catalogue))
        if unknown or len(set(want)) != len(want):
            sys.exit("--models: unknown %s or duplicate ids in %r; known: %s" % (unknown, a.models, ",".join(catalogue)))
        models = [m for m in models if m["id"] in want]
    per_set = a.clips
    if a.dry_run:
        models, per_set = models[:1], 1
        a.cold_loads = min(a.cold_loads, 1)
    clips = []
    for set_name in ("test-clean", "test-other"):
        subset = [c for c in manifest["clips"] if c["set"] == set_name]
        clips += subset[:per_set] if per_set else subset

    root = a.runtime_root
    exes = {"orukeet": (os.path.join(root, "Orukeet", "orukeet-worker"), os.path.join(root, "Orukeet", "lib")),
            "transcribe": (os.path.join(root, "Transcribe", "transcribe-worker"), os.path.join(root, "Transcribe"))}
    workers = {k: {"path": v[0], "sha256": sha256_file(v[0]), "GGML_BACKEND_DL_PATH": v[1]} for k, v in exes.items()}
    lib_hashes = {f: sha256_file(os.path.join(exes["orukeet"][1], f)) for f in sorted(os.listdir(exes["orukeet"][1]))}
    workers["orukeet"]["lib_sha256"] = lib_hashes

    run_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + ("-dryrun" if a.dry_run else "")
    raw_dir = os.path.join(a.cache, "raw", run_id)
    os.makedirs(raw_dir)
    out_dir = a.out or os.path.join(a.cache, "dryrun", run_id)
    os.makedirs(out_dir, exist_ok=True)
    if not os.path.isabs(out_dir):
        out_dir = os.path.abspath(out_dir)

    # Audio: verify every clip against the preregistered hash before any model runs.
    # Probe for cold first-result: the first test-clean clip in the 8-12 s bin, always loaded.
    probe = next(c for c in manifest["clips"] if c["set"] == "test-clean" and c["bin"] == "8-12")
    audio = {}
    for c in clips + [probe]:
        path = os.path.join(a.cache, c["audio_path"])
        data = open(path, "rb").read()
        if hashlib.sha256(data).hexdigest() != c["audio_f32le_sha256"] or len(data) != 4 * c["samples"]:
            sys.exit("audio hash mismatch for %s" % c["id"])
        audio[c["id"]] = data

    selected = [m["id"] for m in models]
    selection = {"models_requested": want, "clips_per_set_limit": per_set, "dry_run": a.dry_run,
                 "catalogue_models": catalogue, "selected_models": selected,
                 "manifest_clips": len(manifest["clips"]), "selected_clips": len(clips),
                 "partial": bool(want is not None or per_set or a.dry_run or selected != catalogue
                                 or len(clips) != len(manifest["clips"]))}

    env = environment(root, workers)
    started = time.time()
    write_atomic(os.path.join(raw_dir, "env.json"),
                 lambda f: json.dump({"env": env, "manifest_sha256": manifest_sha, "args": vars(a)}, f, indent=1))
    print("run %s: %d models x %d clips; manifest %s; raw %s" % (run_id, len(models), len(clips), manifest_sha[:12], raw_dir), flush=True)

    summary_models, rows, hyps = [], [], []
    for m in models:
        exe, libdir = exes[m["worker"]]
        model_path = os.path.join(a.cache, "models", m["id"], m["file"])
        rec = {"id": m["id"], "name": m["name"], "worker": m["worker"], "worker_sha256": workers[m["worker"]]["sha256"],
               "model_file": m["file"], "model_sha256_pinned": m["sha256"], "status": "ok", "before": snapshot()}
        t_model = time.time()
        w = None
        model_rows, model_hyps = [], []
        try:
            if not os.path.exists(model_path):
                raise RuntimeError("model file missing: %s" % model_path)
            sha = sha256_file(model_path)
            rec["model_sha256_verified"] = sha
            if sha != m["sha256"] or os.path.getsize(model_path) != m["bytes"]:
                raise RuntimeError("model hash mismatch; refused")
            stderr_path = os.path.join(raw_dir, m["id"] + ".stderr.log")
            with open(os.path.join(raw_dir, m["id"] + ".jsonl"), "w") as receipts:
                try:
                    cold = []
                    for k in range(a.cold_loads):
                        w = Worker(exe, model_path, libdir, stderr_path)
                        ready, line, secs = w.wait_ready()
                        # Extension: spawn -> first result on one fixed probe clip. orukeet-worker loads
                        # lazily (its ready line comes before the first real decode), transcribe-worker
                        # pre-warms before ready, so ready alone does not compare the two.
                        pobj, pline, pdt = w.request(audio[probe["id"]], probe["samples"])
                        first = w.t_last_line - w.t_spawn
                        tail = w.close()
                        cold.append({"seconds": secs, "first_result_seconds": first, "worker_load_ms": ready.get("load_ms"),
                                     "maxrss_bytes": w.rusage.ru_maxrss, "exit": w.proc.returncode, "closing": tail})
                        receipts.write(json.dumps({"kind": "cold", "n": k + 1, "ready_line": line, "seconds": secs,
                                                   "probe_clip": probe["id"], "probe_result_line": pline, "probe_seconds": pdt,
                                                   "first_result_seconds": first, "maxrss_bytes": w.rusage.ru_maxrss,
                                                   "exit": w.proc.returncode, "closing": tail}) + "\n")
                        print("  %s cold %d: ready %.3fs, first result %.3fs" % (m["id"], k + 1, secs, first), flush=True)

                    w = Worker(exe, model_path, libdir, stderr_path)
                    ready, line, secs = w.wait_ready()
                    rec["ready_line"] = ready
                    receipts.write(json.dumps({"kind": "warm_ready", "ready_line": line, "seconds": secs}) + "\n")
                    timed_all, talk10, mismatches, total_audio, total_decode = [], [], 0, 0.0, 0.0
                    tot = {s: {"n": 0, "s": 0, "d": 0, "i": 0} for s in ("test-clean", "test-other")}
                    for idx, c in enumerate(clips):
                        payload = audio[c["id"]]
                        texts, times, worker_ms = [], [], []
                        for rep in range(a.repeats + 1):
                            obj, rline, dt = w.request(payload, c["samples"])
                            receipts.write(json.dumps({"kind": "warmup" if rep == 0 else "timed", "clip": c["id"], "rep": rep,
                                                       "seconds": dt, "result_line": rline}) + "\n")
                            texts.append(obj["text"])
                            if idx == 0 and rep == 0:
                                first_request = {"clip": c["id"], "duration_s": c["duration_s"], "seconds": dt,
                                                 "note": "first request after ready (untimed warm-up of clip 1); not in latency stats"}
                            if rep:
                                times.append(dt)
                                worker_ms.append(obj.get("recognition_ms"))
                        hyp = texts[1]
                        same = all(t == hyp for t in texts)
                        mismatches += 0 if same else 1
                        sc = score.counts(c["ref_text"], hyp)
                        for key in ("n", "s", "d", "i"):
                            tot[c["set"]][key] += sc[key]
                        timed_all += times
                        if 8.0 <= c["duration_s"] <= 12.0:
                            talk10 += times
                        total_audio += c["duration_s"] * len(times)
                        total_decode += sum(times)
                        model_rows.append({"model": m["id"], "clip_id": c["id"], "set": c["set"], "bin": c["bin"],
                                           "duration_s": c["duration_s"], "ref_words": sc["n"], "sub": sc["s"], "del": sc["d"],
                                           "ins": sc["i"], "errors": sc["s"] + sc["d"] + sc["i"],
                                           **{"t%d_s" % (r + 1): round(t, 6) for r, t in enumerate(times)},
                                           **{"worker_ms_%d" % (r + 1): ms for r, ms in enumerate(worker_ms)},
                                           "outputs_identical": same})
                        model_hyps.append({"model": m["id"], "clip_id": c["id"], "hyp": hyp, "hyp_norm": sc["hyp_norm"],
                                           "ref_norm": sc["ref_norm"], "all_outputs_identical": same,
                                           **({} if same else {"other_outputs": texts})})
                        if (idx + 1) % 25 == 0 or idx + 1 == len(clips):
                            print("  %s %d/%d clips, %.0fs elapsed" % (m["id"], idx + 1, len(clips), time.time() - t_model), flush=True)
                    tail = w.close()
                    receipts.write(json.dumps({"kind": "warm_close", "exit": w.proc.returncode, "maxrss_bytes": w.rusage.ru_maxrss,
                                               "closing": tail}) + "\n")
                except BaseException as e:  # the receipt ends with why it stopped, then closes whole
                    receipts.write(json.dumps({"kind": "failed", "error": "%s: %s" % (type(e).__name__, e),
                                               "clips_completed": len(model_rows), "clips_expected": len(clips)}) + "\n")
                    raise

            def wer(keys):
                n = sum(tot[k]["n"] for k in keys)
                e = sum(tot[k]["s"] + tot[k]["d"] + tot[k]["i"] for k in keys)
                return {"wer_percent": round(100.0 * e / n, 3) if n else None, "errors": e, "ref_words": n,
                        "sub": sum(tot[k]["s"] for k in keys), "del": sum(tot[k]["d"] for k in keys),
                        "ins": sum(tot[k]["i"] for k in keys),
                        "clips": sum(1 for c in clips if c["set"] in keys)}
            colds = [x["seconds"] for x in cold]
            firsts = [x["first_result_seconds"] for x in cold]
            rec.update({
                "wer": {"test-clean": wer(["test-clean"]), "test-other": wer(["test-other"]),
                        "combined": wer(["test-clean", "test-other"])},
                "latency_s": {"n_timed": len(timed_all), "median": statistics.median(timed_all),
                              "p90": percentile(timed_all, 0.9), "min": min(timed_all), "max": max(timed_all)},
                "talk_10s_latency_s": {"label": "10-second talk (clips 8-12 s)", "n_timed": len(talk10),
                                       "n_clips": len(talk10) // a.repeats if a.repeats else 0,
                                       "median": statistics.median(talk10) if talk10 else None,
                                       "p90": percentile(talk10, 0.9) if talk10 else None},
                "speed_x_realtime": round(total_audio / total_decode, 2) if total_decode else None,
                "cold_load_s": {"runs": colds, "median": statistics.median(colds), "min": min(colds), "max": max(colds),
                                "worker_load_ms": [x["worker_load_ms"] for x in cold]},
                "cold_first_result_s": {"runs": firsts, "median": statistics.median(firsts), "probe_clip": probe["id"],
                                        "probe_duration_s": probe["duration_s"],
                                        "definition": "new process: spawn to the result line of one request (the probe clip)"},
                "peak_rss_bytes": {"warm_process": w.rusage.ru_maxrss, "cold_processes_max": max(x["maxrss_bytes"] for x in cold),
                                   "method": "wait4() ru_maxrss of the worker process (bytes on macOS)"},
                "first_request_after_ready": first_request,
                "outputs_differing_across_4_requests": mismatches,
                "n_clips": len(clips),
                "receipt_jsonl": os.path.relpath(os.path.join(raw_dir, m["id"] + ".jsonl"), a.cache),
                "receipt_sha256": sha256_file(os.path.join(raw_dir, m["id"] + ".jsonl")),
            })
            rows.extend(model_rows)
            hyps.extend(model_hyps)
        except Exception as e:  # a failed model is reported, never silently dropped
            rec["status"] = "failed"
            rec["error"] = "%s: %s" % (type(e).__name__, e)
            rec["clips_completed"], rec["clips_expected"] = len(model_rows), len(clips)
            print("  %s FAILED: %s" % (m["id"], rec["error"]), flush=True)
        finally:  # never leave a worker running or its stderr log open
            if w is not None and w.status is None:
                try:
                    w.proc.kill()
                    w.close()
                except Exception:
                    pass
        rec["after"] = snapshot()
        rec["model_wall_s"] = round(time.time() - t_model, 1)
        summary_models.append(rec)
        if rec["status"] == "ok":
            print("%s: WER clean %.2f other %.2f comb %.2f | 10s-talk median %.3fs | cold %.2fs | %.0fs" % (
                m["id"], rec["wer"]["test-clean"]["wer_percent"], rec["wer"]["test-other"]["wer_percent"],
                rec["wer"]["combined"]["wer_percent"], rec["talk_10s_latency_s"]["median"] or -1,
                rec["cold_load_s"]["median"], rec["model_wall_s"]), flush=True)

    not_measured = [{"id": "apple", "name": "Apple", "status": "not measured",
                     "reason": "needs Speech Recognition permission in an app context (SFSpeechRecognizer); this bench runs no app and asks for no permission"}]
    summary = {
        "schema": "tinkr-speech-bench-summary/1",
        "run_id": run_id,
        "dry_run": a.dry_run,
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
        "finished_utc": utc(),
        "wall_seconds": round(time.time() - started, 1),
        "manifest_sha256": manifest_sha,
        "manifest_created_utc": manifest.get("created_utc"),
        "selection": selection,
        "clips": {"per_set": {s: sum(1 for c in clips if c["set"] == s) for s in ("test-clean", "test-other")},
                  "total": len(clips), "audio_seconds": round(sum(c["duration_s"] for c in clips), 2)},
        "method": {"cold_loads": a.cold_loads, "timed_repeats_per_clip": a.repeats, "warmup_per_clip": 1,
                   "timing": "end of writing the ORK1 frame to the result line's newline, time.perf_counter()",
                   "wer": "corpus WER = (S+D+I)/N after Whisper EnglishTextNormalizer, from timed request 1",
                   "p90": "linear interpolation between closest ranks",
                   "talk_10s": "median of timed requests on clips with 8.0 <= duration <= 12.0 s",
                   "cold_load": "new process, spawn to ready line; OS file cache and Metal shader cache not purged",
                   "cold_first_result": "new process, spawn to result line of one probe-clip request (extension to the plan)",
                   "worker_args": "--model <abs> --gpu 0; env GGML_BACKEND_DL_PATH, OMP_NUM_THREADS=2"},
        "environment": env,
        "models": summary_models,
        "not_measured": not_measured,
        "raw_receipts_dir": os.path.relpath(raw_dir, a.cache),
    }
    fields = ["model", "clip_id", "set", "bin", "duration_s", "ref_words", "sub", "del", "ins", "errors"] + \
             ["t%d_s" % (r + 1) for r in range(a.repeats)] + ["worker_ms_%d" % (r + 1) for r in range(a.repeats)] + ["outputs_identical"]

    def write_csv(f):
        wcsv = csv.DictWriter(f, fieldnames=fields)
        wcsv.writeheader()
        wcsv.writerows(rows)
    write_atomic(os.path.join(out_dir, "per_clip.csv"), write_csv, newline="")
    write_atomic(os.path.join(out_dir, "hypotheses.jsonl"),
                 lambda f: f.writelines(json.dumps(h, ensure_ascii=False) + "\n" for h in hyps))
    write_atomic(os.path.join(out_dir, "manifest.sha256"), lambda f: f.write("%s  manifest.json\n" % manifest_sha))
    write_atomic(os.path.join(out_dir, "receipts.sha256"), lambda f: f.writelines(
        "%s  %s\n" % (sha256_file(os.path.join(raw_dir, name)), os.path.join(os.path.relpath(raw_dir, a.cache), name))
        for name in sorted(os.listdir(raw_dir))))
    # summary.json last: it exists only once everything it describes has been written.
    write_atomic(os.path.join(out_dir, "summary.json"), lambda f: (json.dump(summary, f, indent=1), f.write("\n")))
    print("done in %.0fs -> %s" % (time.time() - started, out_dir), flush=True)
    if any(r["status"] != "ok" for r in summary_models):
        sys.exit(2)


if __name__ == "__main__":
    main()
