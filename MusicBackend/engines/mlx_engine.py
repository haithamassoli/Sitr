"""demucs source-separation engine (also registered under the alias ``demucs``).

The class name reads "MLX" because that's the strategic backend we want; the
*current* implementation runs htdemucs via the upstream ``demucs`` PyTorch
package on whatever torch device is available — Apple MPS, NVIDIA CUDA, or CPU,
auto-selected by :func:`_pick_device`. Swapping in a real MLX backend later
means replacing the ``_make_separator`` factory below — nothing else in the
codebase needs to change.

Why the indirection: source separation libraries change their APIs frequently.
Keeping the boundary at ``_make_separator`` lets tests stub the engine without
loading torch, and lets us pin a concrete backend per checkout.
"""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .base import DEMUCS_STEMS, Engine, EngineCapabilities, SeparationResult

log = logging.getLogger(__name__)

# Bundle one model so playback never waits for a first-run weight download.
_SUPPORTED_MODELS: tuple[str, ...] = (
    "htdemucs",
)
_DEFAULT_MODEL = "htdemucs"


@dataclass
class _Prepared:
    """Opaque ``prepare()`` output handed back to ``infer()``. Holds the decoded,
    normalized input plus what's needed to denormalize and label the result."""

    bundle: Any
    wav: Any  # torch.Tensor (channels, samples), normalized
    ref: Any  # torch.Tensor used to undo normalization
    sources: list[str]
    sample_rate: int
    name: str
    model_name: str


class MLXEngine(Engine):
    def __init__(
        self,
        separator_factory: Callable[[str, str], Any] | None = None,
    ) -> None:
        # Cached separator keyed by model name; demucs loads weights lazily and
        # we only want to pay that cost once per process.
        self._separators: dict[str, Any] = {}
        # Serializes the lazy load. Without it the startup warmup thread and the
        # first job's decode thread can both miss the cache and load the same
        # model concurrently — a duplicate weight download plus two copies pushed
        # to the GPU (transient ~2x memory), which matters most on a cold install
        # or a low-VRAM GPU. The per-job GPU lock doesn't cover this: warmup runs
        # outside it.
        self._load_lock = threading.Lock()
        # Serializes GPU use between the warmup pass (outside the jobs' GPU
        # lock) and real inference; concurrent MPS use from two threads is not
        # safe.
        self._infer_lock = threading.Lock()
        self._factory = separator_factory or _make_separator
        self._device = _pick_device()

    def capabilities(self) -> EngineCapabilities:
        return EngineCapabilities(
            name="mlx",
            device=f"{self._device} (via demucs)",
            supported_models=_SUPPORTED_MODELS,
            default_model=_DEFAULT_MODEL,
            supported_stems=DEMUCS_STEMS,
        )

    def warmup(self) -> None:
        bundle = self._ensure_loaded(_DEFAULT_MODEL)
        if self._device == "cpu":
            return
        # Loading weights isn't enough: the first forward pass on MPS/CUDA also
        # builds kernels (~0.7 s extra on an M3), which would otherwise land on
        # the user's first chunk. Run one silent segment to pay it here.
        import torch
        from demucs.apply import apply_model

        model = bundle.model
        x = torch.zeros(1, int(model.audio_channels), _single_pass_length(model))
        with self._infer_lock, torch.no_grad():
            apply_model(model, x, device=self._device, shifts=0, split=False,
                        progress=False, num_workers=0)

    def prepare(self, audio_path: Path, *, model: str | None = None) -> Any:
        """Decode + normalize ``audio_path`` into a model-ready input (CPU/IO).

        Split from :meth:`infer` so the pipeline can run this on a producer
        thread while the GPU is busy with another chunk. No GPU work here.
        """
        model_name = model or _DEFAULT_MODEL
        if model_name not in _SUPPORTED_MODELS:
            raise ValueError(
                f"Unknown model {model_name!r}. Supported: {_SUPPORTED_MODELS}"
            )

        bundle = self._ensure_loaded(model_name)

        from demucs.audio import AudioFile

        demucs_model = bundle.model
        sample_rate = int(demucs_model.samplerate)
        channels = int(demucs_model.audio_channels)
        sources: list[str] = list(demucs_model.sources)

        # The processor hands us a WAV already at the model's rate/layout, so
        # read it directly (~2 ms) instead of through ``AudioFile``, which spawns
        # ffprobe + ffmpeg (~100 ms per chunk). Anything else goes through
        # ``AudioFile`` to be resampled/remixed.
        wav = None
        try:
            import soundfile as sf
            import torch

            data, sr = sf.read(str(audio_path), dtype="float32", always_2d=True)
            if sr == sample_rate and data.shape[1] == channels:
                wav = torch.from_numpy(data.T.copy())
        except RuntimeError:
            pass  # not a libsndfile format; fall back to ffmpeg
        if wav is None:
            wav = AudioFile(audio_path).read(
                streams=0, samplerate=sample_rate, channels=channels
            )
        # Normalize to mean 0 / unit variance — demucs's own separate.py does the
        # same, and it noticeably improves quality on quiet inputs. Keep ``ref``
        # so :meth:`infer` can undo it.
        ref = wav.mean(0)
        wav = (wav - ref.mean()) / (ref.std() + 1e-8)
        return _Prepared(
            bundle=bundle,
            wav=wav,
            ref=ref,
            sources=sources,
            sample_rate=sample_rate,
            name=audio_path.name,
            model_name=model_name,
        )

    def infer_batch(self, prepared: list[Any]) -> list[SeparationResult]:
        """Run the model on a batch of :meth:`prepare` results (the GPU half).

        One ``apply_model`` call over the whole batch fills the GPU's cores that
        a single chunk leaves idle. Inputs may differ in length (the last chunk
        of a track is shorter); we zero-pad to the longest, then trim each output
        back. Each chunk keeps its own normalization ``ref``. Returns in-memory
        ``(samples, channels)`` float32 stems — no disk I/O.
        """
        import torch
        from demucs.apply import apply_model

        n = len(prepared)
        model = prepared[0].bundle.model
        lengths = [p.wav.shape[-1] for p in prepared]
        max_len = max(lengths)
        channels = prepared[0].wav.shape[0]
        log.info("Separating %d chunk(s) (%s) with %s on %s",
                 n, prepared[0].name, prepared[0].model_name, self._device)

        # Stack into (batch, channels, samples), zero-padding short members.
        x = torch.zeros(n, channels, max_len, dtype=prepared[0].wav.dtype)
        for i, p in enumerate(prepared):
            x[i, :, : lengths[i]] = p.wav

        # Only split when the input exceeds one model segment (7.8 s for
        # htdemucs). With split=True even a 7.8 s input takes two full passes,
        # because demucs steps windows by 75% of a segment.
        split = max_len > _single_pass_length(model)

        # Time only the inference call — the real accelerator work.
        with self._infer_lock:
            t_gpu0 = time.perf_counter()
            with torch.no_grad():
                estimates = apply_model(
                    model, x, device=self._device, shifts=0, split=split,
                    overlap=0.25, progress=False, num_workers=0,
                )
            # MPS and CUDA dispatch kernels asynchronously, so apply_model can
            # return before the GPU is done. Force a sync inside the timed
            # region or we'd measure only dispatch and wildly undercount. (CPU
            # is synchronous.)
            if self._device == "mps":
                sync = getattr(getattr(torch, "mps", None), "synchronize", None)
                if sync:
                    sync()
            elif self._device == "cuda":
                torch.cuda.synchronize()
            gpu_each = (time.perf_counter() - t_gpu0) / n

        results: list[SeparationResult] = []
        for i, p in enumerate(prepared):
            # Per-chunk denormalization, then trim off the zero-padding.
            est = estimates[i] * p.ref.std() + p.ref.mean()
            stems: dict[str, Any] = {}
            for stem_name, stem_tensor in zip(p.sources, est):
                arr = stem_tensor.detach().to("cpu").numpy().T  # (samples, channels)
                stems[stem_name] = arr[: lengths[i]]
                if stem_name not in DEMUCS_STEMS:
                    log.warning("Unexpected stem from %s: %s",
                                p.model_name, stem_name)
            sr = p.sample_rate
            results.append(SeparationResult(
                stems=stems,
                sample_rate=sr,
                duration_seconds=lengths[i] / sr if sr else 0.0,
                gpu_seconds=gpu_each,
            ))
        return results

    # -- internals -----------------------------------------------------------

    def _ensure_loaded(self, model_name: str) -> Any:
        # Double-checked: the fast path stays lock-free for the common
        # already-loaded case, and the lock only serializes the rare concurrent
        # first load (warmup vs first job) so the loser waits instead of
        # duplicating the download + GPU copy.
        cached = self._separators.get(model_name)
        if cached is not None:
            return cached
        with self._load_lock:
            cached = self._separators.get(model_name)
            if cached is not None:
                return cached
            log.info("Loading model %s on %s", model_name, self._device)
            sep = self._factory(model_name, self._device)
            self._separators[model_name] = sep
            return sep


def _single_pass_length(model: Any) -> int:
    """Longest input (samples) the model separates in one forward pass without
    ``split``: its training segment. Mirrors ``HTDemucs.valid_length``; a bag
    of models is limited by its shortest member."""
    members = getattr(model, "models", None) or [model]
    return min(int(m.segment * m.samplerate) for m in members)


def _pick_device() -> str:
    """Return the best torch device available on the current host.

    Priority: Apple MPS, then CUDA (NVIDIA), then CPU. A CUDA GPU is only chosen
    if this torch build actually ships kernels for its compute capability —
    otherwise inference crashes at launch ("no kernel image is available"), so
    we fall back to CPU instead.
    """
    try:
        import torch

        if torch.backends.mps.is_available():
            return "mps"
        if torch.cuda.is_available() and _cuda_is_usable(torch):
            return "cuda"
    except Exception:  # torch not installed yet
        log.debug("device probe failed; defaulting to CPU", exc_info=True)
    return "cpu"


def _arch_version(token: str) -> int | None:
    """Parse an arch token's numeric capability: ``"90"`` / ``"90a"`` -> ``90``.

    Torch emits architecture-specific entries with a trailing ``a``/``f`` (e.g.
    ``sm_90a``, ``sm_120a``, ``compute_90a``) from ``get_arch_list()``; mirror
    torch's own ``_extract_arch_version`` by stripping that suffix so these
    aren't silently dropped.
    """
    num = token.removesuffix("a").removesuffix("f")
    return int(num) if num.isdigit() else None


def _cuda_is_usable(torch: Any) -> bool:
    """True if this torch build can run kernels on the current CUDA GPU.

    Recent torch wheels drop older GPU architectures (e.g. Pascal / sm_61), so a
    *detectable* GPU isn't necessarily *usable*. Compare the device's compute
    capability against the wheel's built-in arch list, allowing same-major
    minor-version forward compatibility (an ``sm_80`` cubin runs on ``sm_86``)
    and forward PTX JIT (a ``compute_70`` PTX runs on anything ``>= 7.0``).

    This doesn't model torch's rare embedded-SKU exclusions (e.g. sm_87 Jetson
    Orin vs an sm_80/86 build), so a few uncommon embedded GPUs could be wrongly
    accepted; the common too-old-GPU case (the one this guards) is handled.
    """
    try:
        major, minor = torch.cuda.get_device_capability()
        dev = major * 10 + minor
        archs = torch.cuda.get_arch_list()
    except Exception:
        return True  # can't introspect — let torch try
    reals, ptx = [], []
    for a in archs:
        if a.startswith("sm_"):
            n = _arch_version(a[3:])
            if n is not None:
                reals.append(n)
        elif a.startswith("compute_"):
            n = _arch_version(a[8:])
            if n is not None:
                ptx.append(n)
    if any(r // 10 == dev // 10 and dev >= r for r in reals):
        return True
    if any(dev >= p for p in ptx):
        return True
    if reals or ptx:
        log.warning(
            "CUDA GPU (sm_%d%d) is not supported by this torch build "
            "(arch list: %s) — falling back to CPU. Install a torch build that "
            "targets your GPU to use it.",
            major, minor, ", ".join(archs),
        )
        return False
    return True  # empty/odd arch list — let torch try rather than guess


class _ModelBundle:
    """Holds a pretrained demucs model bound to a device. The wrapper exists
    so the cache key in ``MLXEngine._separators`` is a single object that's
    cheap to swap."""

    def __init__(self, model_name: str, device: str) -> None:
        # Weights are not redistributed: fetch them once from Meta's server
        # into the torch hub cache. torch.hub checks the hash prefix in the file
        # name (955717e8-8726e21a.th). demucs >= 4.1 ``get_model`` would try the
        # unpinned Hugging Face repo first, so use its legacy repo directly.
        from demucs.pretrained import REMOTE_ROOT, _parse_remote_files
        from demucs.repo import AnyModelRepo, BagOnlyRepo, RemoteRepo

        remote = RemoteRepo(_parse_remote_files(REMOTE_ROOT / "files.txt"))
        self.model = AnyModelRepo(remote, BagOnlyRepo(REMOTE_ROOT, remote)).get_model(model_name)
        self.model.eval()
        self.model.to(device)
        self.model.eval()
        self.device = device


def _make_separator(model_name: str, device: str) -> Any:
    return _ModelBundle(model_name, device)
