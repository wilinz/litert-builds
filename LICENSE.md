# Licence

The build script and the workflow in this repository are Apache-2.0.

What they produce is TensorFlow Lite, which is Apache-2.0 and belongs to the
TensorFlow authors. Nothing here modifies it: the sources are cloned at the tag
`tflite.toml` names and compiled unchanged. Each release carries a `.build`
file naming the version, the commit of this repository that produced it, the
compiler, and the checksums.
