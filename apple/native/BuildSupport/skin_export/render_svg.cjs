// Offline rendering of reviewed vector source; no remote assets or scripts.
const fs = require('fs');
const { Resvg } = require(process.env.VETA_RESVG_MODULE || '@resvg/resvg-js');
const svg = fs.readFileSync(process.argv[2]);
const renderer = new Resvg(svg, {font: {loadSystemFonts: true, defaultFontFamily: 'Arial'}});
fs.writeFileSync(process.argv[3], renderer.render().asPng());
