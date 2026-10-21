import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const directory = resolve(process.argv[2] ?? "dist");
const arch = process.argv[3] ?? process.arch;
assert.equal(process.platform, "darwin", "Run macOS validation on macOS");
assert.equal(process.arch, arch, "Run release validation in a native target process");
const machoArch = { arm64: "arm64", x64: "x86_64" }[arch];
assert.ok(machoArch, `Unsupported macOS architecture ${arch}`);
assert.equal(execFileSync("uname", ["-m"], { encoding: "utf8" }).trim(), machoArch);

const cli = join(directory, "zig-asar");
const library = join(directory, "libasar.dylib");
for (const binary of [cli, library]) {
  assert.equal(execFileSync("lipo", ["-archs", binary], { encoding: "utf8" }).trim(), machoArch);
  const commands = execFileSync("otool", ["-l", binary], { encoding: "utf8" });
  assert.equal(commands.match(/\bminos\s+(\S+)/)?.[1], "14.0", `${binary} deployment target`);
  const dependencies = execFileSync("otool", ["-L", binary], { encoding: "utf8" }).trim().split("\n").slice(1);
  for (const line of dependencies) {
    const name = line.trim().split(/\s/, 1)[0];
    assert.ok(name.startsWith("/usr/lib/") || name.startsWith("/System/Library/") ||
      (binary === library && name === "@rpath/libasar.dylib"), `${binary} has non-system dependency ${name}`);
  }
}
const exports = execFileSync("nm", ["-gjU", library], { encoding: "utf8" }).trim().split("\n").sort();
const expectedExports = readFileSync(new URL("asar-exported-symbols.txt", import.meta.url), "utf8").trim().split("\n").sort();
assert.deepEqual(exports, expectedExports, "Only the public C API is exported");

const temporary = mkdtempSync(join(tmpdir(), "zig-asar-release-"));
try {
  const source = join(temporary, "source");
  const payload = Buffer.from([0, 1, 2, 127, 128, 254, 255]);
  const native = Buffer.from("unpacked native module fixture\n");
  mkdirSync(join(source, "nested"), { recursive: true });
  writeFileSync(join(source, "nested/payload.bin"), payload);
  writeFileSync(join(source, "native.node"), native);
  const cliArchive = join(temporary, "cli.asar");
  const ffiArchive = join(temporary, "ffi.asar");
  execFileSync(cli, ["pack", source, cliArchive, "--unpack", "*.node"], { stdio: "inherit" });
  assert.match(execFileSync(cli, ["list", cliArchive], { encoding: "utf8" }), /nested\/payload\.bin/);
  assert.deepEqual(execFileSync(cli, ["extract", cliArchive, "nested/payload.bin"]), payload);
  assert.deepEqual(readFileSync(`${cliArchive}.unpacked/native.node`), native);

  // Link with Apple's toolchain, as Electrobun does, instead of only dlopening.
  // This catches accidental linker-private exports as well as C ABI defects.
  const smoke = join(temporary, "ffi-smoke");
  execFileSync("clang", ["-arch", machoArch, "-mmacosx-version-min=14.0",
    fileURLToPath(new URL("test-release-ffi.c", import.meta.url)),
    "-L", directory, `-Wl,-rpath,${directory}`, "-lasar", "-o", smoke], { stdio: "inherit" });
  execFileSync(smoke, [source, cliArchive, ffiArchive], { stdio: "inherit" });
  assert.deepEqual(readFileSync(`${ffiArchive}.unpacked/native.node`), native);

  // Sign a copy to exercise the Intel Mach-O header padding without changing
  // the immutable release file used above.
  const signedLibrary = join(temporary, "libasar.dylib");
  copyFileSync(library, signedLibrary);
  execFileSync("codesign", ["--force", "--sign", "-", signedLibrary], { stdio: "inherit" });
  execFileSync("codesign", ["--verify", "--strict", signedLibrary], { stdio: "inherit" });
  console.log(`Validated ${arch} macOS release: CLI, C ABI, deployment target, linkage, exports and signing`);
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
