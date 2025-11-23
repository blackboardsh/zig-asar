#!/usr/bin/env node
/**
 * Package binaries for distribution
 * Copies the built binaries from zig-out/ to dist/
 */

import { mkdir, copyFile, access } from 'fs/promises';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const rootDir = join(__dirname, '..');

const platform = process.platform;
const libExt = platform === 'win32' ? '.dll' : platform === 'darwin' ? '.dylib' : '.so';
const binExt = platform === 'win32' ? '.exe' : '';

async function packageBinaries() {
  const distDir = join(rootDir, 'dist');
  const zigOutBin = join(rootDir, 'zig-out', 'bin');
  const zigOutLib = join(rootDir, 'zig-out', 'lib');

  // Create dist directory
  await mkdir(distDir, { recursive: true });

  // Copy CLI binary
  const cliBin = 'zig-asar';
  const cliSrc = join(zigOutBin, cliBin + binExt);
  const cliDest = join(distDir, cliBin + binExt);

  try {
    await access(cliSrc);
    await copyFile(cliSrc, cliDest);
    console.log(`✓ Copied ${cliBin}${binExt} to dist/`);
  } catch (err) {
    console.error(`✗ Could not copy ${cliBin}${binExt}:`, err.message);
    throw new Error(`Failed to package ${cliBin}${binExt}. Make sure to run 'zig build -Doptimize=ReleaseFast' first.`);
  }

  // Copy dynamic library
  const libName = 'libasar';
  const libSrc = join(zigOutLib, libName + libExt);
  const libDest = join(distDir, libName + libExt);

  try {
    await access(libSrc);
    await copyFile(libSrc, libDest);
    console.log(`✓ Copied ${libName}${libExt} to dist/`);
  } catch (err) {
    console.error(`✗ Could not copy ${libName}${libExt}:`, err.message);
    throw new Error(`Failed to package ${libName}${libExt}. Make sure to run 'zig build -Doptimize=ReleaseFast' first.`);
  }

  console.log('\n✓ Binaries packaged successfully!');
  console.log(`  Platform: ${platform}`);
  console.log(`  CLI: ${cliBin}${binExt}`);
  console.log(`  Library: ${libName}${libExt}`);
}

packageBinaries().catch(err => {
  console.error('Error packaging binaries:', err);
  process.exit(1);
});
