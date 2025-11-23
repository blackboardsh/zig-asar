import { test, expect } from "bun:test";
import { execSync } from "child_process";
import { existsSync, mkdirSync, writeFileSync, rmSync } from "fs";
import { join } from "path";

test("zig-asar CLI is available", () => {
  const result = execSync("zig-out/bin/zig-asar").toString();
  expect(result).toContain("zig-asar - ASAR archive tool");
});

test("pack and extract basic archive", () => {
  const testDir = "/tmp/zig-asar-test";
  const asarPath = "/tmp/test-archive.asar";

  // Clean up
  if (existsSync(testDir)) rmSync(testDir, { recursive: true });
  if (existsSync(asarPath)) rmSync(asarPath);

  // Create test files
  mkdirSync(testDir, { recursive: true });
  mkdirSync(join(testDir, "subdir"), { recursive: true });
  writeFileSync(join(testDir, "test.txt"), "Hello ASAR!");
  writeFileSync(join(testDir, "subdir", "nested.txt"), "Nested content");

  // Pack
  execSync(`zig-out/bin/zig-asar pack ${testDir} ${asarPath}`);
  expect(existsSync(asarPath)).toBe(true);

  // Extract and verify
  const extracted = execSync(`zig-out/bin/zig-asar extract ${asarPath} test.txt`).toString();
  expect(extracted).toBe("Hello ASAR!");

  const extractedNested = execSync(`zig-out/bin/zig-asar extract ${asarPath} subdir/nested.txt`).toString();
  expect(extractedNested).toBe("Nested content");

  // Clean up
  rmSync(testDir, { recursive: true });
  rmSync(asarPath);
});

test("unpack pattern excludes files", () => {
  const testDir = "/tmp/zig-asar-unpack-test";
  const asarPath = "/tmp/test-unpack.asar";
  const unpackedDir = asarPath + ".unpacked";

  // Clean up
  if (existsSync(testDir)) rmSync(testDir, { recursive: true });
  if (existsSync(asarPath)) rmSync(asarPath);
  if (existsSync(unpackedDir)) rmSync(unpackedDir, { recursive: true });

  // Create test files
  mkdirSync(testDir, { recursive: true });
  writeFileSync(join(testDir, "regular.txt"), "Regular file");
  writeFileSync(join(testDir, "native.node"), "Native module");

  // Pack with unpack pattern
  execSync(`zig-out/bin/zig-asar pack ${testDir} ${asarPath} --unpack "*.node"`);
  
  expect(existsSync(asarPath)).toBe(true);
  expect(existsSync(unpackedDir)).toBe(true);
  expect(existsSync(join(unpackedDir, "native.node"))).toBe(true);

  // Clean up
  rmSync(testDir, { recursive: true });
  rmSync(asarPath);
  rmSync(unpackedDir, { recursive: true });
});
