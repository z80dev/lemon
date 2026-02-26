#!/usr/bin/env node
/**
 * Export Excalidraw JSON files to SVG using simple SVG generation.
 * This generates clean SVG without the hand-drawn effect since that requires
 * the full Excalidraw rendering engine.
 *
 * Usage: node export-excalidraw.js [diagram-name]
 *
 * For hand-drawn SVG export:
 * 1. Open docs/diagrams/*.excalidraw in https://excalidraw.com
 * 2. Export as SVG from the menu
 * 3. Save to docs/diagrams/*.svg
 */

import { readFileSync, writeFileSync, readdirSync } from 'fs';
import { join, basename } from 'path';

const DOCS_DIR = join(import.meta.dirname, '../../docs/diagrams');

function parseExcalidraw(filePath) {
  const content = readFileSync(filePath, 'utf-8');
  return JSON.parse(content);
}

function getBounds(elements) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;

  for (const el of elements) {
    if (el.x !== undefined && el.y !== undefined) {
      minX = Math.min(minX, el.x);
      minY = Math.min(minY, el.y);
      maxX = Math.max(maxX, el.x + (el.width || 0));
      maxY = Math.max(maxY, el.y + (el.height || 0));
    }
    // Handle arrows and lines with points
    if (el.points) {
      for (const [px, py] of el.points) {
        minX = Math.min(minX, el.x + px);
        minY = Math.min(minY, el.y + py);
        maxX = Math.max(maxX, el.x + px);
        maxY = Math.max(maxY, el.y + py);
      }
    }
  }

  return { minX, minY, maxX, maxY };
}

function renderElement(el) {
  const roughness = el.roughness || 1;

  switch (el.type) {
    case 'rectangle': {
      const rx = (el.roundness?.type === 3) ? 8 : 0;
      return `<rect x="${el.x}" y="${el.y}" width="${el.width}" height="${el.height}"
        rx="${rx}" ry="${rx}"
        fill="${el.backgroundColor || 'none'}"
        stroke="${el.strokeColor || '#000'}"
        stroke-width="${el.strokeWidth || 1}"/>`;
    }

    case 'text': {
      const lines = (el.text || '').split('\n');
      const fontSize = el.fontSize || 14;
      const lineHeight = fontSize * 1.2;
      const textContent = lines.map((line, i) => {
        const y = el.y + fontSize + (i * lineHeight);
        let x = el.x;
        let anchor = 'start';
        if (el.textAlign === 'center') {
          x = el.x + (el.width || 0) / 2;
          anchor = 'middle';
        } else if (el.textAlign === 'right') {
          x = el.x + (el.width || 0);
          anchor = 'end';
        }
        return `<tspan x="${x}" y="${y}" text-anchor="${anchor}">${escapeXml(line)}</tspan>`;
      }).join('');

      return `<text font-family="Virgil, Segoe UI Emoji, sans-serif" font-size="${fontSize}px"
        fill="${el.strokeColor || '#000'}">${textContent}</text>`;
    }

    case 'line': {
      if (!el.points || el.points.length < 2) return '';
      const pathD = el.points.map((p, i) =>
        `${i === 0 ? 'M' : 'L'} ${el.x + p[0]} ${el.y + p[1]}`
      ).join(' ');
      return `<path d="${pathD}" fill="none" stroke="${el.strokeColor || '#000'}"
        stroke-width="${el.strokeWidth || 1}"/>`;
    }

    case 'arrow': {
      if (!el.points || el.points.length < 2) return '';
      const [start, end] = [el.points[0], el.points[el.points.length - 1]];
      const startX = el.x + start[0];
      const startY = el.y + start[1];
      const endX = el.x + end[0];
      const endY = el.y + end[1];

      // Calculate arrowhead
      const angle = Math.atan2(endY - startY, endX - startX);
      const arrowLen = 10;
      const arrowAngle = Math.PI / 6;
      const ax1 = endX - arrowLen * Math.cos(angle - arrowAngle);
      const ay1 = endY - arrowLen * Math.sin(angle - arrowAngle);
      const ax2 = endX - arrowLen * Math.cos(angle + arrowAngle);
      const ay2 = endY - arrowLen * Math.sin(angle + arrowAngle);

      return `<path d="M ${startX} ${startY} L ${endX} ${endY}" fill="none"
        stroke="${el.strokeColor || '#000'}" stroke-width="${el.strokeWidth || 1}"/>
        <path d="M ${ax1} ${ay1} L ${endX} ${endY} L ${ax2} ${ay2}" fill="none"
        stroke="${el.strokeColor || '#000'}" stroke-width="${el.strokeWidth || 1}"/>`;
    }

    default:
      return '';
  }
}

function escapeXml(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

function generateSVG(excalidrawData) {
  const elements = excalidrawData.elements || [];
  const bounds = getBounds(elements);
  const padding = 20;
  const width = bounds.maxX - bounds.minX + padding * 2;
  const height = bounds.maxY - bounds.minY + padding * 2;

  // Sort elements: rectangles first (background), then lines, then text (foreground)
  const sortedElements = [...elements].sort((a, b) => {
    const order = { rectangle: 0, line: 1, arrow: 1, text: 2 };
    return (order[a.type] || 1) - (order[b.type] || 1);
  });

  // Offset all elements so the diagram starts at (padding, padding)
  const offsetElements = sortedElements.map(el => ({
    ...el,
    x: (el.x || 0) - bounds.minX + padding,
    y: (el.y || 0) - bounds.minY + padding,
  }));

  const bgColor = excalidrawData.appState?.viewBackgroundColor || '#ffffff';

  const svgContent = offsetElements.map(renderElement).filter(Boolean).join('\n  ');

  return `<svg version="1.1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}">
<!-- svg-source:excalidraw -->
<rect x="0" y="0" width="${width}" height="${height}" fill="${bgColor}"/>
  ${svgContent}
</svg>`;
}

function exportDiagram(name) {
  const inputPath = join(DOCS_DIR, `${name}.excalidraw`);
  const outputPath = join(DOCS_DIR, `${name}.svg`);

  try {
    const data = parseExcalidraw(inputPath);
    const svg = generateSVG(data);
    writeFileSync(outputPath, svg);
    console.log(`✓ Exported ${name}.svg`);
    return true;
  } catch (error) {
    console.error(`✗ Failed to export ${name}: ${error.message}`);
    return false;
  }
}

function listDiagrams() {
  const files = readdirSync(DOCS_DIR);
  return files
    .filter(f => f.endsWith('.excalidraw'))
    .map(f => basename(f, '.excalidraw'));
}

// Main
const args = process.argv.slice(2);

if (args.includes('--help') || args.includes('-h')) {
  console.log(`
Export Excalidraw JSON files to SVG

Usage:
  node export-excalidraw.js [diagram-name]   Export specific diagram
  node export-excalidraw.js                  Export all diagrams
  node export-excalidraw.js --list           List available diagrams

Note: For hand-drawn SVG export, open the .excalidraw files in
https://excalidraw.com and export manually from the menu.
`);
  process.exit(0);
}

if (args.includes('--list')) {
  console.log('Available diagrams:');
  listDiagrams().forEach(d => console.log(`  - ${d}`));
  process.exit(0);
}

const diagrams = args.length > 0 ? args : listDiagrams();
let success = 0, failed = 0;

for (const diagram of diagrams) {
  if (exportDiagram(diagram)) {
    success++;
  } else {
    failed++;
  }
}

console.log(`\nExported ${success} diagram(s)${failed > 0 ? `, ${failed} failed` : ''}`);
