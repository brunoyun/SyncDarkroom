# Converts OpenCV Zoo SFace (face_recognition_sface_2021dec.onnx, Apache-2.0,
# sha256 0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79) to Core ML.
# Usage: pip install torch onnx onnx2torch coremltools pillow
#        python scripts/convert_sface.py face_recognition_sface_2021dec.onnx SyncDarkroom/Resources/ML/sface.mlpackage
import onnx, torch, coremltools as ct, numpy as np, sys
from onnx2torch import convert
m = onnx.load(sys.argv[1])
print("inputs", [(i.name, [d.dim_value for d in i.type.tensor_type.shape.dim]) for i in m.graph.input])
print("outputs", [(o.name, [d.dim_value for d in o.type.tensor_type.shape.dim]) for o in m.graph.output])
tm = convert(m).eval()
x = torch.rand(1, 3, 112, 112) * 255
with torch.no_grad(): ref = tm(x)
traced = torch.jit.trace(tm, x)
mlm = ct.convert(traced, inputs=[ct.ImageType(name="face", shape=(1, 3, 112, 112), scale=1.0, bias=[0, 0, 0], color_layout=ct.colorlayout.RGB)],
                 outputs=[ct.TensorType(name="embedding")], minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16)
mlm.short_description = "SFace face recognition (OpenCV Zoo, Apache-2.0). Input: 112x112 RGB face aligned to the ArcFace template. Output: 128-d embedding."
mlm.save(sys.argv[2])
# check vs onnx-torch reference
from PIL import Image
img = Image.fromarray(x[0].permute(1,2,0).numpy().astype(np.uint8))
ref2 = tm(torch.from_numpy(np.array(img)).permute(2,0,1).float().unsqueeze(0)).detach().numpy().ravel()
out = list(mlm.predict({"face": img}).values())[0].ravel()
print("cosine coreml vs torch:", float(np.dot(out, ref2) / np.linalg.norm(out) / np.linalg.norm(ref2)))
