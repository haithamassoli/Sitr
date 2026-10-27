"""coremltools 9.0 torch-frontend fixes shared by convert_detr.py and convert_yolov9.py (imported for side effects)."""
import numpy as np
# coremltools 9.0 `int(t)` on a folded shape-[1] constant calls int(ndarray) and fails; take the item first.
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch import ops as _tops
from coremltools.converters.mil.frontend.torch.torch_op_registry import _TORCH_OPS_REGISTRY
_orig_cast = _tops._cast


def _cast(context, node, dtype, dtype_name):
    x = _tops._get_inputs(context, node, expected=1)[0]
    if x.can_be_folded_to_const() and isinstance(x.val, np.ndarray) and x.val.size == 1:
        context.add(mb.const(val=dtype(x.val.item()), name=node.name), node.name)
    else:
        _orig_cast(context, node, dtype, dtype_name)


_tops._cast = _cast


# Sine position embeddings trace as outer(arange, omega); coremltools types the arange int32 and the matmul rejects the mix.
@_tops.register_torch_op(override=True)
def outer(context, node):
    x, y = (mb.cast(x=v, dtype="fp32") for v in _tops._get_inputs(context, node, expected=2))
    context.add(mb.matmul(x=mb.reshape(x=x, shape=[-1, 1]), y=mb.reshape(x=y, shape=[1, -1]), name=node.name))


_orig_linear = _TORCH_OPS_REGISTRY["linear"]


# D-FINE's distribution integral is F.linear(probs, project) with a 1-D `project`: a dot product on the last axis.
@_tops.register_torch_op(override=True)
def linear(context, node):
    inputs = _tops._get_inputs(context, node, expected=[2, 3])
    if inputs[1].rank != 1 or (len(inputs) == 3 and inputs[2] is not None):
        return _orig_linear(context, node)
    w = mb.expand_dims(x=mb.cast(x=inputs[1], dtype="fp32"), axes=[-1])
    context.add(mb.squeeze(x=mb.matmul(x=inputs[0], y=w), axes=[-1], name=node.name))
