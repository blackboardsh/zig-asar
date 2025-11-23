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
  // Windows uses 'asar.dll', Unix uses 'libasar.{dylib,so}'
  // Windows may put DLL in bin/ instead of lib/
  const libNameInZigOut = platform === 'win32' ? 'asar' : 'libasar';
  const libNameInDist = 'libasar'; // Always use libasar for consistency

  // On Windows, try both lib/ and bin/ directories
  const possibleLibPaths = platform === 'win32'
    ? [join(zigOutLib, libNameInZigOut + libExt), join(zigOutBin, libNameInZigOut + libExt)]
    : [join(zigOutLib, libNameInZigOut + libExt)];

  let libSrc = null;
  for (const path of possibleLibPaths) {
    try {
      await access(path);
      libSrc = path;
      break;
    } catch {
      // Continue searching
    }
  }

  if (!libSrc) {
    const searchedPaths = possibleLibPaths.map(p => `  - ${p}`).join('\n');
    console.error(`✗ Could not find library. Searched:\n${searchedPaths}`);
    throw new Error(`Failed to find ${libNameInZigOut}${libExt}. Make sure to run 'zig build -Doptimize=ReleaseFast' first.`);
  }

  const libDest = join(distDir, libNameInDist + libExt);
  await copyFile(libSrc, libDest);
  console.log(`✓ Copied ${libNameInZigOut}${libExt} -> ${libNameInDist}${libExt} to dist/`);
  console.log(`  Source: ${libSrc}`);

  // On Windows, also copy the .lib import library (needed for linking)
  if (platform === 'win32') {
    const importLibName = libNameInZigOut + '.lib';
    const possibleImportLibPaths = [
      join(zigOutLib, importLibName),
      join(zigOutBin, importLibName)
    ];

    let importLibSrc = null;
    for (const path of possibleImportLibPaths) {
      try {
        await access(path);
        importLibSrc = path;
        break;
      } catch {
        // Continue searching
      }
    }

    if (importLibSrc) {
      const importLibDest = join(distDir, libNameInDist + '.lib');
      await copyFile(importLibSrc, importLibDest);
      console.log(`✓ Copied ${importLibName} -> ${libNameInDist}.lib to dist/`);
      console.log(`  Source: ${importLibSrc}`);
    } else {
      console.warn(`⚠️  Warning: Could not find ${importLibName}. Linking against this library may not work.`);
      console.warn(`  Searched:\n${possibleImportLibPaths.map(p => `    - ${p}`).join('\n')}`);
    }
  }

  console.log('\n✓ Binaries packaged successfully!');
  console.log(`  Platform: ${platform}`);
  console.log(`  CLI: ${cliBin}${binExt}`);
  console.log(`  Library: ${libNameInDist}${libExt}`);
  if (platform === 'win32') {
    console.log(`  Import Library: ${libNameInDist}.lib`);
  }
}

packageBinaries().catch(err => {
  console.error('Error packaging binaries:', err);
  process.exit(1);
});
