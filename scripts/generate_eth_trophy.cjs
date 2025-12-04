const fs = require("fs");
const path = require("path");

const iconData = require("./data/icons32Data.json");

const BASE_COLORS = ["#f409cd", "#7c2bff", "#30d100", "#ed0e11", "#1317f7", "#f7931a", "#5e5e5e", "#ab8d3f"];
const RATIO_MID = 0.78;
const RATIO_IN = 0.62;

function isCryptoShrinkTarget(symbolIdx) {
  return symbolIdx === 0 || symbolIdx === 1 || symbolIdx === 4;
}

function isZodiacShrinkTarget(symbolIdx) {
  return symbolIdx >= 1 && symbolIdx <= 7;
}

function isGamblingShrinkTarget(symbolIdx) {
  return symbolIdx === 0 || symbolIdx === 6;
}

function symbolFitScale(quadrant, symbolIdx) {
  let fit;
  if (quadrant === 0 && (symbolIdx === 3 || symbolIdx === 7)) {
    fit = 1.03;
  } else if (quadrant === 1 && symbolIdx === 6) {
    fit = 0.6;
  } else {
    fit = 0.8;
  }

  if (quadrant === 1 && isZodiacShrinkTarget(symbolIdx)) {
    fit *= 0.9;
  } else if (quadrant === 0 && isCryptoShrinkTarget(symbolIdx)) {
    fit *= 0.85;
  } else if (quadrant === 2) {
    if (isGamblingShrinkTarget(symbolIdx)) {
      fit *= 0.9;
    } else if (symbolIdx === 1) {
      fit *= 1.15;
    }
  } else if (quadrant === 3) {
    if (symbolIdx !== 6 && symbolIdx !== 7) {
      fit *= 0.9;
    }
  }

  return fit;
}

function buildBadgeSvg(quadrant, colorIdx, symbolIdx, iconData) {
  const outerColor = BASE_COLORS[colorIdx] || "#888888";
  const midColor = "#111111";
  const innerColor = "#ffffff";
  const ICON_VB = 512;
  const CENTER = 256;
  const OUTER_RADIUS = CENTER;
  const MID_RADIUS = Math.round(OUTER_RADIUS * RATIO_MID);
  const INNER_RADIUS = Math.round(OUTER_RADIUS * RATIO_IN);
  const iconIndex = quadrant * 8 + symbolIdx;
  const pathMarkup = iconData.paths[iconIndex] || "";
  const vbW = ICON_VB;
  const vbH = ICON_VB;
  const symbolScale = symbolFitScale(quadrant, symbolIdx);
  const maxDim = Math.max(vbW, vbH) || 1;
  const scale = (2 * INNER_RADIUS * symbolScale) / maxDim;
  const tx = CENTER - (vbW * scale) / 2;
  const ty = CENTER - (vbH * scale) / 2;
  const transform = `matrix(${scale} 0 0 ${scale} ${tx} ${ty})`;
  const requiresSolidFill = quadrant === 0 && (symbolIdx === 1 || symbolIdx === 5);
  const strokeColor = requiresSolidFill ? "none" : outerColor;
  const symbolGroup = `<g fill="${outerColor}" stroke="${strokeColor}" style="vector-effect:non-scaling-stroke">${pathMarkup}</g>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${CENTER * 2} ${CENTER * 2}">
<circle cx="${CENTER}" cy="${CENTER}" r="${OUTER_RADIUS}" fill="${outerColor}"/>
<circle cx="${CENTER}" cy="${CENTER}" r="${MID_RADIUS}" fill="${midColor}"/>
<circle cx="${CENTER}" cy="${CENTER}" r="${INNER_RADIUS}" fill="${innerColor}"/>
<g transform="${transform}">${symbolGroup}</g>
</svg>`;
}

const quadrant = 0; // Q1
const colorIdx = 2; // Green
const symbolIdx = 6; // Ethereum

const svg = buildBadgeSvg(quadrant, colorIdx, symbolIdx, iconData);
console.log(svg);
