#!/usr/bin/env node
/**
 * Azure Sandbox Lifecycle — architecture diagram generator.
 *
 * Produces a self-contained .html file (official Azure service icons inlined as
 * base64 SVG data URIs) that can be rendered to PNG with render-png.js.
 *
 * Icons come from the Azure public service icon pack. Point AZURE_ICON_ZIP at it,
 * or drop it in ~/Downloads. Download: https://learn.microsoft.com/azure/architecture/icons/
 *
 * Install deps in this directory first:  npm install adm-zip
 */
const fs = require('fs');
const path = require('path');
const AdmZip = require('adm-zip');

const ICON_ZIP = process.env.AZURE_ICON_ZIP
  || path.join(process.env.USERPROFILE || process.env.HOME || '.',
    '.copilot', 'installed-plugins', 'csa-skills', 'csa-skills', 'skills',
    'csa-azure-diagrams', 'Azure_Public_Service_Icons_V23.zip');
const OUTPUT_DIR = __dirname;

function resolveIconZip() {
  if (fs.existsSync(ICON_ZIP)) return ICON_ZIP;
  const dl = path.join(process.env.USERPROFILE || process.env.HOME || '.', 'Downloads');
  if (fs.existsSync(dl)) {
    const hit = fs.readdirSync(dl)
      .filter(f => /^Azure_Public_Service_Icons_V.*\.zip$/i.test(f))
      .sort().reverse()[0];
    if (hit) return path.join(dl, hit);
  }
  throw new Error('Azure icon zip not found. Set AZURE_ICON_ZIP or download from '
    + 'https://learn.microsoft.com/azure/architecture/icons/');
}

const zip = new AdmZip(resolveIconZip());
const zipEntries = zip.getEntries();
const iconCache = {};

// Resolve an icon by a distinctive filename fragment so we do not depend on the
// pack's numeric prefixes staying identical across releases.
const iconSpec = {
  funcApp:    'service-function-apps.svg',
  automation: 'service-automation-accounts.svg',
  storage:    'service-storage-accounts.svg',
  acs:        'service-azure-communication-services.svg',
  managedId:  'service-managed-identities.svg',
  policy:     'service-policy.svg',
  budget:     'service-cost-management.svg',
  monitor:    'service-monitor.svg',
  vm:         'service-virtual-machine.svg',
  sqlDb:      'service-sql-database.svg',
  resourceGrp:'service-resource-groups.svg',
  subscription:'service-subscriptions.svg',
};

function loadIcon(key) {
  if (iconCache[key] !== undefined) return iconCache[key];
  const frag = (iconSpec[key] || '').toLowerCase();
  const entry = frag
    ? zipEntries
        .filter(e => e.entryName.toLowerCase().endsWith(frag))
        .sort((a, b) => a.entryName.length - b.entryName.length)[0]
    : null;
  if (!entry) {
    console.warn(`  ! Icon not resolved for key: ${key} (${frag || 'no spec'})`);
    iconCache[key] = null;
    return null;
  }
  iconCache[key] = `data:image/svg+xml;base64,${entry.getData().toString('base64')}`;
  return iconCache[key];
}

function esc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

const containerStyles = {
  region:        ['#F0F7FF', '#6C8EBF'],
  vnet:          ['#E8F5E9', '#43A047'],
  workloadGroup: ['#FFF3E0', '#E65100'],
  dataGroup:     ['#E3F2FD', '#1565C0'],
  resourceGroup: ['#F5F5F5', '#9E9E9E'],
  onPrem:        ['#FCE4EC', '#C62828'],
};

class Diagram {
  constructor(title, subtitle, width = 1520, height = 1080) {
    this.title = title;
    this.subtitle = subtitle;
    this.width = width;
    this.height = height;
    this.boxes = [];
    this.icons = [];
    this.lines = [];
    this.geom = {};
  }

  container(id, label, x, y, w, h, style = 'region', dashed = false) {
    const [fill, border] = containerStyles[style] || containerStyles.region;
    this.geom[id] = { x, y, w, h };
    const borderCss = dashed ? `1px dashed ${border}` : `2px solid ${border}`;
    this.boxes.push(
      `<div class="box" style="left:${x}px;top:${y}px;width:${w}px;height:${h}px;` +
      `background:${fill};border:${borderCss};">` +
      `<div class="box-title" style="color:${border};">${esc(label)}</div></div>`
    );
    return id;
  }

  iconCell(id, label, iconKey, x, y, size = 56) {
    this.geom[id] = { x, y, w: size, h: size + 26 };
    const src = loadIcon(iconKey);
    const img = src
      ? `<img src="${src}" width="${size}" height="${size}" alt="${esc(label)}"/>`
      : `<div class="fallback" style="width:${size}px;height:${size}px;">${esc(iconKey)}</div>`;
    this.icons.push(
      `<div class="icon" style="left:${x}px;top:${y}px;width:${Math.max(size, 120)}px;margin-left:${(size - Math.max(size, 120)) / 2}px;">` +
      `${img}<div class="icon-label">${esc(label)}</div></div>`
    );
    return id;
  }

  // Non-Azure actor (Teams or human) rendered as a labeled chip.
  actor(id, label, x, y, w = 150, h = 60) {
    this.geom[id] = { x, y, w, h };
    this.icons.push(
      `<div class="actor" style="left:${x}px;top:${y}px;width:${w}px;height:${h}px;">${esc(label)}</div>`
    );
    return id;
  }

  _anchor(side, g) {
    switch (side) {
      case 'top':    return { x: g.x + g.w / 2, y: g.y,        dx: 0, dy: -1 };
      case 'bottom': return { x: g.x + g.w / 2, y: g.y + g.h,  dx: 0, dy: 1 };
      case 'left':   return { x: g.x,          y: g.y + g.h / 2, dx: -1, dy: 0 };
      default:       return { x: g.x + g.w,     y: g.y + g.h / 2, dx: 1,  dy: 0 };
    }
  }

  // Orthogonal (elbow) connector between anchored box edges. Sides may be
  // 'auto' (inferred from relative position) or top/bottom/left/right.
  connect(fromId, toId, opts = {}) {
    const { color = '#5B6B7B', width = 2, dashed = false, label = '',
            fromSide = 'auto', toSide = 'auto' } = opts;
    const a = this.geom[fromId], b = this.geom[toId];
    if (!a || !b) return;
    const acx = a.x + a.w / 2, acy = a.y + a.h / 2;
    const bcx = b.x + b.w / 2, bcy = b.y + b.h / 2;
    let fs = fromSide, ts = toSide;
    if (fs === 'auto' || ts === 'auto') {
      const vertical = Math.abs(bcy - acy) >= Math.abs(bcx - acx);
      if (vertical) { fs = bcy >= acy ? 'bottom' : 'top'; ts = bcy >= acy ? 'top' : 'bottom'; }
      else          { fs = bcx >= acx ? 'right'  : 'left'; ts = bcx >= acx ? 'left' : 'right'; }
    }
    const A = this._anchor(fs, a), B = this._anchor(ts, b);
    const stub = 24;
    const A2 = { x: A.x + A.dx * stub, y: A.y + A.dy * stub };
    const B2 = { x: B.x + B.dx * stub, y: B.y + B.dy * stub };
    const vertOrigin = fs === 'top' || fs === 'bottom';
    const corner = vertOrigin ? { x: A2.x, y: B2.y } : { x: B2.x, y: A2.y };
    const pts = [A, A2, corner, B2, B].map(p => `${Math.round(p.x)},${Math.round(p.y)}`).join(' ');
    const dash = dashed ? 'stroke-dasharray="6 5"' : '';
    this.lines.push(`<polyline points="${pts}" fill="none" stroke="${color}" stroke-width="${width}" ${dash} marker-end="url(#arrow)" stroke-linejoin="round"/>`);
    if (label) {
      const lx = (corner.x + B2.x) / 2, ly = (vertOrigin ? corner.y : (A2.y + B2.y) / 2);
      this.lines.push(`<text x="${Math.round(lx)}" y="${Math.round(ly) - 6}" class="edge-label">${esc(label)}</text>`);
    }
  }

  toHtml() {
    return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>${esc(this.title)}</title>
<style>
  body { margin:0; font-family:'Segoe UI',Arial,sans-serif; background:#fff; }
  .canvas { position:relative; width:${this.width}px; height:${this.height}px; margin:12px auto; }
  .box { position:absolute; border-radius:8px; box-sizing:border-box; }
  .box-title { font-weight:600; font-size:13px; padding:5px 12px; }
  .icon { position:absolute; text-align:center; }
  .icon img { display:block; margin:0 auto; }
  .icon-label { font-size:11px; color:#242424; margin-top:3px; line-height:1.25; white-space:pre-line; }
  .actor { position:absolute; display:flex; align-items:center; justify-content:center; text-align:center;
           font-size:12px; font-weight:600; color:#3B2B2B; background:#FCE4EC; border:2px solid #C62828;
           border-radius:10px; box-sizing:border-box; padding:4px 8px; line-height:1.2; }
  .fallback { display:flex; align-items:center; justify-content:center; font-size:9px;
              background:#E3F2FD; border:1px solid #1565C0; border-radius:4px; margin:0 auto; }
  svg.edges { position:absolute; left:0; top:0; pointer-events:none; }
  .edge-label { font-size:10px; fill:#3A4A5A; text-anchor:middle; paint-order:stroke;
                stroke:#fff; stroke-width:3px; stroke-linejoin:round; }
  h1 { font-size:20px; color:#1F3864; text-align:center; margin:14px 0 2px; }
  .sub { font-size:12.5px; color:#556; text-align:center; margin:0 0 4px; }
  .legend { width:${this.width}px; margin:0 auto 20px; font-size:11px; color:#556; text-align:center; }
</style></head>
<body>
  <h1>${esc(this.title)}</h1>
  <div class="sub">${esc(this.subtitle)}</div>
  <div class="canvas">
    ${this.boxes.join('\n    ')}
    <svg class="edges" width="${this.width}" height="${this.height}">
      <defs>
        <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
          <path d="M 0 0 L 10 5 L 0 10 z" fill="#5B6B7B"/>
        </marker>
      </defs>
    ${this.lines.join('\n    ')}
    </svg>
    ${this.icons.join('\n    ')}
  </div>
  <div class="legend">
    Solid arrows show request/data flow &nbsp;&bull;&nbsp; dashed arrows show governance applied at provisioning time.
    HMAC-signed, time-limited owner-action tokens; deletion runs only after the owner confirms.
  </div>
</body></html>`;
  }

  write(filename) {
    const filePath = path.join(OUTPUT_DIR, filename);
    fs.writeFileSync(filePath, this.toHtml(), 'utf8');
    const kb = (Buffer.byteLength(this.toHtml(), 'utf8') / 1024).toFixed(1);
    console.log(`OK ${filename} (${kb} KB)`);
  }
}

function generate() {
  const d = new Diagram(
    'Azure Sandbox Lifecycle - Owner Notification & Deletion Architecture',
    'Daily owner notification, self-service extension, and confirmation-gated deletion using managed identities',
    1520, 1060
  );

  // --- Human owner (outside Azure) ---
  d.container('ext', 'Owner interaction (outside Azure)', 40, 60, 1440, 150, 'onPrem');
  d.actor('flowbot', 'Power Automate Flow bot', 1000, 108, 190, 66);
  d.actor('owner', 'Sandbox owner', 1270, 108, 150, 66);

  // --- Azure ---
  d.container('azure', 'Azure — Management-Subscription', 40, 250, 1440, 780, 'region');

  // Notifications RG
  d.container('rgNotify', 'rg-sbx-notifications', 80, 300, 260, 210, 'resourceGroup', true);
  d.iconCell('acs', 'Azure Communication\nServices (Email)', 'acs', 150, 360);

  // Approval RG
  d.container('rgApproval', 'rg-sbx-approval', 370, 300, 720, 250, 'resourceGroup', true);
  d.iconCell('automation', 'Automation Account\nDaily notice · Reader',     'automation', 410, 360);
  d.iconCell('func',       'Approval Function App\nFlex Consumption · PS 7.4', 'funcApp', 590, 360);
  d.iconCell('storage',    'Storage account\n(identity-based)',           'storage', 770, 360);
  d.iconCell('sysMi',      'Function system MI\nContributor on sub',        'managedId', 960, 360);

  // Provisioning guardrails
  d.container('rgGov', 'Provisioning guardrails (Bicep)', 1120, 300, 300, 250, 'resourceGroup', true);
  d.iconCell('policy', 'Azure Policy\n(allowed locations)', 'policy', 1160, 360);
  d.iconCell('budget', 'Budget alerts\n80% actual · 100% fcst', 'budget', 1320, 360);

  // Optional budget-cleanup path: an action group calls the Function on 100% actual spend.
  d.iconCell('actionGroup', 'Action Group\nbudget \u2192 cleanup', 'monitor', 1150, 560);

  // Managed sandboxes
  d.container('sandboxes', 'Managed sandbox resource groups  ·  tag: sandbox-lifecycle_managed = true', 80, 700, 1340, 300, 'workloadGroup');
  d.container('rg1', 'rg-sbx-api-001 (active)', 130, 760, 360, 210, 'resourceGroup', true);
  d.iconCell('vm1',  'VM',      'vm',      190, 820);
  d.iconCell('st1',  'Storage', 'storage', 360, 820);

  d.container('rg2', 'rg-sbx-data-001 (active)', 560, 760, 360, 210, 'resourceGroup', true);
  d.iconCell('sql2', 'SQL DB',  'sqlDb',   620, 820);
  d.iconCell('st2',  'Storage', 'storage', 790, 820);

  d.container('rg3', 'rg-sbx-sim-001 (expired)', 990, 760, 380, 210, 'resourceGroup', true);
  d.iconCell('vm3',  'VM',      'vm',      1050, 820);
  d.iconCell('st3',  'Storage', 'storage', 1230, 820);

  // --- Flows ---
  d.connect('automation', 'acs',   { fromSide: 'left', toSide: 'right', color: '#1565C0' });
  d.connect('acs', 'owner',        { fromSide: 'top', toSide: 'top', label: 'email notice' });
  d.connect('automation', 'flowbot', { fromSide: 'top', toSide: 'left', label: 'Adaptive Card + owner UPN', color: '#6264A7' });
  d.connect('flowbot', 'owner',    { fromSide: 'right', toSide: 'left', label: 'Teams chat', color: '#6264A7' });
  d.connect('owner', 'func',       { fromSide: 'bottom', toSide: 'top', label: 'Extend or Delete + Confirm', color: '#107C10', width: 3 });
  d.connect('func', 'storage',     { fromSide: 'right', toSide: 'left', label: 'host storage' });
  d.connect('func', 'sysMi',       { fromSide: 'right', toSide: 'left', label: 'uses' });
  d.connect('sysMi', 'rg3',        { fromSide: 'bottom', toSide: 'top', label: 'tags / deletes RG', color: '#A4262C', width: 3 });
  d.connect('automation', 'sandboxes', { fromSide: 'bottom', toSide: 'top', label: 'Resource Graph read', color: '#1565C0' });
  d.connect('policy', 'rg1', { fromSide: 'bottom', toSide: 'top', color: '#7B1FA2', dashed: true, label: 'governs' });
  d.connect('budget', 'rg2', { fromSide: 'bottom', toSide: 'top', color: '#7B1FA2', dashed: true });
  d.connect('budget', 'actionGroup', { fromSide: 'bottom', toSide: 'top', color: '#E65100', width: 2, label: '100% actual' });
  d.connect('actionGroup', 'func', { fromSide: 'left', toSide: 'right', color: '#E65100', width: 2, label: 'webhook \u2192 mark expired' });

  d.write('sandbox-lifecycle-architecture.html');
}

generate();
console.log('Done.');
