#!/usr/bin/env node

/**
 * Lemon Diagram Generator
 *
 * Converts Mermaid diagrams to SVG files using mermaid-cli.
 *
 * Usage:
 *   node generate.js                    # Generate all diagrams
 *   node generate.js architecture       # Generate specific diagram
 *   node generate.js --list             # List available diagrams
 */

import { execSync, spawn } from 'child_process';
import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync, copyFileSync } from 'fs';
import { join, basename } from 'path';
import { fileURLToPath } from 'url';
import { dirname } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const MERMAID_DIR = join(__dirname, 'mermaid');
const OUTPUT_DIR = join(__dirname, 'output');
const SVG_DIR = join(OUTPUT_DIR, 'svg');
const DOCS_DIR = join(__dirname, '..', '..', 'docs', 'diagrams');

// Mermaid config for better looking diagrams
const MERMAID_CONFIG = {
  theme: 'default',
  themeVariables: {
    primaryColor: '#fef08a',
    primaryTextColor: '#1f2937',
    primaryBorderColor: '#fbbf24',
    lineColor: '#6b7280',
    secondaryColor: '#e5e7eb',
    tertiaryColor: '#f3f4f6',
    fontSize: '14px',
  },
  flowchart: {
    htmlLabels: true,
    curve: 'basis',
    padding: 20,
    nodeSpacing: 50,
    rankSpacing: 50,
  }
};

// Ensure output directories exist
[OUTPUT_DIR, SVG_DIR, DOCS_DIR].forEach(dir => {
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
});

// Write mermaid config
const configPath = join(__dirname, 'mermaid-config.json');
writeFileSync(configPath, JSON.stringify(MERMAID_CONFIG, null, 2));

/**
 * Process a single Mermaid file using mmdc
 */
async function processDiagram(mermaidFile) {
  const name = basename(mermaidFile, '.mmd');
  const inputPath = join(MERMAID_DIR, mermaidFile);
  const outputPath = join(SVG_DIR, `${name}.svg`);
  const docsOutputPath = join(DOCS_DIR, `${name}.svg`);

  console.log(`Processing: ${name}`);

  try {
    // Use npx to run mmdc
    const mmdcPath = join(__dirname, 'node_modules', '.bin', 'mmdc');

    execSync(`"${mmdcPath}" -i "${inputPath}" -o "${outputPath}" -c "${configPath}" -b transparent`, {
      stdio: ['pipe', 'pipe', 'pipe'],
      timeout: 30000,
    });

    console.log(`  -> ${outputPath}`);

    // Copy to docs directory
    copyFileSync(outputPath, docsOutputPath);
    console.log(`  -> ${docsOutputPath}`);

    return { name, success: true };
  } catch (error) {
    console.error(`  Error: ${error.message}`);
    if (error.stderr) {
      console.error(`  stderr: ${error.stderr.toString()}`);
    }
    return { name, success: false, error: error.message };
  }
}

/**
 * List available diagrams
 */
function listDiagrams() {
  if (!existsSync(MERMAID_DIR)) {
    console.log('No mermaid directory found. Create diagrams in tools/diagrams/mermaid/');
    return [];
  }

  const files = readdirSync(MERMAID_DIR).filter(f => f.endsWith('.mmd'));
  console.log('Available diagrams:');
  files.forEach(f => console.log(`  - ${basename(f, '.mmd')}`));
  return files;
}

/**
 * Main entry point
 */
async function main() {
  const args = process.argv.slice(2);

  if (args.includes('--list') || args.includes('-l')) {
    listDiagrams();
    return;
  }

  if (args.includes('--help') || args.includes('-h')) {
    console.log(`
Lemon Diagram Generator

Usage:
  node generate.js                    Generate all diagrams
  node generate.js <name>             Generate specific diagram
  node generate.js --list             List available diagrams
  node generate.js --help             Show this help

Diagrams are defined as Mermaid files in tools/diagrams/mermaid/
Output is written to:
  - tools/diagrams/output/svg/  (working copies)
  - docs/diagrams/              (for README embedding)
`);
    return;
  }

  // Ensure mermaid directory exists
  if (!existsSync(MERMAID_DIR)) {
    mkdirSync(MERMAID_DIR, { recursive: true });
    console.log('Created mermaid directory. Add .mmd files to generate diagrams.');
    return;
  }

  // Get list of diagrams to process
  let files = readdirSync(MERMAID_DIR).filter(f => f.endsWith('.mmd'));

  if (args.length > 0 && !args[0].startsWith('-')) {
    // Filter to specific diagram
    const target = args[0];
    files = files.filter(f => basename(f, '.mmd') === target);
    if (files.length === 0) {
      console.error(`Diagram not found: ${target}`);
      console.log('Use --list to see available diagrams');
      process.exit(1);
    }
  }

  if (files.length === 0) {
    console.log('No diagrams found. Add .mmd files to tools/diagrams/mermaid/');
    return;
  }

  console.log(`Generating ${files.length} diagram(s)...\n`);

  const results = [];
  for (const file of files) {
    results.push(await processDiagram(file));
  }

  console.log('\nSummary:');
  const succeeded = results.filter(r => r.success).length;
  const failed = results.filter(r => !r.success).length;
  console.log(`  Succeeded: ${succeeded}`);
  if (failed > 0) {
    console.log(`  Failed: ${failed}`);
    results.filter(r => !r.success).forEach(r => {
      console.log(`    - ${r.name}: ${r.error}`);
    });
  }
}

main().catch(console.error);
