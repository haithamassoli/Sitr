"""FastAPI entrypoint for the nomusic backend.

Run directly with ``python backend/server.py`` (no uvicorn CLI needed).

``create_app`` is a thin assembler: it builds the app, wires the shared engine /
cache / job registry onto ``app.state``, starts the background daemons (cache
TTL sweep, memory GC, engine warmup), and includes the routers. The endpoints
live in :mod:`routes` (system / jobs / media):

  GET  /healthz
  GET  /capabilities
  POST /process              {url, model?, keep_stems?} -> {job_id, ...}
  POST /process/{job_id}/prioritize {from_chunk} -> {applied}
  GET  /status/{job_id}      -> JobStatus
  GET  /events/{job_id}      -> text/event-stream (SSE status updates)
  GET  /chunk/{job_id}/{idx} -> audio/ogg (425 if not yet ready)
  GET  /audio/{job_id}       -> audio/ogg (concatenated track; ?format=mp3 transcodes)
  GET  /video/{job_id}       -> video/mp4 (original video, stripped audio muxed in)
  GET  /video/{job_id}/progress -> {phase, percent} for the export in flight
  GET  /cache                -> cache stats
  POST /cache/clear          -> {deleted_bytes}
"""

from __future__ import annotations

import asyncio
import ctypes
import logging
import os
import re
import signal
import sys
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import PlainTextResponse

# PyInstaller's executable lives in Contents/MacOS; bundled tools live in
# Contents/Resources. The model downloads on first use into Application Support
# (the signed bundle is read-only). Set these before importing config or yt-dlp.
if getattr(sys, "frozen", False):
    resources = Path(sys.executable).resolve().parent.parent / "Resources"
    os.environ["PATH"] = str(resources / "bin") + os.pathsep + os.environ.get("PATH", "")
    os.environ["NOMUSIC_JS_RUNTIME"] = str(resources / "bin" / "deno")
    os.environ["TORCH_HOME"] = str(Path.home() / "Library" / "Application Support" / "Sitr" / "Music" / "torch")
    # A frozen Python has no system CA path; torch.hub's model download needs one.
    import certifi
    os.environ.setdefault("SSL_CERT_FILE", certifi.where())
    os.environ.setdefault("NOMUSIC_CACHE_DIR", str(Path.home() / "Library" / "Caches" / "Sitr" / "Music"))

from config import SETTINGS
from engines import get_engine
from jobs import JobRegistry
from pipeline.cache import JobCache
from pipeline.processor import Processor
from routes.jobs import router as jobs_router
from routes.media import router as media_router
from routes.system import router as system_router

# Directory holding the flat backend modules; needed by the uvicorn reloader
# (see main()), which re-imports "server" in a watcher subprocess and so needs
# the dir on PYTHONPATH. Running ``python backend/server.py`` puts this dir on
# sys.path automatically (Python prepends the executed script's directory), so
# the sibling ``from config import …`` imports above resolve.
_BACKEND_DIR = Path(__file__).resolve().parent

log = logging.getLogger("nomusic.server")
_EXTENSION_ORIGIN = re.compile(r"chrome-extension://[a-p]{32}")
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost"})
_SITR_MUSIC_NOTIFY = b"com.goldentik.Sitr.Music.enabled"
# Helper -> Sitr status, read by Sitr's Music tab (Sitr has no network access,
# so it can't ask over HTTP). Model: 1 preparing, 2 ready, 3 failed (retrying).
# Extension: 1 once any extension request has arrived.
_NOTIFY_MODEL = b"com.goldentik.Sitr.Music.model"
_NOTIFY_EXTENSION = b"com.goldentik.Sitr.Music.extension"
_MODEL_PREPARING, _MODEL_READY, _MODEL_FAILED = 1, 2, 3
_WARMUP_RETRY_SECONDS = 30.0
_published: dict[bytes, int] = {}

# Seconds in a day — the cache TTL is configured in days but compared in seconds.
_SECONDS_PER_DAY = 86400.0


def _raise_open_file_limit() -> None:
    """Lift this process's open-file soft limit toward its hard limit.

    The MP3/MP4 export opens one ffmpeg ``-i`` input per chunk (pipeline/export.py),
    so a long video — a 45-min track is ~285 chunks at the default 9.5 s stride —
    can blow past the macOS default soft limit of 256 file descriptors and fail
    the export with an opaque ffmpeg error. ffmpeg inherits this process's
    rlimits, so raising the limit here covers the spawned subprocess too.
    Best-effort: any failure just leaves the default in place.
    """
    try:
        import resource
    except ImportError:
        return  # non-POSIX (Windows): no rlimits, and unsupported anyway.
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    except (ValueError, OSError):
        return
    # 8192 is comfortably above any realistic chunk count and well under macOS's
    # per-process ceiling (kern.maxfilesperproc); macOS also rejects an infinite
    # NOFILE, so cap to the concrete hard limit when it isn't unlimited.
    target = 8192
    if hard != resource.RLIM_INFINITY:
        target = min(target, hard)
    if soft >= target:
        return
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
        log.info("Raised open-file soft limit %d -> %d", soft, target)
    except (ValueError, OSError):
        log.debug("could not raise open-file limit from %d", soft, exc_info=True)


def _configure_logging() -> None:
    """Set up root logging once, at app/CLI startup rather than import time.

    NOMUSIC_DEBUG=1 raises the level to DEBUG, surfacing the verbose diagnostics
    (e.g. the progressive download/gate logs) that are otherwise hidden.
    """
    debug = os.environ.get("NOMUSIC_DEBUG", "").strip().lower() in (
        "1", "true", "yes", "on",
    )
    logging.basicConfig(
        level=logging.DEBUG if debug else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def _start_cache_ttl_sweeper(cache: JobCache) -> None:
    """Run an initial sweep, then schedule one every
    ``cache_sweep_interval_seconds``. Skipped entirely when TTL is 0.

    Lives in a daemon thread so it doesn't block server shutdown."""
    if SETTINGS.cache_ttl_days <= 0 or SETTINGS.cache_sweep_interval_seconds <= 0:
        log.info("Cache TTL sweep disabled (ttl_days=%s)", SETTINGS.cache_ttl_days)
        return

    ttl_seconds = SETTINGS.cache_ttl_days * _SECONDS_PER_DAY

    def _loop() -> None:
        while True:
            try:
                removed, freed = cache.sweep_older_than(ttl_seconds)
                if removed:
                    log.info(
                        "TTL sweep: removed %d entries, freed %d bytes",
                        removed,
                        freed,
                    )
            except Exception:
                # Daemon loop: one failed sweep must not kill the thread, or the
                # cache would stop being reclaimed for the server's lifetime.
                log.exception("TTL sweep failed")
            time.sleep(SETTINGS.cache_sweep_interval_seconds)

    t = threading.Thread(target=_loop, name="nomusic-cache-ttl", daemon=True)
    t.start()


def _start_memory_gc(registry: JobRegistry) -> None:
    """Periodically reclaim in-memory job entries whose disk cache is gone.

    Runs alongside the disk TTL sweeper on its own daemon thread, so the
    in-memory JobStatus map can't grow without bound on a long-lived server.
    Keyed to its own interval so a hosted deployment can GC aggressively
    without touching the disk-sweep cadence. ``0`` disables it."""
    interval = SETTINGS.memory_gc_interval_seconds
    if interval <= 0:
        log.info("Memory GC disabled (interval=%s)", interval)
        return

    def _loop() -> None:
        while True:
            time.sleep(interval)
            try:
                dropped = registry.memory_gc()
                if dropped:
                    log.info("Memory GC dropped %d stale in-memory job(s)", dropped)
            except Exception:
                # Daemon loop: swallow so a single failed pass doesn't stop all
                # future GC and let the in-memory job map grow unbounded.
                log.exception("Memory GC failed")

    t = threading.Thread(target=_loop, name="nomusic-memory-gc", daemon=True)
    t.start()


def _start_engine_warmup(engine) -> None:
    """Load the default model weights on a background thread at startup.

    The first separation otherwise pays a one-off model-load cost (weights
    fetch + MPS init, several seconds) on the user's first chunk. Warming up
    in the background means that cost is usually already paid by the time the
    first job reaches its separation phase, so first-chunk latency matches
    steady state. Best-effort: a failure here just falls back to lazy loading.
    """

    def _loop() -> None:
        # The first run downloads the model; retry until it succeeds so a Mac
        # that was offline at launch recovers without a restart.
        while True:
            _publish(_NOTIFY_MODEL, _MODEL_PREPARING)
            try:
                engine.warmup()
                _publish(_NOTIFY_MODEL, _MODEL_READY)
                log.info("Engine warmup complete")
                return
            except Exception:
                _publish(_NOTIFY_MODEL, _MODEL_FAILED)
                log.exception("Engine warmup failed; retrying in %.0fs", _WARMUP_RETRY_SECONDS)
                time.sleep(_WARMUP_RETRY_SECONDS)

    t = threading.Thread(target=_loop, name="nomusic-engine-warmup", daemon=True)
    t.start()


def _publish(name: bytes, value: int) -> None:
    """Set a Darwin notification state for Sitr and post it. Best-effort."""
    try:
        if name not in _published:
            _published[name] = _register_notify(name)[1]
        lib = ctypes.CDLL(None)
        lib.notify_set_state.argtypes = [ctypes.c_int, ctypes.c_uint64]
        lib.notify_post.argtypes = [ctypes.c_char_p]
        lib.notify_set_state(_published[name], value)
        lib.notify_post(name)
    except Exception:
        log.debug("notify publish failed for %r", name, exc_info=True)


def _register_notify(name: bytes = _SITR_MUSIC_NOTIFY):
    notify = ctypes.CDLL(None)
    notify.notify_register_check.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_int)]
    notify.notify_check.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
    notify.notify_get_state.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint64)]
    notify.notify_cancel.argtypes = [ctypes.c_int]
    token = ctypes.c_int()
    status = notify.notify_register_check(name, ctypes.byref(token))
    if status != 0:
        raise RuntimeError(f"notify_register_check failed: {status}")
    return notify, token.value


def _notify_enabled(notify, token: int) -> bool:
    state = ctypes.c_uint64()
    status = notify.notify_get_state(token, ctypes.byref(state))
    if status != 0:
        raise RuntimeError(f"notify_get_state failed: {status}")
    return state.value == 1


async def _watch_sitr_enabled(notify, token: int) -> None:
    try:
        if not _notify_enabled(notify, token):
            os.kill(os.getpid(), signal.SIGTERM)
            return
        while True:
            await asyncio.sleep(0.25)
            changed = ctypes.c_int()
            status = notify.notify_check(token, ctypes.byref(changed))
            if status != 0:
                raise RuntimeError(f"notify_check failed: {status}")
            if changed.value and not _notify_enabled(notify, token):
                os.kill(os.getpid(), signal.SIGTERM)
                return
    except Exception:
        log.exception("Managed helper lost Sitr notification; stopping")
        os.kill(os.getpid(), signal.SIGTERM)
    finally:
        notify.notify_cancel(token)


def _sitr_managed() -> bool:
    return "--sitr-standalone" not in sys.argv and (
        getattr(sys, "frozen", False) or "--sitr-managed" in sys.argv
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Capture the running event loop once at startup. Worker threads use it
    # (via call_soon_threadsafe) to push status snapshots onto SSE queues.
    app.state.registry.attach_loop(asyncio.get_running_loop())
    managed = _sitr_managed()
    task = None
    if managed:
        notify, token = _register_notify()
        task = asyncio.create_task(_watch_sitr_enabled(notify, token))
    try:
        yield
    finally:
        if task is not None:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)


def create_app() -> FastAPI:
    _configure_logging()
    _raise_open_file_limit()
    app = FastAPI(title="nomusic", version="0.2.0", lifespan=lifespan)

    # Every browser request must come from the extension service worker. A
    # native caller without Origin must opt in with a non-secret header, which
    # prevents plain image/navigation/form requests from starting GET exports.
    app.add_middleware(
        CORSMiddleware,
        allow_origin_regex=_EXTENSION_ORIGIN.pattern,
        allow_credentials=False,
        allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
        allow_headers=["*"],
        allow_private_network=True,
    )

    @app.middleware("http")
    async def extension_origin_only(request, call_next):
        # DNS rebinding: a page on evil.example can re-point its own name at
        # 127.0.0.1. Its same-origin GETs then carry no Origin header and may
        # set the client header freely, so the checks below would pass.
        # Clients always address us by loopback name, so reject any other Host.
        if request.url.hostname not in _LOOPBACK_HOSTS:
            return PlainTextResponse("Forbidden host", status_code=403)
        origin = request.headers.get("origin")
        if origin is not None:
            allowed = bool(_EXTENSION_ORIGIN.fullmatch(origin))
            if allowed and _NOTIFY_EXTENSION not in _published:
                _publish(_NOTIFY_EXTENSION, 1)
        else:
            allowed = request.headers.get("x-sitr-music-client") in ("extension", "native")
        if not allowed:
            return PlainTextResponse("Forbidden origin", status_code=403)
        return await call_next(request)

    engine = get_engine(SETTINGS.engine_name)
    cache = JobCache(SETTINGS.cache_dir)
    processor = Processor(
        engine=engine,
        cache=cache,
        chunk_seconds=SETTINGS.chunk_seconds,
        chunk_overlap_seconds=SETTINGS.chunk_overlap_seconds,
        keep_source_after_complete=SETTINGS.keep_source_after_complete,
        progressive=SETTINGS.progressive_download,
    )
    registry = JobRegistry(processor=processor, cache=cache)

    # Stash the shared services on app.state so the routers (and tests) reach
    # them via request.app.state instead of closing over create_app locals.
    app.state.engine = engine
    app.state.cache = cache
    app.state.registry = registry

    _start_cache_ttl_sweeper(cache)
    _start_memory_gc(registry)
    _start_engine_warmup(engine)

    app.include_router(system_router)
    app.include_router(jobs_router)
    app.include_router(media_router)
    return app


app = create_app()


def main() -> None:
    _configure_logging()

    import uvicorn

    # Dev convenience: NOMUSIC_RELOAD=1 watches backend/*.py and restarts on
    # save, so you don't re-run the server by hand on every change. Off by
    # default (the reloader spawns a watcher subprocess + re-imports the app,
    # which reloads the model — fine for dev, wasteful for normal use).
    reload = os.environ.get("NOMUSIC_RELOAD", "").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )
    log.info(
        "Starting nomusic backend on http://%s:%d (engine=%s%s)",
        SETTINGS.host,
        SETTINGS.port,
        SETTINGS.engine_name,
        " · auto-reload" if reload else "",
    )
    if reload:
        # uvicorn's reloader needs an import string (not the app object) so its
        # watcher subprocess can re-import on change. Put the backend dir on
        # PYTHONPATH so that subprocess resolves "server" no matter which cwd
        # the script was launched from (the README runs it from the repo root).
        os.environ["PYTHONPATH"] = (
            str(_BACKEND_DIR) + os.pathsep + os.environ.get("PYTHONPATH", "")
        )
        uvicorn.run(
            "server:app",
            host=SETTINGS.host,
            port=SETTINGS.port,
            reload=True,
            reload_dirs=[str(_BACKEND_DIR)],
            log_level="info",
            access_log=False,
        )
    else:
        uvicorn.run(
            app,
            host=SETTINGS.host,
            port=SETTINGS.port,
            log_level="info",
            access_log=False,
        )


if __name__ == "__main__":
    main()
