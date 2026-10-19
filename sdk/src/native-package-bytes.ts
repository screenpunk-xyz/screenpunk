import { fail } from "./native-package-json.js";

const typedArrayPrototype = Object.getPrototypeOf(Uint8Array.prototype);
const storageGetters = ["buffer", "byteOffset", "byteLength"].map(
  (key) => Object.getOwnPropertyDescriptor(typedArrayPrototype, key)!.get!,
);
const rawSet = Uint8Array.prototype.set;
export function rawByteView(data: Uint8Array, path: string): Uint8Array {
  try {
    const buffer = Reflect.apply(storageGetters[0], data, []) as ArrayBuffer;
    const offset = Reflect.apply(storageGetters[1], data, []) as number;
    const length = Reflect.apply(storageGetters[2], data, []) as number;
    if (buffer instanceof SharedArrayBuffer)
      fail(
        "representation",
        path,
        "shared mutable byte storage cannot be snapshotted reproducibly",
      );
    return new Uint8Array(buffer, offset, length);
  } catch (error) {
    if (error instanceof Error && error.name === "NativePackageError")
      throw error;
    return fail(
      "representation",
      path,
      "expected intrinsic typed-array byte storage",
    );
  }
}
export function copyBytes(view: Uint8Array): Uint8Array {
  const output = new Uint8Array(Reflect.apply(storageGetters[2], view, []));
  Reflect.apply(rawSet, output, [view]);
  return output;
}
